<#
    .SYNOPSIS
        Upserts the agent defined under agent/ into a Dataverse environment.

    .DESCRIPTION
        The designer is not the source of truth; agent/ is. This reads the
        manifest and topic files and makes the target environment match them,
        creating what is missing and updating what has drifted. Running it
        twice changes nothing the second time.

    .PARAMETER InstanceUrl
        Dataverse URL, e.g. https://org.crm.dynamics.com/
#>
[CmdletBinding(SupportsShouldProcess)]
# The change table is the product of a run, so it goes to the console.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Human-readable change report.')]
param(
    [Parameter(Mandatory)]
    [string]$InstanceUrl
)

$ErrorActionPreference = 'Stop'
if (-not $InstanceUrl.EndsWith('/')) { $InstanceUrl += '/' }

$root     = Split-Path $PSScriptRoot -Parent
$manifest = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path $root -ChildPath 'agent') -ChildPath 'agent.json')) | ConvertFrom-Json

$token = az account get-access-token --resource $InstanceUrl --query accessToken -o tsv
if (-not $token) { throw "Could not get a token for $InstanceUrl" }

$api             = "${InstanceUrl}api/data/v9.2/"
$script:Token    = $token
$script:SendFile = Join-Path ([System.IO.Path]::GetTempPath()) "dv-send-$PID.json"
$script:RecvFile = Join-Path ([System.IO.Path]::GetTempPath()) "dv-recv-$PID.json"

function Invoke-Dv {
    param(
        [string]$Method = 'Get',
        [Parameter(Mandatory)][string]$Path,
        [object]$Body,
        [string]$SolutionName
    )
    # curl, not Invoke-RestMethod. Under Windows PowerShell 5.1 a write to this
    # API can block indefinitely and ignore -TimeoutSec entirely; curl honours
    # --max-time, so a stuck call fails the run instead of wedging it.
    $curlArgs = @(
        '-s', '-S', '--max-time', '60',
        '-o', $script:RecvFile, '-w', '%{http_code}',
        '-X', $Method.ToUpper(),
        '-H', "Authorization: Bearer $script:Token",
        '-H', 'Accept: application/json',
        '-H', 'OData-MaxVersion: 4.0',
        '-H', 'OData-Version: 4.0'
    )
    if ($SolutionName) { $curlArgs += @('-H', "MSCRM.SolutionUniqueName: $SolutionName") }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        # A UTF-8 BOM makes this API fail with a parse error at position 0.
        [System.IO.File]::WriteAllText($script:SendFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        $curlArgs += @('-H', 'Content-Type: application/json', '--data-binary', "@$script:SendFile")
    }
    # OData filters carry spaces and quotes; curl rejects them unencoded.
    $encoded = $Path.Replace(' ', '%20').Replace("'", '%27')
    $curlArgs += "$api$encoded"

    Write-Verbose "-> $Method $Path"
    $code = & curl.exe @curlArgs
    Write-Verbose "<- HTTP $code"
    $raw  = if (Test-Path $script:RecvFile) { [System.IO.File]::ReadAllText($script:RecvFile) } else { '' }
    if ($code -notmatch '^2') { throw "$Method $Path returned HTTP $code. $raw" }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $raw | ConvertFrom-Json
}

$changes = [System.Collections.Generic.List[object]]::new()
function Add-Change {
    param([string]$Kind, [string]$Name, [string]$Action)
    $changes.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Action = $Action })
}
# --- publisher -------------------------------------------------------------
$p = Invoke-Dv -Path "publishers?`$filter=uniquename eq '$($manifest.publisher.uniqueName)'&`$select=publisherid"
if ($p.value.Count) {
    $publisherId = $p.value[0].publisherid
    Add-Change -Kind 'publisher' -Name $manifest.publisher.uniqueName -Action 'Exists'
}
elseif ($PSCmdlet.ShouldProcess($manifest.publisher.uniqueName, 'create publisher')) {
    $null = Invoke-Dv -Method Post -Path 'publishers' -Body @{
        uniquename                     = $manifest.publisher.uniqueName
        friendlyname                   = $manifest.publisher.friendlyName
        customizationprefix            = $manifest.publisher.prefix
        customizationoptionvalueprefix = $manifest.publisher.optionValuePrefix
    }
    $p = Invoke-Dv -Path "publishers?`$filter=uniquename eq '$($manifest.publisher.uniqueName)'&`$select=publisherid"
    $publisherId = $p.value[0].publisherid
    Add-Change -Kind 'publisher' -Name $manifest.publisher.uniqueName -Action 'Created'
}
else { Add-Change -Kind 'publisher' -Name $manifest.publisher.uniqueName -Action 'WouldCreate'; $publisherId = $null }

