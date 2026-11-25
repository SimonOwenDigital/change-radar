#Requires -Version 7.0
<#
.SYNOPSIS
    Loads matching data into an environment (ADR 0009 step 3). Plans by default; -Apply to change.
    Only adds what is missing: rows that differ from the seed are kept, unless -UpdateToSeed is given.
.DESCRIPTION
    Upserts, as the signed-in user (Az.Accounts), only in the environment named -ExpectedEnvironmentName:
      - crdr_facetvalue from seed/vocabulary.csv (key: facet + value), with aliases (model spellings, ADR 0013).
        With -UpdateToSeed, rows not in the seed are set inactive, never deleted.
      - crdr_rule from seed/rules.csv (key: rulecode).
      - manual crdr_signalfingerprint rows from seed/manual-fingerprints.csv (ADR 0009 omission path), accepted.
      - crdr_subscription from seed/subscriptions.csv (key: name; ADR 0011). An existing row's 'enabled' is an
        installer choice and is never changed, even with -UpdateToSeed.
      - crdr_tenantsetting rows given with -TenantSetting (key: key). Tenant settings are tenant data, so they are
        never seeded from the repo: pass them on the command line, e.g.
        -TenantSetting @{ key = 'copilot_spending_policy'; state = 'enabled'; scope = 'M365 Copilot'; evidence = '...' }
    Never deletes. Reports create / exists / keep / update / deactivate per row (engine Get-SeedStep). 'keep' means the
    row differs from the seed: changed here, or changed in a newer release. -UpdateToSeed makes those rows match the
    seed, which undoes changes made in the app: read the plan first. Settings given with -TenantSetting are always set.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [hashtable[]]$TenantSetting = @(),
    [string]$VocabularyPath = (Join-Path $PSScriptRoot '..' 'seed' 'vocabulary.csv'),
    [string]$RulesPath = (Join-Path $PSScriptRoot '..' 'seed' 'rules.csv'),
    [string]$ManualFingerprintsPath = (Join-Path $PSScriptRoot '..' 'seed' 'manual-fingerprints.csv'),
    [string]$SubscriptionsPath = (Join-Path $PSScriptRoot '..' 'seed' 'subscriptions.csv'),
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' 'solutions' 'design' 'schema.json'),
    [switch]$UpdateToSeed,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' 'engine' 'ChangeRadar.Config.psm1') -Force
function Invoke-Dv([string]$Path, [string]$Method = 'GET', $Body) {
    $h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' }
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = $h }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5)); $p.ContentType = 'application/json; charset=utf-8' }
    Invoke-RestMethod @p
}
function Get-All([string]$Path) {
    $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-Dv $Path
    while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-Dv ($r.'@odata.nextLink'.Substring($dv.Length + 1)) }
    $rows.ToArray()
}
$org = Invoke-Dv "RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) { $i = [array]::IndexOf(@($schema.choices.$choice), $value); if ($i -lt 0) { throw "'$value' is not a $choice choice." }; $base + $i }

$steps = [Collections.Generic.List[object]]::new()
function Add-Step($Table, $Key, $Status, $Path, $Method, $Body) { $steps.Add([pscustomobject]@{ Table = $Table; Key = $Key; Status = $Status; Path = $Path; Method = $Method; Body = $Body }) }
function Test-Same($current, [hashtable]$desired) { foreach ($k in $desired.Keys) { if ("$($current.$k)" -ne "$($desired[$k])") { return $false } }; $true }
# One seeded row: create it, leave it, keep the difference, or (with -UpdateToSeed) make it match the seed.
function Add-SeedStep($Table, $Key, $Cur, [hashtable]$Want, $CreateBody, $CreatePath, $UpdatePath) {
    $same = if ($Cur) { Test-Same $Cur $Want } else { $false }
    $step = Get-SeedStep -InSeed $true -Exists ([bool]$Cur) -Same $same -Active $true -Reset ([bool]$UpdateToSeed)
    if ($step -eq 'create') { Add-Step $Table $Key $step $CreatePath 'POST' $CreateBody }
    elseif ($step -eq 'update') { Add-Step $Table $Key $step $UpdatePath 'PATCH' $Want }
    else { Add-Step $Table $Key $step $null $null $null }
}

