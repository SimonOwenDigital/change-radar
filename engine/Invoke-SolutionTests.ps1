#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the solution view cases (tests/solutions/solutions.json) against engine/ChangeRadar.Solutions.psm1 (ADR 0020).
    Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot '..' 'tests' 'solutions' 'solutions.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Solutions.psm1') -Force
$d = Get-Content -Raw $Path -Encoding utf8 | ConvertFrom-Json -Depth 20
$rows = [Collections.Generic.List[object]]::new()
function Add-Row($id, $ok, $got, $note) { $rows.Add([pscustomobject]@{ Case = $id; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Got = $got; Note = $note }) }
function Format-Rows($list, [string[]]$props) { (@($list) | ForEach-Object { $r = $_; ($props | ForEach-Object { "$($r.$_)" }) -join '/' }) -join '; ' }

foreach ($c in $d.objectIds) { $got = Get-SolutionObjectId $c.asset; Add-Row $c.id ("$got" -ceq "$($c.expected)") "$got" $c.note }
foreach ($c in $d.counted) { $got = Test-CountedSolution $c.solution; Add-Row $c.id ($got -eq $c.expected) "$got" $c.note }
$memProps = 'assetid', 'uniquename', 'displayname', 'publisher', 'managed', 'microsoft'
foreach ($c in $d.membership) {
    $got = Format-Rows (Get-SolutionMembership -Assets $c.assets -Components $c.components -MicrosoftPublishers $d.microsoftPublishers) $memProps
    $want = Format-Rows $c.expected $memProps
    Add-Row $c.id ($got -ceq $want) $got $c.note
}
foreach ($c in $d.groups) {
    $g = Get-SolutionGroups -Assets $c.assets -Membership $c.membership -DetailEnvironments $c.detailEnvironments
    $got = ($g.Keys | ForEach-Object { "$_=$($g[$_] -join ',')" }) -join '; '
    $want = ($c.expected.PSObject.Properties | ForEach-Object { "$($_.Name)=$(@($_.Value) -join ',')" }) -join '; '
    Add-Row $c.id ($got -ceq $want) $got $c.note
}
foreach ($c in $d.related) {
    $got = (@(Get-RelatedSignals -SolutionAssets $c.solutionAssets -AssetFingerprints $c.assetFingerprints -SignalFingerprints $c.signalFingerprints -Affects $c.affects -Facets $d.relatedFacets) | ForEach-Object { "$($_.signal)=$($_.links -join ',')" }) -join '; '
    $want = (@($c.expected) | ForEach-Object { "$($_.signal)=$($_.links -join ',')" }) -join '; '
    Add-Row $c.id ($got -ceq $want) $got $c.note
}
$sumProps = 'uniquename', 'assets', 'items', 'highest', 'nextDeadline', 'action'
foreach ($c in $d.summary) {
    $got = Format-Rows (Get-SolutionSummary -Solutions $c.solutions -Membership $c.membership -Exposures $c.exposures -Today ([datetime]$d.today)) $sumProps
    $want = Format-Rows $c.expected $sumProps
    Add-Row $c.id ($got -ceq $want) $got $c.note
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$($rows.Count - $failed) passed, $failed failed, $($rows.Count) cases"
if ($failed) { exit 1 }
