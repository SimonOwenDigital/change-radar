#Requires -Version 7.0
<#
.SYNOPSIS
    Checks that the 'assess signals' flow wrote the ratings and estate summaries the reference engine derives (ADR 0010). Read-only.
.DESCRIPTION
    For every signal with open (New or Confirmed) exposures or an existing assessment, per source:
      - engine Get-EstateImpact, using the generic impact the flow stored (the prompt's judgement isn't re-asked),
        must match crdr_estateimpact, affectedcount, unknownenvcount, productionbonus and actionbonus;
      - engine Get-ExposureSummary must match crdr_exposuresummary exactly (when there are open exposures);
      - every signal and source with open exposures must have an assessment, and every assessment must belong to one
        that has, or had, exposures.
    Override fields are reported, not checked: the flow must never have written them (overriddenby empty unless set).
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
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Assessment.psm1') -Force
function Get-Headers { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-Headers) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-Headers) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
$org = Invoke-RestMethod -Headers (Get-Headers) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Label([string]$choice, $value) { if ($null -eq $value) { return $null }; @($schema.choices.$choice)[[int]$value - $base] }
function Get-Opt([string]$choice, [string]$value) { $base + [array]::IndexOf(@($schema.choices.$choice), $value) }
$typeMap = @{}; (Get-Content -Raw (Join-Path $PSScriptRoot '..' '..' 'seed' 'asset-signatures.json') | ConvertFrom-Json).resourceTypeByType.PSObject.Properties | ForEach-Object { $typeMap[$_.Name] = $_.Value }
$max = [int](Import-Csv (Join-Path $PSScriptRoot '..' '..' 'seed' 'config.csv') | Where-Object key -eq 'estate_impact_max').value

$open = "crdr_status eq $(Get-Opt 'exposurestatus' 'new') or crdr_status eq $(Get-Opt 'exposurestatus' 'confirmed')"
$ex = @(Get-All "crdr_exposures?`$select=crdr_name,crdr_group,crdr_status,crdr_source,_crdr_signal_value,_crdr_asset_value&`$filter=$open&`$expand=crdr_asset(`$select=crdr_resourcetype,crdr_environmenttype)" | ForEach-Object {
        $isSetting = -not $_._crdr_asset_value
        [pscustomobject]@{ signal = $_._crdr_signal_value; source = (Get-Label 'assetsource' $_.crdr_source); kind = $(if ($isSetting) { 'setting' } else { 'asset' }); assetId = $_._crdr_asset_value
            settingKey = $(if ($isSetting) { ($_.crdr_name -split ' \| setting: ')[-1] }); resourceType = $(if (-not $isSetting) { $_.crdr_asset.crdr_resourcetype })
            environmentType = $(if (-not $isSetting) { Get-Label 'environmenttype' $_.crdr_asset.crdr_environmenttype }); group = $_.crdr_group; status = (Get-Label 'exposurestatus' $_.crdr_status) } })
$assessments = @(Get-All 'crdr_assessments?$select=crdr_name,_crdr_signal_value,crdr_source,crdr_genericimpact,crdr_estateimpact,crdr_affectedcount,crdr_unknownenvcount,crdr_productionbonus,crdr_actionbonus,crdr_exposuresummary,crdr_overrideimpact,_crdr_overriddenby_value,crdr_rationale,crdr_recommendedaction')
$signalIds = @(@($ex.signal) + @($assessments._crdr_signal_value) | Where-Object { $_ } | Sort-Object -Unique)
$problems = [Collections.Generic.List[string]]::new(); $rows = [Collections.Generic.List[object]]::new()
foreach ($sid in $signalIds) {
    $s = Invoke-RestMethod -Headers (Get-Headers) -Uri "$dv/crdr_signals($sid)?`$select=crdr_externalid,crdr_actionrequired,crdr_keydate"
    $groups = @(Get-All "crdr_signalfingerprints?`$select=crdr_group,crdr_name&`$filter=_crdr_signal_value eq $sid and crdr_status eq $(Get-Opt 'fingerprintstatus' 'accepted')&`$orderby=crdr_group asc,crdr_name asc" |
            Group-Object crdr_group | ForEach-Object { [pscustomobject]@{ group = $_.Name; facets = @($_.Group.crdr_name) } })
    $sigEx = @($ex | Where-Object signal -eq $sid)
    foreach ($src in $schema.choices.assetsource) {
        $a = @($assessments | Where-Object { $_._crdr_signal_value -eq $sid -and (Get-Label 'assetsource' $_.crdr_source) -eq $src })
        $srcEx = @($sigEx | Where-Object source -eq $src)
        $key = "$($s.crdr_externalid) | $src"
        if (-not $a -and -not $srcEx) { continue }
        if ($a.Count -gt 1) { $problems.Add("$key`: $($a.Count) assessments"); continue }
        if (-not $a) { $problems.Add("$key`: open exposures but no assessment"); continue }
        $a = $a[0]
        $generic = Get-Label 'impact' $a.crdr_genericimpact
        if (-not $generic) { $problems.Add("$key`: no generic impact"); continue }
        $signal = [pscustomobject]@{ id = $s.crdr_externalid; genericImpact = $generic; actionRequired = [bool]$s.crdr_actionrequired; keyDate = $s.crdr_keydate }
        $e = @(Get-EstateImpact -Signal $signal -Exposures $srcEx -EstateImpactMax $max)
        $want = if ($e) { $e[0] } else { [pscustomobject]@{ estateImpact = 'none'; affectedCount = 0; unknownEnvironmentCount = 0; productionBonus = $false; actionBonus = $false } }
        $got = [ordered]@{ estateImpact = (Get-Label 'impact' $a.crdr_estateimpact); affectedCount = $a.crdr_affectedcount; unknownEnvironmentCount = $a.crdr_unknownenvcount; productionBonus = [bool]$a.crdr_productionbonus; actionBonus = [bool]$a.crdr_actionbonus }
        foreach ($f in $got.Keys) { if ("$($got[$f])" -ne "$($want.$f)") { $problems.Add("$key`: $f flow '$($got[$f])', engine '$($want.$f)'") } }
        if ($srcEx) {
            $sum = Get-ExposureSummary -Source $src -Signal $signal -Exposures $srcEx -Groups $groups -ResourceTypeMap $typeMap
            if ("$($a.crdr_exposuresummary)".Replace("`r`n", "`n") -cne $sum) { $problems.Add("$key`: summary differs`n  flow:   $("$($a.crdr_exposuresummary)".Replace("`n", ' / '))`n  engine: $($sum.Replace("`n", ' / '))") }
        }
        if (-not "$($a.crdr_rationale)".Trim() -or -not "$($a.crdr_recommendedaction)".Trim()) { $problems.Add("$key`: rationale or action missing") }
        $rows.Add([pscustomobject]@{ Assessment = $key; Generic = $generic; Estate = $got.estateImpact; Affected = $got.affectedCount; Unknown = $got.unknownEnvironmentCount; Prod = $got.productionBonus; Action = $got.actionBonus; Override = (Get-Label 'impact' $a.crdr_overrideimpact) })
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 200
if ($problems.Count) { "MISMATCHES ($($problems.Count)):"; $problems | ForEach-Object { "  $_" }; exit 1 }
"PARITY: the assess flow and the engine agree on every rating and estate summary ($($rows.Count) assessments)."
