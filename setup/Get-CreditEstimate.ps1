#Requires -Version 7.0
<#
.SYNOPSIS
    Forecasts an installed Change Radar's AI credit use from its own data (docs/requirements.md 3.1 and 3.2). Read-only.
.DESCRIPTION
    Measures the forecast inputs in one environment and runs engine Get-CreditForecast (tests/credits/credits.json):
    Catch-up (catchup_max_per_run until catchup_until) is applied for the nights it has left.
      Signals       prompt-eligible signals still to fingerprint (new, or changed since fingerprinted)
      ToRate        of the signals in the rating window (or all, with rating_scope = all), those still to rate
      ToAssess      exposed signals (per estate source) with no assessment yet
      Exposed       signals with open exposures (New or Confirmed); demo exposures count only while demo_data is on
      Daily         new or changed eligible signals a day (signal.new and signal.changed events over -Days)
      WindowShare   share of eligible signals in the rating window
      ReassessShare estate assessments prompted a night ÷ exposed signals processed (assess run summaries)
      AibPerCall    AI Builder credits per prompt call, from the AI events log (msdyn_aievent)
    The install's first day is left out of Daily and ReassessShare: it is the backlog, not a normal day. An input with
    too little history (under 3 days) falls back to the documented assumption and is marked "assumed".
    Also reports the credits the prompts actually used over -Days, scaled to 30 days, to compare with the forecast.

    Runs as the signed-in user (Connect-AzAccount), who needs read access to Change Radar's tables and to AI events
    (System Administrator or Change Radar Admin). Writes nothing.
.EXAMPLE
    ./setup/Get-CreditEstimate.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>'
    ./setup/Get-CreditEstimate.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>' -Days 28 -AsObject
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [ValidateRange(3, 90)][int]$Days = 14,
    [switch]$AsObject
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $root 'engine' 'ChangeRadar.Credits.psm1') -Force
Import-Module (Join-Path $root 'engine' 'ChangeRadar.Config.psm1') -Force
Import-Module Az.Accounts -ErrorAction Stop
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
function Get-Header { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'odata.maxpagesize=5000' } }
function Get-All([string]$Query) {
    $out = [System.Collections.Generic.List[object]]::new(); $next = "$dv/$Query"
    while ($next) { $r = Invoke-RestMethod -Headers (Get-Header) -Uri $next; foreach ($v in $r.value) { $out.Add($v) }; $next = $r.PSObject.Properties['@odata.nextLink']?.Value }
    , $out
}
$org = Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

# Choice values, as the flows compute them (solutions/design/schema.json).
$schema = Get-Content -Raw (Join-Path $root 'solutions' 'design' 'schema.json') | ConvertFrom-Json
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Opt([string]$choice, [string]$value) { $i = [array]::IndexOf(@($schema.choices.$choice), $value); if ($i -lt 0) { throw "No $choice '$value'." }; $base + $i }
$prompts = Get-Content -Raw (Join-Path $root 'solutions' 'design' 'prompts.json') | ConvertFrom-Json
$now = [datetime]::UtcNow; $today = $now.Date

# Settings
$cfg = @{}; foreach ($c in (Get-All 'crdr_configs?$select=crdr_key,crdr_value')) { $cfg[$c.crdr_key] = $c.crdr_value }
# A missing setting reads as its seed default, as the flows do.
$seed = @{}; Import-Csv (Join-Path $root 'seed' 'config.csv') | ForEach-Object { $seed[$_.key] = $_.value }
function CapOf([string]$key) { $raw = if ($cfg.ContainsKey($key)) { $cfg[$key] } else { $seed[$key] }; $v = 0; if ([int]::TryParse("$raw", [ref]$v)) { $v } else { 0 } }
$caps = @{ fingerprint = CapOf 'fingerprint_max_per_run'; rating = CapOf 'rating_max_per_run'; assessment = CapOf 'assessment_max_per_run' }
# Catch-up (finding 14): nights left before catchup_until, if it applies (engine Get-EffectiveCap, the flows' rule).
$catchCap = CapOf 'catchup_max_per_run'
$catchUntil = if ($cfg.ContainsKey('catchup_until')) { "$($cfg['catchup_until'])".Trim() } else { '' }
$todayStr = [datetime]::UtcNow.ToString('yyyy-MM-dd')
$catchNights = if ($catchCap -gt 1 -and (Get-EffectiveCap -Cap 1 -CatchupCap $catchCap -Until $catchUntil -Today $todayStr) -gt 1) { [int]([datetime]::ParseExact($catchUntil, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) - [datetime]::UtcNow.Date).TotalDays } else { 0 }
$rateAll = "$($cfg['rating_scope'])".Trim().ToLowerInvariant() -eq 'all'
$demoOn = Test-DemoDataOn $cfg['demo_data']

