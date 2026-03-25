<#
.SYNOPSIS
    Inventories all "Workflow" app registrations in Entra ID.
    Classifies by credential status, owner presence, and service principal presence.

.NOTES
    Required scopes: Application.Read.All, Directory.Read.All
    Minimum role:    Application Administrator (read-only is fine here)
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications

[CmdletBinding()]
param(
    [string]$ExportPath  = ".\WorkflowAppRegistrations_$(Get-Date -Format 'yyyyMMdd_HHmm').csv",
    [string]$NamePrefix  = "Workflow",
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

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-GraphNextLink {
    param(
        [AllowNull()]
        [object]$ResponseObject
    )

    if ($null -eq $ResponseObject) {
        return $null
    }

    foreach ($propertyName in @('@odata.nextLink', '@odata.nextlink', 'odata.nextLink', 'odata.nextlink', 'NextLink', 'nextLink')) {
        $propertyValue = Get-ObjectPropertyValue -InputObject $ResponseObject -PropertyName $propertyName
        if ($propertyValue) {
            return $propertyValue
        }
    }

    if ($ResponseObject -is [System.Collections.IDictionary]) {
        foreach ($key in @('@odata.nextLink', '@odata.nextlink', 'odata.nextLink', 'odata.nextlink', 'NextLink', 'nextLink')) {
            if ($ResponseObject.Contains($key) -and $ResponseObject[$key]) {
                return $ResponseObject[$key]
            }
        }
    }

    return $null
}

function Invoke-GraphCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [hashtable]$Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri

    while ($nextUri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri -Headers $Headers

        foreach ($item in (ConvertTo-Array $response.value)) {
            $items.Add($item)
        }

        $nextUri = Get-GraphNextLink -ResponseObject $response
    }

    return ,([object[]]$items.ToArray())
}

# ── Connect ──────────────────────────────────────────────────────────────────
if (-not $SkipConnect) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All" `
                    -NoWelcome
}

# ── Retrieve all "Workflow" app registrations ─────────────────────────────────
Write-Host "Querying app registrations and service principals with names starting '$NamePrefix'..." -ForegroundColor Cyan

# Graph filter — picks up exact match and prefixed variants
$escapedPrefix = $NamePrefix.Replace("'", "''")
$apps = Invoke-GraphCollection `
    -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=startswith(displayName,'$escapedPrefix')&`$select=id,appId,displayName,createdDateTime,passwordCredentials,keyCredentials&`$top=999" `
    -Headers @{ ConsistencyLevel = "eventual" }
$servicePrincipals = Invoke-GraphCollection `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=startswith(displayName,'$escapedPrefix')&`$select=id,appId,displayName,accountEnabled,tags,servicePrincipalType,createdDateTime&`$top=999" `
    -Headers @{ ConsistencyLevel = "eventual" }

$appCount = $apps.Count
$servicePrincipalCount = $servicePrincipals.Count

$servicePrincipalByAppId = @{}
foreach ($servicePrincipal in $servicePrincipals) {
    if ($servicePrincipal.appId -and -not $servicePrincipalByAppId.ContainsKey($servicePrincipal.appId)) {
        $servicePrincipalByAppId[$servicePrincipal.appId] = $servicePrincipal
    }
}

Write-Host "  Found $appCount app registrations and $servicePrincipalCount service principals." -ForegroundColor Gray

if (($appCount + $servicePrincipalCount) -eq 0) {
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "No matching app registrations or service principals found. Exported an empty CSV to: $ExportPath" -ForegroundColor Yellow
    return
}

# ── Build results ─────────────────────────────────────────────────────────────
$now    = Get-Date
$cutoff = $now.AddDays(-180)
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$appIdsSeen = [System.Collections.Generic.HashSet[string]]::new()

$i = 0
foreach ($app in $apps) {
    $i++
    Write-Progress -Activity "Processing app registrations" `
                   -Status "$i / $appCount  — $($app.displayName)" `
                   -PercentComplete (($i / $appCount) * 100)

    if ($app.appId) {
        [void]$appIdsSeen.Add($app.appId)
    }

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
    $spType = $null
    if ($app.appId -and $servicePrincipalByAppId.ContainsKey($app.appId)) {
        $sp = $servicePrincipalByAppId[$app.appId]
        $spEnabled = Get-ObjectPropertyValue -InputObject $sp -PropertyName 'accountEnabled'
        $spType = Get-ObjectPropertyValue -InputObject $sp -PropertyName 'servicePrincipalType'
    }

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
        RecordType          = "Application"
        DisplayName         = $app.displayName
        AppId               = $app.appId
        ObjectId            = $app.id
        AppRegistrationExists = $true
        CreatedDate         = $createdDate.ToString("yyyy-MM-dd")
        AgeClassification   = $ageClassification
        CredentialStatus    = $credStatus
        SoonestExpiry       = if ($soonestExpiry) { ([datetime]$soonestExpiry).ToString("yyyy-MM-dd") } else { "" }
        OwnerCount          = $ownerCount
        SPExists            = if ($sp) { $true } else { $false }
        SPEnabled           = $spEnabled
        SPType              = $spType
        RiskTier            = $riskTier
    })
}

Write-Progress -Activity "Processing app registrations" -Completed

foreach ($sp in $servicePrincipals) {
    if ($sp.appId -and $appIdsSeen.Contains($sp.appId)) {
        continue
    }

    $createdDate = $null
    if ($sp.createdDateTime) {
        $createdDate = [datetime]$sp.createdDateTime
    }

    $spEnabled = Get-ObjectPropertyValue -InputObject $sp -PropertyName 'accountEnabled'
    $spType = Get-ObjectPropertyValue -InputObject $sp -PropertyName 'servicePrincipalType'

    $results.Add([PSCustomObject]@{
        RecordType            = "ServicePrincipalOnly"
        DisplayName           = $sp.displayName
        AppId                 = $sp.appId
        ObjectId              = $sp.id
        AppRegistrationExists = $false
        CreatedDate           = if ($createdDate) { $createdDate.ToString("yyyy-MM-dd") } else { "" }
        AgeClassification     = if ($createdDate) { if ($createdDate -lt $cutoff) { "Legacy (>180 days)" } else { "Recent (<180 days)" } } else { "Unknown" }
        CredentialStatus      = "Unknown (service principal only)"
        SoonestExpiry         = ""
        OwnerCount            = ""
        SPExists              = $true
        SPEnabled             = $spEnabled
        SPType                = $spType
        RiskTier              = "INFO — service principal only"
    })
}

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
