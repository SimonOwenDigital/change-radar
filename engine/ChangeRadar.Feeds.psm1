#Requires -Version 7.0
<#
    Change Radar reference engine: generic feed adapters (ADR 0014; lifecycle pages per ADR 0013 and spike T9).
    Turns a fetched page or feed plus its profile into shaped signals, the same fields the collectors' Shape produces:
    externalid, title, summary, products, horizon, keydate, datelabel, actionrequired, url, lastchanged.
    Kinds: learnpage_tables (model lifecycle tables), learnpage_sections (dated release-note sections), rss.
    The flows mirror this module; tests/feeds/cases.json holds the expected results.
#>
Set-StrictMode -Version Latest

$script:Culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$script:Display = [Globalization.CultureInfo]::GetCultureInfo('en-GB')
$script:Entities = '&nbsp;', '&mdash;', '&ndash;', '&rsquo;', '&lsquo;', '&ldquo;', '&rdquo;', '&hellip;', '&copy;', '&reg;', '&trade;'

function Get-Prop($o, [string]$name, $default = $null) {
    if ($null -eq $o) { return $default }
    if ($o -is [hashtable]) { if ($o.ContainsKey($name)) { return $o[$name] } else { return $default } }
    $p = $o.PSObject.Properties[$name]; if ($p) { $p.Value } else { $default }
}
function ConvertTo-FeedSlug([string]$text) {
    (($text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}
function New-ExternalId([string]$key, [string]$slug) { ("$key-$slug").Substring(0, [math]::Min(100, "$key-$slug".Length)).TrimEnd('-') }
function Get-Text([string]$html) {
    # Block tags become a space; inline tags (links, emphasis) vanish without one, so 'Yes (<a>x</a>)' reads 'Yes (x)'.
    $t = [regex]::Replace($html, '</?(p|br|li|ul|ol|div|h[1-6]|tr|td|th|table|tbody|thead)\b[^>]*>', ' ')
    [Net.WebUtility]::HtmlDecode(([regex]::Replace($t, '<[^>]+>', '') -replace '\s+', ' ')).Trim()
}
function Get-Meta([string]$html, [string]$name) { [regex]::Match($html, "<meta name=""$name"" content=""([^""]*)""").Groups[1].Value }
function Format-Day([datetime]$d) { $d.ToString('d MMMM yyyy', $script:Display) }
function Clear-Html([string]$html) {
    # What the flow does before xml(): drop named HTML entities XML doesn't know and close <br>.
    foreach ($e in $script:Entities) { $html = $html.Replace($e, ' ') }
    $html.Replace('<br>', '<br/>')
}
function ConvertTo-LifecycleDate([string]$text) {
    $t = "$text".Trim(); $month = $false
    if ($t -and -not $t.Contains(',')) { $parts = $t -split ' '; if ($parts.Count -eq 2) { $t = "$($parts[0]) 1, $($parts[1])"; $month = $true } }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, 'MMMM d, yyyy', $script:Culture, 'None', [ref]$d)) { return @{ date = $d; month = [bool]$month } }
    $null
}
function Get-HorizonForDate([datetime]$date, [datetime]$today, $config) {
    $days = ($date - $today).TotalDays
    if ($days -le [int](Get-Prop $config 'horizon_now_days' 14)) { 'now' } elseif ($days -le [int](Get-Prop $config 'horizon_imminent_days' 90)) { 'imminent' } else { 'future' }
}

