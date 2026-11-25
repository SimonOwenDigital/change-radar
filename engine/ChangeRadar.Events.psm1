#Requires -Version 7.0
<#
    Reference implementation of events, dispatch and the Notify-Teams card (spec §7, §12; ADR 0011). Pure functions over
    plain objects: no tenant access. The event, dispatcher and handler flows must behave the same (checked by parity).
#>
Set-StrictMode -Version Latest

$script:Levels = @('none', 'low', 'medium', 'high', 'critical')
$script:OpenStatuses = @('new', 'confirmed')
# The fields collectors track in crdr_signalversion.crdr_changedfields (wording-only changes aren't events, ADR 0011).
$script:SignalKeyFields = @('title', 'keyDate', 'dateLabel', 'actionRequired')

function Get-Prop($o, [string]$name) { if ($null -eq $o) { return $null }; if ($o -is [hashtable]) { return $o[$name] }; $p = $o.PSObject.Properties[$name]; if ($p) { $p.Value } else { $null } }
# Date-only strings (e.g. a Dataverse date-only key date) are UTC days, never local time.
function ConvertTo-UtcDay($d) { if (-not $d) { return $null }; if ($d -is [datetime]) { return $d.ToUniversalTime().Date }; [datetimeoffset]::Parse("$d", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime.Date }
function Get-EffectiveImpact($estate, $override) { if ($override) { "$override".ToLowerInvariant() } elseif ($estate) { "$estate".ToLowerInvariant() } else { 'none' } }
function Format-Impact([string]$i) { if (-not $i) { return '' }; $i.Substring(0, 1).ToUpperInvariant() + $i.Substring(1) }

function Get-RecordEvents {
    <# Events raised by one create (Before = $null) or update of a signal, exposure or assessment. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('signal', 'exposure', 'assessment', 'asset')][string]$Table, $Before, [Parameter(Mandatory)]$After)
    $events = [Collections.Generic.List[string]]::new()
    switch ($Table) {
        'signal' {
            $health = (Get-Prop $After 'source') -eq 'graph_health'
            # A new incident that is already over (horizon future: restored, review published) is not an opening
            # (install test: the first night collects the last month's incidents, most of them over).
            if ($null -eq $Before) { $events.Add('signal.new'); if ($health -and (Get-Prop $After 'horizon') -ne 'future') { $events.Add('incident.opened') }; break }
            $changed = @($script:SignalKeyFields | Where-Object { "$(Get-Prop $Before $_)" -ne "$(Get-Prop $After $_)" })
            if ($changed) { $events.Add('signal.changed') }
            if ($health -and (Get-Prop $Before 'horizon') -ne 'future' -and (Get-Prop $After 'horizon') -eq 'future') { $events.Add('incident.resolved') }
        }
        'exposure' {
            $now = Get-Prop $After 'status'
            if ($null -eq $Before) { if ($script:OpenStatuses -contains $now) { $events.Add('exposure.found') }; break }
            if ((Get-Prop $Before 'status') -eq 'unmatched' -and $now -eq 'new') { $events.Add('exposure.found') }
        }
        'asset' {
            # ADR 0013: a silent model move. Only a known model replaced by a different known model; a first model or
            # one that is now unknown is not a move.
            $was = "$(Get-Prop $Before 'model')"; $now = "$(Get-Prop $After 'model')"
            if ($null -ne $Before -and $was -and $now -and $was -cne $now) { $events.Add('asset.modelchanged') }
        }
        'assessment' {
            if ($null -eq $Before) { $events.Add('assessment.rated'); break }
            if ("$(Get-Prop $Before 'estateImpact')" -ne "$(Get-Prop $After 'estateImpact')" -or "$(Get-Prop $Before 'overrideImpact')" -ne "$(Get-Prop $After 'overrideImpact')") { $events.Add('assessment.rated') }
        }
    }
    $events.ToArray()
}

function Test-DeadlineApproaching {
    <# deadline.approaching: action required, key date exactly 14 or 3 UTC days from today, at least one open live exposure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Signal, [int]$OpenLiveExposures, [datetime]$Today = [datetime]::UtcNow.Date, [int[]]$Days = @(14, 3))
    if (-not (Get-Prop $Signal 'actionRequired') -or $OpenLiveExposures -lt 1) { return $false }
    $kd = ConvertTo-UtcDay (Get-Prop $Signal 'keyDate'); if (-not $kd) { return $false }
    $Days -contains [int]$kd.Subtract($Today.Date).TotalDays
}

function Get-EventHandlers {
    <# Handlers an event is dispatched to: enabled subscriptions for its type whose filters pass. Handlers that post
       outside Change Radar receive live events only (signal events have no estate and count as live). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Event, [object[]]$Subscriptions = @())
    $estate = Get-Prop $Event 'estate'; $isLive = (-not $estate) -or $estate -eq 'live'
    $effective = Get-EffectiveImpact (Get-Prop $Event 'estateImpact') (Get-Prop $Event 'overrideImpact')
    $out = foreach ($s in $Subscriptions) {
        if (-not (Get-Prop $s 'enabled') -or (Get-Prop $s 'eventType') -ne (Get-Prop $Event 'type')) { continue }
        if ((Get-Prop $s 'postsOutside') -and -not $isLive) { continue }
        $min = Get-Prop $s 'filterMinImpact'
        if ($min -and [array]::IndexOf($script:Levels, $effective) -lt [array]::IndexOf($script:Levels, "$min".ToLowerInvariant())) { continue }
        Get-Prop $s 'handler'
    }
    @($out | Sort-Object -Unique)
}

