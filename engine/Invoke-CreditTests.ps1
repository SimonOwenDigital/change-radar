#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the credit forecast cases (tests/credits/credits.json) against engine/ChangeRadar.Credits.psm1. Exit code 1 on any failure.
    Only the expected fields a case lists are checked.
#>
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot '..' 'tests' 'credits' 'credits.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Credits.psm1') -Force
$d = Get-Content -Raw $Path -Encoding utf8 | ConvertFrom-Json -Depth 10
$rows = foreach ($c in $d.cases) {
    $i = $c.input
    $got = Get-CreditForecast -Signals $i.signals -ToRate $i.toRate -ToAssess $i.toAssess -Exposed $i.exposed -Daily $i.daily -WindowShare $i.windowShare -ReassessShare $i.reassessShare -FingerprintCap $i.fingerprintCap -RatingCap $i.ratingCap -AssessmentCap $i.assessmentCap -CatchupCap $(if ($i.PSObject.Properties['catchupCap']) { $i.catchupCap } else { 0 }) -CatchupNights $(if ($i.PSObject.Properties['catchupNights']) { $i.catchupNights } else { 0 }) -AibPerCall $i.aibPerCall -CopilotPerCall $i.copilotPerCall
    $bad = foreach ($p in $c.expected.PSObject.Properties) {
        $g = $got.($p.Name)
        $same = if ($p.Value -is [array] -or $g -is [array]) { (@($g) -join ',') -eq (@($p.Value) -join ',') } else { "$g" -eq "$($p.Value)" }
        if (-not $same) { "$($p.Name): expected $(@($p.Value) -join ',') got $(@($g) -join ',')" }
    }
    [pscustomobject]@{ Case = $c.id; Result = $(if ($bad) { 'FAIL' } else { 'PASS' }); Detail = ($bad -join '; ') }
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$(@($rows).Count - $failed) passed, $failed failed, $(@($rows).Count) cases"
if ($failed) { exit 1 }