function Get-LifecycleSignals {
    <# Model lifecycle tables (spike T9 profiles): one signal per model row. #>
    param([string]$Html, $Feed, $FeedProfile, [datetime]$Today, $Config, [string]$LastMarker, $Options = @{}, [hashtable]$ModelMap)
    $commit = Get-Meta $Html 'git_commit_id'; $updated = Get-Meta $Html 'updated_at'
    $out = [ordered]@{ status = 'read'; marker = $commit; signals = [Collections.Generic.List[object]]::new(); gaps = [Collections.Generic.List[string]]::new(); fingerprints = [Collections.Generic.List[object]]::new() }
    if ($LastMarker -and $commit -eq $LastMarker) { $out.status = 'unchanged'; return [pscustomobject]$out }
    $retiredWithin = [int](Get-Prop $Options 'retiredWithinDays' (Get-Prop $FeedProfile 'retiredWithinDays' 90))
    $tables = [regex]::Matches($Html, '(?s)<table\b.*?</table>')
    $seen = @{}
    foreach ($tp in @(Get-Prop $FeedProfile 'tables')) {
        $match = $null
        foreach ($t in $tables) {
            $heads = @([regex]::Matches($t.Value, '(?s)<th\b[^>]*>(.*?)</th>') | ForEach-Object { Get-Text $_.Groups[1].Value })
            if (@($tp.requires | Where-Object { $heads -notcontains $_ }).Count -eq 0) { $match = @{ t = $t; heads = $heads }; break }
        }
        if (-not $match) { $out.gaps.Add("page shape changed: no table with headers '$(@($tp.requires) -join "', '")'"); continue }
        $col = @{}
        foreach ($p in $tp.columns.PSObject.Properties) {
            $i = [array]::IndexOf($match.heads, $p.Value)
            if ($i -lt 0) { $i = [array]::FindIndex([string[]]$match.heads, [Predicate[string]] { param($h) $h.StartsWith($p.Value) }) }
            if ($i -ge 0) { $col[$p.Name] = $i }
        }
        $headingDate = $null
        if ((Get-Prop $tp 'dateFrom') -eq 'heading') {
            # The flow reads the text after the profile's headingPrefix up to ')'; without a prefix, the nearest heading.
            $prefix = Get-Prop $tp 'headingPrefix'
            $ht = if ($prefix -and $Html.Contains($prefix)) { ($Html.Substring($Html.IndexOf($prefix) + $prefix.Length) -split '\)')[0] }
                  else { $h = [regex]::Matches($Html.Substring(0, $match.t.Index), '(?s)<h[23]\b[^>]*>(.*?)</h[23]>') | Select-Object -Last 1; if ($h) { Get-Text $h.Groups[1].Value } else { '' } }
            $dm = [regex]::Match($ht, '[A-Z][a-z]+ \d{1,2}, \d{4}')
            if ($dm.Success) { $headingDate = ConvertTo-LifecycleDate $dm.Value } else { $out.gaps.Add('no date in the heading before the table'); continue }
        }
        foreach ($tr in [regex]::Matches($match.t.Value, '(?s)<tr\b[^>]*>(.*?)</tr>')) {
            $cells = @([regex]::Matches($tr.Groups[1].Value, '(?s)<td\b[^>]*>(.*?)</td>') | ForEach-Object { Get-Text $_.Groups[1].Value })
            if ($cells.Count -eq 0) { continue }
            $get = { param($n) if ($col.ContainsKey($n) -and $col[$n] -lt $cells.Count) { $cells[$col[$n]] } else { $null } }
            $date = if ($headingDate) { $headingDate } else { ConvertTo-LifecycleDate (& $get 'date') }
            if (-not $date) { $out.gaps.Add("unreadable date '$(& $get 'date')' for '$(& $get 'model')'"); continue }
            $label = if ($col.ContainsKey('status')) { & $get 'status' } else { $tp.status }
            $retired = $label -match '^Retired' -or $date.date -lt $Today
            if ($retired -and ($Today - $date.date).TotalDays -gt $retiredWithin) { continue }
            $modelCell = & $get 'model'
            $models = if (Get-Prop $tp 'split') { $modelCell -split [regex]::Escape($tp.split) } else { @($modelCell) }
            foreach ($m in $models) {
                $m = $m.Trim(); if (-not $m) { continue }
                $model = $m; $qualifier = $null
                if ($m -match '^(?<m>.+?)\s*\((?<q>[^)]*)\)\s*$') { $model = $Matches.m.Trim(); $qualifier = $Matches.q.Trim() }
                $id = New-ExternalId $Feed.key (ConvertTo-FeedSlug ($model + $(if ($qualifier) { " $qualifier" })))
                if ($seen.ContainsKey($id)) { continue }; $seen[$id] = $true
                $replacement = & $get 'replacement'
                $when = if ($date.month) { 'in ' + $date.date.ToString('MMMM yyyy', $script:Display) } else { 'on ' + (Format-Day $date.date) }
                $parts = @("Replacement: $replacement")
                foreach ($f in @(@('harness', 'Harness'), @('tier', 'Tier'), @('extension', 'Extension available'), @('provider', 'Provider'))) { $v = & $get $f[0]; if ($v) { $parts += "$($f[1]): $v" } }
                # Rule fingerprint (ADR 0013): the model id plus the profile's scope facets; an unknown model is a gap.
                if ($ModelMap) {
                    $k = $model.Trim().ToLowerInvariant()
                    if ($ModelMap.ContainsKey($k)) {
                        $out.fingerprints.Add([pscustomobject][ordered]@{ externalid = $id; group = 'A'; facet = 'model'; value = $ModelMap[$k] })
                        $scope = Get-Prop $FeedProfile 'fingerprintScope'
                        foreach ($fct in 'resource_type', 'harness') { foreach ($v in @(Get-Prop $scope $fct)) { if ($v) { $out.fingerprints.Add([pscustomobject][ordered]@{ externalid = $id; group = 'A'; facet = $fct; value = $v }) } } }
                        # ADR 0017: callerScope adds group B, the model plus those facets (capability ai_prompt for prompts),
                        # so the flows that call a prompt on the model are exposed as well as the prompt.
                        $callers = Get-Prop $FeedProfile 'callerScope'
                        if ($callers) {
                            $out.fingerprints.Add([pscustomobject][ordered]@{ externalid = $id; group = 'B'; facet = 'model'; value = $ModelMap[$k] })
                            foreach ($fct in 'capability', 'resource_type') { foreach ($v in @(Get-Prop $callers $fct)) { if ($v) { $out.fingerprints.Add([pscustomobject][ordered]@{ externalid = $id; group = 'B'; facet = $fct; value = $v }) } } }
                        }
                    }
                    else { $out.gaps.Add("unmapped model '$model'") }
                }
                $out.signals.Add([pscustomobject][ordered]@{
                        externalid = $id
                        title = "$m $(if ($retired) { 'retired' } else { 'retires' }) from $($FeedProfile.surface) $when"
                        # ADR 0013 step 5: a retiring row ends with what Microsoft does (the profile's migrationNote), so the rating prompt knows.
                        summary = (($parts -join '. ') + '.' + $(if (-not $retired -and (Get-Prop $FeedProfile 'migrationNote')) { ' ' + (Get-Prop $FeedProfile 'migrationNote') } else { '' }))
                        products = $Feed.products
                        horizon = if ($retired) { 'future' } else { Get-HorizonForDate $date.date $Today $Config }
                        keydate = $date.date.ToString('yyyy-MM-dd')
                        datelabel = $(if ($retired) { "Retired · replaced by $replacement" } else { "Retiring · replacement $replacement" }).Substring(0, [math]::Min(100, $(if ($retired) { "Retired · replaced by $replacement" } else { "Retiring · replacement $replacement" }).Length))
                        actionrequired = -not $retired
                        url = $Feed.url
                        lastchanged = $updated })
            }
        }
    }
    [pscustomobject]$out
}

