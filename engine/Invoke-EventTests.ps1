#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the event, dispatch and card cases (tests/events/*.json) against engine/ChangeRadar.Events.psm1. Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$Dir = (Join-Path $PSScriptRoot '..' 'tests' 'events'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Events.psm1') -Force
$rows = [Collections.Generic.List[object]]::new()
function Add-Row($id, $ok, $got, $note) { $rows.Add([pscustomobject]@{ Case = $id; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Got = $got; Note = $note }) }

$d = Get-Content -Raw (Join-Path $Dir 'derive.json') | ConvertFrom-Json -Depth 20
foreach ($c in $d.cases) {
    $got = @(Get-RecordEvents -Table $c.table -Before $c.before -After $c.after)
    Add-Row $c.id ((($got | Sort-Object) -join ',') -eq ((@($c.expected) | Sort-Object) -join ',')) ($got -join ',') $c.note
}
$today = [datetime]::ParseExact($d.today, 'yyyy-MM-dd', $null)
foreach ($c in $d.deadline.cases) {
    $got = Test-DeadlineApproaching -Signal $c.signal -OpenLiveExposures $c.openLiveExposures -Today $today
    Add-Row $c.id ($got -eq $c.expected) "$got" $c.note
}
$p = Get-Content -Raw (Join-Path $Dir 'dispatch.json') | ConvertFrom-Json -Depth 20
foreach ($c in $p.cases) {
    $got = @(Get-EventHandlers -Event $c.event -Subscriptions @($p.subscriptions))
    Add-Row $c.id (($got -join ',') -eq ((@($c.expected) | Sort-Object) -join ',')) ($got -join ',') $(if ($c.PSObject.Properties['note']) { $c.note })
}
$k = Get-Content -Raw (Join-Path $Dir 'card.json') | ConvertFrom-Json -Depth 20
foreach ($c in $k.cases) {
    $a = if ($c.PSObject.Properties['assessment']) { $c.assessment } else { $null }
    $assets = if ($c.PSObject.Properties['assets']) { @($c.assets) } else { @() }
    $card = Get-AlertCard -Event $c.event -Signal $c.signal -Assessment $a -Assets $assets -AppUrl $k.appUrl
    $want = $c.expected; $problems = @()
    foreach ($f in 'heading', 'why', 'more', 'keyDate', 'action') { if ("$($card.$f)" -cne "$($want.$f)") { $problems += "${f}: '$($card.$f)'" } }
    if ((@($card.assets) -join '|') -cne (@($want.assets) -join '|')) { $problems += "assets: $(@($card.assets) -join '|')" }
    foreach ($l in 'app', 'source') { $w = $want.links.$l.Replace('{appUrl}', $k.appUrl); if ($card.links.$l -cne $w) { $problems += "link ${l}: $($card.links.$l)" } }
    Add-Row $c.id (-not $problems) ($problems -join '; ') $c.note
}
$lb = Get-Content -Raw (Join-Path $Dir 'labels.json') -Encoding utf8 | ConvertFrom-Json -Depth 20
foreach ($c in $lb.assetLabel) { $got = Get-AssetLabel $c.name; Add-Row $c.id ($got -ceq $c.expected) $got $(if ($c.PSObject.Properties['note']) { $c.note }) }
foreach ($c in $lb.digestLine) { $got = Format-DigestLine $c.eventName; Add-Row $c.id ($got -ceq $c.expected) $got $null }
$ds = Get-Content -Raw (Join-Path $Dir 'destinations.json') -Encoding utf8 | ConvertFrom-Json -Depth 20
foreach ($c in $ds.parse) {
    $got = @(Get-AlertDestinations -Destinations $c.destinations -Recipient $c.recipient | ForEach-Object {
        $x = $_
        switch ($x.kind) { 'channel' { "channel:$($x.teamId)/$($x.channelId)" } 'invalid' { "invalid:$($x.entry) ($($x.reason))" } default { "$($x.kind):$($x.address)" } } })
    Add-Row $c.id (($got -join ' ; ') -ceq (@($c.expected) -join ' ; ')) ($got -join ' ; ') $(if ($c.PSObject.Properties['note']) { $c.note })
}
foreach ($c in $ds.email.cases) {
    $card = $c.card; $card.links.app = $card.links.app.Replace('{appUrl}', $ds.email.appUrl)
    $mail = Get-AlertEmail -Card $card -Type $c.type
    $wantHtml = $c.expected.html.Replace('{appUrl}', [Net.WebUtility]::HtmlEncode($ds.email.appUrl))
    $problems = @()
    if ($mail.subject -cne $c.expected.subject) { $problems += "subject: $($mail.subject)" }
    if ($mail.html -cne $wantHtml) { $problems += "html: $($mail.html)" }
    Add-Row $c.id (-not $problems) ($problems -join '; ') $null
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$($rows.Count - $failed) passed, $failed failed, $($rows.Count) cases"
if ($failed) { exit 1 }
