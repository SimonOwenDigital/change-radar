#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the estate impact scoring cases (tests/assessment/scoring.json) against engine/ChangeRadar.Assessment.psm1.
.DESCRIPTION
    Each case's result per source must match 'expected' exactly (estate impact, affected count, unknown environment
    count, bonuses), and no extra source may appear. Exit code 0 when everything passes, 1 otherwise.
#>
[CmdletBinding()]
param([string]$CasesPath = (Join-Path $PSScriptRoot '..' 'tests' 'assessment' 'scoring.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Assessment.psm1') -Force

$spec = Get-Content -Raw $CasesPath | ConvertFrom-Json -Depth 20
$today = [datetime]::ParseExact($spec.today, 'yyyy-MM-dd', $null)
$fields = 'estateImpact', 'affectedCount', 'unknownEnvironmentCount', 'productionBonus', 'actionBonus'
$rows = foreach ($c in $spec.cases) {
    $actual = @(Get-EstateImpact -Signal $c.signal -Exposures @($c.exposures) -Today $today -EstateImpactMax $spec.estateImpactMax)
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($e in @($c.expected)) {
        $a = $actual | Where-Object source -eq $e.source
        if (-not $a) { $problems.Add("$($e.source): missing"); continue }
        foreach ($f in $fields) { if ("$($a.$f)" -ne "$($e.$f)") { $problems.Add("$($e.source).${f}: expected $($e.$f), got $($a.$f)") } }
    }
    foreach ($a in $actual | Where-Object { @($c.expected).source -notcontains $_.source }) { $problems.Add("$($a.source): unexpected result") }
    [pscustomobject]@{ Case = $c.id; Result = $(if ($problems.Count) { 'FAIL' } else { 'PASS' }); Got = (($actual | ForEach-Object { "$($_.source)=$($_.estateImpact)" }) -join ' '); Detail = ($problems -join '; '); Note = $c.note }
}
# Exposure summaries (the prompt's input): exact text.
$sumSpec = Get-Content -Raw (Join-Path (Split-Path $CasesPath) 'summary.json') | ConvertFrom-Json -Depth 20
$typeMap = @{}; (Get-Content -Raw (Join-Path $PSScriptRoot '..' 'seed' 'asset-signatures.json') | ConvertFrom-Json).resourceTypeByType.PSObject.Properties | ForEach-Object { $typeMap[$_.Name] = $_.Value }
$sumToday = [datetime]::ParseExact($sumSpec.today, 'yyyy-MM-dd', $null)
$rows = @($rows) + @(foreach ($c in $sumSpec.cases) {
        $text = Get-ExposureSummary -Source $c.source -Signal $c.signal -Exposures @($c.exposures) -Groups @($c.groups) -ResourceTypeMap $typeMap -Today $sumToday
        $ok = $text -ceq $c.expected
        $leak = @($c.exposures | ForEach-Object { $_.PSObject.Properties['assetName'] ? $_.assetName : $null; $_.PSObject.Properties['environmentName'] ? $_.environmentName : $null } | Where-Object { $_ -and $text.Contains($_) })
        [pscustomobject]@{ Case = $c.id; Result = $(if ($ok -and -not $leak) { 'PASS' } else { 'FAIL' }); Got = ''; Detail = $(if ($leak) { "name leaked: $($leak -join ', ')" } elseif (-not $ok) { "got:`n$text" }); Note = $c.note }
    })
$rows | Format-Table Case, Result, Got, Detail, Note -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$(@($rows).Count - $failed) passed, $failed failed, $(@($rows).Count) cases"
if ($failed) { exit 1 }
