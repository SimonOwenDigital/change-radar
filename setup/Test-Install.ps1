#Requires -Version 7.0
<#
.SYNOPSIS
    Checks a Change Radar install in one read-only run (install.md step 9; ADR 0022). Writes nothing.
.DESCRIPTION
    Run it after the first night's collection. Each check reports PASS, WARN or FAIL with what to do about it:
      solution     ChangeRadarCore is installed (managed in a real install)
      flows        every core flow is on
      handlers     each handler installed (ChangeRadarHandlers), on or off, with its flow and subscriptions agreeing;
                   no runs left queued for a handler that isn't on (ADR 0023)
      connections  every connection reference is bound (Teams and Outlook only while a handler that uses them is on)
      variables    the three environment variables have values
      settings     every seed setting exists; an alert destination and app_url are set; credit caps aren't 0
      seed data    vocabulary, rules and subscriptions are loaded; at least one feed is on
      collection   each collector ran successfully within -Hours (default 36), with its access tier
      signals      signals and accepted fingerprints exist
      reader       the reader's application user exists, is enabled and holds only Change Radar Reader; that role
                   reads every Change Radar table and has no unmanaged layer over it (install test finding 6)
      roles        Change Radar User and Change Radar Admin exist
      alerts       no run of a handler that's on failed in the last 7 days since the alert settings were last changed
      status       demo data and catch-up, for information
    Exit code 1 if anything FAILs. Runs as the signed-in user (Connect-AzAccount) with System Administrator or
    Change Radar Admin plus read on solutions, flows and users.
.EXAMPLE
    ./setup/Test-Install.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string]$SolutionUniqueName = 'ChangeRadarCore',
    [ValidateRange(1, 720)][int]$Hours = 36
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $root 'engine' 'ChangeRadar.Config.psm1') -Force
Import-Module (Join-Path $root 'engine' 'ChangeRadar.Handlers.psm1') -Force
Import-Module Az.Accounts -ErrorAction Stop
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
function Get-Hdr { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'odata.maxpagesize=5000,odata.include-annotations="OData.Community.Display.V1.FormattedValue"' } }
$hdr = Get-Hdr
function Get-All([string]$Query) {
    $out = [Collections.Generic.List[object]]::new(); $next = "$dv/$Query"
    while ($next) { $r = Invoke-RestMethod -Headers $hdr -Uri $next; foreach ($v in $r.value) { $out.Add($v) }; $next = $r.PSObject.Properties['@odata.nextLink']?.Value }
    $out.ToArray()
}
$fv = '@OData.Community.Display.V1.FormattedValue'
$org = Invoke-RestMethod -Headers $hdr -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$results = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Area, [string]$Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Result, [string]$Detail, [string]$Fix = '') {
    $results.Add([pscustomobject]@{ Result = $Result; Area = $Area; Check = $Check; Detail = $Detail; Fix = $Fix })
}
$schema = Get-Content -Raw (Join-Path $root 'solutions' 'design' 'schema.json') | ConvertFrom-Json
$tables = @($schema.tables.name | ForEach-Object { "crdr_$_" })
$since = [datetime]::UtcNow.AddHours(-$Hours)

# Solution
$sol = @(Get-All "solutions?`$select=solutionid,uniquename,version,ismanaged&`$filter=uniquename eq '$SolutionUniqueName'")
if (-not $sol) { Add-Check 'solution' $SolutionUniqueName 'FAIL' 'not installed' 'Import it (install.md step 3).'; $results | Format-Table -AutoSize -Wrap | Out-String -Width 220; exit 1 }
$sol = $sol[0]
Add-Check 'solution' $SolutionUniqueName $(if ($sol.ismanaged) { 'PASS' } else { 'INFO' }) "version $($sol.version), $(if ($sol.ismanaged) { 'managed' } else { 'unmanaged (a dev environment)' })"