# Signals: active, not service health, not from an unrated feed (the flows' own rules)
$unrated = @((Get-All 'crdr_feeds?$select=crdr_feedid&$filter=crdr_unrated eq true') | ForEach-Object crdr_feedid)
$health = Opt 'signalsource' 'graph_health'
$signals = Get-All "crdr_signals?`$select=crdr_signalid,createdon,crdr_lastchanged,crdr_fingerprintedon,crdr_ratedon,crdr_horizon,crdr_keydate,_crdr_feed_value&`$filter=statecode eq 0 and crdr_source ne $health"
$eligible = @($signals | Where-Object { -not ($unrated -contains $_._crdr_feed_value) })
$eligibleIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($eligible.crdr_signalid))
function Stale($s, [string]$field) { $at = $s.$field; -not $at -or ($s.crdr_lastchanged -and [datetime]$s.crdr_lastchanged -gt [datetime]$at) }

# Exposures: open, live (and demo while it's on)
$open = "(crdr_status eq $(Opt 'exposurestatus' 'new') or crdr_status eq $(Opt 'exposurestatus' 'confirmed'))"
$srcFilter = if ($demoOn) { '' } else { " and crdr_source ne $(Opt 'assetsource' 'synthetic')" }
$exposures = Get-All "crdr_exposures?`$select=_crdr_signal_value,crdr_source&`$filter=$open$srcFilter"
$pairs = @($exposures | ForEach-Object { "$($_._crdr_signal_value)|$($_.crdr_source)" } | Sort-Object -Unique)
$exposedIds = @($exposures._crdr_signal_value | Sort-Object -Unique)
$assessed = [System.Collections.Generic.HashSet[string]]::new([string[]]@((Get-All 'crdr_assessments?$select=_crdr_signal_value,crdr_source') | ForEach-Object { "$($_._crdr_signal_value)|$($_.crdr_source)" }))

$inWindow = { param($s) $rateAll -or ($exposedIds -contains $s.crdr_signalid) -or $s.crdr_horizon -in (Opt 'horizon' 'now'), (Opt 'horizon' 'imminent') -or
    ($s.crdr_keydate -and ([datetime]$s.crdr_keydate).Date -ge $today -and ([datetime]$s.crdr_keydate).Date -le $today.AddDays(183)) }
$window = @($eligible | Where-Object { & $inWindow $_ })

# History window: the last -Days, leaving out the install's first day (the backlog)
$firstSeen = (@($signals.createdon | ForEach-Object { [datetime]$_ }) | Measure-Object -Minimum).Minimum
$from = @($now.AddDays(-$Days), $(if ($firstSeen) { $firstSeen.ToUniversalTime().Date.AddDays(1) } else { $now })) | Sort-Object | Select-Object -Last 1
$span = [Math]::Max(0, ($now - $from).TotalDays)
$fromIso = $from.ToString('yyyy-MM-ddTHH:mm:ssZ')

$evTypes = "(crdr_eventtype eq $(Opt 'eventtype' 'signal.new') or crdr_eventtype eq $(Opt 'eventtype' 'signal.changed'))"
$events = Get-All "crdr_events?`$select=_crdr_signal_value&`$filter=$evTypes and createdon ge $fromIso"
$changed = @($events | Where-Object { $_._crdr_signal_value -and $eligibleIds.Contains($_._crdr_signal_value) }).Count