function Get-ReleaseNoteSignals {
    <# Dated release-note sections: h2 = date, h3 = area, each top-level list item = one signal, kept when its area is in scope or its title has a keyword. #>
    param([string]$Html, $Feed, $FeedProfile, [datetime]$Today, [string]$LastMarker, $Options = @{})
    $commit = Get-Meta $Html 'git_commit_id'
    $out = [ordered]@{ status = 'read'; marker = $commit; signals = [Collections.Generic.List[object]]::new(); gaps = [Collections.Generic.List[string]]::new() }
    if ($LastMarker -and $commit -eq $LastMarker) { $out.status = 'unchanged'; return [pscustomobject]$out }
    $since = [int](Get-Prop $Options 'sinceDays' (Get-Prop $FeedProfile 'sinceDays' 90))
    $areas = @(Get-Prop $FeedProfile 'areas'); $keywords = @(Get-Prop $FeedProfile 'titleKeywords')
    $areaProducts = Get-Prop $FeedProfile 'areaProducts'
    $clean = Clear-Html $Html
    $seen = @{}
    foreach ($chunk in ($clean -split '<h2 id="' | Select-Object -Skip 1)) {
        $sid = $chunk.Substring(0, $chunk.IndexOf('"'))
        $dm = [regex]::Match($sid, '^([a-z]+)-(\d{1,2})-(\d{4})$'); if (-not $dm.Success) { continue }
        $date = ConvertTo-LifecycleDate ("{0} {1}, {2}" -f ($script:Culture.TextInfo.ToTitleCase($dm.Groups[1].Value)), $dm.Groups[2].Value, $dm.Groups[3].Value)
        if (-not $date -or ($Today - $date.date).TotalDays -gt $since) { continue }
        $end = $chunk.LastIndexOf('</ul>'); if ($end -lt 0) { continue }
        try { $x = [xml]('<div><h2 id="' + $chunk.Substring(0, $end + 5) + '</div>') } catch { $out.gaps.Add("section $sid could not be read"); continue }
        $area = ''
        foreach ($n in $x.div.ChildNodes) {
            if ($n.Name -eq 'h3') { $area = $n.InnerText.Trim(); continue }
            if ($n.Name -ne 'ul') { continue }
            foreach ($li in $n.SelectNodes('li')) {
                $strong = $li.SelectSingleNode('p[1]/node()[1][self::strong]'); if (-not $strong) { continue }
                $title = ($strong.InnerText -replace '\s+', ' ').Trim()
                $inScope = $areas -contains $area -or @($keywords | Where-Object { $title.ToLowerInvariant().Contains($_) }).Count -gt 0
                if (-not $inScope) { continue }
                $id = New-ExternalId $Feed.key ($date.date.ToString('yyyyMMdd') + '-' + (ConvertTo-FeedSlug $title))
                if ($seen.ContainsKey($id)) { continue }; $seen[$id] = $true
                $products = if ($areaProducts -and (Get-Prop $areaProducts $area)) { Get-Prop $areaProducts $area } else { $Feed.products }
                $summary = ($li.InnerText -replace '\s+', ' ').Trim()
                $out.signals.Add([pscustomobject][ordered]@{
                        externalid = $id; title = $title; summary = $summary.Substring(0, [math]::Min(20000, $summary.Length)); products = $products
                        horizon = 'future'; keydate = $date.date.ToString('yyyy-MM-dd'); datelabel = "Released · $area".Substring(0, [math]::Min(100, "Released · $area".Length))
                        actionrequired = $false; url = "$($Feed.url)#$sid"; lastchanged = $date.date.ToString('yyyy-MM-dd') })
            }
        }
    }
    [pscustomobject]$out
}

