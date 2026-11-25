#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the phase 1 collectors into ChangeRadarCore in the dev environment. Plans by default; -Apply to change.

.DESCRIPTION
    Creates or updates, inside solution ChangeRadarCore:
      - environment variables crdr_tenantid, crdr_readerclientid (text) and crdr_readercertificate (secret, Key Vault),
        with values for this environment (values are not committed; strip them from exports, see docs)
      - connection reference crdr_dataverse -> an existing Microsoft Dataverse connection you own (-ConnectionId)
      - connection reference crdr_powerplatformadmin -> a Power Platform for Admins V2 connection (-AdminConnectionId);
        the estate inventory flow waits until it's given (ADR 0008)
      - connection reference crdr_teams -> a Microsoft Teams connection (-TeamsConnectionId); the Notify-Teams and
        Digest-Weekly handlers wait until it's given (ADR 0011)
      - connection reference crdr_outlook -> an Office 365 Outlook connection (-OutlookConnectionId), created empty
        until one is given; the Notify-Email and Digest-Email handlers are saved switched off, and turned on only with
        -EnableEmail (ADR 0011 addendum: email ships off)
      - the cloud flows generated in solutions/design/flows/*.json, turned on
    and upserts crdr_config rows from seed/config.csv (data, by alternate key crdr_key). Install-time settings are
    never in the repo: -AlertRecipient sets alert_recipient, -AlertDestinations sets alert_destinations, and app_url is derived from this environment's app.

    Writes only to the dev environment named by -ExpectedEnvironmentName. Reads Azure and Entra ID to resolve the
    tenant id, client id and vault secret path; changes nothing there.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ConnectionId,
    [string]$AdminConnectionId,
    [string]$TeamsConnectionId,
    [string]$OutlookConnectionId,
    [switch]$EnableEmail,      # turn on Notify-Email and Digest-Email (needs the crdr_outlook connection)
    [string]$AlertRecipient,   # user principal name that receives Change Radar cards (ADR 0011); tenant data, so command line only
    [string]$AlertDestinations, # chat:/channel:/email: entries separated by ';' (ADR 0011 addendum); tenant data, so command line only
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SolutionUniqueName = 'ChangeRadarCore',
    [string]$HandlersSolution = 'ChangeRadarHandlers',   # ADR 0023: the handlers, their template and the Teams and Outlook references
    [string]$ResourceGroup = 'rg-crdr-dev',
    [string]$VaultName,
    [string]$SecretName = 'crdr-reader',
    [string]$AppName = 'crdr-reader',
    [string]$FlowDir = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'flows'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' '..' 'seed' 'config.csv'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
$flowNames = [ordered]@{
    CollectServiceHealth = 'Change Radar: collect service health'
    CollectMessageCenter = 'Change Radar: collect Message Center'
    CollectRoadmap       = 'Change Radar: collect roadmap'
    CollectLearnTables   = 'Change Radar: collect Learn page tables (feeds)'
    CollectLearnSections = 'Change Radar: collect Learn page sections (feeds)'
    CollectRssFeeds      = 'Change Radar: collect RSS feeds'
    CollectWebSections   = 'Change Radar: collect web page sections (feeds)'
    CollectPdfChangeLogs = 'Change Radar: collect licensing guide change logs (feeds)'
    RecomputeHorizons    = 'Change Radar: recompute horizons'
    CollectEstate        = 'Change Radar: collect estate inventory'
    CollectDetail        = 'Change Radar: collect Dataverse detail'
    MatchExposures       = 'Change Radar: match exposures'
    FingerprintSignals   = 'Change Radar: fingerprint signals'
    AssessSignals        = 'Change Radar: assess signals'
    RecordOverride       = 'Change Radar: record assessment override'
    RaiseSignalEvents    = 'Change Radar: raise signal events'
    RaiseDeadlineEvents  = 'Change Radar: raise deadline events'
    DispatchEvents       = 'Change Radar: dispatch events'
    NotifyTeams          = 'Change Radar handler: Notify-Teams'
    DigestWeekly         = 'Change Radar handler: Digest-Weekly'
    NotifyEmail          = 'Change Radar handler: Notify-Email'
    DigestEmail          = 'Change Radar handler: Digest-Email'
    ReadableSummary      = 'Change Radar: readable summary'
    HandlerTemplate      = 'Change Radar handler: Handler template'
}
# ADR 0023: these live in ChangeRadarHandlers. In this dev environment a handler keeps whatever state it is in (new ones
# arrive off); the Handlers export ships them all off whatever their state here.
$handlerFlows = @('NotifyTeams', 'DigestWeekly', 'NotifyEmail', 'DigestEmail', 'HandlerTemplate')
$handlerRefs = @('crdr_teams', 'crdr_outlook')
# Flows that need the Power Platform for Admins V2 connection (delegated, ADR 0008). Skipped until -AdminConnectionId is given.
$adminFlows = @('CollectEstate')
# Flows that post to Teams (ADR 0011). Skipped until -TeamsConnectionId is given.
$teamsFlows = @('NotifyTeams', 'DigestWeekly')
# Flows that send email (ADR 0011 addendum). Saved switched off; turned on only with -EnableEmail and a connection.
$emailFlows = @('NotifyEmail', 'DigestEmail')

Import-Module Az.Accounts -ErrorAction Stop
function Get-Token([string]$r) { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $r -AsSecureString).Token -AsPlainText }
function Invoke-Dv([string]$Method = 'GET', [string]$Path, $Body, [hashtable]$Extra = @{}) {
    $h = @{ Authorization = "Bearer $(Get-Token $EnvironmentUrl)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'return=representation' } + $Extra
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = $h }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @p } catch { $d = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $_.Exception.Message }; throw "$Method $Path failed: $d" }
}
function Get-One([string]$path) { @((Invoke-Dv -Path $path).value) | Select-Object -First 1 }
# ADR 0023: a component moves by being added to Handlers first, then removed from Core, so it's never in neither.
function Move-ToHandlers([string]$id, [int]$type) {
    if (-not (Test-InSolution $id $HandlersSolution)) { Invoke-Dv -Method POST -Path 'AddSolutionComponent' -Body @{ ComponentId = $id; ComponentType = $type; SolutionUniqueName = $HandlersSolution; AddRequiredComponents = $false } | Out-Null }
    # RemoveSolutionComponent (Web API) takes a solutioncomponent whose id is the component's own id; the type comes from
    # ComponentType (Learn reference 2026-11-24; the row id is refused, observed in pp-lab).
    if (Test-InSolution $id $SolutionUniqueName) { Invoke-Dv -Method POST -Path 'RemoveSolutionComponent' -Body @{ SolutionComponent = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.solutioncomponent'; solutioncomponentid = $id }; ComponentType = $type; SolutionUniqueName = $SolutionUniqueName } | Out-Null }
}

# ---------- guards and inputs ----------
$org = Invoke-Dv -Path 'RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType''Default'')'
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Stopping." }
$solIds = @{}
foreach ($sn in $SolutionUniqueName, $HandlersSolution) { $r = Get-One "solutions?`$select=solutionid&`$filter=uniquename eq '$sn'"; if (-not $r) { throw "Solution $sn not found." }; $solIds[$sn] = $r.solutionid }
function Get-SolutionFor([string]$key) { if ($handlerFlows -contains $key -or $handlerRefs -contains $key) { $HandlersSolution } else { $SolutionUniqueName } }
function Test-InSolution([string]$objectId, [string]$sn) { [bool](Get-One "solutioncomponents?`$select=solutioncomponentid&`$filter=objectid eq $objectId and _solutionid_value eq $($solIds[$sn])") }
if (-not $VaultName) {
    $hx = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SubscriptionId))).ToLowerInvariant()
    $VaultName = "kv-crdr-dev-$($hx.Substring(0, 4))"
}
$tenantId = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $(Get-Token 'https://management.azure.com/')" } -Uri "https://management.azure.com/subscriptions/$($SubscriptionId)?api-version=2022-12-01").tenantId
$apps = @((Invoke-RestMethod -Headers @{ Authorization = "Bearer $(Get-Token 'https://graph.microsoft.com/')" } -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppName'&`$select=appId").value)
if ($apps.Count -ne 1) { throw "Expected one app registration named '$AppName'." }
$secretPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$VaultName/secrets/$SecretName"

$vars = @(
    @{ schema = 'crdr_tenantid'; display = 'Tenant ID'; type = 100000000; value = $tenantId; desc = 'Microsoft Entra tenant ID (GUID)' }
    @{ schema = 'crdr_readerclientid'; display = 'Reader client ID'; type = 100000000; value = $apps[0].appId; desc = 'Application (client) ID of the read-only app registration (crdr-reader)' }
    @{ schema = 'crdr_readercertificate'; display = 'Reader certificate'; type = 100000005; value = $secretPath; desc = 'Key Vault secret holding the reader certificate (PFX). Value: /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/secrets/<name>' }
)

# ---------- plan ----------
$steps = [System.Collections.Generic.List[object]]::new()
function Add-Step([string]$area, [string]$name, [string]$status, [hashtable]$data, [scriptblock]$action) { $steps.Add([pscustomobject]@{ Area = $area; Name = $name; Status = $status; Data = $data; Action = $action }) }

foreach ($v in $vars) {
    $def = Get-One "environmentvariabledefinitions?`$select=environmentvariabledefinitionid&`$filter=schemaname eq '$($v.schema)'"
    $val = if ($def) { Get-One "environmentvariablevalues?`$select=environmentvariablevalueid,value&`$filter=_environmentvariabledefinitionid_value eq $($def.environmentvariabledefinitionid)" } else { $null }
    $status = if (-not $def) { 'create' } elseif (-not $val) { 'set value' } elseif ($val.value -ne $v.value) { 'update value' } else { 'exists' }
    Add-Step 'Environment variable' "$($v.schema) ($($v.type -eq 100000005 ? 'secret, Key Vault' : 'text'))" $status @{ vv = $v; d = $def; x = $val } {
        param($StepData); $vv = $StepData['vv']; $d = $StepData['d']; $x = $StepData['x']
        $defId = if ($d) { $d.environmentvariabledefinitionid } else {
            $body = @{ schemaname = $vv.schema; displayname = $vv.display; type = $vv.type; description = $vv.desc }
            if ($vv.type -eq 100000005) { $body.secretstore = 0 }
            (Invoke-Dv -Method POST -Path 'environmentvariabledefinitions' -Body $body -Extra @{ 'MSCRM.SolutionUniqueName' = $SolutionUniqueName }).environmentvariabledefinitionid
        }
        if ($x) { Invoke-Dv -Method PATCH -Path "environmentvariablevalues($($x.environmentvariablevalueid))" -Body @{ value = $vv.value } | Out-Null }
        else { Invoke-Dv -Method POST -Path 'environmentvariablevalues' -Body @{ schemaname = "$($vv.schema)_value"; value = $vv.value; 'EnvironmentVariableDefinitionId@odata.bind' = "/environmentvariabledefinitions($defId)" } | Out-Null }
    }
}

$cr = Get-One "connectionreferences?`$select=connectionreferenceid,connectionid&`$filter=connectionreferencelogicalname eq 'crdr_dataverse'"
$crStatus = if (-not $cr) { 'create' } elseif ($ConnectionId -and $cr.connectionid -ne $ConnectionId) { 'update' } else { 'exists' }
Add-Step 'Connection reference' 'crdr_dataverse -> Microsoft Dataverse' $crStatus @{ crRef = $cr; cid = $ConnectionId } {
    param($StepData); $crRef = $StepData['crRef']; $cid = $StepData['cid']
    if (-not $cid) { throw 'Pass -ConnectionId (pac connection list --environment <url>).' }
    if ($crRef) { Invoke-Dv -Method PATCH -Path "connectionreferences($($crRef.connectionreferenceid))" -Body @{ connectionid = $cid } | Out-Null }
    else { Invoke-Dv -Method POST -Path 'connectionreferences' -Extra @{ 'MSCRM.SolutionUniqueName' = $SolutionUniqueName } -Body @{ connectionreferencelogicalname = 'crdr_dataverse'; connectionreferencedisplayname = 'Change Radar Dataverse'; connectorid = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'; connectionid = $cid; description = 'Dataverse connection used by Change Radar flows to read config and write signals' } | Out-Null }
}

$acr = Get-One "connectionreferences?`$select=connectionreferenceid,connectionid&`$filter=connectionreferencelogicalname eq 'crdr_powerplatformadmin'"
$acrStatus = if (-not $AdminConnectionId -and -not ($acr -and $acr.connectionid)) { 'WAITING' } elseif (-not $acr) { 'create' } elseif ($AdminConnectionId -and $acr.connectionid -ne $AdminConnectionId) { 'update' } else { 'exists' }
Add-Step 'Connection reference' 'crdr_powerplatformadmin -> Power Platform for Admins V2' $acrStatus @{ crRef = $acr; cid = $AdminConnectionId } {
    param($StepData); $crRef = $StepData['crRef']; $cid = $StepData['cid']
    if ($crRef) { Invoke-Dv -Method PATCH -Path "connectionreferences($($crRef.connectionreferenceid))" -Body @{ connectionid = $cid } | Out-Null }
    else { Invoke-Dv -Method POST -Path 'connectionreferences' -Extra @{ 'MSCRM.SolutionUniqueName' = $SolutionUniqueName } -Body @{ connectionreferencelogicalname = 'crdr_powerplatformadmin'; connectionreferencedisplayname = 'Change Radar Power Platform admin (delegated)'; connectorid = '/providers/Microsoft.PowerApps/apis/shared_powerplatformadminv2'; connectionid = $cid; description = 'Delegated Power Platform for Admins V2 connection used to read tenant inventory (ADR 0008). Read-only use: Query Power Platform resources.' } | Out-Null }
}
$adminReady = $acrStatus -ne 'WAITING'

$tcr = Get-One "connectionreferences?`$select=connectionreferenceid,connectionid&`$filter=connectionreferencelogicalname eq 'crdr_teams'"
$tcrStatus = if (-not $TeamsConnectionId -and -not ($tcr -and $tcr.connectionid)) { 'WAITING' } elseif (-not $tcr) { 'create' } elseif ($TeamsConnectionId -and $tcr.connectionid -ne $TeamsConnectionId) { 'update' } else { 'exists' }
Add-Step 'Connection reference' 'crdr_teams -> Microsoft Teams' $tcrStatus @{ crRef = $tcr; cid = $TeamsConnectionId } {
    param($StepData); $crRef = $StepData['crRef']; $cid = $StepData['cid']
    if ($crRef) { Invoke-Dv -Method PATCH -Path "connectionreferences($($crRef.connectionreferenceid))" -Body @{ connectionid = $cid } | Out-Null }
    else { Invoke-Dv -Method POST -Path 'connectionreferences' -Extra @{ 'MSCRM.SolutionUniqueName' = $HandlersSolution } -Body @{ connectionreferencelogicalname = 'crdr_teams'; connectionreferencedisplayname = 'Change Radar Teams'; connectorid = '/providers/Microsoft.PowerApps/apis/shared_teams'; connectionid = $cid; description = 'Microsoft Teams connection the Notify-Teams and Digest-Weekly handlers post cards with, as the Flow bot in a chat with alert_recipient (ADR 0011). Posts only; reads nothing.' } | Out-Null }
}
$teamsReady = $tcrStatus -ne 'WAITING'

$ocr = Get-One "connectionreferences?`$select=connectionreferenceid,connectionid&`$filter=connectionreferencelogicalname eq 'crdr_outlook'"
$ocrStatus = if (-not $ocr) { 'create' } elseif ($OutlookConnectionId -and $ocr.connectionid -ne $OutlookConnectionId) { 'update' } else { 'exists' }
Add-Step 'Connection reference' "crdr_outlook -> Office 365 Outlook$(if (-not $OutlookConnectionId -and -not ($ocr -and $ocr.connectionid)) { ' (no connection yet)' })" $ocrStatus @{ crRef = $ocr; cid = $OutlookConnectionId } {
    param($StepData); $crRef = $StepData['crRef']; $cid = $StepData['cid']
    if ($crRef) { Invoke-Dv -Method PATCH -Path "connectionreferences($($crRef.connectionreferenceid))" -Body @{ connectionid = $cid } | Out-Null }
    else {
        $body = @{ connectionreferencelogicalname = 'crdr_outlook'; connectionreferencedisplayname = 'Change Radar Outlook'; connectorid = '/providers/Microsoft.PowerApps/apis/shared_office365'; description = 'Office 365 Outlook connection the Notify-Email and Digest-Email handlers send alerts with (Send an email (V2)), as the connection owner, to the email: entries in alert_destinations (ADR 0011 addendum). Sends only; reads nothing. Optional: email ships off.' }
        if ($cid) { $body.connectionid = $cid }
        Invoke-Dv -Method POST -Path 'connectionreferences' -Extra @{ 'MSCRM.SolutionUniqueName' = $HandlersSolution } -Body $body | Out-Null
    }
}
# ADR 0023: move existing Teams and Outlook references from Core to Handlers (add to Handlers, then remove from Core).
foreach ($refName in $handlerRefs) {
    $ref = Get-One "connectionreferences?`$select=connectionreferenceid&`$filter=connectionreferencelogicalname eq '$refName'"
    if ($ref -and ((Test-InSolution $ref.connectionreferenceid $SolutionUniqueName) -or -not (Test-InSolution $ref.connectionreferenceid $HandlersSolution))) {
        Add-Step 'Solution' "move $refName to $HandlersSolution" 'move' @{ id = $ref.connectionreferenceid; type = 10169 } { param($StepData); Move-ToHandlers $StepData['id'] $StepData['type'] }
    }
}
$emailReady = [bool]($OutlookConnectionId -or ($ocr -and $ocr.connectionid))
if ($EnableEmail -and -not $emailReady) { throw '-EnableEmail needs an Office 365 Outlook connection: pass -OutlookConnectionId.' }

# Install-time settings (tenant data): from the command line or this environment, never from the seed.
$installValues = @{}
if ($AlertRecipient) { $installValues['alert_recipient'] = $AlertRecipient }
if ($AlertDestinations) { $installValues['alert_destinations'] = $AlertDestinations }
$appRow = Get-One "appmodules?`$select=appmoduleid&`$filter=uniquename eq 'crdr_ChangeRadar'"
if ($appRow) { $installValues['app_url'] = "$EnvironmentUrl/main.aspx?appid=$($appRow.appmoduleid)" }

foreach ($row in Import-Csv $ConfigPath) {
    $cur = Get-One "crdr_configs?`$select=crdr_value,crdr_description&`$filter=crdr_key eq '$($row.key)'"
    $install = $installValues.ContainsKey($row.key)
    $status = if ($install -and (-not $cur -or $cur.crdr_value -ne $installValues[$row.key])) { 'set' } elseif (-not $cur) { 'create' } elseif ($cur.crdr_value -ne $row.value -and -not $install) { 'KEEP' } elseif ($cur.crdr_description -ne $row.description) { 'update' } else { 'exists' }
    # Existing values are installer settings: never overwritten (KEEP), only descriptions are refreshed. Install-time
    # values given on the command line (or derived from the environment) are set.
    Add-Step 'Config' $row.key $status @{ r = $row; isNew = (-not $cur); value = $installValues[$row.key] } {
        param($StepData); $r = $StepData['r']; $isNew = $StepData['isNew']
        $body = @{ crdr_description = $r.description }; if ($StepData['value']) { $body.crdr_value = $StepData['value'] } elseif ($isNew) { $body.crdr_value = $r.value }
        Invoke-Dv -Method PATCH -Path "crdr_configs(crdr_key='$([uri]::EscapeDataString($r.key))')" -Body $body | Out-Null
    }
}

foreach ($file in $flowNames.Keys) {
    $clientdata = (Get-Content -Raw (Join-Path $FlowDir "$file.json") | ConvertFrom-Json -Depth 80 | ConvertTo-Json -Depth 80 -Compress)
    $name = $flowNames[$file]
    $wf = Get-One "workflows?`$select=workflowid,clientdata,statecode&`$filter=name eq '$name' and category eq 5"
    $same = $wf -and (($wf.clientdata | ConvertFrom-Json -Depth 80 | ConvertTo-Json -Depth 80 -Compress) -eq $clientdata)
    $isHandler = $handlerFlows -contains $file
    # Handlers keep their state here (ADR 0023); email flows come on only with -EnableEmail; the template stays off.
    $turnOn = if ($file -eq 'HandlerTemplate') { $false } elseif ($emailFlows -contains $file) { [bool]$EnableEmail -or ($wf -and $wf.statecode -eq 1) } elseif ($isHandler) { [bool]($wf -and $wf.statecode -eq 1) } else { $true }
    $status = if (-not $wf) { 'create' } elseif (-not $same) { 'update' } elseif ($turnOn -and $wf.statecode -ne 1) { 'turn on' } else { 'exists' }
    if ($isHandler -and $wf -and ((Test-InSolution $wf.workflowid $SolutionUniqueName) -or -not (Test-InSolution $wf.workflowid $HandlersSolution))) {
        Add-Step 'Solution' "move $name to $HandlersSolution" 'move' @{ id = $wf.workflowid; type = 29 } { param($StepData); Move-ToHandlers $StepData['id'] $StepData['type'] }
    }
    # Dataverse refuses to update a flow whose connection reference has no connection yet, though it lets one be created
    # (observed in pp-lab, 2026-11-23). Until the Outlook connection exists, an email flow is replaced instead.
    $recreate = $emailFlows -contains $file -and -not $emailReady -and $status -eq 'update'
    if ($recreate) { $status = 'replace' }
    if (-not $turnOn -and $status -ne 'exists') { $status = "$status (off)" }
    if ($adminFlows -contains $file -and -not $adminReady) { $status = 'WAITING' }
    if ($teamsFlows -contains $file -and -not $teamsReady) { $status = 'WAITING' }
    $desc = ((Get-Content -Raw (Join-Path $FlowDir "$file.json") | ConvertFrom-Json -Depth 80).properties.definition.description)
    Add-Step 'Cloud flow' $name $status @{ w = $wf; cd = $clientdata; n = $name; desc = $desc; on = $turnOn; re = $recreate; sol = (Get-SolutionFor $file) } {
        param($StepData); $w = $StepData['w']; $cd = $StepData['cd']; $n = $StepData['n']; $desc = $StepData['desc']
        if ($StepData['re']) { Invoke-Dv -Method DELETE -Path "workflows($($w.workflowid))" | Out-Null; $w = $null }
        if ($w) {
            if ($w.statecode -eq 1) { Invoke-Dv -Method PATCH -Path "workflows($($w.workflowid))" -Body @{ statecode = 0; statuscode = 1 } | Out-Null }
            Invoke-Dv -Method PATCH -Path "workflows($($w.workflowid))" -Body @{ clientdata = $cd; description = $desc } | Out-Null
            $id = $w.workflowid
        } else {
            $id = (Invoke-Dv -Method POST -Path 'workflows' -Extra @{ 'MSCRM.SolutionUniqueName' = $StepData['sol'] } -Body @{ name = $n; category = 5; type = 1; primaryentity = 'none'; clientdata = $cd; description = $desc }).workflowid
        }
        if ($StepData['on']) { Invoke-Dv -Method PATCH -Path "workflows($id)" -Body @{ statecode = 1; statuscode = 2 } | Out-Null }
    }
}

Write-Host "`nPLAN ($ExpectedEnvironmentName, solution $SolutionUniqueName)"
foreach ($s in $steps) { Write-Host ("  {0,-12} {1,-21} {2}" -f $s.Status, $s.Area, $s.Name) }
$todo = @($steps | Where-Object Status -notin 'exists', 'KEEP', 'WAITING')
Write-Host "`nTotal: $($todo.Count) to change. KEEP = existing setting differs from seed and is left alone. WAITING = needs -AdminConnectionId (Power Platform for Admins V2) or -TeamsConnectionId (Microsoft Teams)."
if (-not $Apply) { return }
$i = 0
foreach ($s in $todo) { $i++; Write-Host "[$i/$($todo.Count)] $($s.Area): $($s.Name)"; & $s.Action $s.Data }
Write-Host "`nDone."