# Vocabulary
$fvCols = 'crdr_facetvalueid,crdr_name,crdr_facet,crdr_value,crdr_description,crdr_active,crdr_aliases'
$current = @{}; foreach ($r in Get-All "crdr_facetvalues?`$select=$fvCols") { $current["$($r.crdr_facet)|$($r.crdr_value)"] = $r }
$seen = @{}
foreach ($v in Import-Csv $VocabularyPath) {
    $facet = Get-Opt 'facet' $v.facet; $key = "$facet|$($v.value)"; $seen[$key] = 1
    $want = @{ crdr_name = "$($v.facet): $($v.value)"; crdr_facet = $facet; crdr_value = $v.value; crdr_description = $v.description; crdr_aliases = "$($v.aliases)"; crdr_active = $true }
    $cur = $current[$key]
    Add-SeedStep 'facetvalue' $want.crdr_name $cur $want $want 'crdr_facetvalues' $(if ($cur) { "crdr_facetvalues($($cur.crdr_facetvalueid))" })
}
foreach ($k in $current.Keys | Where-Object { -not $seen[$_] }) {
    $step = Get-SeedStep -InSeed $false -Exists $true -Same $false -Active ([bool]$current[$k].crdr_active) -Reset ([bool]$UpdateToSeed)
    if ($step -eq 'deactivate') { Add-Step 'facetvalue' $current[$k].crdr_name $step "crdr_facetvalues($($current[$k].crdr_facetvalueid))" 'PATCH' @{ crdr_active = $false } }
    elseif ($step -eq 'keep') { Add-Step 'facetvalue' $current[$k].crdr_name $step $null $null $null }
}

# Rules
$ruleCurrent = @{}; foreach ($r in Get-All 'crdr_rules?$select=crdr_ruleid,crdr_rulecode,crdr_name,crdr_signalfacet,crdr_assetfacet,crdr_condition,crdr_role,crdr_active,crdr_description') { $ruleCurrent[$r.crdr_rulecode] = $r }
foreach ($r in Import-Csv $RulesPath) {
    $want = @{ crdr_rulecode = $r.rule_id; crdr_name = $r.name; crdr_signalfacet = (Get-Opt 'facet' $r.signal_facet); crdr_assetfacet = (Get-Opt 'facet' $r.asset_facet)
        crdr_condition = (Get-Opt 'rulecondition' $r.condition); crdr_role = (Get-Opt 'rulerole' $r.role); crdr_active = ($r.active -eq 'true'); crdr_description = $r.description }
    $cur = $ruleCurrent[$r.rule_id]
    Add-SeedStep 'rule' $r.rule_id $cur $want $want 'crdr_rules' $(if ($cur) { "crdr_rules($($cur.crdr_ruleid))" })
}

# Manual signal fingerprints (ADR 0009 omission path): public signal ids only, so they live in the seed. Key: signal +
# group + facet + value among manual rows. Always accepted; the fingerprint flow skips a signal that has any.
$mfOpt = Get-Opt 'extractedby' 'manual'
$mfCurrent = @{}
foreach ($r in Get-All "crdr_signalfingerprints?`$select=crdr_signalfingerprintid,_crdr_signal_value,crdr_group,crdr_facet,crdr_value,crdr_status,crdr_reason,crdr_name&`$filter=crdr_extractedby eq $mfOpt") { $mfCurrent["$($r._crdr_signal_value)|$($r.crdr_group)|$($r.crdr_facet)|$($r.crdr_value)"] = $r }
foreach ($m in Import-Csv $ManualFingerprintsPath) {
    $sigs = @(Get-All "crdr_signals?`$select=crdr_signalid&`$filter=crdr_externalid eq '$($m.signal_id)'")
    if ($sigs.Count -ne 1) { Add-Step 'manualfingerprint' "$($m.signal_id) $($m.facet): $($m.value)" "skip ($($sigs.Count) signals with that id)" $null $null $null; continue }
    $sid = $sigs[0].crdr_signalid; $facet = Get-Opt 'facet' $m.facet
    $want = @{ crdr_name = "$($m.facet): $($m.value)"; crdr_group = $m.group; crdr_facet = $facet; crdr_value = $m.value; crdr_status = (Get-Opt 'fingerprintstatus' 'accepted'); crdr_reason = $m.reason }
    $key = "$sid|$($m.group)|$facet|$($m.value)"; $cur = $mfCurrent[$key]
    $create = $want + @{ crdr_extractedby = $mfOpt; crdr_confidence = 1; 'crdr_signal@odata.bind' = "/crdr_signals($sid)" }
    Add-SeedStep 'manualfingerprint' "$($m.signal_id) $($m.group) $($want.crdr_name)" $cur $want $create 'crdr_signalfingerprints' $(if ($cur) { "crdr_signalfingerprints($($cur.crdr_signalfingerprintid))" })
}

