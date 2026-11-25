#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the matching test suite (tests/cases/*.json) and reports pass/fail per case.
.DESCRIPTION
    Each case file's estate fragment is merged onto tests/base-estate.json, fingerprinted and
    matched against the file's signal. A file also fails if the engine exposes an asset that no
    case mentions. Exit code 0 when everything passes, 1 otherwise.
.EXAMPLE
    pwsh -File engine/Invoke-MatchingTests.ps1 -ReportPath tests/results.md
#>
[CmdletBinding()]
param(
    [string]$TestsDir = (Join-Path $PSScriptRoot '..' 'tests'),
    [string]$ReportPath,
    [string]$SeedDir = (Join-Path $PSScriptRoot '..' 'seed')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Matching.psm1') -Force

$ctx = Import-MatchingContext -SeedDir $SeedDir
$base = Read-JsonFile (Join-Path $TestsDir 'base-estate.json')
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($file in (Get-ChildItem (Join-Path $TestsDir 'cases') -Filter *.json | Sort-Object Name)) {
    $t = Read-JsonFile $file.FullName
    $estate = Merge-Estate -Base $base -Fragment $t.estate
    $assets = @(Get-AssetFingerprints -Estate $estate -Context $ctx)
    $result = Find-Exposures -Signal $t.signal -Assets $assets -Estate $estate -Context $ctx
    $covered = @()

    foreach ($case in $t.cases) {
        $target = if ($case.PSObject.Properties['assetId']) { "asset:$($case.assetId)" } else { $case.target }
        $covered += $target
        $expectMatch = [bool]$case.expect.match
        $detail = ''
        switch -Regex ($target) {
            '^(asset|setting):' {
                $exp = @($result.exposures | Where-Object target -eq $target) | Select-Object -First 1
                $actualMatch = [bool]$exp
                $pass = ($actualMatch -eq $expectMatch)
                if ($pass -and $expectMatch -and $case.expect.PSObject.Properties['matchedFacets']) {
                    $want = (@($case.expect.matchedFacets) | Sort-Object) -join ','
                    $got = (@($exp.matchedFacets) | Sort-Object) -join ','
                    if ($want -ne $got) { $pass = $false; $detail = "facets expected [$want] got [$got]" }
                }
                if ($pass -and $expectMatch -and $case.expect.PSObject.Properties['status'] -and "$($exp.status)" -cne $case.expect.status) { $pass = $false; $detail = "status expected '$($case.expect.status)' got '$($exp.status)'" }
                if ($exp -and -not $detail) { $detail = "facets [$((@($exp.matchedFacets) | Sort-Object) -join ',')] via $(@($exp.rules) -join '+')" }
            }
            '^rejected:(.+)=(.+)$' {
                $actualMatch = [bool](@($result.rejected | Where-Object { $_.facet -eq $Matches[1] -and $_.value -eq $Matches[2] }).Count)
                $pass = ($actualMatch -eq $expectMatch)
            }
            '^review:(.+)=(.+)$' {
                $actualMatch = [bool](@($result.review | Where-Object { $_.facet -eq $Matches[1] -and $_.value -eq $Matches[2] }).Count)
                $pass = ($actualMatch -eq $expectMatch)
            }
            default { $actualMatch = $false; $pass = $false; $detail = "unknown target '$target'" }
        }
        $rows.Add([pscustomobject]@{ File = $t.id; Case = $case.id; Kind = $case.kind; Expected = $expectMatch; Actual = $actualMatch; Result = $(if ($pass) { 'PASS' } else { 'FAIL' }); Detail = $detail })
    }

    foreach ($exp in $result.exposures) {
        if ($covered -notcontains $exp.target) {
            $rows.Add([pscustomobject]@{ File = $t.id; Case = '(unexpected)'; Kind = 'unexpected'; Expected = $false; Actual = $true; Result = 'FAIL'; Detail = "exposure $($exp.target) has no case" })
        }
    }
}

$passed = @($rows | Where-Object Result -eq 'PASS').Count
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
$rows | Format-Table File, Case, Kind, Expected, Actual, Result, Detail -AutoSize | Out-String -Width 220 | Write-Host
Write-Host ("{0} passed, {1} failed, {2} cases" -f $passed, $failed, $rows.Count)

if ($ReportPath) {
    $md = @('# Matching test results', '', "Run with ``pwsh -File engine/Invoke-MatchingTests.ps1``. $passed passed, $failed failed, $($rows.Count) cases.", '',
        '| File | Case | Kind | Expected match | Actual match | Result | Detail |', '|---|---|---|---|---|---|---|') +
        ($rows | ForEach-Object { "| $($_.File) | $($_.Case) | $($_.Kind) | $($_.Expected) | $($_.Actual) | $($_.Result) | $($_.Detail) |" })
    [IO.File]::WriteAllText($ReportPath, (($md -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}
if ($failed -gt 0) { exit 1 } else { exit 0 }
