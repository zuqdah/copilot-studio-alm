<#
    .SYNOPSIS
        Reports what this lab has actually cost, and what it is able to cost.

    .DESCRIPTION
        Two different questions. Azure Cost Management answers the first but
        lags 24-48 hours, so a lab built and torn down inside a day reads as
        zero even when it was not. The billing policy answers the second
        immediately: a meter that is switched off cannot bill, whatever the
        usage. Both are printed, because either alone is misleading.
#>
[CmdletBinding()]
param(
    [string]$BillingPolicyId = '4e444929-2d60-4f12-9396-fb35c1d72ab4',
    [string]$ResourceGroup   = 'rg-powerplatform-lab'
)

$ErrorActionPreference = 'Stop'

# --- what can bill at all --------------------------------------------------
$ppToken = az account get-access-token --resource 'https://api.powerplatform.com' --query accessToken -o tsv
$policy = Invoke-RestMethod -Method Get `
    -Uri "https://api.powerplatform.com/licensing/billingPolicies/$BillingPolicyId`?api-version=2024-10-01" `
    -Headers @{ Authorization = "Bearer $ppToken" }

$rates = @{
    MCSMessages             = '$0.01 per Copilot Credit'
    Database                = '$48 per GB/month above 1 GB free'
    File                    = '$2.40 per GB/month above 1 GB free'
    Log                     = '$12 per GB/month, no free tier'
    CloudFlowRuns           = '$0.60 per premium flow run'
    PAAttendedRPA           = '$3.00 per run'
    PAUnattendedRPA         = '$3.00 per run'
    AppPass                 = '$10 per active user/app/month'
    PowerPagesAuthenticated = '$4 per active user/site/month'
    PowerPagesAnonymous     = '$0.30 per active user/site/month'
    W365APAYGO              = 'Cloud PC execution'
}

Write-Host "`nMeters on policy $($policy.name):" -ForegroundColor Cyan
$policy.payGoEntitlements |
    Sort-Object -Property @{ Expression = 'payAsYouGoState'; Descending = $true }, entitlementId |
    ForEach-Object {
        [pscustomobject]@{
            Meter   = $_.entitlementId
            Billing = if ($_.payAsYouGoState) { 'ENABLED' } else { 'off' }
            Rate    = $rates[$_.entitlementId]
        }
    } | Format-Table -AutoSize | Out-String -Width 90 | Write-Host

# --- what has billed -------------------------------------------------------
$sub = az account show --query id -o tsv
$body = @{
    type      = 'ActualCost'
    timeframe = 'MonthToDate'
    dataset   = @{
        granularity = 'None'
        aggregation = @{ totalCost = @{ name = 'PreTaxCost'; function = 'Sum' } }
        grouping    = @(@{ type = 'Dimension'; name = 'ServiceName' })
    }
} | ConvertTo-Json -Depth 10 -Compress

$tmp = Join-Path $env:TEMP 'labcost-query.json'
[System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Month-to-date actual cost:" -ForegroundColor Cyan
$raw = az rest --method post --only-show-errors `
    --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
    --body "@$tmp" -o json 2>$null

if (-not $raw) {
    # Cost Management throttles aggressively and rejects bursts with 429.
    Write-Host "  Cost Management did not answer (throttled, or no usage posted yet)." -ForegroundColor Yellow
    Write-Host "  Billing data lags 24-48 hours, so a same-day lab reads as zero."
}
else {
    $rows = ($raw | ConvertFrom-Json).properties.rows
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Host "  No usage records posted yet."
    }
    else {
        $total = 0.0
        foreach ($r in $rows) {
            '  {0,-42} ${1:N4}' -f $r[1], $r[0] | Write-Host
            $total += [double]$r[0]
        }
        '  {0,-42} ${1:N4}' -f 'TOTAL', $total | Write-Host -ForegroundColor Green
    }
}

# --- budget ----------------------------------------------------------------
$budget = az consumption budget list --only-show-errors -o json 2>$null | ConvertFrom-Json
if ($budget) {
    Write-Host "`nBudgets:" -ForegroundColor Cyan
    $budget | ForEach-Object {
        '  {0}: ${1} {2}, current spend ${3:N2}' -f $_.name, $_.amount, $_.timeGrain, [double]$_.currentSpend.amount | Write-Host
    }
}
