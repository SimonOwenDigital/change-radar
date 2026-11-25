#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the radar home cases (tests/radar/radar.json) against engine/ChangeRadar.Radar.psm1. Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$CasesPath = (Join-Path $PSScriptRoot '..' 'tests' 'radar' 'radar.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Radar.psm1') -Force
$t = Get-Content -Raw $CasesPath | ConvertFrom-Json -Depth 20
$today = [datetime]::ParseExact($t.today, 'yyyy-MM-dd', $null)
$rows = [Collections.Generic.List[object]]::new()
function Add-Row($id, $ok, $got, $note) { $rows.Add([pscustomobject]@{ Case = $id; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Got = "$got"; Note = $note }) }
function Note($c) { if ($c.PSObject.Properties['note']) { $c.note } }
foreach ($c in $t.buckets) { $g = Get-TimeBucket $c.keyDate $today; Add-Row $c.id ($g -eq $c.expected) $g (Note $c) }
foreach ($c in $t.impact) { $g = Get-ItemImpact $c.signal $c.live; Add-Row $c.id ($g.impact -eq $c.expected.impact -and $g.basis -eq $c.expected.basis) "$($g.impact)/$($g.basis)" (Note $c) }
foreach ($c in $t.timeline) { $g = Get-TimelineRow $c.signal $today; Add-Row $c.id ($g -eq $c.expected) $g (Note $c) }
$s = Get-RadarSummary @($t.summary.signals) $today; $e = $t.summary.expected
foreach ($f in 'incidentsActive', 'actionRequired', 'highImpact', 'retiring', 'futureRoadmap', 'headline') { Add-Row "summary-$f" ("$($s.$f)" -ceq "$($e.$f)") $s.$f '' }
Add-Row 'summary-next' ($s.nextDeadline.id -eq $e.nextDeadline.id -and $s.nextDeadline.keyDate -eq $e.nextDeadline.keyDate) "$($s.nextDeadline.id) $($s.nextDeadline.keyDate)" ''
foreach ($c in $t.patternWindow) { $g = Test-InPatternWindow $c.keyDate $today -ShowOlder:([bool]$c.showOlder); Add-Row $c.id ($g -eq $c.expected) $g (Note $c) }
foreach ($c in $t.headlines) { $g = Format-RadarHeadline $c.counts.actionRequired $c.counts.highImpact $c.next; Add-Row $c.id ($g -ceq $c.expected) $g '' }
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$($rows.Count - $failed) passed, $failed failed, $($rows.Count) cases"
if ($failed) { exit 1 }