function Get-RssSignals {
    <# RSS 2.0 items: informational signals dated by publication. #>
    param([string]$Xml, $Feed, $FeedProfile)
    $out = [ordered]@{ status = 'read'; marker = $null; signals = [Collections.Generic.List[object]]::new(); gaps = [Collections.Generic.List[string]]::new() }
    try { $doc = [xml]$Xml } catch { $out.gaps.Add('feed is not valid XML'); return [pscustomobject]$out }
    $label = Get-Prop $FeedProfile 'label' 'Feed'
    foreach ($item in @($doc.rss.channel.item)) {
        $link = "$($item.link)".Trim()
        $slug = ConvertTo-FeedSlug (($link.TrimEnd('/') -split '/')[-1])
        $pub = [datetimeoffset]::Parse("$($item.pubDate)", $script:Culture).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $desc = $item.description; $descText = if ($desc -is [Xml.XmlElement]) { $desc.InnerText } else { "$desc" }
        $summary = Get-Text $descText
        $out.signals.Add([pscustomobject][ordered]@{
                externalid = New-ExternalId $Feed.key $slug; title = "$($item.title)".Trim(); summary = $summary.Substring(0, [math]::Min(20000, $summary.Length))
                products = $Feed.products; horizon = 'future'; keydate = $pub; datelabel = "$label · published"; actionrequired = $false; url = $link; lastchanged = $pub })
    }
    if ($out.signals.Count) { $out.marker = ($out.signals | ForEach-Object lastchanged | Sort-Object -Descending | Select-Object -First 1) }
    [pscustomobject]$out
}