$runs = Get-All "crdr_collectionruns?`$select=crdr_name&`$filter=crdr_collector eq 'assess' and createdon ge $fromIso"
$prompted = 0; $processed = 0
foreach ($r in $runs) { if ($r.crdr_name -match 'signals (\d+), prompted (\d+)') { $processed += [int]$Matches[1]; $prompted += [int]$Matches[2] } }

$models = @((Get-All "msdyn_aimodels?`$select=msdyn_aimodelid&`$filter=msdyn_aimodelid eq $($prompts.fingerprint.id) or msdyn_aimodelid eq $($prompts.assessment.id)").msdyn_aimodelid)
$ai = if ($models) { Get-All "msdyn_aievents?`$select=msdyn_creditconsumed,_msdyn_aimodelid_value&`$filter=createdon ge $fromIso and ($((@($models) | ForEach-Object { "_msdyn_aimodelid_value eq $_" }) -join ' or '))" } else { @() }
$aiCalls = @($ai).Count; $aiCredits = 0.0; foreach ($e in @($ai)) { $aiCredits += [double]$e.msdyn_creditconsumed }

# Inputs: measured where the history allows, otherwise the documented assumption
$enough = $span -ge 3
$inputs = [ordered]@{
    Signals       = [pscustomobject]@{ Value = @($eligible | Where-Object { Stale $_ 'crdr_fingerprintedon' }).Count; Known = 'measured' }
    ToRate        = [pscustomobject]@{ Value = @($window | Where-Object { Stale $_ 'crdr_ratedon' }).Count; Known = 'measured' }
    ToAssess      = [pscustomobject]@{ Value = @($pairs | Where-Object { -not $assessed.Contains($_) }).Count; Known = 'measured' }
    Exposed       = [pscustomobject]@{ Value = $exposedIds.Count; Known = $(if ($demoOn) { 'measured (demo data on: demo exposures included)' } else { 'measured' }) }
    Daily         = $(if ($enough) { [pscustomobject]@{ Value = [Math]::Round($changed / $span, 1); Known = "measured over $([Math]::Round($span, 1)) days" } } else { [pscustomobject]@{ Value = 10; Known = 'assumed (under 3 days of history)' } })
    WindowShare   = [pscustomobject]@{ Value = $(if ($rateAll) { 1 } elseif ($eligible.Count) { [Math]::Round($window.Count / $eligible.Count, 2) } else { 0.25 }); Known = $(if ($rateAll) { 'rating_scope = all' } elseif ($eligible.Count) { 'measured' } else { 'assumed' }) }
    ReassessShare = $(if ($enough -and $processed) { [pscustomobject]@{ Value = [Math]::Round($prompted / $processed, 2); Known = "measured over $(@($runs).Count) assess runs" } } else { [pscustomobject]@{ Value = 0.15; Known = 'assumed (no assess runs with exposures yet)' } })
    AibPerCall    = $(if ($aiCalls -ge 10) { [pscustomobject]@{ Value = [Math]::Round($aiCredits / $aiCalls, 2); Known = "measured over $aiCalls calls" } } else { [pscustomobject]@{ Value = 5.5; Known = 'assumed (under 10 calls logged)' } })
}
# Copilot Credits per call: the rate table charges 0.1 Copilot Credits where it charges 1.2 AI Builder credits per 1,000 tokens.
$copilotPerCall = [Math]::Round($inputs.AibPerCall.Value / 12, 3)
$f = Get-CreditForecast -Signals $inputs.Signals.Value -ToRate $inputs.ToRate.Value -ToAssess $inputs.ToAssess.Value -Exposed $inputs.Exposed.Value `
    -Daily $inputs.Daily.Value -WindowShare $inputs.WindowShare.Value -ReassessShare $inputs.ReassessShare.Value `
    -FingerprintCap $caps.fingerprint -RatingCap $caps.rating -AssessmentCap $caps.assessment -CatchupCap $catchCap -CatchupNights $catchNights -AibPerCall $inputs.AibPerCall.Value -CopilotPerCall $copilotPerCall
