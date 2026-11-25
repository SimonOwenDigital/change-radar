#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the dispatcher and the Notify-Teams handler against the reference engine (ADR 0011). Read-only.
.DESCRIPTION
    For events raised since -Since (default: last 24 hours):
      - dispatch: engine Get-EventHandlers with the Dataverse subscriptions must give exactly the handlers that have a
        crdr_handlerrun for the event (all v1 handlers post outside Change Radar, so live events only);
      - cards: for each Notify-Teams run that succeeded, engine Get-AlertCard on the same signal, assessment and live
        open exposures must equal the card fields the handler stored in crdr_handlerrun.detail.
    Exit code 1 on any difference.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [datetime]$Since = [datetime]::UtcNow.AddHours(-24),
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Events.psm1') -Force
function Get-All([string]$Path) {
    $h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' }
    $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers $h -Uri "$dv/$Path"
    while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers $h -Uri $r.'@odata.nextLink' }
    $rows.ToArray()
}
$who = Invoke-RestMethod -Headers @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json' } -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($who.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($who.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Label([string]$choice, $value) { if ($null -eq $value -or "$value" -eq '') { return $null }; @($schema.choices.$choice)[[int]$value - $base] }
function Get-Opt([string]$choice, [string]$value) { $base + [array]::IndexOf(@($schema.choices.$choice), $value) }

$appUrl = (@(Get-All "crdr_configs?`$select=crdr_value&`$filter=crdr_key eq 'app_url'")[0]).crdr_value
$subs = @(Get-All 'crdr_subscriptions?$select=crdr_subscriptionid,crdr_name,crdr_eventtype,crdr_handler,crdr_filterminimpact,crdr_enabled' | ForEach-Object {
        [pscustomobject]@{ name = $_.crdr_name; eventType = (Get-Label 'eventtype' $_.crdr_eventtype); handler = $_.crdr_handler; filterMinImpact = (Get-Label 'impact' $_.crdr_filterminimpact); enabled = [bool]$_.crdr_enabled; postsOutside = $true } })