function Remove-Blocks([string]$html, [string]$tag) {
    # Drops every <tag ...>...</tag> block (script, style, svg) by plain splitting, as the flow does: each part after the
    # first '<tag' keeps only what follows its '</tag>' (nothing when there is none).
    $parts = $html -split [regex]::Escape("<$tag")
    if ($parts.Count -eq 1) { return $html }
    $sb = [Text.StringBuilder]::new($parts[0])
    foreach ($p in $parts[1..($parts.Count - 1)]) { $i = $p.IndexOf("</$tag>"); if ($i -ge 0) { [void]$sb.Append($p.Substring($i + "</$tag>".Length)) } }
    $sb.ToString()
}
function Get-WebSectionSignals {
    <# Web page sections (ADR 0018, ADR 0019, spike T11): one signal per heading section of a page, for the Book of News
       and for undated Learn pages. The page is cut to profile.contentStart..contentEnd, script/style/svg blocks are dropped,
       and it is split at <h2, <h3 and <h4. A section's summary is its raw HTML up to the next heading (the Readable summary
       flow makes the text), so a change to it is a change to the section. Plain string operations only, so the flow can
       mirror it exactly. #>
    param([string]$Html, $Feed, $FeedProfile, [string]$LastMarker)
    $markerKind = Get-Prop $FeedProfile 'marker' 'git_commit_id'
    $marker = if ($markerKind -eq 'dateModified') { $m = [regex]::Match($Html, '"dateModified":"([^"]+)"'); $m.Groups[1].Value } else { Get-Meta $Html 'git_commit_id' }
    $out = [ordered]@{ status = 'read'; marker = $marker; signals = [Collections.Generic.List[object]]::new(); gaps = [Collections.Generic.List[string]]::new() }
    if ($LastMarker -and $marker -eq $LastMarker) { $out.status = 'unchanged'; return [pscustomobject]$out }
    $start = Get-Prop $FeedProfile 'contentStart' '<main'; $endTag = Get-Prop $FeedProfile 'contentEnd' '</main>'
    $i = $Html.IndexOf($start); $j = if ($i -ge 0) { $Html.IndexOf($endTag, $i) } else { -1 }
    if ($i -lt 0 -or $j -lt 0) { $out.gaps.Add('content markers not found'); return [pscustomobject]$out }
    $content = $Html.Substring($i, $j - $i)
    foreach ($t in 'script', 'style', 'svg') { $content = Remove-Blocks $content $t }
    $sep = [string][char]0x241E
    foreach ($l in 2, 3, 4) { $content = $content.Replace("<h$l", "$sep$l") }
    $chunks = @($content.Split($sep) | Select-Object -Skip 1)
    # Each chunk: level digit, attributes up to '>', the heading's inner HTML up to '</hN>', then the body.
    $secs = foreach ($c in $chunks) {
        $level = [int][string]$c[0]; $rest = $c.Substring(1)
        $gt = $rest.IndexOf('>'); $attrs = if ($gt -ge 0) { $rest.Substring(0, $gt) } else { $rest }
        $after = if ($gt -ge 0) { $rest.Substring($gt + 1) } else { '' }
        $close = "</h$level>"; $ci = $after.IndexOf($close)
        $inner = if ($ci -ge 0) { $after.Substring(0, $ci) } else { $after }
        $body = if ($ci -ge 0) { $after.Substring($ci + $close.Length) } else { '' }
        $x = [xml]('<t>' + (Clear-Html $inner) + '</t>')
        $title = ($x.DocumentElement.InnerText -replace '[ \t\r\n]+', ' ').Trim()
        $id = if ($attrs.Contains('id="')) { $attrs.Substring($attrs.IndexOf('id="') + 4).Split('"')[0] } else { '' }
        [pscustomobject]@{ level = $level; title = $title; id = $id; body = $body.Trim() }
    }
    $secs = @($secs)
    $skip = @(Get-Prop $FeedProfile 'skipTitles' @() | ForEach-Object { $_.ToLowerInvariant() })
    $unit = Get-Prop $FeedProfile 'unit' 'all'; $minChars = [int](Get-Prop $FeedProfile 'minChars' 1)
    $head = @(Get-Prop $FeedProfile 'scopeHead' @()); $bodyWords = @(Get-Prop $FeedProfile 'scopeBody' @())
    $idFrom = Get-Prop $FeedProfile 'idFrom' 'title'; $prefix = Get-Prop $FeedProfile 'titlePrefix' ''
    $label = Get-Prop $FeedProfile 'label' 'Web page'
    $keydate = Get-Prop $FeedProfile 'keydate' ''
    if (-not $keydate) { $u = Get-Meta $Html 'updated_at'; $keydate = if ($u) { ([datetime]::Parse($u, $script:Culture, 'AdjustToUniversal')).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' } }
    $t2 = ''; $t3 = ''; $seen = @{}
    for ($k = 0; $k -lt $secs.Count; $k++) {
        $s = $secs[$k]
        if ($s.level -eq 2) { $t2 = $s.title; $t3 = '' } elseif ($s.level -eq 3) { $t3 = $s.title }
        $path = switch ($s.level) { 2 { $s.title } 3 { "$t2 > $($s.title)" } default { "$t2 > $t3 > $($s.title)" } }
        $leaf = ($k + 1 -ge $secs.Count) -or ($secs[$k + 1].level -le $s.level)
        if (-not $s.title -or $skip -contains $s.title.ToLowerInvariant()) { continue }
        if ($unit -eq 'leaf' -and -not $leaf) { continue }
        if ($s.body.Length -lt $minChars) { continue }
        if ($head.Count -or $bodyWords.Count) {
            $lp = $path.ToLowerInvariant(); $lb = $s.body.ToLowerInvariant()
            $hit = @($head | Where-Object { $lp.Contains($_) }).Count -or @($bodyWords | Where-Object { $lb.Contains($_) }).Count
            if (-not $hit) { continue }
        }
        $ext = New-ExternalId $Feed.key (ConvertTo-FeedSlug $(if ($idFrom -eq 'path') { $path } else { $s.title }))
        if ($seen.ContainsKey($ext)) { continue }; $seen[$ext] = $true
        $title = if ($prefix) { "${prefix}: $($s.title)" } else { $s.title }
        $out.signals.Add([pscustomobject][ordered]@{
                externalid = $ext; title = $title.Substring(0, [math]::Min(400, $title.Length)); summary = $s.body.Substring(0, [math]::Min(20000, $s.body.Length))
                products = $Feed.products; horizon = 'future'; keydate = $keydate; datelabel = $label.Substring(0, [math]::Min(100, $label.Length)); actionrequired = $false
                url = $(if ($s.id) { "$($Feed.url)#$($s.id)" } else { $Feed.url }); lastchanged = $keydate })
    }
    [pscustomobject]$out
}

$script:Months = 'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'
function Test-MonthYear([string]$t) { $p = @($t.Trim().ToLowerInvariant() -split ' '); $p.Count -eq 2 -and $script:Months -contains $p[0] -and $p[1].Length -eq 4 -and $p[1] -match '^\d{4}$' }
function Get-PdfChangeLogSignals {
    <# Licensing guide change logs (ADR 0019, spike T12): AI Builder text recognition output (predictionOutput: results[] per
       page with fullPageText and lines with bounding boxes) to one signal per change log row. The change log starts on the
       last page whose text says 'change log' without dot leaders (the contents page has them). Columns come from the
       header positions (Page, Change, Action, Date; 'Page(s) Topic' can be one line); the third column holds New, Update
       or Remove and the fourth the description. Rows: profile.rowAlign 'top' (cells top-aligned with the date) or 'middle'
       (the date centred in its row). Lines keep their OCR order (the flow can't sort), and a page without headers uses the
       previous page's columns. #>
    param([string]$Json, $Feed, $FeedProfile)
    $out = [ordered]@{ status = 'read'; marker = $null; signals = [Collections.Generic.List[object]]::new(); gaps = [Collections.Generic.List[string]]::new() }
    $po = $Json | ConvertFrom-Json -Depth 30
    $pages = @($po.results)
    $cl = @($pages | Where-Object { $t = "$($_.fullPageText)".ToLowerInvariant(); $t.Contains('change log') -and -not $t.Contains('.....') })
    if (-not $cl.Count) { $out.gaps.Add('change log not found'); return [pscustomobject]$out }
    $start = ($cl | ForEach-Object page | Measure-Object -Maximum).Maximum
    $guide = Get-Prop $FeedProfile 'guideName' $Feed.key; $label = Get-Prop $FeedProfile 'label' 'Licensing guide'
    $eps = 0.004; $bounds = $null; $seen = @{}
    foreach ($p in @($pages | Where-Object { $_.page -ge $start })) {
        $lines = @($p.lines | ForEach-Object { [pscustomobject]@{ t = "$($_.text)".Trim(); top = [double]$_.boundingBox.top; left = [double]$_.boundingBox.left; mid = [double]$_.boundingBox.top + [double]$_.boundingBox.height / 2 } })
        # Date cells: lines that are exactly '<Month> <year>' (text recognition keeps a date on one line, spike T12).
        $dates = [Collections.Generic.List[object]]::new(); $used = @{}
        for ($i = 0; $i -lt $lines.Count; $i++) { $l = $lines[$i]; if (Test-MonthYear $l.t) { $dates.Add([pscustomobject]@{ i = $i; t = $l.t; top = $l.top; left = $l.left }) } }
        $firstTop = if ($dates.Count) { $dates[0].top } else { 2 }
        $above = @($lines | Where-Object { $_.top -lt $firstTop })
        $hp = @($above | Where-Object { $_.t.StartsWith('Page') })[0]; $hc = @($above | Where-Object { $_.t -eq 'Change' })[0]
        $ha = @($above | Where-Object { $_.t -eq 'Action' })[0]; $hd = @($above | Where-Object { $_.t -eq 'Date' })[0]
        if ($hp -and $hc -and $ha -and $hd) { $bounds = @(($hp.left + 0.04), ($hc.left - 0.01), ($ha.left - 0.01), ($hd.left - 0.01)) }
        if (-not $bounds) { $out.gaps.Add("page $($p.page): change log headers not found"); continue }
        $dates = @($dates | Where-Object { $_.left -ge $bounds[3] })
        $dateIdx = @{}; foreach ($d in $dates) { $dateIdx[$d.i] = $true }
        # The page footer ('(c) <year> Microsoft Corporation...') ends the table.
        $foot = @($lines | Where-Object { $_.t.StartsWith([string][char]0x00A9) -and $dates.Count -and $_.top -gt $dates[-1].top } | ForEach-Object top | Sort-Object)
        $footTop = if ($foot.Count) { $foot[0] } else { 2 }
        # Rows: 'top' (cells top-aligned with the date: Copilot Studio, Copilot Credits, Dynamics 365) runs from a date's top to
        # the next date's top; 'middle' (the date centred in its row: Power Platform) splits halfway between date centres.
        $align = Get-Prop $FeedProfile 'rowAlign' 'top'
        for ($k = 0; $k -lt $dates.Count; $k++) {
            $d = $dates[$k]; $dm = $lines[$d.i].mid
            if ($align -eq 'middle') {
                $lo = if ($k -eq 0) { $hd.top + 0.008 } else { ($lines[$dates[$k - 1].i].mid + $dm) / 2 }
                $hi = if ($k + 1 -lt $dates.Count) { ($dm + $lines[$dates[$k + 1].i].mid) / 2 } else { [math]::Min($footTop - $eps, $dm + ($dm - $lo)) }
            } else {
                $lo = $d.top - $eps
                $hi = if ($k + 1 -lt $dates.Count) { $dates[$k + 1].top - $eps } else { [math]::Min($footTop - $eps, $d.top + 0.04) }
            }
            $cols = @('', '', '', '')
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                $y = if ($align -eq 'middle') { $l.mid } else { $l.top }
                if ($dateIdx.ContainsKey($i) -or $used.ContainsKey($i) -or $y -lt $lo -or $y -ge $hi) { continue }
                $c = if ($l.left -lt $bounds[0]) { 0 } elseif ($l.left -lt $bounds[1]) { 1 } elseif ($l.left -lt $bounds[2]) { 2 } elseif ($l.left -lt $bounds[3]) { 3 } else { -1 }
                if ($c -ge 0) { $cols[$c] = ("$($cols[$c]) $($l.t)").Trim() }
            }
            $pagesCell, $topic, $kind, $change = $cols
            if (-not $change) { continue }
            # Cells text recognition merged into one line: 'Customer Insights New' (topic and change type) and
            # 'Various Dynamics 365' (page and topic).
            if (-not $kind) { foreach ($w in 'New', 'Update', 'Remove') { if ($topic.EndsWith(" $w")) { $kind = $w; $topic = $topic.Substring(0, $topic.Length - $w.Length - 1); break } } }
            foreach ($w in 'Various', 'N/A') { if ($pagesCell.StartsWith("$w ")) { $topic = ("$($pagesCell.Substring($w.Length + 1)) $topic").Trim(); $pagesCell = $w; break } }
            $parts = $d.t -split ' '; $month = "$((Get-Culture).TextInfo.ToTitleCase($parts[0].ToLowerInvariant())) $($parts[1])"
            $ext = New-ExternalId $Feed.key (ConvertTo-FeedSlug "$month $change")
            if ($seen.ContainsKey($ext)) { continue }; $seen[$ext] = $true
            $mi = [array]::IndexOf($script:Months, $parts[0].ToLowerInvariant()) + 1
            $keydate = '{0}-{1:00}-01' -f $parts[1], $mi
            $title = "${guide}: $change"
            $summary = "${kind}: $change. Topic: $topic. Page(s): $pagesCell. Month: $month. Source: the $guide."
            $out.signals.Add([pscustomobject][ordered]@{
                    externalid = $ext; title = $title.Substring(0, [math]::Min(400, $title.Length)); summary = $summary.Substring(0, [math]::Min(20000, $summary.Length))
                    products = $Feed.products; horizon = 'future'; keydate = $keydate; datelabel = "$label · $kind".Substring(0, [math]::Min(100, "$label · $kind".Length))
                    actionrequired = $false; url = $Feed.url; lastchanged = $keydate })
        }
    }
    [pscustomobject]$out
}

