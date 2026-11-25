#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the readable-summary cases (tests/text/readable.json) against engine/ChangeRadar.Text.psm1. Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$CasesPath = (Join-Path $PSScriptRoot '..' 'tests' 'text' 'readable.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Text.psm1') -Force
$spec = Get-Content -Raw $CasesPath -Encoding utf8 | ConvertFrom-Json -Depth 10
$failed = 0
foreach ($c in $spec.cases) {
    $got = ConvertTo-ReadableText $c.html
    if ($got -cne $c.expected) { $failed++; "FAIL $($c.id): got '$($got.Replace("`n", '\n'))'" } else { "PASS $($c.id)" }
}
"$($spec.cases.Count - $failed) passed, $failed failed, $($spec.cases.Count) cases"
if ($failed) { exit 1 }
