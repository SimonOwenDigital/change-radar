#Requires -Version 7.0
<#
.SYNOPSIS
    Matches signals against an estate file and writes exposures with evidence.
.DESCRIPTION
    Signals come from any JSON file holding either a "signal" object (test case files) or a
    "signals" array. Output is a JSON file of results per signal plus a Markdown summary.
.EXAMPLE
    pwsh -File engine/Invoke-Matching.ps1 -EstatePath samples/synthetic/mid-size-enterprise/estate.json `
        -SignalPaths "tests/cases/[mr]*.json" -OutDir samples/synthetic/mid-size-enterprise/exposures
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$EstatePath,
    [Parameter(Mandatory)] [string[]]$SignalPaths,
    [Parameter(Mandatory)] [string]$OutDir,
    [int]$MaxEvidenceRowsInSummary = 5
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Matching.psm1') -Force

$ctx = Import-MatchingContext
$estate = Read-JsonFile $EstatePath
$assets = @(Get-AssetFingerprints -Estate $estate -Context $ctx)

$resolved = @($SignalPaths | ForEach-Object { Resolve-Path -Path $_ } | ForEach-Object Path)
$signals = foreach ($path in $resolved) {
    $doc = Read-JsonFile $path
    if ($doc.PSObject.Properties['signals']) { $doc.signals } elseif ($doc.PSObject.Properties['signal']) { $doc.signal }
}
$signals = @($signals | Sort-Object id -Unique)

$results = foreach ($s in $signals) { Find-Exposures -Signal $s -Assets $assets -Estate $estate -Context $ctx }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$payload = [ordered]@{
    estate = [ordered]@{ path = ($EstatePath -replace '\\', '/'); source = $estate.meta.source; syntheticOrg = $estate.meta.syntheticOrg; asOf = $estate.meta.asOf; assets = $assets.Count }
    results = @($results)
}
[IO.File]::WriteAllText((Join-Path $OutDir 'exposures.json'), (($payload | ConvertTo-Json -Depth 12) -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))

$badge = if ($estate.meta.source -ne 'live') { "> **Demo data:** $($estate.meta.source) estate for $($estate.meta.syntheticOrg). Not a real organisation." } else { '' }
$md = @('# Exposures', '', $badge, '', "Estate: ``$($EstatePath -replace '\\','/')`` ($($assets.Count) assets, as of $($estate.meta.asOf)).", '',
    '| Signal | Title | Exposures | Settings | Rejected facets | In review | Notes |', '|---|---|---|---|---|---|---|')
foreach ($r in $results) {
    $md += "| $($r.signalId) | $($r.title) | $(@($r.exposures).Count) | $((@($r.settingFindings) | ForEach-Object { "$($_.target)=$($_.state)" }) -join '; ') | $(@($r.rejected).Count) | $(@($r.review).Count) | $(($r.notes -join ' ') -replace '\|','/') |"
}
foreach ($r in $results) {
    $md += @('', "## $($r.signalId): $($r.title)", '')
    if (@($r.exposures).Count -eq 0) { $md += 'No exposures.'; continue }
    $byEnv = $r.exposures | Group-Object { if ($_.environmentType) { $_.environmentType } else { 'n/a' } } | ForEach-Object { "$($_.Name) $($_.Count)" }
    $md += "By environment type: $($byEnv -join ', ').", '', '| Asset | Type | Env type | Matched facets | Evidence |', '|---|---|---|---|---|'
    foreach ($e in ($r.exposures | Select-Object -First $MaxEvidenceRowsInSummary)) {
        $md += "| $($e.assetName) | $($e.assetType -replace '^microsoft\.', '') | $($e.environmentType) | $(@($e.matchedFacets) -join ', ') | $((@($e.evidence) | ForEach-Object { "$($_.rule): $($_.field)" }) -join '<br>') |"
    }
    if (@($r.exposures).Count -gt $MaxEvidenceRowsInSummary) { $md += '', "…and $(@($r.exposures).Count - $MaxEvidenceRowsInSummary) more in ``exposures.json``." }
}
[IO.File]::WriteAllText((Join-Path $OutDir 'README.md'), (($md -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
$results | ForEach-Object { "{0,-12} exposures={1,4}  rejected={2} review={3}" -f $_.signalId, @($_.exposures).Count, @($_.rejected).Count, @($_.review).Count } | Write-Host
