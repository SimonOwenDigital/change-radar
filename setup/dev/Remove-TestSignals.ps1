#Requires -Version 7.0
<#
.SYNOPSIS
    Removes the test signals injected by New-TestSignals.ps1 and everything they caused (ADR 0011). Dev environment only; plans by default.
.DESCRIPTION
    Deletes, for signals whose external id starts TEST-: their alert log rows, their events (handler runs cascade with
    them), then the signals (versions, fingerprints, exposures and assessments cascade), and watch topics whose name
    starts [TEST] (ADR 0015). Only TEST- signals and [TEST] watches are touched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Invoke-Dv([string]$Path, [string]$Method = 'GET') {
    $h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' }
    Invoke-RestMethod -Method $Method -Uri "$dv/$Path" -Headers $h
}
$org = Invoke-Dv "RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$signals = @((Invoke-Dv "crdr_signals?`$select=crdr_signalid,crdr_externalid&`$filter=startswith(crdr_externalid,'TEST-')").value)
$alerts = @(); $events = @()
foreach ($s in $signals) {
    $alerts += @((Invoke-Dv "crdr_alertlogs?`$select=crdr_alertlogid&`$filter=_crdr_signal_value eq $($s.crdr_signalid)").value)
    $events += @((Invoke-Dv "crdr_events?`$select=crdr_eventid&`$filter=_crdr_signal_value eq $($s.crdr_signalid)").value)
}
$watchSet = (Invoke-Dv "EntityDefinitions(LogicalName='crdr_watch')?`$select=EntitySetName").EntitySetName
# Filtered here, not in OData: startswith becomes SQL LIKE, where [TEST] is a character class (observed 2026-11-23).
$watches = @(@((Invoke-Dv "${watchSet}?`$select=crdr_watchid,crdr_name").value) | Where-Object { $_.crdr_name.StartsWith('[TEST]') })
"PLAN ($ExpectedEnvironmentName): delete $($alerts.Count) alert log row(s), $($events.Count) event(s) (with their handler runs), $($signals.Count) signal(s): $((@($signals | ForEach-Object crdr_externalid)) -join ', '); $($watches.Count) test watch topic(s)"
if (-not $Apply) { 'Plan only. Nothing was changed. Re-run with -Apply.'; return }
foreach ($a in $alerts) { Invoke-Dv "crdr_alertlogs($($a.crdr_alertlogid))" 'DELETE' | Out-Null }
foreach ($e in $events) { Invoke-Dv "crdr_events($($e.crdr_eventid))" 'DELETE' | Out-Null }
foreach ($s in $signals) { Invoke-Dv "crdr_signals($($s.crdr_signalid))" 'DELETE' | Out-Null }
foreach ($w in $watches) { Invoke-Dv "$watchSet($($w.crdr_watchid))" 'DELETE' | Out-Null }
"Removed. Run the match and assess flows once more to settle exposure and assessment counts."
