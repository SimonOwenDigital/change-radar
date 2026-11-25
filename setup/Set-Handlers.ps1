#Requires -Version 7.0
<#
.SYNOPSIS
    Switches Change Radar's handlers on or off: each handler's flow and its subscriptions together (ADR 0023).
.DESCRIPTION
    Plans by default; -Apply changes. Without -On or -Off it shows each handler's state. A handler is on when its flow
    'Change Radar handler: <name>' is on and its subscriptions (crdr_subscription.handler = <name>) are enabled.
    The handlers ship in ChangeRadarHandlers, all off. Before turning one on:
      Notify-Teams, Digest-Weekly  the Microsoft Teams connection is bound to crdr_teams, and alert_destinations (or
                                   alert_recipient) names a chat: or channel: entry (setup/Import-Config.ps1)
      Notify-Email, Digest-Email   the Office 365 Outlook connection is bound to crdr_outlook, and alert_destinations
                                   has an email: entry
    Handlers that write outside Change Radar (a subscription with writes = yes) are named in the plan, so the choice is
    deliberate (CLAUDE.md, spec §7). Runs as the signed-in user (Connect-AzAccount), who needs to be able to turn the
    flows on (System Administrator, or the flows' owner) and write crdr_subscription (Change Radar Admin).
    The plan rule is engine Get-HandlerPlan (tests/handlers/handlers.json).
.EXAMPLE
    ./setup/Set-Handlers.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>'
    ./setup/Set-Handlers.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>' -On Notify-Teams,Digest-Weekly -Apply
    ./setup/Set-Handlers.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>' -Off Digest-Weekly -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string[]]$On = @(),
    [string[]]$Off = @(),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $root 'engine' 'ChangeRadar.Handlers.psm1') -Force
Import-Module Az.Accounts -ErrorAction Stop
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
function Get-Hdr { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' } }
function Invoke-Dv([string]$Method = 'GET', [string]$Path, $Body) {
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = (Get-Hdr) }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress)); $p.ContentType = 'application/json; charset=utf-8'; $p.Headers['If-Match'] = '*' }
    try { Invoke-RestMethod @p } catch { $d = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $_.Exception.Message }; throw "$Method $Path failed: $d" }
}
$org = Invoke-Dv -Path "RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$flowRows = @((Invoke-Dv -Path "workflows?`$select=workflowid,name,statecode&`$filter=startswith(name,'Change Radar handler: ') and category eq 5").value)
$subRows = @((Invoke-Dv -Path 'crdr_subscriptions?$select=crdr_subscriptionid,crdr_name,crdr_handler,crdr_enabled,crdr_writes').value)
$installed = @($flowRows | ForEach-Object { [pscustomobject]@{ flow = $_.name; on = ($_.statecode -eq 1) } })
$subs = @($subRows | ForEach-Object { [pscustomobject]@{ name = $_.crdr_name; handler = $_.crdr_handler; enabled = [bool]$_.crdr_enabled } })

Write-Host "`nHANDLERS ($ExpectedEnvironmentName)"
if (-not $flowRows) { Write-Host '  none installed: import ChangeRadarHandlers to add alerts.' }
foreach ($f in $flowRows | Sort-Object name) {
    $n = Get-HandlerName $f.name
    $mine = @($subRows | Where-Object { "$($_.crdr_handler)" -ieq $n })
    $writes = @($mine | Where-Object crdr_writes)
    Write-Host ("  {0,-18} flow {1,-3}  subscriptions {2} of {3} enabled{4}" -f $n, $(if ($f.statecode -eq 1) { 'on' } else { 'off' }), @($mine | Where-Object crdr_enabled).Count, $mine.Count, $(if ($writes) { '  WRITES OUTSIDE CHANGE RADAR' } else { '' }))
}
if (-not $On -and -not $Off) { return }

$plan = Get-HandlerPlan -Installed $installed -Subscriptions $subs -On $On -Off $Off
if ($plan.error) { throw "Nothing changed: $($plan.error)." }

# Readiness for the handlers being turned on: their connection and a destination of their kind.
$cfg = @{}; foreach ($c in @((Invoke-Dv -Path 'crdr_configs?$select=crdr_key,crdr_value').value)) { $cfg[$c.crdr_key] = "$($c.crdr_value)" }
$dest = "$($cfg['alert_destinations']);$(if ($cfg['alert_recipient']) { "chat:$($cfg['alert_recipient'])" })"
$refs = @{}; foreach ($r in @((Invoke-Dv -Path "connectionreferences?`$select=connectionreferencelogicalname,connectionid&`$filter=startswith(connectionreferencelogicalname,'crdr_')").value)) { $refs[$r.connectionreferencelogicalname] = [bool]$r.connectionid }
$warn = foreach ($n in @($On | ForEach-Object { $_.Trim() })) {
    $teams = $n -in 'Notify-Teams', 'Digest-Weekly'; $email = $n -in 'Notify-Email', 'Digest-Email'
    if ($teams -and -not $refs['crdr_teams']) { "$($n): the Teams connection reference (crdr_teams) has no connection: the flow won't turn on" }
    if ($teams -and $dest -notmatch '(^|;)\s*(chat|channel):\S') { "$($n): no chat: or channel: destination; set alert_destinations or alert_recipient (setup/Import-Config.ps1)" }
    if ($email -and -not $refs['crdr_outlook']) { "$($n): the Outlook connection reference (crdr_outlook) has no connection: the flow won't turn on" }
    if ($email -and $dest -notmatch '(^|;)\s*email:\S') { "$($n): no email: destination in alert_destinations" }
    if (@($subRows | Where-Object { "$($_.crdr_handler)" -ieq $n -and $_.crdr_writes }).Count) { "$($n): writes outside Change Radar (see its documentation for what, where and as whom)" }
}

Write-Host "`nPLAN"
if (-not $plan.steps) { Write-Host '  nothing to change: already as asked.' }
foreach ($s in $plan.steps) { Write-Host "  $s" }
foreach ($w in @($warn)) { Write-Host "  WARNING $w" }
if (-not $Apply -or -not $plan.steps) { if ($plan.steps) { Write-Host 'Plan only. Nothing was changed. Re-run with -Apply.' }; return }

foreach ($s in $plan.steps) {
    if ($s -match '^flow (.+) (on|off)$') {
        $f = $flowRows | Where-Object { (Get-HandlerName $_.name) -ieq $Matches[1] } | Select-Object -First 1
        $state = if ($Matches[2] -eq 'on') { @{ statecode = 1; statuscode = 2 } } else { @{ statecode = 0; statuscode = 1 } }
        Invoke-Dv -Method PATCH -Path "workflows($($f.workflowid))" -Body $state | Out-Null
    } elseif ($s -match '^subscription (.+) (enable|disable)$') {
        $r = $subRows | Where-Object crdr_name -eq $Matches[1] | Select-Object -First 1
        Invoke-Dv -Method PATCH -Path "crdr_subscriptions($($r.crdr_subscriptionid))" -Body @{ crdr_enabled = ($Matches[2] -eq 'enable') } | Out-Null
    }
    Write-Host "  done: $s"
}
Write-Host 'Done. Check with setup/Test-Install.ps1.'