# Subscriptions (event -> handler routing, ADR 0011)
$subCurrent = @{}; foreach ($r in Get-All 'crdr_subscriptions?$select=crdr_subscriptionid,crdr_name,crdr_eventtype,crdr_handler,crdr_filterminimpact,crdr_enabled,crdr_writes') { $subCurrent[$r.crdr_name] = $r }
foreach ($r in Import-Csv $SubscriptionsPath) {
    $want = @{ crdr_name = $r.name; crdr_eventtype = (Get-Opt 'eventtype' $r.event_type); crdr_handler = $r.handler; crdr_writes = ($r.writes -eq 'true')
        crdr_filterminimpact = $(if ($r.filter_min_impact) { Get-Opt 'impact' $r.filter_min_impact } else { $null }) }
    $cur = $subCurrent[$r.name]
    Add-SeedStep 'subscription' $r.name $cur $want ($want + @{ crdr_enabled = ($r.enabled -eq 'true') }) 'crdr_subscriptions' $(if ($cur) { "crdr_subscriptions($($cur.crdr_subscriptionid))" })
}

# Tenant settings (tenant data from the command line, never from the repo)
foreach ($t in $TenantSetting) {
    $want = @{ crdr_key = $t.key; crdr_state = (Get-Opt 'settingstate' $t.state); crdr_scope = "$($t.scope)"; crdr_evidence = "$($t.evidence)"; crdr_checkedon = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $cur = @(Get-All "crdr_tenantsettings?`$select=crdr_tenantsettingid,crdr_key,crdr_state,crdr_scope,crdr_evidence&`$filter=crdr_key eq '$($t.key)'") | Select-Object -First 1
    $compare = @{} + $want; $compare.Remove('crdr_checkedon')
    if (-not $cur) { Add-Step 'tenantsetting' $t.key 'create' 'crdr_tenantsettings' 'POST' $want }
    elseif (-not (Test-Same $cur $compare)) { Add-Step 'tenantsetting' $t.key 'update' "crdr_tenantsettings($($cur.crdr_tenantsettingid))" 'PATCH' $want }
    else { Add-Step 'tenantsetting' $t.key 'exists' $null $null $null }
}

"PLAN ($ExpectedEnvironmentName)"
$steps | Group-Object Table, Status | ForEach-Object { "  {0,-28} {1}" -f $_.Name, $_.Count }
$steps | Where-Object Status -ne 'exists' | ForEach-Object { "  {0,-10} {1,-14} {2}" -f $_.Status, $_.Table, $_.Key }
if (@($steps | Where-Object Status -eq 'keep').Count) { "  'keep': differs from the seed and is left as it is. -UpdateToSeed makes these rows match the seed (undoing changes made in the app)." }
if (-not $Apply) { 'Plan only. Nothing was changed. Re-run with -Apply.'; return }
$todo = @($steps | Where-Object Status -in 'create', 'update', 'deactivate'); $i = 0
foreach ($s in $todo) { $i++; Invoke-Dv $s.Path $s.Method $s.Body | Out-Null }
"Done: $i change(s)."