function Get-AssetLabel {
    <# A Copilot-created flow's generated name, OAI_<guid>_<Name>_..., reads as '<Name> (created by Copilot)'. Any other name is unchanged. #>
    param([string]$Name)
    if ($Name -cmatch '^OAI_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?:_(.*))?$') {
        $first = if ($Matches[1]) { ($Matches[1] -split '_')[0] } else { '' }
        if ($first) { return "$first (created by Copilot)" } else { return 'Flow created by Copilot' }
    }
    $Name
}

function Format-DigestLine {
    <# One digest line from an event name 'type | part | ...': the parts after the type joined by ' · '. Ratings show the source and
       rating capitalised, as on the cards; exposures show the asset label. #>
    param([string]$EventName)
    $parts = @($EventName -split ' \| ')
    $type = $parts[0]; $rest = @($parts | Select-Object -Skip 1)
    if ($type -eq 'assessment.rated' -and $rest.Count -ge 3) { $rest[1] = Format-Impact $rest[1]; $rest[2] = Format-Impact $rest[2] }
    if ($type -eq 'exposure.found' -and $rest.Count -ge 2) { $rest[1] = Get-AssetLabel $rest[1] }
    if ($type -eq 'asset.modelchanged' -and $rest.Count -ge 3) { return "$(Get-AssetLabel $rest[0]) · moved from $($rest[1]) to $($rest[2])" }
    # ADR 0015: 'watch.matched | ext | title | watch' and 'watch.updated | ext | title | what changed'.
    if ($type -eq 'watch.matched' -and $rest.Count -ge 3) { return "$($rest[0]) · $($rest[1]) · watch: $($rest[2])" }
    if ($type -eq 'watch.updated' -and $rest.Count -ge 3) { return "$($rest[0]) · $($rest[1]) · changed: $($rest[2])" }
    $rest -join ' · '
}