# Flows (Core): every one on. Handler flows (ADR 0023) are checked under handlers, whichever solution holds them.
$flowIds = @((Get-All "solutioncomponents?`$select=objectid&`$filter=_solutionid_value eq $($sol.solutionid) and componenttype eq 29") | ForEach-Object objectid)
$flows = @(Get-All "workflows?`$select=workflowid,name,statecode&`$filter=category eq 5" | Where-Object { $flowIds -contains $_.workflowid -and -not (Get-HandlerName $_.name) })
$off = @($flows | Where-Object { $_.statecode -ne 1 })
if ($off) { Add-Check 'flows' 'switched on' 'FAIL' "$($off.Count) of $($flows.Count) off: $(($off.name) -join '; ')" 'Turn them on (Power Automate, Solutions, ChangeRadarCore), after the connections are bound.' }
else { Add-Check 'flows' 'switched on' 'PASS' "$(@($flows | Where-Object statecode -eq 1).Count) of $($flows.Count) on" }

# Handlers (ADR 0023): installed, on or off, and whole (flow and subscriptions agree)
$hFlows = @(Get-All "workflows?`$select=workflowid,name,statecode&`$filter=startswith(name,'Change Radar handler: ') and category eq 5")
$hSubs = @(Get-All 'crdr_subscriptions?$select=crdr_name,crdr_handler,crdr_enabled')
$handlersOn = @()
if (-not $hFlows) { Add-Check 'handlers' 'installed' 'INFO' 'none: no alerts are sent' 'Import ChangeRadarHandlers, then setup/Set-Handlers.ps1 -On Notify-Teams,Digest-Weekly (install.md step 6).' }
foreach ($hf in $hFlows | Sort-Object name) {
    $n = Get-HandlerName $hf.name; $mine = @($hSubs | Where-Object { "$($_.crdr_handler)" -ieq $n }); $en = @($mine | Where-Object crdr_enabled).Count
    $flowOn = $hf.statecode -eq 1
    if ($flowOn) { $handlersOn += $n }
    $state = "flow $(if ($flowOn) { 'on' } else { 'off' }), subscriptions $en of $($mine.Count) enabled"
    if ($flowOn -and $mine.Count -and -not $en) { Add-Check 'handlers' $n 'WARN' "$($state): on, but nothing is routed to it" "setup/Set-Handlers.ps1 -On $n" }
    elseif (-not $flowOn -and $en) { Add-Check 'handlers' $n 'WARN' "$($state): events are queued for it but nothing runs" "setup/Set-Handlers.ps1 -On $n, or -Off $n" }
    else { Add-Check 'handlers' $n $(if ($flowOn) { 'PASS' } else { 'INFO' }) $state }
}
# Runs queued over a day for a handler that isn't running (digests legitimately hold runs until their day, while on).
$stale = @(Get-All "crdr_handlerruns?`$select=crdr_name&`$filter=crdr_outcome eq $([int]"$($schema.publisher.optionValuePrefix)0003") and createdon lt $([datetime]::UtcNow.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))") | Where-Object { $handlersOn -notcontains (($_.crdr_name -split ' \| ')[0]) }
if ($stale) { Add-Check 'handlers' 'queued runs' 'WARN' "$($stale.Count) queued over a day for handlers that aren't on: $((@($stale | ForEach-Object { ($_.crdr_name -split ' \| ')[0] }) | Sort-Object -Unique) -join ', ')" 'Turn the handler on, or off with setup/Set-Handlers.ps1 -Off (which disables its subscriptions).' }

# Connection references: Teams and Outlook matter only while a handler that uses them is on
$refs = @(Get-All "connectionreferences?`$select=connectionreferencelogicalname,connectionid&`$filter=startswith(connectionreferencelogicalname,'crdr_')")
$needs = @{ crdr_teams = @('Notify-Teams', 'Digest-Weekly'); crdr_outlook = @('Notify-Email', 'Digest-Email') }
foreach ($r in $refs) {
    $users = @($needs[$r.connectionreferencelogicalname] | Where-Object { $_ -and $handlersOn -contains $_ })
    $optional = $needs.ContainsKey($r.connectionreferencelogicalname) -and -not $users
    if ($r.connectionid) { Add-Check 'connections' $r.connectionreferencelogicalname 'PASS' 'bound' }
    elseif ($optional) { Add-Check 'connections' $r.connectionreferencelogicalname 'INFO' "not bound; needed only for $($needs[$r.connectionreferencelogicalname] -join ' and ')" }
    else { Add-Check 'connections' $r.connectionreferencelogicalname 'FAIL' "not bound$(if ($users) { "; $($users -join ', ') on" })" 'Create the connection and set it on the reference (install.md step 3.1).' }
}

