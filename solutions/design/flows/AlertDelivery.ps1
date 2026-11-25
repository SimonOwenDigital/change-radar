# Change Radar alert delivery expressions (ADR 0011 addendum), dot-sourced by New-CollectorFlows.ps1 and
# setup/dev/Test-DestinationParity.ps1. Needs function After (runAfter helper) from the caller.
# HTML-escape, as engine ConvertTo-HtmlText: & first, then < > and ".
function HtmlEsc([string]$x) { "replace(replace(replace(replace(string($x), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '`"', '&quot;')" }
# Address and GUID shape checks a flow expression can make (engine Get-AlertDestinations uses the same rules).
function IsAddr([string]$x) {
    $dom = "last(split($x, '@'))"
    "and(equals(length(split($x, '@')), 2), greater(indexOf($x, '@'), 0), contains($dom, '.'), not(startsWith($dom, '.')), not(endsWith($dom, '.')), not(contains($x, ' ')), not(contains($x, decodeUriComponent('%09'))))"
}
function IsGuid([string]$x) {
    $p = "concat($x, '$(' ' * 36)')"
    "and(equals(length($x), 36), equals(substring($p, 8, 1), '-'), equals(substring($p, 13, 1), '-'), equals(substring($p, 18, 1), '-'), equals(substring($p, 23, 1), '-'), equals(length(split($x, '-')), 5))"
}
# alert_destinations plus alert_recipient (one more chat: entry) -> outputs('Destinations'): objects with kind
# (chat, channel, email or invalid), address, teamId, channelId, entry and reason. Repeats are kept once (union).
function Add-DestinationActions([Collections.Specialized.OrderedDictionary]$a, [string]$destExpr, [string]$recipExpr, [hashtable]$runAfter) {
    $r = "trim(string(coalesce($recipExpr, '')))"
    $a['Dest_entries'] = [ordered]@{ type = 'Query'; runAfter = $runAfter; inputs = @{ from = "@split(concat(string(coalesce($destExpr, '')), ';', if(equals($r, ''), '', concat('chat:', $r))), ';')"; where = "@not(equals(trim(item()), ''))" } }
    # substring() fails when the start equals the length, even 0 on empty text ('chat:', 'channel:<team>/'), so every
    # cut is taken from the text padded with a space (verified in pp-lab, 2026-11-23).
    $e = 'trim(item())'; $i = "indexOf($e, ':')"
    $a['Dest_split'] = [ordered]@{ type = 'Select'; runAfter = (After 'Dest_entries'); inputs = @{ from = "@body('Dest_entries')"; select = [ordered]@{
                e = "@$e"; colon = "@greaterOrEquals($i, 0)"; k = "@toLower(trim(substring(concat($e, ' '), 0, max($i, 0))))"; v = "@trim(substring(concat($e, ' '), add($i, 1)))" } } }
    $k = "item()?['k']"; $v = "item()?['v']"; $j = "indexOf($v, '/')"
    $team = "trim(substring(concat($v, ' '), 0, max($j, 0)))"; $ch = "trim(substring(concat($v, ' '), add($j, 1)))"
    $chOk = "and(startsWith($ch, '19:'), greater(length($ch), 3), not(contains($ch, ' ')))"
    $reason = "if(not(item()?['colon']), 'no kind: start with chat:, channel: or email:', if(or(equals($k, 'chat'), equals($k, 'email')), if($(IsAddr $v), '', 'not an email address'), if(equals($k, 'channel'), if(less($j, 0), 'use channel:<team id>/<channel id>', if(not($(IsGuid $team)), 'team id is not a GUID', if(not($chOk), 'channel id should start with 19:', ''))), concat('unknown kind ''', $k, ''': use chat:, channel: or email:'))))"
    $a['Dest_check'] = [ordered]@{ type = 'Select'; runAfter = (After 'Dest_split'); inputs = @{ from = "@body('Dest_split')"; select = [ordered]@{
                e = "@item()?['e']"; k = "@$k"; v = "@$v"; team = "@$team"; ch = "@$ch"; reason = "@$reason" } } }
    $ok = "equals(item()?['reason'], '')"; $isCh = "equals(item()?['k'], 'channel')"
    $a['Dest_final'] = [ordered]@{ type = 'Select'; runAfter = (After 'Dest_check'); inputs = @{ from = "@body('Dest_check')"; select = [ordered]@{
                kind = "@if($ok, item()?['k'], 'invalid')"; address = "@if(and($ok, not($isCh)), toLower(item()?['v']), '')"
                teamId = "@if(and($ok, $isCh), toLower(item()?['team']), '')"; channelId = "@if(and($ok, $isCh), item()?['ch'], '')"
                entry = "@if($ok, '', item()?['e'])"; reason = "@item()?['reason']" } } }
    $a['Destinations'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Dest_final'); inputs = "@union(body('Dest_final'), body('Dest_final'))" }
}
# The card and email footer (engine Get-AlertFooter). $t: the event type expression.
function AlertFooter([string]$t) { "if(equals($t, 'assessment.rated'), 'Rating: generic impact (LLM) plus production and action-date bonuses. The action is written by an LLM: check it before acting.', 'From Change Radar.')" }
# A card's fields as an HTML email (engine Get-AlertEmail). $f: the fields expression; $footer: the footer expression.
function EmailHtml([string]$f, [string]$footer) {
    $H = { param($x) HtmlEsc $x }
    $emailFacts = "concat('Key date: ', $(& $H "if(equals(${f}?['keyDate'], ''), 'none', ${f}?['keyDate'])"), if(equals(length(${f}?['assets']), 0), '', concat('<br>Affected: ', $(& $H "join(${f}?['assets'], ', ')"), if(greater(${f}?['more'], 0), concat(' and ', string(${f}?['more']), ' more'), ''))))"
    $emailLinks = "concat('<a href=`"', $(& $H "${f}?['links']?['app']"), '`">Open in Change Radar</a>', if(equals(string(${f}?['links']?['source']), ''), '', concat(' · <a href=`"', $(& $H "${f}?['links']?['source']"), '`">Open source</a>')))"
    "concat('<p><strong>', $(& $H "${f}?['heading']"), '</strong></p><p>', $(& $H "${f}?['why']"), '</p><p>', $emailFacts, '</p><p><strong>Recommended action</strong><br>', $(& $H "${f}?['action']"), '</p><p>', $emailLinks, '</p><p style=`"color:#666666;font-size:small`">', $(& $H $footer), '</p>')"
}
