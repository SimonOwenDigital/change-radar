#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 2 "done when" check: every app, flow and agent in the tenant appears with facets and evidence. Read-only.
.DESCRIPTION
    1. Exports live inventory with queries/inventory.ps1 (delegated; the export stays in the temp folder).
    2. Reads crdr_asset and crdr_assetfingerprint from the dev environment.
    3. Per inventory type: resources in inventory, assets in Dataverse (live + fixture), missing ones.
       Per asset: facets present, and every fingerprint has evidence. Lists fixture assets separately.
    Exit code 1 if any app, flow or agent is missing, has no facets, or has a fingerprint without evidence.
    Prints names to the console only; nothing is written to the repo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
Import-Module Az.Accounts -ErrorAction Stop
function Get-Token { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText }
function Get-All([string]$Path) {
    $h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' }
    $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/$Path" -Headers $h
    while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Uri $r.'@odata.nextLink' -Headers $h }
    $rows.ToArray()
}
$org = Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')" -Headers @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json' }
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$export = Join-Path ([IO.Path]::GetTempPath()) 'change-radar-coverage-estate.json'
& (Join-Path $PSScriptRoot '..' '..' 'queries' 'inventory.ps1') -OutPath $export | Out-Null
$inv = @((Get-Content -Raw $export | ConvertFrom-Json -Depth 50).inventory)

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$sources = @($schema.choices.assetsource); $base = [int]"$($schema.publisher.optionValuePrefix)0000"
$synthetic = $base + [array]::IndexOf($sources, 'synthetic')
$assets = @(Get-All "crdr_assets?`$select=crdr_assetid,crdr_sourceid,crdr_name,crdr_resourcetype,crdr_source,crdr_solutionuniquename&`$filter=crdr_source ne $synthetic")
$fps = @(Get-All "crdr_assetfingerprints?`$select=crdr_name,crdr_evidence,_crdr_asset_value&`$filter=crdr_asset/crdr_source ne $synthetic")
$byAsset = @{}; foreach ($f in $fps) { if (-not $byAsset[$f._crdr_asset_value]) { $byAsset[$f._crdr_asset_value] = [Collections.Generic.List[object]]::new() }; $byAsset[$f._crdr_asset_value].Add($f) }
$assetByKey = @{}; foreach ($a in $assets) { $assetByKey[$a.crdr_sourceid] = $a }

$problems = [Collections.Generic.List[string]]::new()
$rows = foreach ($g in $inv | Group-Object type | Sort-Object Name) {
    $found = 0; $withFacets = 0; $facetCount = 0; $fixtures = 0
    foreach ($r in $g.Group) {
        $key = "$([string]$r.properties.PSObject.Properties['environmentId']?.Value)|$($r.name)|"
        $a = $assetByKey[$key]
        if (-not $a) { $problems.Add("missing: $($g.Name) '$($r.properties.displayName)'"); continue }
        $found++
        if ($sources[$a.crdr_source - $base] -eq 'fixture') { $fixtures++ }
        $mine = @($byAsset[$a.crdr_assetid] | Where-Object { $_ })
        if ($mine.Count) { $withFacets++; $facetCount += $mine.Count } else { $problems.Add("no facets: $($a.crdr_name)") }
        foreach ($f in $mine) { if (-not $f.crdr_evidence) { $problems.Add("no evidence: $($a.crdr_name) / $($f.crdr_name)") } }
    }
    [pscustomobject]@{ Type = $g.Name; Inventory = $g.Count; InDataverse = $found; WithFacets = $withFacets; Facets = $facetCount; Fixture = $fixtures }
}
"Coverage against live inventory ($($inv.Count) resources; Dataverse holds $($assets.Count) live + fixture assets, $($fps.Count) fingerprints)"
$rows | Format-Table -AutoSize | Out-String -Width 200
$fixtureAssets = @($assets | Where-Object { $sources[$_.crdr_source - $base] -eq 'fixture' })
"Fixture assets (source = fixture, kept out of live ratings): $(@($fixtureAssets | ForEach-Object { "$($_.crdr_name) [$($_.crdr_solutionuniquename)]" }) -join '; ')"
$facetMix = $fps | Group-Object { ($_.crdr_name -split ':')[0] } | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" }
"Facets by kind: $($facetMix -join ', ')"
if ($problems.Count) { "PROBLEMS ($($problems.Count)):"; $problems | ForEach-Object { "  $_" }; exit 1 }
'COVERED: every app, flow and agent in inventory is in Dataverse with facets, and every fingerprint has evidence.'
