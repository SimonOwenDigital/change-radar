#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the feed adapter cases (tests/feeds/cases.json) against engine/ChangeRadar.Feeds.psm1, using the feed rows in
    seed/feeds.csv and their profiles in seed/feed-profiles/. Exit code 1 on any failure.
#>
[CmdletBinding()]
param(
    [string]$CasesPath = (Join-Path $PSScriptRoot '..' 'tests' 'feeds' 'cases.json'),
    [string]$SeedDir = (Join-Path $PSScriptRoot '..' 'seed')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Feeds.psm1') -Force

$spec = Get-Content -Raw $CasesPath -Encoding utf8 | ConvertFrom-Json -Depth 30 -DateKind String
$feeds = @{}; Import-Csv (Join-Path $SeedDir 'feeds.csv') -Encoding utf8 | ForEach-Object { $feeds[$_.key] = $_ }
$today = [datetime]::ParseExact($spec.today, 'yyyy-MM-dd', $null)
$casesDir = Split-Path $CasesPath
$rows = [Collections.Generic.List[object]]::new()

foreach ($c in $spec.cases) {
    $feed = $feeds[$c.feed]
    $profile = Get-Content -Raw (Join-Path $SeedDir 'feed-profiles' $feed.profile) -Encoding utf8 | ConvertFrom-Json -Depth 20
    $content = Get-Content -Raw (Join-Path $casesDir $c.sample) -Encoding utf8
    $opts = @{}; $last = $null
    if ($c.PSObject.Properties['options']) { foreach ($p in $c.options.PSObject.Properties) { if ($p.Name -eq 'lastMarker') { $last = $p.Value } else { $opts[$p.Name] = $p.Value } } }
    $r = Invoke-FeedAdapter -Content $content -Feed $feed -FeedProfile $profile -Today $today -Config $spec.config -LastMarker $last -Options $opts
    $problems = [Collections.Generic.List[string]]::new()
    $x = $c.expect
    if ($r.signals.Count -ne $x.count) { $problems.Add("count $($r.signals.Count), expected $($x.count)") }
    if ((@($r.gaps) -join ' | ') -cne (@($x.gaps) -join ' | ')) { $problems.Add("gaps: $(@($r.gaps) -join ' | ')") }
    if ($x.PSObject.Properties['status'] -and $r.status -ne $x.status) { $problems.Add("status $($r.status)") }
    if ($x.PSObject.Properties['signals']) {
        foreach ($s in $x.signals.PSObject.Properties) {
            $got = @($r.signals | Where-Object externalid -ceq $s.Name) | Select-Object -First 1
            if (-not $got) { $problems.Add("missing $($s.Name)"); continue }
            foreach ($f in $s.Value.PSObject.Properties) {
                if ($f.Name -eq 'summaryStartsWith') { if (-not "$($got.summary)".StartsWith($f.Value)) { $problems.Add("$($s.Name) summary '$("$($got.summary)".Substring(0, [math]::Min(80, "$($got.summary)".Length)))'") }; continue }
                if ("$($got.($f.Name))" -cne "$($f.Value)") { $problems.Add("$($s.Name) $($f.Name) '$($got.($f.Name))'") }
            }
        }
    }
    if ($x.PSObject.Properties['absent']) { foreach ($a in $x.absent) { if (@($r.signals | Where-Object externalid -ceq $a).Count) { $problems.Add("unexpected $a") } } }
    $rows.Add([pscustomobject]@{ Case = $c.id; Result = $(if ($problems.Count) { 'FAIL' } else { 'PASS' }); Detail = ($problems -join '; '); Note = $c.note })
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$($rows.Count - $failed) passed, $failed failed, $($rows.Count) cases"
if ($failed) { exit 1 }