$sinceIso = $Since.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$events = @(Get-All "crdr_events?`$select=crdr_eventid,crdr_name,crdr_eventtype,crdr_payloadjson,_crdr_signal_value,_crdr_assessment_value&`$filter=createdon ge $sinceIso")
$runs = @(Get-All "crdr_handlerruns?`$select=crdr_name,crdr_outcome,crdr_detail,_crdr_event_value,crdr_ranon&`$filter=createdon ge $sinceIso")
$problems = [Collections.Generic.List[string]]::new(); $changed = 0; $cards = 0
foreach ($e in $events) {
    $p = if ($e.crdr_payloadjson) { $e.crdr_payloadjson | ConvertFrom-Json } else { [pscustomobject]@{} }
    $type = Get-Label 'eventtype' $e.crdr_eventtype
    $ev = [pscustomobject]@{ type = $type; estate = $p.PSObject.Properties['estate'] ? $p.estate : $null; estateImpact = $p.PSObject.Properties['estateImpact'] ? $p.estateImpact : $null
        overrideImpact = $p.PSObject.Properties['overrideImpact'] ? $p.overrideImpact : $null; daysLeft = $p.PSObject.Properties['daysLeft'] ? $p.daysLeft : $null
        # ADR 0015: the watch cards' words come from the payload.
        watchName = $p.PSObject.Properties['watchName'] ? $p.watchName : $null; changes = $p.PSObject.Properties['changes'] ? $p.changes : $null }
    $want = @(Get-EventHandlers -Event $ev -Subscriptions $subs)
    $mine = @($runs | Where-Object _crdr_event_value -eq $e.crdr_eventid)
    $got = @($mine | ForEach-Object { ($_.crdr_name -split ' \| ')[0] } | Sort-Object -Unique)
    if (($want -join ',') -ne ($got -join ',')) { $problems.Add("dispatch '$($e.crdr_name)': engine [$($want -join ',')], flow [$($got -join ',')]") }
    foreach ($r in $mine | Where-Object { $_.crdr_name -like 'Notify-Teams |*' -and (Get-Label 'handleroutcome' $_.crdr_outcome) -eq 'succeeded' }) {
        $cards++
        if ($type -eq 'asset.modelchanged') {
            # ADR 0013: no signal; the card comes from the payload (assetId, assetName, assetType, environmentName, fromModel, toModel).
            $mcEvent = [pscustomobject]@{ type = $type }; foreach ($prop in $p.PSObject.Properties) { $mcEvent | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force }
            $card = Get-AlertCard -Event $mcEvent -AppUrl $appUrl
        } else {
        $s = Invoke-RestMethod -Headers @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json' } -Uri "$dv/crdr_signals($($e._crdr_signal_value))?`$select=crdr_signalid,crdr_externalid,crdr_title,crdr_products,crdr_keydate,crdr_url,crdr_lastchanged&`$expand=crdr_feed(`$select=crdr_profile)"
        $aFilter = if ($e._crdr_assessment_value) { "crdr_assessmentid eq $($e._crdr_assessment_value)" } else { "_crdr_signal_value eq $($e._crdr_signal_value) and crdr_source eq $(Get-Opt 'assetsource' 'live')" }
        $a = @(Get-All "crdr_assessments?`$select=crdr_assessmentid,crdr_estateimpact,crdr_overrideimpact,crdr_affectedcount,crdr_recommendedaction,modifiedon&`$filter=$aFilter&`$top=1") | Select-Object -First 1
        $assessment = if ($a) { [pscustomobject]@{ id = $a.crdr_assessmentid; estateImpact = (Get-Label 'impact' $a.crdr_estateimpact); overrideImpact = (Get-Label 'impact' $a.crdr_overrideimpact); affectedCount = $a.crdr_affectedcount; recommendedAction = $a.crdr_recommendedaction } } else { $null }
        $open = "crdr_status eq $(Get-Opt 'exposurestatus' 'new') or crdr_status eq $(Get-Opt 'exposurestatus' 'confirmed')"
        $names = @(Get-All "crdr_exposures?`$select=_crdr_asset_value&`$expand=crdr_asset(`$select=crdr_name)&`$filter=_crdr_signal_value eq $($e._crdr_signal_value) and crdr_source eq $(Get-Opt 'assetsource' 'live') and ($open) and _crdr_asset_value ne null" | ForEach-Object { $_.crdr_asset.crdr_name })
        # ADR 0013 step 5: the feed profile's migration note.
        $profile = if ($s.PSObject.Properties['crdr_feed'] -and $s.crdr_feed -and $s.crdr_feed.crdr_profile) { $s.crdr_feed.crdr_profile | ConvertFrom-Json } else { $null }
        $mNote = if ($profile -and $profile.PSObject.Properties['migrationNote']) { $profile.migrationNote } else { $null }
        $signal = [pscustomobject]@{ id = $s.crdr_signalid; externalId = $s.crdr_externalid; title = $s.crdr_title; products = $s.crdr_products; keyDate = $s.crdr_keydate; url = $s.crdr_url; migrationNote = $mNote }
        $card = Get-AlertCard -Event $ev -Signal $signal -Assessment $assessment -Assets $names -AppUrl $appUrl
        }
        # A card is rebuilt from today's records: if its assessment changed after the card was sent, they can't agree. Say so; don't count it.
        if ($a -and $r.crdr_ranon -and ([datetime]$a.modifiedon) -gt ([datetime]$r.crdr_ranon)) { $changed++; continue }
        # The same for the signal: a source change after the card (a new key date, say) can't agree either.
        if ($type -ne 'asset.modelchanged' -and $s.crdr_lastchanged -and $r.crdr_ranon -and ([datetime]$s.crdr_lastchanged) -gt ([datetime]$r.crdr_ranon)) { $changed++; continue }
        # Since the ADR 0011 addendum the detail is '<delivery summary> Card: <fields JSON>'; older runs hold the JSON alone.
        $detail = "$($r.crdr_detail)"; $at = $detail.IndexOf(' Card: {')
        $stored = $(if ($at -ge 0) { $detail.Substring($at + 7) } else { $detail }) | ConvertFrom-Json
        foreach ($f in 'heading', 'why', 'more', 'keyDate', 'action') { if ("$($card.$f)" -cne "$($stored.$f)") { $problems.Add("card '$($e.crdr_name)' ${f}: engine '$($card.$f)' / flow '$($stored.$f)'") } }
        if ((@($card.assets) -join '|') -cne (@($stored.assets) -join '|')) { $problems.Add("card '$($e.crdr_name)' assets differ") }
        foreach ($l in 'app', 'source') { if ($card.links.$l -cne $stored.links.$l) { $problems.Add("card '$($e.crdr_name)' link $l differs") } }
    }
}
"events since $sinceIso`: $($events.Count); handler runs: $($runs.Count); cards checked: $($cards - $changed)$(if ($changed) { "; $changed card(s) skipped: their assessment or signal changed after they were sent" })"
if ($problems.Count) { "MISMATCHES ($($problems.Count)):"; $problems | ForEach-Object { "  $_" }; exit 1 }
'PARITY: the dispatcher and Notify-Teams agree with the engine on every event and card.'
