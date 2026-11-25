#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the generic feed collectors against the reference engine (ADR 0014). Read-only.
.DESCRIPTION
    For each active crdr_feed (or the keys given with -Feed): fetches the live page or feed, runs engine
    Invoke-FeedAdapter on it for today (UTC), reads the crdr_signal rows linked to that feed, and compares them by
    external id: the set of ids, and title, key date, horizon, action required, date label, products and URL per signal
    (summary: the flow keeps the same text for tables and sections; RSS summaries are stored as HTML and stripped on
    display, so only their start is compared). Also prints the feed's marker and its latest collection run.
    Exits 1 on any difference.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [switch]$FixSummaries,   # Learn table feeds: write the engine's summary where the stored one differs (after a profile change such as migrationNote); crdr_summary only
    [string[]]$Feed = @(),
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' '..' 'seed' 'config.csv')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Feeds.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Text.psm1') -Force
function Get-Headers { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; Prefer = 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-Headers) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-Headers) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
$org = Invoke-RestMethod -Headers (Get-Headers) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Label([string]$choice, $value) { if ($null -eq $value) { return $null }; @($schema.choices.$choice)[[int]$value - $base] }
$config = @{}; Import-Csv $ConfigPath | ForEach-Object { $config[$_.key] = $_.value }
foreach ($r in @(Get-All 'crdr_configs?$select=crdr_key,crdr_value')) { $config[$r.crdr_key] = $r.crdr_value }
$today = [datetime]::UtcNow.Date