$actual = if ($enough -and $aiCalls) { [pscustomobject]@{ Days = [Math]::Round($span, 1); Calls = $aiCalls; Aib = [Math]::Round($aiCredits); Per30DaysAib = [Math]::Round($aiCredits / $span * 30); Per30DaysCopilot = [Math]::Round($aiCredits / $span * 30 / 12) } }

if ($AsObject) { return [pscustomobject]@{ Environment = $org.Detail.FriendlyName; Caps = $caps; Catchup = [pscustomobject]@{ Cap = $catchCap; Until = $catchUntil; NightsLeft = $catchNights }; RatingScopeAll = $rateAll; DemoDataOn = $demoOn; Inputs = $inputs; Forecast = $f; Actual = $actual } }

Write-Host "`nCREDIT ESTIMATE: $($org.Detail.FriendlyName) (read-only)"
Write-Host ("  Caps per run: fingerprint {0}, rating {1}, assessment {2} (0 = no cap); rating_scope {3}; demo_data {4}" -f $caps.fingerprint, $caps.rating, $caps.assessment, $(if ($rateAll) { 'all' } else { 'window' }), $(if ($demoOn) { 'on' } else { 'off' }))
if ($catchNights) { Write-Host ("  Catch-up: caps raised to {0} for {1} more night(s), until {2}" -f $catchCap, $catchNights, $catchUntil) } else { Write-Host '  Catch-up: not active' }
Write-Host "`nInputs"
foreach ($k in $inputs.Keys) { Write-Host ("  {0,-14} {1,8}   {2}" -f $k, $inputs[$k].Value, $inputs[$k].Known) }
Write-Host "`nForecast (calls; AI Builder credits, or Copilot Credits)"
Write-Host ("  Backlog still to clear     {0,6} calls" -f $f.backlogCalls)
Write-Host ("  Next 30 days, peak         {0,6} calls   {1,7:N0} AI Builder   {2,6:N0} Copilot" -f $f.peakCalls, $f.peakAib, $f.peakCopilot)
Write-Host ("  A normal month after       {0,6} calls   {1,7:N0} AI Builder   {2,6:N0} Copilot" -f $f.monthlyCalls, $f.monthlyAib, $f.monthlyCopilot)
if ($catchNights -and $null -ne $f.firstMonthCeilingCalls) { Write-Host ("  Ceiling, next 30 days      {0,6} calls   {1,7:N0} AI Builder   {2,6:N0} Copilot   (with catch-up)" -f $f.firstMonthCeilingCalls, [Math]::Round($f.firstMonthCeilingCalls * $inputs.AibPerCall.Value), [Math]::Round($f.firstMonthCeilingCalls * $copilotPerCall)) }
if ($null -ne $f.ceilingCalls) { Write-Host ("  Ceiling at these caps      {0,6} calls   {1,7:N0} AI Builder   {2,6:N0} Copilot" -f $f.ceilingCalls, $f.ceilingAib, $f.ceilingCopilot) }
else { Write-Host '  Ceiling at these caps      none: a cap is 0' }
$nights = if ($null -eq $f.nightsToClear) { 'never at this cap: new changes fill it; raise fingerprint_max_per_run' } else { "$($f.nightsToClear)" }
Write-Host "  Nights to clear the fingerprint backlog: $nights"
if ($f.cappedStages) { Write-Host "  Held down by its cap in a normal month: $($f.cappedStages -join ', ') (work waits a night or more)" }
if ($actual) { Write-Host ("`nActually used by the prompts over the last {0} days: {1} calls, {2:N0} AI Builder credits; about {3:N0} AI Builder ({4:N0} Copilot) a 30-day month at that rate. It includes any backlog cleared in that time, so it runs above a normal month until the backlog is gone" -f $actual.Days, $actual.Calls, $actual.Aib, $actual.Per30DaysAib, $actual.Per30DaysCopilot) }
Write-Host "`nAn approximation (requirements.md 3.1). Text recognition on licensing guides and Ask Change Radar are not included."