function Get-AlertCard {
    <# Notify-Teams card fields for an incident, rating or deadline event (spec §7). Assets: up to 5 names, sorted
       case-insensitively, then '+N more'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Event, $Signal, $Assessment, [string[]]$Assets = @(), [Parameter(Mandatory)][string]$AppUrl)
    $type = Get-Prop $Event 'type'
    if ($type -eq 'asset.modelchanged') {
        # ADR 0013: the asset is the subject; there is no signal.
        # ADR 0017: a prompt's callers (flow names in the payload) follow it, sorted; still one card.
        $name = Get-AssetLabel (Get-Prop $Event 'assetName'); $to = Get-Prop $Event 'toModel'
        $callers = @(@(Get-Prop $Event 'callers') | Where-Object { $_ } | ForEach-Object { Get-AssetLabel $_ } | Sort-Object { $_.ToLowerInvariant() })
        $n = $callers.Count
        $all = @(@($name) + $callers | Select-Object -Unique)   # as the handler's union(): an exact repeat is shown once
        $why = "The $(Get-Prop $Event 'assetType') $name in $(Get-Prop $Event 'environmentName') moved from $(Get-Prop $Event 'fromModel') to $to without anyone editing it. Its answers may differ."
        if ($n -eq 1) { $why += ' 1 flow calls it, so its results may change too.' } elseif ($n -gt 1) { $why += " $n flows call it, so their results may change too." }
        $action = if ($n -eq 0) { 'Re-test it with your usual questions and check its answers before people notice a change.' }
                  else { "Re-test it and the $(if ($n -eq 1) { 'flow that calls' } else { 'flows that call' }) it with your usual inputs, and check the results before people notice a change." }
        return [pscustomobject]@{ heading = "Model changed: $name now uses $to"
            why = $why
            assets = @($all | Select-Object -First 5); more = [math]::Max(0, $all.Count - 5); keyDate = ''; action = $action
            links = [pscustomobject]@{ app = "$AppUrl&pagetype=entityrecord&etn=crdr_asset&id=$(Get-Prop $Event 'assetId')"; source = '' } }
    }
    if ($null -eq $Signal) { throw "Event type '$type' needs a signal." }
    $title = Get-Prop $Signal 'title'; $ext = Get-Prop $Signal 'externalId'
    $kd = ConvertTo-UtcDay (Get-Prop $Signal 'keyDate'); $keyDate = if ($kd) { $kd.ToString('yyyy-MM-dd') } else { '' }
    $sorted = @($Assets | Where-Object { $_ } | ForEach-Object { Get-AssetLabel $_ } | Sort-Object { $_.ToLowerInvariant() })
    $shown = @($sorted | Select-Object -First 5); $more = [math]::Max(0, $sorted.Count - 5)
    $count = if ($Assessment -and $null -ne (Get-Prop $Assessment 'affectedCount')) { [int](Get-Prop $Assessment 'affectedCount') } else { $sorted.Count }
    $recordLink = { param($etn, $id) "$AppUrl&pagetype=entityrecord&etn=$etn&id=$id" }
    $signalLink = & $recordLink 'crdr_signal' (Get-Prop $Signal 'id')
    switch ($type) {
        'incident.opened' {
            $heading = "Incident: $title"; $why = "Service incident affecting $(Get-Prop $Signal 'products') ($ext)."
            $action = 'Follow the incident in the Microsoft 365 admin centre and tell affected users.'; $app = $signalLink
        }
        'incident.resolved' {
            $heading = "Resolved: $title"; $why = "Service incident affecting $(Get-Prop $Signal 'products') ($ext) is resolved."
            $action = 'No action needed. Check the post-incident report in the admin centre if users were affected.'; $app = $signalLink
        }
        'assessment.rated' {
            $estate = Get-Prop $Assessment 'estateImpact'; $override = Get-Prop $Assessment 'overrideImpact'
            $effective = Get-EffectiveImpact $estate $override
            $heading = "$(Format-Impact $effective) for your estate: $title"
            $why = "$ext affects $count of your assets$(if ($override) { " (rated $(Format-Impact $override) by override; estate rating $(Format-Impact $estate))" })."
            $action = "$(Get-Prop $Assessment 'recommendedAction')"; $app = & $recordLink 'crdr_assessment' (Get-Prop $Assessment 'id')
        }
        'deadline.approaching' {
            $heading = "Action due in $(Get-Prop $Event 'daysLeft') days: $title"
            $why = "$ext requires action by $keyDate and affects $count of your assets."
            $action = if ($Assessment -and (Get-Prop $Assessment 'recommendedAction')) { "$(Get-Prop $Assessment 'recommendedAction')" } else { 'Open the signal and check the affected assets.' }
            $app = $signalLink
        }
        # ADR 0015: the watch list. The signal's open live exposures, if any, are listed as on other cards.
        'watch.matched' {
            $heading = "On your watch list: $title"
            $why = "$ext matches your watch $([char]0x201C)$(Get-Prop $Event 'watchName')$([char]0x201D). Changes to it will be sent too."
            $action = 'Read it in Change Radar. To stop following it, switch Watched off on the signal.'; $app = $signalLink
        }
        'watch.updated' {
            $heading = "Watched item updated: $title"; $why = "$ext changed: $(Get-Prop $Event 'changes')."
            $action = 'Open it in Change Radar to see what changed.'; $app = $signalLink
        }
        default { throw "No card for event type '$type'." }
    }
    # ADR 0013 step 5: a model retirement's feed profile says what Microsoft does (migrationNote); rating and deadline cards say it too.
    $note = "$(Get-Prop $Signal 'migrationNote')"
    if ($note -and $type -in 'assessment.rated', 'deadline.approaching') { $why = "$why $note" }
    [pscustomobject]@{ heading = $heading; why = $why; assets = $shown; more = $more; keyDate = $keyDate; action = $action
        links = [pscustomobject]@{ app = $app; source = "$(Get-Prop $Signal 'url')" } }
}

