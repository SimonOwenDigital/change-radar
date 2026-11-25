#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the model cases (tests/models/models.json): model ids from the vocabulary, and the rule fingerprints of the
    lifecycle signals from the saved Learn pages (ADR 0013 step 3). Exit code 1 on any failure.
#>
[CmdletBinding()]
param(
    [string]$CasesPath = (Join-Path $PSScriptRoot '..' 'tests' 'models' 'models.json'),
    [string]$SeedDir = (Join-Path $PSScriptRoot '..' 'seed')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Matching.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Feeds.psm1') -Force
$spec = Get-Content -Raw $CasesPath -Encoding utf8 | ConvertFrom-Json -Depth 20 -DateKind String
$map = Import-ModelMap -SeedDir $SeedDir
$feeds = @{}; Import-Csv (Join-Path $SeedDir 'feeds.csv') -Encoding utf8 | ForEach-Object { $feeds[$_.key] = $_ }
$rows = [Collections.Generic.List[object]]::new()
foreach ($c in $spec.modelIds) { $got = Get-ModelId $map $c.text; $rows.Add([pscustomobject]@{ Case = $c.id; Result = $(if ("$got" -ceq "$($c.expected)") { 'PASS' } else { 'FAIL' }); Detail = "got '$got'" }) }
foreach ($c in $spec.promptModelTypes.cases) { $got = Get-PromptModelType $c.configuration; $rows.Add([pscustomobject]@{ Case = $c.id; Result = $(if ("$got" -ceq "$($c.expected)") { 'PASS' } else { 'FAIL' }); Detail = "got '$got'" }) }
foreach ($c in $spec.promptCalls.cases) {
    $got = (@(Get-PromptCalls $c.clientData) | ForEach-Object { "$($_.operation)|$($_.promptId)" }) -join ', '
    $want = @($c.expected) -join ', '
    $rows.Add([pscustomobject]@{ Case = $c.id; Result = $(if ($got -ceq $want) { 'PASS' } else { 'FAIL' }); Detail = "got [$got]" })
}
$lf = $spec.lifecycleFingerprints
$today = [datetime]::ParseExact($lf.today, 'yyyy-MM-dd', $null)
$casesDir = Split-Path $CasesPath
$runs = @{}
function Get-Run([string]$key, [string]$sample) {
    if (-not $runs.ContainsKey($key)) {
        $f = $feeds[$key]; $fp = Get-Content -Raw (Join-Path $SeedDir 'feed-profiles' $f.profile) -Encoding utf8 | ConvertFrom-Json -Depth 20
        $runs[$key] = Invoke-FeedAdapter -Content (Get-Content -Raw (Join-Path $casesDir $sample) -Encoding utf8) -Feed $f -FeedProfile $fp -Today $today -Config @{} -ModelMap $map
    }
    $runs[$key]
}
foreach ($c in $lf.cases) {
    $r = Get-Run $c.feed $c.sample
    $got = (@($r.fingerprints | Where-Object externalid -ceq $c.externalid) | ForEach-Object { "$(if ($_.group -ne 'A') { "$($_.group):" })$($_.facet)=$($_.value)" }) -join ', '
    $want = (@($c.expected) | ForEach-Object { "$(if ($_.PSObject.Properties['group'] -and $_.group -ne 'A') { "$($_.group):" })$($_.facet)=$($_.value)" }) -join ', '
    $rows.Add([pscustomobject]@{ Case = $c.id; Result = $(if ($got -ceq $want) { 'PASS' } else { 'FAIL' }); Detail = $got })
}
$samples = @{ 'ML-CS' = 'pages/authoring-select-agent-model.html'; 'ML-CSM' = 'pages/authoring-agent-model-availability.html'; 'ML-PR' = 'pages/prompt-model-availability.html' }
$gaps = @($lf.allMapped.feeds | ForEach-Object { (Get-Run $_ $samples[$_]).gaps } | Where-Object { $_ -like 'unmapped model*' })
$rows.Add([pscustomobject]@{ Case = 'lfp-all-mapped'; Result = $(if ($gaps.Count -eq $lf.allMapped.expectedGaps) { 'PASS' } else { 'FAIL' }); Detail = ($gaps -join '; ') })
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$($rows.Count - $failed) passed, $failed failed, $($rows.Count) cases"
if ($failed) { exit 1 }