# --- solution --------------------------------------------------------------
$s = Invoke-Dv -Path "solutions?`$filter=uniquename eq '$($manifest.solution.uniqueName)'&`$select=solutionid,version"
if ($s.value.Count) {
    Add-Change -Kind 'solution' -Name $manifest.solution.uniqueName -Action 'Exists'
}
elseif ($publisherId -and $PSCmdlet.ShouldProcess($manifest.solution.uniqueName, 'create solution')) {
    $null = Invoke-Dv -Method Post -Path 'solutions' -Body @{
        uniquename               = $manifest.solution.uniqueName
        friendlyname             = $manifest.solution.friendlyName
        version                  = $manifest.solution.version
        description              = $manifest.solution.description
        'publisherid@odata.bind' = "/publishers($publisherId)"
    }
    Add-Change -Kind 'solution' -Name $manifest.solution.uniqueName -Action 'Created'
}
else { Add-Change -Kind 'solution' -Name $manifest.solution.uniqueName -Action 'WouldCreate' }

# --- agent -----------------------------------------------------------------
$schema = $manifest.agent.schemaName
$b = Invoke-Dv -Path "bots?`$filter=schemaname eq '$schema'&`$select=botid,name"
if ($b.value.Count) {
    $botId = $b.value[0].botid
    Add-Change -Kind 'agent' -Name $manifest.agent.name -Action 'Exists'
}
elseif ($PSCmdlet.ShouldProcess($manifest.agent.name, 'create agent')) {
    $null = Invoke-Dv -Method Post -Path 'bots' -SolutionName $manifest.solution.uniqueName -Body @{
        name       = $manifest.agent.name
        schemaname = $schema
        language   = $manifest.agent.language
    }
    $b = Invoke-Dv -Path "bots?`$filter=schemaname eq '$schema'&`$select=botid"
    $botId = $b.value[0].botid
    Add-Change -Kind 'agent' -Name $manifest.agent.name -Action 'Created'
}
else { Add-Change -Kind 'agent' -Name $manifest.agent.name -Action 'WouldCreate'; $botId = $null }

# --- topics ----------------------------------------------------------------
$topicsDir = Join-Path -Path (Join-Path -Path $root -ChildPath 'agent') -ChildPath 'topics'
foreach ($topic in $manifest.topics) {
    # ReadAllText, not Get-Content -Raw. Get-Content decorates its output with
    # ETS properties including PSDrive and PSProvider, which are deep enough to
    # make ConvertTo-Json -Depth 10 walk them forever. The string looks
    # identical and the serializer hangs with no error.
    $yaml = [System.IO.File]::ReadAllText((Join-Path -Path $topicsDir -ChildPath $topic.file))

    $existing = Invoke-Dv -Path "botcomponents?`$filter=schemaname eq '$($topic.schemaName)'&`$select=botcomponentid,data"
    if ($existing.value.Count) {
        if ($existing.value[0].data -eq $yaml) {
            Add-Change -Kind 'topic' -Name $topic.name -Action 'Unchanged'
        }
        elseif ($PSCmdlet.ShouldProcess($topic.name, 'update topic')) {
            $null = Invoke-Dv -Method Patch -Path "botcomponents($($existing.value[0].botcomponentid))" -SolutionName $manifest.solution.uniqueName -Body @{ data = $yaml }
            Add-Change -Kind 'topic' -Name $topic.name -Action 'Updated'
        }
        else { Add-Change -Kind 'topic' -Name $topic.name -Action 'WouldUpdate' }
    }
    elseif ($botId -and $PSCmdlet.ShouldProcess($topic.name, 'create topic')) {
        $null = Invoke-Dv -Method Post -Path 'botcomponents' -SolutionName $manifest.solution.uniqueName -Body @{
            name                     = $topic.name
            schemaname               = $topic.schemaName
            componenttype            = 9
            data                     = $yaml
            'parentbotid@odata.bind' = "/bots($botId)"
        }
        Add-Change -Kind 'topic' -Name $topic.name -Action 'Created'
    }
    else { Add-Change -Kind 'topic' -Name $topic.name -Action 'WouldCreate' }
}

foreach ($tmp in @($script:SendFile, $script:RecvFile)) {
    if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) }
}

$changes | Format-Table -AutoSize | Out-String -Width 80 | Write-Host
[pscustomobject]@{
    InstanceUrl = $InstanceUrl
    Created     = @($changes | Where-Object Action -eq 'Created').Count
    Updated     = @($changes | Where-Object Action -eq 'Updated').Count
    Unchanged   = @($changes | Where-Object { $_.Action -in 'Unchanged', 'Exists' }).Count
    Planned     = @($changes | Where-Object { $_.Action -like 'Would*' }).Count
}