function Get-AlertDestinations {
    <# ADR 0011 addendum: where alerts go. alert_destinations is 'kind:value' entries separated by ';' (chat:<upn>,
       channel:<team id>/<channel id>, email:<address>); alert_recipient, if set, is one more chat: entry. Repeats are kept
       once (first wins). A bad entry comes back as kind 'invalid' with a reason, so the others are still sent. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Destinations, [AllowNull()][AllowEmptyString()][string]$Recipient)
    # Rules a flow expression can check too (no regular expressions in WDL): one '@' with text before it; a domain
    # containing '.' that neither starts nor ends with '.'; no space or tab.
    $isAddress = { param($v)
        $parts = $v.Split('@'); $dom = $parts[-1]
        $parts.Count -eq 2 -and $parts[0].Length -gt 0 -and $dom.Contains('.') -and -not $dom.StartsWith('.') -and -not $dom.EndsWith('.') -and -not $v.Contains(' ') -and -not $v.Contains("`t") }
    # A GUID's shape: 36 characters, '-' at 8, 13, 18 and 23, five parts.
    $isGuid = { param($t) $t.Length -eq 36 -and $t[8] -eq '-' -and $t[13] -eq '-' -and $t[18] -eq '-' -and $t[23] -eq '-' -and $t.Split('-').Count -eq 5 }
    $entries = @("$Destinations".Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ("$Recipient".Trim()) { $entries += "chat:$("$Recipient".Trim())" }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); $out = [Collections.Generic.List[object]]::new()
    foreach ($e in $entries) {
        $bad = { param($reason) [pscustomobject]@{ kind = 'invalid'; entry = $e; reason = $reason; address = $null; teamId = $null; channelId = $null } }
        $i = $e.IndexOf(':')
        if ($i -lt 0) { $out.Add((& $bad 'no kind: start with chat:, channel: or email:')); continue }
        $kind = $e.Substring(0, $i).Trim().ToLowerInvariant(); $v = $e.Substring($i + 1).Trim()
        $d = switch ($kind) {
            { $_ -in 'chat', 'email' } {
                if (& $isAddress $v) { [pscustomobject]@{ kind = $kind; entry = $e; reason = $null; address = $v.ToLowerInvariant(); teamId = $null; channelId = $null } }
                else { & $bad 'not an email address' }
            }
            'channel' {
                $j = $v.IndexOf('/')
                if ($j -lt 0) { & $bad 'use channel:<team id>/<channel id>' }
                else {
                    $team = $v.Substring(0, $j).Trim(); $ch = $v.Substring($j + 1).Trim()
                    if (-not (& $isGuid $team)) { & $bad 'team id is not a GUID' }
                    elseif (-not $ch.StartsWith('19:') -or $ch.Length -le 3 -or $ch.Contains(' ')) { & $bad 'channel id should start with 19:' }
                    else { [pscustomobject]@{ kind = 'channel'; entry = $e; reason = $null; address = $null; teamId = $team.ToLowerInvariant(); channelId = $ch } }
                }
            }
            default { & $bad "unknown kind '$kind': use chat:, channel: or email:" }
        }
        $key = switch ($d.kind) { 'channel' { "channel:$($d.teamId)/$($d.channelId)" } 'invalid' { "invalid:$e" } default { "$($d.kind):$($d.address)" } }
        if (-not $seen.Add($key)) { continue }
        $out.Add($d)
    }
    $out.ToArray()
}

function ConvertTo-HtmlText([AllowNull()][string]$s) {
    # As the handler's replace() chain: & first, then < > and ".
    "$s".Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-AlertFooter([string]$Type) {
    if ($Type -eq 'assessment.rated') { 'Rating: generic impact (LLM) plus production and action-date bonuses. The action is written by an LLM: check it before acting.' } else { 'From Change Radar.' }
}

function Get-AlertEmail {
    <# ADR 0011 addendum: a card (Get-AlertCard fields) as an HTML email for an email: destination. Subject is the heading. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Card, [Parameter(Mandatory)][string]$Type)
    $h = { param($x) ConvertTo-HtmlText $x }
    $assets = @(@(Get-Prop $Card 'assets') | Where-Object { $_ })
    $more = [int](Get-Prop $Card 'more')
    $kd = "$(Get-Prop $Card 'keyDate')"; if (-not $kd) { $kd = 'none' }
    $facts = "Key date: $(& $h $kd)"
    if ($assets.Count) { $facts += "<br>Affected: $(& $h ($assets -join ', '))$(if ($more -gt 0) { " and $more more" })" }
    $links = Get-Prop $Card 'links'
    $linkHtml = "<a href=`"$(& $h (Get-Prop $links 'app'))`">Open in Change Radar</a>"
    $src = "$(Get-Prop $links 'source')"; if ($src) { $linkHtml += " · <a href=`"$(& $h $src)`">Open source</a>" }
    $html = "<p><strong>$(& $h (Get-Prop $Card 'heading'))</strong></p><p>$(& $h (Get-Prop $Card 'why'))</p><p>$facts</p>" +
            "<p><strong>Recommended action</strong><br>$(& $h (Get-Prop $Card 'action'))</p><p>$linkHtml</p>" +
            "<p style=`"color:#666666;font-size:small`">$(& $h (Get-AlertFooter $Type))</p>"
    [pscustomobject]@{ subject = "$(Get-Prop $Card 'heading')"; html = $html }
}

Export-ModuleMember -Function Get-RecordEvents, Test-DeadlineApproaching, Get-EventHandlers, Get-AlertCard, Get-EffectiveImpact, Get-AssetLabel, Format-DigestLine, Get-AlertDestinations, Get-AlertEmail, Get-AlertFooter
