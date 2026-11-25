#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the rule-theme cases (tests/themes/rules.json) against engine/ChangeRadar.Assessment.psm1 with the rules in
    seed/theme-rules.csv and the themes in seed/themes.csv. Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$CasesPath = (Join-Path $PSScriptRoot '..' 'tests' 'themes' 'rules.json'),
    [string]$SeedDir = (Join-Path $PSScriptRoot '..' 'seed'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Assessment.psm1') -Force
$spec = Get-Content -Raw $CasesPath -Encoding utf8 | ConvertFrom-Json -Depth 10
$themes = @(Import-Csv (Join-Path $SeedDir 'themes.csv') | ForEach-Object theme)
$natures = @((Get-Content -Raw (Join-Path $PSScriptRoot '..' 'solutions' 'design' 'schema.json') | ConvertFrom-Json -Depth 50).choices.nature)
$rules = Import-ThemeRules -Rules @(Import-Csv (Join-Path $SeedDir 'theme-rules.csv')) -Themes $themes -Natures $natures
$failed = 0; $n = 0
foreach ($c in $spec.cases) {
    $n++; $got = Get-RuleTheme -Signal $c.signal -Rules $rules
    if ("$got" -cne "$($c.expected)") { $failed++; "FAIL $($c.id): expected '$($c.expected)', got '$got'" } else { "PASS $($c.id)" }
}
foreach ($c in $spec.natureCases) {
    $n++; $got = Get-RuleNature -Signal $c.signal -Rules $rules
    if ("$got" -cne "$($c.expected)") { $failed++; "FAIL $($c.id): expected '$($c.expected)', got '$got'" } else { "PASS $($c.id)" }
}
foreach ($c in $spec.natureErrors) {
    $n++; $err = $null
    try { $null = Import-ThemeRules -Rules @($c.rules) -Themes $themes -Natures $natures } catch { $err = "$_" }
    if ($err -and $err.Contains($c.expectError)) { "PASS $($c.id)" } else { $failed++; "FAIL $($c.id): expected an error naming '$($c.expectError)', got '$err'" }
}
foreach ($c in $spec.configErrors) {
    $n++; $err = $null
    try { $null = Import-ThemeRules -Rules @($c.rules) -Themes $themes } catch { $err = "$_" }
    if ($err -and $err.Contains($c.expectError)) { "PASS $($c.id)" } else { $failed++; "FAIL $($c.id): expected an error naming '$($c.expectError)', got '$err'" }
}
"$($n - $failed) passed, $failed failed, $n cases"
if ($failed) { exit 1 }