$feeds = @(Get-All 'crdr_feeds?$select=crdr_feedid,crdr_key,crdr_name,crdr_kind,crdr_url,crdr_products,crdr_profile,crdr_active,crdr_lastmarker,crdr_lastcheckedon')
$feeds = @($feeds | Where-Object { if ($Feed.Count) { $Feed -contains $_.crdr_key } else { $_.crdr_active } })
$bad = 0
foreach ($f in $feeds) {
    $kind = Get-Label 'feedkind' $f.crdr_kind
    $feedRow = [pscustomobject]@{ key = $f.crdr_key; kind = $kind; url = $f.crdr_url; products = $f.crdr_products }
    # An RSS feed's CDN can serve an older cached copy; fetch again (up to 5 times) until the copy is at least as new as
    # the stored marker, as the collector only ever moves forward.
    for ($try = 1; $try -le 5; $try++) {
        # Accept headers as the collectors send them: news.microsoft.com blocks bare requests (spike T11).
        if ($kind -eq 'pdf_changelog') {
            # A guide is read with AI Builder text recognition, which costs credits; parity uses the recognition output saved in
            # tests/feeds/samples/licensing-guides/ (spike T12), valid while the guide's Last-Modified hasn't changed since.
            $sample = Join-Path $PSScriptRoot '..' '..' 'tests' 'feeds' 'samples' 'licensing-guides' "$($f.crdr_key).json"
            $content = Get-Content -Raw $sample -Encoding utf8
            "   (pdf_changelog: compared with the saved recognition output $(Split-Path $sample -Leaf); stored marker '$($f.crdr_lastmarker)')"
        } else {
        $content = (Invoke-WebRequest -Uri $f.crdr_url -UserAgent 'ChangeRadar/1.0 (parity check)' -Headers @{ Accept = 'text/html,application/xhtml+xml,application/rss+xml,application/xml'; 'Accept-Language' = 'en-GB,en;q=0.9' }).Content
        }
        $r = Invoke-FeedAdapter -Content $content -Feed $feedRow -FeedProfile ($f.crdr_profile | ConvertFrom-Json -Depth 20) -Today $today -Config $config
        if ($kind -ne 'rss' -or -not $f.crdr_lastmarker -or ([datetimeoffset]"$($r.marker)") -ge ([datetimeoffset]"$($f.crdr_lastmarker)")) { break }
    }
    if ($kind -eq 'rss' -and $f.crdr_lastmarker -and ([datetimeoffset]"$($r.marker)") -lt ([datetimeoffset]"$($f.crdr_lastmarker)")) { "== $($f.crdr_key): only stale copies of the feed in 5 tries (newest item $($r.marker), stored $($f.crdr_lastmarker)); not compared."; continue }
    $stored = @(Get-All "crdr_signals?`$select=crdr_signalid,crdr_externalid,crdr_title,crdr_summary,crdr_keydate,crdr_horizon,crdr_actionrequired,crdr_datelabel,crdr_products,crdr_url&`$filter=_crdr_feed_value eq $($f.crdr_feedid)")
    $run = @(Get-All "crdr_collectionruns?`$select=crdr_name,crdr_gaps,crdr_startedon&`$filter=crdr_collector eq 'feed:$($f.crdr_key)'&`$orderby=crdr_startedon desc&`$top=1") | Select-Object -First 1
    # A date-like marker (RSS newest item, Book of News dateModified) comes back from ConvertFrom-Json as a DateTime: compare as dates.
    "== $($f.crdr_key) ($kind): engine $($r.signals.Count), stored $($stored.Count); marker $(if ("$($f.crdr_lastmarker)" -eq "$($r.marker)" -or ($f.crdr_lastmarker -is [datetime] -and $r.marker -and ([datetimeoffset]$f.crdr_lastmarker).UtcDateTime -eq ([datetimeoffset]"$($r.marker)").UtcDateTime) -or ($kind -eq 'rss' -and $f.crdr_lastmarker -and ([datetimeoffset]"$($f.crdr_lastmarker)") -eq ([datetimeoffset]"$($r.marker)"))) { 'matches the live page' } else { "'$($f.crdr_lastmarker)' vs live '$($r.marker)'" })"
    if ($run) { "   last run: $($run.crdr_name)$(if ($run.crdr_gaps) { "; gaps: $($run.crdr_gaps)" })" }
    $problems = [Collections.Generic.List[string]]::new()
    $byId = @{}; foreach ($s in $stored) { $byId[$s.crdr_externalid] = $s }
    foreach ($e in $r.signals) {
        $s = $byId[$e.externalid]
        if (-not $s) { $problems.Add("missing $($e.externalid)"); continue }
        $checks = [ordered]@{
            title = @($e.title, $s.crdr_title); keydate = @("$($e.keydate)".Substring(0, 10), ([datetime]$s.crdr_keydate).ToString('yyyy-MM-dd'))
            horizon = @($e.horizon, (Get-Label 'horizon' $s.crdr_horizon)); actionrequired = @([bool]$e.actionrequired, [bool]$s.crdr_actionrequired)
            datelabel = @($e.datelabel, $s.crdr_datelabel); products = @($e.products, $s.crdr_products); url = @($e.url, $s.crdr_url) }
        if ($kind -eq 'rss') { $checks.summary = @($true, (ConvertTo-ReadableText "$($s.crdr_summary)").Contains(($e.summary -split ' ' | Select-Object -First 4) -join ' ')) }  # RSS: stored HTML read as people see it (entities decoded)
        else {
            $checks.summary = @($e.summary, $s.crdr_summary)
            if ($FixSummaries -and $kind -eq 'learnpage_tables' -and "$($e.summary)" -cne "$($s.crdr_summary)") {
                Invoke-RestMethod -Method Patch -Headers ((Get-Headers) + @{ 'If-Match' = '*' }) -Uri "$dv/crdr_signals($($s.crdr_signalid))" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes((@{ crdr_summary = $e.summary } | ConvertTo-Json))) | Out-Null
                "   fixed summary: $($s.crdr_externalid)"; $checks.summary = @($e.summary, $e.summary)
            }
        }
        foreach ($k in $checks.Keys) { if ("$($checks[$k][0])" -cne "$($checks[$k][1])") { $problems.Add("$($e.externalid) ${k}: engine '$($checks[$k][0])', stored '$($checks[$k][1])'") } }
    }
    # Signals are never deleted, so a stored signal the engine no longer produces is kept history, not a difference, when the
    # source has moved on: a change log row Microsoft removed or reworded (pdf_changelog keeps all, ADR 0019), an entry older
    # than the kind's window (learnpage_sections sinceDays, learnpage_tables retiredWithinDays; default 90), or an RSS item
    # older than the oldest item still in the feed.
    $prof = $f.crdr_profile | ConvertFrom-Json -Depth 20
    $window = switch ($kind) { 'learnpage_sections' { [int]($(if ($prof -and $prof.PSObject.Properties['sinceDays']) { $prof.sinceDays } else { 90 })) } 'learnpage_tables' { [int]($(if ($prof -and $prof.PSObject.Properties['retiredWithinDays']) { $prof.retiredWithinDays } else { 90 })) } default { $null } }
    $oldestItem = if ($kind -eq 'rss' -and $r.signals.Count) { (@($r.signals | ForEach-Object { [datetime]"$($_.keydate)" }) | Measure-Object -Minimum).Minimum } else { $null }
    $kept = 0
    foreach ($id in $byId.Keys) {
        if (@($r.signals | Where-Object externalid -ceq $id).Count) { continue }
        $kd = if ($byId[$id].crdr_keydate) { ([datetime]$byId[$id].crdr_keydate).Date } else { $null }
        if ($kind -eq 'pdf_changelog' -or ($window -and $kd -and ($today - $kd).TotalDays -gt $window) -or ($oldestItem -and $kd -and $kd -lt $oldestItem.Date)) { $kept++; continue }
        $problems.Add("stored but not produced by the engine today: $id")
    }
    if ($kept) { "   kept history: $kept stored signal(s) the source no longer lists (removed, reworded or older than the window)" }
    if ($r.gaps.Count) { "   engine gaps: $($r.gaps -join '; ')" }
    if ($problems.Count) { $bad += $problems.Count; $problems | ForEach-Object { "   DIFF $_" } } else { '   PARITY: every signal matches the engine.' }
}
if ($bad) { "MISMATCH: $bad difference(s)."; exit 1 }
