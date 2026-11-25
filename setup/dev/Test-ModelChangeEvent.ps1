#Requires -Version 7.0
<#
.SYNOPSIS
    ADR 0013 done-when 3: shows the detail flow raising asset.modelchanged for a test asset, without posting. Dev only.
.DESCRIPTION
    Uses Change Radar's own fingerprint prompt (an asset of type microsoft.aibuilder/prompts) as the test asset:
      1. labels its asset row fixture (source = fixture, organisation 'Change Radar fixtures (FIXTURE: test assets, not real)')
         and changes its stored 'model' fingerprint to -FromModel, as if the prompt had been on that model last run;
      2. runs 'Change Radar: collect Dataverse detail', which sees the real model and raises asset.modelchanged;
      3. checks the event (type, payload estate = fixture, from and to models) and that the dispatcher queued no
         handler run for it (posting handlers take live events only, ADR 0011);
      4. restores the asset to live and checks its model fingerprint is the real one again.
    ADR 0017: the payload names the flows that call the prompt (callers); the script checks -ExpectCaller is among them
    and prints the card the engine builds from the payload (Get-AlertCard), which lists the caller under Affected.
    Writes only Change Radar's own tables in -ExpectedEnvironmentName. The prompt itself is never touched.
    Simon, 2026-11-22: a false change is never written to a live asset that could post.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$EnvironmentId,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$PromptName = 'Change Radar signal fingerprint',
    [string]$FromModel = 'gpt-6-luna',
    [string]$ExpectCaller = 'Change Radar: fingerprint signals',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Get-AuthHeader { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' } }
function Get-Rows([string]$Path) { @((Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/$Path").value) }
function Update-Row([string]$Path, $Body) { Invoke-RestMethod -Method Patch -Headers ((Get-AuthHeader) + @{ 'If-Match' = '*' }) -Uri "$dv/$Path" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json))) | Out-Null }
$org = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) { $base + [array]::IndexOf(@($schema.choices.$choice), $value) }

$asset = Get-Rows "crdr_assets?`$select=crdr_assetid,crdr_source,crdr_syntheticorg&`$filter=crdr_resourcetype eq 'microsoft.aibuilder/prompts' and crdr_name eq '$($PromptName.Replace("'", "''"))'" | Select-Object -First 1
if (-not $asset) { throw "No prompt asset '$PromptName': run the detail flow first." }
if ($asset.crdr_source -ne (Get-Opt 'assetsource' 'live')) { throw "The asset is not live (source $($asset.crdr_source)): a previous test may not have restored it." }
$fp = Get-Rows "crdr_assetfingerprints?`$select=crdr_assetfingerprintid,crdr_value&`$filter=_crdr_asset_value eq $($asset.crdr_assetid) and crdr_facet eq $(Get-Opt 'facet' 'model')" | Select-Object -First 1
if (-not $fp) { throw 'The prompt asset has no model fingerprint.' }
$realModel = $fp.crdr_value
if ($realModel -eq $FromModel) { throw "-FromModel must differ from the real model '$realModel'." }
$started = [datetime]::UtcNow
$flowId = (Get-Rows "workflows?`$select=workflowid&`$filter=name eq 'Change Radar: collect Dataverse detail' and type eq 1")[0].workflowid
try {
    "1. Labelling the asset fixture and setting its model fingerprint to $FromModel (real: $realModel)"
    Update-Row "crdr_assets($($asset.crdr_assetid))" @{ crdr_source = (Get-Opt 'assetsource' 'fixture'); crdr_syntheticorg = 'Change Radar fixtures (FIXTURE: test assets, not real)' }
    Update-Row "crdr_assetfingerprints($($fp.crdr_assetfingerprintid))" @{ crdr_name = "model: $FromModel"; crdr_value = $FromModel }
    '2. Running the detail flow'
    & (Join-Path $PSScriptRoot 'Invoke-FlowRun.ps1') -EnvironmentId $EnvironmentId -WorkflowId $flowId -TimeoutSeconds 600
} finally {
    '4. Restoring the asset to live'
    Update-Row "crdr_assets($($asset.crdr_assetid))" @{ crdr_source = (Get-Opt 'assetsource' 'live'); crdr_syntheticorg = $null }
}
$ev = @(Get-Rows "crdr_events?`$select=crdr_eventid,crdr_name,crdr_payloadjson,_crdr_signal_value,_crdr_asset_value&`$filter=crdr_eventtype eq $(Get-Opt 'eventtype' 'asset.modelchanged') and _crdr_asset_value eq $($asset.crdr_assetid) and createdon ge $($started.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
$fails = 0
if ($ev.Count -ne 1) { $fails++; "FAIL: expected one asset.modelchanged event, found $($ev.Count)" } else {
    $p = $ev[0].crdr_payloadjson | ConvertFrom-Json
    "3. Event: $($ev[0].crdr_name)"
    foreach ($c in @(@('estate', 'fixture'), @('fromModel', $FromModel), @('toModel', $realModel), @('assetType', 'prompt'))) { if ("$($p.($c[0]))" -cne $c[1]) { $fails++; "FAIL: payload $($c[0]) = '$($p.($c[0]))', expected '$($c[1])'" } }
    if ($ev[0]._crdr_signal_value) { $fails++; 'FAIL: the event has a signal' }
    # ADR 0017: the callers, and the card the engine builds from this payload.
    $callers = @($p.PSObject.Properties['callers'] ? $p.callers : @())
    if ($ExpectCaller -and $callers -notcontains $ExpectCaller) { $fails++; "FAIL: payload callers [$($callers -join ', ')], expected '$ExpectCaller' among them" } else { "   callers: $($callers -join ', ')" }
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Events.psm1') -Force
    $mcEvent = [pscustomobject]@{ type = 'asset.modelchanged' }; foreach ($prop in $p.PSObject.Properties) { $mcEvent | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force }
    $card = Get-AlertCard -Event $mcEvent -AppUrl 'https://<app>'
    "   card: $($card.heading)"; "         $($card.why)"; "         Affected: $(@($card.assets) -join '; ')"; "         $($card.action)"
    Start-Sleep 20   # the dispatcher triggers on the new event row
    $runs = @(Get-Rows "crdr_handlerruns?`$select=crdr_name&`$filter=_crdr_event_value eq $($ev[0].crdr_eventid)")
    if ($runs.Count) { $fails++; "FAIL: $($runs.Count) handler run(s) queued for a fixture event" } else { '   no handler run queued: fixture events are not posted (ADR 0011)' }
}
$after = (Get-Rows "crdr_assetfingerprints?`$select=crdr_value&`$filter=_crdr_asset_value eq $($asset.crdr_assetid) and crdr_facet eq $(Get-Opt 'facet' 'model')").crdr_value
if (@($after) -join ',' -ne $realModel) { $fails++; "FAIL: model fingerprint now '$(@($after) -join ',')', expected '$realModel'" } else { "   model fingerprint back to $realModel" }
if ($fails) { "FAILED: $fails"; exit 1 }
'PASS: asset.modelchanged raised for the test asset, naming its calling flows, not posted, asset restored.'
