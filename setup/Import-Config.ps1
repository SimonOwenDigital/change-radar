#Requires -Version 7.0
<#
.SYNOPSIS
    Loads Change Radar's settings (seed/config.csv) into crdr_config, and sets the install-specific ones (ADR 0022).
.DESCRIPTION
    Plans by default; -Apply writes. A setting that doesn't exist yet is created with its seed value. An existing
    setting is never overwritten: it's the installer's choice, so only its description is refreshed. The exceptions are
    the install-specific values given on the command line (they're tenant data, so they never live in the repo):
      -AlertRecipient     alert_recipient: the user principal name that receives Teams cards
      -AlertDestinations  alert_destinations: chat:/channel:/email: entries separated by ';' (ADR 0011 addendum)
      -DetailEnvironments detail_environments: environment URLs separated by ';' whose solution detail the reader reads
    app_url is set to this environment's Change Radar app.
    catchup_until (install test finding 14): when this script first creates it on a fresh install (no signal fingerprinted yet),
    it is set to today + -CatchupDays (default 14), so the first weeks run at catchup_max_per_run. On an existing install it is
    created empty (no catch-up) unless -CatchupDays is given. It is never changed once it exists.

    Runs as the signed-in user (Connect-AzAccount), who needs write access to crdr_config.
.EXAMPLE
    ./setup/Import-Config.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>' -AlertRecipient admin@contoso.com
    ./setup/Import-Config.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>' -AlertRecipient admin@contoso.com -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string]$AlertRecipient,
    [string]$AlertDestinations,
    [string]$DetailEnvironments,
    [ValidateRange(0, 119)][int]$CatchupDays = 14,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'seed' 'config.csv'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Get-Header { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' } }
$org = Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Nothing changed." }

$install = @{}
if ($AlertRecipient) { $install['alert_recipient'] = $AlertRecipient }
if ($AlertDestinations) { $install['alert_destinations'] = $AlertDestinations }
if ($DetailEnvironments) { $install['detail_environments'] = $DetailEnvironments }
$app = @((Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/appmodules?`$select=appmoduleid&`$filter=uniquename eq 'crdr_ChangeRadar'").value)
if ($app) { $install['app_url'] = "$EnvironmentUrl/main.aspx?appid=$($app[0].appmoduleid)" }

# Catch-up date, used only if catchup_until is created now: on a fresh install, or when -CatchupDays is given.
$fresh = -not @((Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/crdr_signals?`$select=crdr_signalid&`$filter=crdr_fingerprintedon ne null&`$top=1").value).Count
$catchup = if ($CatchupDays -gt 0 -and ($fresh -or $PSBoundParameters.ContainsKey('CatchupDays'))) { [datetime]::UtcNow.Date.AddDays($CatchupDays).ToString('yyyy-MM-dd') } else { '' }
$rows = @(Import-Csv $ConfigPath)
$plan = foreach ($row in $rows) {
    $cur = @((Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/crdr_configs?`$select=crdr_configid,crdr_value,crdr_description&`$filter=crdr_key eq '$($row.key)'").value) | Select-Object -First 1
    $value = if ($install.ContainsKey($row.key)) { $install[$row.key] } elseif ($row.key -eq 'catchup_until') { $catchup } else { $row.value }
    $status = if (-not $cur) { 'create' } elseif ($install.ContainsKey($row.key) -and $cur.crdr_value -ne $value) { 'set' } elseif ($cur.crdr_description -ne $row.description) { 'describe' } else { 'exists' }
    [pscustomobject]@{ Key = $row.key; Status = $status; Value = $(if ($status -in 'create', 'set') { $value } else { $cur.crdr_value }); Id = $(if ($cur) { $cur.crdr_configid }); Description = $row.description }
}
Write-Host "`nPLAN ($ExpectedEnvironmentName): settings from $ConfigPath"
$plan | ForEach-Object { Write-Host ("  {0,-9} {1,-34} {2}" -f $_.Status, $_.Key, $(if ($_.Key -in 'alert_recipient', 'alert_destinations') { '(install value, not shown)' } else { "$($_.Value)".Substring(0, [Math]::Min(60, "$($_.Value)".Length)) })) }
$todo = @($plan | Where-Object Status -ne 'exists')
Write-Host "`n$($todo.Count) to change. Existing settings are never overwritten, except the install values given on the command line."
if (-not $Apply) { return }
foreach ($p in $todo) {
    $body = if ($p.Status -eq 'describe') { @{ crdr_description = $p.Description } } elseif ($p.Status -eq 'set') { @{ crdr_value = $p.Value } } else { @{ crdr_key = $p.Key; crdr_value = $p.Value; crdr_description = $p.Description } }
    $json = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json))
    if ($p.Status -eq 'create') { Invoke-RestMethod -Method POST -Uri "$dv/crdr_configs" -Headers (Get-Header) -ContentType 'application/json; charset=utf-8' -Body $json | Out-Null }
    else { Invoke-RestMethod -Method PATCH -Uri "$dv/crdr_configs($($p.Id))" -Headers ((Get-Header) + @{ 'If-Match' = '*' }) -ContentType 'application/json; charset=utf-8' -Body $json | Out-Null }
}
Write-Host 'Done.'
