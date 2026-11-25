#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the watch list cases (tests/watch/watch.json) against engine/ChangeRadar.Watch.psm1. Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot '..' 'tests' 'watch' 'watch.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Watch.psm1') -Force
$d = Get-Content -Raw $Path -Encoding utf8 | ConvertFrom-Json -Depth 20
$rows = [Collections.Generic.List[object]]::new()
function Add-Row($id, $ok, $got, $note) { $rows.Add([pscustomobject]@{ Case = $id; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Got = $got; Note = $note }) }
foreach ($c in $d.match) {
    $got = Test-WatchMatch -Watch $d.watches.($c.watch) -Signal $c.signal
    Add-Row $c.id ($got -eq $c.expected) "$got" $c.note
}
foreach ($c in $d.events) {
    $ws = @($c.watches | ForEach-Object { $d.watches.$_ })
    $got = @(Get-WatchEvents -Watches $ws -Signal $c.signal -Created $c.created -WasWatched $c.wasWatched -OptedOut ([bool]($c.PSObject.Properties['optedOut'] -and $c.optedOut)) -ChangedFields $c.changedFields)
    $g = ($got | ForEach-Object { "$($_.type):$(if ($_.PSObject.Properties['watch']) { $_.watch } else { $_.changes })" }) -join ','
    $w = (@($c.expected) | ForEach-Object { "$($_.type):$(if ($_.PSObject.Properties['watch']) { $_.watch } else { $_.changes })" }) -join ','
    Add-Row $c.id ($g -ceq $w) $g $c.note
}
foreach ($c in $d.changes) { $got = Format-WatchChange $c.changedFields; Add-Row $c.id ($got -ceq $c.expected) $got $null }
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$($rows.Count - $failed) passed, $failed failed, $($rows.Count) cases"
if ($failed) { exit 1 }