# Environment variables
foreach ($d in @(Get-All "environmentvariabledefinitions?`$select=schemaname,defaultvalue&`$filter=startswith(schemaname,'crdr_')&`$expand=environmentvariabledefinition_environmentvariablevalue(`$select=value)")) {
    $val = @($d.environmentvariabledefinition_environmentvariablevalue | Where-Object { $_.value })
    if ($val -or $d.defaultvalue) { Add-Check 'variables' $d.schemaname 'PASS' 'has a value' }
    else { Add-Check 'variables' $d.schemaname 'FAIL' 'no value' 'Set it in deploymentSettings.json and re-import, or in the solution (install.md step 3.2).' }
}

# Settings
$cfg = @{}; $alertSetAt = [datetime]::MinValue
foreach ($c in (Get-All 'crdr_configs?$select=crdr_key,crdr_value,modifiedon')) {
    $cfg[$c.crdr_key] = "$($c.crdr_value)"
    if ($c.crdr_key -in 'alert_recipient', 'alert_destinations' -and $c.crdr_value -and ([datetime]$c.modifiedon).ToUniversalTime() -gt $alertSetAt) { $alertSetAt = ([datetime]$c.modifiedon).ToUniversalTime() }
}
$seedKeys = @(Import-Csv (Join-Path $root 'seed' 'config.csv') | ForEach-Object key)
$missing = @($seedKeys | Where-Object { -not $cfg.ContainsKey($_) })
if ($missing) { Add-Check 'settings' 'all present' 'WARN' "missing: $($missing -join ', ') (the flows use the seed default)" 'Run setup/Import-Config.ps1 -Apply.' }
else { Add-Check 'settings' 'all present' 'PASS' "$($seedKeys.Count) settings" }
if ($cfg['alert_recipient'] -or $cfg['alert_destinations']) { Add-Check 'settings' 'alert destination' 'PASS' 'set (value not shown)' }
elseif (-not $handlersOn) { Add-Check 'settings' 'alert destination' 'INFO' 'not set; not needed until a handler is on (ADR 0023)' }
else { Add-Check 'settings' 'alert destination' 'FAIL' "neither alert_recipient nor alert_destinations is set, and $($handlersOn -join ', ') on: alerts fail" 'setup/Import-Config.ps1 -AlertRecipient or -AlertDestinations.' }
if ($cfg['app_url']) { Add-Check 'settings' 'app_url' 'PASS' 'set' } else { Add-Check 'settings' 'app_url' 'WARN' 'not set: card links won''t open the app' 'Run setup/Import-Config.ps1 -Apply (it works it out).' }
$zeroCaps = @('fingerprint_max_per_run', 'rating_max_per_run', 'assessment_max_per_run' | Where-Object { $cfg.ContainsKey($_) -and $cfg[$_].Trim() -in '0', '' })
if ($zeroCaps) { Add-Check 'settings' 'credit caps' 'WARN' "no cap: $($zeroCaps -join ', ')" 'Set a cap unless you mean it (requirements.md 3.1).' }
else { Add-Check 'settings' 'credit caps' 'PASS' "fingerprint $($cfg['fingerprint_max_per_run']), rating $($cfg['rating_max_per_run']), assessment $(if ($cfg.ContainsKey('assessment_max_per_run')) { $cfg['assessment_max_per_run'] } else { 'seed default' })" }