function Invoke-FeedAdapter {
    <# Dispatches on the feed's kind. $Feed: key, kind, url, products. $FeedProfile: the feed's profile JSON. #>
    param([Parameter(Mandatory)][string]$Content, [Parameter(Mandatory)]$Feed, [Parameter(Mandatory)]$FeedProfile, [datetime]$Today, $Config = @{}, [string]$LastMarker, $Options = @{}, [hashtable]$ModelMap)
    switch ($Feed.kind) {
        'learnpage_tables' { Get-LifecycleSignals -Html $Content -Feed $Feed -FeedProfile $FeedProfile -Today $Today -Config $Config -LastMarker $LastMarker -Options $Options -ModelMap $ModelMap }
        'learnpage_sections' { Get-ReleaseNoteSignals -Html $Content -Feed $Feed -FeedProfile $FeedProfile -Today $Today -LastMarker $LastMarker -Options $Options }
        'rss' { Get-RssSignals -Xml $Content -Feed $Feed -FeedProfile $FeedProfile }
        'webpage_sections' { Get-WebSectionSignals -Html $Content -Feed $Feed -FeedProfile $FeedProfile -LastMarker $LastMarker }
        'pdf_changelog' { Get-PdfChangeLogSignals -Json $Content -Feed $Feed -FeedProfile $FeedProfile }
        default { throw "Unknown feed kind '$($Feed.kind)'." }
    }
}

Export-ModuleMember -Function Invoke-FeedAdapter, ConvertTo-FeedSlug
