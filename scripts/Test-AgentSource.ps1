<#
    .SYNOPSIS
        Validates the agent source tree before anything is deployed.

    .DESCRIPTION
        Deploy-Agent.ps1 makes an environment match agent/. That is only safe
        if agent/ is coherent, so these checks run first and in CI: the
        manifest and the files on disk must agree, schema names must be unique
        and carry the publisher prefix, and every topic must parse as YAML and
        declare a trigger. A typo in a schema name would otherwise create a
        second component rather than update the intended one.
#>
[CmdletBinding()]
# The findings list is the product of this script, so it goes to the console.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Human-readable validation report.')]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path $PSScriptRoot -Parent }

$problems = [System.Collections.Generic.List[string]]::new()
function Add-Problem { param([string]$Message) $problems.Add($Message) }

$agentDir  = Join-Path -Path $Path -ChildPath 'agent'
$topicsDir = Join-Path -Path $agentDir -ChildPath 'topics'
$manifestPath = Join-Path -Path $agentDir -ChildPath 'agent.json'

if (-not (Test-Path $manifestPath)) { throw "No manifest at $manifestPath" }

try { $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json }
catch { throw "agent.json is not valid JSON: $($_.Exception.Message)" }

# --- manifest shape --------------------------------------------------------
foreach ($key in 'publisher', 'solution', 'agent', 'topics') {
    if (-not $manifest.PSObject.Properties.Name.Contains($key)) { Add-Problem "manifest is missing '$key'" }
}

$prefix = $manifest.publisher.prefix
if ([string]::IsNullOrWhiteSpace($prefix)) { Add-Problem 'publisher.prefix is empty' }
elseif ($prefix -notmatch '^[a-z][a-z0-9]{1,7}$') {
    # Dataverse requires 2-8 characters, starting with a letter.
    Add-Problem "publisher.prefix '$prefix' is not 2-8 lowercase alphanumeric characters starting with a letter"
}

if ($manifest.agent.schemaName -notlike "${prefix}_*") {
    Add-Problem "agent.schemaName '$($manifest.agent.schemaName)' does not start with the publisher prefix '${prefix}_'"
}

# --- manifest and disk must agree -----------------------------------------
$declared = @($manifest.topics)
$onDisk   = @(Get-ChildItem -Path $topicsDir -Filter *.yaml -ErrorAction SilentlyContinue)

foreach ($topic in $declared) {
    $file = Join-Path -Path $topicsDir -ChildPath $topic.file
    if (-not (Test-Path $file)) { Add-Problem "topic '$($topic.name)' declares $($topic.file), which does not exist" }
    if ($topic.schemaName -notlike "${prefix}_*") {
        Add-Problem "topic '$($topic.name)' schemaName '$($topic.schemaName)' does not start with '${prefix}_'"
    }
}

foreach ($file in $onDisk) {
    if ($declared.file -notcontains $file.Name) {
        # An unreferenced topic is never deployed, which is a silent no-op.
        Add-Problem "$($file.Name) is not referenced by agent.json and would never deploy"
    }
}

$dupeSchema = $declared | Group-Object schemaName | Where-Object Count -gt 1
foreach ($d in $dupeSchema) { Add-Problem "schemaName '$($d.Name)' is declared $($d.Count) times" }

$dupeFile = $declared | Group-Object file | Where-Object Count -gt 1
foreach ($d in $dupeFile) { Add-Problem "file '$($d.Name)' is declared $($d.Count) times" }

# --- topics must parse and declare a trigger ------------------------------
$yamlModule = Get-Module -ListAvailable -Name powershell-yaml | Select-Object -First 1
if ($yamlModule) { Import-Module powershell-yaml -ErrorAction Stop }
else { Write-Warning 'powershell-yaml not installed; topics are checked structurally only.' }

foreach ($topic in $declared) {
    $file = Join-Path -Path $topicsDir -ChildPath $topic.file
    if (-not (Test-Path $file)) { continue }
    $text = [System.IO.File]::ReadAllText($file)

    if ($yamlModule) {
        try { $doc = ConvertFrom-Yaml $text }
        catch { Add-Problem "$($topic.file) is not valid YAML: $($_.Exception.Message)"; continue }

        if ($doc.kind -ne 'AdaptiveDialog') { Add-Problem "$($topic.file) has kind '$($doc.kind)', expected AdaptiveDialog" }
        if (-not $doc.beginDialog)          { Add-Problem "$($topic.file) has no beginDialog" }
        $queries = $doc.beginDialog.intent.triggerQueries
        if (-not $queries -or @($queries).Count -eq 0) {
            # A topic with no trigger can never be matched.
            Add-Problem "$($topic.file) declares no triggerQueries, so it can never fire"
        }
        if (-not $doc.beginDialog.actions -or @($doc.beginDialog.actions).Count -eq 0) {
            Add-Problem "$($topic.file) has no actions, so it would do nothing"
        }
    }
    else {
        foreach ($needle in 'kind: AdaptiveDialog', 'beginDialog:', 'triggerQueries:', 'actions:') {
            if ($text -notmatch [regex]::Escape($needle)) { Add-Problem "$($topic.file) is missing '$needle'" }
        }
    }
}

# --- report ----------------------------------------------------------------
$checked = [pscustomobject]@{
    Manifest = Split-Path $manifestPath -Leaf
    Topics   = $declared.Count
    Files    = $onDisk.Count
    Problems = $problems.Count
}
$checked | Format-List | Out-String | Write-Host

if ($problems.Count) {
    $problems | ForEach-Object { Write-Host "  FAIL  $_" }
    throw "Agent source validation found $($problems.Count) problem(s)."
}
Write-Host 'Agent source is valid.'