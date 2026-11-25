#Requires -Version 7.0
<#
.SYNOPSIS
    Loads Change Radar's synthetic demo organisation into an environment and switches demo_data on (ADR 0022).
.DESCRIPTION
    For evaluation and training environments only: never load demo data in production. The script refuses an
    environment whose type is Production (checked with the Power Platform admin API when the signed-in user can read
    it; otherwise -NotProduction must be given to confirm).

    Plans by default; -Apply loads. The estate (assets, asset fingerprints, solutions and memberships) is written by
    setup/Import-Estate.ps1, labelled source = synthetic and the synthetic organisation's name. Exposures and
    ratings follow at the next match run (06:00 UTC) and assess run; assessing demo signals uses AI Builder credits.
    Remove it all again with setup/Remove-DemoData.ps1.
.EXAMPLE
    ./setup/Import-DemoData.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<friendly name>'
    ./setup/Import-DemoData.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<friendly name>' -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string]$EstatePath = (Join-Path $PSScriptRoot '..' 'samples' 'synthetic' 'mid-size-enterprise' 'estate.json'),
    [switch]$NotProduction,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Get-Token([string]$Resource) { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $Resource -AsSecureString).Token -AsPlainText }
$org = Invoke-RestMethod -Headers @{ Authorization = "Bearer $(Get-Token $EnvironmentUrl)"; Accept = 'application/json' } -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Nothing changed." }

# Never production: ask the Power Platform admin API for the environment type.
$sku = $null
try {
    $env = Invoke-RestMethod -Headers @{ Authorization = "Bearer $(Get-Token 'https://service.powerapps.com/')" } -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($org.Detail.EnvironmentId)?api-version=2020-10-01"
    $sku = $env.properties.environmentSku
} catch { $sku = $null }
if ($sku -eq 'Production') { throw "'$ExpectedEnvironmentName' is a Production environment. Demo data is never loaded in production." }
if (-not $sku -and -not $NotProduction) { throw "Couldn't read the environment type. If '$ExpectedEnvironmentName' is not a production environment, re-run with -NotProduction." }
Write-Host "Environment '$ExpectedEnvironmentName' type: $(if ($sku) { $sku } else { 'not readable; confirmed not production with -NotProduction' })"

& (Join-Path $PSScriptRoot 'Import-Estate.ps1') -EnvironmentUrl $EnvironmentUrl -EstatePath $EstatePath -ExpectedEnvironmentName $ExpectedEnvironmentName -NotProduction:$NotProduction -Apply:$Apply
if (-not $Apply) { Write-Host "demo_data would be set to 'on'."; return }

$h = @{ Authorization = "Bearer $(Get-Token $EnvironmentUrl)"; Accept = 'application/json'; 'OData-Version' = '4.0' }
$row = @((Invoke-RestMethod -Headers $h -Uri "$dv/crdr_configs?`$select=crdr_configid&`$filter=crdr_key eq 'demo_data'").value)
if ($row) { Invoke-RestMethod -Method PATCH -Uri "$dv/crdr_configs($($row[0].crdr_configid))" -Headers ($h + @{ 'If-Match' = '*' }) -ContentType 'application/json' -Body '{"crdr_value":"on"}' | Out-Null }
else { Invoke-RestMethod -Method POST -Uri "$dv/crdr_configs" -Headers $h -ContentType 'application/json' -Body '{"crdr_key":"demo_data","crdr_value":"on"}' | Out-Null }
Write-Host "demo_data is on. Exposures and ratings for the demo organisation follow at the next match and assess runs."
