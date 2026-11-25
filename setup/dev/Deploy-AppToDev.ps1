#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Change Radar app (phases 1 to 3) into ChangeRadarCore in the dev environment. Plans by default; -Apply to change.

.DESCRIPTION
    Creates or updates, inside solution ChangeRadarCore (ADR 0007):
      - system views on Signals: Now, Imminent, Future; on Collection runs: Recent collection runs
      - charts on Signals: Signals by horizon (column), Signals by source (pie)
      - dashboard 'Change Radar overview': both charts, the Now and Imminent lists, recent collection runs
      - views on Assets: Estate assets; on Asset fingerprints: Asset fingerprints; the asset main form (details + Fingerprints list)
      - phase 3 review queue (ADR 0009): views Fingerprints to review, Signal fingerprints, Open exposures, Live exposures;
        main forms for signals (fingerprints and exposures lists), signal fingerprints (Status editable) and exposures
      - model-driven app 'Change Radar' (crdr_ChangeRadar) with its site map: Overview, Signals, Exposures; Review:
        Fingerprints to review, Signal fingerprints; Assets; Collection runs, Config, Tenant settings, Rules, Vocabulary
    then publishes. Writes only to the environment named by -ExpectedEnvironmentName.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SolutionUniqueName = 'ChangeRadarCore',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
$sol = @{ 'MSCRM.SolutionUniqueName' = $SolutionUniqueName }

Import-Module Az.Accounts -ErrorAction Stop
function Get-Token { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText }
function Invoke-Dv([string]$Method = 'GET', [string]$Path, $Body, [hashtable]$Extra = @{}) {
    $h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'return=representation' }
    foreach ($k in $Extra.Keys) { if ($Extra[$k]) { $h[$k] = $Extra[$k] } else { $h.Remove($k) } }   # empty value removes a default header
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = $h }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @p } catch {
        # Keep the server's own message: a non-JSON error body used to surface as a ConvertFrom-Json error (observed 2026-11-21).
        $raw = "$($_.ErrorDetails.Message)"; $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $d = try { ($raw | ConvertFrom-Json -ErrorAction Stop).error.message } catch { if ($raw) { $raw.Substring(0, [math]::Min(300, $raw.Length)) } else { $_.Exception.Message } }
        throw "$Method $Path failed ($code): $d"
    }
}
function Get-One([string]$path) { @((Invoke-Dv -Path $path).value) | Select-Object -First 1 }
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }

$org = Invoke-Dv -Path 'RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType''Default'')'
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Stopping." }
$lcid = (Invoke-Dv -Path 'organizations?$select=languagecode').value[0].languagecode
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) { $base + [array]::IndexOf(@($schema.choices.$choice), $value) }
$meta = @{}
$appTables = 'crdr_signal', 'crdr_collectionrun', 'crdr_config', 'crdr_signalversion', 'crdr_asset', 'crdr_assetfingerprint', 'crdr_signalfingerprint', 'crdr_exposure', 'crdr_tenantsetting', 'crdr_rule', 'crdr_facetvalue', 'crdr_assessment', 'crdr_watch', 'crdr_feed', 'crdr_subscription'
foreach ($e in $appTables) { $meta[$e] = Invoke-Dv -Path "EntityDefinitions(LogicalName='$e')?`$select=ObjectTypeCode,MetadataId,EntitySetName" }

