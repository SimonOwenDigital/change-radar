#Requires -Version 7.0
<#
.SYNOPSIS
    Proves what the Change Radar User role can and can't do (ADR 0022; install test), as the signed-in user.
.DESCRIPTION
    Run it signed in (az login) as someone who holds Change Radar User and Basic User and no admin or customizer role;
    it refuses otherwise, because an admin would pass every case. Expected outcomes (solutions/design/roles.json):
      allowed  read one row from every Change Radar table
      allowed  update an exposure's status, an assessment's override reason, a signal's Watched flag, a fingerprint's
               status (each written back with the value it already has, so nothing changes)
      allowed  see the Change Radar app (app module)
      refused  update a setting (crdr_config), a feed, a rule; create a rule, a subscription, a vocabulary value, a signal
    A refused create that unexpectedly succeeds is deleted at once and reported as a failure. Writes nothing else.
.EXAMPLE
    ./setup/dev/Test-UserRole.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
function Get-Hdr { @{ Authorization = "Bearer $(az account get-access-token --resource $EnvironmentUrl --query accessToken -o tsv)"; Accept = 'application/json'; 'OData-Version' = '4.0' } }
$hd = Get-Hdr
function Send([string]$Method, [string]$Path, $Body) {
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = $hd + @{ 'If-Match' = '*' }; SkipHttpErrorCheck = $true; StatusCodeVariable = 'sc' }
    if ($Method -eq 'POST') { $p.Headers = $hd + @{ Prefer = 'return=representation' } }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5)); $p.ContentType = 'application/json; charset=utf-8' }
    $r = Invoke-RestMethod @p
    [pscustomobject]@{ Status = [int]$sc; Body = $r }
}
$org = Invoke-RestMethod -Headers $hd -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$me = (Invoke-RestMethod -Headers $hd -Uri "$dv/WhoAmI").UserId
$roles = @((Invoke-RestMethod -Headers $hd -Uri "$dv/systemusers($me)/systemuserroles_association?`$select=name").value.name)
$admin = @($roles | Where-Object { $_ -in 'System Administrator', 'System Customizer', 'Change Radar Admin' })
if ($admin -or $roles -notcontains 'Change Radar User') { throw "Refusing: the signed-in user must hold Change Radar User and no admin or customizer role. Holds: $($roles -join ', ')." }
Write-Host "Signed-in user holds: $($roles -join ', ')"

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
$results = [Collections.Generic.List[object]]::new()
function Add-Result($Case, $Expect, $Got, $Note) { $ok = ($Expect -eq 'allowed' -and $Got -lt 300) -or ($Expect -eq 'refused' -and $Got -eq 403); $results.Add([pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Case = $Case; Expected = $Expect; Status = $Got; Note = $Note }) }

# Reads
foreach ($t in $schema.tables) {
    $set = (Invoke-RestMethod -Headers $hd -Uri "$dv/EntityDefinitions(LogicalName='crdr_$($t.name)')?`$select=EntitySetName").EntitySetName
    $r = Send 'GET' "$($set)?`$top=1"
    Add-Result "read crdr_$($t.name)" 'allowed' $r.Status ''
}
$app = Send 'GET' "appmodules?`$select=name&`$filter=uniquename eq 'crdr_ChangeRadar'"
Add-Result 'see the Change Radar app' 'allowed' $(if ($app.Status -lt 300 -and @($app.Body.value).Count) { 200 } else { 403 }) ''

# Allowed writes: write back the current value
function First([string]$set, [string]$select) { (Send 'GET' "$($set)?`$select=$select&`$top=1").Body.value | Select-Object -First 1 }
$ex = First 'crdr_exposures' 'crdr_exposureid,crdr_status'
if ($ex) { Add-Result 'update exposure status' 'allowed' (Send 'PATCH' "crdr_exposures($($ex.crdr_exposureid))" @{ crdr_status = $ex.crdr_status }).Status 'same value' }
$as = First 'crdr_assessments' 'crdr_assessmentid,crdr_overridereason'
if ($as) { Add-Result 'update assessment override' 'allowed' (Send 'PATCH' "crdr_assessments($($as.crdr_assessmentid))" @{ crdr_overridereason = $as.crdr_overridereason }).Status 'same value' }
$sg = First 'crdr_signals' 'crdr_signalid,crdr_watched'
Add-Result 'update signal Watched' 'allowed' (Send 'PATCH' "crdr_signals($($sg.crdr_signalid))" @{ crdr_watched = [bool]$sg.crdr_watched }).Status 'same value'
$fp = First 'crdr_signalfingerprints' 'crdr_signalfingerprintid,crdr_status'
Add-Result 'update fingerprint status' 'allowed' (Send 'PATCH' "crdr_signalfingerprints($($fp.crdr_signalfingerprintid))" @{ crdr_status = $fp.crdr_status }).Status 'same value'

# Refused writes
$cf = First 'crdr_configs' 'crdr_configid,crdr_value'
Add-Result 'update a setting' 'refused' (Send 'PATCH' "crdr_configs($($cf.crdr_configid))" @{ crdr_value = $cf.crdr_value }).Status 'same value'
$fd = First 'crdr_feeds' 'crdr_feedid,crdr_active'
Add-Result 'update a feed' 'refused' (Send 'PATCH' "crdr_feeds($($fd.crdr_feedid))" @{ crdr_active = [bool]$fd.crdr_active }).Status 'same value'
$ru = First 'crdr_rules' 'crdr_ruleid,crdr_active'
Add-Result 'update a rule' 'refused' (Send 'PATCH' "crdr_rules($($ru.crdr_ruleid))" @{ crdr_active = [bool]$ru.crdr_active }).Status 'same value'
foreach ($c in @(
        @{ Case = 'create a rule'; Set = 'crdr_rules'; Key = 'crdr_ruleid'; Body = @{ crdr_name = '[TEST] role test' } },
        @{ Case = 'create a subscription'; Set = 'crdr_subscriptions'; Key = 'crdr_subscriptionid'; Body = @{ crdr_name = '[TEST] role test'; crdr_eventtype = $base; crdr_handler = 'none'; crdr_enabled = $false } },
        @{ Case = 'create a vocabulary value'; Set = 'crdr_facetvalues'; Key = 'crdr_facetvalueid'; Body = @{ crdr_name = '[TEST] role test' } },
        @{ Case = 'create a signal'; Set = 'crdr_signals'; Key = 'crdr_signalid'; Body = @{ crdr_title = '[TEST] role test'; crdr_externalid = 'TEST-ROLE-0001' } })) {
    $r = Send 'POST' $c.Set $c.Body
    $note = ''
    if ($r.Status -lt 300) { $id = $r.Body.($c.Key); Send 'DELETE' "$($c.Set)($id)" | Out-Null; $note = 'created unexpectedly; deleted' }
    Add-Result $c.Case 'refused' $r.Status $note
}

$results | Format-Table -AutoSize | Out-String -Width 200
$failed = @($results | Where-Object Result -eq 'FAIL').Count
"$($results.Count - $failed) passed, $failed failed, $($results.Count) cases"
if ($failed) { exit 1 }
