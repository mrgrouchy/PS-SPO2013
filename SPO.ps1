<#
.SYNOPSIS
    Inventories all "Workflow" app registrations in Entra ID.
    Classifies by credential status, owner presence, and SP existence.

.NOTES
    Required scopes: Application.Read.All, Directory.Read.All
    Minimum role:    Application Administrator (read-only is fine here)
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications

[CmdletBinding()]
param(
    [string]$ExportPath  = ".\WorkflowAppRegistrations_$(Get-Date -Format 'yyyyMMdd_HHmm').csv",
    [switch]$SkipConnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Array {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return ,([object[]]@())
    }

    return ,([object[]]@($InputObject))
}

# ── Connect ──────────────────────────────────────────────────────────────────
if (-not $SkipConnect) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All" `
                    -NoWelcome
}

# ── Retrieve all "Workflow" app registrations ─────────────────────────────────
Write-Host "Querying app registrations named 'Workflow'..." -ForegroundColor Cyan

# Graph filter — picks up exact match and prefixed variants
$appsResponse = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=startswith(displayName,'Workflow')&`$select=id,appId,displayName,createdDateTime,passwordCredentials,keyCredentials,owners&`$top=999&`$count=true" `
    -Headers @{ ConsistencyLevel = "eventual" }
$apps = ConvertTo-Array $appsResponse.value
$appCount = $apps.Count

Write-Host "  Found $appCount app registrations." -ForegroundColor Gray

if ($appCount -eq 0) {
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "No matching app registrations found. Exported an empty CSV to: $ExportPath" -ForegroundColor Yellow
    return
}

# ── Build results ─────────────────────────────────────────────────────────────
$now    = Get-Date
$cutoff = $now.AddDays(-180)
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

$i = 0
foreach ($app in $apps) {
    $i++
    Write-Progress -Activity "Processing app registrations" `
                   -Status "$i / $appCount  — $($app.displayName)" `
                   -PercentComplete (($i / $appCount) * 100)

    # ── Credentials ──────────────────────────────────────────────────────────
    $secrets = ConvertTo-Array $app.passwordCredentials
    $certs   = ConvertTo-Array $app.keyCredentials

    $hasActiveSecret = $secrets | Where-Object {
        $_.endDateTime -and [datetime]$_.endDateTime -gt $now
    }
    $hasActiveCert = $certs | Where-Object {
        $_.endDateTime -and [datetime]$_.endDateTime -gt $now
    }
    $hasExpiredSecret = $secrets | Where-Object {
        $_.endDateTime -and [datetime]$_.endDateTime -le $now
    }
    $soonestExpiry = ($secrets + $certs |
        Where-Object { $_.endDateTime } |
        Sort-Object { [datetime]$_.endDateTime } |
        Select-Object -First 1).endDateTime

    $credStatus = if ($hasActiveSecret -or $hasActiveCert) {
        "Active credentials"
    } elseif ($hasExpiredSecret) {
        "Expired credentials only"
    } else {
        "No credentials"
    }

    # ── Owners ────────────────────────────────────────────────────────────────
    # Owners aren't expanded inline in bulk queries — fetch per app
    $ownerCount = 0
    try {
        $ownerResp = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/owners?`$select=id,displayName" `
            -ErrorAction SilentlyContinue
        $ownerCount = (ConvertTo-Array $ownerResp.value).Count
    } catch { <# tolerate 404 / permission gaps #> }

    # ── Service principal ─────────────────────────────────────────────────────
    $sp = $null
    $spEnabled = $null
    try {
        $spResp = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id,accountEnabled,tags,servicePrincipalType" `
            -ErrorAction SilentlyContinue
        $sp = ConvertTo-Array $spResp.value | Select-Object -First 1
        if ($sp) { $spEnabled = $sp.accountEnabled }
    } catch { <# tolerate #> }

    # ── Age classification ────────────────────────────────────────────────────
    $createdDate    = [datetime]$app.createdDateTime
    $ageClassification = if ($createdDate -lt $cutoff) { "Legacy (>180 days)" } else { "Recent (<180 days)" }

    # ── Risk tier ─────────────────────────────────────────────────────────────
    $riskTier = switch ($true) {
        { $credStatus -eq "Active credentials" -and $ownerCount -eq 0 } { "HIGH — active creds, no owner"; break }
        { $credStatus -eq "Active credentials" -and $ownerCount -gt 0 } { "MEDIUM — active creds, has owner"; break }
        { $credStatus -eq "Expired credentials only" }                  { "LOW — expired creds"; break }
        default                                                          { "INFO — no creds" }
    }

    $results.Add([PSCustomObject]@{
        DisplayName         = $app.displayName
        AppId               = $app.appId
        ObjectId            = $app.id
        CreatedDate         = $createdDate.ToString("yyyy-MM-dd")
        AgeClassification   = $ageClassification
        CredentialStatus    = $credStatus
        SoonestExpiry       = if ($soonestExpiry) { ([datetime]$soonestExpiry).ToString("yyyy-MM-dd") } else { "" }
        OwnerCount          = $ownerCount
        SPExists            = if ($sp) { $true } else { $false }
        SPEnabled           = $spEnabled
        SPType              = $sp.servicePrincipalType
        RiskTier            = $riskTier
    })
}

Write-Progress -Activity "Processing app registrations" -Completed

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n── Summary ──────────────────────────────────────" -ForegroundColor Cyan
$results | Group-Object RiskTier | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-45} {1}" -f $_.Name, $_.Count) }

Write-Host "`n── Credential status ────────────────────────────" -ForegroundColor Cyan
$results | Group-Object CredentialStatus | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-30} {1}" -f $_.Name, $_.Count) }

Write-Host "`n── Age ──────────────────────────────────────────" -ForegroundColor Cyan
$results | Group-Object AgeClassification | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-30} {1}" -f $_.Name, $_.Count) }

# ── Export ────────────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Host "`nExported $($results.Count) records to: $ExportPath" -ForegroundColor Green

# ── High-risk subset to console ───────────────────────────────────────────────
$highRisk = @( $results | Where-Object { $_.RiskTier -like "HIGH*" } )
if ($highRisk.Count -gt 0) {
    Write-Host "`n── HIGH risk (active creds, no owner) ──────────" -ForegroundColor Red
    $highRisk | Select-Object DisplayName, AppId, CreatedDate, SoonestExpiry |
        Format-Table -AutoSize
}