# ---------- definitions ----------
$signalCols = @(@('crdr_title', 450), @('crdr_externalid', 110), @('crdr_source', 160), @('crdr_datelabel', 220), @('crdr_keydate', 110), @('crdr_products', 250), @('crdr_actionrequired', 90), @('crdr_lastchanged', 130))
$allCols = @(@('crdr_title', 450), @('crdr_horizon', 90)) + $signalCols[1..($signalCols.Count - 1)]
function New-ViewXml([string]$entity, [string]$idAttr, [object[]]$cols, [string[]]$order, [bool]$desc, [string]$filter) {
    $dir = $desc.ToString().ToLower()
    $orders = ($order | ForEach-Object { "<order attribute=`"$_`" descending=`"$dir`" />" }) -join ''
    # A column named sig.<attribute> is the parent signal's, through an outer link (alias sig) on the crdr_signal lookup.
    $attrs = ($cols | Where-Object { $_[0] -notlike 'sig.*' } | ForEach-Object { "<attribute name=`"$($_[0])`" />" }) -join ''
    $sigAttrs = @($cols | Where-Object { $_[0] -like 'sig.*' } | ForEach-Object { "<attribute name=`"$($_[0].Substring(4))`" />" })
    if ($sigAttrs) { $attrs += "<link-entity name=`"crdr_signal`" from=`"crdr_signalid`" to=`"crdr_signal`" link-type=`"outer`" alias=`"sig`">$($sigAttrs -join '')</link-entity>" }
    $fetch = "<fetch version=`"1.0`" mapping=`"logical`"><entity name=`"$entity`">$attrs<attribute name=`"$idAttr`" />$orders<filter type=`"and`"><condition attribute=`"statecode`" operator=`"eq`" value=`"0`" />$filter</filter></entity></fetch>"
    $cells = ($cols | ForEach-Object { "<cell name=`"$($_[0])`" width=`"$($_[1])`" />" }) -join ''
    $layout = "<grid name=`"resultset`" object=`"$($meta[$entity].ObjectTypeCode)`" jump=`"$($cols[0][0])`" select=`"1`" icon=`"1`" preview=`"1`"><row name=`"result`" id=`"$idAttr`">$cells</row></grid>"
    @{ fetch = $fetch; layout = $layout }
}
$assetCols = @(@('crdr_name', 300), @('crdr_resourcetype', 230), @('crdr_environmentname', 150), @('crdr_environmenttype', 110), @('crdr_source', 90), @('crdr_solutionuniquename', 160), @('crdr_lastseen', 130))
$exposureCols = @(@('crdr_name', 340), @('crdr_source', 90), @('crdr_status', 110), @('crdr_matchedfacets', 220), @('crdr_rules', 200), @('modifiedon', 130))
$assessCols = @(@('crdr_name', 280), @('crdr_estateimpact', 100), @('crdr_overrideimpact', 100), @('crdr_genericimpact', 100), @('crdr_nature', 130), @('crdr_affectedcount', 80), @('crdr_source', 90), @('crdr_assessedon', 130))
$openExposure = "<condition attribute=`"crdr_status`" operator=`"in`"><value>$(Get-Opt 'exposurestatus' 'new')</value><value>$(Get-Opt 'exposurestatus' 'confirmed')</value></condition>"
$hzCond = { param($v)"<condition attribute=`"crdr_horizon`" operator=`"eq`" value=`"$(Get-Opt 'horizon' $v)`" />" }
$views = [ordered]@{
    'Active Signals'         = @{ entity = 'crdr_signal'; desc = 'All active signals, by horizon (Now, Imminent, Future) then key date.'; xml = New-ViewXml 'crdr_signal' 'crdr_signalid' $allCols @('crdr_horizon', 'crdr_keydate') $false '' }
    # Charts get their own unsorted view: a view's sort overrides the chart's (observed 2026-11-20).
    'Signals for charts'     = @{ entity = 'crdr_signal'; desc = 'All active signals, unsorted, so the dashboard charts keep their own order. Used by the Overview charts.'; xml = New-ViewXml 'crdr_signal' 'crdr_signalid' @(@('crdr_title', 450), @('crdr_horizon', 90), @('crdr_source', 160)) @() $false '' }
    'Now'                    = @{ entity = 'crdr_signal'; desc = 'Signals that need attention now: open incidents and advisories, and Message Center actions due within horizon_now_days or overdue (ADR 0007).'; xml = New-ViewXml 'crdr_signal' 'crdr_signalid' $signalCols 'crdr_keydate' $false (& $hzCond 'now') }
    'Imminent'               = @{ entity = 'crdr_signal'; desc = 'Signals coming soon: Message Center actions within horizon_imminent_days, recent plan-for-change posts, roadmap items rolling out or due soon (ADR 0007).'; xml = New-ViewXml 'crdr_signal' 'crdr_signalid' $signalCols 'crdr_keydate' $false (& $hzCond 'imminent') }
    'Future'                 = @{ entity = 'crdr_signal'; desc = 'Everything else, including resolved incidents.'; xml = New-ViewXml 'crdr_signal' 'crdr_signalid' $signalCols 'crdr_keydate' $true (& $hzCond 'future') }
    'Recent collection runs' = @{ entity = 'crdr_collectionrun'; desc = 'Collector runs, newest first, with access tier and gaps.'; xml = New-ViewXml 'crdr_collectionrun' 'crdr_collectionrunid' @(@('crdr_name', 420), @('crdr_collector', 130), @('crdr_accesstier', 100), @('crdr_itemcount', 90), @('crdr_gaps', 300)) 'crdr_startedon' $true '' }
    # Phase 2 demo (ADR 0008): every app, flow and agent with its source label; fingerprints carry the evidence.
    # Default view for Assets: live and fixture only; the synthetic estate (hundreds of rows) has its own view (spec §15.2).
    'Estate assets'          = @{ entity = 'crdr_asset'; default = $true; desc = 'Every collected app, flow and agent in the tenant (live, plus fixtures labelled as such), by type, with environment and source.'; xml = New-ViewXml 'crdr_asset' 'crdr_assetid' $assetCols @('crdr_resourcetype', 'crdr_name') $false "<condition attribute=`"crdr_source`" operator=`"ne`" value=`"$(Get-Opt 'assetsource' 'synthetic')`" />" }
    'Synthetic assets'       = @{ entity = 'crdr_asset'; desc = 'The generated synthetic estate (source = synthetic), for demos only. Never mixed with live assets in a rating.'; xml = New-ViewXml 'crdr_asset' 'crdr_assetid' ($assetCols[0..3] + @(, @('crdr_syntheticorg', 200))) @('crdr_resourcetype', 'crdr_name') $false "<condition attribute=`"crdr_source`" operator=`"eq`" value=`"$(Get-Opt 'assetsource' 'synthetic')`" />" }
    'Asset fingerprints'     = @{ entity = 'crdr_assetfingerprint'; desc = 'Facets of an asset with the evidence for each.'; xml = New-ViewXml 'crdr_assetfingerprint' 'crdr_assetfingerprintid' @(@('crdr_name', 260), @('crdr_evidence', 600)) 'crdr_name' $false '' }
    # Phase 3 review queue (ADR 0009): fingerprints below fingerprint_confidence_threshold wait here; only accepted ones match.
    'Fingerprints to review' = @{ entity = 'crdr_signalfingerprint'; desc = 'Signal fingerprints the LLM was unsure of (confidence below fingerprint_confidence_threshold). Open one and set Status to Accepted or Rejected; only accepted fingerprints are matched.'; xml = New-ViewXml 'crdr_signalfingerprint' 'crdr_signalfingerprintid' @(@('crdr_name', 240), @('sig.crdr_externalid', 110), @('crdr_signal', 300), @('crdr_group', 60), @('crdr_confidence', 90), @('crdr_reason', 500)) 'crdr_confidence' $false "<condition attribute=`"crdr_status`" operator=`"eq`" value=`"$(Get-Opt 'fingerprintstatus' 'review')`" />" }
    'Signal fingerprints'    = @{ entity = 'crdr_signalfingerprint'; default = $true; desc = 'Every signal fingerprint: LLM and manual, accepted, in review and rejected.'; xml = New-ViewXml 'crdr_signalfingerprint' 'crdr_signalfingerprintid' @(@('crdr_name', 240), @('sig.crdr_externalid', 110), @('crdr_signal', 280), @('crdr_group', 60), @('crdr_extractedby', 90), @('crdr_confidence', 90), @('crdr_status', 90), @('crdr_reason', 400)) @('crdr_group', 'crdr_name') $false '' }
    'Fingerprints of a signal' = @{ entity = 'crdr_signalfingerprint'; desc = 'Used by the signal form: the fingerprint groups, with who extracted each facet and its review status.'; xml = New-ViewXml 'crdr_signalfingerprint' 'crdr_signalfingerprintid' @(@('crdr_group', 60), @('crdr_name', 240), @('crdr_extractedby', 90), @('crdr_confidence', 90), @('crdr_status', 90), @('crdr_reason', 400)) @('crdr_group', 'crdr_name') $false '' }
    'Open exposures'         = @{ entity = 'crdr_exposure'; default = $true; desc = 'Exposures that still match and have not been dismissed (New or Confirmed), every source.'; xml = New-ViewXml 'crdr_exposure' 'crdr_exposureid' $exposureCols @('crdr_source', 'crdr_name') $false $openExposure }
    'Live exposures'         = @{ entity = 'crdr_exposure'; desc = 'Open exposures in the real tenant only (source = live). Never mixed with fixture or synthetic exposures.'; xml = New-ViewXml 'crdr_exposure' 'crdr_exposureid' $exposureCols 'crdr_name' $false ($openExposure + "<condition attribute=`"crdr_source`" operator=`"eq`" value=`"$(Get-Opt 'assetsource' 'live')`" />") }
    # Phase 4 (ADR 0010): ratings per signal and source; the override, when set, is the rating that counts.
    'Assessments'            = @{ entity = 'crdr_assessment'; default = $true; desc = 'Every assessment, highest estate impact first. Override, when set, replaces the estate impact.'; xml = New-ViewXml 'crdr_assessment' 'crdr_assessmentid' $assessCols 'crdr_estateimpact' $true '' }
    'Live assessments'       = @{ entity = 'crdr_assessment'; desc = 'Assessments of the real tenant only (source = live).'; xml = New-ViewXml 'crdr_assessment' 'crdr_assessmentid' $assessCols 'crdr_estateimpact' $true "<condition attribute=`"crdr_source`" operator=`"eq`" value=`"$(Get-Opt 'assetsource' 'live')`" />" }
    'Overridden assessments' = @{ entity = 'crdr_assessment'; desc = 'Assessments a person has overridden, with the reason: calibration data for the rules and the prompt (spec section 6).'; xml = New-ViewXml 'crdr_assessment' 'crdr_assessmentid' @(@('crdr_name', 260), @('crdr_estateimpact', 100), @('crdr_overrideimpact', 110), @('crdr_overridereason', 400), @('crdr_overriddenby', 150), @('crdr_overriddenon', 130)) 'crdr_overriddenon' $true "<condition attribute=`"crdr_overrideimpact`" operator=`"not-null`" />" }
    'Assessments of a signal' = @{ entity = 'crdr_assessment'; desc = 'Used by the signal form: the rating per source.'; xml = New-ViewXml 'crdr_assessment' 'crdr_assessmentid' @(@('crdr_source', 90), @('crdr_estateimpact', 100), @('crdr_overrideimpact', 100), @('crdr_genericimpact', 100), @('crdr_nature', 130), @('crdr_affectedcount', 80)) 'crdr_source' $false '' }
    # ADR 0015: the watch list. Topics, and the signals on the list (watched by a topic or by hand).
    'Watch list'             = @{ entity = 'crdr_watch'; default = $true; desc = 'Watch list topics: a new or changed signal whose title or summary matches one goes on the watch list and raises a card.'; xml = New-ViewXml 'crdr_watch' 'crdr_watchid' @(@('crdr_name', 240), @('crdr_active', 70), @('crdr_anyof', 220), @('crdr_alsooneof', 300), @('crdr_ignorephrases', 200), @('crdr_products', 160)) 'crdr_name' $false '' }
    'Watched signals'        = @{ entity = 'crdr_signal'; desc = 'Signals on the watch list: any change to them raises a card (ADR 0015).'; xml = New-ViewXml 'crdr_signal' 'crdr_signalid' @(@('crdr_title', 420), @('crdr_externalid', 110), @('crdr_watch', 200), @('crdr_watchedon', 130), @('crdr_datelabel', 200), @('crdr_keydate', 110), @('crdr_lastchanged', 130)) 'crdr_lastchanged' $true "<condition attribute=`"crdr_watched`" operator=`"eq`" value=`"1`" />" }
    'Exposures of a signal'  = @{ entity = 'crdr_exposure'; desc = 'Used by the signal form: every exposure of the signal, whatever its status, by source.'; xml = New-ViewXml 'crdr_exposure' 'crdr_exposureid' @(@('crdr_name', 320), @('crdr_source', 90), @('crdr_status', 130), @('crdr_matchedfacets', 220)) @('crdr_source', 'crdr_name') $false '' }
}
$palette = '91,151,213; 237,125,49; 160,116,166; 255,192,0; 68,114,196; 112,173,71; 37,94,145; 158,72,14; 99,99,99; 153,115,0; 38,68,120; 67,104,43'
$columnXml = "<Chart Palette=`"None`" PaletteCustomColors=`"$palette`"><Series><Series ChartType=`"Column`" IsValueShownAsLabel=`"True`" Font=`"{0}, 9.5px`" LabelForeColor=`"59, 59, 59`" CustomProperties=`"PointWidth=0.75, MaxPixelPointWidth=40`"></Series></Series><ChartAreas><ChartArea BorderColor=`"White`" BorderDashStyle=`"Solid`"><AxisY LabelAutoFitMinFontSize=`"8`" TitleForeColor=`"59, 59, 59`" TitleFont=`"{0}, 10.5px`" LineColor=`"165, 172, 181`" IntervalAutoMode=`"VariableCount`"><MajorGrid LineColor=`"239, 242, 246`" /><MajorTickMark LineColor=`"165, 172, 181`" /><LabelStyle Font=`"{0}, 10.5px`" ForeColor=`"59, 59, 59`" /></AxisY><AxisX LabelAutoFitMinFontSize=`"8`" TitleForeColor=`"59, 59, 59`" TitleFont=`"{0}, 10.5px`" LineColor=`"165, 172, 181`" IntervalAutoMode=`"VariableCount`"><MajorTickMark LineColor=`"165, 172, 181`" /><MajorGrid LineColor=`"Transparent`" /><LabelStyle Font=`"{0}, 10.5px`" ForeColor=`"59, 59, 59`" /></AxisX></ChartArea></ChartAreas><Titles><Title Alignment=`"TopLeft`" DockingOffset=`"-3`" Font=`"{0}, 13px`" ForeColor=`"59, 59, 59`"></Title></Titles></Chart>"
$pieXml = "<Chart Palette=`"None`" PaletteCustomColors=`"$palette`"><Series><Series ShadowOffset=`"0`" IsValueShownAsLabel=`"true`" ChartType=`"Pie`" Font=`"{0}, 9.5px`" LabelForeColor=`"59, 59, 59`" CustomProperties=`"PieLabelStyle=Inside, PieDrawingStyle=Default`"><SmartLabelStyle Enabled=`"True`" /></Series></Series><ChartAreas><ChartArea><Area3DStyle Enable3D=`"false`" /></ChartArea></ChartAreas><Legends><Legend Alignment=`"Center`" LegendStyle=`"Table`" Docking=`"right`" IsEquallySpacedItems=`"True`" Font=`"{0}, 11px`" ShadowColor=`"0, 0, 0, 0`" ForeColor=`"59, 59, 59`" /></Legends><Titles><Title Alignment=`"TopLeft`" DockingOffset=`"-3`" Font=`"{0}, 13px`" ForeColor=`"0, 0, 0`"></Title></Titles></Chart>"
function New-ChartData([string]$groupBy, [string]$seriesBy) {
    $series = $seriesBy ? "<attribute groupby=`"true`" alias=`"series_column`" name=`"$seriesBy`" />" : ''
    # Horizon reads near to far, left to right (Simon, 2026-11-20). Aggregate fetches order a choice by its label, not its
    # value (observed 2026-11-20); descending labels give Now, Imminent, Future, asserted against schema order below.
    $order = if ($groupBy -eq 'crdr_horizon') { "<order alias=`"groupby_column`" descending=`"true`" />" } else { '' }
    # The renderer colours series by position in its own palette, not by value. The pie lists sources by label, so the
    # stacked chart's series are sorted by label too: each source then has the same colour in both charts (Simon, 2026-11-22).
    if ($seriesBy) { $order += "<order alias=`"series_column`" />" }
    "<datadefinition><fetchcollection><fetch mapping=`"logical`" aggregate=`"true`"><entity name=`"crdr_signal`"><attribute groupby=`"true`" alias=`"groupby_column`" name=`"$groupBy`" />$series<attribute alias=`"aggregate_column`" name=`"crdr_signalid`" aggregate=`"count`" />$order</entity></fetch></fetchcollection><categorycollection><category><measurecollection><measure alias=`"aggregate_column`" /></measurecollection></category></categorycollection></datadefinition>"
}
$hzLabels = @($schema.choices.horizon | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase($_) })
if ((@($hzLabels | Sort-Object -Descending) -join ',') -ne ($hzLabels -join ',')) { throw "Horizon labels ($($hzLabels -join ', ')) no longer sort descending into near-to-far order; the Signals by horizon chart needs a different sort." }
$stackedXml = $columnXml.Replace('ChartType="Column"', 'ChartType="StackedColumn"').Replace('</ChartAreas>', '</ChartAreas><Legends><Legend Alignment="Center" LegendStyle="Table" Docking="bottom" Font="{0}, 11px" ShadowColor="0, 0, 0, 0" ForeColor="59, 59, 59" /></Legends>')
if ($stackedXml -notmatch 'StackedColumn') { throw 'Stacked chart template did not apply.' }
$charts = [ordered]@{
    'Signals by horizon' = @{ data = New-ChartData 'crdr_horizon' 'crdr_source'; presentation = $stackedXml; desc = 'Count of signals per horizon, stacked by source. Select a segment to drill down by another column.' }
    'Signals by source'  = @{ data = New-ChartData 'crdr_source'; presentation = $pieXml; desc = 'Count of signals per source.' }
}

# ---------- plan ----------
$steps = [System.Collections.Generic.List[object]]::new()
function Add-Step([string]$area, [string]$name, [string]$status, [hashtable]$data, [scriptblock]$action) { $steps.Add([pscustomobject]@{ Area = $area; Name = $name; Status = $status; Data = $data; Action = $action }) }
$ids = @{}

foreach ($n in $views.Keys) {
    $v = $views[$n]
    $cur = Get-One "savedqueries?`$select=savedqueryid,fetchxml,layoutxml,isdefault&`$filter=returnedtypecode eq '$($v.entity)' and name eq '$n' and querytype eq 0"
    if ($cur) { $ids["view:$n"] = $cur.savedqueryid }
    $isDefault = [bool]$v['default']
    $status = if (-not $cur) { 'create' } elseif ($cur.fetchxml -ne $v.xml.fetch -or $cur.layoutxml -ne $v.xml.layout -or ($isDefault -and -not $cur.isdefault)) { 'update' } else { 'exists' }
    Add-Step 'View' "$n ($($v.entity))$(if ($isDefault) { ', default' })" $status @{ n = $n; v = $v; cur = $cur } {
        param($StepData); $v = $StepData['v']; $cur = $StepData['cur']
        $body = @{ fetchxml = $v.xml.fetch; layoutxml = $v.xml.layout; description = $v.desc }
        if ($v['default']) {
            $body.isdefault = $true
            # Setting a new default doesn't clear the old one (observed 2026-11-20), so unset the others first.
            foreach ($o in @((Invoke-Dv -Path "savedqueries?`$select=savedqueryid,name&`$filter=returnedtypecode eq '$($v.entity)' and querytype eq 0 and isdefault eq true and name ne '$($StepData['n'])'").value)) {
                Invoke-Dv -Method PATCH -Path "savedqueries($($o.savedqueryid))" -Body @{ isdefault = $false } | Out-Null
            }
        }
        if ($cur) { Invoke-Dv -Method PATCH -Path "savedqueries($($cur.savedqueryid))" -Body $body | Out-Null }
        else { $body += @{ name = $StepData['n']; returnedtypecode = $v.entity; querytype = 0 }; if (-not $body.ContainsKey('isdefault')) { $body.isdefault = $false }; $script:ids["view:$($StepData['n'])"] = (Invoke-Dv -Method POST -Path 'savedqueries' -Body $body -Extra $sol).savedqueryid }
    }
}
foreach ($n in $charts.Keys) {
    $c = $charts[$n]
    $cur = Get-One "savedqueryvisualizations?`$select=savedqueryvisualizationid,datadescription,presentationdescription&`$filter=primaryentitytypecode eq 'crdr_signal' and name eq '$n'"
    if ($cur) { $ids["chart:$n"] = $cur.savedqueryvisualizationid }
    $status = if (-not $cur) { 'create' } elseif ($cur.datadescription -ne $c.data -or $cur.presentationdescription -ne $c.presentation) { 'update' } else { 'exists' }
    Add-Step 'Chart' $n $status @{ n = $n; c = $c; cur = $cur } {
        param($StepData); $c = $StepData['c']; $cur = $StepData['cur']
        $body = @{ datadescription = $c.data; presentationdescription = $c.presentation; description = $c.desc }
        if ($cur) { Invoke-Dv -Method PATCH -Path "savedqueryvisualizations($($cur.savedqueryvisualizationid))" -Body $body | Out-Null }
        else { $body += @{ name = $StepData['n']; primaryentitytypecode = 'crdr_signal'; isdefault = $false }; $script:ids["chart:$($StepData['n'])"] = (Invoke-Dv -Method POST -Path 'savedqueryvisualizations' -Body $body -Extra $sol).savedqueryvisualizationid }
    }
}

$dashName = 'Change Radar overview'
$dash = Get-One "systemforms?`$select=formid&`$filter=type eq 0 and name eq '$dashName'"
$activeView = (Get-One "savedqueries?`$select=savedqueryid&`$filter=returnedtypecode eq 'crdr_signal' and name eq 'Active Signals' and querytype eq 0").savedqueryid
Add-Step 'Dashboard' $dashName ($dash ? 'update' : 'create') @{ dash = $dash; activeView = $activeView } {
    param($StepData)
    $g = { "{$([guid]::NewGuid())}" }
    function Cell([string]$label, [string]$entity, [string]$viewId, [string]$chartId, [int]$colspan, [string]$ctl) {
        $mode = $chartId ? 'Chart' : 'Grid'
        $vis = $chartId ? "<VisualizationId>{$chartId}</VisualizationId><IsUserChart>false</IsUserChart><EnableChartPicker>false</EnableChartPicker>" : ''
        "<cell id=`"$(& $g)`" showlabel=`"true`" rowspan=`"12`" colspan=`"$colspan`" auto=`"false`"><labels><label description=`"$(Esc $label)`" languagecode=`"$lcid`" /></labels><control id=`"$ctl`" classid=`"{E7A81278-8635-4d9e-8D4D-59480B391C5B}`"><parameters><TargetEntityType>$entity</TargetEntityType><ViewId>{$viewId}</ViewId><IsUserView>false</IsUserView><RelationshipName /><AutoExpand>Fixed</AutoExpand><EnableQuickFind>false</EnableQuickFind><EnableViewPicker>false</EnableViewPicker><EnableJumpBar>false</EnableJumpBar><ChartGridMode>$mode</ChartGridMode>$vis<RecordsPerPage>10</RecordsPerPage></parameters></control></cell>"
    }
    $rows = @(
        "<row>$(Cell 'Signals by horizon' 'crdr_signal' $script:ids['view:Signals for charts'] $script:ids['chart:Signals by horizon'] 1 'chart_horizon')$(Cell 'Signals by source' 'crdr_signal' $script:ids['view:Signals for charts'] $script:ids['chart:Signals by source'] 1 'chart_source')</row>"
        "<row>$(Cell 'Now' 'crdr_signal' $script:ids['view:Now'] '' 2 'list_now')</row>"
        "<row>$(Cell 'Imminent' 'crdr_signal' $script:ids['view:Imminent'] '' 2 'list_imminent')</row>"
        "<row>$(Cell 'Recent collection runs' 'crdr_collectionrun' $script:ids['view:Recent collection runs'] '' 2 'list_runs')</row>"
    ) -join ''
    $formxml = "<form><tabs><tab name=`"tab_overview`" verticallayout=`"true`" id=`"$(& $g)`"><labels><label description=`"Overview`" languagecode=`"$lcid`" /></labels><columns><column width=`"100%`"><sections><section name=`"section_overview`" showlabel=`"false`" showbar=`"false`" columns=`"11`" id=`"$(& $g)`"><labels><label description=`"Overview`" languagecode=`"$lcid`" /></labels><rows>$rows</rows></section></sections></column></columns></tab></tabs></form>"
    $body = @{ formxml = $formxml; description = 'Change Radar at a glance: signals by horizon and source, what needs attention now and soon, and collector health.' }
    if ($StepData['dash']) { Invoke-Dv -Method PATCH -Path "systemforms($($StepData['dash'].formid))" -Body $body | Out-Null; $script:ids['dashboard'] = $StepData['dash'].formid }
    else { $body += @{ name = $dashName; type = 0; objecttypecode = 'none'; isdefault = $false }; $script:ids['dashboard'] = (Invoke-Dv -Method POST -Path 'systemforms' -Body $body -Extra $sol).formid }
}

$assetForm = Get-One "systemforms?`$select=formid,formxml&`$filter=objecttypecode eq 'crdr_asset' and type eq 2"
Add-Step 'Form' 'Asset main form: details and Fingerprints list (crdr_asset)' 'update' @{ form = $assetForm } {
    param($StepData)
    $g = { "{$([guid]::NewGuid())}" }
    $cls = @{ text = '{4273EDBD-AC1D-40d3-9FB2-095C621B552D}'; choice = '{3EF39988-22BB-4f0b-BBBE-64B5A3748AEE}'; date = '{5B773807-9FB2-42db-97C3-7A91EFF8ADFF}' }
    $fieldRow = { param($col, $label, $kind) "<row><cell id=`"$(& $g)`"><labels><label description=`"$(Esc $label)`" languagecode=`"$lcid`" /></labels><control id=`"$col`" classid=`"$($cls[$kind])`" datafieldname=`"$col`" disabled=`"true`" /></cell></row>" }
    $fields = @(@('crdr_name', 'Name', 'text'), @('crdr_resourcetype', 'Resource type', 'text'), @('crdr_environmentname', 'Environment', 'text'), @('crdr_environmenttype', 'Environment type', 'choice'),
        @('crdr_source', 'Source', 'choice'), @('crdr_syntheticorg', 'Synthetic or fixture organisation', 'text'), @('crdr_solutionuniquename', 'Solution', 'text'),
        @('crdr_componentid', 'Component ID', 'text'), @('crdr_sourceid', 'Source ID', 'text'), @('crdr_lastseen', 'Last seen', 'date'))
    $rowsXml = ($fields | ForEach-Object { & $fieldRow $_[0] $_[1] $_[2] }) -join ''
    $grid = "<row><cell id=`"$(& $g)`" showlabel=`"true`" rowspan=`"10`" colspan=`"1`" auto=`"false`"><labels><label description=`"Fingerprints`" languagecode=`"$lcid`" /></labels>" +
        "<control id=`"fingerprints`" classid=`"{E7A81278-8635-4d9e-8D4D-59480B391C5B}`" indicationOfSubgrid=`"true`"><parameters><ViewId>{$($script:ids['view:Asset fingerprints'])}</ViewId><IsUserView>false</IsUserView>" +
        "<RelationshipName>crdr_asset_assetfingerprint_asset</RelationshipName><TargetEntityType>crdr_assetfingerprint</TargetEntityType><AutoExpand>Fixed</AutoExpand><EnableQuickFind>false</EnableQuickFind>" +
        "<EnableViewPicker>false</EnableViewPicker><EnableJumpBar>false</EnableJumpBar><ChartGridMode>Grid</ChartGridMode><VisualizationId /><IsUserChart>false</IsUserChart><EnableChartPicker>false</EnableChartPicker><RecordsPerPage>25</RecordsPerPage></parameters></control></cell></row>"
    $section = { param($name, $label, $rows) "<section name=`"$name`" showlabel=`"true`" showbar=`"false`" id=`"$(& $g)`" IsUserDefined=`"0`" columns=`"1`"><labels><label description=`"$label`" languagecode=`"$lcid`" /></labels><rows>$rows</rows></section>" }
    $formxml = "<form><tabs><tab name=`"tab_asset`" verticallayout=`"true`" id=`"$(& $g)`" IsUserDefined=`"1`"><labels><label description=`"Asset`" languagecode=`"$lcid`" /></labels><columns><column width=`"40%`"><sections>$(& $section 'sec_details' 'Details' $rowsXml)</sections></column><column width=`"60%`"><sections>$(& $section 'sec_fingerprints' 'Facets and evidence' $grid)</sections></column></columns></tab></tabs></form>"
    Invoke-Dv -Method PATCH -Path "systemforms($($StepData['form'].formid))" -Body @{ formxml = $formxml } | Out-Null
    $script:ids['assetForm'] = $StepData['form'].formid
}

# Quick find: the Web API rejects any fetchxml change to a quick-find view (querytype 4) with 400 0x80040216 "An
# unexpected error occurred", by PATCH or PUT, even unchanged (observed 2026-11-21). Find columns are set in the maker
# portal instead (docs/decisions/0009, step 6) and travel with the solution export: signals search External ID and
# Products as well as Title; signal fingerprints search Value and Signal.

# Form scripts (web resources), from solutions/design/webresources. Created in the solution, updated in place.
foreach ($ws in @(@{ name = 'crdr_/scripts/assessment.js'; file = 'assessment.js'; display = 'Change Radar assessment form' })) {
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'webresources' $ws.file)))
    $cur = Get-One "webresourceset?`$select=webresourceid,content&`$filter=name eq '$($ws.name)'"
    Add-Step 'Script' $ws.name $(if (-not $cur) { 'create' } elseif ($cur.content -ne $content) { 'update' } else { 'exists' }) @{ ws = $ws; content = $content; cur = $cur } {
        param($StepData)
        if ($StepData['cur']) { Invoke-Dv -Method PATCH -Path "webresourceset($($StepData['cur'].webresourceid))" -Body @{ content = $StepData['content'] } | Out-Null }
        else { Invoke-Dv -Method POST -Path 'webresourceset' -Extra ($sol + @{ Prefer = 'return=minimal' }) -Body @{ name = $StepData['ws'].name; displayname = $StepData['ws'].display; webresourcetype = 3; content = $StepData['content'] } | Out-Null }
    }
}

# Phase 3 forms (ADR 0009). Field spec: column, label, kind, editable. Collector- and flow-owned columns are read-only;
# reviewers edit fingerprint and exposure Status, and fill in every fingerprint column when adding a manual one.
$fieldCls = @{ text = '{4273EDBD-AC1D-40d3-9FB2-095C621B552D}'; choice = '{3EF39988-22BB-4f0b-BBBE-64B5A3748AEE}'; date = '{5B773807-9FB2-42db-97C3-7A91EFF8ADFF}'
    lookup = '{270BD3DB-D9AF-4782-9025-509E298DEC0A}'; decimal = '{C3EFE0C3-0EC6-42be-8349-CBD9079DFD8E}'; memo = '{E0DECE4B-6FC8-4a8f-A065-082708572369}'
    bool = '{67FAC785-CD58-4f9f-ABB3-4B7DDC6ED5ED}'; int = '{C6D124CA-7EDA-4a60-AEA9-7FB8D318B68F}'; url = '{71716B6C-711E-476c-8AB8-5D11542BFB47}' }
$fieldCls['richtext'] = $fieldCls['memo']   # a memo shown with the Rich Text Editor control (renders stored HTML; read-only here)
function New-FormXml([object[]]$Tabs) {
    # Tabs: @{ name; label; columns = @( @{ width; sections = @( @{ name; label; fields = @(,@(col,label,kind,editable)); grids = @(@{ id; label; view; rel; entity; rows }) } ) } ) }
    $g = { "{$([guid]::NewGuid())}" }
    $rte = [Collections.Generic.List[object]]::new()
    $tabXml = foreach ($t in $Tabs) {
        $cols = foreach ($c in $t.columns) {
            $secs = foreach ($s in $c.sections) {
                $rows = @(foreach ($f in @($s['fields'] | Where-Object { $_ })) {
                        $uid = if ($f[2] -eq 'richtext') { $u = & $g; $rte.Add(@{ uid = $u; col = $f[0] }); " uniqueid=`"$u`"" } else { '' }
                        "<row><cell id=`"$(& $g)`"$(if ($f[2] -in 'memo', 'richtext') { ' rowspan="8"' })><labels><label description=`"$(Esc $f[1])`" languagecode=`"$lcid`" /></labels><control id=`"$($f[0])`" classid=`"$($fieldCls[$f[2]])`" datafieldname=`"$($f[0])`" disabled=`"$(([bool]-not $f[3]).ToString().ToLower())`"$uid /></cell></row>"
                        if ($f[2] -in 'memo', 'richtext') { 1..7 | ForEach-Object { '<row />' } }
                    }) + @(foreach ($gr in @($s['grids'] | Where-Object { $_ })) {
                        "<row><cell id=`"$(& $g)`" showlabel=`"true`" rowspan=`"$($gr.rows)`" colspan=`"1`" auto=`"false`"><labels><label description=`"$(Esc $gr.label)`" languagecode=`"$lcid`" /></labels>" +
                        "<control id=`"$($gr.id)`" classid=`"{E7A81278-8635-4d9e-8D4D-59480B391C5B}`" indicationOfSubgrid=`"true`"><parameters><ViewId>{$($script:ids["view:$($gr.view)"])}</ViewId><IsUserView>false</IsUserView>" +
                        "<RelationshipName>$($gr.rel)</RelationshipName><TargetEntityType>$($gr.entity)</TargetEntityType><AutoExpand>Fixed</AutoExpand><EnableQuickFind>false</EnableQuickFind>" +
                        "<EnableViewPicker>false</EnableViewPicker><EnableJumpBar>false</EnableJumpBar><ChartGridMode>Grid</ChartGridMode><VisualizationId /><IsUserChart>false</IsUserChart><EnableChartPicker>false</EnableChartPicker><RecordsPerPage>$($gr.rows * 2)</RecordsPerPage></parameters></control></cell></row>"
                        1..($gr.rows - 1) | ForEach-Object { '<row />' }
                    })
                "<section name=`"$($s.name)`" showlabel=`"true`" showbar=`"false`" id=`"$(& $g)`" IsUserDefined=`"0`" columns=`"1`"><labels><label description=`"$(Esc $s.label)`" languagecode=`"$lcid`" /></labels><rows>$($rows -join '')</rows></section>"
            }
            "<column width=`"$($c.width)`"><sections>$($secs -join '')</sections></column>"
        }
        "<tab name=`"$($t.name)`" verticallayout=`"true`" id=`"$(& $g)`" IsUserDefined=`"1`"><labels><label description=`"$(Esc $t.label)`" languagecode=`"$lcid`" /></labels><columns>$($cols -join '')</columns></tab>"
    }
    # Rich text fields: the Rich Text Editor control on web (0), phone (1) and tablet (2), bound by the control's uniqueid.
    $descs = foreach ($r in $rte) {
        $p = "<parameters><datafieldname>$($r.col)</datafieldname></parameters>"
        "<controlDescription forControl=`"$($r.uid)`"><customControl id=`"$($fieldCls['memo'])`">$p</customControl>" +
        ((0..2 | ForEach-Object { "<customControl formFactor=`"$_`" name=`"MscrmControls.RichTextEditor.RichTextEditorControl`">$p</customControl>" }) -join '') + '</controlDescription>'
    }
    "<form><tabs>$($tabXml -join '')</tabs>$(if ($rte.Count) { "<controlDescriptions>$($descs -join '')</controlDescriptions>" })</form>"
}
$forms = [ordered]@{
    crdr_signal            = @{ desc = 'Signal main form: details, fingerprints and exposures, and the original text'; tabs = {
            @(@{ name = 'tab_signal'; label = 'Signal'; columns = @(
                        @{ width = '40%'; sections = @(@{ name = 'sec_details'; label = 'Details'; fields = @(
                                        @('crdr_title', 'Title', 'text', $false), @('crdr_source', 'Source', 'choice', $false), @('crdr_externalid', 'External ID', 'text', $false),
                                        @('crdr_horizon', 'Horizon', 'choice', $false), @('crdr_datelabel', 'Date', 'text', $false), @('crdr_keydate', 'Key date', 'date', $false),
                                        @('crdr_products', 'Products', 'text', $false), @('crdr_actionrequired', 'Action required', 'bool', $false), @('crdr_url', 'Link', 'url', $false),
                                        @('crdr_firstseen', 'First seen', 'date', $false), @('crdr_lastchanged', 'Last changed', 'date', $false), @('crdr_fingerprintedon', 'Fingerprinted on', 'date', $false)) }
                                @{ name = 'sec_watch'; label = 'Watch list (changes to a watched signal raise a card)'; fields = @(
                                        @('crdr_watched', 'Watched', 'bool', $true), @('crdr_watch', 'Watched because of', 'lookup', $false), @('crdr_watchedon', 'Watched on', 'date', $false)) }) }
                        @{ width = '60%'; sections = @(
                                @{ name = 'sec_fingerprints'; label = 'Fingerprint (groups are alternatives; facets in a group must all hold)'; grids = @(@{ id = 'fingerprints'; label = 'Fingerprints'; view = 'Fingerprints of a signal'; rel = 'crdr_signal_signalfingerprint_signal'; entity = 'crdr_signalfingerprint'; rows = 8 }) }
                                @{ name = 'sec_assessments'; label = 'Assessment (estate rating per source)'; grids = @(@{ id = 'assessments'; label = 'Assessments'; view = 'Assessments of a signal'; rel = 'crdr_signal_assessment_signal'; entity = 'crdr_assessment'; rows = 4 }) }
                                @{ name = 'sec_exposures'; label = 'Exposures'; grids = @(@{ id = 'exposures'; label = 'Exposures'; view = 'Exposures of a signal'; rel = 'crdr_signal_exposure_signal'; entity = 'crdr_exposure'; rows = 8 }) }) }) }
                @{ name = 'tab_text'; label = 'Text'; columns = @(@{ width = '100%'; sections = @(@{ name = 'sec_readable'; label = 'Summary'; fields = @(, @('crdr_summarytext', 'Summary', 'memo', $false)) }, @{ name = 'sec_text'; label = 'As collected (HTML for Message Center posts and blogs)'; fields = @(, @('crdr_summary', 'As collected', 'memo', $false)) }) }) }) } }
    crdr_signalfingerprint = @{ desc = 'Signal fingerprint main form: review (set Status) or add a manual fingerprint'; tabs = {
            @(@{ name = 'tab_fingerprint'; label = 'Fingerprint'; columns = @(
                        @{ width = '50%'; sections = @(@{ name = 'sec_review'; label = 'Review'; fields = @(
                                        @('crdr_status', 'Status (only Accepted fingerprints are matched)', 'choice', $true), @('crdr_signal', 'Signal', 'lookup', $true),
                                        @('crdr_extractedby', 'Extracted by (Manual for one you add)', 'choice', $true), @('crdr_confidence', 'Confidence', 'decimal', $false),
                                        @('crdr_reason', 'Reason', 'text', $true), @('modifiedby', 'Modified by', 'lookup', $false), @('modifiedon', 'Modified on', 'date', $false)) }) }
                        @{ width = '50%'; sections = @(@{ name = 'sec_facet'; label = 'Facet'; fields = @(
                                        @('crdr_group', 'Group (same group = AND; manual groups M1, M2...)', 'text', $true), @('crdr_facet', 'Facet', 'choice', $true),
                                        @('crdr_value', 'Value (from the vocabulary)', 'text', $true), @('crdr_name', 'Name (facet: value)', 'text', $true)) }) }) }) } }
    crdr_watch             = @{ desc = 'Watch main form: the words that put a signal on the watch list (ADR 0015)'; tabs = {
            @(@{ name = 'tab_watch'; label = 'Watch'; columns = @(
                        @{ width = '60%'; sections = @(@{ name = 'sec_words'; label = 'Words (separate with semicolons; whole words, any case)'; fields = @(
                                        @('crdr_name', 'Name', 'text', $true), @('crdr_active', 'Active', 'bool', $true),
                                        @('crdr_anyof', 'Any of these words (one must appear)', 'text', $true), @('crdr_alsooneof', 'And one of these words (optional)', 'text', $true),
                                        @('crdr_ignorephrases', 'Ignore these phrases (removed before checking, e.g. Windows Autopilot)', 'text', $true), @('crdr_products', 'Products (optional; one must be in the signal''s products)', 'text', $true)) }) }
                        @{ width = '40%'; sections = @(@{ name = 'sec_about'; label = 'About'; fields = @(, @('crdr_description', 'Description', 'memo', $true)) }) }) }) } }
    crdr_exposure          = @{ desc = 'Exposure main form: what matched and why; set Status to Confirmed or Dismissed'; tabs = {
            @(@{ name = 'tab_exposure'; label = 'Exposure'; columns = @(
                        @{ width = '40%'; sections = @(@{ name = 'sec_exposure'; label = 'Exposure'; fields = @(
                                        @('crdr_status', 'Status', 'choice', $true), @('crdr_signal', 'Signal', 'lookup', $false), @('crdr_asset', 'Asset', 'lookup', $false),
                                        @('crdr_tenantsetting', 'Tenant setting', 'lookup', $false), @('crdr_source', 'Source', 'choice', $false), @('crdr_group', 'Fingerprint group', 'text', $false),
                                        @('crdr_matchedfacets', 'Matched facets', 'text', $false), @('crdr_rules', 'Rules', 'text', $false), @('modifiedby', 'Modified by', 'lookup', $false), @('modifiedon', 'Modified on', 'date', $false)) }) }
                        @{ width = '60%'; sections = @(@{ name = 'sec_evidence'; label = 'Evidence'; fields = @(, @('crdr_evidencetext', 'Evidence', 'memo', $false)) }) }) }) } }
    crdr_assessment        = @{ desc = 'Assessment main form: rating and its parts, LLM rationale and action, override with a required reason'; script = 'crdr_/scripts/assessment.js'; onLoad = 'ChangeRadar.Assessment.onLoad'; tabs = {
            @(@{ name = 'tab_assessment'; label = 'Assessment'; columns = @(
                        @{ width = '40%'; sections = @(
                                @{ name = 'sec_override'; label = 'Override (replaces the estate impact; None dismisses it)'; fields = @(
                                        @('crdr_overrideimpact', 'Override impact', 'choice', $true), @('crdr_overridereason', 'Override reason (required with an override)', 'memo', $true),
                                        @('crdr_overriddenby', 'Override set or cleared by', 'lookup', $false), @('crdr_overriddenon', 'Override set or cleared on', 'date', $false)) }
                                @{ name = 'sec_rating'; label = 'Rating: generic impact + 1 production + 1 action within 30 days, capped'; fields = @(
                                        @('crdr_estateimpact', 'Estate impact', 'choice', $false), @('crdr_genericimpact', 'Generic impact (LLM)', 'choice', $false), @('crdr_nature', 'Nature (LLM)', 'choice', $false),
                                        @('crdr_productionbonus', 'Production bonus', 'bool', $false), @('crdr_actionbonus', 'Action bonus', 'bool', $false), @('crdr_affectedcount', 'Affected count', 'int', $false),
                                        @('crdr_unknownenvcount', 'Assets with unknown environment', 'int', $false), @('crdr_source', 'Source', 'choice', $false), @('crdr_signal', 'Signal', 'lookup', $false),
                                        @('crdr_assessedon', 'Assessed on', 'date', $false), @('crdr_model', 'Prompt', 'text', $false)) }) }
                        @{ width = '60%'; sections = @(
                                @{ name = 'sec_llm'; label = 'Assessment written by the LLM: an assessment, not fact'; fields = @(@('crdr_rationale', 'Rationale', 'memo', $false), @('crdr_recommendedaction', 'Recommended action', 'memo', $false)) }
                                @{ name = 'sec_summary'; label = 'What the prompt was told (no names leave the estate)'; fields = @(, @('crdr_exposuresummary', 'Estate summary', 'memo', $false)) }) }) }) } }
}
foreach ($e in $forms.Keys) {
    $f = Get-One "systemforms?`$select=formid&`$filter=objecttypecode eq '$e' and type eq 2 and name eq 'Information'"
    if (-not $f) { throw "No main form 'Information' on $e." }
    Add-Step 'Form' "$($forms[$e].desc) ($e)" 'update' @{ form = $f; spec = $forms[$e] } {
        param($StepData)
        $xml = New-FormXml (& $StepData['spec'].tabs)
        if ($StepData['spec']['script']) {
            # Form script: library plus an onload handler (it adds its own onchange handlers).
            $lib = $StepData['spec'].script
            $xml = $xml.Replace('</tabs></form>', "</tabs><formLibraries><Library name=`"$lib`" libraryUniqueId=`"{$([guid]::NewGuid())}`" /></formLibraries><events><event name=`"onload`" application=`"false`" active=`"false`"><Handlers><Handler functionName=`"$($StepData['spec'].onLoad)`" libraryName=`"$lib`" handlerUniqueId=`"{$([guid]::NewGuid())}`" enabled=`"true`" parameters=`"`" passExecutionContext=`"true`" /></Handlers></event></events></form>")
        }
        Invoke-Dv -Method PATCH -Path "systemforms($($StepData['form'].formid))" -Body @{ formxml = $xml } | Out-Null
    }
}

$app = Get-One "appmodules/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()?`$select=appmoduleid&`$filter=uniquename eq 'crdr_ChangeRadar'"
$sitemap = Get-One "sitemaps?`$select=sitemapid,sitemapxml&`$filter=sitemapnameunique eq 'crdr_ChangeRadar'"
Add-Step 'App' 'Change Radar (crdr_ChangeRadar), site map, components' ($app ? 'update' : 'create') @{ app = $app; sitemap = $sitemap } {
    param($StepData)
    $sub = { param($id, $attrs, $title) "<SubArea Id=`"$id`" $attrs Client=`"All,Outlook,OutlookLaptopClient,OutlookWorkstationClient,Web`" AvailableOffline=`"true`" PassParams=`"false`" Sku=`"All,OnPremise,Live,SPLA`"><Titles><Title LCID=`"$lcid`" Title=`"$title`" /></Titles></SubArea>" }
    # Generative pages (ADR 0012) are placed by the genpage upload (--add-to-sitemap) with an environment-specific page id.
    # Keep whatever page entries the current site map has, first in the group they are in (Radar for any other group),
    # so this rewrite never drops them or moves them to another group (both pages are in Radar today).
    $genPages = @{ group_radar = ''; group_review = '' }
    if ($StepData['sitemap'] -and $StepData['sitemap'].sitemapxml) {
        foreach ($g in [regex]::Matches($StepData['sitemap'].sitemapxml, '<Group\b[^>]*\bId="([^"]+)"[^>]*>(.*?)</Group>')) {
            $target = if ($genPages.ContainsKey($g.Groups[1].Value)) { $g.Groups[1].Value } else { 'group_radar' }
            $genPages[$target] += ([regex]::Matches($g.Groups[2].Value, '<SubArea[^>]*\bGenPageId="[^"]+"[^>]*>.*?</SubArea>') | ForEach-Object Value) -join ''
        }
    }
    $xml = "<SiteMap IntroducedVersion=`"7.0.0.0`"><Area Id=`"area_radar`" ShowGroups=`"true`" IntroducedVersion=`"7.0.0.0`"><Titles><Title LCID=`"$lcid`" Title=`"Change Radar`" /></Titles>" +
    "<Group Id=`"group_radar`" IsProfile=`"false`" IntroducedVersion=`"7.0.0.0`"><Titles><Title LCID=`"$lcid`" Title=`"Radar`" /></Titles>" + $genPages['group_radar'] +
    # The classic Overview dashboard was removed from the menu and the app on 2026-11-22 (Simon): the Radar page replaces it (ADR 0012).
    # Assessments is linked by Url (either form works). The played app's menu can lag a publish by over an hour (2026-11-21: 80 minutes, unaffected by hard refresh or publishing from the editor).
    (& $sub 'sub_signals' 'Entity="crdr_signal"' 'Signals') +
    (& $sub 'sub_watched' "Url=`"/main.aspx?pagetype=entitylist&amp;etn=crdr_signal&amp;viewid=$($script:ids['view:Watched signals'])&amp;viewtype=1039`"" 'Watched signals') + (& $sub 'sub_watchlist' 'Entity="crdr_watch"' 'Watch list') +
    (& $sub 'sub_exposures' 'Entity="crdr_exposure"' 'Exposures') + (& $sub 'sub_assessments' "Url=`"/main.aspx?pagetype=entitylist&amp;etn=crdr_assessment&amp;viewid=$($script:ids['view:Assessments'])&amp;viewtype=1039`"" 'Assessments') + '</Group>' +
    "<Group Id=`"group_review`" IsProfile=`"false`" IntroducedVersion=`"7.0.0.0`"><Titles><Title LCID=`"$lcid`" Title=`"Review`" /></Titles>" + $genPages['group_review'] +
    (& $sub 'sub_review' "Url=`"/main.aspx?pagetype=entitylist&amp;etn=crdr_signalfingerprint&amp;viewid=$($script:ids['view:Fingerprints to review'])&amp;viewtype=1039`"" 'Fingerprints to review') +
    (& $sub 'sub_fingerprints' 'Entity="crdr_signalfingerprint"' 'Signal fingerprints') + '</Group>' +
    "<Group Id=`"group_estate`" IsProfile=`"false`" IntroducedVersion=`"7.0.0.0`"><Titles><Title LCID=`"$lcid`" Title=`"Estate`" /></Titles>" +
    (& $sub 'sub_assets' 'Entity="crdr_asset"' 'Assets') + '</Group>' +   # opens the default view, Estate assets (a Url next to Entity was ignored)
    "<Group Id=`"group_operations`" IsProfile=`"false`" IntroducedVersion=`"7.0.0.0`"><Titles><Title LCID=`"$lcid`" Title=`"Operations`" /></Titles>" +
    (& $sub 'sub_runs' 'Entity="crdr_collectionrun"' 'Collection runs') + (& $sub 'sub_config' 'Entity="crdr_config"' 'Config') +
    (& $sub 'sub_settings' 'Entity="crdr_tenantsetting"' 'Tenant settings') + (& $sub 'sub_rules' 'Entity="crdr_rule"' 'Rules') + (& $sub 'sub_vocabulary' 'Entity="crdr_facetvalue"' 'Vocabulary') +
    # Feeds and Subscriptions (ADR 0022): configuration an admin changes, so they belong in the menu.
    (& $sub 'sub_feeds' 'Entity="crdr_feed"' 'Feeds') + (& $sub 'sub_subscriptions' 'Entity="crdr_subscription"' 'Subscriptions') + '</Group></Area></SiteMap>'
    $smId = if ($StepData['sitemap']) { Invoke-Dv -Method PATCH -Path "sitemaps($($StepData['sitemap'].sitemapid))" -Body @{ sitemapxml = $xml } | Out-Null; $StepData['sitemap'].sitemapid }
    else { (Invoke-Dv -Method POST -Path 'sitemaps' -Extra $sol -Body @{ sitemapname = 'Change Radar'; sitemapnameunique = 'crdr_ChangeRadar'; isappaware = $true; sitemapxml = $xml }).sitemapid }
    $appId = if ($StepData['app']) { $StepData['app'].appmoduleid } else {
        # Echoing a new app back (Prefer: return=representation) fails because it's unpublished, so create, then look it up.
        Invoke-Dv -Method POST -Path 'appmodules' -Extra ($sol + @{ Prefer = 'return=minimal' }) -Body @{ name = 'Change Radar'; uniquename = 'crdr_ChangeRadar'; description = 'What is changing in Power Platform and Copilot, and when. Phase 1: signals from Graph and the public roadmap.'; webresourceid = '953b9fac-1e5e-e611-80d6-00155ded156f'; clienttype = 4; formfactor = 1; navigationtype = 0 } | Out-Null
        (Get-One "appmodules/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()?`$select=appmoduleid&`$filter=uniquename eq 'crdr_ChangeRadar'").appmoduleid
    }
    $components = @(
        @{ '@odata.type' = 'Microsoft.Dynamics.CRM.sitemap'; sitemapid = $smId }
    ) + @($appTables | ForEach-Object { @{ '@odata.id' = "$($meta[$_].EntitySetName)($($meta[$_].MetadataId))" } })
    # A table is referenced through its OWN entity set: <entityset>(<MetadataId>). An instance of Microsoft.Dynamics.CRM.entity
    # adds the metadata table named 'entity' instead, whatever entityid says (AB#6612527, as noted in the model-apps plugin;
    # observed in pp-lab 2026-11-22). Remove that placeholder if an earlier run of this script added it.
    $entityTable = Invoke-Dv -Path "EntityDefinitions(LogicalName='entity')?`$select=MetadataId,EntitySetName"
    Invoke-Dv -Method POST -Path 'RemoveAppComponents' -Body @{ AppId = $appId; Components = @(@{ '@odata.id' = "$($entityTable.EntitySetName)($($entityTable.MetadataId))" }) } | Out-Null
    # The classic Overview dashboard is no longer part of the app (the dashboard itself stays in the solution for now).
    if ($script:ids['dashboard']) { Invoke-Dv -Method POST -Path 'RemoveAppComponents' -Body @{ AppId = $appId; Components = @(@{ '@odata.id' = "systemforms($($script:ids['dashboard']))" }) } | Out-Null }
    Invoke-Dv -Method POST -Path 'AddAppComponents' -Body @{ AppId = $appId; Components = $components } | Out-Null
    $script:ids['app'] = $appId
}

Write-Host "`nPLAN ($ExpectedEnvironmentName, solution $SolutionUniqueName)"
foreach ($s in $steps) { Write-Host ("  {0,-8} {1,-10} {2}" -f $s.Status, $s.Area, $s.Name) }
if (-not $Apply) { return }
$i = 0
foreach ($s in $steps) { $i++; Write-Host "[$i/$($steps.Count)] $($s.Area): $($s.Name)"; if ($s.Status -ne 'exists') { & $s.Action $s.Data } }
Write-Host 'Publishing...'
Invoke-Dv -Method POST -Path 'PublishAllXml' -Body @{} -Extra @{ Prefer = '' } | Out-Null   # fails to parse the body when Prefer is sent
$published = Get-One "appmodules?`$select=appmoduleidunique&`$filter=appmoduleid eq $($ids['app'])"
$tableIds = @(@((Invoke-Dv -Path "appmodulecomponents?`$select=objectid&`$filter=_appmoduleidunique_value eq $($published.appmoduleidunique) and componenttype eq 1").value) | ForEach-Object { "$($_.objectid)".ToLower() })
$missing = @($appTables | Where-Object { $tableIds -notcontains "$($meta[$_].MetadataId)".ToLower() })
$placeholder = $tableIds -contains "$((Invoke-Dv -Path "EntityDefinitions(LogicalName='entity')?`$select=MetadataId").MetadataId)".ToLower()
Write-Host "App tables: $($appTables.Count - $missing.Count) of $($appTables.Count) in the published app$(if ($missing) { "; missing: $($missing -join ', ')" })$(if ($placeholder) { "; the 'entity' placeholder is still there" })"
$v = Invoke-Dv -Path "ValidateApp(AppModuleId=$($ids['app']))"
$issues = @($v.AppValidationResponse.ValidationIssueList)
Write-Host "App validation: $($v.AppValidationResponse.ValidationSuccess ? 'passed' : 'FAILED') ($($issues.Count) issue(s))"
$issues | ForEach-Object { Write-Host "  $($_.ErrorType): $($_.Message)" }
Write-Host "`nOpen: $EnvironmentUrl/main.aspx?appid=$($ids['app'])"
