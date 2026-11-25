#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the configuration switch cases (tests/config/config.json) against engine/ChangeRadar.Config.psm1. Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot '..' 'tests' 'config' 'config.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Config.psm1') -Force
$d = Get-Content -Raw $Path -Encoding utf8 | ConvertFrom-Json -Depth 10
$rows = foreach ($c in $d.demoData) {
    $got = Test-DemoDataOn $c.value
    [pscustomobject]@{ Case = $c.id; Result = $(if ($got -eq $c.expected) { 'PASS' } else { 'FAIL' }); Got = $got; Value = "'$($c.value)'" }
}
$rows = @($rows) + @(foreach ($c in $d.assessmentStep) {
    $got = Get-AssessmentStep -NeedsPrompt $c.needsPrompt -Prompted $c.prompted -Max $c.max
    [pscustomobject]@{ Case = $c.id; Result = $(if ($got -eq $c.expected) { 'PASS' } else { 'FAIL' }); Got = $got; Value = "needs=$($c.needsPrompt) prompted=$($c.prompted) max=$($c.max)" }
}) + @(foreach ($c in $d.demoToggle) {
    $w = Get-DemoDataValue -On $c.on; $ok = $w -eq $c.writes -and (Test-DemoDataOn $w) -eq $c.on
    [pscustomobject]@{ Case = $c.id; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Got = $w; Value = "on=$($c.on)" }
}) + @(foreach ($c in $d.estateShown) {
    $g = Get-EstateShown -Value $c.value -Loaded $c.loaded
    [pscustomobject]@{ Case = $c.id; Result = $(if ($g -eq $c.expected) { 'PASS' } else { 'FAIL' }); Got = $g; Value = "'$($c.value)'" }
}) + @(foreach ($c in $d.effectiveCap) {
    $got = Get-EffectiveCap -Cap $c.cap -CatchupCap $c.catchupCap -Until $c.until -Today $c.today
    [pscustomobject]@{ Case = $c.id; Result = $(if ($got -eq $c.expected) { 'PASS' } else { 'FAIL' }); Got = $got; Value = "cap=$($c.cap) catchup=$($c.catchupCap) until='$($c.until)' today=$($c.today)" }
})
$rows += @(foreach ($c in $d.seedStep) {
    $got = Get-SeedStep -InSeed $c.inSeed -Exists $c.exists -Same $c.same -Active $c.active -Reset $c.reset
    [pscustomobject]@{ Case = $c.id; Result = $(if ($got -eq $c.expected) { 'PASS' } else { 'FAIL' }); Got = $got; Value = "inSeed=$($c.inSeed) exists=$($c.exists) same=$($c.same) active=$($c.active) reset=$($c.reset)" }
})
$rows | Format-Table -AutoSize | Out-String -Width 200
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$(@($rows).Count - $failed) passed, $failed failed, $(@($rows).Count) cases"
if ($failed) { exit 1 }
