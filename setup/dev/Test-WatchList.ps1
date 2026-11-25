#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the watch list in the dev environment against the engine (ADR 0015), and optionally backfills it.
.DESCRIPTION
    Reads the active watches and every signal, and asks the engine (ChangeRadar.Watch) which watch each unwatched,
    never-matched signal matches. The flow only checks a signal when it is collected or changes, so a new or edited
    topic doesn't reach older signals until they change. This script reports them:
      - should be watched: matches an active topic but isn't on the watch list;
      - topic no longer matches: watched because of a topic whose words no longer match it (information only);
      - opted out: matched once, then Watched was switched off (left alone).
    -Backfill puts the "should be watched" signals on the watch list (Watched, the watch link, Watched on) WITHOUT
    raising events or cards: events come only from signal version rows. Writes only Change Radar's own table.
    Exit code 1 when anything should be watched and -Backfill wasn't given.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [switch]$Backfill
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Watch.psm1') -Force
function Invoke-Dv([string]$Path, [string]$Method = 'GET', $Body) {
    $h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'odata.maxpagesize=5000' }
    $p = @{ Method = $Method; Uri = $(if ($Path -like 'http*') { $Path } else { "$dv/$Path" }); Headers = $h }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5)); $p.ContentType = 'application/json; charset=utf-8' }
    Invoke-RestMethod @p
}
function Get-All([string]$Path) { $out = @(); $r = Invoke-Dv $Path; $out += @($r.value); while ($r.PSObject.Properties['@odata.nextLink']) { $r = Invoke-Dv $r.'@odata.nextLink'; $out += @($r.value) }; , $out }
$org = Invoke-Dv "RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$set = (Invoke-Dv "EntityDefinitions(LogicalName='crdr_watch')?`$select=EntitySetName").EntitySetName

$watches = @((Get-All "${set}?`$select=crdr_watchid,crdr_name,crdr_anyof,crdr_alsooneof,crdr_ignorephrases,crdr_products,crdr_active") | ForEach-Object {
        [pscustomobject]@{ id = $_.crdr_watchid; name = $_.crdr_name; active = [bool]$_.crdr_active; anyOf = $_.crdr_anyof; alsoOneOf = $_.crdr_alsooneof; ignore = $_.crdr_ignorephrases; products = $_.crdr_products } })
$byId = @{}; foreach ($w in $watches) { $byId[$w.id] = $w }
$active = @($watches | Where-Object active)
$signals = Get-All 'crdr_signals?$select=crdr_signalid,crdr_externalid,crdr_title,crdr_summary,crdr_products,crdr_watched,_crdr_watch_value'
$should = [Collections.Generic.List[object]]::new(); $stale = [Collections.Generic.List[object]]::new(); $optedOut = 0; $watched = 0
foreach ($s in $signals) {
    $sig = [pscustomobject]@{ title = $s.crdr_title; summary = $s.crdr_summary; products = $s.crdr_products }
    $link = $s._crdr_watch_value
    if ($s.crdr_watched) {
        $watched++
        if ($link -and $byId.ContainsKey($link) -and -not (Test-WatchMatch -Watch $byId[$link] -Signal $sig)) { $stale.Add([pscustomobject]@{ Signal = $s.crdr_externalid; Watch = $byId[$link].name; Title = $s.crdr_title }) }
        continue
    }
    if ($link) { $optedOut++; continue }
    $ev = @(Get-WatchEvents -Watches $active -Signal $sig -Created $true -WasWatched $false)
    if ($ev.Count) { $w = $active | Where-Object name -ceq $ev[0].watch | Select-Object -First 1; $should.Add([pscustomobject]@{ Signal = $s.crdr_externalid; Watch = $w.name; WatchId = $w.id; Id = $s.crdr_signalid; Title = $s.crdr_title }) }
}
"Watches: $($watches.Count) ($($active.Count) active). Signals: $($signals.Count); watched $watched; opted out $optedOut."
if ($should.Count) { "Should be watched: $($should.Count)"; $should | Format-Table Signal, Watch, Title -AutoSize | Out-String -Width 200 } else { 'Should be watched: none.' }
if ($stale.Count) { "Watched, but the topic no longer matches (information): $($stale.Count)"; $stale | Format-Table -AutoSize | Out-String -Width 200 }
if (-not $should.Count) { return }
if (-not $Backfill) { 'Re-run with -Backfill to put them on the watch list (no events or cards).'; exit 1 }
foreach ($x in $should) {
    Invoke-Dv "crdr_signals($($x.Id))" 'PATCH' @{ crdr_watched = $true; 'crdr_watch@odata.bind' = "/$set($($x.WatchId))"; crdr_watchedon = [datetime]::UtcNow.ToString('o') } | Out-Null
}
"Backfilled: $($should.Count) signal(s) put on the watch list, without events."