# Seed data
$vocab = @(Get-All 'crdr_facetvalues?$select=crdr_facetvalueid&$filter=crdr_active eq true').Count
$rules = @(Get-All 'crdr_rules?$select=crdr_ruleid&$filter=crdr_active eq true').Count
$subs = @(Get-All 'crdr_subscriptions?$select=crdr_subscriptionid').Count   # loaded; enabled per handler is checked under handlers (ADR 0023)
$feeds = @(Get-All 'crdr_feeds?$select=crdr_key,crdr_active')
$feedsOn = @($feeds | Where-Object crdr_active)
foreach ($x in @(@('vocabulary', $vocab), @('rules', $rules), @('subscriptions', $subs))) {
    if ($x[1]) { Add-Check 'seed data' $x[0] 'PASS' "$($x[1]) $(if ($x[0] -eq 'subscriptions') { 'loaded' } else { 'active' })" } else { Add-Check 'seed data' $x[0] 'FAIL' 'none' 'Run setup/Import-MatchingData.ps1 -Apply (install.md step 5).' }
}
if ($feedsOn) { Add-Check 'seed data' 'feeds' 'PASS' "$($feedsOn.Count) of $($feeds.Count) on" }
elseif ($feeds) { Add-Check 'seed data' 'feeds' 'WARN' "$($feeds.Count) loaded, none on: no feed signals" 'Switch on the ones you want (Operations, Feeds) or re-run setup/Import-Feeds.ps1 -UseSeedActive.' }
else { Add-Check 'seed data' 'feeds' 'WARN' 'none loaded' 'Run setup/Import-Feeds.ps1 -Apply.' }

# Collection runs
$runs = @(Get-All "crdr_collectionruns?`$select=crdr_name,crdr_collector,crdr_accesstier,createdon&`$filter=createdon ge $($since.ToString('yyyy-MM-ddTHH:mm:ssZ'))&`$orderby=createdon desc")
$expected = @('service-health', 'message-center', 'roadmap', 'estate-inventory', 'horizons', 'fingerprint', 'match', 'assess')
if ($cfg['detail_environments']) { $expected += 'dataverse-detail' }
$expected += @($feedsOn | ForEach-Object { "feed:$($_.crdr_key)" })
foreach ($c in $expected) {
    $last = @($runs | Where-Object crdr_collector -eq $c) | Select-Object -First 1
    if (-not $last) { Add-Check 'collection' $c $(if ($c -like 'feed:*') { 'WARN' } else { 'FAIL' }) "no run in the last $Hours hours" 'Check the flow''s run history (Power Automate); a first run happens at the scheduled time.' }
    elseif ($last.crdr_name -match 'FAILED') { Add-Check 'collection' $c 'FAIL' "$($last.crdr_name)" 'Open the flow''s last run in Power Automate to see the failing step.' }
    else { Add-Check 'collection' $c 'PASS' ("{0:yyyy-MM-dd HH:mm}, tier {1}" -f ([datetime]$last.createdon).ToUniversalTime(), $last."crdr_accesstier$fv") }
}

# Signals and fingerprints
$sig = @(Get-All 'crdr_signals?$select=crdr_signalid&$filter=statecode eq 0').Count
$fps = @(Get-All "crdr_signalfingerprints?`$select=crdr_signalfingerprintid&`$filter=crdr_status eq $([int]"$($schema.publisher.optionValuePrefix)0000")").Count
if ($sig) { Add-Check 'signals' 'signals' 'PASS' "$sig active" } else { Add-Check 'signals' 'signals' 'FAIL' 'none' 'The collectors haven''t written anything: check their runs.' }
if ($fps) { Add-Check 'signals' 'accepted fingerprints' 'PASS' "$fps" } else { Add-Check 'signals' 'accepted fingerprints' 'WARN' 'none yet' 'Expected after the first fingerprint run; check its run and the AI Builder or Copilot Credit capacity.' }

