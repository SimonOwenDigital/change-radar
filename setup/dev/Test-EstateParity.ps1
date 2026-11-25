#Requires -Version 7.0
<#
.SYNOPSIS
    Checks that the estate inventory and Dataverse detail flows wrote what the reference engine derives (ADR 0008).
.DESCRIPTION
    1. Exports live inventory with queries/inventory.ps1 (delegated, read-only; the export stays in the temp folder).
    2. Adds Dataverse detail with queries/dataverse-detail.ps1 (as the reader app, read-only), which also moves
       resources in a fixture solution into a separate fixture estate (spec §15.2).
    3. Fingerprints both estates with engine/ChangeRadar.Matching.psm1 (Get-AssetFingerprints).
    4. Reads crdr_asset and crdr_assetfingerprint rows from the dev environment (read-only), by source.
    5. Compares per source (live, fixture), asset by asset (source id = environment id | resource name |) and facet by
       facet ('facet: value'), and checks that no asset carries the wrong source.

    Facets the engine can produce but no flow writes yet (owner-based auth modes, SharePoint tempauth, kit
    capabilities) only appear when an estate holds principals, connector definitions or kit rows. Phase 2's
    exports have none, so any difference is a real mismatch. Exit code 1 on any mismatch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Matching.psm1') -Force
function Get-Token { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText }
function Get-All([string]$Path) {
    $h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' }
    $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/$Path" -Headers $h
    while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Uri $r.'@odata.nextLink' -Headers $h }
    $rows.ToArray()
}
$org = Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')" -Headers @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json' }
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$tmp = [IO.Path]::GetTempPath()
$liveExport = Join-Path $tmp 'change-radar-live-estate.json'
$fixtureExport = Join-Path $tmp 'change-radar-fixture-estate.json'
if (Test-Path $fixtureExport) { Remove-Item -LiteralPath $fixtureExport }
& (Join-Path $PSScriptRoot '..' '..' 'queries' 'inventory.ps1') -OutPath $liveExport | Out-Null
& (Join-Path $PSScriptRoot '..' '..' 'queries' 'dataverse-detail.ps1') -SubscriptionId $SubscriptionId -EnvironmentUrl $EnvironmentUrl -ExpectedEnvironmentName $ExpectedEnvironmentName -EstatePath $liveExport -FixtureEstatePath $fixtureExport | Out-Null

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
function Get-SourceValue([string]$name) { [int]"$($schema.publisher.optionValuePrefix)0000" + [array]::IndexOf(@($schema.choices.assetsource), $name) }
$ctx = Import-MatchingContext
$problems = [Collections.Generic.List[string]]::new()
$expectedKeys = @{}
foreach ($pair in @(@('live', $liveExport), @('fixture', $fixtureExport))) {
    $source = $pair[0]
    $estate = Get-Content -Raw $pair[1] | ConvertFrom-Json -Depth 50
    $expected = @{}
    foreach ($fp in @(if (@($estate.inventory).Count) { Get-AssetFingerprints -Estate $estate -Context $ctx })) {
        $r = $estate.inventory | Where-Object name -eq $fp.assetId | Select-Object -First 1
        $key = "$([string]$r.properties.PSObject.Properties['environmentId']?.Value)|$($r.name)|"
        $expected[$key] = [pscustomobject]@{ name = $fp.name; facets = @($fp.facets | ForEach-Object { "$($_.facet): $($_.value)" } | Sort-Object -Unique) }
        $expectedKeys[$key] = $source
    }
    $value = Get-SourceValue $source
    $assets = @(Get-All "crdr_assets?`$select=crdr_assetid,crdr_sourceid,crdr_name&`$filter=crdr_source eq $value")
    $fpRows = @(Get-All "crdr_assetfingerprints?`$select=crdr_name,_crdr_asset_value&`$filter=crdr_asset/crdr_source eq $value")
    $byAsset = @{}; foreach ($f in $fpRows) { $byAsset[$f._crdr_asset_value] = @($byAsset[$f._crdr_asset_value]) + $f.crdr_name }
    $actual = @{}; foreach ($a in $assets) { $actual[$a.crdr_sourceid] = @(@($byAsset[$a.crdr_assetid]) | Where-Object { $_ } | Sort-Object -Unique) }
    foreach ($k in $expected.Keys) {
        if (-not $actual.ContainsKey($k)) { $problems.Add("[$source] missing asset (or wrong source): $($expected[$k].name)"); continue }
        foreach ($x in @(Compare-Object @($expected[$k].facets) @($actual[$k]))) {
            $problems.Add("[$source] $($expected[$k].name): $($x.InputObject) $(if ($x.SideIndicator -eq '<=') { 'expected by engine, not written by the flows' } else { 'written by the flows, not expected by engine' })")
        }
    }
    $stale = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) })
    "${source}: engine $($expected.Count) assets, $(($expected.Values.facets | Measure-Object).Count) facets; Dataverse $($actual.Count) assets, $($fpRows.Count) fingerprints$(if ($stale) { "; $($stale.Count) in Dataverse but not in inventory now (left in place, lastseen shows when)" })"
}
if ($problems.Count) { "MISMATCHES ($($problems.Count)):"; $problems | ForEach-Object { "  $_" }; exit 1 }
'PARITY: the flows and the engine agree on every asset, facet and source.'
