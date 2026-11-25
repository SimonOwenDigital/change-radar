#Requires -Version 7.0
<#
.SYNOPSIS
    Checks that the 'match exposures' flow wrote the exposures the reference engine derives (ADR 0009 step 5). Read-only.
.DESCRIPTION
    Builds the engine's inputs from the dev environment, then compares:
      - signals: accepted crdr_signalfingerprint rows (the flow's input), with their groups
      - estates: crdr_asset + crdr_assetfingerprint per source (live, fixture, synthetic), never mixed
      - tenant settings: enabled crdr_tenantsetting rows (live estate only; settings describe the real tenant)
      - rules and vocabulary: seed/ via Import-MatchingContext (the same data setup/Import-MatchingData.ps1 loads)
    Engine: engine/ChangeRadar.Matching.psm1 Find-Exposures per signal per estate.
    Dataverse: crdr_exposure rows the flow considers matching (every status except 'unmatched'; a person's 'dismissed'
    still matches, it's just been judged). Key: signal external id | asset source id (or setting: key) | source.
    Exit code 1 on any difference.
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

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Label([string]$choice, $value) { @($schema.choices.$choice)[[int]$value - $base] }
function Get-Opt([string]$choice, [string]$value) { $base + [array]::IndexOf(@($schema.choices.$choice), $value) }
$ctx = Import-MatchingContext

# Signals: accepted fingerprints only (manual or LLM), as the flow reads them.
$fpRows = @(Get-All "crdr_signalfingerprints?`$select=_crdr_signal_value,crdr_group,crdr_facet,crdr_value,crdr_extractedby&`$filter=crdr_status eq $(Get-Opt 'fingerprintstatus' 'accepted')")
$sigRows = @{}; foreach ($s in Get-All 'crdr_signals?$select=crdr_signalid,crdr_externalid,crdr_title') { $sigRows[$s.crdr_signalid] = $s }
$signals = foreach ($g in $fpRows | Group-Object _crdr_signal_value) {
    [pscustomobject]@{ id = $sigRows[$g.Name].crdr_externalid; title = $sigRows[$g.Name].crdr_title
        fingerprint = @($g.Group | ForEach-Object { [pscustomobject]@{ group = ($_.crdr_group ?? 'A'); facet = (Get-Label 'facet' $_.crdr_facet); value = $_.crdr_value; confidence = 1.0; extractedBy = (Get-Label 'extractedby' $_.crdr_extractedby) } }) }
}

# Estates per source, assets built straight from Dataverse fingerprints (the flow's view of the estate).
$assets = @(Get-All 'crdr_assets?$select=crdr_assetid,crdr_sourceid,crdr_name,crdr_resourcetype,crdr_source')
$afp = @{}; foreach ($f in Get-All 'crdr_assetfingerprints?$select=_crdr_asset_value,crdr_facet,crdr_value,crdr_evidence') { if (-not $afp[$f._crdr_asset_value]) { $afp[$f._crdr_asset_value] = [Collections.Generic.List[object]]::new() }; $afp[$f._crdr_asset_value].Add($f) }
$settings = @(Get-All "crdr_tenantsettings?`$select=crdr_key,crdr_scope&`$filter=crdr_state eq $(Get-Opt 'settingstate' 'enabled')" | ForEach-Object { [pscustomobject]@{ key = $_.crdr_key; enabled = $true; scope = @("$($_.crdr_scope)" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } })

$expected = @{}
foreach ($src in $assets | Group-Object { Get-Label 'assetsource' $_.crdr_source }) {
    $estAssets = @($src.Group | ForEach-Object {
            $a = $_; [pscustomobject]@{ assetId = $a.crdr_sourceid; name = $a.crdr_name; type = $a.crdr_resourcetype; environmentType = $null; source = $src.Name; hasAgentKit = $false
                facets = @(@($afp[$a.crdr_assetid]) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ facet = (Get-Label 'facet' $_.crdr_facet); value = $_.crdr_value; evidence = $_.crdr_evidence } }) } })
    $estate = [pscustomobject]@{ meta = [pscustomobject]@{ source = $src.Name }; tenantSettings = $(if ($src.Name -eq 'live') { $settings } else { @() }) }
    foreach ($sig in $signals) {
        foreach ($x in (Find-Exposures -Signal $sig -Assets $estAssets -Estate $estate -Context $ctx).exposures) {
            if ($x.target -like 'setting:*' -and $src.Name -ne 'live') { continue }   # settings: live only, as the flow
            $key = "$($sig.id)|$(if ($x.assetId) { $x.assetId } else { $x.target })|$($src.Name)"
            $expected[$key] = $x
        }
    }
}

$sourceById = @{}; foreach ($a in $assets) { $sourceById[$a.crdr_assetid] = $a.crdr_sourceid }
$actual = @{}
foreach ($e in Get-All "crdr_exposures?`$select=crdr_name,_crdr_signal_value,_crdr_asset_value,crdr_source,crdr_matchedfacets,crdr_rules&`$filter=crdr_status ne $(Get-Opt 'exposurestatus' 'unmatched')") {
    $target = if ($e._crdr_asset_value) { $sourceById[$e._crdr_asset_value] } else { 'setting:' + ($e.crdr_name -split ' \| setting: ')[-1] }
    $actual["$($sigRows[$e._crdr_signal_value].crdr_externalid)|$target|$(Get-Label 'assetsource' $e.crdr_source)"] = $e
}
$problems = @()
foreach ($k in $expected.Keys | Where-Object { -not $actual.ContainsKey($_) }) { $problems += "missing (engine expects): $k" }
foreach ($k in $actual.Keys | Where-Object { -not $expected.ContainsKey($_) }) { $problems += "extra (flow wrote, engine doesn't expect): $k" }
"signals with accepted fingerprints: $(@($signals).Count); engine exposures: $($expected.Count); Dataverse exposures (matching): $($actual.Count)"
$expected.Keys | ForEach-Object { $p = $_ -split '\|'; "$($p[0]) $($p[-1])" } | Group-Object | Sort-Object Name | ForEach-Object { "  $($_.Name): $($_.Count)" }
if ($problems) { "MISMATCHES ($($problems.Count)):"; $problems | Sort-Object | Select-Object -First 40 | ForEach-Object { "  $_" }; exit 1 }
'PARITY: the match flow and the engine agree on every exposure.'