# Reader identity and roles
$roleRows = @(Get-All "roles?`$select=roleid,name,solutionid&`$filter=startswith(name,'Change Radar')")
$reader = $roleRows | Where-Object name -eq 'Change Radar Reader' | Select-Object -First 1
if (-not $reader) { Add-Check 'reader' 'Change Radar Reader role' 'FAIL' 'missing' 'It ships in ChangeRadarCore: re-import the solution.' }
else {
    $rp = @((Get-All "roles($($reader.roleid))/roleprivileges_association?`$select=name") | ForEach-Object name)
    $noRead = @($tables | Where-Object { $rp -notcontains "prvRead$_" -and @($rp | Where-Object { $_ -ieq "prvRead$_" }).Count -eq 0 })
    if ($noRead) { Add-Check 'reader' 'role reads every table' 'FAIL' "no read on $($noRead -join ', ')" 'Re-import a solution built after install test finding 6.' } else { Add-Check 'reader' 'role reads every table' 'PASS' "$($tables.Count) tables" }
    if ($sol.ismanaged -and $reader.solutionid -ne $sol.solutionid) { Add-Check 'reader' 'no unmanaged layer' 'WARN' 'the role has an unmanaged layer: later updates of it won''t apply' "Remove it: GET $dv/RemoveActiveCustomizations(SolutionComponentName='Role',ComponentId=$($reader.roleid))" }
    elseif ($sol.ismanaged) { Add-Check 'reader' 'no unmanaged layer' 'PASS' 'role as the solution ships it' }
    $users = @((Get-All "roles($($reader.roleid))/systemuserroles_association?`$select=fullname,applicationid,isdisabled") | Where-Object applicationid)
    if (-not $users) { Add-Check 'reader' 'application user' 'FAIL' 'no application user holds the Reader role' 'Run setup/New-ReaderIdentity.ps1 -Apply (install.md step 4).' }
    foreach ($u in $users) {
        $other = @((Get-All "systemusers($($u.systemuserid))/systemuserroles_association?`$select=name") | ForEach-Object name | Where-Object { $_ -ne 'Change Radar Reader' })
        if ($u.isdisabled) { Add-Check 'reader' 'application user' 'FAIL' "$($u.fullname) is disabled" 'Enable it (Power Platform admin centre, Application users).' }
        elseif ($other) { Add-Check 'reader' 'application user' 'WARN' "$($u.fullname) also holds: $($other -join ', ')" 'The reader should hold only Change Radar Reader (read-only).' }
        else { Add-Check 'reader' 'application user' 'PASS' "$($u.fullname): enabled, Reader role only" }
    }
}
foreach ($n in 'Change Radar User', 'Change Radar Admin') {
    if ($roleRows | Where-Object name -eq $n) { Add-Check 'roles' $n 'PASS' 'present' } else { Add-Check 'roles' $n 'FAIL' 'missing' 'It ships in ChangeRadarCore: re-import the solution.' }
}

# Alert handlers
# Failures before the alert settings were last changed are history (install test: 64 failed before a destination was set).
$alertFrom = @([datetime]::UtcNow.AddDays(-7), $alertSetAt) | Sort-Object | Select-Object -Last 1
$failedRuns = @(Get-All "crdr_handlerruns?`$select=crdr_name,createdon&`$filter=crdr_outcome eq $([int]"$($schema.publisher.optionValuePrefix)0002") and createdon ge $($alertFrom.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
foreach ($n in $handlersOn) {
    $failed = @($failedRuns | Where-Object { $_.crdr_name -like "$n |*" })
    if ($failed) { Add-Check 'alerts' $n 'FAIL' "$($failed.Count) failed since $($alertFrom.ToString('yyyy-MM-dd HH:mm')), latest: $($failed[0].crdr_name)" 'Check alert_destinations and the connection; the handler run row says why.' }
    else { Add-Check 'alerts' $n 'PASS' "no failures since $($alertFrom.ToString('yyyy-MM-dd HH:mm')) UTC" }
}

# Status
Add-Check 'status' 'demo data' 'INFO' $(if (Test-DemoDataOn $cfg['demo_data']) { 'ON: demo exposures and ratings are included (never in production)' } else { 'off' })
$today = [datetime]::UtcNow.ToString('yyyy-MM-dd'); $cc = 0; [void][int]::TryParse("$($cfg['catchup_max_per_run'])", [ref]$cc)
$catch = if ($cfg.ContainsKey('catchup_until') -and $cc -gt 1 -and (Get-EffectiveCap -Cap 1 -CatchupCap $cc -Until $cfg['catchup_until'] -Today $today) -gt 1) { "on until $($cfg['catchup_until']) (caps raised to $cc)" } else { 'not active' }
Add-Check 'status' 'catch-up' 'INFO' $catch

$results | Format-Table Result, Area, Check, Detail, Fix -AutoSize -Wrap | Out-String -Width 240
$fail = @($results | Where-Object Result -eq 'FAIL').Count; $warn = @($results | Where-Object Result -eq 'WARN').Count
"$($org.Detail.FriendlyName): $(@($results | Where-Object Result -eq 'PASS').Count) pass, $warn warn, $fail fail."
if ($fail) { exit 1 }
