#Requires -Version 7.0
<#
.SYNOPSIS
    Removes Change Radar's synthetic demo data from an environment, and switches demo_data off (ADR 0022).
.DESCRIPTION
    Plans by default: prints what it would delete, table by table. Nothing is deleted unless -Apply is given.

    Deletes only rows labelled source = synthetic, and the events that refer to them, in this order (lookups between
    Change Radar tables clear rather than cascade, so dependants go first):
      1. events whose exposure or assessment is synthetic (their handler runs are deleted with them)
      2. synthetic exposures
      3. synthetic assessments
      4. synthetic solution memberships, then synthetic solutions
      5. synthetic assets (their asset fingerprints are deleted with them)
    Then sets crdr_config demo_data to off. Live and fixture rows are never touched.

    Runs as the signed-in user (Connect-AzAccount), who needs write access to Change Radar's tables in the environment
    (for example the System Customizer role, or the Change Radar admin role when one is installed).
.EXAMPLE
    ./setup/Remove-DemoData.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<friendly name>'
    ./setup/Remove-DemoData.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<friendly name>' -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [int]$BatchSize = 500,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
$synthetic = 169890002
function Get-Token { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText }
function Get-All([string]$Path) {
    $h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' }
    $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Uri "$dv/$Path" -Headers $h
    while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Uri $r.'@odata.nextLink' -Headers $h }
    $rows.ToArray()
}
function Invoke-Delete([string]$EntitySet, [string[]]$Ids) {
    for ($i = 0; $i -lt $Ids.Count; $i += $BatchSize) {
        $chunk = $Ids[$i..([Math]::Min($i + $BatchSize, $Ids.Count) - 1)]
        $id = "batch_$([guid]::NewGuid())"; $sb = [Text.StringBuilder]::new()
        foreach ($rid in $chunk) { [void]$sb.Append("--$id`r`nContent-Type: application/http`r`nContent-Transfer-Encoding: binary`r`n`r`nDELETE $dv/$EntitySet($rid) HTTP/1.1`r`n`r`n") }
        [void]$sb.Append("--$id--`r`n")
        $h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'odata.continue-on-error' }
        $resp = Invoke-WebRequest -Method POST -Uri "$dv/`$batch" -Headers $h -ContentType "multipart/mixed; boundary=$id" -Body ([Text.Encoding]::UTF8.GetBytes($sb.ToString()))
        $text = [Text.Encoding]::UTF8.GetString($resp.Content)
        $bad = @([regex]::Matches($text, 'HTTP/1\.1 (4\d\d|5\d\d)[^\r\n]*') | ForEach-Object Value)
        if ($bad.Count) { throw "$EntitySet : $($bad.Count) delete(s) failed, first: $($bad[0]) $([regex]::Match($text, '"message":"([^"]+)"').Groups[1].Value)" }
    }
}

$org = Invoke-RestMethod -Headers @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json' } -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Nothing changed." }

$events = @(@(Get-All "crdr_events?`$select=crdr_eventid&`$filter=crdr_exposure/crdr_source eq $synthetic") + @(Get-All "crdr_events?`$select=crdr_eventid&`$filter=crdr_assessment/crdr_source eq $synthetic") | ForEach-Object crdr_eventid | Sort-Object -Unique)
$plan = [ordered]@{
    crdr_events          = $events
    crdr_exposures       = @(Get-All "crdr_exposures?`$select=crdr_exposureid&`$filter=crdr_source eq $synthetic" | ForEach-Object crdr_exposureid)
    crdr_assessments     = @(Get-All "crdr_assessments?`$select=crdr_assessmentid&`$filter=crdr_source eq $synthetic" | ForEach-Object crdr_assessmentid)
    crdr_solutionmembers = @(Get-All "crdr_solutionmembers?`$select=crdr_solutionmemberid&`$filter=crdr_source eq $synthetic" | ForEach-Object crdr_solutionmemberid)
    crdr_solutions       = @(Get-All "crdr_solutions?`$select=crdr_solutionid&`$filter=crdr_source eq $synthetic" | ForEach-Object crdr_solutionid)
    crdr_assets          = @(Get-All "crdr_assets?`$select=crdr_assetid&`$filter=crdr_source eq $synthetic" | ForEach-Object crdr_assetid)
}
$fpCount = @(Get-All "crdr_assetfingerprints?`$select=crdr_assetfingerprintid&`$filter=crdr_asset/crdr_source eq $synthetic").Count
$demoRow = @(Get-All "crdr_configs?`$select=crdr_configid,crdr_value&`$filter=crdr_key eq 'demo_data'")

Write-Host "`nPLAN ($ExpectedEnvironmentName): remove synthetic demo data"
foreach ($k in $plan.Keys) { Write-Host ("  {0,-22} {1,6} to delete" -f $k, $plan[$k].Count) }
Write-Host ("  {0,-22} {1,6} deleted with their assets" -f 'crdr_assetfingerprints', $fpCount)
Write-Host ("  {0,-22} demo_data = '{1}' -> 'off'" -f 'crdr_configs', $(if ($demoRow) { $demoRow[0].crdr_value } else { '(no row)' }))
if (-not $Apply) { Write-Host "`nPlan only. Nothing was changed. Re-run with -Apply to delete."; return }

foreach ($k in $plan.Keys) { if ($plan[$k].Count) { Write-Host "Deleting $k..."; Invoke-Delete $k $plan[$k] } }
$h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; 'OData-Version' = '4.0' }
if ($demoRow) { Invoke-RestMethod -Method PATCH -Uri "$dv/crdr_configs($($demoRow[0].crdr_configid))" -Headers ($h + @{ 'If-Match' = '*' }) -ContentType 'application/json' -Body '{"crdr_value":"off"}' | Out-Null }
else { Invoke-RestMethod -Method POST -Uri "$dv/crdr_configs" -Headers $h -ContentType 'application/json' -Body '{"crdr_key":"demo_data","crdr_value":"off"}' | Out-Null }
$left = @(Get-All "crdr_assets?`$select=crdr_assetid&`$filter=crdr_source eq $synthetic").Count
Write-Host "Done. Synthetic assets left: $left. demo_data is off."
