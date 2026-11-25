#Requires -Version 7.0
<#
.SYNOPSIS
    Prints the radar home headline and tile counts the reference engine derives from live Dataverse data (ADR 0012). Read-only.
.DESCRIPTION
    Reads active signals and their live assessments (source = live, latest assessed on) and runs engine Get-RadarSummary
    for today (UTC). Compare the output with the Radar page's headline and tiles. With -Expected, compares and exits 1 on
    any difference: pass the page's numbers as 'incidents,action,high,retiring,future'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$Expected,
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Radar.psm1') -Force
function Get-Headers { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-Headers) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-Headers) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
$org = Invoke-RestMethod -Headers (Get-Headers) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Label([string]$choice, $value) { if ($null -eq $value) { return $null }; @($schema.choices.$choice)[[int]$value - $base] }
$liveSource = $base + [array]::IndexOf(@($schema.choices.assetsource), 'live')

$live = @{}
foreach ($a in @(Get-All "crdr_assessments?`$select=_crdr_signal_value,crdr_estateimpact,crdr_overrideimpact,crdr_assessedon&`$filter=crdr_source eq $liveSource")) {
    $k = "$($a._crdr_signal_value)".ToLower()
    if (-not $live.ContainsKey($k) -or [datetime]$a.crdr_assessedon -gt [datetime]$live[$k].crdr_assessedon) { $live[$k] = $a }
}
$signals = @(Get-All "crdr_signals?`$select=crdr_signalid,crdr_title,crdr_source,crdr_horizon,crdr_keydate,crdr_datelabel,crdr_actionrequired,crdr_genericimpact,crdr_nature&`$filter=statecode eq 0" | ForEach-Object {
        $l = $live["$($_.crdr_signalid)".ToLower()]
        [pscustomobject]@{ id = $_.crdr_signalid; title = $_.crdr_title; source = (Get-Label 'signalsource' $_.crdr_source); horizon = (Get-Label 'horizon' $_.crdr_horizon)
            keyDate = $_.crdr_keydate; dateLabel = $_.crdr_datelabel; actionRequired = [bool]$_.crdr_actionrequired
            genericImpact = (Get-Label 'impact' $_.crdr_genericimpact); nature = (Get-Label 'nature' $_.crdr_nature)
            live = if ($l) { [pscustomobject]@{ estateImpact = (Get-Label 'impact' $l.crdr_estateimpact); overrideImpact = (Get-Label 'impact' $l.crdr_overrideimpact) } } else { $null } }
    })
$s = Get-RadarSummary -Signals $signals -Today ([datetime]::UtcNow.Date)
"Signals: $($signals.Count) active; today $([datetime]::UtcNow.ToString('yyyy-MM-dd')) (UTC)"
"Tiles: Now $($s.incidentsActive), Action required $($s.actionRequired), High impact $($s.highImpact), Retiring $($s.retiring), Future $($s.futureRoadmap)"
"Headline: $($s.headline)"
if ($Expected) {
    $got = "$($s.incidentsActive),$($s.actionRequired),$($s.highImpact),$($s.retiring),$($s.futureRoadmap)"
    if ($got -ne $Expected) { "MISMATCH: engine $got, page $Expected"; exit 1 } else { 'Page tiles match the engine.' }
}
