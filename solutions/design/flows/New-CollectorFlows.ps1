#Requires -Version 7.0
<#
.SYNOPSIS
    Generates the phase 1 cloud flow definitions (clientdata JSON) for ChangeRadarCore. Never deploys anything.

.DESCRIPTION
    Writes one <name>.json per flow next to this script. Generate, don't hand-edit (power-automate-lessons §2):
    change this script, re-run it, review the diff, then deploy with setup/dev/Deploy-CollectorsToDev.ps1.

    Flows (ADR 0007 for horizons; spike T6 for authentication):
      CollectServiceHealth  every 15 min  Graph /admin/serviceAnnouncement/issues    -> crdr_signal (graph_health)
      CollectMessageCenter  hourly        Graph /admin/serviceAnnouncement/messages  -> crdr_signal (graph_mc)
      CollectRoadmap        daily         public Microsoft Copilot Roadmap JSON      -> crdr_signal (roadmap)
      RecomputeHorizons     daily         re-rates Message Center and roadmap signals as dates approach
      CollectEstate         daily         Power Platform inventory (delegated, ADR 0008)          -> crdr_asset + crdr_assetfingerprint

    Each collector: reads crdr_config, fetches, keeps in-scope items, shapes them into signal fields, skips items
    whose id + last-modified already match a stored signal, then creates or updates the signal and writes a
    crdr_signalversion snapshot. Every run writes one crdr_collectionrun row (tier, counts, gaps), whatever happened.

    Nothing tenant-specific is generated: tenant id and client id are environment variables, the certificate is a
    Key Vault secret environment variable, and Dataverse goes through connection reference crdr_dataverse.
#>
[CmdletBinding()]
param(
    [string]$OutDir = $PSScriptRoot,
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' 'schema.json'),
    [string]$RoadmapMapPath = (Join-Path $PSScriptRoot '..' '..' '..' 'seed' 'roadmap-product-map.csv'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' '..' '..' 'seed' 'config.csv'),
    [string]$SignaturesPath = (Join-Path $PSScriptRoot '..' '..' '..' 'seed' 'asset-signatures.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- solution constants ----------
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) {
    $i = [array]::IndexOf(@($schema.choices.$choice), $value)
    if ($i -lt 0) { throw "Choice '$choice' has no value '$value'." }
    $base + $i
}
$src = @{ mc = Get-Opt 'signalsource' 'graph_mc'; health = Get-Opt 'signalsource' 'graph_health'; roadmap = Get-Opt 'signalsource' 'roadmap' }
$hz = @{ now = Get-Opt 'horizon' 'now'; imminent = Get-Opt 'horizon' 'imminent'; future = Get-Opt 'horizon' 'future' }
$tier = @{ full = Get-Opt 'accesstier' 'full'; public = Get-Opt 'accesstier' 'public' }
$config = @{}; Import-Csv $ConfigPath | ForEach-Object { $config[$_.key] = $_.value }
# Change Radar's own prompts, called by id (solutions/design/prompts.json; ADR 0017).
$ownPrompts = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'prompts.json') | ConvertFrom-Json
$roadmapProducts = @(Import-Csv $RoadmapMapPath | Where-Object in_scope -eq 'true' | ForEach-Object roadmap_product)

$dvApi = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'
$auth = "@parameters('`$authentication')"
$allStates = @('Succeeded', 'Failed', 'Skipped', 'TimedOut')

# ---------- helpers ----------
function Dv([string]$op, [hashtable]$params, [hashtable]$runAfter = @{}, [hashtable]$extra = @{}) {
    $a = [ordered]@{ type = 'OpenApiConnection'; runAfter = $runAfter
        inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_commondataserviceforapps'; operationId = $op; apiId = $dvApi }; parameters = $params; authentication = $auth } }
    foreach ($k in $extra.Keys) { $a[$k] = $extra[$k] }
    $a
}
function After([string]$name, [string[]]$states = @('Succeeded')) { @{ $name = $states } }
function Trunc([string]$expr, [int]$n) { "if(greater(length(coalesce($expr, '')), $n), substring($expr, 0, $n), coalesce($expr, ''))" }
function DateKey([string]$expr) { "if(empty($expr), '', formatDateTime($expr, 'yyyy-MM-ddTHH:mm:ss'))" }
function Add-ConfigQuery([Collections.Specialized.OrderedDictionary]$actions, [string]$name, [string]$key) {
    $actions[$name] = [ordered]@{ type = 'Query'; runAfter = (After 'List_config'); inputs = @{ from = "@body('List_config')?['value']"; where = "@equals(item()?['crdr_key'], '$key')" } }
}
function ConfigInt([string]$query, [string]$default) { "int(coalesce(first(body('$query'))?['crdr_value'], '$default'))" }
# demo_data (ADR 0022; engine Test-DemoDataOn, tests/config/config.json): off, false, no or 0 switch demo data off; no row means on.
function DemoOff([string]$query) { "contains(createArray('off', 'false', 'no', '0'), toLower(trim(coalesce(first(body('$query'))?['crdr_value'], ''))))" }
# Catch-up (install test finding 14; engine Get-EffectiveCap, tests/config/config.json): before catchup_until ('yyyy-MM-dd')
# a per-run cap is raised to catchup_max_per_run. Textual checks only, as expressions can't test digits; the 120-day bound
# stops a malformed value meaning catch-up forever. Never lowers a cap; 0 (no cap) stays 0.
function EffectiveCap([string]$capExpr) {
    $u = "trim(coalesce(first(body('Config_catchup_until'))?['crdr_value'], ''))"
    $pad = "concat($u, '          ')"
    $cc = ConfigInt 'Config_catchup_max' $config['catchup_max_per_run']
    "if(and(greater($cc, 0), greater($capExpr, 0), equals(length($u), 10), startsWith($u, '20'), equals(substring($pad, 4, 1), '-'), equals(substring($pad, 7, 1), '-'), less(formatDateTime(utcNow(), 'yyyy-MM-dd'), $u), less($u, formatDateTime(addDays(utcNow(), 120), 'yyyy-MM-dd'))), max($capExpr, $cc), $capExpr)"
}

$envParams = [ordered]@{
    '$connections'                         = @{ defaultValue = @{}; type = 'Object' }
    '$authentication'                      = @{ defaultValue = @{}; type = 'SecureObject' }
    'Tenant ID (crdr_tenantid)'            = @{ defaultValue = ''; type = 'String'; metadata = @{ schemaName = 'crdr_tenantid'; description = 'Microsoft Entra tenant ID' } }
    'Reader client ID (crdr_readerclientid)' = @{ defaultValue = ''; type = 'String'; metadata = @{ schemaName = 'crdr_readerclientid'; description = 'Application (client) ID of the crdr-reader app registration' } }
}

function New-Flow([string]$Description, [hashtable]$Trigger, [Collections.Specialized.OrderedDictionary]$Actions, [hashtable]$ExtraReferences = @{}, [string]$TriggerName = 'Recurrence') {
    $refs = [ordered]@{ shared_commondataserviceforapps = [ordered]@{ runtimeSource = 'embedded'; connection = @{ connectionReferenceLogicalName = 'crdr_dataverse' }; api = @{ name = 'shared_commondataserviceforapps' } } }
    foreach ($k in $ExtraReferences.Keys) { $refs[$k] = [ordered]@{ runtimeSource = 'embedded'; connection = @{ connectionReferenceLogicalName = $ExtraReferences[$k] }; api = @{ name = $k } } }
    [ordered]@{
        properties    = [ordered]@{
            connectionReferences = $refs
            definition           = [ordered]@{
                '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
                contentVersion = '1.0.0.0'; parameters = $envParams
                triggers = @{ $TriggerName = $Trigger }
                actions = $Actions
                description = $Description
            }
            templateName         = ''
        }
        schemaVersion = '1.0.0.0'
    }
}
function Recurrence([string]$freq, [int]$interval, [hashtable]$schedule) {
    $r = [ordered]@{ type = 'Recurrence'; recurrence = [ordered]@{ frequency = $freq; interval = $interval } }
    if ($schedule) { $r.recurrence.schedule = $schedule }
    $r
}

# Shared tail: upsert loop + run log. $Shape is the name of the Select action holding shaped items; each has
# key, externalid, title, summary, products, horizon, keydate, datelabel, actionrequired, url, lastchanged, snapshot.
function Add-UpsertAndLog([Collections.Specialized.OrderedDictionary]$scopeActions, [string]$Shape, [int]$Source, [string]$ShapeRunAfter, [string]$FilterExpr, [hashtable]$ExtraCreate = @{}, [Collections.Specialized.OrderedDictionary]$OnCreate) {
    # $FilterExpr (optional) replaces the source filter, e.g. a feed collector's "@concat(... _crdr_feed_value eq <id>)";
    # $ExtraCreate adds fields to created signals, e.g. the feed lookup.
    $scopeActions['List_existing'] = Dv 'ListRecords' ([ordered]@{
            entityName = 'crdr_signals'
            '$select'  = 'crdr_signalid,crdr_externalid,crdr_lastchanged,crdr_title,crdr_keydate,crdr_datelabel,crdr_horizon,crdr_actionrequired'
            '$filter'  = $(if ($FilterExpr) { $FilterExpr } else { "crdr_source eq $Source" }) }) (After $ShapeRunAfter) @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
    $scopeActions['Existing_keys'] = [ordered]@{ type = 'Select'; runAfter = (After 'List_existing')
        inputs = @{ from = "@body('List_existing')?['value']"; select = "@concat(item()?['crdr_externalid'], '|', $(DateKey "item()?['crdr_lastchanged']"))" } }
    $scopeActions['Changed'] = [ordered]@{ type = 'Query'; runAfter = (After 'Existing_keys')
        inputs = @{ from = "@body('$Shape')"; where = "@not(contains(body('Existing_keys'), item()?['key']))" } }
    $it = "items('Upsert')"
    $old = "first(body('Find_existing'))"
    $fields = [ordered]@{
        'item/crdr_title' = "@${it}?['title']"; 'item/crdr_summary' = "@${it}?['summary']"; 'item/crdr_products' = "@${it}?['products']"
        'item/crdr_horizon' = "@${it}?['horizon']"; 'item/crdr_keydate' = "@${it}?['keydate']"; 'item/crdr_datelabel' = "@${it}?['datelabel']"
        'item/crdr_actionrequired' = "@${it}?['actionrequired']"; 'item/crdr_url' = "@${it}?['url']"; 'item/crdr_lastchanged' = "@${it}?['lastchanged']"
    }
    $create = [ordered]@{ entityName = 'crdr_signals'; 'item/crdr_source' = $Source; 'item/crdr_externalid' = "@${it}?['externalid']"; 'item/crdr_firstseen' = '@utcNow()' } + $fields
    foreach ($k in ($ExtraCreate.Keys | Sort-Object)) { $create[$k] = $ExtraCreate[$k] }
    $update = [ordered]@{ entityName = 'crdr_signals'; recordId = "@${old}?['crdr_signalid']" } + $fields
    $changedFields = "@concat(" + (@(
            "if(equals(${old}?['crdr_title'], ${it}?['title']), '', 'title; ')"
            "if(equals(${old}?['crdr_horizon'], ${it}?['horizon']), '', 'horizon; ')"
            "if(equals(coalesce(${old}?['crdr_datelabel'], ''), ${it}?['datelabel']), '', 'date label; ')"
            "if(equals(${old}?['crdr_actionrequired'], ${it}?['actionrequired']), '', 'action required; ')"
            "if(equals($(DateKey "${old}?['crdr_keydate']"), $(DateKey "${it}?['keydate']")), '', 'key date; ')"
            "'last modified'") -join ', ') + ")"
    function Version([string]$after, [string]$signalId, [string]$changed) {
        Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_signalversions'; 'item/crdr_name' = "@concat(${it}?['externalid'], ' ', ${it}?['lastchanged'])"
                'item/crdr_signal@odata.bind' = "@concat('/crdr_signals(', $signalId, ')')"; 'item/crdr_snapshotjson' = "@${it}?['snapshot']"
                'item/crdr_capturedon' = '@utcNow()'; 'item/crdr_changedfields' = $changed }) (After $after)
    }
    $scopeActions['Upsert'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Changed')"; runAfter = (After 'Changed')
        runtimeConfiguration = @{ concurrency = @{ repetitions = 10 } }
        actions = [ordered]@{
            Find_existing = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('List_existing')?['value']"; where = "@equals(item()?['crdr_externalid'], ${it}?['externalid'])" } }
            Is_new = [ordered]@{ type = 'If'; runAfter = (After 'Find_existing'); expression = @{ equals = @("@empty(body('Find_existing'))", $true) }
                actions = [ordered]@{
                    Create_signal = Dv 'CreateRecord' $create
                    Create_version = Version 'Create_signal' "body('Create_signal')?['crdr_signalid']" 'created'
                } + $(if ($OnCreate) { $OnCreate } else { [ordered]@{} })
                else = @{ actions = [ordered]@{
                        Update_signal = Dv 'UpdateRecord' $update
                        Update_version = Version 'Update_signal' "${old}?['crdr_signalid']" $changedFields
                    } }
            }
        } }
}
function Add-RunLog([Collections.Specialized.OrderedDictionary]$actions, [string]$collector, [string]$fetchAction, [string]$fetchedExpr, [string]$inScopeAction, [bool]$graph) {
    $ok = "equals(actions('Collect')?['status'], 'Succeeded')"
    $tierExpr = if ($graph) { "@if(equals(actions('$fetchAction')?['status'], 'Succeeded'), $($tier.full), $($tier.public))" } else { $tier.full }
    $gaps = "@if($ok, '', concat('$fetchAction ', coalesce(actions('$fetchAction')?['status'], 'not run'), ' HTTP ', string(coalesce(outputs('$fetchAction')?['statusCode'], '-')), '. ', string(coalesce(outputs('$fetchAction')?['body']?['error']?['message'], '')), ' Collect scope: ', actions('Collect')?['status']))"
    $count = { param($a) "length(coalesce(actions('$a')?['outputs']?['body'], json('[]')))" }
    $actions['Record_run'] = Dv 'CreateRecord' ([ordered]@{
            entityName = 'crdr_collectionruns'
            'item/crdr_name' = "@concat('$collector ', formatDateTime(trigger()?['startTime'], 'yyyy-MM-dd HH:mm'), ': fetched ', string($fetchedExpr), ', in scope ', string($(& $count $inScopeAction)), ', new or changed ', string($(& $count 'Changed')))"
            'item/crdr_collector' = $collector; 'item/crdr_accesstier' = $tierExpr; 'item/crdr_startedon' = "@trigger()?['startTime']"
            'item/crdr_itemcount' = "@$(& $count 'Changed')"; 'item/crdr_gaps' = $gaps
        }) (After 'Collect' $allStates)
    $actions['Fail_if_collect_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Record_run' $allStates)
        expression = @{ not = @{ equals = @("@actions('Collect')?['status']", 'Succeeded') } }
        actions = @{ Terminate = @{ type = 'Terminate'; runAfter = @{}; inputs = @{ runStatus = 'Failed'; runError = @{ code = 'CollectFailed'; message = "@{coalesce(string(outputs('$fetchAction')?['body']?['error']?['message']), 'See the Collect scope')}" } } } }
        else = @{ actions = @{} } }
}

function New-GraphCollector([string]$collector, [string]$path, [int]$source, [string]$inScopeWhere, [hashtable]$shape, [hashtable]$trigger, [string]$description) {
    $actions = [ordered]@{}
    $actions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
    Add-ConfigQuery $actions 'Config_services' 'graph_services'
    Add-ConfigQuery $actions 'Config_now_days' 'horizon_now_days'
    Add-ConfigQuery $actions 'Config_imminent_days' 'horizon_imminent_days'
    Add-ConfigQuery $actions 'Config_recent_days' 'horizon_recent_days'
    $scope = [ordered]@{}
    $scope['Get_certificate'] = Dv 'PerformUnboundAction' ([ordered]@{ actionName = 'RetrieveEnvironmentVariableSecretValue'; 'item/EnvironmentVariableName' = 'crdr_readercertificate' }) @{} @{ runtimeConfiguration = @{ secureData = @{ properties = @('inputs', 'outputs') } } }
    $scope['Get_items'] = [ordered]@{ type = 'Http'; runAfter = (After 'Get_certificate')
        inputs = [ordered]@{ method = 'GET'; uri = "https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/$path"
            authentication = [ordered]@{ type = 'ActiveDirectoryOAuth'; authority = 'https://login.microsoftonline.com'; tenant = "@parameters('Tenant ID (crdr_tenantid)')"; audience = 'https://graph.microsoft.com'
                clientId = "@parameters('Reader client ID (crdr_readerclientid)')"; pfx = "@body('Get_certificate')?['EnvironmentVariableSecretValue']"; password = "@string('')" } }
        runtimeConfiguration = @{ secureData = @{ properties = @('inputs') }; paginationPolicy = @{ minimumItemCount = 100000 } } }
    $scope['Services'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Get_items'); inputs = "@split(coalesce(first(body('Config_services'))?['crdr_value'], ''), ';')" }
    $scope['In_scope'] = [ordered]@{ type = 'Query'; runAfter = (After 'Services'); inputs = @{ from = "@body('Get_items')?['value']"; where = "@$inScopeWhere" } }
    $scope['Shape'] = [ordered]@{ type = 'Select'; runAfter = (After 'In_scope'); inputs = @{ from = "@body('In_scope')"; select = $shape } }
    Add-UpsertAndLog $scope 'Shape' $source 'Shape'
    $actions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = [ordered]@{ Config_services = @('Succeeded'); Config_now_days = @('Succeeded'); Config_imminent_days = @('Succeeded'); Config_recent_days = @('Succeeded') }; actions = $scope }
    Add-RunLog $actions $collector 'Get_items' "length(coalesce(body('Get_items')?['value'], json('[]')))" 'In_scope' $true
    New-Flow $description $trigger $actions
}

$nowDays = ConfigInt 'Config_now_days' $config['horizon_now_days']
$immDays = ConfigInt 'Config_imminent_days' $config['horizon_imminent_days']
$recentDays = ConfigInt 'Config_recent_days' $config['horizon_recent_days']
$rmDays = ConfigInt 'Config_roadmap_days' $config['horizon_roadmap_days']
$recent = { param($dateExpr) "greaterOrEquals(ticks($dateExpr), ticks(addDays(utcNow(), mul(-1, $recentDays))))" }
$within = { param($dateExpr, $daysExpr) "lessOrEquals(ticks($dateExpr), ticks(addDays(utcNow(), $daysExpr)))" }
$snapshot = "if(greater(length(string(item())), 100000), substring(string(item()), 0, 100000), string(item()))"

# ---------- Service health ----------
$healthShape = [ordered]@{
    key = "@concat(item()?['id'], '|', $(DateKey "item()?['lastModifiedDateTime']"))"; externalid = "@item()?['id']"
    title = "@$(Trunc "item()?['title']" 400)"; summary = "@$(Trunc "item()?['impactDescription']" 20000)"; products = "@$(Trunc "item()?['service']" 400)"
    horizon = "@if(equals(item()?['isResolved'], true), $($hz.future), $($hz.now))"
    keydate = "@item()?['startDateTime']"; datelabel = "@$(Trunc "concat(item()?['classification'], ' · ', item()?['status'])" 100)"
    actionrequired = $false; url = "@concat('https://admin.microsoft.com/#/servicehealth/:/alerts/', item()?['id'])"
    lastchanged = "@item()?['lastModifiedDateTime']"; snapshot = "@$snapshot"
}
$flows = [ordered]@{}
$flows['CollectServiceHealth'] = New-GraphCollector 'service-health' 'issues' $src.health "contains(outputs('Services'), item()?['service'])" $healthShape (Recurrence 'Minute' ([int]$config['poll_minutes_service_health'])) 'Change Radar: collect Graph service health issues for the services in crdr_config graph_services.'

# ---------- Message Center ----------
$mcKey = "coalesce(item()?['actionRequiredByDateTime'], item()?['startDateTime'])"
$mcShape = [ordered]@{
    key = "@concat(item()?['id'], '|', $(DateKey "item()?['lastModifiedDateTime']"))"; externalid = "@item()?['id']"
    title = "@$(Trunc "item()?['title']" 400)"; summary = "@$(Trunc "item()?['body']?['content']" 20000)"; products = "@$(Trunc "join(item()?['services'], '; ')" 400)"
    horizon = "@if(and(not(empty(item()?['actionRequiredByDateTime'])), $(& $within "item()?['actionRequiredByDateTime']" $nowDays)), $($hz.now), if(or(and(not(empty(item()?['actionRequiredByDateTime'])), $(& $within "item()?['actionRequiredByDateTime']" $immDays)), and(equals(item()?['category'], 'planForChange'), $(& $recent "item()?['startDateTime']"))), $($hz.imminent), $($hz.future)))"
    keydate = "@$mcKey"; datelabel = "@if(empty(item()?['actionRequiredByDateTime']), concat(coalesce(json('{""planForChange"":""Plan for change"",""stayInformed"":""Stay informed"",""preventOrFixIssue"":""Prevent or fix issue""}')?[coalesce(item()?['category'], '')], 'Message'), ' · published'), 'Action required by')"
    actionrequired = "@not(empty(item()?['actionRequiredByDateTime']))"; url = "@concat('https://admin.microsoft.com/#/MessageCenter/:/messages/', item()?['id'])"
    lastchanged = "@item()?['lastModifiedDateTime']"; snapshot = "@$snapshot"
}
$flows['CollectMessageCenter'] = New-GraphCollector 'message-center' 'messages' $src.mc "not(empty(intersection(coalesce(item()?['services'], json('[]')), outputs('Services'))))" $mcShape (Recurrence 'Minute' ([int]$config['poll_minutes_message_center'])) 'Change Radar: collect Graph Message Center posts for the services in crdr_config graph_services.'

# ---------- Roadmap (public, no authentication) ----------
$months = '{"January":"01","February":"02","March":"03","April":"04","May":"05","June":"06","July":"07","August":"08","September":"09","October":"10","November":"11","December":"12"}'
$ga = "item()?['publicDisclosureAvailabilityDate']"
$gaDate = "if(and(not(empty($ga)), contains(coalesce($ga, ''), ' CY')), concat(replace(last(split($ga, ' ')), 'CY', ''), '-', coalesce(json('$months')?[first(split($ga, ' '))], '01'), '-01T00:00:00Z'), null)"
$status = "item()?['status']"
# Slipped: still in development but its GA month has already started passing (ADR 0007, amended). Shown as 'Slipped · ...' and kept in Future.
$slipped = "and(equals($status, 'In development'), not(empty($gaDate)), less(ticks(coalesce($gaDate, '9999-12-31T00:00:00Z')), ticks(startOfMonth(utcNow()))))"
$rmProducts = 'join(xpath(xml(json(concat(''{"r":{"p":'', string(coalesce(item()?[''tagsContainer'']?[''products''], json(''[]''))), ''}}''))), ''//tagName/text()''), ''; '')'
$rmShape = [ordered]@{
    key = "@concat('RM', string(item()?['id']), '|', $(DateKey "item()?['modified']"))"; externalid = "@concat('RM', string(item()?['id']))"
    title = "@$(Trunc "item()?['title']" 400)"; summary = "@$(Trunc "item()?['description']" 20000)"
    products = "@$(Trunc $rmProducts 400)"
    horizon = "@if(or(equals($status, 'Launched'), equals($status, 'Cancelled')), $($hz.future), if(equals($status, 'Rolling out'), $($hz.imminent), if($slipped, $($hz.future), if(and(not(empty($gaDate)), $(& $within $gaDate $rmDays)), $($hz.imminent), $($hz.future)))))"
    keydate = "@$gaDate"; datelabel = "@$(Trunc "concat(if($slipped, 'Slipped · ', ''), coalesce($status, ''), ' · GA ', coalesce($ga, 'not announced'))" 100)"
    actionrequired = $false; url = "@concat('https://www.microsoft.com/microsoft-365/roadmap?id=', string(item()?['id']))"
    lastchanged = "@item()?['modified']"; snapshot = "@$snapshot"
}
$rmWhere = 'or(' + (($roadmapProducts | ForEach-Object { ('contains(string(coalesce(item()?[''tagsContainer'']?[''products''], json(''[]''))), ''"tagName":"{0}"'')' -f $_) }) -join ', ') + ', false)'
$rmActions = [ordered]@{}
$rmActions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
Add-ConfigQuery $rmActions 'Config_roadmap_days' 'horizon_roadmap_days'
$rmScope = [ordered]@{}
$rmScope['Get_items'] = [ordered]@{ type = 'Http'; runAfter = @{}; inputs = [ordered]@{ method = 'GET'; uri = 'https://www.microsoft.com/releasecommunications/api/v1/m365'; headers = @{ 'User-Agent' = 'change-radar-collector/0.1' } } }
$rmScope['In_scope'] = [ordered]@{ type = 'Query'; runAfter = (After 'Get_items'); inputs = @{ from = "@body('Get_items')"; where = "@$rmWhere" } }
$rmScope['Shape'] = [ordered]@{ type = 'Select'; runAfter = (After 'In_scope'); inputs = @{ from = "@body('In_scope')"; select = $rmShape } }
Add-UpsertAndLog $rmScope 'Shape' $src.roadmap 'Shape'
$rmActions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = (After 'Config_roadmap_days'); actions = $rmScope }
Add-RunLog $rmActions 'roadmap' 'Get_items' "length(coalesce(body('Get_items'), json('[]')))" 'In_scope' $false
$flows['CollectRoadmap'] = New-Flow 'Change Radar: collect the public Microsoft Copilot Roadmap for in-scope products (seed/roadmap-product-map.csv).' (Recurrence 'Day' 1 @{ hours = @('5') }) $rmActions

# -InputObject, not the pipeline: piping unrolls a one-item array into a bare value, which breaks intersection().
function JsonLit($o) { "json('" + ((ConvertTo-Json -InputObject $o -Depth 10 -Compress) -replace "'", "''") + "')" }
$facetOpt = [ordered]@{}; foreach ($f in @($schema.choices.facet)) { $facetOpt[$f] = Get-Opt 'facet' $f }

# ---------- Model vocabulary as an XML map (ADR 0013) ----------
# <m><r v="id"><a>id</a><a>alias</a>...</r>...</m>, all spellings lower-cased; a lookup is one XPath, '' when unknown.
# Engine Import-ModelMap / Get-ModelId use the same rows (value and '|'-separated aliases, ignoring case).
function Add-ModelMap([Collections.Specialized.OrderedDictionary]$actions, [hashtable]$runAfter = @{}) {
    $actions['List_models'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_facetvalues'; '$select' = 'crdr_value,crdr_aliases'; '$filter' = "crdr_facet eq $(Get-Opt 'facet' 'model') and crdr_active eq true" }) $runAfter
    $actions['Model_rows'] = [ordered]@{ type = 'Select'; runAfter = (After 'List_models'); inputs = @{ from = "@body('List_models')?['value']"
            select = "@concat('<r v=""', item()?['crdr_value'], '""><a>', toLower(item()?['crdr_value']), '</a><a>', replace(toLower(trim(coalesce(item()?['crdr_aliases'], ''))), '|', '</a><a>'), '</a></r>')" } }
    $actions['Model_xml'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Model_rows'); inputs = "@xml(concat('<m>', join(body('Model_rows'), ''), '</m>'))" }
}
function ModelLookup([string]$textExpr) { "xpath(outputs('Model_xml'), concat('string(/m/r[a = ''', replace(toLower(trim(coalesce($textExpr, ''))), '''', ''), ''']/@v)'))" }

# ---------- Generic feeds (ADR 0014): shared parts ----------
$src.feed = Get-Opt 'signalsource' 'feed'
$feedKind = @{ tables = Get-Opt 'feedkind' 'learnpage_tables'; sections = Get-Opt 'feedkind' 'learnpage_sections'; rss = Get-Opt 'feedkind' 'rss' }
# Engine ConvertTo-FeedSlug lower-cases and turns every run of characters outside a-z and 0-9 into one '-'. WDL has no
# regex, so the common punctuation is replaced and runs collapsed; parity (Test-FeedParity.ps1) catches anything else.
function SlugRaw([string]$x) {
    # The replacements and collapsing only, without the end trim (callers that stage the id trim it themselves).
    $s = "toLower($x)"
    foreach ($ch in @(' ', '.', '/', ',', '(', ')', ':', "''", '&', '+', '_', ';', '"', '!', '?', '[', ']', '#', '*', '|', '>', '<', '%', '=', '@', [string][char]0x2013, [string][char]0x2014, [string][char]0x2019, [string][char]0x2018)) { $s = "replace($s, '$ch', '-')" }
    foreach ($i in 1..4) { $s = "replace($s, '--', '-')" }
    $s
}
function Slug([string]$x) {
    $s = "toLower($x)"
    foreach ($ch in @(' ', '.', '/', ',', '(', ')', ':', "''", '&', '+', '_', ';', '"', '!', '?', '[', ']', '#', '*', '|', [string][char]0x2013, [string][char]0x2014, [string][char]0x2019, [string][char]0x2018)) { $s = "replace($s, '$ch', '-')" }
    foreach ($i in 1..4) { $s = "replace($s, '--', '-')" }
    "if(endsWith($s, '-'), substring($s, 0, sub(length($s), 1)), $s)"
}
function Add-FeedLoop([Collections.Specialized.OrderedDictionary]$actions, [int]$kind, [Collections.Specialized.OrderedDictionary]$collect, [string]$markerExpr, [string]$collector) {
    # Loops over the active feeds of one kind. Each feed: reset variables, run $collect (a Scope ending in the shared
    # upsert, which reads body('Shape')), log one crdr_collectionrun row, store the marker, never stop the other feeds.
    $actions['Init_records'] = [ordered]@{ type = 'InitializeVariable'; runAfter = @{}; inputs = @{ variables = @(@{ name = 'records'; type = 'string'; value = '' }) } }
    $actions['Init_gaps'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_records'); inputs = @{ variables = @(@{ name = 'gaps'; type = 'array'; value = @() }) } }
    $actions['Init_failed'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_gaps'); inputs = @{ variables = @(@{ name = 'failed'; type = 'array'; value = @() }) } }
    $actions['List_feeds'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_feeds'; '$select' = 'crdr_feedid,crdr_key,crdr_name,crdr_url,crdr_products,crdr_profile,crdr_lastmarker'
            '$filter' = "crdr_active eq true and crdr_kind eq $kind" }) ([ordered]@{ Init_failed = @('Succeeded'); Config_now_days = @('Succeeded'); Config_imminent_days = @('Succeeded') })
    $f = "items('Each_feed')"
    $loop = [ordered]@{}
    $loop['Reset_records'] = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'records'; value = '' } }
    $loop['Reset_gaps'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Reset_records'); inputs = @{ name = 'gaps'; value = @() } }
    $loop['Collect'] = [ordered]@{ type = 'Scope'; runAfter = (After 'Reset_gaps'); actions = $collect }
    $ok = "equals(actions('Collect')?['status'], 'Succeeded')"
    $changedCount = "length(coalesce(actions('Changed')?['outputs']?['body'], json('[]')))"
    $gapText = "concat(join(variables('gaps'), '; '), if($ok, '', concat(if(empty(variables('gaps')), '', '; '), 'collect ', coalesce(actions('Collect')?['status'], 'not run'), ' (HTTP ', string(coalesce(actions('Get_page')?['outputs']?['statusCode'], '-')), ')')))"
    $loop['Record_run'] = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_collectionruns'
            'item/crdr_name' = "@concat('feed ', ${f}?['crdr_key'], ' ', formatDateTime(utcNow(), 'yyyy-MM-dd HH:mm'), if(equals(coalesce(actions('Changed_page')?['outputs'], true), false), ': unchanged', concat(': in scope ', string(length(coalesce(actions('Shape')?['outputs']?['body'], json('[]')))), ', new or changed ', string($changedCount))))"
            'item/crdr_collector' = "@concat('${collector}:', ${f}?['crdr_key'])"; 'item/crdr_accesstier' = $tier.full; 'item/crdr_startedon' = "@trigger()?['startTime']"
            'item/crdr_itemcount' = "@$changedCount"; 'item/crdr_gaps' = "@$(Trunc $gapText 4000)" }) (After 'Collect' $allStates)
    $loop['Update_feed'] = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_feeds'; recordId = "@${f}?['crdr_feedid']"; 'item/crdr_lastcheckedon' = '@utcNow()'
            'item/crdr_lastmarker' = "@if($ok, $markerExpr, coalesce(${f}?['crdr_lastmarker'], ''))" }) (After 'Record_run' $allStates)
    $loop['If_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Update_feed' $allStates); expression = @{ equals = @("@$ok", $false) }
        actions = @{ Note_failed = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'failed'; value = "@${f}?['crdr_key']" } } }; else = @{ actions = @{} } }
    $actions['Each_feed'] = [ordered]@{ type = 'Foreach'; foreach = "@body('List_feeds')?['value']"; runAfter = (After 'List_feeds'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $loop }
    $actions['Fail_if_any_feed_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Each_feed' $allStates); expression = @{ equals = @("@empty(variables('failed'))", $false) }
        actions = @{ Terminate = @{ type = 'Terminate'; runAfter = @{}; inputs = @{ runStatus = 'Failed'; runError = @{ code = 'FeedFailed'; message = "@concat('Feeds that failed: ', join(variables('failed'), ', '))" } } } }; else = @{ actions = @{} } }
}
function Add-FeedConfig([Collections.Specialized.OrderedDictionary]$actions) {
    $actions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
    Add-ConfigQuery $actions 'Config_now_days' 'horizon_now_days'
    Add-ConfigQuery $actions 'Config_imminent_days' 'horizon_imminent_days'
}
$feedFilter = "@concat('crdr_source eq $($src.feed) and _crdr_feed_value eq ', items('Each_feed')?['crdr_feedid'])"
$feedCreate = @{ 'item/crdr_feed@odata.bind' = "@concat('/crdr_feeds(', items('Each_feed')?['crdr_feedid'], ')')" }
$fetchPage = [ordered]@{ type = 'Http'; runAfter = @{}; inputs = [ordered]@{ method = 'GET'; uri = "@items('Each_feed')?['crdr_url']"; headers = @{ 'User-Agent' = 'change-radar-collector/0.1' } } }
function MetaExpr([string]$name) { "first(split(last(split(outputs('Page'), 'name=""$name"" content=""')), '""'))" }

# ---------- Learn page tables (ADR 0013 model lifecycle; spike T9) ----------
$lt = [ordered]@{}
Add-FeedConfig $lt
$ltc = [ordered]@{}
$ltc['Get_page'] = $fetchPage
$ltc['Page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Get_page'); inputs = "@string(body('Get_page'))" }
$ltc['Commit'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Page'); inputs = "@$(MetaExpr 'git_commit_id')" }
$ltc['Updated'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Commit'); inputs = "@$(MetaExpr 'updated_at')" }
$ltc['Profile'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Updated'); inputs = "@json(coalesce(items('Each_feed')?['crdr_profile'], '{}'))" }
$ltc['Changed_page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Profile'); inputs = "@not(equals(outputs('Commit'), coalesce(items('Each_feed')?['crdr_lastmarker'], '')))" }
Add-ModelMap $ltc
$ltc['Scope_rt'] = [ordered]@{ type = 'Select'; runAfter = (After 'Profile'); inputs = @{ from = "@coalesce(outputs('Profile')?['fingerprintScope']?['resource_type'], json('[]'))"; select = [ordered]@{ group = 'A'; facet = 'resource_type'; value = '@item()' } } }
$ltc['Scope_harness'] = [ordered]@{ type = 'Select'; runAfter = (After 'Scope_rt'); inputs = @{ from = "@coalesce(outputs('Profile')?['fingerprintScope']?['harness'], json('[]'))"; select = [ordered]@{ group = 'A'; facet = 'harness'; value = '@item()' } } }
# ADR 0017 (engine Invoke-FeedAdapter): callerScope adds group B, the model plus capability ai_prompt, for the flows that call a prompt.
$ltc['Scope_callers'] = [ordered]@{ type = 'Select'; runAfter = (After 'Scope_harness'); inputs = @{ from = "@coalesce(outputs('Profile')?['callerScope']?['capability'], json('[]'))"; select = [ordered]@{ group = 'B'; facet = 'capability'; value = '@item()' } } }
$ltc['Tables'] = [ordered]@{ type = 'Select'; runAfter = [ordered]@{ Changed_page = @('Succeeded'); Model_xml = @('Succeeded'); Scope_callers = @('Succeeded') }; inputs = @{ from = "@if(outputs('Changed_page'), skip(split(outputs('Page'), '<table'), 1), json('[]'))"; select = "@xml(concat('<table', first(split(item(), '</table>')), '</table>'))" } }
$tp = "items('Each_table')"
$tt = [ordered]@{}
$tt['Header_test'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@concat('count(/table/thead/tr/th[normalize-space(.)=''', join(${tp}?['requires'], ''' or normalize-space(.)='''), '''])')" }
$tt['Match'] = [ordered]@{ type = 'Query'; runAfter = (After 'Header_test'); inputs = @{ from = "@body('Tables')"; where = "@equals(int(xpath(item(), outputs('Header_test'))), length(${tp}?['requires']))" } }
$found = [ordered]@{}
$found['T'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@first(body('Match'))" }
function ColIndex([string]$name) {
    $h = "coalesce(${tp}?['columns']?['$name'], '')"
    "if(equals($h, ''), 0, if(equals(int(xpath(outputs('T'), concat('count(/table/thead/tr/th[starts-with(normalize-space(.),''', $h, ''')])'))), 0), 0, add(int(xpath(outputs('T'), concat('count(/table/thead/tr/th[starts-with(normalize-space(.),''', $h, ''')][1]/preceding-sibling::th)'))), 1)))"
}
$colNames = 'model', 'date', 'status', 'replacement', 'harness', 'tier', 'extension', 'provider'
$cols = [ordered]@{}; foreach ($c in $colNames) { $cols[$c] = "@$(ColIndex $c)" }
$cols['rows'] = "@int(xpath(outputs('T'), 'count(/table/tbody/tr)'))"
$cols['headingDate'] = "@trim(first(split(last(split(outputs('Page'), coalesce(${tp}?['headingPrefix'], '{no heading}'))), ')')))"
$found['Cols'] = [ordered]@{ type = 'Compose'; runAfter = (After 'T'); inputs = $cols }
function Cell([string]$name) { "xpath(outputs('T'), concat('normalize-space(/table/tbody/tr[', string(item()), ']/td[', string(outputs('Cols')?['$name']), '])'))" }
$rest = "concat('" + [char]0x00B6 + "', if(equals(outputs('Cols')?['status'], 0), coalesce(${tp}?['status'], ''), $(Cell 'status')), '" + [char]0x00A6 + "', if(equals(${tp}?['dateFrom'], 'heading'), outputs('Cols')?['headingDate'], $(Cell 'date')), '" + [char]0x00A6 + "', $(Cell 'replacement'), '" + [char]0x00A6 + "', $(Cell 'harness'), '" + [char]0x00A6 + "', $(Cell 'tier'), '" + [char]0x00A6 + "', $(Cell 'extension'), '" + [char]0x00A6 + "', $(Cell 'provider'))"
$sepRec = [string][char]0x2016
$found['Rows'] = [ordered]@{ type = 'Select'; runAfter = (After 'Cols'); inputs = @{ from = "@range(1, outputs('Cols')?['rows'])"
        select = "@if(equals(coalesce(${tp}?['split'], ''), ''), concat($(Cell 'model'), $rest), concat(replace($(Cell 'model'), ${tp}?['split'], concat($rest, '$sepRec')), $rest))" } }
$found['Add_records'] = [ordered]@{ type = 'AppendToStringVariable'; runAfter = (After 'Rows'); inputs = @{ name = 'records'; value = "@concat(join(body('Rows'), '$sepRec'), '$sepRec')" } }
$notFound = [ordered]@{ Note_gap = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'gaps'; value = "@concat('page shape changed: no table with headers ''', join(${tp}?['requires'], ''', '''), '''')" } } }
$tt['If_found'] = [ordered]@{ type = 'If'; runAfter = (After 'Match'); expression = @{ equals = @("@empty(body('Match'))", $false) }; actions = $found; else = @{ actions = $notFound } }
$ltc['Each_table'] = [ordered]@{ type = 'Foreach'; foreach = "@if(outputs('Changed_page'), coalesce(outputs('Profile')?['tables'], json('[]')), json('[]'))"; runAfter = (After 'Tables'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $tt }
$ltc['Records'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_table'); inputs = @{ from = "@split(variables('records'), '$sepRec')"; where = "@not(equals(trim(first(split(item(), '" + [char]0x00B6 + "'))), ''))" } }
# One shaped signal per record "model¶status¦date¦replacement¦harness¦tier¦extension¦provider" (engine Get-LifecycleSignals).
$m = "trim(first(split(item(), '" + [char]0x00B6 + "')))"
function RestPart([int]$i) { "trim(coalesce(split(last(split(item(), '" + [char]0x00B6 + "')), '" + [char]0x00A6 + "')?[$i], ''))" }
$dt = RestPart 1
$dateNorm = "if(equals($dt, ''), 'January 1, 1900', if(contains($dt, ','), $dt, concat(first(split($dt, ' ')), ' 1, ', last(split($dt, ' ')))))"
$date = "parseDateTime($dateNorm, 'en-US', 'MMMM d, yyyy')"
$isMonth = "and(not(equals($dt, '')), not(contains($dt, ',')))"
$today0 = 'startOfDay(utcNow())'
$retired = "or(startsWith($(RestPart 0), 'Retired'), less(ticks($date), ticks($today0)))"
$days = "div(sub(ticks($date), ticks($today0)), 864000000000)"
$rep = RestPart 2
$extId = "concat(items('Each_feed')?['crdr_key'], '-', $(Slug $m))"
$extIdT = "if(greater(length($extId), 100), substring($extId, 0, 100), $extId)"
$labelExpr = "if($retired, concat('Retired · replaced by ', $rep), concat('Retiring · replacement ', $rep))"
$ltc['Shaped'] = [ordered]@{ type = 'Select'; runAfter = (After 'Records'); inputs = @{ from = "@body('Records')"; select = [ordered]@{
            externalid = "@$extIdT"
            key = "@concat($extIdT, '|', $(DateKey "outputs('Updated')"))"
            title = "@$(Trunc "concat($m, if($retired, ' retired from ', ' retires from '), coalesce(outputs('Profile')?['surface'], ''), if($isMonth, concat(' in ', formatDateTime($date, 'MMMM yyyy')), concat(' on ', formatDateTime($date, 'd MMMM yyyy'))))" 400)"
            summary = "@concat('Replacement: ', $rep, if(equals($(RestPart 3), ''), '', concat('. Harness: ', $(RestPart 3))), if(equals($(RestPart 4), ''), '', concat('. Tier: ', $(RestPart 4))), if(equals($(RestPart 5), ''), '', concat('. Extension available: ', $(RestPart 5))), if(equals($(RestPart 6), ''), '', concat('. Provider: ', $(RestPart 6))), '.', if(or($retired, empty(coalesce(outputs('Profile')?['migrationNote'], ''))), '', concat(' ', outputs('Profile')?['migrationNote'])))"  # ADR 0013 step 5: retiring rows end with the profile's migration note
            products = "@$(Trunc "items('Each_feed')?['crdr_products']" 400)"
            horizon = "@if($retired, $($hz.future), if(lessOrEquals($days, $nowDays), $($hz.now), if(lessOrEquals($days, $immDays), $($hz.imminent), $($hz.future))))"
            keydate = "@formatDateTime($date, 'yyyy-MM-dd')"
            datelabel = "@$(Trunc $labelExpr 100)"
            actionrequired = "@not($retired)"
            url = "@items('Each_feed')?['crdr_url']"
            lastchanged = "@outputs('Updated')"
            snapshot = "@$(Trunc "item()" 100000)"
            skip = "@and($retired, greater(mul(-1, $days), int(coalesce(outputs('Profile')?['retiredWithinDays'], 90))))"
            modeltext = "@if(and(contains($m, '('), endsWith($m, ')')), trim(first(split($m, '('))), $m)" } } }
$ltc['Shape'] = [ordered]@{ type = 'Query'; runAfter = (After 'Shaped'); inputs = @{ from = "@body('Shaped')"; where = "@equals(item()?['skip'], false)" } }
$fpEach = "items('Each_rule_fp')"
$ltOnCreate = [ordered]@{}
$ltOnCreate['Model_id'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Create_signal'); inputs = "@$(ModelLookup "items('Upsert')?['modeltext']")" }
$ltOnCreate['If_model_known'] = [ordered]@{ type = 'If'; runAfter = (After 'Model_id'); expression = @{ equals = @("@empty(outputs('Model_id'))", $false) }
    actions = [ordered]@{ Each_rule_fp = [ordered]@{ type = 'Foreach'; runAfter = @{}
            foreach = "@union(createArray(addProperty(addProperty(addProperty(json('{}'), 'group', 'A'), 'facet', 'model'), 'value', outputs('Model_id'))), body('Scope_rt'), body('Scope_harness'), if(empty(body('Scope_callers')), json('[]'), createArray(addProperty(addProperty(addProperty(json('{}'), 'group', 'B'), 'facet', 'model'), 'value', outputs('Model_id')))), body('Scope_callers'))"
            actions = @{ Create_rule_fp = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_signalfingerprints'
                        'item/crdr_name' = "@concat(${fpEach}?['facet'], ': ', ${fpEach}?['value'])"; 'item/crdr_signal@odata.bind' = "@concat('/crdr_signals(', body('Create_signal')?['crdr_signalid'], ')')"
                        'item/crdr_group' = "@${fpEach}?['group']"; 'item/crdr_facet' = "@$(JsonLit $facetOpt)?[${fpEach}?['facet']]"; 'item/crdr_value' = "@${fpEach}?['value']"
                        'item/crdr_extractedby' = (Get-Opt 'extractedby' 'rule'); 'item/crdr_confidence' = 1; 'item/crdr_status' = (Get-Opt 'fingerprintstatus' 'accepted')
                        'item/crdr_reason' = "@if(equals(${fpEach}?['group'], 'B'), 'Rule fingerprint from the Learn model lifecycle table (ADR 0017): the model and the capability of the flows that call such a prompt.', 'Rule fingerprint from the Learn model lifecycle table (ADR 0013): the model and the table''s scope.')" }) } } }
    else = @{ actions = @{ Note_unmapped = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'gaps'; value = "@concat('unmapped model ''', items('Upsert')?['modeltext'], '''')" } } } } }
Add-UpsertAndLog $ltc 'Shape' $src.feed 'Shape' $feedFilter $feedCreate $ltOnCreate
Add-FeedLoop $lt $feedKind.tables $ltc "outputs('Commit')" 'feed'
$flows['CollectLearnTables'] = New-Flow 'Change Radar: collect the active Learn page table feeds (crdr_feed kind learnpage_tables), such as the Copilot Studio and prompt model lifecycle tables (ADR 0013, ADR 0014, spike T9).' (Recurrence 'Day' 1 @{ hours = @('5'); minutes = @('15') }) $lt

# ---------- Learn page sections (ADR 0014: Microsoft 365 Copilot release notes) ----------
$P = [string][char]0x00B6   # field separator in record strings
$R = [string][char]0x2016   # record separator
$ls = [ordered]@{}
Add-FeedConfig $ls
$lsc = [ordered]@{}
$lsc['Get_page'] = $fetchPage
# Engine Clear-Html: named HTML entities XML doesn't know become spaces, and <br> is closed, before xml().
$clean = "string(body('Get_page'))"
foreach ($e in '&nbsp;', '&mdash;', '&ndash;', '&rsquo;', '&lsquo;', '&ldquo;', '&rdquo;', '&hellip;', '&copy;', '&reg;', '&trade;') { $clean = "replace($clean, '$e', ' ')" }
$clean = "replace($clean, '<br>', '<br/>')"
$lsc['Page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Get_page'); inputs = "@$clean" }
$lsc['Commit'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Page'); inputs = "@$(MetaExpr 'git_commit_id')" }
$lsc['Profile'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Commit'); inputs = "@json(coalesce(items('Each_feed')?['crdr_profile'], '{}'))" }
$lsc['Changed_page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Profile'); inputs = "@not(equals(outputs('Commit'), coalesce(items('Each_feed')?['crdr_lastmarker'], '')))" }
$lsc['Keywords'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Changed_page'); inputs = "@xml(concat('<k><w>', join(coalesce(outputs('Profile')?['titleKeywords'], json('[]')), '</w><w>'), '</w></k>'))" }
$lsc['Chunks'] = [ordered]@{ type = 'Select'; runAfter = (After 'Keywords'); inputs = @{ from = "@if(outputs('Changed_page'), skip(split(outputs('Page'), '<h2 id=""'), 1), json('[]'))"; select = [ordered]@{ id = "@first(split(item(), '""'))"; body = '@item()' } } }
$months = '["january","february","march","april","may","june","july","august","september","october","november","december"]'
$lsc['Dated'] = [ordered]@{ type = 'Query'; runAfter = (After 'Chunks'); inputs = @{ from = "@body('Chunks')"
        where = "@and(equals(length(split(item()?['id'], '-')), 3), equals(length(last(split(item()?['id'], '-'))), 4), contains(json('$months'), first(split(item()?['id'], '-'))))" } }
$mon = "first(split(item()?['id'], '-'))"
$lsc['With_dates'] = [ordered]@{ type = 'Select'; runAfter = (After 'Dated'); inputs = @{ from = "@body('Dated')"; select = [ordered]@{ id = "@item()?['id']"; body = "@item()?['body']"
            date = "@formatDateTime(parseDateTime(concat(toUpper(substring($mon, 0, 1)), substring($mon, 1), ' ', split(item()?['id'], '-')[1], ', ', last(split(item()?['id'], '-'))), 'en-US', 'MMMM d, yyyy'), 'yyyy-MM-dd')" } } }
$lsc['Recent'] = [ordered]@{ type = 'Query'; runAfter = (After 'With_dates'); inputs = @{ from = "@body('With_dates')"; where = "@greaterOrEquals(ticks(item()?['date']), ticks(addDays(startOfDay(utcNow()), mul(-1, int(coalesce(outputs('Profile')?['sinceDays'], 90))))))" } }
$sec = "items('Each_section')"
$b = "${sec}?['body']"
$try = [ordered]@{}
$try['X'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@xml(if(contains($b, '</ul>'), concat('<div><h2 id=""', substring($b, 0, add(lastIndexOf($b, '</ul>'), 5)), '</div>'), '<div/>'))" }
# Title: a bold tag that is the first thing in the item's first paragraph (items without one are bullets that broke out of
# the previous feature); area: the nearest h3 before the item's list. Engine Get-ReleaseNoteSignals uses the same paths.
$li = { param($path) "xpath(outputs('X'), concat('normalize-space((/div/ul/li)[', string(item()), ']$path)'))" }
$try['Items'] = [ordered]@{ type = 'Select'; runAfter = (After 'X'); inputs = @{ from = "@range(1, int(xpath(outputs('X'), 'count(/div/ul/li)')))"; select = [ordered]@{
            title = "@$(& $li '/p[1]/node()[1][self::strong]')"; area = "@$(& $li '/../preceding-sibling::h3[1]')"; summary = "@xpath(outputs('X'), concat('normalize-space((/div/ul/li)[', string(item()), '])'))" } } }
$kwHit = "greater(int(xpath(outputs('Keywords'), concat('count(/k/w[contains(''', replace(toLower(item()?['title']), '''', ' '), ''', .)])'))), 0)"
$try['In_scope'] = [ordered]@{ type = 'Query'; runAfter = (After 'Items'); inputs = @{ from = "@body('Items')"; where = "@and(not(equals(item()?['title'], '')), or(contains(coalesce(outputs('Profile')?['areas'], json('[]')), item()?['area']), $kwHit))" } }
$try['Section_records'] = [ordered]@{ type = 'Select'; runAfter = (After 'In_scope'); inputs = @{ from = "@body('In_scope')"; select = "@concat(${sec}?['id'], '$P', ${sec}?['date'], '$P', item()?['area'], '$P', item()?['title'], '$P', item()?['summary'])" } }
$try['Add_records'] = [ordered]@{ type = 'AppendToStringVariable'; runAfter = (After 'Section_records'); inputs = @{ name = 'records'; value = "@concat(join(body('Section_records'), '$R'), '$R')" } }
$sl = [ordered]@{}
$sl['Try'] = [ordered]@{ type = 'Scope'; runAfter = @{}; actions = $try }
$sl['Note_unreadable'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Try' @('Failed', 'TimedOut')); inputs = @{ name = 'gaps'; value = "@concat('section ', ${sec}?['id'], ' could not be read')" } }
$lsc['Each_section'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Recent')"; runAfter = (After 'Recent'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $sl }
$lsc['Records'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_section'); inputs = @{ from = "@split(variables('records'), '$R')"; where = "@not(equals(item(), ''))" } }
function SecPart([int]$i) { "coalesce(split(item(), '$P')?[$i], '')" }
# Staged so each expression stays well under the 8,192-character limit:
#   Parsed: record fields and the raw slug; Keyed: external id as engine New-ExternalId (slug trimmed of '-' at both
#   ends, cut to 100 characters); Shaped: trailing '-' after the cut trimmed; Shape: first occurrence of each id only.
$lsc['Parsed'] = [ordered]@{ type = 'Select'; runAfter = (After 'Records'); inputs = @{ from = "@body('Records')"; select = [ordered]@{
            sid = "@$(SecPart 0)"; date = "@$(SecPart 1)"; area = "@$(SecPart 2)"; title = "@$(SecPart 3)"; summary = "@$(SecPart 4)"; slug0 = "@$(SlugRaw (SecPart 3))" } } }
$s0 = "item()?['slug0']"
$s1 = "if(startsWith($s0, '-'), substring($s0, 1), $s0)"
$idFull = "concat(items('Each_feed')?['crdr_key'], '-', replace(item()?['date'], '-', ''), '-', if(endsWith($s1, '-'), substring($s1, 0, sub(length($s1), 1)), $s1))"
$lsc['Keyed'] = [ordered]@{ type = 'Select'; runAfter = (After 'Parsed'); inputs = @{ from = "@body('Parsed')"; select = [ordered]@{
            sid = "@item()?['sid']"; date = "@item()?['date']"; area = "@item()?['area']"; title = "@item()?['title']"; summary = "@item()?['summary']"; idcut = "@substring($idFull, 0, min(100, length($idFull)))" } } }
$idc = "item()?['idcut']"
$sExtT = "if(endsWith($idc, '-'), substring($idc, 0, sub(length($idc), 1)), $idc)"
$sArea = "item()?['area']"
$lsc['Shaped'] = [ordered]@{ type = 'Select'; runAfter = (After 'Keyed'); inputs = @{ from = "@body('Keyed')"; select = [ordered]@{
            externalid = "@$sExtT"; key = "@concat($sExtT, '|', $(DateKey "item()?['date']"))"
            title = "@$(Trunc "item()?['title']" 400)"; summary = "@$(Trunc "item()?['summary']" 20000)"
            products = "@$(Trunc "coalesce(outputs('Profile')?['areaProducts']?[$sArea], items('Each_feed')?['crdr_products'])" 400)"
            horizon = $hz.future; keydate = "@item()?['date']"; datelabel = "@$(Trunc "concat('Released · ', $sArea)" 100)"; actionrequired = $false
            url = "@concat(items('Each_feed')?['crdr_url'], '#', item()?['sid'])"; lastchanged = "@item()?['date']"; snapshot = "@$(Trunc 'string(item())' 100000)" } } }
# Engine keeps the first item with a given id (the same feature can appear twice in one section).
$lsc['Id_list'] = [ordered]@{ type = 'Select'; runAfter = (After 'Shaped'); inputs = @{ from = "@body('Shaped')"; select = "@item()?['externalid']" } }
$lsc['Ids'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Id_list'); inputs = "@xml(concat('<r><i>', join(body('Id_list'), '</i><i>'), '</i></r>'))" }
$firstOnly = "equals(int(xpath(outputs('Ids'), concat('count(/r/i[position() < ', string(add(item(), 1)), '][. = ''', body('Id_list')[item()], '''])'))), 0)"
$lsc['First_ids'] = [ordered]@{ type = 'Query'; runAfter = (After 'Ids'); inputs = @{ from = "@range(0, length(body('Shaped')))"; where = "@$firstOnly" } }
$lsc['Shape'] = [ordered]@{ type = 'Select'; runAfter = (After 'First_ids'); inputs = @{ from = "@body('First_ids')"; select = "@body('Shaped')[item()]" } }
Add-UpsertAndLog $lsc 'Shape' $src.feed 'Shape' $feedFilter $feedCreate
Add-FeedLoop $ls $feedKind.sections $lsc "outputs('Commit')" 'feed'
$flows['CollectLearnSections'] = New-Flow 'Change Radar: collect the active Learn page section feeds (crdr_feed kind learnpage_sections), such as the Microsoft 365 Copilot release notes: dated sections, items in scope by area or model keyword (ADR 0014).' (Recurrence 'Day' 1 @{ hours = @('5'); minutes = @('20') }) $ls

# ---------- RSS feeds (ADR 0014) ----------
$rs = [ordered]@{}
Add-FeedConfig $rs
$rsc = [ordered]@{}
$rsc['Get_page'] = $fetchPage
$rsc['X'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Get_page'); inputs = "@xml(string(body('Get_page')))" }
$rsc['Profile'] = [ordered]@{ type = 'Compose'; runAfter = (After 'X'); inputs = "@json(coalesce(items('Each_feed')?['crdr_profile'], '{}'))" }
$rx = { param($field) "xpath(outputs('X'), concat('string(/rss/channel/item[', string(item()), ']/$field)'))" }
$rsc['Items'] = [ordered]@{ type = 'Select'; runAfter = (After 'Profile'); inputs = @{ from = "@range(1, int(xpath(outputs('X'), 'count(/rss/channel/item)')))"; select = [ordered]@{
            title = "@trim($(& $rx 'title'))"; link = "@trim($(& $rx 'link'))"; pub = "@formatDateTime($(& $rx 'pubDate'), 'yyyy-MM-ddTHH:mm:ssZ')"; description = "@$(& $rx 'description')" } } }
$rsc['Marker'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Items'); inputs = "@coalesce(first(body('Items'))?['pub'], '')" }
# Changed only when the newest item is later than the stored marker: the feed's CDN serves stale copies at random
# (observed 2026-11-22: a copy built 24 Sep and one built 27 Oct), and a stale copy must neither re-run nor move the marker back.
$rsc['Changed_page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Marker'); inputs = "@and(not(equals(outputs('Marker'), '')), greater(ticks(outputs('Marker')), ticks(if(equals(coalesce(items('Each_feed')?['crdr_lastmarker'], ''), ''), '1900-01-01T00:00:00Z', items('Each_feed')?['crdr_lastmarker']))))" }
$link = "item()?['link']"
$lastSeg = "last(split(if(endsWith($link, '/'), substring($link, 0, sub(length($link), 1)), $link), '/'))"
# Staged so no single expression passes the 8,192-character limit: the slug is worked out once per item here.
$rsc['Slugged'] = [ordered]@{ type = 'Select'; runAfter = (After 'Changed_page'); inputs = @{ from = "@if(outputs('Changed_page'), body('Items'), json('[]'))"; select = [ordered]@{
            title = "@item()?['title']"; link = "@$link"; pub = "@item()?['pub']"; description = "@item()?['description']"; slug = "@$(Slug $lastSeg)" } } }
$rExt = "concat(items('Each_feed')?['crdr_key'], '-', item()?['slug'])"
$rCut = "substring($rExt, 0, min(100, length($rExt)))"
$rExtT = "if(endsWith($rCut, '-'), substring($rCut, 0, sub(length($rCut), 1)), $rCut)"   # engine New-ExternalId trims a '-' left by the cut
$rsc['Shaped'] = [ordered]@{ type = 'Select'; runAfter = (After 'Slugged'); inputs = @{ from = "@body('Slugged')"; select = [ordered]@{
            externalid = "@$rExtT"; key = "@concat($rExtT, '|', $(DateKey "item()?['pub']"))"
            title = "@$(Trunc "item()?['title']" 400)"; summary = "@$(Trunc "item()?['description']" 20000)"; products = "@$(Trunc "items('Each_feed')?['crdr_products']" 400)"
            horizon = $hz.future; keydate = "@item()?['pub']"; datelabel = "@$(Trunc "concat(coalesce(outputs('Profile')?['label'], 'Feed'), ' · published')" 100)"; actionrequired = $false
            url = "@$link"; lastchanged = "@item()?['pub']"; snapshot = "@$(Trunc 'string(item())' 100000)" } } }
$rsc['Shape'] = [ordered]@{ type = 'Query'; runAfter = (After 'Shaped'); inputs = @{ from = "@body('Shaped')"; where = '@true' } }
Add-UpsertAndLog $rsc 'Shape' $src.feed 'Shape' $feedFilter $feedCreate
Add-FeedLoop $rs $feedKind.rss $rsc "if(outputs('Changed_page'), outputs('Marker'), coalesce(items('Each_feed')?['crdr_lastmarker'], ''))" 'feed'
$flows['CollectRssFeeds'] = New-Flow 'Change Radar: collect the active RSS feeds (crdr_feed kind rss), such as the Copilot Studio blog: one informational signal per item, dated by publication (ADR 0014).' (Recurrence 'Day' 1 @{ hours = @('5'); minutes = @('25') }) $rs

# ---------- Web page sections (ADR 0018 Book of News, ADR 0019 Learn licensing pages; spike T11) ----------
# Mirrors engine Get-WebSectionSignals with split/join only (WDL has no regex, and substring() fails at the end of a text):
# cut <contentStart>..<contentEnd>, drop script/style/svg blocks, split at <h2/<h3/<h4, title by xml() + normalize-space,
# parents from an XPath index, scope by up to 12 words per list, summary = the section's raw HTML. Change detection is
# on the section HTML (Existing_keys below). The first run of a feed (no marker yet) is silent: no version rows, no events.
$wsKind = Get-Opt 'feedkind' 'webpage_sections'
$SEP = [string][char]0x241E
$NOWORD = [string][char]0x241F   # a scope slot nobody fills: never found in a page
$natOptFeed = [ordered]@{}; foreach ($v in $schema.choices.nature) { $natOptFeed[$v] = Get-Opt 'nature' $v }
$ws = [ordered]@{}
Add-FeedConfig $ws
$wsc = [ordered]@{}
$wsc['Get_page'] = [ordered]@{ type = 'Http'; runAfter = @{}; inputs = [ordered]@{ method = 'GET'; uri = "@items('Each_feed')?['crdr_url']"
        # Spike T11: news.microsoft.com's firewall blocks bare requests; an honest client name with Accept headers is let through.
        headers = [ordered]@{ 'User-Agent' = 'ChangeRadar/1.0 (signal collector)'; Accept = 'text/html,application/xhtml+xml'; 'Accept-Language' = 'en-GB,en;q=0.9' } } }
$wsc['Page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Get_page'); inputs = "@string(body('Get_page'))" }
$wsc['Profile'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Page'); inputs = "@json(coalesce(items('Each_feed')?['crdr_profile'], '{}'))" }
$wsc['Marker'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Profile')
    inputs = "@if(equals(coalesce(outputs('Profile')?['marker'], 'git_commit_id'), 'dateModified'), if(contains(outputs('Page'), '""dateModified"":""'), first(split(last(split(outputs('Page'), '""dateModified"":""')), '""')), ''), if(contains(outputs('Page'), 'name=""git_commit_id"" content=""'), $(MetaExpr 'git_commit_id'), ''))" }
$wsc['Changed_page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Marker'); inputs = "@not(equals(outputs('Marker'), coalesce(items('Each_feed')?['crdr_lastmarker'], '')))" }
$cs = "coalesce(outputs('Profile')?['contentStart'], '<main')"; $ce = "coalesce(outputs('Profile')?['contentEnd'], '</main>')"
$wsc['Has_content'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Changed_page'); inputs = "@and(outputs('Changed_page'), contains(outputs('Page'), $cs), contains(join(skip(split(outputs('Page'), $cs), 1), $cs), $ce))" }
$wsc['Note_markers'] = [ordered]@{ type = 'If'; runAfter = (After 'Has_content'); expression = @{ and = @(@{ equals = @("@outputs('Changed_page')", $true) }, @{ equals = @("@outputs('Has_content')", $false) }) }
    actions = @{ Add_gap = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'gaps'; value = 'content markers not found' } } }; else = @{ actions = @{} } }
# Content = contentStart plus what follows it, up to the first contentEnd after it (engine: Substring(i, j - i)).
$wsc['Content'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Note_markers'); inputs = "@if(outputs('Has_content'), concat($cs, first(split(join(skip(split(outputs('Page'), $cs), 1), $cs), $ce))), '')" }
$prevBlock = 'Content'; $prevExpr = "outputs('Content')"
foreach ($t in 'script', 'style', 'svg') {
    $n = "No_$t"
    $wsc["${n}_parts"] = [ordered]@{ type = 'Select'; runAfter = (After $prevBlock); inputs = @{ from = "@skip(split($prevExpr, '<$t'), 1)"; select = "@join(skip(split(item(), '</$t>'), 1), '</$t>')" } }
    $wsc[$n] = [ordered]@{ type = 'Compose'; runAfter = (After "${n}_parts"); inputs = "@concat(first(split($prevExpr, '<$t')), join(body('${n}_parts'), ''))" }
    $prevBlock = $n; $prevExpr = "outputs('$n')"
}
$wsc['Chunks'] = [ordered]@{ type = 'Compose'; runAfter = (After $prevBlock); inputs = "@skip(split(replace(replace(replace($prevExpr, '<h2', '${SEP}2'), '<h3', '${SEP}3'), '<h4', '${SEP}4'), '$SEP'), 1)" }
$cleanInner = "first(split(join(skip(split(substring(concat(item(), ' '), 1), '>'), 1), '>'), concat('</h', substring(item(), 0, 1), '>')))"
foreach ($e in '&nbsp;', '&mdash;', '&ndash;', '&rsquo;', '&lsquo;', '&ldquo;', '&rdquo;', '&hellip;', '&copy;', '&reg;', '&trade;') { $cleanInner = "replace($cleanInner, '$e', ' ')" }
$cleanInner = "replace($cleanInner, '<br>', '<br/>')"
$restExpr = "substring(concat(item(), ' '), 1)"
$attrsExpr = "first(split($restExpr, '>'))"
$closeExpr = "concat('</h', substring(item(), 0, 1), '>')"
$afterExpr = "join(skip(split($restExpr, '>'), 1), '>')"
$wsc['Parsed'] = [ordered]@{ type = 'Select'; runAfter = (After 'Chunks'); inputs = @{ from = "@outputs('Chunks')"; select = [ordered]@{
            level = "@int(substring(item(), 0, 1))"
            title = "@xpath(xml(concat('<t>', $cleanInner, '</t>')), 'normalize-space(/t)')"
            id = "@if(contains($attrsExpr, 'id=""'), first(split(join(skip(split($attrsExpr, 'id=""'), 1), 'id=""'), '""')), '')"
            body = "@trim(join(skip(split($afterExpr, $closeExpr), 1), $closeExpr))" } } }
# XPath index of levels and titles, for each section's parent h2 and h3.
$escT = "replace(replace(replace(item()?['title'], '&', '&amp;'), '<', '&lt;'), '>', '&gt;')"
$wsc['Index_rows'] = [ordered]@{ type = 'Select'; runAfter = (After 'Parsed'); inputs = @{ from = "@body('Parsed')"; select = "@concat('<c><l>', string(item()?['level']), '</l><t>', $escT, '</t></c>')" } }
$wsc['Index'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Index_rows'); inputs = "@xml(concat('<r>', join(body('Index_rows'), ''), '</r>'))" }
$pi = "body('Parsed')[item()]"
$nUpTo = "string(add(item(), 1))"
$t2 = "xpath(outputs('Index'), concat('string((/r/c[position() <= ', $nUpTo, '][l=2])[last()]/t)'))"
$t3 = "xpath(outputs('Index'), concat('string((/r/c[position() <= ', $nUpTo, '][l=3][count(preceding-sibling::c[l=2]) = count(/r/c[position() <= ', $nUpTo, '][l=2])])[last()]/t)'))"
$wsc['With_path'] = [ordered]@{ type = 'Select'; runAfter = (After 'Index'); inputs = @{ from = "@range(0, length(body('Parsed')))"; select = [ordered]@{
            level = "@${pi}?['level']"; title = "@${pi}?['title']"; id = "@${pi}?['id']"; body = "@${pi}?['body']"
            path = "@if(equals(${pi}?['level'], 2), ${pi}?['title'], if(equals(${pi}?['level'], 3), concat($t2, ' > ', ${pi}?['title']), concat($t2, ' > ', $t3, ' > ', ${pi}?['title'])))"
            leaf = "@or(greaterOrEquals(add(item(), 1), length(body('Parsed'))), lessOrEquals(body('Parsed')[add(item(), 1)]?['level'], ${pi}?['level']))" } } }
$skipList = "toLower(join(coalesce(outputs('Profile')?['skipTitles'], json('[]')), '$SEP'))"
function ScopeHits([string]$list, [string]$text) {
    $slots = foreach ($k in 0..11) { "contains($text, coalesce(outputs('Profile')?['$list']?[$k], '$NOWORD'))" }
    "or($($slots -join ', '))"
}
$noScope = "and(empty(coalesce(outputs('Profile')?['scopeHead'], json('[]'))), empty(coalesce(outputs('Profile')?['scopeBody'], json('[]'))))"
$wsc['Kept'] = [ordered]@{ type = 'Query'; runAfter = (After 'With_path'); inputs = @{ from = "@body('With_path')"
        where = "@and(not(equals(item()?['title'], '')), not(contains(split($skipList, '$SEP'), toLower(item()?['title']))), or(not(equals(coalesce(outputs('Profile')?['unit'], 'all'), 'leaf')), item()?['leaf']), greaterOrEquals(length(item()?['body']), int(coalesce(outputs('Profile')?['minChars'], 1))), or($noScope, $(ScopeHits 'scopeHead' "toLower(item()?['path'])"), $(ScopeHits 'scopeBody' "toLower(item()?['body'])")))" } }
$wsc['Slugged'] = [ordered]@{ type = 'Select'; runAfter = (After 'Kept'); inputs = @{ from = "@body('Kept')"; select = [ordered]@{
            title = "@item()?['title']"; id = "@item()?['id']"; body = "@item()?['body']"
            slug0 = "@$(SlugRaw "if(equals(coalesce(outputs('Profile')?['idFrom'], 'title'), 'path'), item()?['path'], item()?['title'])")" } } }
$ws0 = "item()?['slug0']"
$ws1 = "if(startsWith($ws0, '-'), substring($ws0, 1), $ws0)"
$wsIdFull = "concat(items('Each_feed')?['crdr_key'], '-', if(endsWith($ws1, '-'), substring($ws1, 0, sub(length($ws1), 1)), $ws1))"
$wsc['Keyed'] = [ordered]@{ type = 'Select'; runAfter = (After 'Slugged'); inputs = @{ from = "@body('Slugged')"; select = [ordered]@{
            title = "@item()?['title']"; id = "@item()?['id']"; body = "@item()?['body']"; idcut = "@substring($wsIdFull, 0, min(100, length($wsIdFull)))" } } }
$wsKeydate = "if(empty(coalesce(outputs('Profile')?['keydate'], '')), if(contains(outputs('Page'), 'name=""updated_at"" content=""'), formatDateTime($(MetaExpr 'updated_at'), 'yyyy-MM-ddTHH:mm:ssZ'), ''), outputs('Profile')?['keydate'])"
$wsc['Keydate'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Keyed'); inputs = "@$wsKeydate" }
$wIdc = "item()?['idcut']"
$wExt = "if(endsWith($wIdc, '-'), substring($wIdc, 0, sub(length($wIdc), 1)), $wIdc)"
$wTitle = "if(empty(coalesce(outputs('Profile')?['titlePrefix'], '')), item()?['title'], concat(outputs('Profile')?['titlePrefix'], ': ', item()?['title']))"
$wSummary = Trunc "item()?['body']" 20000
$wsc['Shaped'] = [ordered]@{ type = 'Select'; runAfter = (After 'Keydate'); inputs = @{ from = "@body('Keyed')"; select = [ordered]@{
            externalid = "@$wExt"; key = "@concat($wExt, '$SEP', $wSummary)"
            title = "@$(Trunc $wTitle 400)"; summary = "@$wSummary"; products = "@$(Trunc "items('Each_feed')?['crdr_products']" 400)"
            horizon = $hz.future; keydate = "@outputs('Keydate')"; datelabel = "@$(Trunc "coalesce(outputs('Profile')?['label'], 'Web page')" 100)"; actionrequired = $false
            url = "@if(empty(item()?['id']), items('Each_feed')?['crdr_url'], concat(items('Each_feed')?['crdr_url'], '#', item()?['id']))"; lastchanged = "@outputs('Keydate')"
            snapshot = "@concat('{""externalid"":""', $wExt, '"",""keydate"":""', outputs('Keydate'), '""}')" } } }
# First section with a given id only (engine $seen), as in the release-note collector.
$wsc['Id_list'] = [ordered]@{ type = 'Select'; runAfter = (After 'Shaped'); inputs = @{ from = "@body('Shaped')"; select = "@item()?['externalid']" } }
$wsc['Ids'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Id_list'); inputs = "@xml(concat('<r><i>', join(body('Id_list'), '</i><i>'), '</i></r>'))" }
$wsFirst = "equals(int(xpath(outputs('Ids'), concat('count(/r/i[position() < ', string(add(item(), 1)), '][. = ''', body('Id_list')[item()], '''])'))), 0)"
$wsc['First_ids'] = [ordered]@{ type = 'Query'; runAfter = (After 'Ids'); inputs = @{ from = "@range(0, length(body('Shaped')))"; where = "@$wsFirst" } }
$wsc['Shape'] = [ordered]@{ type = 'Select'; runAfter = (After 'First_ids'); inputs = @{ from = "@body('First_ids')"; select = "@body('Shaped')[item()]" } }
$wsCreate = [ordered]@{ 'item/crdr_feed@odata.bind' = "@concat('/crdr_feeds(', items('Each_feed')?['crdr_feedid'], ')')"
    'item/crdr_confidencelabel' = "@coalesce(outputs('Profile')?['confidenceLabel'], '')"
    'item/crdr_nature' = "@if(empty(coalesce(outputs('Profile')?['nature'], '')), null, $(JsonLit $natOptFeed)?[outputs('Profile')?['nature']])" }
Add-UpsertAndLog $wsc 'Shape' $src.feed 'Shape' $feedFilter $wsCreate
# Change detection on the section's HTML, not on the date: a section is new or changed when (id, summary) isn't stored yet.
$wsc['List_existing'].inputs.parameters['$select'] = 'crdr_signalid,crdr_externalid,crdr_lastchanged,crdr_title,crdr_keydate,crdr_datelabel,crdr_horizon,crdr_actionrequired,crdr_summary'
$wsc['Existing_keys'].inputs.select = "@concat(item()?['crdr_externalid'], '$SEP', coalesce(item()?['crdr_summary'], ''))"
# Silent first run (no marker yet): signals are created without version rows, so no events and no cards.
$isNew = $wsc['Upsert'].actions['Is_new']
$cv = $isNew.actions['Create_version']; $cv.runAfter = @{}
$isNew.actions['Create_version'] = [ordered]@{ type = 'If'; runAfter = (After 'Create_signal'); expression = @{ equals = @("@empty(coalesce(items('Each_feed')?['crdr_lastmarker'], ''))", $false) }
    actions = [ordered]@{ Create_version_row = $cv }; else = @{ actions = @{} } }
Add-FeedLoop $ws $wsKind $wsc "outputs('Marker')" 'feed'
$flows['CollectWebSections'] = New-Flow 'Change Radar: collect the active web page section feeds (crdr_feed kind webpage_sections): the Book of News for an event and undated Learn pages such as licensing and billing rates. One signal per heading section; a changed section updates its signal. The first run of a feed is silent (ADR 0018, ADR 0019, spike T11).' (Recurrence 'Day' 1 @{ hours = @('5'); minutes = @('35') }) $ws

# ---------- Licensing guide change logs (ADR 0019, spike T12) ----------
# Mirrors engine Get-PdfChangeLogSignals. Daily: HEAD the fwlink (the HTTP action doesn't follow redirects, so read Location),
# HEAD the PDF for Last-Modified, and only when it changed GET it and run AI Builder text recognition (about 3 AI Builder
# credits a guide). Rows are rebuilt from the change log lines by position. First run of a feed: silent, as for web sections.
$pcKind = Get-Opt 'feedkind' 'pdf_changelog'
$monthsJson = '{"january":"01","february":"02","march":"03","april":"04","may":"05","june":"06","july":"07","august":"08","september":"09","october":"10","november":"11","december":"12"}'
$pcUa = [ordered]@{ 'User-Agent' = 'ChangeRadar/1.0 (signal collector)'; Accept = 'application/pdf' }
$pc = [ordered]@{}
Add-FeedConfig $pc
$pcc = [ordered]@{}
$pcc['Reset_bounds'] = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'bounds'; value = @() } }
$pcc['Reset_rows'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Reset_bounds'); inputs = @{ name = 'rows'; value = @() } }
$pcc['Profile'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Reset_rows'); inputs = "@json(coalesce(items('Each_feed')?['crdr_profile'], '{}'))" }
$pcc['Head_fwlink'] = [ordered]@{ type = 'Http'; runAfter = (After 'Profile'); inputs = [ordered]@{ method = 'HEAD'; uri = "@items('Each_feed')?['crdr_url']"; headers = $pcUa } }
$pcc['Pdf_url'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Head_fwlink' @('Succeeded', 'Failed')); inputs = "@coalesce(outputs('Head_fwlink')?['headers']?['Location'], items('Each_feed')?['crdr_url'])" }
$pcc['Head_pdf'] = [ordered]@{ type = 'Http'; runAfter = (After 'Pdf_url'); inputs = [ordered]@{ method = 'HEAD'; uri = "@outputs('Pdf_url')"; headers = $pcUa } }
$pcc['Marker'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Head_pdf'); inputs = "@coalesce(outputs('Head_pdf')?['headers']?['Last-Modified'], '')" }
$pcc['Changed_page'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Marker'); inputs = "@and(not(equals(outputs('Marker'), '')), not(equals(outputs('Marker'), coalesce(items('Each_feed')?['crdr_lastmarker'], ''))))" }
$pcc['If_changed'] = [ordered]@{ type = 'If'; runAfter = (After 'Changed_page'); expression = @{ equals = @("@outputs('Changed_page')", $true) }
    actions = [ordered]@{
        # Named Get_page: the shared feed loop's run log reports its HTTP status.
        Get_page = [ordered]@{ type = 'Http'; runAfter = @{}; inputs = [ordered]@{ method = 'GET'; uri = "@outputs('Pdf_url')"; headers = $pcUa } }
        # Spike T12: base64(body) (not body()?['$content']); 'pages' is ignored by the model, so it isn't sent.
        Ocr = [ordered]@{ type = 'OpenApiConnection'; runAfter = (After 'Get_page')
            inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_commondataserviceforapps'; operationId = 'aibuilderpredict_textrecognition'; apiId = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps' }
                # The prebuilt model's record is looked up by template at run time (Text_model): its id is environment data.
                parameters = [ordered]@{ recordId = "@first(body('Text_model')?['value'])?['msdyn_aimodelid']"
                    item = [ordered]@{ version = '2.0'; requestv2 = [ordered]@{ '@@odata.type' = '#Microsoft.Dynamics.CRM.expando'; mimeType = 'application/pdf'; base64Encoded = "@base64(body('Get_page'))" } } }
                authentication = "@parameters('`$authentication')" } }
    }; else = @{ actions = @{} } }
$pcc['Results'] = [ordered]@{ type = 'Compose'; runAfter = (After 'If_changed'); inputs = "@coalesce(actions('Ocr')?['outputs']?['body']?['responsev2']?['predictionOutput']?['results'], json('[]'))" }
$pcc['Cl_pages'] = [ordered]@{ type = 'Query'; runAfter = (After 'Results'); inputs = @{ from = "@outputs('Results')"; where = "@and(contains(toLower(coalesce(item()?['fullPageText'], '')), 'change log'), not(contains(coalesce(item()?['fullPageText'], ''), '.....')))" } }
$pcc['Cl_nums'] = [ordered]@{ type = 'Select'; runAfter = (After 'Cl_pages'); inputs = @{ from = "@body('Cl_pages')"; select = "@item()?['page']" } }
$pcc['Start'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Cl_nums'); inputs = "@if(empty(body('Cl_nums')), 0, max(body('Cl_nums')))" }
$pcc['Note_no_log'] = [ordered]@{ type = 'If'; runAfter = (After 'Start'); expression = @{ and = @(@{ equals = @("@outputs('Changed_page')", $true) }, @{ equals = @("@outputs('Start')", 0) }) }
    actions = @{ Add_gap_log = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'gaps'; value = 'change log not found' } } }; else = @{ actions = @{} } }
$pcc['Log_pages'] = [ordered]@{ type = 'Query'; runAfter = (After 'Note_no_log'); inputs = @{ from = "@outputs('Results')"; where = "@and(greater(outputs('Start'), 0), greaterOrEquals(item()?['page'], outputs('Start')))" } }
# A line is a date cell when it is exactly '<Month> <year>' (engine Test-MonthYear; the year's digits checked without int()).
function IsMonthYear([string]$x) {
    $t = "trim(${x}?['t'])"; $yr = "last(split($t, ' '))"
    $digitsGone = $yr; foreach ($dg in 0..9) { $digitsGone = "replace($digitsGone, '$dg', '')" }
    "and(equals(length(split($t, ' ')), 2), contains(json('$monthsJson'), toLower(first(split($t, ' ')))), equals(length($yr), 4), equals(length($digitsGone), 0))"
}
$pg = [ordered]@{}
$pg['Lines'] = [ordered]@{ type = 'Select'; runAfter = @{}; inputs = @{ from = "@coalesce(items('Each_page')?['lines'], json('[]'))"; select = [ordered]@{
            t = "@trim(coalesce(item()?['text'], ''))"; top = "@float(item()?['boundingBox']?['top'])"; left = "@float(item()?['boundingBox']?['left'])"
            mid = "@add(float(item()?['boundingBox']?['top']), div(float(item()?['boundingBox']?['height']), 2))" } } }
$pg['My_lines'] = [ordered]@{ type = 'Query'; runAfter = (After 'Lines'); inputs = @{ from = "@body('Lines')"; where = "@$(IsMonthYear 'item()')" } }
$pg['First_top'] = [ordered]@{ type = 'Compose'; runAfter = (After 'My_lines'); inputs = "@if(empty(body('My_lines')), 2, first(body('My_lines'))?['top'])" }
$pg['Above'] = [ordered]@{ type = 'Query'; runAfter = (After 'First_top'); inputs = @{ from = "@body('Lines')"; where = "@less(item()?['top'], outputs('First_top'))" } }
$pg['Hp'] = [ordered]@{ type = 'Query'; runAfter = (After 'Above'); inputs = @{ from = "@body('Above')"; where = "@startsWith(item()?['t'], 'Page')" } }
$pg['Hc'] = [ordered]@{ type = 'Query'; runAfter = (After 'Hp'); inputs = @{ from = "@body('Above')"; where = "@equals(item()?['t'], 'Change')" } }
$pg['Ha'] = [ordered]@{ type = 'Query'; runAfter = (After 'Hc'); inputs = @{ from = "@body('Above')"; where = "@equals(item()?['t'], 'Action')" } }
$pg['Hd'] = [ordered]@{ type = 'Query'; runAfter = (After 'Ha'); inputs = @{ from = "@body('Above')"; where = "@equals(item()?['t'], 'Date')" } }
$pg['If_headers'] = [ordered]@{ type = 'If'; runAfter = (After 'Hd'); expression = @{ and = @(@{ equals = @("@empty(body('Hp'))", $false) }, @{ equals = @("@empty(body('Hc'))", $false) }, @{ equals = @("@empty(body('Ha'))", $false) }, @{ equals = @("@empty(body('Hd'))", $false) }) }
    actions = @{ Set_bounds = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'bounds'; value = "@createArray(add(first(body('Hp'))?['left'], 0.04), sub(first(body('Hc'))?['left'], 0.01), sub(first(body('Ha'))?['left'], 0.01), sub(first(body('Hd'))?['left'], 0.01))" } } }; else = @{ actions = @{} } }
$pg['Note_no_headers'] = [ordered]@{ type = 'If'; runAfter = (After 'If_headers'); expression = @{ equals = @("@empty(variables('bounds'))", $true) }
    actions = @{ Add_gap_headers = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'gaps'; value = "@concat('page ', string(items('Each_page')?['page']), ': change log headers not found')" } } }; else = @{ actions = @{} } }
$pg['Dates'] = [ordered]@{ type = 'Query'; runAfter = (After 'Note_no_headers'); inputs = @{ from = "@if(empty(variables('bounds')), json('[]'), body('My_lines'))"; where = "@greaterOrEquals(item()?['left'], variables('bounds')[3])" } }
$pg['Foot'] = [ordered]@{ type = 'Query'; runAfter = (After 'Dates'); inputs = @{ from = "@body('Lines')"; where = "@and(not(empty(body('Dates'))), startsWith(item()?['t'], '$([char]0x00A9)'), greater(item()?['top'], if(empty(body('Dates')), 2, last(body('Dates'))?['top'])))" } }
$pg['Foot_tops'] = [ordered]@{ type = 'Select'; runAfter = (After 'Foot'); inputs = @{ from = "@body('Foot')"; select = "@item()?['top']" } }
$pg['Foot_top'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Foot_tops'); inputs = "@if(empty(body('Foot_tops')), 2, min(body('Foot_tops')))" }
$pg['Hd_top'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Foot_top'); inputs = "@if(empty(body('Hd')), 0, first(body('Hd'))?['top'])" }
$D = "body('Dates')"; $ix = 'item()'; $n = "length($D)"
$dk = "$D[$ix]"; $dPrev = "$D[sub($ix, 1)]"; $dNext = "$D[add($ix, 1)]"
$hasNext = "less(add($ix, 1), $n)"
$loMid = "if(equals($ix, 0), add(outputs('Hd_top'), 0.008), div(add(${dPrev}?['mid'], ${dk}?['mid']), 2))"
$hiMid = "if($hasNext, div(add(${dk}?['mid'], ${dNext}?['mid']), 2), min(sub(outputs('Foot_top'), 0.004), add(${dk}?['mid'], sub(${dk}?['mid'], $loMid))))"
$loTop = "sub(${dk}?['top'], 0.004)"
$hiTop = "if($hasNext, sub(${dNext}?['top'], 0.004), min(sub(outputs('Foot_top'), 0.004), add(${dk}?['top'], 0.04)))"
$isMid = "equals(coalesce(outputs('Profile')?['rowAlign'], 'top'), 'middle')"
$pg['Row_defs'] = [ordered]@{ type = 'Select'; runAfter = (After 'Hd_top'); inputs = @{ from = "@range(0, $n)"; select = [ordered]@{
            t = "@${dk}?['t']"; lo = "@if($isMid, $loMid, $loTop)"; hi = "@if($isMid, $hiMid, $hiTop)" } } }
$r = "items('Each_row')"
$yv = "if($isMid, item()?['mid'], item()?['top'])"
$inRow = "and(greaterOrEquals($yv, ${r}?['lo']), less($yv, ${r}?['hi']), not(and($(IsMonthYear 'item()'), greaterOrEquals(item()?['left'], variables('bounds')[3]))))"
$colCond = @(
    "less(item()?['left'], variables('bounds')[0])"
    "and(greaterOrEquals(item()?['left'], variables('bounds')[0]), less(item()?['left'], variables('bounds')[1]))"
    "and(greaterOrEquals(item()?['left'], variables('bounds')[1]), less(item()?['left'], variables('bounds')[2]))"
    "and(greaterOrEquals(item()?['left'], variables('bounds')[2]), less(item()?['left'], variables('bounds')[3]))")
$row = [ordered]@{}; $prevR = $null
foreach ($k in 0..3) {
    $row["C$k"] = [ordered]@{ type = 'Query'; runAfter = $(if ($prevR) { After $prevR } else { @{} }); inputs = @{ from = "@body('Lines')"; where = "@and($inRow, $($colCond[$k]))" } }
    $row["T$k"] = [ordered]@{ type = 'Select'; runAfter = (After "C$k"); inputs = @{ from = "@body('C$k')"; select = "@item()?['t']" } }
    $prevR = "T$k"
}
$t0 = "trim(join(body('T0'), ' '))"; $t1 = "trim(join(body('T1'), ' '))"; $t2 = "trim(join(body('T2'), ' '))"; $t3 = "trim(join(body('T3'), ' '))"
# Repairs, as the engine: 'Customer Insights New' (topic and change type merged), 'Various Dynamics 365' (page and topic merged).
$row['Kind'] = [ordered]@{ type = 'Compose'; runAfter = (After 'T3'); inputs = "@if(empty($t2), if(endsWith($t1, ' New'), 'New', if(endsWith($t1, ' Update'), 'Update', if(endsWith($t1, ' Remove'), 'Remove', ''))), $t2)" }
$row['Topic_a'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Kind'); inputs = "@if(and(empty($t2), not(empty(outputs('Kind')))), substring($t1, 0, sub(length($t1), add(length(outputs('Kind')), 1))), $t1)" }
$row['Add_row'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Topic_a'); inputs = @{ name = 'rows'; value = [ordered]@{
            month = "@${r}?['t']"; kind = "@outputs('Kind')"; change = "@$t3"
            pages = "@if(startsWith($t0, 'Various '), 'Various', if(startsWith($t0, 'N/A '), 'N/A', $t0))"
            topic = "@if(startsWith($t0, 'Various '), trim(concat(substring($t0, 8), ' ', outputs('Topic_a'))), if(startsWith($t0, 'N/A '), trim(concat(substring($t0, 4), ' ', outputs('Topic_a'))), outputs('Topic_a')))" } } }
$pg['Each_row'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Row_defs')"; runAfter = (After 'Row_defs'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $row }
$pcc['Each_page'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Log_pages')"; runAfter = (After 'Log_pages'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $pg }
$pcc['Rows'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_page'); inputs = @{ from = "@variables('rows')"; where = "@not(empty(item()?['change']))" } }
$pcc['Slugged'] = [ordered]@{ type = 'Select'; runAfter = (After 'Rows'); inputs = @{ from = "@body('Rows')"; select = [ordered]@{
            month = "@item()?['month']"; kind = "@item()?['kind']"; change = "@item()?['change']"; pages = "@item()?['pages']"; topic = "@item()?['topic']"
            slug0 = "@$(SlugRaw "concat(item()?['month'], ' ', item()?['change'])")" } } }
$p0 = "item()?['slug0']"; $p1 = "if(startsWith($p0, '-'), substring($p0, 1), $p0)"
$pcIdFull = "concat(items('Each_feed')?['crdr_key'], '-', if(endsWith($p1, '-'), substring($p1, 0, sub(length($p1), 1)), $p1))"
$pcc['Keyed'] = [ordered]@{ type = 'Select'; runAfter = (After 'Slugged'); inputs = @{ from = "@body('Slugged')"; select = [ordered]@{
            month = "@item()?['month']"; kind = "@item()?['kind']"; change = "@item()?['change']"; pages = "@item()?['pages']"; topic = "@item()?['topic']"
            idcut = "@substring($pcIdFull, 0, min(100, length($pcIdFull)))" } } }
$pIdc = "item()?['idcut']"; $pExt = "if(endsWith($pIdc, '-'), substring($pIdc, 0, sub(length($pIdc), 1)), $pIdc)"
$guide = "coalesce(outputs('Profile')?['guideName'], items('Each_feed')?['crdr_key'])"
$pSummary = "concat(item()?['kind'], ': ', item()?['change'], '. Topic: ', item()?['topic'], '. Page(s): ', item()?['pages'], '. Month: ', item()?['month'], '. Source: the ', $guide, '.')"
$pKeydate = "concat(last(split(item()?['month'], ' ')), '-', json('$monthsJson')?[toLower(first(split(item()?['month'], ' ')))], '-01')"
$pcc['Shaped'] = [ordered]@{ type = 'Select'; runAfter = (After 'Keyed'); inputs = @{ from = "@body('Keyed')"; select = [ordered]@{
            externalid = "@$pExt"; key = "@concat($pExt, '$SEP', $(Trunc $pSummary 20000))"
            title = "@$(Trunc "concat($guide, ': ', item()?['change'])" 400)"; summary = "@$(Trunc $pSummary 20000)"; products = "@$(Trunc "items('Each_feed')?['crdr_products']" 400)"
            horizon = $hz.future; keydate = "@$pKeydate"; datelabel = "@$(Trunc "concat(coalesce(outputs('Profile')?['label'], 'Licensing guide'), ' · ', item()?['kind'])" 100)"; actionrequired = $false
            url = "@items('Each_feed')?['crdr_url']"; lastchanged = "@$pKeydate"; snapshot = "@concat('{""externalid"":""', $pExt, '""}')" } } }
$pcc['Id_list'] = [ordered]@{ type = 'Select'; runAfter = (After 'Shaped'); inputs = @{ from = "@body('Shaped')"; select = "@item()?['externalid']" } }
$pcc['Ids'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Id_list'); inputs = "@xml(concat('<r><i>', join(body('Id_list'), '</i><i>'), '</i></r>'))" }
$pcc['First_ids'] = [ordered]@{ type = 'Query'; runAfter = (After 'Ids'); inputs = @{ from = "@range(0, length(body('Shaped')))"; where = "@$wsFirst" } }
$pcc['Shape'] = [ordered]@{ type = 'Select'; runAfter = (After 'First_ids'); inputs = @{ from = "@body('First_ids')"; select = "@body('Shaped')[item()]" } }
Add-UpsertAndLog $pcc 'Shape' $src.feed 'Shape' $feedFilter $wsCreate
$pcc['List_existing'].inputs.parameters['$select'] = 'crdr_signalid,crdr_externalid,crdr_lastchanged,crdr_title,crdr_keydate,crdr_datelabel,crdr_horizon,crdr_actionrequired,crdr_summary'
$pcc['Existing_keys'].inputs.select = "@concat(item()?['crdr_externalid'], '$SEP', coalesce(item()?['crdr_summary'], ''))"
$isNew2 = $pcc['Upsert'].actions['Is_new']
$cv2 = $isNew2.actions['Create_version']; $cv2.runAfter = @{}
$isNew2.actions['Create_version'] = [ordered]@{ type = 'If'; runAfter = (After 'Create_signal'); expression = @{ equals = @("@empty(coalesce(items('Each_feed')?['crdr_lastmarker'], ''))", $false) }
    actions = [ordered]@{ Create_version_row = $cv2 }; else = @{ actions = @{} } }
Add-FeedLoop $pc $pcKind $pcc "outputs('Marker')" 'feed'
# Two more variables for this collector, initialised before the feeds are listed.
$pc['Init_bounds'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_failed'); inputs = @{ variables = @(@{ name = 'bounds'; type = 'array'; value = @() }) } }
$pc['Init_rows'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_bounds'); inputs = @{ variables = @(@{ name = 'rows'; type = 'array'; value = @() }) } }
$pc['Text_model'] = Dv 'ListRecords' ([ordered]@{ entityName = 'msdyn_aimodels'; '$select' = 'msdyn_aimodelid,msdyn_name'; '$filter' = "msdyn_TemplateId/msdyn_uniquename eq 'TextRecognition' and statecode eq 1"; '$top' = 1 }) (After 'Init_rows')
$pc['List_feeds'].runAfter.Remove('Init_failed'); $pc['List_feeds'].runAfter['Text_model'] = @('Succeeded')
$flows['CollectPdfChangeLogs'] = New-Flow 'Change Radar: collect the active licensing guide change logs (crdr_feed kind pdf_changelog): when a guide PDF changes (Last-Modified), read it with AI Builder text recognition and keep one signal per change log row. The first run of a feed is silent (ADR 0019, spike T12).' (Recurrence 'Day' 1 @{ hours = @('5'); minutes = @('40') }) $pc

# ---------- Recompute horizons (daily) ----------
$kd = "item()?['crdr_keydate']"
$newHorizon = "if(equals(item()?['crdr_source'], $($src.mc)), if(and(equals(item()?['crdr_actionrequired'], true), not(empty($kd)), $(& $within $kd $nowDays)), $($hz.now), if(or(and(equals(item()?['crdr_actionrequired'], true), not(empty($kd)), $(& $within $kd $immDays)), and(startsWith(coalesce(item()?['crdr_datelabel'], ''), 'Plan for change'), not(empty($kd)), $(& $recent $kd))), $($hz.imminent), $($hz.future))), " +
"if(or(startsWith(coalesce(item()?['crdr_datelabel'], ''), 'Launched'), startsWith(coalesce(item()?['crdr_datelabel'], ''), 'Cancelled')), $($hz.future), if(startsWith(coalesce(item()?['crdr_datelabel'], ''), 'Rolling out'), $($hz.imminent), if(startsWith(coalesce(item()?['crdr_datelabel'], ''), 'Slipped'), $($hz.future), if(and(not(empty($kd)), $(& $within $kd $rmDays)), $($hz.imminent), $($hz.future))))))"
# A roadmap item still in development whose GA month has passed becomes 'Slipped · ...' (the collector only rewrites it when Microsoft edits the item).
$label = "coalesce(item()?['crdr_datelabel'], '')"
$newLabel = "if(and(equals(item()?['crdr_source'], $($src.roadmap)), startsWith($label, 'In development'), not(empty($kd)), less(ticks(coalesce($kd, '9999-12-31T00:00:00Z')), ticks(startOfMonth(utcNow())))), concat('Slipped · ', $label), $label)"
$hzActions = [ordered]@{}
$hzActions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
Add-ConfigQuery $hzActions 'Config_now_days' 'horizon_now_days'
Add-ConfigQuery $hzActions 'Config_imminent_days' 'horizon_imminent_days'
Add-ConfigQuery $hzActions 'Config_recent_days' 'horizon_recent_days'
Add-ConfigQuery $hzActions 'Config_roadmap_days' 'horizon_roadmap_days'
$hzScope = [ordered]@{}
$hzScope['Get_items'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signals'; '$select' = 'crdr_signalid,crdr_source,crdr_keydate,crdr_actionrequired,crdr_datelabel,crdr_horizon'
        '$filter' = "crdr_source eq $($src.mc) or crdr_source eq $($src.roadmap)" }) @{} @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$hzScope['Rated'] = [ordered]@{ type = 'Select'; runAfter = (After 'Get_items'); inputs = @{ from = "@body('Get_items')?['value']"; select = [ordered]@{ id = "@item()?['crdr_signalid']"; old = "@item()?['crdr_horizon']"; new = "@$newHorizon"; oldlabel = "@item()?['crdr_datelabel']"; newlabel = "@$newLabel" } } }
$hzScope['Changed'] = [ordered]@{ type = 'Query'; runAfter = (After 'Rated'); inputs = @{ from = "@body('Rated')"; where = "@or(not(equals(item()?['old'], item()?['new'])), not(equals(item()?['oldlabel'], item()?['newlabel'])))" } }
$hzScope['Update'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Changed')"; runAfter = (After 'Changed'); runtimeConfiguration = @{ concurrency = @{ repetitions = 10 } }
    actions = @{ Update_horizon = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@items('Update')?['id']"; 'item/crdr_horizon' = "@items('Update')?['new']"; 'item/crdr_datelabel' = "@items('Update')?['newlabel']" }) } }
$hzActions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = [ordered]@{ Config_now_days = @('Succeeded'); Config_imminent_days = @('Succeeded'); Config_recent_days = @('Succeeded'); Config_roadmap_days = @('Succeeded') }; actions = $hzScope }
Add-RunLog $hzActions 'horizons' 'Get_items' "length(coalesce(body('Get_items')?['value'], json('[]')))" 'Rated' $false
$flows['RecomputeHorizons'] = New-Flow 'Change Radar: recompute Now/Imminent/Future for Message Center and roadmap signals as their dates approach (ADR 0007).' (Recurrence 'Day' 1 @{ hours = @('6') }) $hzActions

# ---------- Estate inventory (daily, delegated; ADR 0008) ----------
# Mirrors engine/ChangeRadar.Matching.psm1 Get-AssetFingerprints for the facets live inventory can give today:
# product, resource type, environment type, connector, harness, generative orchestration, custom web channel,
# scheduled prompt, and maker/invoker connections. Owner-based facets need principals (not collected yet), and
# PCF, SharePoint tempauth and kit capabilities need Dataverse detail or the kit. The maps come from
# seed/asset-signatures.json, so the flow and the engine read the same data. Parity: setup/dev/Test-EstateParity.ps1.
$sig = Get-Content -Raw $SignaturesPath | ConvertFrom-Json -Depth 20
$ppApi = '/providers/Microsoft.PowerApps/apis/shared_powerplatformadminv2'
function PpAdmin([string]$op, $params, [hashtable]$runAfter = @{}) {
    [ordered]@{ type = 'OpenApiConnection'; runAfter = $runAfter
        inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_powerplatformadminv2'; operationId = $op; apiId = $ppApi }; parameters = $params; authentication = $auth } }
}
# -InputObject, not the pipeline: piping unrolls a one-item array into a bare value, which breaks intersection().
function JsonLit($o) { "json('" + ((ConvertTo-Json -InputObject $o -Depth 10 -Compress) -replace "'", "''") + "')" }
$facetOpt = [ordered]@{}; foreach ($f in @($schema.choices.facet)) { $facetOpt[$f] = Get-Opt 'facet' $f }
$envTypeOpt = [ordered]@{}; foreach ($k in $sig.environmentTypeBySku.PSObject.Properties) { $envTypeOpt[$k.Name] = Get-Opt 'environmenttype' $k.Value }
$liveSource = Get-Opt 'assetsource' 'live'
# Source is set only when an asset is created; the detail flow may relabel it fixture, and matching ignores source
# (anything not synthetic), so a relabelled asset is never duplicated (ADR 0008 addendum 2).
$syntheticSource = Get-Opt 'assetsource' 'synthetic'
$fixtureSource = Get-Opt 'assetsource' 'fixture'
# Facets the detail flow owns: the estate flow never deletes them. By name, or (ADR 0017) by evidence prefix.
$detailFacets = JsonLit @($sig.detailFacets.values)
$detailPrefix = $sig.detailFacets.evidencePrefix
$excludedTypes = @("'microsoft.powerplatformconnector/connectors'", "'microsoft.powerplatformusage/usagerecords'", "'microsoft.powerplatform/environments'", "'microsoft.powerplatform/environmentgroups'")  # groups: tenant structure, not maker assets (seen in inventory 2026-11-22)
# '$type' must be the first key of every clause (verified 2026-11-19); [ordered] keeps it there.
$clauses = @(
    [ordered]@{ '$type' = 'extend'; FieldName = 'joinKey'; Expression = 'tolower(tostring(properties.environmentId))' }
    [ordered]@{ '$type' = 'join'; JoinKind = 'leftouter'; LeftColumnName = 'joinKey'; RightColumnName = 'joinKey'
        RightTable = [ordered]@{ TableName = 'PowerPlatformResources'; Clauses = @(
                [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = '=='; Values = @("'microsoft.powerplatform/environments'") }
                [ordered]@{ '$type' = 'project'; FieldList = @('joinKey = tolower(name)', 'environmentName = tostring(properties.displayName)', 'environmentType = tostring(properties.environmentType)') }) } }
    [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = '!in~'; Values = $excludedTypes }
)
$it = "items('Upsert')"
$raw = "${it}?['raw']"
$p = "${raw}?['properties']"
$conns = "coalesce(${p}?['powerPlatformConnectors'], json('[]'))"
function Fact([string]$cond, [string]$facet, [string]$valueExpr, [string]$evidenceExpr) {
    # Built with addProperty, so values and evidence need no JSON escaping.
    "if($cond, createArray(addProperty(addProperty(json('{""facet"":""$facet""}'), 'value', $valueExpr), 'evidence', $evidenceExpr)), json('[]'))"  # createArray() with no arguments is invalid (observed 2026-11-20)
}
$rtMap = JsonLit $sig.resourceTypeByType
$harnessMap = JsonLit $sig.harnessByValue
$webChannels = JsonLit @($sig.customWebChannels.values)
$schedOps = JsonLit @($sig.scheduledPrompt.triggerOperations)
$schedConns = JsonLit @($sig.scheduledPrompt.connectors)
$gen = $sig.orchestrationGenerative
$scalar = 'union(' + (@(
        (Fact "not(empty(${rtMap}?[${raw}?['type']]))" 'resource_type' "${rtMap}?[${raw}?['type']]" "concat('inventory.type = ''', ${raw}?['type'], '''')")
        (Fact "not(empty(${it}?['envtypeLabel']))" 'environment_type' "${it}?['envtypeLabel']" "concat('environments[', ${it}?['envid'], '].properties.environmentType = ''', ${it}?['envtypeRaw'], '''')")
        (Fact "not(empty(${harnessMap}?[coalesce(${p}?['harness'], '-')]))" 'harness' "${harnessMap}?[coalesce(${p}?['harness'], '-')]" "concat('inventory.properties.harness = ''', ${p}?['harness'], '''')")
        (Fact "equals(${p}?['orchestration'], '$gen')" 'capability' "'generative_orchestration'" "'inventory.properties.orchestration = ''$gen'''")
        (Fact "not(empty(intersection(coalesce(${p}?['channels'], json('[]')), $webChannels)))" 'capability' "'custom_web_ui'" "concat('inventory.properties.channels contains ', string(intersection(coalesce(${p}?['channels'], json('[]')), $webChannels)), ' [$($sig.customWebChannels.status)]')")
        (Fact "and(contains($schedOps, coalesce(${p}?['trigger']?['operationId'], '-')), not(empty(intersection(body('Connector_ids'), $schedConns))))" 'capability' "'scheduled_prompt'" "concat('inventory.properties.trigger.operationId = ''', ${p}?['trigger']?['operationId'], ''' and connector ''', first(intersection(body('Connector_ids'), $schedConns)), '''')")
        (Fact "and(equals(${raw}?['type'], 'microsoft.copilotstudio/agents'), greater(int(coalesce(${p}?['componentsCounts']?['knowledge'], 0)), 0))" 'capability' "'$($sig.agentKnowledge.capability)'" "concat('inventory.properties.componentsCounts.knowledge = ', string(${p}?['componentsCounts']?['knowledge']), ' (knowledgeByType ', string(coalesce(${p}?['componentsCounts']?['knowledgeByType'], json('{}'))), ') [$($sig.agentKnowledge.status)]')")
        (Fact "not(equals($(ModelLookup "${p}?['model']"), ''))" 'model' "$(ModelLookup "${p}?['model']")" "concat('inventory.properties.model = ''', ${p}?['model'], '''')")
        (Fact "contains(string($conns), '""connectionProvider"":""Maker""')" 'auth_mode' "'maker'" "'a connector operation has connectionProvider = ''Maker'''")
        (Fact "contains(string($conns), '""connectionProvider"":""User""')" 'auth_mode' "'invoker'" "'a connector operation has connectionProvider = ''User'''")
    ) -join ', ') + ')'
$productList = "if(and(equals(${raw}?['type'], 'microsoft.copilotstudio/agents'), contains($(JsonLit @($sig.agentBuilderCreatedIn)), coalesce(${p}?['createdIn'], '-'))), createArray('$($sig.agentBuilderProduct)'), coalesce($(JsonLit $sig.productByType)?[${raw}?['type']], json('[]')))"

$esActions = [ordered]@{}
$esActions['Init_rows'] = [ordered]@{ type = 'InitializeVariable'; runAfter = @{}; inputs = @{ variables = @(@{ name = 'Rows'; type = 'array'; value = @() }) } }
$esActions['Init_skip'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_rows'); inputs = @{ variables = @(@{ name = 'SkipToken'; type = 'string'; value = '' }) } }
$esActions['Init_more'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_skip'); inputs = @{ variables = @(@{ name = 'More'; type = 'boolean'; value = $true }) } }
$es = [ordered]@{}
$es['Pages'] = [ordered]@{ type = 'Until'; runAfter = @{}; expression = "@equals(variables('More'), false)"; limit = @{ count = 100; timeout = 'PT1H' }
    actions = [ordered]@{
        Query_page = PpAdmin 'QueryResources' ([ordered]@{ 'api-version' = '2024-10-01'; 'body/TableName' = 'PowerPlatformResources'; 'body/Clauses' = $clauses; 'body/Options/Top' = 1000; 'body/Options/SkipToken' = "@variables('SkipToken')" })
        Merge_rows = [ordered]@{ type = 'Compose'; runAfter = (After 'Query_page'); inputs = "@union(variables('Rows'), coalesce(body('Query_page')?['data'], json('[]')))" }
        Set_rows   = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Merge_rows'); inputs = @{ name = 'Rows'; value = "@outputs('Merge_rows')" } }
        Set_skip   = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Set_rows'); inputs = @{ name = 'SkipToken'; value = "@coalesce(body('Query_page')?['skipToken'], '')" } }
        Set_more   = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Set_skip'); inputs = @{ name = 'More'; value = "@not(empty(variables('SkipToken')))" } }
    } }
$evOpt = [ordered]@{}; foreach ($v in $schema.choices.eventtype) { $evOpt[$v] = Get-Opt 'eventtype' $v }
function New-EventActions([string]$Prefix, [hashtable]$RunAfter, [string]$Type, [string]$SignalExpr, [string]$ExposureExpr, [string]$AssessmentExpr, [Collections.Specialized.OrderedDictionary]$Payload, [string]$CorrExpr, [string]$NameExpr, [string]$AssetExpr) {
    $a = [ordered]@{}
    $a["${Prefix}_payload"] = [ordered]@{ type = 'Compose'; runAfter = $RunAfter; inputs = $Payload }
    $rec = [ordered]@{ entityName = 'crdr_events'; 'item/crdr_name' = "@$(Trunc $NameExpr 200)"; 'item/crdr_eventtype' = $evOpt[$Type]
        'item/crdr_payloadjson' = "@string(outputs('${Prefix}_payload'))"; 'item/crdr_raisedon' = '@utcNow()'; 'item/crdr_correlationid' = "@$(Trunc $CorrExpr 100)" }
    # asset.modelchanged has no signal; its asset is the subject (ADR 0013).
    if ($SignalExpr) { $rec['item/crdr_signal@odata.bind'] = "@concat('/crdr_signals(', $SignalExpr, ')')" }
    if ($AssetExpr) { $rec['item/crdr_asset@odata.bind'] = "@concat('/crdr_assets(', $AssetExpr, ')')" }
    if ($ExposureExpr) { $rec['item/crdr_exposure@odata.bind'] = "@concat('/crdr_exposures(', $ExposureExpr, ')')" }
    if ($AssessmentExpr) { $rec['item/crdr_assessment@odata.bind'] = "@concat('/crdr_assessments(', $AssessmentExpr, ')')" }
    $a[$Prefix] = Dv 'CreateRecord' $rec (After "${Prefix}_payload")
    $a
}
function Add-Actions($target, $source) { foreach ($k in $source.Keys) { $target[$k] = $source[$k] } }
# ---------- asset.modelchanged (ADR 0013; engine Get-RecordEvents table 'asset') ----------
# Raised when an existing asset's known model is replaced by a different known model. A first model, or a model that
# is now unknown (unmapped or not reported), is not a move. OldRows: the asset's fingerprint rows before this run
# (crdr_name 'model: x'); NewFacets: this run's facets (facet, value). The payload carries what the card shows.
function Add-ModelChangeEvent([Collections.Specialized.OrderedDictionary]$actions, [string]$Prefix, [hashtable]$RunAfter, [string]$OldRowsExpr, [string]$NewFacetsExpr, [string]$AssetIdExpr, [string]$NameExpr, [string]$TypeLabelExpr, [string]$EnvNameExpr, [string]$EstateExpr, [string]$CallersExpr) {
    # Rows whose evidence starts with the detail prefix are a caller's model (ADR 0017), never the asset's own.
    $actions["${Prefix}_old"] = [ordered]@{ type = 'Query'; runAfter = $RunAfter; inputs = @{ from = "@$OldRowsExpr"; where = "@and(startsWith(coalesce(item()?['crdr_name'], ''), 'model: '), not(startsWith(coalesce(item()?['crdr_evidence'], ''), '$($sig.detailFacets.evidencePrefix)')))" } }
    $actions["${Prefix}_new"] = [ordered]@{ type = 'Query'; runAfter = (After "${Prefix}_old"); inputs = @{ from = "@$NewFacetsExpr"; where = "@equals(item()?['facet'], 'model')" } }
    $was = "substring(coalesce(first(body('${Prefix}_old'))?['crdr_name'], 'model: '), 7)"; $now = "coalesce(first(body('${Prefix}_new'))?['value'], '')"
    $pl = [ordered]@{ estate = "@$EstateExpr"; assetId = "@$AssetIdExpr"; assetName = "@$NameExpr"; assetType = "@$TypeLabelExpr"; environmentName = "@$EnvNameExpr"; fromModel = "@$was"; toModel = "@$now" }
    if ($CallersExpr) { $pl['callers'] = "@$CallersExpr" }
    $raise = [ordered]@{}
    Add-Actions $raise (New-EventActions "${Prefix}_raise" @{} 'asset.modelchanged' $null $null $null $pl "concat('asset.modelchanged|', $AssetIdExpr, '|', $now, '|', formatDateTime(utcNow(), 'yyyy-MM-dd'))" "concat('asset.modelchanged | ', $NameExpr, ' | ', $was, ' | ', $now)" $AssetIdExpr)
    $actions["${Prefix}_if"] = [ordered]@{ type = 'If'; runAfter = (After "${Prefix}_new")
        expression = @{ and = @(@{ equals = @("@empty(body('${Prefix}_old'))", $false) }, @{ equals = @("@empty(body('${Prefix}_new'))", $false) }, @{ not = @{ equals = @("@$was", "@$now") } }) }
        actions = $raise; else = @{ actions = @{} } }
}
$es['Shape'] = [ordered]@{ type = 'Select'; runAfter = (After 'Pages'); inputs = @{ from = "@variables('Rows')"; select = [ordered]@{
            sourceid = "@concat(coalesce(item()?['properties']?['environmentId'], ''), '|', item()?['name'], '|')"
            name = "@$(Trunc "coalesce(item()?['properties']?['displayName'], item()?['name'])" 400)"
            type = "@item()?['type']"; envid = "@coalesce(item()?['properties']?['environmentId'], '')"; envname = "@item()?['environmentName']"
            envtypeRaw = "@item()?['environmentType']"; envtypeLabel = "@$(JsonLit $sig.environmentTypeBySku)?[coalesce(item()?['environmentType'], '-')]"
            envtype = "@$(JsonLit $envTypeOpt)?[coalesce(item()?['environmentType'], '-')]"
            componentid = "@if(equals(item()?['type'], 'microsoft.powerapps/canvasapps'), item()?['name'], coalesce(item()?['properties']?['appModuleId'], item()?['properties']?['workflowEntityId'], ''))"
            owner = "@item()?['properties']?['ownerId']"; lastmodified = "@item()?['properties']?['lastModifiedAt']"; raw = '@item()'
        } } }
Add-ModelMap $es
$es['List_assets'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assets'; '$select' = 'crdr_assetid,crdr_sourceid,crdr_source'; '$filter' = "crdr_source ne $syntheticSource" }) (After 'Shape') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$assetFields = [ordered]@{
    'item/crdr_name' = "@${it}?['name']"; 'item/crdr_resourcetype' = "@${it}?['type']"; 'item/crdr_environmentid' = "@${it}?['envid']"
    'item/crdr_environmentname' = "@${it}?['envname']"; 'item/crdr_environmenttype' = "@${it}?['envtype']"; 'item/crdr_ownerobjectid' = "@${it}?['owner']"
    'item/crdr_lastmodified' = "@${it}?['lastmodified']"; 'item/crdr_lastseen' = '@utcNow()'; 'item/crdr_componentid' = "@${it}?['componentid']"
}
$cf = "items('Create_fingerprints')"
$es['Upsert'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Shape')"; runAfter = [ordered]@{ List_assets = @('Succeeded'); Model_xml = @('Succeeded') }; runtimeConfiguration = @{ concurrency = @{ repetitions = 10 } }
    actions = [ordered]@{
        Find_asset = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('List_assets')?['value']"; where = "@equals(item()?['crdr_sourceid'], ${it}?['sourceid'])" } }
        Is_new = [ordered]@{ type = 'If'; runAfter = (After 'Find_asset'); expression = @{ equals = @("@empty(body('Find_asset'))", $true) }
            actions = [ordered]@{ Create_asset = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_assets'; 'item/crdr_sourceid' = "@${it}?['sourceid']"; 'item/crdr_source' = $liveSource } + $assetFields) }
            else = @{ actions = [ordered]@{ Update_asset = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_assets'; recordId = "@first(body('Find_asset'))?['crdr_assetid']" } + $assetFields) } } }
        Asset_id = [ordered]@{ type = 'Compose'; runAfter = (After 'Is_new'); inputs = "@coalesce(actions('Create_asset')?['outputs']?['body']?['crdr_assetid'], first(body('Find_asset'))?['crdr_assetid'])" }
        Connector_ids = [ordered]@{ type = 'Select'; runAfter = (After 'Asset_id'); inputs = @{ from = "@$conns"; select = "@item()?['connectorId']" } }
        Connector_facets = [ordered]@{ type = 'Select'; runAfter = (After 'Connector_ids'); inputs = @{ from = "@$conns"; select = [ordered]@{ facet = 'connector'; value = "@item()?['connectorId']"; evidence = "@concat('inventory.properties.powerPlatformConnectors[].connectorId = ''', item()?['connectorId'], '''')" } } }
        Product_facets = [ordered]@{ type = 'Select'; runAfter = (After 'Connector_facets'); inputs = @{ from = "@$productList"; select = [ordered]@{ facet = 'product'; value = '@item()'; evidence = "@if(equals(${raw}?['type'], 'microsoft.copilotstudio/agents'), concat('inventory.type = ''', ${raw}?['type'], ''', createdIn = ''', coalesce(${p}?['createdIn'], ''), ''''), concat('inventory.type = ''', ${raw}?['type'], ''''))" } } }
        All_facets = [ordered]@{ type = 'Compose'; runAfter = (After 'Product_facets'); inputs = "@union(body('Product_facets'), $scalar, body('Connector_facets'))" }
        Desired_names = [ordered]@{ type = 'Select'; runAfter = (After 'All_facets'); inputs = @{ from = "@outputs('All_facets')"; select = "@concat(item()?['facet'], ': ', item()?['value'])" } }
        List_fingerprints = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assetfingerprints'; '$select' = 'crdr_assetfingerprintid,crdr_name,crdr_evidence'; '$filter' = "@concat('_crdr_asset_value eq ', outputs('Asset_id'))" }) (After 'Desired_names')
        Existing_names = [ordered]@{ type = 'Select'; runAfter = (After 'List_fingerprints'); inputs = @{ from = "@body('List_fingerprints')?['value']"; select = "@item()?['crdr_name']" } }
        To_create = [ordered]@{ type = 'Query'; runAfter = (After 'Existing_names'); inputs = @{ from = "@outputs('All_facets')"; where = "@not(contains(body('Existing_names'), concat(item()?['facet'], ': ', item()?['value'])))" } }
        To_delete = [ordered]@{ type = 'Query'; runAfter = (After 'To_create'); inputs = @{ from = "@body('List_fingerprints')?['value']"; where = "@and(not(contains(body('Desired_names'), item()?['crdr_name'])), not(contains($detailFacets, item()?['crdr_name'])), not(startsWith(coalesce(item()?['crdr_evidence'], ''), '$detailPrefix')))" } }
        Create_fingerprints = [ordered]@{ type = 'Foreach'; foreach = "@body('To_create')"; runAfter = (After 'To_delete')
            actions = @{ Create_fingerprint = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'
                        'item/crdr_name' = "@$(Trunc "concat(${cf}?['facet'], ': ', ${cf}?['value'])" 200)"
                        'item/crdr_asset@odata.bind' = "@concat('/crdr_assets(', outputs('Asset_id'), ')')"
                        'item/crdr_facet' = "@$(JsonLit $facetOpt)?[${cf}?['facet']]"
                        'item/crdr_value' = "@${cf}?['value']"
                        'item/crdr_evidence' = "@$(Trunc "${cf}?['evidence']" 1000)" }) } }
        Delete_fingerprints = [ordered]@{ type = 'Foreach'; foreach = "@body('To_delete')"; runAfter = (After 'Create_fingerprints')
            actions = @{ Delete_fingerprint = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; recordId = "@items('Delete_fingerprints')?['crdr_assetfingerprintid']" }) } }
    } }
# A known model replaced by another on an existing asset: asset.modelchanged (live or fixture; never synthetic here).
Add-ModelChangeEvent $es['Upsert'].actions 'Model_change' (After 'Delete_fingerprints') "body('List_fingerprints')?['value']" "outputs('All_facets')" "outputs('Asset_id')" "${it}?['name']" "coalesce(${rtMap}?[${it}?['type']], ${it}?['type'])" "coalesce(${it}?['envname'], '')" "if(equals(first(body('Find_asset'))?['crdr_source'], $fixtureSource), 'fixture', 'live')"
$esActions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = (After 'Init_more'); actions = $es }
$esOk = "equals(actions('Collect')?['status'], 'Succeeded')"
$esActions['Record_run'] = Dv 'CreateRecord' ([ordered]@{
        entityName = 'crdr_collectionruns'
        'item/crdr_name' = "@concat('estate-inventory ', formatDateTime(trigger()?['startTime'], 'yyyy-MM-dd HH:mm'), ': resources ', string(length(variables('Rows'))), if($esOk, concat(', assets written ', string(length(coalesce(actions('Shape')?['outputs']?['body'], json('[]'))))), ', FAILED: assets written not confirmed'))"
        'item/crdr_collector' = 'estate-inventory'; 'item/crdr_accesstier' = $tier.full; 'item/crdr_startedon' = "@trigger()?['startTime']"
        # A failed run must not look like a successful write (observed 2026-11-20): count only when Collect succeeded.
        'item/crdr_itemcount' = "@if($esOk, length(variables('Rows')), 0)"
        'item/crdr_gaps' = "@if($esOk, 'Not collected yet: owner kind (user or service principal), Dataverse detail, Copilot Studio Kit (ADR 0008).', concat('Query_page ', coalesce(actions('Query_page')?['status'], 'not run'), '. ', string(coalesce(outputs('Query_page')?['body']?['error']?['message'], outputs('Query_page')?['body']?['message'], '')), ' Collect scope: ', actions('Collect')?['status']))"
    }) (After 'Collect' $allStates)
$esActions['Fail_if_collect_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Record_run' $allStates)
    expression = @{ not = @{ equals = @("@actions('Collect')?['status']", 'Succeeded') } }
    actions = @{ Terminate = @{ type = 'Terminate'; runAfter = @{}; inputs = @{ runStatus = 'Failed'; runError = @{ code = 'CollectFailed'; message = 'Estate inventory failed: see the Collect scope and the crdr_collectionrun row.' } } } }
    else = @{ actions = @{} } }
$flows['CollectEstate'] = New-Flow 'Change Radar: collect the Power Platform estate from inventory (delegated) into crdr_asset with facets and evidence (ADR 0008).' (Recurrence 'Day' 1 @{ hours = @('4') }) $esActions @{ shared_powerplatformadminv2 = 'crdr_powerplatformadmin' }

# ---------- Dataverse detail (ADR 0008 addendum 2) ----------
# Per environment in crdr_config detail_environments, as the reader app (read-only role):
#   1. labels assets that belong to a solution in fixture_solutions as source = fixture (spec §15.2)
#   2. owns 'capability: pcf_control': maker-built control <- form (60) <- app module (80), or <- canvas app (300)
# Same rules as queries/dataverse-detail.ps1, which Test-EstateParity.ps1 compares against.
$envUrl = "items('Each_env')"
function DvHttp([string]$pathExpr, [hashtable]$runAfter, [switch]$Single) {
    $rc = if ($Single) { @{ secureData = @{ properties = @('inputs') } } } else { @{ secureData = @{ properties = @('inputs') }; paginationPolicy = @{ minimumItemCount = 100000 } } }
    [ordered]@{ type = 'Http'; runAfter = $runAfter
        inputs = [ordered]@{ method = 'GET'; uri = "@{$envUrl}/api/data/v9.2/$pathExpr"; headers = [ordered]@{ Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' }
            authentication = [ordered]@{ type = 'ActiveDirectoryOAuth'; authority = 'https://login.microsoftonline.com'; tenant = "@parameters('Tenant ID (crdr_tenantid)')"; audience = "@{$envUrl}"
                clientId = "@parameters('Reader client ID (crdr_readerclientid)')"; pfx = "@body('Get_certificate')?['EnvironmentVariableSecretValue']"; password = "@string('')" } }
        runtimeConfiguration = $rc }
}
$msPublishers = JsonLit @($sig.pcfMicrosoftPublishers.values)
$pcfName = 'capability: pcf_control'
$dtActions = [ordered]@{}
$dtActions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
Add-ConfigQuery $dtActions 'Config_envs' 'detail_environments'
Add-ConfigQuery $dtActions 'Config_fixtures' 'fixture_solutions'
$dtActions['Init_hits'] = [ordered]@{ type = 'InitializeVariable'; runAfter = [ordered]@{ Config_envs = @('Succeeded'); Config_fixtures = @('Succeeded') }; inputs = @{ variables = @(@{ name = 'Hits'; type = 'array'; value = @() }) } }
$dtActions['Init_log'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_hits'); inputs = @{ variables = @(@{ name = 'Log'; type = 'array'; value = @() }) } }
$dtActions['Init_prompts'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_log'); inputs = @{ variables = @(@{ name = 'Prompts'; type = 'integer'; value = 0 }) } }
# ADR 0017: prompt calls read from flow definitions, the prompts' models, and each caller's desired facets.
$prev = 'Init_prompts'
foreach ($v in 'Calls', 'PromptInfo', 'Desired', 'Seen', 'SolRows', 'SolPairs') {
    $dtActions["Init_$v"] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After $prev); inputs = @{ variables = @(@{ name = $v; type = 'array'; value = @() }) } }
    $prev = "Init_$v"
}
$dt = [ordered]@{}
$dt['Get_certificate'] = Dv 'PerformUnboundAction' ([ordered]@{ actionName = 'RetrieveEnvironmentVariableSecretValue'; 'item/EnvironmentVariableName' = 'crdr_readercertificate' }) @{} @{ runtimeConfiguration = @{ secureData = @{ properties = @('inputs', 'outputs') } } }
$dt['Env_list'] = [ordered]@{ type = 'Query'; runAfter = (After 'Get_certificate'); inputs = @{ from = "@split(coalesce(first(body('Config_envs'))?['crdr_value'], ''), ';')"; where = "@not(empty(trim(item())))" } }
$dt['Fixture_list'] = [ordered]@{ type = 'Query'; runAfter = (After 'Env_list'); inputs = @{ from = "@split(coalesce(first(body('Config_fixtures'))?['crdr_value'], ''), ';')"; where = "@not(empty(trim(item())))" } }
$ev = [ordered]@{}
$ev['Reset_hits'] = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'Hits'; value = @() } }
$ev['Org'] = DvHttp "RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')" (After 'Reset_hits') -Single  # one object, not a page: pagination rejects it (observed 2026-11-20)
$ev['Env_id'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Org'); inputs = "@body('Org')?['Detail']?['EnvironmentId']" }
$ev['Env_assets'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assets'; '$select' = 'crdr_assetid,crdr_name,crdr_componentid,crdr_source,crdr_solutionuniquename,crdr_sourceid,crdr_environmentname,crdr_environmenttype'
        '$filter' = "@concat('crdr_environmentid eq ''', outputs('Env_id'), ''' and crdr_source ne $syntheticSource')" }) (After 'Env_id') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
# 1. Fixture membership (flows 29, model-driven apps 80, canvas apps 300)
$ev['Fixture_components'] = DvHttp "solutioncomponents?`$select=objectid,componenttype&`$expand=solutionid(`$select=uniquename)&`$filter=(componenttype eq 29 or componenttype eq 80 or componenttype eq 300) and (@{join(body('Fixture_filter'), ' or ')})" (After 'Fixture_filter')
$ev['Fixture_filter'] = [ordered]@{ type = 'Select'; runAfter = (After 'Env_assets'); inputs = @{ from = "@if(empty(body('Fixture_list')), createArray('-'), body('Fixture_list'))"; select = "@concat('solutionid/uniquename eq ''', trim(item()), '''')" } }
$ev['Fixture_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Fixture_components'); inputs = @{ from = "@body('Fixture_components')?['value']"; select = "@item()?['objectid']" } }
$ev['To_relabel'] = [ordered]@{ type = 'Query'; runAfter = (After 'Fixture_ids'); inputs = @{ from = "@body('Env_assets')?['value']"; where = "@and(contains(body('Fixture_ids'), item()?['crdr_componentid']), not(equals(item()?['crdr_source'], $fixtureSource)))" } }
$ev['Relabel'] = [ordered]@{ type = 'Foreach'; foreach = "@body('To_relabel')"; runAfter = (After 'To_relabel')
    actions = [ordered]@{
        Membership = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Fixture_components')?['value']"; where = "@equals(item()?['objectid'], items('Relabel')?['crdr_componentid'])" } }
        Relabel_asset = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_assets'; recordId = "@items('Relabel')?['crdr_assetid']"; 'item/crdr_source' = $fixtureSource
                'item/crdr_solutionuniquename' = "@first(body('Membership'))?['solutionid']?['uniquename']"; 'item/crdr_syntheticorg' = 'Change Radar fixtures (FIXTURE: test assets, not real)' }) (After 'Membership') } }
# 2. Maker-built code components and the apps that use them
$ev['Controls'] = DvHttp 'customcontrols?$select=customcontrolid,name' (After 'Relabel')
$ev['Owners'] = DvHttp 'solutioncomponents?$select=objectid&$filter=componenttype eq 66&$expand=solutionid($select=uniquename;$expand=publisherid($select=uniquename))' (After 'Controls')
$ev['Shipped'] = [ordered]@{ type = 'Query'; runAfter = (After 'Owners'); inputs = @{ from = "@body('Owners')?['value']"; where = "@contains($msPublishers, item()?['solutionid']?['publisherid']?['uniquename'])" } }
$ev['Shipped_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Shipped'); inputs = @{ from = "@body('Shipped')"; select = "@item()?['objectid']" } }
$ev['Maker_owned'] = [ordered]@{ type = 'Query'; runAfter = (After 'Shipped_ids'); inputs = @{ from = "@body('Owners')?['value']"; where = "@and(not(contains($msPublishers, item()?['solutionid']?['publisherid']?['uniquename'])), not(contains(createArray('Default', 'Active'), item()?['solutionid']?['uniquename'])))" } }
$ev['Maker_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Maker_owned'); inputs = @{ from = "@body('Maker_owned')"; select = "@item()?['objectid']" } }
$ev['Maker'] = [ordered]@{ type = 'Query'; runAfter = (After 'Maker_ids'); inputs = @{ from = "@body('Controls')?['value']"; where = "@and(contains(body('Maker_ids'), item()?['customcontrolid']), not(contains(body('Shipped_ids'), item()?['customcontrolid'])))" } }
$ctl = "items('Each_control')"
$ec = [ordered]@{}
$ec['Deps'] = DvHttp "dependencies?`$select=dependentcomponenttype,dependentcomponentobjectid&`$filter=requiredcomponentobjectid eq @{${ctl}?['customcontrolid']}" @{}
$ec['Canvas_deps'] = [ordered]@{ type = 'Query'; runAfter = (After 'Deps'); inputs = @{ from = "@body('Deps')?['value']"; where = "@equals(item()?['dependentcomponenttype'], 300)" } }
$ec['Canvas_hits'] = [ordered]@{ type = 'Select'; runAfter = (After 'Canvas_deps'); inputs = @{ from = "@body('Canvas_deps')"; select = [ordered]@{ componentid = "@item()?['dependentcomponentobjectid']"; control = "@${ctl}?['name']"; path = "@concat('canvas app ', item()?['dependentcomponentobjectid'])" } } }
$ec['Hits_with_canvas'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Canvas_hits'); inputs = "@union(variables('Hits'), body('Canvas_hits'))" }
$ec['Add_canvas_hits'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Hits_with_canvas'); inputs = @{ name = 'Hits'; value = "@outputs('Hits_with_canvas')" } }
$ec['Form_deps'] = [ordered]@{ type = 'Query'; runAfter = (After 'Add_canvas_hits'); inputs = @{ from = "@body('Deps')?['value']"; where = "@equals(item()?['dependentcomponenttype'], 60)" } }
$frm = "items('Each_form')"
$ec['Each_form'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Form_deps')"; runAfter = (After 'Form_deps'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
    actions = [ordered]@{
        App_deps = DvHttp "dependencies?`$select=dependentcomponentobjectid&`$filter=requiredcomponentobjectid eq @{${frm}?['dependentcomponentobjectid']} and dependentcomponenttype eq 80" @{}
        App_hits = [ordered]@{ type = 'Select'; runAfter = (After 'App_deps'); inputs = @{ from = "@body('App_deps')?['value']"; select = [ordered]@{ componentid = "@item()?['dependentcomponentobjectid']"; control = "@${ctl}?['name']"; path = "@concat('form ', ${frm}?['dependentcomponentobjectid'], ' -> app module ', item()?['dependentcomponentobjectid'])" } } }
        Hits_with_app = [ordered]@{ type = 'Compose'; runAfter = (After 'App_hits'); inputs = "@union(variables('Hits'), body('App_hits'))" }
        Add_app_hits = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Hits_with_app'); inputs = @{ name = 'Hits'; value = "@outputs('Hits_with_app')" } }
    } }
$ev['Each_control'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Maker')"; runAfter = (After 'Maker'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ec }
# 3. Reconcile 'capability: pcf_control' for this environment's assets
$ev['Existing_pcf'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assetfingerprints'; '$select' = 'crdr_assetfingerprintid,_crdr_asset_value,crdr_evidence'
        '$filter' = "@concat('crdr_name eq ''$pcfName'' and crdr_asset/crdr_environmentid eq ''', outputs('Env_id'), '''')" }) (After 'Each_control') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$ast = "items('Each_asset')"
$ea = [ordered]@{}
$ea['Asset_hits'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@variables('Hits')"; where = "@and(not(empty(${ast}?['crdr_componentid'])), equals(item()?['componentid'], ${ast}?['crdr_componentid']))" } }
$ea['Asset_existing'] = [ordered]@{ type = 'Query'; runAfter = (After 'Asset_hits'); inputs = @{ from = "@body('Existing_pcf')?['value']"; where = "@equals(item()?['_crdr_asset_value'], ${ast}?['crdr_assetid'])" } }
$ea['Evidence_parts'] = [ordered]@{ type = 'Select'; runAfter = (After 'Asset_existing'); inputs = @{ from = "@body('Asset_hits')"; select = "@concat('dependency: control ''', item()?['control'], ''' <- ', item()?['path'])" } }
$ea['Evidence'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Evidence_parts'); inputs = "@$(Trunc "join(body('Evidence_parts'), '; ')" 1000)" }
$ea['Has_pcf'] = [ordered]@{ type = 'If'; runAfter = (After 'Evidence'); expression = @{ not = @{ equals = @("@empty(body('Asset_hits'))", $true) } }
    actions = [ordered]@{
        Pcf_exists = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ equals = @("@empty(body('Asset_existing'))", $true) }
            actions = [ordered]@{ Create_pcf = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; 'item/crdr_name' = $pcfName
                        'item/crdr_asset@odata.bind' = "@concat('/crdr_assets(', ${ast}?['crdr_assetid'], ')')"; 'item/crdr_facet' = $facetOpt['capability']
                        'item/crdr_value' = 'pcf_control'; 'item/crdr_evidence' = "@outputs('Evidence')" }) }
            else = @{ actions = [ordered]@{ Update_pcf = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; recordId = "@first(body('Asset_existing'))?['crdr_assetfingerprintid']"; 'item/crdr_evidence' = "@outputs('Evidence')" }) } } } }
    else = @{ actions = [ordered]@{
            Remove_pcf = [ordered]@{ type = 'Foreach'; foreach = "@body('Asset_existing')"; runAfter = @{}
                actions = @{ Delete_pcf = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; recordId = "@items('Remove_pcf')?['crdr_assetfingerprintid']" }) } } } } }
$ev['Each_asset'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Env_assets')?['value']"; runAfter = (After 'Existing_pcf'); runtimeConfiguration = @{ concurrency = @{ repetitions = 10 } }; actions = $ea }
$ev['Log_detail'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Each_asset'); inputs = @{ name = 'Log'; value = "@concat(outputs('Env_id'), ': maker-built controls ', string(length(body('Maker'))), ', app dependencies ', string(length(variables('Hits'))), ', fixtures relabelled ', string(length(body('To_relabel'))))" } }
# 4. Prompts (ADR 0013; engine Get-PromptModelType, queries/dataverse-detail.ps1): an active msdyn_aimodel whose active
# run configuration names modelParameters.modelType. The value is read as text (the stored JSON isn't always valid):
# after the first "modelType" key, only a colon and spaces, then the quoted string. Live assets of Change Radar's own
# type microsoft.aibuilder/prompts, written and reconciled here only; the estate flow never sees them.
$promptType = 'microsoft.aibuilder/prompts'
$envLabelMap = [ordered]@{}; foreach ($v in $schema.choices.environmenttype) { $envLabelMap["$(Get-Opt 'environmenttype' $v)"] = $v }
$envLabel = JsonLit $envLabelMap
$promptStatic = @(@($sig.productByType.$promptType) | ForEach-Object { [ordered]@{ facet = 'product'; value = $_; evidence = "inventory.type = '$promptType'" } }) + @([ordered]@{ facet = 'resource_type'; value = $sig.resourceTypeByType.$promptType; evidence = "inventory.type = '$promptType'" })
$promptStaticJson = (ConvertTo-Json -Compress -Depth 5 @($promptStatic)).Replace("'", "''")
$ev['Run_configs'] = DvHttp 'msdyn_aiconfigurations?$select=msdyn_aiconfigurationid,msdyn_customconfiguration&$filter=msdyn_type eq 190690001' (After 'Log_detail')
$ev['Prompt_models'] = DvHttp 'msdyn_aimodels?$select=msdyn_aimodelid,msdyn_name,ismanaged,_ownerid_value,modifiedon,_msdyn_activerunconfigurationid_value&$filter=statecode eq 1 and _msdyn_activerunconfigurationid_value ne null' (After 'Run_configs')
$ev['Ms_prompt_rows'] = DvHttp 'solutioncomponents?$select=objectid&$filter=componenttype eq 401&$expand=solutionid($select=uniquename;$expand=publisherid($select=uniquename))' (After 'Prompt_models')
$ev['Ms_prompts'] = [ordered]@{ type = 'Query'; runAfter = (After 'Ms_prompt_rows'); inputs = @{ from = "@body('Ms_prompt_rows')?['value']"; where = "@contains($msPublishers, item()?['solutionid']?['publisherid']?['uniquename'])" } }
$ev['Ms_prompt_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Ms_prompts'); inputs = @{ from = "@body('Ms_prompts')"; select = "@item()?['objectid']" } }
$ev['Env_row'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Ms_prompt_ids'); inputs = "@first(body('Env_assets')?['value'])" }
# 4a. Prompt calls (ADR 0017; engine Get-PromptCalls, tests/models/models.json promptCalls): flow definitions that
# contain an AI Builder action, read as text. Only the operation, the prompt id and the flow are kept; the definition
# itself is never stored. A recordId that is an expression is a prompt chosen at run time: no id.
$q = '"'   # one double quote, interpolated as is
$opKey = '"operationId":"aibuilderpredict_'; $anyOp = '"operationId":"'; $ridKey = '"recordId":"'
$seg = "first(split(item(), '$anyOp'))"
$rid = "first(split(coalesce(split($seg, '$ridKey')?[1], ''), '$q'))"
$ev['Workflows'] = DvHttp "workflows?`$select=workflowid,name,clientdata&`$filter=type eq 1 and contains(clientdata,'aibuilderpredict_')" (After 'Env_row')
$ev['Reset_calls'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Workflows'); inputs = @{ name = 'Calls'; value = @() } }
$wf = "items('Each_flow')"
$ef = [ordered]@{}
$ef['Flow_calls'] = [ordered]@{ type = 'Select'; runAfter = @{}; inputs = @{ from = "@skip(split(coalesce(${wf}?['clientdata'], ''), '$opKey'), 1)"; select = [ordered]@{
            wf = "@toLower(${wf}?['workflowid'])"; name = "@${wf}?['name']"; op = "@first(split(item(), '$q'))"
            id = "@if(and(not(startsWith($rid, '@')), equals(length($rid), 36), equals(length(split($rid, '-')), 5)), toLower($rid), '')" } } }
$ef['Calls_now'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Flow_calls'); inputs = "@union(variables('Calls'), body('Flow_calls'))" }
$ef['Set_calls'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Calls_now'); inputs = @{ name = 'Calls'; value = "@outputs('Calls_now')" } }
$ev['Each_flow'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Workflows')?['value']"; runAfter = (After 'Reset_calls'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ef }
$ev['Reset_prompt_info'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Each_flow'); inputs = @{ name = 'PromptInfo'; value = @() } }
$pm = "items('Each_prompt')"
$q = '"'   # one double quote, interpolated as is
$ep = [ordered]@{}
$ep['Config'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Run_configs')?['value']"; where = "@equals(item()?['msdyn_aiconfigurationid'], ${pm}?['_msdyn_activerunconfigurationid_value'])" } }
$ep['After_key'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Config'); inputs = "@join(skip(split(coalesce(first(body('Config'))?['msdyn_customconfiguration'], ''), '${q}modelType${q}'), 1), '${q}modelType${q}')" }
$ep['Key_parts'] = [ordered]@{ type = 'Compose'; runAfter = (After 'After_key'); inputs = "@split(outputs('After_key'), '$q')" }
# Engine regex "modelType"\s*:\s*"([^"]*)": before the first quote only one colon and spaces; the value is the next part.
$ep['Model_type'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Key_parts')
    inputs = "@if(and(greater(length(outputs('Key_parts')), 2), equals(trim(replace(first(outputs('Key_parts')), ':', '')), ''), equals(length(split(first(outputs('Key_parts')), ':')), 2)), outputs('Key_parts')[1], '')" }
$ep['Model_id'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Model_type'); inputs = "@$(ModelLookup "outputs('Model_type')")" }
$envFacet = "if(empty(outputs('Prompt_env_type')), json('[]'), createArray(addProperty(addProperty(json('{${q}facet${q}:${q}environment_type${q}}'), 'value', outputs('Prompt_env_type')), 'evidence', 'environment of the Dataverse detail run')))"
$modelFacet = "if(empty(outputs('Model_id')), json('[]'), createArray(addProperty(addProperty(json('{${q}facet${q}:${q}model${q}}'), 'value', outputs('Model_id')), 'evidence', concat('inventory.properties.model = ''', outputs('Model_type'), ''' (active run configuration modelParameters.modelType)'))))"
$cpf = "items('Create_prompt_fps')"
$ep['Is_prompt'] = [ordered]@{ type = 'If'; runAfter = (After 'Model_id'); expression = @{ not = @{ equals = @("@outputs('Model_type')", '') } }
    actions = [ordered]@{
        Prompt_sourceid = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@concat(outputs('Env_id'), '|', ${pm}?['msdyn_aimodelid'], '|')" }
        Prompt_found = [ordered]@{ type = 'Query'; runAfter = (After 'Prompt_sourceid'); inputs = @{ from = "@body('Env_assets')?['value']"; where = "@equals(item()?['crdr_sourceid'], outputs('Prompt_sourceid'))" } }
        Prompt_new = [ordered]@{ type = 'If'; runAfter = (After 'Prompt_found'); expression = @{ equals = @("@empty(body('Prompt_found'))", $true) }
            actions = [ordered]@{ Create_prompt = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_assets'; 'item/crdr_sourceid' = "@outputs('Prompt_sourceid')"; 'item/crdr_source' = $liveSource
                    'item/crdr_name' = "@$(Trunc "coalesce(${pm}?['msdyn_name'], ${pm}?['msdyn_aimodelid'])" 400)"; 'item/crdr_resourcetype' = $promptType; 'item/crdr_environmentid' = "@outputs('Env_id')"
                    'item/crdr_environmentname' = "@outputs('Env_row')?['crdr_environmentname']"; 'item/crdr_environmenttype' = "@outputs('Env_row')?['crdr_environmenttype']"
                    'item/crdr_ownerobjectid' = "@${pm}?['_ownerid_value']"; 'item/crdr_lastmodified' = "@${pm}?['modifiedon']"; 'item/crdr_lastseen' = '@utcNow()'; 'item/crdr_componentid' = "@${pm}?['msdyn_aimodelid']"; 'item/crdr_microsoftsystem' = "@contains(body('Ms_prompt_ids'), ${pm}?['msdyn_aimodelid'])" }) }
            else = @{ actions = [ordered]@{ Update_prompt = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_assets'; recordId = "@first(body('Prompt_found'))?['crdr_assetid']"
                        'item/crdr_name' = "@$(Trunc "coalesce(${pm}?['msdyn_name'], ${pm}?['msdyn_aimodelid'])" 400)"; 'item/crdr_lastmodified' = "@${pm}?['modifiedon']"; 'item/crdr_lastseen' = '@utcNow()'; 'item/crdr_microsoftsystem' = "@contains(body('Ms_prompt_ids'), ${pm}?['msdyn_aimodelid'])" }) } } }
        Prompt_id = [ordered]@{ type = 'Compose'; runAfter = (After 'Prompt_new'); inputs = "@coalesce(actions('Create_prompt')?['outputs']?['body']?['crdr_assetid'], first(body('Prompt_found'))?['crdr_assetid'])" }
        Prompt_env_type = [ordered]@{ type = 'Compose'; runAfter = (After 'Prompt_id'); inputs = "@${envLabel}?[string(coalesce(outputs('Env_row')?['crdr_environmenttype'], ''))]" }
        Prompt_facets = [ordered]@{ type = 'Compose'; runAfter = (After 'Prompt_env_type'); inputs = "@union(json('$promptStaticJson'), $envFacet, $modelFacet)" }
        Prompt_names = [ordered]@{ type = 'Select'; runAfter = (After 'Prompt_facets'); inputs = @{ from = "@outputs('Prompt_facets')"; select = "@concat(item()?['facet'], ': ', item()?['value'])" } }
        Prompt_fps = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assetfingerprints'; '$select' = 'crdr_assetfingerprintid,crdr_name'; '$filter' = "@concat('_crdr_asset_value eq ', outputs('Prompt_id'))" }) (After 'Prompt_names')
        Prompt_existing = [ordered]@{ type = 'Select'; runAfter = (After 'Prompt_fps'); inputs = @{ from = "@body('Prompt_fps')?['value']"; select = "@item()?['crdr_name']" } }
        Prompt_create = [ordered]@{ type = 'Query'; runAfter = (After 'Prompt_existing'); inputs = @{ from = "@outputs('Prompt_facets')"; where = "@not(contains(body('Prompt_existing'), concat(item()?['facet'], ': ', item()?['value'])))" } }
        Prompt_delete = [ordered]@{ type = 'Query'; runAfter = (After 'Prompt_create'); inputs = @{ from = "@body('Prompt_fps')?['value']"; where = "@not(contains(body('Prompt_names'), item()?['crdr_name']))" } }
        Create_prompt_fps = [ordered]@{ type = 'Foreach'; foreach = "@body('Prompt_create')"; runAfter = (After 'Prompt_delete')
            actions = @{ Create_prompt_fp = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'
                        'item/crdr_name' = "@$(Trunc "concat(${cpf}?['facet'], ': ', ${cpf}?['value'])" 200)"
                        'item/crdr_asset@odata.bind' = "@concat('/crdr_assets(', outputs('Prompt_id'), ')')"
                        'item/crdr_facet' = "@$(JsonLit $facetOpt)?[${cpf}?['facet']]"
                        'item/crdr_value' = "@${cpf}?['value']"; 'item/crdr_evidence' = "@$(Trunc "${cpf}?['evidence']" 1000)" }) } }
        Delete_prompt_fps = [ordered]@{ type = 'Foreach'; foreach = "@body('Prompt_delete')"; runAfter = (After 'Create_prompt_fps')
            actions = @{ Delete_prompt_fp = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; recordId = "@items('Delete_prompt_fps')?['crdr_assetfingerprintid']" }) } }
        Count_prompt = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Delete_prompt_fps'); inputs = @{ name = 'Prompts'; value = 1 } }
        Note_prompt = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Count_prompt'); inputs = @{ name = 'PromptInfo'; value = [ordered]@{ id = "@toLower(${pm}?['msdyn_aimodelid'])"; name = "@coalesce(${pm}?['msdyn_name'], ${pm}?['msdyn_aimodelid'])"; modelType = "@outputs('Model_type')"; model = "@outputs('Model_id')" } } }
        Caller_rows = [ordered]@{ type = 'Query'; runAfter = (After 'Note_prompt'); inputs = @{ from = "@variables('Calls')"; where = "@equals(item()?['id'], toLower(${pm}?['msdyn_aimodelid']))" } }
        Caller_flow_names = [ordered]@{ type = 'Select'; runAfter = (After 'Caller_rows'); inputs = @{ from = "@body('Caller_rows')"; select = "@item()?['name']" } }
        Gap_model = [ordered]@{ type = 'If'; runAfter = (After 'Caller_flow_names'); expression = @{ equals = @("@empty(outputs('Model_id'))", $true) }
            actions = @{ Log_gap = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'Log'; value = "@concat('unmapped model ''', outputs('Model_type'), ''' on prompt ', ${pm}?['msdyn_aimodelid'])" } } }
            else = @{ actions = @{} } }
    }
    else = @{ actions = @{} } }
# A prompt whose active run configuration moved to another known model: asset.modelchanged; fixture when its asset is labelled fixture.
# ADR 0017: the card names the flows that call the prompt (distinct names; the handler sorts them).
Add-ModelChangeEvent $ep['Is_prompt'].actions 'Model_change' (After 'Gap_model') "body('Prompt_fps')?['value']" "outputs('Prompt_facets')" "outputs('Prompt_id')" "coalesce(${pm}?['msdyn_name'], ${pm}?['msdyn_aimodelid'])" "'prompt'" "coalesce(outputs('Env_row')?['crdr_environmentname'], '')" "if(equals(first(body('Prompt_found'))?['crdr_source'], $fixtureSource), 'fixture', 'live')" "union(body('Caller_flow_names'), body('Caller_flow_names'))"
$ev['Reset_prompts'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Reset_prompt_info'); inputs = @{ name = 'Prompts'; value = 0 } }
$ev['Each_prompt'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Prompt_models')?['value']"; runAfter = (After 'Reset_prompts'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ep }
$ev['Log_prompts'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Each_prompt'); inputs = @{ name = 'Log'; value = "@concat(outputs('Env_id'), ': prompts ', string(variables('Prompts')))" } }
# 4b. Callers (ADR 0017; engine Get-AssetFingerprints): each flow asset in this environment that calls a prompt gets
# 'capability: ai_prompt' and, per model, 'model: <id>' from the first prompt it calls (definition order) whose model
# is known. Evidence starts 'flow definition: ', which is how the estate flow knows to leave these rows alone.
$pfx = $sig.detailFacets.evidencePrefix
$ev['Existing_callers'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assetfingerprints'; '$select' = 'crdr_assetfingerprintid,_crdr_asset_value,crdr_name,crdr_evidence'
        '$filter' = "@concat('startswith(crdr_evidence,''$pfx'') and crdr_asset/crdr_environmentid eq ''', outputs('Env_id'), '''')" }) (After 'Log_prompts') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$ev['Call_flow_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Existing_callers'); inputs = @{ from = "@variables('Calls')"; select = "@item()?['wf']" } }
$ev['Caller_assets'] = [ordered]@{ type = 'Query'; runAfter = (After 'Call_flow_ids'); inputs = @{ from = "@body('Env_assets')?['value']"; where = "@and(not(empty(item()?['crdr_componentid'])), contains(body('Call_flow_ids'), toLower(coalesce(item()?['crdr_componentid'], ''))))" } }
$ca = "items('Each_caller')"
$ec2 = [ordered]@{}
$ec2['Reset_desired'] = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'Desired'; value = @() } }
$ec2['Reset_seen'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Reset_desired'); inputs = @{ name = 'Seen'; value = @() } }
$ec2['My_calls'] = [ordered]@{ type = 'Query'; runAfter = (After 'Reset_seen'); inputs = @{ from = "@variables('Calls')"; where = "@equals(item()?['wf'], toLower(${ca}?['crdr_componentid']))" } }
$ec2['My_ops'] = [ordered]@{ type = 'Select'; runAfter = (After 'My_calls'); inputs = @{ from = "@body('My_calls')"; select = "@concat('aibuilderpredict_', item()?['op'])" } }
$ec2['Want_ai'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'My_ops'); inputs = @{ name = 'Desired'; value = [ordered]@{ facet = 'capability'; value = 'ai_prompt'; evidence = "@concat('$pfx', join(union(body('My_ops'), body('My_ops')), ', '))" } } }
$cl = "items('Each_call')"
$info = "first(body('Call_info'))"
$ecl = [ordered]@{}
$ecl['Call_info'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@variables('PromptInfo')"; where = "@and(not(empty(${cl}?['id'])), equals(item()?['id'], ${cl}?['id']))" } }
$ecl['If_new_model'] = [ordered]@{ type = 'If'; runAfter = (After 'Call_info')
    expression = @{ and = @(@{ equals = @("@empty(body('Call_info'))", $false) }, @{ equals = @("@empty(coalesce(${info}?['model'], ''))", $false) }, @{ equals = @("@contains(variables('Seen'), coalesce(${info}?['model'], ''))", $false) }) }
    actions = [ordered]@{
        Mark_seen = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'Seen'; value = "@${info}?['model']" } }
        Want_model = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Mark_seen'); inputs = @{ name = 'Desired'; value = [ordered]@{ facet = 'model'; value = "@${info}?['model']"; evidence = "@concat('${pfx}calls prompt ''', ${info}?['name'], ''' on ', ${info}?['modelType'])" } } } }
    else = @{ actions = @{} } }
$ec2['Each_call'] = [ordered]@{ type = 'Foreach'; foreach = "@body('My_calls')"; runAfter = (After 'Want_ai'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ecl }
$ec2['Desired_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Each_call'); inputs = @{ from = "@variables('Desired')"; select = "@concat(item()?['facet'], ': ', item()?['value'])" } }
$ec2['Mine'] = [ordered]@{ type = 'Query'; runAfter = (After 'Desired_names'); inputs = @{ from = "@body('Existing_callers')?['value']"; where = "@equals(item()?['_crdr_asset_value'], ${ca}?['crdr_assetid'])" } }
$dz = "items('Each_desired')"
$ed = [ordered]@{}
$ed['Same'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Mine')"; where = "@equals(item()?['crdr_name'], concat(${dz}?['facet'], ': ', ${dz}?['value']))" } }
$ed['If_missing'] = [ordered]@{ type = 'If'; runAfter = (After 'Same'); expression = @{ equals = @("@empty(body('Same'))", $true) }
    actions = [ordered]@{ Create_caller_fp = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; 'item/crdr_name' = "@$(Trunc "concat(${dz}?['facet'], ': ', ${dz}?['value'])" 200)"
                'item/crdr_asset@odata.bind' = "@concat('/crdr_assets(', ${ca}?['crdr_assetid'], ')')"; 'item/crdr_facet' = "@$(JsonLit $facetOpt)?[${dz}?['facet']]"
                'item/crdr_value' = "@${dz}?['value']"; 'item/crdr_evidence' = "@$(Trunc "${dz}?['evidence']" 1000)" }) }
    else = @{ actions = [ordered]@{ If_evidence_changed = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ not = @{ equals = @("@first(body('Same'))?['crdr_evidence']", "@$(Trunc "${dz}?['evidence']" 1000)") } }
                actions = [ordered]@{ Update_caller_fp = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; recordId = "@first(body('Same'))?['crdr_assetfingerprintid']"; 'item/crdr_evidence' = "@$(Trunc "${dz}?['evidence']" 1000)" }) }
                else = @{ actions = @{} } } } } }
$ec2['Each_desired'] = [ordered]@{ type = 'Foreach'; foreach = "@variables('Desired')"; runAfter = (After 'Mine'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ed }
$ec2['Not_wanted'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_desired'); inputs = @{ from = "@body('Mine')"; where = "@not(contains(body('Desired_names'), item()?['crdr_name']))" } }
$ec2['Remove_unwanted'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Not_wanted')"; runAfter = (After 'Not_wanted')
    actions = @{ Delete_unwanted = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; recordId = "@items('Remove_unwanted')?['crdr_assetfingerprintid']" }) } }
$ev['Each_caller'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Caller_assets')"; runAfter = (After 'Caller_assets'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ec2 }
# A flow that no longer calls a prompt (or is no longer an asset here) loses its caller facets.
$ev['Caller_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Each_caller'); inputs = @{ from = "@body('Caller_assets')"; select = "@item()?['crdr_assetid']" } }
$ev['Stale_callers'] = [ordered]@{ type = 'Query'; runAfter = (After 'Caller_ids'); inputs = @{ from = "@body('Existing_callers')?['value']"; where = "@not(contains(body('Caller_ids'), item()?['_crdr_asset_value']))" } }
$ev['Remove_stale'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Stale_callers')"; runAfter = (After 'Stale_callers')
    actions = @{ Delete_stale = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_assetfingerprints'; recordId = "@items('Remove_stale')?['crdr_assetfingerprintid']" }) } }
$ev['Log_callers'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Remove_stale'); inputs = @{ name = 'Log'; value = "@concat(outputs('Env_id'), ': flows calling prompts ', string(length(body('Caller_assets'))), ' (prompt actions ', string(length(variables('Calls'))), ')')" } }
# 5. Solutions (ADR 0020; engine ChangeRadar.Solutions.psm1, tests/solutions/solutions.json). Each asset's object id is its
# component id, or for agents the resource id in its source id. Its solution components are read in chunks of 25 ids;
# Default, Active and the Common Data Services Default Solution (display name, or a Cr-hex unique name with a Cr-hex
# publisher) are not counted. Solutions and memberships are created when missing and deleted when they no longer hold.
function HexStrip([string]$e) { foreach ($ch in '0123456789abcdef'.ToCharArray()) { $e = "replace($e, '$ch', '')" }; $e }
$solU = "coalesce(item()?['u'], '')"; $solP = "coalesce(item()?['p'], '')"
$cdsDefault = "and(startsWith($solU, 'Cr'), startsWith($solP, 'Cr'), greaterOrEquals(length($solU), 6), greaterOrEquals(length($solP), 6), empty($(HexStrip "replace($solU, 'Cr', '')")), empty($(HexStrip "replace($solP, 'Cr', '')")))"
$ev['Reset_sol_rows'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Log_callers'); inputs = @{ name = 'SolRows'; value = @() } }
$ev['Reset_sol_pairs'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Reset_sol_rows'); inputs = @{ name = 'SolPairs'; value = @() } }
$ev['Sol_oids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Reset_sol_pairs'); inputs = @{ from = "@body('Env_assets')?['value']"; select = [ordered]@{
            aid = "@item()?['crdr_assetid']"; name = "@item()?['crdr_name']"; src = "@item()?['crdr_source']"
            oid = "@toLower(if(empty(coalesce(item()?['crdr_componentid'], '')), coalesce(split(coalesce(item()?['crdr_sourceid'], ''), '|')?[1], ''), item()?['crdr_componentid']))" } } }
$ev['Sol_known'] = [ordered]@{ type = 'Query'; runAfter = (After 'Sol_oids'); inputs = @{ from = "@body('Sol_oids')"; where = "@not(empty(trim(item()?['oid'])))" } }
$ev['Sol_oid_list'] = [ordered]@{ type = 'Select'; runAfter = (After 'Sol_known'); inputs = @{ from = "@body('Sol_known')"; select = "@item()?['oid']" } }
$ev['Sol_chunks'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Sol_oid_list'); inputs = "@chunk(body('Sol_oid_list'), 25)" }
$esc = [ordered]@{}
$esc['Sol_filter'] = [ordered]@{ type = 'Select'; runAfter = @{}; inputs = @{ from = "@items('Each_sol_chunk')"; select = "@concat('objectid eq ', item())" } }
$esc['Sol_components'] = DvHttp "solutioncomponents?`$select=objectid&`$expand=solutionid(`$select=uniquename,friendlyname,ismanaged;`$expand=publisherid(`$select=uniquename))&`$filter=@{join(body('Sol_filter'), ' or ')}" (After 'Sol_filter')
$esc['Sol_chunk_rows'] = [ordered]@{ type = 'Select'; runAfter = (After 'Sol_components'); inputs = @{ from = "@body('Sol_components')?['value']"; select = [ordered]@{
            oid = "@toLower(item()?['objectid'])"; u = "@item()?['solutionid']?['uniquename']"; f = "@item()?['solutionid']?['friendlyname']"
            m = "@item()?['solutionid']?['ismanaged']"; p = "@item()?['solutionid']?['publisherid']?['uniquename']" } } }
$esc['Sol_rows_now'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Sol_chunk_rows'); inputs = "@union(variables('SolRows'), body('Sol_chunk_rows'))" }
$esc['Set_sol_rows'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Sol_rows_now'); inputs = @{ name = 'SolRows'; value = "@outputs('Sol_rows_now')" } }
$ev['Each_sol_chunk'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Sol_chunks')"; runAfter = (After 'Sol_chunks'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $esc }
$ev['Sol_counted'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_sol_chunk'); inputs = @{ from = "@variables('SolRows')"
        where = "@and(not(contains(createArray('Default', 'Active'), $solU)), not(equals(coalesce(item()?['f'], ''), 'Common Data Services Default Solution')), not($cdsDefault))" } }
$ev['Sol_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Sol_counted'); inputs = @{ from = "@body('Sol_counted')"; select = "@item()?['u']" } }
$ev['Sol_distinct'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Sol_names'); inputs = "@union(body('Sol_names'), body('Sol_names'))" }
$envFilter = "@concat('crdr_environmentid eq ''', outputs('Env_id'), '''')"
$ev['Existing_solutions'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_solutions'; '$select' = 'crdr_solutionid,crdr_uniquename'; '$filter' = $envFilter }) (After 'Sol_distinct')
$ens = [ordered]@{}
$ens['Sol_exists'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Existing_solutions')?['value']"; where = "@equals(item()?['crdr_uniquename'], items('Each_new_solution'))" } }
$ens['Sol_first'] = [ordered]@{ type = 'Query'; runAfter = (After 'Sol_exists'); inputs = @{ from = "@body('Sol_counted')"; where = "@equals(item()?['u'], items('Each_new_solution'))" } }
$ens['If_new_solution'] = [ordered]@{ type = 'If'; runAfter = (After 'Sol_first'); expression = @{ equals = @("@empty(body('Sol_exists'))", $true) }
    actions = [ordered]@{ Create_solution = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_solutions'
            'item/crdr_name' = "@$(Trunc "coalesce(first(body('Sol_first'))?['f'], items('Each_new_solution'))" 200)"; 'item/crdr_uniquename' = "@items('Each_new_solution')"
            'item/crdr_environmentid' = "@outputs('Env_id')"; 'item/crdr_environmentname' = "@outputs('Env_row')?['crdr_environmentname']"
            'item/crdr_publisher' = "@first(body('Sol_first'))?['p']"; 'item/crdr_managed' = "@equals(first(body('Sol_first'))?['m'], true)"
            'item/crdr_microsoft' = "@contains($msPublishers, coalesce(first(body('Sol_first'))?['p'], ''))"; 'item/crdr_source' = $liveSource }) }
    else = @{ actions = @{} } }
$ev['Each_new_solution'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Sol_distinct')"; runAfter = (After 'Existing_solutions'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ens }
$ev['Solutions_now'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_solutions'; '$select' = 'crdr_solutionid,crdr_uniquename'; '$filter' = $envFilter }) (After 'Each_new_solution')
$ev['Existing_members'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_solutionmembers'; '$select' = 'crdr_solutionmemberid,_crdr_asset_value,_crdr_solution_value'
        '$filter' = "@concat('crdr_solution/crdr_environmentid eq ''', outputs('Env_id'), '''')" }) (After 'Solutions_now') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$sa = "items('Each_sol_asset')"; $sm = "items('Each_sol_mine')"
$esm = [ordered]@{}
$esm['Sol_target'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Solutions_now')?['value']"; where = "@equals(item()?['crdr_uniquename'], ${sm}?['u'])" } }
$esm['Sol_target_id'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Sol_target'); inputs = "@first(body('Sol_target'))?['crdr_solutionid']" }
$esm['Note_pair'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Sol_target_id'); inputs = @{ name = 'SolPairs'; value = "@concat(${sa}?['aid'], '|', outputs('Sol_target_id'))" } }
$esm['Member_exists'] = [ordered]@{ type = 'Query'; runAfter = (After 'Note_pair'); inputs = @{ from = "@body('Existing_members')?['value']"; where = "@and(equals(item()?['_crdr_asset_value'], ${sa}?['aid']), equals(item()?['_crdr_solution_value'], outputs('Sol_target_id')))" } }
$esm['If_new_member'] = [ordered]@{ type = 'If'; runAfter = (After 'Member_exists'); expression = @{ and = @(@{ equals = @("@empty(body('Member_exists'))", $true) }, @{ equals = @("@empty(coalesce(outputs('Sol_target_id'), ''))", $false) }) }
    actions = [ordered]@{ Create_member = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_solutionmembers'
            'item/crdr_name' = "@$(Trunc "concat(coalesce(${sa}?['name'], ''), ' in ', coalesce(${sm}?['f'], ${sm}?['u']))" 400)"
            'item/crdr_asset@odata.bind' = "@concat('/crdr_assets(', ${sa}?['aid'], ')')"; 'item/crdr_solution@odata.bind' = "@concat('/crdr_solutions(', outputs('Sol_target_id'), ')')"
            'item/crdr_source' = "@${sa}?['src']" }) }
    else = @{ actions = @{} } }
$esa = [ordered]@{}
$esa['Sol_mine'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Sol_counted')"; where = "@equals(item()?['oid'], ${sa}?['oid'])" } }
$esa['Each_sol_mine'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Sol_mine')"; runAfter = (After 'Sol_mine'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $esm }
$ev['Each_sol_asset'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Sol_known')"; runAfter = (After 'Existing_members'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $esa }
$ev['Stale_members'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_sol_asset'); inputs = @{ from = "@body('Existing_members')?['value']"; where = "@not(contains(variables('SolPairs'), concat(item()?['_crdr_asset_value'], '|', item()?['_crdr_solution_value'])))" } }
$ev['Remove_stale_members'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Stale_members')"; runAfter = (After 'Stale_members')
    actions = @{ Delete_member = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_solutionmembers'; recordId = "@items('Remove_stale_members')?['crdr_solutionmemberid']" }) } }
$ev['Stale_solutions'] = [ordered]@{ type = 'Query'; runAfter = (After 'Remove_stale_members'); inputs = @{ from = "@body('Solutions_now')?['value']"; where = "@not(contains(outputs('Sol_distinct'), item()?['crdr_uniquename']))" } }
$ev['Remove_stale_solutions'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Stale_solutions')"; runAfter = (After 'Stale_solutions')
    actions = @{ Delete_solution = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_solutions'; recordId = "@items('Remove_stale_solutions')?['crdr_solutionid']" }) } }
$ev['Log_solutions'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Remove_stale_solutions'); inputs = @{ name = 'Log'; value = "@concat(outputs('Env_id'), ': solutions ', string(length(outputs('Sol_distinct'))), ', memberships ', string(length(variables('SolPairs'))))" } }
Add-ModelMap $dt (After 'Fixture_list')
$dt['Each_env'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Env_list')"; runAfter = (After 'Model_xml'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ev }
$dtActions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = (After $prev); actions = $dt }
$dtOk = "equals(actions('Collect')?['status'], 'Succeeded')"
$dtActions['Record_run'] = Dv 'CreateRecord' ([ordered]@{
        entityName = 'crdr_collectionruns'
        'item/crdr_name' = "@$(Trunc "concat('dataverse-detail ', formatDateTime(trigger()?['startTime'], 'yyyy-MM-dd HH:mm'), if($dtOk, ': ', ': FAILED: '), if(empty(variables('Log')), 'no environments in detail_environments', join(variables('Log'), '; ')))" 200)"
        'item/crdr_collector' = 'dataverse-detail'; 'item/crdr_accesstier' = $tier.full; 'item/crdr_startedon' = "@trigger()?['startTime']"
        'item/crdr_itemcount' = "@if($dtOk, length(variables('Log')), 0)"
        'item/crdr_gaps' = "@if($dtOk, 'Not attributed: code components on forms of a table an app includes without listing its forms. Canvas detection not yet proven against a fixture. Fixtures are not relabelled live if they leave a fixture solution.', concat('Collect scope: ', actions('Collect')?['status'], '. See the run for the failing environment.'))"
    }) (After 'Collect' $allStates)
$dtActions['Fail_if_collect_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Record_run' $allStates)
    expression = @{ not = @{ equals = @("@actions('Collect')?['status']", 'Succeeded') } }
    actions = @{ Terminate = @{ type = 'Terminate'; runAfter = @{}; inputs = @{ runStatus = 'Failed'; runError = @{ code = 'CollectFailed'; message = 'Dataverse detail failed: see the Collect scope and the crdr_collectionrun row.' } } } }
    else = @{ actions = @{} } }
$flows['CollectDetail'] = New-Flow 'Change Radar: collect Dataverse component detail per environment as the reader app: fixture labels, maker-built code components, prompts and their models, and the flows that call them (ADR 0008 addendum 2, ADR 0013, ADR 0017).' (Recurrence 'Day' 1 @{ hours = @('4'); minutes = @('30') }) $dtActions

# ---------- Fingerprint signals (ADR 0009 step 4, spike T7) ----------
# Calls Change Radar's fingerprint prompt, by id (solutions/design/prompts.json; ADR 0017), for signals never fingerprinted or changed since,
# limited to fingerprint_signal_ids when set. Same guards as spikes/T7/Test-FingerprintPrompt.ps1 and the engine:
# label repair (a vocabulary value under the wrong facet name is relabelled when the value belongs to one facet), values
# outside the vocabulary rejected, confidence below fingerprint_confidence_threshold to review. A signal with any manual
# fingerprint is skipped; its LLM rows are replaced only when it is fingerprinted again.
$fpOpt = @{ llm = Get-Opt 'extractedby' 'llm'; manual = Get-Opt 'extractedby' 'manual' }
$fpStatus = [ordered]@{ accepted = Get-Opt 'fingerprintstatus' 'accepted'; review = Get-Opt 'fingerprintstatus' 'review'; rejected = Get-Opt 'fingerprintstatus' 'rejected' }
$sg = "items('Each_signal')"
$ff = "items('Each_facet')"
$fp = [ordered]@{}
$fpActions = [ordered]@{}
$fpActions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
Add-ConfigQuery $fpActions 'Config_ids' 'fingerprint_signal_ids'
Add-ConfigQuery $fpActions 'Config_threshold' 'fingerprint_confidence_threshold'
Add-ConfigQuery $fpActions 'Config_fpmax' 'fingerprint_max_per_run'
Add-ConfigQuery $fpActions 'Config_catchup_max' 'catchup_max_per_run'
Add-ConfigQuery $fpActions 'Config_catchup_until' 'catchup_until'
$fpActions['Cap_fp'] = [ordered]@{ type = 'Compose'; runAfter = [ordered]@{ Config_fpmax = @('Succeeded'); Config_catchup_max = @('Succeeded'); Config_catchup_until = @('Succeeded') }; inputs = "@$(EffectiveCap (ConfigInt 'Config_fpmax' $config['fingerprint_max_per_run']))" }
$fpRunAfter = [ordered]@{ Config_ids = @('Succeeded'); Config_threshold = @('Succeeded'); Cap_fp = @('Succeeded') }
$i = 0; $prev = $null
foreach ($v in 'Done', 'Skipped', 'Accepted', 'Review', 'Rejected', 'Tokens') {
    $fpActions["Init_$v"] = [ordered]@{ type = 'InitializeVariable'; runAfter = $(if ($prev) { After $prev } else { $fpRunAfter }); inputs = @{ variables = @(@{ name = $v; type = 'integer'; value = 0 }) } }
    $prev = "Init_$v"
}
$promptName = "'$($ownPrompts.fingerprint.name)'"
# Checks the prompt is there; the run log names it.
$fp['Find_prompt'] = Dv 'ListRecords' ([ordered]@{ entityName = 'msdyn_aimodels'; '$select' = 'msdyn_aimodelid,msdyn_name'; '$filter' = "msdyn_aimodelid eq $($ownPrompts.fingerprint.id)"; '$top' = 1 })
$fp['Id_list'] = [ordered]@{ type = 'Query'; runAfter = (After 'Find_prompt'); inputs = @{ from = "@split(coalesce(first(body('Config_ids'))?['crdr_value'], ''), ';')"; where = '@not(empty(trim(item())))' } }
$fp['Vocab'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_facetvalues'; '$select' = 'crdr_name,crdr_value'; '$filter' = 'crdr_active eq true' }) (After 'Id_list') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$fp['Vocab_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Vocab'); inputs = @{ from = "@body('Vocab')?['value']"; select = "@item()?['crdr_name']" } }
# Service health incidents are never fingerprinted (ADR 0012 addendum, 2026-11-22: no estate to match, credits saved).
# Signals from unrated feeds are never fingerprinted (ADR 0018, ADR 0019: Book of News, licensing pages and guides).
$fp['Unrated_feeds'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_feeds'; '$select' = 'crdr_feedid'; '$filter' = 'crdr_unrated eq true' }) (After 'Vocab_names')
$fp['Unrated_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Unrated_feeds'); inputs = @{ from = "@body('Unrated_feeds')?['value']"; select = "@item()?['crdr_feedid']" } }
$fp['Signals'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signals'; '$select' = 'crdr_signalid,crdr_externalid,crdr_title,crdr_products,crdr_summary,crdr_lastchanged,crdr_fingerprintedon,_crdr_feed_value'; '$filter' = "statecode eq 0 and crdr_source ne $(Get-Opt 'signalsource' 'graph_health')" }) (After 'Unrated_ids') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$fp['To_do'] = [ordered]@{ type = 'Query'; runAfter = (After 'Signals'); inputs = @{ from = "@body('Signals')?['value']"
        where = "@and(not(contains(body('Unrated_ids'), coalesce(item()?['_crdr_feed_value'], ''))), or(empty(body('Id_list')), contains(body('Id_list'), item()?['crdr_externalid'])), or(empty(item()?['crdr_fingerprintedon']), greater(ticks(coalesce(item()?['crdr_lastchanged'], '1900-01-01T00:00:00Z')), ticks(item()?['crdr_fingerprintedon']))))" } }
$es2 = [ordered]@{}
$es2['Existing'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signalfingerprints'; '$select' = 'crdr_signalfingerprintid,crdr_extractedby'; '$filter' = "@concat('_crdr_signal_value eq ', ${sg}?['crdr_signalid'])" })
# Manual or rule fingerprints win: such a signal is skipped (rule rows come from the model lifecycle tables, ADR 0013).
$es2['Manual_rows'] = [ordered]@{ type = 'Query'; runAfter = (After 'Existing'); inputs = @{ from = "@body('Existing')?['value']"; where = "@or(equals(item()?['crdr_extractedby'], $($fpOpt.manual)), equals(item()?['crdr_extractedby'], $(Get-Opt 'extractedby' 'rule')))" } }
$work = [ordered]@{}
$work['Run_prompt'] = [ordered]@{ type = 'OpenApiConnection'; runAfter = @{}
    inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_commondataserviceforapps'; operationId = 'aibuilderpredict_customprompt'; apiId = $dvApi }
        # Operation copied from a designer-made "Run a prompt" action (2026-11-20). The designer flattens the inputs
        # (item/requestv2/<input>) because its recordId is a literal; with a dynamic recordId, save-time validation can't
        # resolve the prompt's schema and requires 'item' whole. Without 'source' the call fails ("Source is null").
        parameters = [ordered]@{ recordId = "$($ownPrompts.fingerprint.id)"
            item = [ordered]@{
                version = '2.0'   # required by Predict (observed 2026-11-20); the designer's flattened form sets it implicitly
                # requestv2 must be marked as an open type, or Dataverse rejects the input names (observed 2026-11-20).
                # '@@' escapes a leading '@', which the flow engine would otherwise parse as an expression.
                requestv2 = [ordered]@{ '@@odata.type' = '#Microsoft.Dynamics.CRM.expando'; Title = "@${sg}?['crdr_title']"; Products = "@coalesce(${sg}?['crdr_products'], '')"; Body = "@coalesce(${sg}?['crdr_summary'], '')" }
                source = "@concat('{""consumptionSource"":""PowerAutomate"",""partnerSource"":""AIBuilder"",""consumptionSourceVersion"":""Flow"",""partnerSourceVersion"":""', workflow()?['name'], '""}')" } }
        authentication = $auth } }
$out = "outputs('Run_prompt')?['body/responsev2/predictionOutput']"
$work['Facets'] = [ordered]@{ type = 'Query'; runAfter = (After 'Run_prompt'); inputs = @{ from = "@coalesce(${out}?['structuredOutput']?['facets'], json(coalesce(${out}?['text'], '{""facets"":[]}'))?['facets'], json('[]'))"; where = "@not(empty(trim(string(coalesce(item()?['value'], '')))))" } }
$work['Add_tokens'] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Facets'); inputs = @{ name = 'Tokens'; value = "@add(int(coalesce(${out}?['promptTokens'], 0)), int(coalesce(${out}?['completionTokens'], 0)))" } }
$work['Old_llm_rows'] = [ordered]@{ type = 'Query'; runAfter = (After 'Add_tokens'); inputs = @{ from = "@body('Existing')?['value']"; where = "@equals(item()?['crdr_extractedby'], $($fpOpt.llm))" } }
$work['Delete_old'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Old_llm_rows')"; runAfter = (After 'Old_llm_rows')
    actions = @{ Delete_row = Dv 'DeleteRecord' ([ordered]@{ entityName = 'crdr_signalfingerprints'; recordId = "@items('Delete_old')?['crdr_signalfingerprintid']" }) } }
$ef = [ordered]@{}
$ef['Raw_name'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@concat(${ff}?['facet'], ': ', ${ff}?['value'])" }
$ef['Same_value'] = [ordered]@{ type = 'Query'; runAfter = (After 'Raw_name'); inputs = @{ from = "@body('Vocab')?['value']"; where = "@equals(item()?['crdr_value'], ${ff}?['value'])" } }
$ef['Final_name'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Same_value'); inputs = "@if(contains(body('Vocab_names'), outputs('Raw_name')), outputs('Raw_name'), if(equals(length(body('Same_value')), 1), first(body('Same_value'))?['crdr_name'], outputs('Raw_name')))" }
$threshold = "float(coalesce(first(body('Config_threshold'))?['crdr_value'], '$($config['fingerprint_confidence_threshold'])'))"
$ef['Status'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Final_name'); inputs = "@if(not(contains(body('Vocab_names'), outputs('Final_name'))), 'rejected', if(less(float(coalesce(${ff}?['confidence'], 0)), $threshold), 'review', 'accepted'))" }
$ef['Facet_option'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Status'); inputs = "@$(JsonLit $facetOpt)?[first(split(outputs('Final_name'), ': '))]" }
$ef['Known_facet'] = [ordered]@{ type = 'If'; runAfter = (After 'Facet_option'); expression = @{ not = @{ equals = @("@string(coalesce(outputs('Facet_option'), ''))", '') } }   # an option value is an integer: empty() rejects it
    actions = [ordered]@{ Create_fingerprint = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_signalfingerprints'
                'item/crdr_name' = "@$(Trunc "outputs('Final_name')" 200)"; 'item/crdr_signal@odata.bind' = "@concat('/crdr_signals(', ${sg}?['crdr_signalid'], ')')"
                'item/crdr_group' = "@$(Trunc "coalesce(${ff}?['group'], 'A')" 10)"; 'item/crdr_facet' = "@outputs('Facet_option')"
                'item/crdr_value' = "@$(Trunc "last(split(outputs('Final_name'), ': '))" 200)"; 'item/crdr_extractedby' = $fpOpt.llm
                'item/crdr_confidence' = "@float(coalesce(${ff}?['confidence'], 0))"; 'item/crdr_status' = "@$(JsonLit $fpStatus)?[outputs('Status')]"
                'item/crdr_reason' = "@$(Trunc "concat(if(equals(outputs('Final_name'), outputs('Raw_name')), '', concat('[relabelled from ', outputs('Raw_name'), '] ')), coalesce(${ff}?['reason'], ''))" 1000)" }) }
    else = @{ actions = @{} } }
$prev = 'Known_facet'
foreach ($s in 'Accepted', 'Review', 'Rejected') {
    $ef["Count_$s"] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After $prev); inputs = @{ name = $s; value = "@if(equals(outputs('Status'), '$($s.ToLower())'), 1, 0)" } }
    $prev = "Count_$s"
}
$work['Each_facet'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Facets')"; runAfter = (After 'Delete_old'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $ef }
$work['Mark_fingerprinted'] = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@${sg}?['crdr_signalid']"; 'item/crdr_fingerprintedon' = '@utcNow()' }) (After 'Each_facet')
$work['Count_done'] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Mark_fingerprinted'); inputs = @{ name = 'Done'; value = 1 } }
$es2['Has_manual'] = [ordered]@{ type = 'If'; runAfter = (After 'Manual_rows'); expression = @{ equals = @("@empty(body('Manual_rows'))", $true) }
    actions = $work
    else = @{ actions = @{ Count_skipped = @{ type = 'IncrementVariable'; runAfter = @{}; inputs = @{ name = 'Skipped'; value = 1 } } } } }
# fingerprint_max_per_run caps prompt calls per run (0 = no cap): the credit safeguard of the ADR 0012 addendum.
$fpMax = "outputs('Cap_fp')"
$fp['Capped'] = [ordered]@{ type = 'Compose'; runAfter = (After 'To_do'); inputs = "@if(greater($fpMax, 0), take(body('To_do'), $fpMax), body('To_do'))" }
$fp['Each_signal'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Capped')"; runAfter = (After 'Capped'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $es2 }
$fpActions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = (After 'Init_Tokens'); actions = $fp }
$fpOk = "equals(actions('Collect')?['status'], 'Succeeded')"
$fpActions['Record_run'] = Dv 'CreateRecord' ([ordered]@{
        entityName = 'crdr_collectionruns'
        'item/crdr_name' = "@$(Trunc "concat('fingerprint ', formatDateTime(trigger()?['startTime'], 'yyyy-MM-dd HH:mm'), if($fpOk, ': ', ': FAILED: '), 'signals ', string(variables('Done')), ', skipped (manual) ', string(variables('Skipped')), ', facets accepted ', string(variables('Accepted')), ' review ', string(variables('Review')), ' rejected ', string(variables('Rejected')), ', tokens ', string(variables('Tokens')))" 200)"
        'item/crdr_collector' = 'fingerprint'; 'item/crdr_accesstier' = $tier.full; 'item/crdr_startedon' = "@trigger()?['startTime']"
        'item/crdr_itemcount' = "@if($fpOk, variables('Done'), 0)"
        'item/crdr_gaps' = "@if($fpOk, concat('Prompt ''', $promptName, '''. Limited to: ', if(empty(body('Id_list')), 'all signals', join(body('Id_list'), ', ')), '. Cap this run: ', string(outputs('Cap_fp')), ' (0 = none).'), concat('Collect scope: ', actions('Collect')?['status'], '. Check the prompt exists (fingerprint_prompt_name) and AI Builder or Copilot credit capacity.'))"
    }) (After 'Collect' $allStates)
$fpActions['Fail_if_collect_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Record_run' $allStates)
    expression = @{ not = @{ equals = @("@actions('Collect')?['status']", 'Succeeded') } }
    actions = @{ Terminate = @{ type = 'Terminate'; runAfter = @{}; inputs = @{ runStatus = 'Failed'; runError = @{ code = 'CollectFailed'; message = 'Fingerprinting failed: see the Collect scope and the crdr_collectionrun row.' } } } }
    else = @{ actions = @{} } }
$flows['FingerprintSignals'] = New-Flow 'Change Radar: fingerprint new and changed signals with the AI hub prompt, vocabulary-checked, low confidence to review (ADR 0009).' (Recurrence 'Day' 1 @{ hours = @('5'); minutes = @('30') }) $fpActions

# ---------- Match exposures (ADR 0009 step 5) ----------
# Same semantics as engine Find-Exposures: per signal, accepted fingerprint groups are alternatives; within a group
# every facet clause with an active rule must hold (AND), any listed value satisfies a clause (OR); a group with no
# trigger clause exposes nothing; setting clauses check crdr_tenantsetting (live only) and expose when the setting is
# absent or doesn't cover the group's products. Asset candidates come from one fingerprint query per clause,
# intersected, so the whole estate (live, fixture, synthetic) is never looped over. Exposures carry the asset's source.
# New exposures start 'new'; a re-match leaves a person's status (confirmed, dismissed) alone. Exposures that no longer
# match, including every open exposure of a signal left with no accepted fingerprint, are set 'unmatched' (never deleted),
# and an unmatched exposure that matches again goes back to 'new'. 'dismissed' is only ever set by a person.
$roleOpt = @{ scope = Get-Opt 'rulerole' 'scope'; trigger = Get-Opt 'rulerole' 'trigger'; setting = Get-Opt 'rulerole' 'setting' }
$exOpt = @{ new = Get-Opt 'exposurestatus' 'new'; confirmed = Get-Opt 'exposurestatus' 'confirmed'; dismissed = Get-Opt 'exposurestatus' 'dismissed'; system = Get-Opt 'exposurestatus' 'system'; unmatched = Get-Opt 'exposurestatus' 'unmatched' }
$facetLabel = [ordered]@{}; foreach ($k in $facetOpt.Keys) { $facetLabel["$($facetOpt[$k])"] = $k }
$enabledState = Get-Opt 'settingstate' 'enabled'
$msg = "items('Each_match_signal')"; $grpI = "items('Each_group')"; $clI = "items('Each_clause')"
$mx = [ordered]@{}
$mxActions = [ordered]@{}
# demo_data off (ADR 0022): synthetic assets are not candidates and their existing exposures are left as they are, so
# switching demo data off neither spends nor raises anything for it, and switching it on again changes nothing.
$mxActions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
Add-ConfigQuery $mxActions 'Config_demo' 'demo_data'
$mxDemoOff = DemoOff 'Config_demo'
$mxActions['Init_matched'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Config_demo'); inputs = @{ variables = @(@{ name = 'Matched'; type = 'array'; value = @() }) } }
$mxActions['Init_hits'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_matched'); inputs = @{ variables = @(@{ name = 'Hits'; type = 'array'; value = @() }) } }
$mxActions['Init_cand'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_hits'); inputs = @{ variables = @(@{ name = 'Cand'; type = 'array'; value = @() }) } }
$mxActions['Init_first'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_cand'); inputs = @{ variables = @(@{ name = 'First'; type = 'boolean'; value = $true }) } }
$prev = 'Init_first'
foreach ($v in 'Signals', 'Created', 'Updated', 'Unmatched') {
    $mxActions["Init_$v"] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After $prev); inputs = @{ variables = @(@{ name = $v; type = 'integer'; value = 0 }) } }; $prev = "Init_$v"
}
$mx['Rules'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_rules'; '$select' = 'crdr_rulecode,crdr_signalfacet,crdr_assetfacet,crdr_role'; '$filter' = 'crdr_active eq true' })
$mx['Accepted'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signalfingerprints'; '$select' = '_crdr_signal_value,crdr_group,crdr_facet,crdr_value'; '$filter' = "crdr_status eq $($fpStatus.accepted)" }) (After 'Rules') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$mx['Accepted_signal_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Accepted'); inputs = @{ from = "@body('Accepted')?['value']"; select = "@item()?['_crdr_signal_value']" } }
$mx['Signal_ids'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Accepted_signal_ids'); inputs = "@union(body('Accepted_signal_ids'), body('Accepted_signal_ids'))" }   # union with itself de-duplicates
$mx['Settings'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_tenantsettings'; '$select' = 'crdr_tenantsettingid,crdr_key,crdr_state,crdr_scope' }) (After 'Signal_ids')

$sigLoop = [ordered]@{}
$sigLoop['Reset_matched'] = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'Matched'; value = @() } }
$sigLoop['Signal_rows'] = [ordered]@{ type = 'Query'; runAfter = (After 'Reset_matched'); inputs = @{ from = "@body('Accepted')?['value']"; where = "@equals(item()?['_crdr_signal_value'], $msg)" } }
$sigLoop['Group_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Signal_rows'); inputs = @{ from = "@body('Signal_rows')"; select = "@coalesce(item()?['crdr_group'], 'A')" } }
$sigLoop['Groups'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Group_names'); inputs = "@union(body('Group_names'), body('Group_names'))" }

$grp = [ordered]@{}
$grp['Group_rows'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Signal_rows')"; where = "@equals(coalesce(item()?['crdr_group'], 'A'), $grpI)" } }
$grp['Group_facets'] = [ordered]@{ type = 'Select'; runAfter = (After 'Group_rows'); inputs = @{ from = "@body('Group_rows')"; select = "@item()?['crdr_facet']" } }
$grp['Clauses'] = [ordered]@{ type = 'Query'; runAfter = (After 'Group_facets'); inputs = @{ from = "@body('Rules')?['value']"; where = "@contains(body('Group_facets'), item()?['crdr_signalfacet'])" } }
$grp['Products'] = [ordered]@{ type = 'Select'; runAfter = (After 'Clauses'); inputs = @{ from = "@body('Group_rows')"; select = "@if(equals(item()?['crdr_facet'], $($facetOpt['product'])), item()?['crdr_value'], '')" } }
$grp['Product_list'] = [ordered]@{ type = 'Query'; runAfter = (After 'Products'); inputs = @{ from = "@body('Products')"; where = "@not(empty(item()))" } }
$grp['Setting_clauses'] = [ordered]@{ type = 'Query'; runAfter = (After 'Product_list'); inputs = @{ from = "@body('Clauses')"; where = "@equals(item()?['crdr_role'], $($roleOpt.setting))" } }
$grp['Asset_clauses'] = [ordered]@{ type = 'Query'; runAfter = (After 'Setting_clauses'); inputs = @{ from = "@body('Clauses')"; where = "@or(equals(item()?['crdr_role'], $($roleOpt.scope)), equals(item()?['crdr_role'], $($roleOpt.trigger)))" } }
$grp['Trigger_clauses'] = [ordered]@{ type = 'Query'; runAfter = (After 'Asset_clauses'); inputs = @{ from = "@body('Clauses')"; where = "@equals(item()?['crdr_role'], $($roleOpt.trigger))" } }
# Settings: each setting value in the group is a key in crdr_tenantsetting.
$setRows = [ordered]@{}
$setRows['Setting_keys'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Group_rows')"; where = "@equals(item()?['crdr_facet'], $($facetOpt['setting']))" } }
$sk = "items('Each_setting_key')"
$skLoop = [ordered]@{}
$skLoop['Setting_row'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Settings')?['value']"; where = "@and(equals(item()?['crdr_key'], ${sk}?['crdr_value']), equals(item()?['crdr_state'], $enabledState))" } }
$skLoop['Scope_list'] = [ordered]@{ type = 'Select'; runAfter = (After 'Setting_row'); inputs = @{ from = "@split(coalesce(first(body('Setting_row'))?['crdr_scope'], ''), ';')"; select = '@trim(item())' } }
$covers = "and(not(empty(body('Setting_row'))), or(empty(body('Product_list')), not(empty(intersection(body('Product_list'), body('Scope_list'))))))"
$skLoop['Not_covered'] = [ordered]@{ type = 'If'; runAfter = (After 'Scope_list'); expression = @{ equals = @("@$covers", $false) }
    actions = @{ Add_setting_match = @{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'Matched'; value = [ordered]@{
                    kind = 'setting'; key = "@${sk}?['crdr_value']"; settingid = "@first(body('Setting_row'))?['crdr_tenantsettingid']"; group = "@$grpI"; rules = "@join(body('Setting_rule_codes'), ',')"; facets = 'setting'
                    evidence = "@if(empty(body('Setting_row')), concat('no enabled crdr_tenantsetting row for ''', ${sk}?['crdr_value'], ''''), concat('crdr_tenantsetting ', ${sk}?['crdr_value'], ' enabled but scope ''', first(body('Setting_row'))?['crdr_scope'], ''' does not cover ''', join(body('Product_list'), ', '), ''''))" } } } }
    else = @{ actions = @{} } }
$setRows['Setting_rule_codes'] = [ordered]@{ type = 'Select'; runAfter = (After 'Setting_keys'); inputs = @{ from = "@body('Setting_clauses')"; select = "@item()?['crdr_rulecode']" } }
$setRows['Each_setting_key'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Setting_keys')"; runAfter = (After 'Setting_rule_codes'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $skLoop }
$grp['Has_setting'] = [ordered]@{ type = 'If'; runAfter = (After 'Trigger_clauses'); expression = @{ equals = @("@empty(body('Setting_clauses'))", $false) }; actions = $setRows; else = @{ actions = @{} } }
# Assets: one fingerprint query per clause, candidate asset ids intersected across clauses.
$cl = [ordered]@{}
$cl['Clause_values'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Group_rows')"; where = "@equals(item()?['crdr_facet'], ${clI}?['crdr_signalfacet'])" } }
$cl['Value_filters'] = [ordered]@{ type = 'Select'; runAfter = (After 'Clause_values'); inputs = @{ from = "@body('Clause_values')"; select = "@concat('crdr_value eq ''', replace(item()?['crdr_value'], '''', ''''''), '''')" } }
$cl['Clause_hits'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assetfingerprints'; '$select' = '_crdr_asset_value,crdr_name,crdr_evidence'
        '$filter' = "@concat('crdr_facet eq ', string(${clI}?['crdr_assetfacet']), ' and (', join(body('Value_filters'), ' or '), ')', if($mxDemoOff, ' and crdr_asset/crdr_source ne $syntheticSource', ''))" }) (After 'Value_filters') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$cl['Clause_assets'] = [ordered]@{ type = 'Select'; runAfter = (After 'Clause_hits'); inputs = @{ from = "@body('Clause_hits')?['value']"; select = "@item()?['_crdr_asset_value']" } }
$cl['Tagged_hits'] = [ordered]@{ type = 'Select'; runAfter = (After 'Clause_assets'); inputs = @{ from = "@body('Clause_hits')?['value']"; select = [ordered]@{ asset = "@item()?['_crdr_asset_value']"; text = "@concat(item()?['crdr_name'], ' [', coalesce(item()?['crdr_evidence'], ''), '] (', ${clI}?['crdr_rulecode'], ')')" } } }
$cl['Next_cand'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Tagged_hits'); inputs = "@if(variables('First'), union(body('Clause_assets'), body('Clause_assets')), intersection(variables('Cand'), body('Clause_assets')))" }
$cl['Set_cand'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Next_cand'); inputs = @{ name = 'Cand'; value = "@outputs('Next_cand')" } }
$cl['Not_first'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Set_cand'); inputs = @{ name = 'First'; value = $false } }
$cl['Next_hits'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Not_first'); inputs = "@union(variables('Hits'), body('Tagged_hits'))" }
$cl['Set_hits'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Next_hits'); inputs = @{ name = 'Hits'; value = "@outputs('Next_hits')" } }
$assetPart = [ordered]@{}
$assetPart['Reset_cand'] = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'Cand'; value = @() } }
$assetPart['Reset_hits'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Reset_cand'); inputs = @{ name = 'Hits'; value = @() } }
$assetPart['Reset_first'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Reset_hits'); inputs = @{ name = 'First'; value = $true } }
$assetPart['Each_clause'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Asset_clauses')"; runAfter = (After 'Reset_first'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $cl }
$assetPart['Clause_codes'] = [ordered]@{ type = 'Select'; runAfter = (After 'Each_clause'); inputs = @{ from = "@body('Asset_clauses')"; select = "@item()?['crdr_rulecode']" } }
$assetPart['Clause_facets'] = [ordered]@{ type = 'Select'; runAfter = (After 'Clause_codes'); inputs = @{ from = "@body('Asset_clauses')"; select = "@$(JsonLit $facetLabel)?[string(item()?['crdr_signalfacet'])]" } }
$ca = "items('Each_candidate')"
$assetPart['Each_candidate'] = [ordered]@{ type = 'Foreach'; foreach = "@variables('Cand')"; runAfter = (After 'Clause_facets'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
    actions = [ordered]@{
        Candidate_hits = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@variables('Hits')"; where = "@equals(item()?['asset'], $ca)" } }
        Candidate_text = [ordered]@{ type = 'Select'; runAfter = (After 'Candidate_hits'); inputs = @{ from = "@body('Candidate_hits')"; select = "@item()?['text']" } }
        Add_asset_match = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Candidate_text'); inputs = @{ name = 'Matched'; value = [ordered]@{
                    kind = 'asset'; asset = "@$ca"; group = "@$grpI"; rules = "@join(body('Clause_codes'), ',')"; facets = "@join(body('Clause_facets'), ',')"; evidence = "@join(body('Candidate_text'), '; ')" } } } } }
$grp['Has_trigger'] = [ordered]@{ type = 'If'; runAfter = (After 'Has_setting'); expression = @{ equals = @("@empty(body('Trigger_clauses'))", $false) }; actions = $assetPart; else = @{ actions = @{} } }
$sigLoop['Each_group'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Groups')"; runAfter = (After 'Groups'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $grp }

# Upsert: one exposure per asset (first matching group wins, as in the engine) and per setting key.
$sigLoop['Signal_record'] = Dv 'GetItem' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@$msg"; '$select' = 'crdr_externalid' }) (After 'Each_group')
$sigLoop['Existing_exposures'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_exposures'; '$select' = 'crdr_exposureid,_crdr_asset_value,crdr_name,crdr_status'; '$filter' = "@concat('_crdr_signal_value eq ', $msg, if($mxDemoOff, ' and crdr_source ne $syntheticSource', ''))" }) (After 'Signal_record') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$sigLoop['Asset_matches'] = [ordered]@{ type = 'Query'; runAfter = (After 'Existing_exposures'); inputs = @{ from = "@variables('Matched')"; where = "@equals(item()?['kind'], 'asset')" } }
$sigLoop['Matched_asset_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Asset_matches'); inputs = @{ from = "@body('Asset_matches')"; select = "@item()?['asset']" } }
$sigLoop['Unique_asset_ids'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Matched_asset_ids'); inputs = "@union(body('Matched_asset_ids'), body('Matched_asset_ids'))" }
$sigLoop['Setting_matches'] = [ordered]@{ type = 'Query'; runAfter = (After 'Unique_asset_ids'); inputs = @{ from = "@variables('Matched')"; where = "@equals(item()?['kind'], 'setting')" } }
$sigLoop['Setting_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Setting_matches'); inputs = @{ from = "@body('Setting_matches')"; select = "@concat(body('Signal_record')?['crdr_externalid'], ' | setting: ', item()?['key'])" } }
$ua = "items('Each_asset_exposure')"
$first = "first(body('This_match'))"
$sigLoop['Each_asset_exposure'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Unique_asset_ids')"; runAfter = (After 'Setting_names'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
    actions = [ordered]@{
        This_match = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Asset_matches')"; where = "@equals(item()?['asset'], $ua)" } }
        Asset_record = Dv 'GetItem' ([ordered]@{ entityName = 'crdr_assets'; recordId = "@$ua"; '$select' = 'crdr_name,crdr_source,crdr_microsoftsystem' }) (After 'This_match')
        Existing_one = [ordered]@{ type = 'Query'; runAfter = (After 'Asset_record'); inputs = @{ from = "@body('Existing_exposures')?['value']"; where = "@equals(item()?['_crdr_asset_value'], $ua)" } }
        Is_new_exposure = [ordered]@{ type = 'If'; runAfter = (After 'Existing_one'); expression = @{ equals = @("@empty(body('Existing_one'))", $true) }
            actions = [ordered]@{
                Create_exposure = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_exposures'
                        'item/crdr_name' = "@$(Trunc "concat(body('Signal_record')?['crdr_externalid'], ' | ', body('Asset_record')?['crdr_name'])" 400)"
                        'item/crdr_signal@odata.bind' = "@concat('/crdr_signals(', $msg, ')')"; 'item/crdr_asset@odata.bind' = "@concat('/crdr_assets(', $ua, ')')"
                        'item/crdr_group' = "@${first}?['group']"; 'item/crdr_matchedfacets' = "@$(Trunc "${first}?['facets']" 400)"; 'item/crdr_rules' = "@$(Trunc "${first}?['rules']" 400)"
                        'item/crdr_evidencetext' = "@$(Trunc "${first}?['evidence']" 10000)"; 'item/crdr_status' = "@if(equals(body('Asset_record')?['crdr_microsoftsystem'], true), $($exOpt.system), $($exOpt.new))"; 'item/crdr_source' = "@body('Asset_record')?['crdr_source']" })
                Count_created = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Create_exposure'); inputs = @{ name = 'Created'; value = 1 } } }
            else = @{ actions = [ordered]@{
                    Update_exposure = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_exposures'; recordId = "@first(body('Existing_one'))?['crdr_exposureid']"
                            'item/crdr_group' = "@${first}?['group']"; 'item/crdr_matchedfacets' = "@$(Trunc "${first}?['facets']" 400)"; 'item/crdr_rules' = "@$(Trunc "${first}?['rules']" 400)"
                            'item/crdr_evidencetext' = "@$(Trunc "${first}?['evidence']" 10000)"; 'item/crdr_source' = "@body('Asset_record')?['crdr_source']"
                            'item/crdr_status' = "@if(equals(body('Asset_record')?['crdr_microsoftsystem'], true), $($exOpt.system), if(or(equals(first(body('Existing_one'))?['crdr_status'], $($exOpt.unmatched)), equals(first(body('Existing_one'))?['crdr_status'], $($exOpt.system))), $($exOpt.new), first(body('Existing_one'))?['crdr_status']))" })
                    Count_updated = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Update_exposure'); inputs = @{ name = 'Updated'; value = 1 } } } } } } }
$sm = "items('Each_setting_exposure')"
$sigLoop['Each_setting_exposure'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Setting_matches')"; runAfter = (After 'Each_asset_exposure'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
    actions = [ordered]@{
        Setting_name = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@concat(body('Signal_record')?['crdr_externalid'], ' | setting: ', ${sm}?['key'])" }
        Existing_setting = [ordered]@{ type = 'Query'; runAfter = (After 'Setting_name'); inputs = @{ from = "@body('Existing_exposures')?['value']"; where = "@equals(item()?['crdr_name'], outputs('Setting_name'))" } }
        Is_new_setting = [ordered]@{ type = 'If'; runAfter = (After 'Existing_setting'); expression = @{ equals = @("@empty(body('Existing_setting'))", $true) }
            actions = [ordered]@{
                Create_setting_exposure = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_exposures'; 'item/crdr_name' = "@outputs('Setting_name')"
                        'item/crdr_signal@odata.bind' = "@concat('/crdr_signals(', $msg, ')')"; 'item/crdr_group' = "@${sm}?['group']"; 'item/crdr_matchedfacets' = 'setting'
                        'item/crdr_rules' = "@${sm}?['rules']"; 'item/crdr_evidencetext' = "@${sm}?['evidence']"; 'item/crdr_status' = $exOpt.new; 'item/crdr_source' = $liveSource })
                Count_created_setting = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Create_setting_exposure'); inputs = @{ name = 'Created'; value = 1 } } }
            else = @{ actions = [ordered]@{
                    Update_setting_exposure = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_exposures'; recordId = "@first(body('Existing_setting'))?['crdr_exposureid']"; 'item/crdr_evidencetext' = "@${sm}?['evidence']"; 'item/crdr_rules' = "@${sm}?['rules']"
                        'item/crdr_status' = "@if(equals(first(body('Existing_setting'))?['crdr_status'], $($exOpt.unmatched)), $($exOpt.new), first(body('Existing_setting'))?['crdr_status'])" })
                    Count_updated_setting = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Update_setting_exposure'); inputs = @{ name = 'Updated'; value = 1 } } } } } } }
$sigLoop['Stale'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_setting_exposure'); inputs = @{ from = "@body('Existing_exposures')?['value']"
        where = "@and(not(equals(item()?['crdr_status'], $($exOpt.dismissed))), not(equals(item()?['crdr_status'], $($exOpt.unmatched))), if(empty(item()?['_crdr_asset_value']), not(contains(body('Setting_names'), item()?['crdr_name'])), not(contains(outputs('Unique_asset_ids'), item()?['_crdr_asset_value']))))" } }
$sigLoop['Each_stale'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Stale')"; runAfter = (After 'Stale')
    actions = [ordered]@{
        Unmatch = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_exposures'; recordId = "@items('Each_stale')?['crdr_exposureid']"; 'item/crdr_status' = $exOpt.unmatched })
        Count_unmatched = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Unmatch'); inputs = @{ name = 'Unmatched'; value = 1 } } } }
$sigLoop['Count_signal'] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Each_stale'); inputs = @{ name = 'Signals'; value = 1 } }
$mx['Each_match_signal'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Signal_ids')"; runAfter = (After 'Settings'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $sigLoop }
# Signals with no accepted fingerprint left (all rejected in review) aren't in Signal_ids, so their open exposures are swept here.
$mx['Open_exposures'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_exposures'; '$select' = 'crdr_exposureid,_crdr_signal_value'; '$filter' = "crdr_status eq $($exOpt.new) or crdr_status eq $($exOpt.confirmed)" }) (After 'Each_match_signal') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$mx['Orphaned'] = [ordered]@{ type = 'Query'; runAfter = (After 'Open_exposures'); inputs = @{ from = "@body('Open_exposures')?['value']"; where = "@not(contains(outputs('Signal_ids'), item()?['_crdr_signal_value']))" } }
$mx['Each_orphaned'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Orphaned')"; runAfter = (After 'Orphaned')
    actions = [ordered]@{
        Unmatch_orphaned = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_exposures'; recordId = "@items('Each_orphaned')?['crdr_exposureid']"; 'item/crdr_status' = $exOpt.unmatched })
        Count_orphaned = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Unmatch_orphaned'); inputs = @{ name = 'Unmatched'; value = 1 } } } }
$mxActions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = (After 'Init_Unmatched'); actions = $mx }
$mxOk = "equals(actions('Collect')?['status'], 'Succeeded')"
$mxActions['Record_run'] = Dv 'CreateRecord' ([ordered]@{
        entityName = 'crdr_collectionruns'
        'item/crdr_name' = "@$(Trunc "concat('match ', formatDateTime(trigger()?['startTime'], 'yyyy-MM-dd HH:mm'), if($mxOk, ': ', ': FAILED: '), 'signals ', string(variables('Signals')), ', exposures created ', string(variables('Created')), ' updated ', string(variables('Updated')), ' unmatched ', string(variables('Unmatched')))" 200)"
        'item/crdr_collector' = 'match'; 'item/crdr_accesstier' = $tier.full; 'item/crdr_startedon' = "@trigger()?['startTime']"
        'item/crdr_itemcount' = "@if($mxOk, add(variables('Created'), variables('Updated')), 0)"
        'item/crdr_gaps' = "@if($mxOk, 'Setting exposures are live only (crdr_tenantsetting describes the real tenant). Agent capabilities that need Dataverse or Kit detail (uses_mcp, http_action, autonomous_trigger) are unknown, so agents are not matched on them.', concat('Collect scope: ', actions('Collect')?['status']))"
    }) (After 'Collect' $allStates)
$mxActions['Fail_if_collect_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Record_run' $allStates)
    expression = @{ not = @{ equals = @("@actions('Collect')?['status']", 'Succeeded') } }
    actions = @{ Terminate = @{ type = 'Terminate'; runAfter = @{}; inputs = @{ runStatus = 'Failed'; runError = @{ code = 'CollectFailed'; message = 'Matching failed: see the Collect scope and the crdr_collectionrun row.' } } } }
    else = @{ actions = @{} } }
$flows['MatchExposures'] = New-Flow 'Change Radar: match accepted signal fingerprints to asset fingerprints and tenant settings with the rules in crdr_rule, upserting crdr_exposure (ADR 0009).' (Recurrence 'Day' 1 @{ hours = @('6') }) $mxActions

# ---------- Assess signals (ADR 0010, spike T8) ----------
# Same semantics as engine/ChangeRadar.Assessment.psm1. Per signal with open exposures (or an existing assessment), per
# source (never mixed): builds the names-free estate summary exactly as Get-ExposureSummary does, calls the assessment
# prompt only when there's no assessment yet, the summary changed, or the signal changed since it was assessed; then
# scores: generic impact + 1 production + 1 action within 30 days (or past), clamped to estate_impact_max, floor Low
# when exposed. A source whose exposures are all gone keeps its row with estate impact None. Override fields
# (overrideimpact, overridereason, overriddenby, overriddenon) are never written here.
$impOpt = [ordered]@{}; foreach ($v in $schema.choices.impact) { $impOpt[$v] = Get-Opt 'impact' $v }
$natOpt = [ordered]@{}; foreach ($v in $schema.choices.nature) { $natOpt[$v] = Get-Opt 'nature' $v }
$envName = [ordered]@{}; foreach ($v in $schema.choices.environmenttype) { $envName["$(Get-Opt 'environmenttype' $v)"] = $v }
$srcOpts = @($schema.choices.assetsource | ForEach-Object { [ordered]@{ n = $_; o = (Get-Opt 'assetsource' $_) } })
$exOpen = @{ new = Get-Opt 'exposurestatus' 'new'; confirmed = Get-Opt 'exposurestatus' 'confirmed' }
$nl = "decodeUriComponent('%0A')"
$as = [ordered]@{}
$asActions = [ordered]@{}
$asActions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
Add-ConfigQuery $asActions 'Config_max' 'estate_impact_max'
Add-ConfigQuery $asActions 'Config_scope' 'rating_scope'
Add-ConfigQuery $asActions 'Config_ratemax' 'rating_max_per_run'
Add-ConfigQuery $asActions 'Config_demo' 'demo_data'
Add-ConfigQuery $asActions 'Config_assessmax' 'assessment_max_per_run'
Add-ConfigQuery $asActions 'Config_catchup_max' 'catchup_max_per_run'
Add-ConfigQuery $asActions 'Config_catchup_until' 'catchup_until'
$capAfter = @{ Config_catchup_max = @('Succeeded'); Config_catchup_until = @('Succeeded') }
$asActions['Cap_rate'] = [ordered]@{ type = 'Compose'; runAfter = ($capAfter + @{ Config_ratemax = @('Succeeded') }); inputs = "@$(EffectiveCap (ConfigInt 'Config_ratemax' $config['rating_max_per_run']))" }
$asActions['Cap_assess'] = [ordered]@{ type = 'Compose'; runAfter = ($capAfter + @{ Config_assessmax = @('Succeeded') }); inputs = "@$(EffectiveCap (ConfigInt 'Config_assessmax' $config['assessment_max_per_run']))" }
$prev = $null
foreach ($v in 'Rated', 'Signals', 'Prompted', 'Rescored', 'Cleared', 'Invalid', 'Tokens', 'Themed', 'Deferred') {
    $asActions["Init_$v"] = [ordered]@{ type = 'InitializeVariable'; runAfter = $(if ($prev) { After $prev } else { [ordered]@{ Config_max = @('Succeeded'); Config_scope = @('Succeeded'); Cap_rate = @('Succeeded'); Config_demo = @('Succeeded'); Cap_assess = @('Succeeded') } }); inputs = @{ variables = @(@{ name = $v; type = 'integer'; value = 0 }) } }
    $prev = "Init_$v"
}
foreach ($v in 'TypeLines', 'GroupTexts') { $asActions["Init_$v"] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After $prev); inputs = @{ variables = @(@{ name = $v; type = 'array'; value = @() }) } }; $prev = "Init_$v" }
$asPrompt = "'$($ownPrompts.assessment.name)'"
$asMax = ConfigInt 'Config_max' $config['estate_impact_max']
$as['Find_prompt'] = Dv 'ListRecords' ([ordered]@{ entityName = 'msdyn_aimodels'; '$select' = 'msdyn_aimodelid,msdyn_name'; '$filter' = "msdyn_aimodelid eq $($ownPrompts.assessment.id)"; '$top' = 1 })
$as['Open_exposures'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_exposures'; '$select' = 'crdr_name,crdr_group,crdr_source,_crdr_signal_value,_crdr_asset_value'
        '$filter' = "crdr_status eq $($exOpen.new) or crdr_status eq $($exOpen.confirmed)"; '$expand' = 'crdr_asset($select=crdr_resourcetype,crdr_environmenttype)' }) (After 'Find_prompt') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$as['Assessments'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assessments'; '$select' = 'crdr_assessmentid,_crdr_signal_value,crdr_source,crdr_exposuresummary,crdr_assessedon,crdr_genericimpact' }) (After 'Open_exposures') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$as['Exposure_signal_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Assessments'); inputs = @{ from = "@body('Open_exposures')?['value']"; select = "@item()?['_crdr_signal_value']" } }
$as['Assessed_signal_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Exposure_signal_ids'); inputs = @{ from = "@body('Assessments')?['value']"; select = "@item()?['_crdr_signal_value']" } }
$as['Signal_ids'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Assessed_signal_ids'); inputs = "@union(body('Exposure_signal_ids'), body('Assessed_signal_ids'))" }
# One row per open exposure, shaped like the engine's input: asset id, display type, environment name, group, setting key.
$as['Rows'] = [ordered]@{ type = 'Select'; runAfter = (After 'Signal_ids'); inputs = @{ from = "@body('Open_exposures')?['value']"; select = [ordered]@{
            signal = "@item()?['_crdr_signal_value']"; source = "@item()?['crdr_source']"; asset = "@coalesce(item()?['_crdr_asset_value'], '')"; group = "@item()?['crdr_group']"
            type = "@coalesce(${rtMap}?[toLower(coalesce(item()?['crdr_asset']?['crdr_resourcetype'], ''))], toLower(coalesce(item()?['crdr_asset']?['crdr_resourcetype'], '')))"
            env = "@coalesce($(JsonLit $envName)?[string(item()?['crdr_asset']?['crdr_environmenttype'])], 'unknown')"
            setting = "@if(empty(item()?['_crdr_asset_value']), last(split(item()?['crdr_name'], ' | setting: ')), '')" } } }

$sid = "items('Each_assess_signal')"; $srcI = "items('Each_source')"
$sgl = [ordered]@{}
$sgl['Signal'] = Dv 'GetItem' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@$sid"; '$select' = 'crdr_externalid,crdr_title,crdr_products,crdr_summary,crdr_actionrequired,crdr_keydate,crdr_lastchanged,crdr_genericimpact,crdr_nature' })
$sgl['Fingerprints'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signalfingerprints'; '$select' = 'crdr_group,crdr_name'; '$orderby' = 'crdr_group asc,crdr_name asc'
        '$filter' = "@concat('_crdr_signal_value eq ', $sid, ' and crdr_status eq $($fpStatus.accepted)')" }) (After 'Signal')
$kd = "body('Signal')?['crdr_keydate']"
$sgl['Action_text'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Fingerprints'); inputs = "@if(not(equals(body('Signal')?['crdr_actionrequired'], true)), 'no', if(empty($kd), 'yes, no date given', if(less(ticks(startOfDay($kd)), ticks(startOfDay(utcNow()))), concat('yes, overdue since ', formatDateTime($kd, 'yyyy-MM-dd')), concat('yes, by ', formatDateTime($kd, 'yyyy-MM-dd')))))" }
$sgl['Action_bonus'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Action_text'); inputs = "@and(equals(body('Signal')?['crdr_actionrequired'], true), not(empty($kd)), lessOrEquals(div(sub(ticks(startOfDay($kd)), ticks(startOfDay(utcNow()))), 864000000000), 30))" }

$src = [ordered]@{}
$src['Src_rows'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Rows')"; where = "@and(equals(item()?['signal'], $sid), equals(item()?['source'], ${srcI}?['o']))" } }
$src['Existing'] = [ordered]@{ type = 'Query'; runAfter = (After 'Src_rows'); inputs = @{ from = "@body('Assessments')?['value']"; where = "@and(equals(item()?['_crdr_signal_value'], $sid), equals(item()?['crdr_source'], ${srcI}?['o']))" } }

$work = [ordered]@{}
# Distinct assets (an asset can carry several exposure rows) and distinct setting keys.
$work['Asset_rows'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Src_rows')"; where = "@not(empty(item()?['asset']))" } }
$work['Asset_shapes'] = [ordered]@{ type = 'Select'; runAfter = (After 'Asset_rows'); inputs = @{ from = "@body('Asset_rows')"; select = [ordered]@{ asset = "@item()?['asset']"; type = "@item()?['type']"; env = "@item()?['env']" } } }
$work['Assets'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Asset_shapes'); inputs = "@union(body('Asset_shapes'), body('Asset_shapes'))" }
$work['Setting_rows'] = [ordered]@{ type = 'Query'; runAfter = (After 'Assets'); inputs = @{ from = "@body('Src_rows')"; where = "@empty(item()?['asset'])" } }
$work['Setting_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Setting_rows'); inputs = @{ from = "@body('Setting_rows')"; select = "@item()?['setting']" } }
$work['Settings_sorted'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Setting_names'); inputs = "@sort(union(body('Setting_names'), body('Setting_names')))" }
$work['Env_list'] = [ordered]@{ type = 'Select'; runAfter = (After 'Settings_sorted'); inputs = @{ from = "@outputs('Assets')"; select = "@item()?['env']" } }
$work['Env_tokens'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Env_list'); inputs = "@concat('|', join(body('Env_list'), '||'), '|')" }   # count of e = occurrences of |e|
$na = "length(outputs('Assets'))"; $ns = "length(outputs('Settings_sorted'))"
$work['Counts'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Env_tokens'); inputs = [ordered]@{ assets = "@$na"; settings = "@$ns"
        unknown = "@sub(length(split(outputs('Env_tokens'), '|unknown|')), 1)"; production = "@contains(outputs('Env_tokens'), '|production|')" } }
# Type lines: one per display type, sorted by count descending then name, with environments in a fixed order.
$work['Reset_type_lines'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Counts'); inputs = @{ name = 'TypeLines'; value = @() } }
$work['Type_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Reset_type_lines'); inputs = @{ from = "@outputs('Assets')"; select = "@item()?['type']" } }
$tI = "items('Each_type')"
$envParts = (@($schema.choices.environmenttype) + 'unknown' | ForEach-Object {
        $label = if ($_ -eq 'unknown') { 'environment unknown' } else { $_ }
        "if(greater(sub(length(split(outputs('Type_env_tokens'), '|$_|')), 1), 0), concat(', $label ', string(sub(length(split(outputs('Type_env_tokens'), '|$_|')), 1))), '')" }) -join ', '
$typeLoop = [ordered]@{}
$typeLoop['Type_assets'] = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@outputs('Assets')"; where = "@equals(item()?['type'], $tI)" } }
$typeLoop['Type_envs'] = [ordered]@{ type = 'Select'; runAfter = (After 'Type_assets'); inputs = @{ from = "@body('Type_assets')"; select = "@item()?['env']" } }
$typeLoop['Type_env_tokens'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Type_envs'); inputs = "@concat('|', join(body('Type_envs'), '||'), '|')" }
$typeLoop['Type_env_text'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Type_env_tokens'); inputs = "@substring(concat($envParts), 2)" }
$typeLoop['Add_type_line'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Type_env_text'); inputs = @{ name = 'TypeLines'; value = [ordered]@{
            k = "@concat(string(sub(100000, length(body('Type_assets')))), '|', $tI)"; line = "@concat('- ', $tI, ': ', string(length(body('Type_assets'))), ' (', outputs('Type_env_text'), ')')" } } }
$work['Each_type'] = [ordered]@{ type = 'Foreach'; foreach = "@union(body('Type_names'), body('Type_names'))"; runAfter = (After 'Type_names'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $typeLoop }
$work['Type_lines'] = [ordered]@{ type = 'Select'; runAfter = (After 'Each_type'); inputs = @{ from = "@if(empty(variables('TypeLines')), variables('TypeLines'), sort(variables('TypeLines'), 'k'))"; select = "@item()?['line']" } }
# Matched on: the accepted fingerprint groups that produced a counted exposure, in group order, facets as stored.
$work['Reset_group_texts'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Type_lines'); inputs = @{ name = 'GroupTexts'; value = @() } }
$work['Group_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Reset_group_texts'); inputs = @{ from = "@body('Src_rows')"; select = "@item()?['group']" } }
$gI = "items('Each_used_group')"
$work['Each_used_group'] = [ordered]@{ type = 'Foreach'; foreach = "@sort(union(body('Group_names'), body('Group_names')))"; runAfter = (After 'Group_names'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
    actions = [ordered]@{
        Group_fps = [ordered]@{ type = 'Query'; runAfter = @{}; inputs = @{ from = "@body('Fingerprints')?['value']"; where = "@equals(item()?['crdr_group'], $gI)" } }
        Group_fp_names = [ordered]@{ type = 'Select'; runAfter = (After 'Group_fps'); inputs = @{ from = "@body('Group_fps')"; select = "@item()?['crdr_name']" } }
        Has_fps = [ordered]@{ type = 'If'; runAfter = (After 'Group_fp_names'); expression = @{ equals = @("@empty(body('Group_fp_names'))", $false) }
            actions = @{ Add_group_text = @{ type = 'AppendToArrayVariable'; runAfter = @{}; inputs = @{ name = 'GroupTexts'; value = "@concat('group ', $gI, ' (', join(body('Group_fp_names'), ' + '), ')')" } } }
            else = @{ actions = @{} } } } }
$plural = { param($n, $w) "concat(string($n), ' $w', if(equals($n, 1), '', 's'))" }
$affected = "if(and(equals($na, 0), equals($ns, 0)), 'none', concat(if(greater($na, 0), $(& $plural $na 'asset'), ''), if(and(greater($na, 0), greater($ns, 0)), ', ', ''), if(greater($ns, 0), $(& $plural $ns 'tenant setting'), '')))"
$work['Summary'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Each_used_group'); inputs = "@concat('Estate: ', ${srcI}?['n'], $nl, 'Affected: ', $affected, if(empty(body('Type_lines')), '', concat($nl, join(body('Type_lines'), $nl))), if(empty(variables('GroupTexts')), '', concat($nl, 'Matched on: ', join(variables('GroupTexts'), '; '))), if(equals($ns, 0), '', concat($nl, 'Tenant settings not in place: ', join(outputs('Settings_sorted'), ', '))), $nl, 'Action required: ', outputs('Action_text'))" }
$ex1 = "first(body('Existing'))"
$work['Needs_prompt'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Summary'); inputs = "@or(empty(body('Existing')), not(equals(coalesce(${ex1}?['crdr_exposuresummary'], ''), outputs('Summary'))), equals(string(coalesce(${ex1}?['crdr_genericimpact'], '')), ''), greater(ticks(coalesce(body('Signal')?['crdr_lastchanged'], '1900-01-01T00:00:00Z')), ticks(coalesce(${ex1}?['crdr_assessedon'], '1900-01-01T00:00:00Z'))))" }
function Score([string]$g) { "min($asMax, max(1, add(add($g, if(outputs('Counts')?['production'], 1, 0)), if(outputs('Action_bonus'), 1, 0))))" }
$scoreFields = [ordered]@{ 'item/crdr_affectedcount' = "@add($na, $ns)"; 'item/crdr_unknownenvcount' = "@outputs('Counts')?['unknown']"; 'item/crdr_productionbonus' = "@outputs('Counts')?['production']"; 'item/crdr_actionbonus' = "@outputs('Action_bonus')"; 'item/crdr_exposuresummary' = "@outputs('Summary')" }
# Prompt path
$pr = [ordered]@{}
$pr['Run_assessment_prompt'] = [ordered]@{ type = 'OpenApiConnection'; runAfter = @{}
    inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_commondataserviceforapps'; operationId = 'aibuilderpredict_customprompt'; apiId = $dvApi }
        parameters = [ordered]@{ recordId = "$($ownPrompts.assessment.id)"
            item = [ordered]@{ version = '2.0'
                requestv2 = [ordered]@{ '@@odata.type' = '#Microsoft.Dynamics.CRM.expando'; Title = "@body('Signal')?['crdr_title']"; Products = "@coalesce(body('Signal')?['crdr_products'], '')"; Body = "@coalesce(body('Signal')?['crdr_summary'], '')"; Exposure = "@outputs('Summary')" }
                source = "@concat('{""consumptionSource"":""PowerAutomate"",""partnerSource"":""AIBuilder"",""consumptionSourceVersion"":""Flow"",""partnerSourceVersion"":""', workflow()?['name'], '""}')" } }
        authentication = $auth } }
$po = "outputs('Run_assessment_prompt')?['body/responsev2/predictionOutput']"
$pr['Answer'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Run_assessment_prompt'); inputs = "@coalesce(${po}?['structuredOutput'], json(coalesce(${po}?['text'], '{}')))" }
$pr['Add_prompt_tokens'] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Answer'); inputs = @{ name = 'Tokens'; value = "@add(int(coalesce(${po}?['promptTokens'], 0)), int(coalesce(${po}?['completionTokens'], 0)))" } }
$pr['Generic_value'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Add_prompt_tokens'); inputs = "@coalesce($(JsonLit ([ordered]@{ none = 0; low = 1; medium = 2; high = 3; critical = 4 }))?[toLower(coalesce(outputs('Answer')?['genericImpact'], ''))], -1)" }
$natureKey = "toLower(coalesce(outputs('Answer')?['nature'], ''))"
$pr['Valid'] = [ordered]@{ type = 'If'; runAfter = (After 'Generic_value'); expression = @{ and = @(@{ greaterOrEquals = @("@outputs('Generic_value')", 0) }, @{ not = @{ equals = @("@string(coalesce($(JsonLit $natOpt)?[$natureKey], ''))", '') } }) }
    actions = [ordered]@{
        Prompt_fields = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = [ordered]@{
                genericimpact = "@coalesce(body('Signal')?['crdr_genericimpact'], add($base, outputs('Generic_value')))"; estateimpact = "@add($base, $(Score "sub(coalesce(body('Signal')?['crdr_genericimpact'], add($base, outputs('Generic_value'))), $base)"))"; nature = "@coalesce(body('Signal')?['crdr_nature'], $(JsonLit $natOpt)?[$natureKey])"
                rationale = "@$(Trunc "string(coalesce(outputs('Answer')?['rationale'], ''))" 10000)"; action = "@$(Trunc "string(coalesce(outputs('Answer')?['recommendedAction'], ''))" 4000)"
                model = "@$(Trunc $asPrompt 100)" } }
        Is_new_assessment = [ordered]@{ type = 'If'; runAfter = (After 'Prompt_fields'); expression = @{ equals = @("@empty(body('Existing'))", $true) }
            actions = @{ Create_assessment = Dv 'CreateRecord' (([ordered]@{ entityName = 'crdr_assessments'
                        'item/crdr_name' = "@$(Trunc "concat(body('Signal')?['crdr_externalid'], ' | ', ${srcI}?['n'])" 400)"; 'item/crdr_signal@odata.bind' = "@concat('/crdr_signals(', $sid, ')')"; 'item/crdr_source' = "@${srcI}?['o']"
                        'item/crdr_genericimpact' = "@outputs('Prompt_fields')?['genericimpact']"; 'item/crdr_estateimpact' = "@outputs('Prompt_fields')?['estateimpact']"; 'item/crdr_nature' = "@outputs('Prompt_fields')?['nature']"
                        'item/crdr_rationale' = "@outputs('Prompt_fields')?['rationale']"; 'item/crdr_recommendedaction' = "@outputs('Prompt_fields')?['action']"; 'item/crdr_model' = "@outputs('Prompt_fields')?['model']"; 'item/crdr_assessedon' = '@utcNow()' }) + $scoreFields) }
            else = @{ actions = @{ Update_assessed = Dv 'UpdateRecord' (([ordered]@{ entityName = 'crdr_assessments'; recordId = "@${ex1}?['crdr_assessmentid']"
                            'item/crdr_genericimpact' = "@outputs('Prompt_fields')?['genericimpact']"; 'item/crdr_estateimpact' = "@outputs('Prompt_fields')?['estateimpact']"; 'item/crdr_nature' = "@outputs('Prompt_fields')?['nature']"
                            'item/crdr_rationale' = "@outputs('Prompt_fields')?['rationale']"; 'item/crdr_recommendedaction' = "@outputs('Prompt_fields')?['action']"; 'item/crdr_model' = "@outputs('Prompt_fields')?['model']"; 'item/crdr_assessedon' = '@utcNow()' }) + $scoreFields) } } }
        Count_prompted = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Is_new_assessment'); inputs = @{ name = 'Prompted'; value = 1 } } }
    else = @{ actions = @{ Count_invalid = @{ type = 'IncrementVariable'; runAfter = @{}; inputs = @{ name = 'Invalid'; value = 1 } } } } }
# Rescore path: inputs unchanged, so keep the prompt's answer and recompute the score (the action date can move it).
$rs = [ordered]@{}
$rs['Rescore'] = Dv 'UpdateRecord' (([ordered]@{ entityName = 'crdr_assessments'; recordId = "@${ex1}?['crdr_assessmentid']"; 'item/crdr_estateimpact' = "@add($base, $(Score "sub(coalesce(body('Signal')?['crdr_genericimpact'], ${ex1}?['crdr_genericimpact']), $base)"))"; 'item/crdr_genericimpact' = "@coalesce(body('Signal')?['crdr_genericimpact'], ${ex1}?['crdr_genericimpact'])" }) + $scoreFields)
$rs['Count_rescored'] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Rescore'); inputs = @{ name = 'Rescored'; value = 1 } }
# assessment_max_per_run (install test finding 15; engine Get-AssessmentStep, tests/config/config.json): at the cap a signal
# that needs the prompt is DEFERRED with nothing written, so it is prompted on a later run. It never falls through to rescore,
# which would store the new summary and stop it ever being prompted. Rescoring calls no prompt and is never capped.
$assessMax = "outputs('Cap_assess')"
$underCap = "or(lessOrEquals($assessMax, 0), less(variables('Prompted'), $assessMax))"
$capGate = [ordered]@{ Under_cap = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ equals = @("@$underCap", $true) }; actions = $pr
        else = @{ actions = @{ Count_deferred = @{ type = 'IncrementVariable'; runAfter = @{}; inputs = @{ name = 'Deferred'; value = 1 } } } } } }
$work['Prompt_or_rescore'] = [ordered]@{ type = 'If'; runAfter = (After 'Needs_prompt'); expression = @{ equals = @("@outputs('Needs_prompt')", $true) }; actions = $capGate; else = @{ actions = $rs } }

$clear = [ordered]@{
    Clear = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_assessments'; recordId = "@${ex1}?['crdr_assessmentid']"; 'item/crdr_estateimpact' = $impOpt['none']; 'item/crdr_affectedcount' = 0; 'item/crdr_unknownenvcount' = 0; 'item/crdr_productionbonus' = $false; 'item/crdr_actionbonus' = $false })
    Count_cleared = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Clear'); inputs = @{ name = 'Cleared'; value = 1 } } }
$src['Exposed_or_cleared'] = [ordered]@{ type = 'If'; runAfter = (After 'Existing'); expression = @{ equals = @("@empty(body('Src_rows'))", $false) }; actions = $work
    else = @{ actions = [ordered]@{ Had_assessment = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ equals = @("@empty(body('Existing'))", $false) }; actions = $clear; else = @{ actions = @{} } } } } }
# demo_data off (ADR 0022): the synthetic source is not assessed, so no credits are spent on demo data.
$srcNoDemo = @($srcOpts | Where-Object { $_.n -ne 'synthetic' })
$sgl['Each_source'] = [ordered]@{ type = 'Foreach'; foreach = "@if($(DemoOff 'Config_demo'), $(JsonLit $srcNoDemo), $(JsonLit $srcOpts))"; runAfter = (After 'Action_bonus'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $src }
$sgl['Count_signal'] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Each_source'); inputs = @{ name = 'Signals'; value = 1 } }
# Signal-level rating (ADR 0012): in-scope signals (exposed, Now, Imminent, or key date within 183 days; not service
# health) that are unrated or changed since rated get generic impact, nature and the opportunity lens from the prompt
# in signal-only mode. Estate assessments below reuse the signal's generic impact and nature.
$impTypeOpt = [ordered]@{}; foreach ($v in $schema.choices.impacttype) { $impTypeOpt[$v] = Get-Opt 'impacttype' $v }
$themeList = JsonLit @(Import-Csv (Join-Path $PSScriptRoot '..' '..' '..' 'seed' 'themes.csv') | ForEach-Object theme)
# Signals from unrated feeds are never rated (ADR 0018, ADR 0019).
$as['Unrated_feeds'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_feeds'; '$select' = 'crdr_feedid'; '$filter' = 'crdr_unrated eq true' }) (After 'Rows')
$as['Unrated_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Unrated_feeds'); inputs = @{ from = "@body('Unrated_feeds')?['value']"; select = "@item()?['crdr_feedid']" } }
$as['Rate_list'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signals'; '$select' = 'crdr_signalid,crdr_title,crdr_products,crdr_summary,crdr_horizon,crdr_keydate,crdr_lastchanged,crdr_ratedon,_crdr_feed_value'
        '$filter' = "statecode eq 0 and crdr_source ne $(Get-Opt 'signalsource' 'graph_health')" }) (After 'Unrated_ids') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$rk = "item()?['crdr_keydate']"
$inScope = "or(contains(outputs('Signal_ids'), item()?['crdr_signalid']), equals(item()?['crdr_horizon'], $($hz.now)), equals(item()?['crdr_horizon'], $($hz.imminent)), and(not(empty($rk)), greaterOrEquals(ticks(startOfDay($rk)), ticks(startOfDay(utcNow()))), lessOrEquals(ticks(startOfDay($rk)), ticks(addDays(startOfDay(utcNow()), 183)))))"
$stale = "or(empty(item()?['crdr_ratedon']), greater(ticks(coalesce(item()?['crdr_lastchanged'], '1900-01-01T00:00:00Z')), ticks(item()?['crdr_ratedon'])))"
# rating_scope 'all' rates every active signal except service health once (ADR 0012 addendum, Simon 2026-11-22: 500-credit cap);
# 'window' (the default) keeps the rating window. rating_max_per_run caps prompt calls per run (0 = no cap).
$rateAll = "equals(toLower(trim(coalesce(first(body('Config_scope'))?['crdr_value'], '$($config['rating_scope'])'))), 'all')"
$as['To_rate'] = [ordered]@{ type = 'Query'; runAfter = (After 'Rate_list'); inputs = @{ from = "@body('Rate_list')?['value']"; where = "@and(not(contains(body('Unrated_ids'), coalesce(item()?['_crdr_feed_value'], ''))), or($rateAll, $inScope), $stale)" } }
$rateMax = "outputs('Cap_rate')"
$as['Rate_capped'] = [ordered]@{ type = 'Compose'; runAfter = (After 'To_rate'); inputs = "@if(greater($rateMax, 0), take(body('To_rate'), $rateMax), body('To_rate'))" }
$ri = "items('Each_rate')"
$rate = [ordered]@{}
$rate['Rate_prompt'] = [ordered]@{ type = 'OpenApiConnection'; runAfter = @{}
    inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_commondataserviceforapps'; operationId = 'aibuilderpredict_customprompt'; apiId = $dvApi }
        parameters = [ordered]@{ recordId = "$($ownPrompts.assessment.id)"
            item = [ordered]@{ version = '2.0'
                requestv2 = [ordered]@{ '@@odata.type' = '#Microsoft.Dynamics.CRM.expando'; Title = "@${ri}?['crdr_title']"; Products = "@coalesce(${ri}?['crdr_products'], '')"; Body = "@coalesce(${ri}?['crdr_summary'], '')"; Exposure = 'Not assessed against an estate.' }
                source = "@concat('{""consumptionSource"":""PowerAutomate"",""partnerSource"":""AIBuilder"",""consumptionSourceVersion"":""Flow"",""partnerSourceVersion"":""', workflow()?['name'], '""}')" } }
        authentication = $auth } }
$ro = "outputs('Rate_prompt')?['body/responsev2/predictionOutput']"
$rate['Rate_answer'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Rate_prompt'); inputs = "@coalesce(${ro}?['structuredOutput'], json(coalesce(${ro}?['text'], '{}')))" }
$rate['Rate_tokens'] = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Rate_answer'); inputs = @{ name = 'Tokens'; value = "@add(int(coalesce(${ro}?['promptTokens'], 0)), int(coalesce(${ro}?['completionTokens'], 0)))" } }
$ra = "outputs('Rate_answer')"
$rg = "$(JsonLit ([ordered]@{ none = 0; low = 1; medium = 2; high = 3; critical = 4 }))?[toLower(string(coalesce(${ra}?['genericImpact'], '')))]"
$rn = "$(JsonLit $natOpt)?[toLower(string(coalesce(${ra}?['nature'], '')))]"
$rt = "$(JsonLit $impTypeOpt)?[toLower(string(coalesce(${ra}?['impactType'], '')))]"
$rateValid = "and(not(equals(string(coalesce($rg, '')), '')), not(equals(string(coalesce($rn, '')), '')), not(equals(string(coalesce($rt, '')), '')), contains($themeList, string(coalesce(${ra}?['theme'], ''))))"
$rate['Rate_valid'] = [ordered]@{ type = 'If'; runAfter = (After 'Rate_tokens'); expression = @{ equals = @("@$rateValid", $true) }
    actions = [ordered]@{
        Save_rating = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@${ri}?['crdr_signalid']"
                'item/crdr_genericimpact' = "@add($base, $rg)"; 'item/crdr_nature' = "@$rn"; 'item/crdr_impacttype' = "@$rt"
                'item/crdr_risk' = "@$(Trunc "string(coalesce(${ra}?['risk'], ''))" 1000)"; 'item/crdr_opportunity' = "@$(Trunc "string(coalesce(${ra}?['opportunity'], ''))" 1000)"
                'item/crdr_audience' = "@$(Trunc "string(coalesce(${ra}?['audience'], ''))" 200)"; 'item/crdr_theme' = "@${ra}?['theme']"
                'item/crdr_ratingconfidence' = "@$(Trunc "toLower(string(coalesce(${ra}?['confidence'], '')))" 20)"; 'item/crdr_ratedon' = '@utcNow()' })
        Count_rated = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Save_rating'); inputs = @{ name = 'Rated'; value = 1 } } }
    else = @{ actions = @{ Count_rate_invalid = @{ type = 'IncrementVariable'; runAfter = @{}; inputs = @{ name = 'Invalid'; value = 1 } } } } }
$as['Each_rate'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Rate_capped')"; runAfter = (After 'Rate_capped'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $rate }
$as['Each_assess_signal'] = [ordered]@{ type = 'Foreach'; foreach = "@outputs('Signal_ids')"; runAfter = (After 'Each_rate'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $sgl }
# Rule themes (ADR 0012 addendum, 2026-11-22; engine Get-RuleTheme): seed/theme-rules.csv, checked against themes.csv
# here. Runs after rating so a rule theme always wins; only signals whose theme differs are written.
Import-Module (Join-Path $PSScriptRoot '..' '..' '..' 'engine' 'ChangeRadar.Assessment.psm1') -Force
$themeRules = Import-ThemeRules -Rules @(Import-Csv (Join-Path $PSScriptRoot '..' '..' '..' 'seed' 'theme-rules.csv')) -Themes @(Import-Csv (Join-Path $PSScriptRoot '..' '..' '..' 'seed' 'themes.csv') | ForEach-Object theme) -Natures @($schema.choices.nature)
$ruleRows = @($themeRules | ForEach-Object {
        $t = $_.theme.Replace("'", "''")
        $match = if ($_.match -ceq 'source') { "crdr_source eq $(Get-Opt 'signalsource' $_.value)" } else { "crdr_feed/crdr_key eq '$($_.value.Replace("'", "''"))'" }
        [ordered]@{ theme = $_.theme; filter = "statecode eq 0 and $match and (crdr_theme eq null or crdr_theme ne '$t')" } })
$rt = [ordered]@{}
$rt['Rule_signals'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signals'; '$select' = 'crdr_signalid'; '$filter' = "@items('Each_theme_rule')?['filter']" }) @{} @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$rt['Each_rule_signal'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Rule_signals')?['value']"; runAfter = (After 'Rule_signals'); runtimeConfiguration = @{ concurrency = @{ repetitions = 4 } }
    actions = [ordered]@{
        Save_rule_theme = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@items('Each_rule_signal')?['crdr_signalid']"; 'item/crdr_theme' = "@items('Each_theme_rule')?['theme']" })
        Count_themed = [ordered]@{ type = 'IncrementVariable'; runAfter = (After 'Save_rule_theme'); inputs = @{ name = 'Themed'; value = 1 } } } }
# Nature rules (ADR 0013 step 5; engine Get-RuleNature): a model retirement with automatic migration is a behaviour
# change, without one breaking. After rating, so the rule wins; only signals whose nature differs are written.
$natureRows = @($themeRules | Where-Object { $_.PSObject.Properties['nature'] -and $_.nature } | ForEach-Object {
        $opt = Get-Opt 'nature' $_.nature
        $match = if ($_.match -ceq 'source') { "crdr_source eq $(Get-Opt 'signalsource' $_.value)" } else { "crdr_feed/crdr_key eq '$($_.value.Replace("'", "''"))'" }
        [ordered]@{ nature = $opt; filter = "statecode eq 0 and $match and (crdr_nature eq null or crdr_nature ne $opt)" } })
$nr = [ordered]@{}
$nr['Nature_signals'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signals'; '$select' = 'crdr_signalid'; '$filter' = "@items('Each_nature_rule')?['filter']" }) @{} @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$nr['Each_nature_signal'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Nature_signals')?['value']"; runAfter = (After 'Nature_signals'); runtimeConfiguration = @{ concurrency = @{ repetitions = 4 } }
    actions = [ordered]@{ Save_rule_nature = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@items('Each_nature_signal')?['crdr_signalid']"; 'item/crdr_nature' = "@items('Each_nature_rule')?['nature']" }) } }
$as['Each_nature_rule'] = [ordered]@{ type = 'Foreach'; foreach = "@json('$((ConvertTo-Json @($natureRows) -Compress -Depth 5).Replace("'", "''"))')"; runAfter = (After 'Each_theme_rule'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $nr }
$as['Each_theme_rule'] = [ordered]@{ type = 'Foreach'; foreach = "@json('$((ConvertTo-Json @($ruleRows) -Compress -Depth 5).Replace("'", "''"))')"; runAfter = (After 'Each_assess_signal'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $rt }
$asActions['Collect'] = [ordered]@{ type = 'Scope'; runAfter = (After 'Init_GroupTexts'); actions = $as }
$asOk = "equals(actions('Collect')?['status'], 'Succeeded')"
$asActions['Record_run'] = Dv 'CreateRecord' ([ordered]@{
        entityName = 'crdr_collectionruns'
        'item/crdr_name' = "@$(Trunc "concat('assess ', formatDateTime(trigger()?['startTime'], 'yyyy-MM-dd HH:mm'), if($asOk, ': ', ': FAILED: '), 'rated ', string(variables('Rated')), ', signals ', string(variables('Signals')), ', prompted ', string(variables('Prompted')), ' rescored ', string(variables('Rescored')), ' deferred ', string(variables('Deferred')), ' cleared ', string(variables('Cleared')), ' invalid ', string(variables('Invalid')), ', rule themes ', string(variables('Themed')), ', tokens ', string(variables('Tokens')))" 200)"
        'item/crdr_collector' = 'assess'; 'item/crdr_accesstier' = $tier.full; 'item/crdr_startedon' = "@trigger()?['startTime']"
        'item/crdr_itemcount' = "@if($asOk, add(variables('Prompted'), variables('Rescored')), 0)"
        'item/crdr_gaps' = "@if($asOk, concat('Prompt ''', $asPrompt, '''. Only signals with open exposures are assessed (ADR 0010). Invalid prompt answers are skipped and retried on the next run. Signals over assessment_max_per_run are deferred to the next run. Caps this run: rating ', string(outputs('Cap_rate')), ', assessment ', string(outputs('Cap_assess')), ' (0 = none).'), concat('Collect scope: ', actions('Collect')?['status'], '. Check the prompt exists (assessment_prompt_name) and Copilot credit capacity.'))"
    }) (After 'Collect' $allStates)
$asActions['Fail_if_collect_failed'] = [ordered]@{ type = 'If'; runAfter = (After 'Record_run' $allStates)
    expression = @{ not = @{ equals = @("@actions('Collect')?['status']", 'Succeeded') } }
    actions = @{ Terminate = @{ type = 'Terminate'; runAfter = @{}; inputs = @{ runStatus = 'Failed'; runError = @{ code = 'CollectFailed'; message = 'Assessment failed: see the Collect scope and the crdr_collectionrun row.' } } } }
    else = @{ actions = @{} } }
$flows['AssessSignals'] = New-Flow 'Change Radar: rate each exposed signal per source (generic impact from the AI hub assessment prompt + production + action date), with rationale and recommended action; never touches overrides (ADR 0010).' (Recurrence 'Day' 1 @{ hours = @('6'); minutes = @('30') }) $asActions

# ---------- Record assessment override (ADR 0010 decision 4) ----------
# When a person sets, changes or clears an override (impact or reason) on crdr_assessment, records who and when in
# crdr_overriddenby / crdr_overriddenon. Writes only those two columns, which aren't filtering columns, so it can't
# trigger itself. Trigger: Dataverse 'When a row is added, modified or deleted', change type Modified (message 3),
# scope Organization (4); message 1 and scope 4 observed in an existing pp-lab flow, 2026-11-21.
$ovTrigger = [ordered]@{ type = 'OpenApiConnectionWebhook'
    inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_commondataserviceforapps'; operationId = 'SubscribeWebhookTrigger'; apiId = $dvApi }
        parameters = [ordered]@{ 'subscriptionRequest/message' = 3; 'subscriptionRequest/entityname' = 'crdr_assessment'; 'subscriptionRequest/scope' = 4
            'subscriptionRequest/filteringattributes' = 'crdr_overrideimpact,crdr_overridereason' }
        authentication = $auth } }
$ovActions = [ordered]@{}
$ovActions['Record_who_and_when'] = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_assessments'; recordId = "@triggerOutputs()?['body/crdr_assessmentid']"
        'item/crdr_overriddenby@odata.bind' = "@concat('/systemusers(', triggerOutputs()?['body/_modifiedby_value'], ')')"; 'item/crdr_overriddenon' = '@utcNow()' })
$flows['RecordOverride'] = New-Flow 'Change Radar: when a person sets, changes or clears an assessment override, record who and when (ADR 0010).' $ovTrigger $ovActions @{} 'When_an_override_changes'

# ---------- Events (ADR 0011) ----------
# Same semantics as engine/ChangeRadar.Events.psm1. Signal events come from new crdr_signalversion rows (collectors
# record what changed); exposure and assessment events are raised inside the match, assess and override flows, which
# know the transition; deadline events come from a daily flow. Each event: name '<type> | <external id> | ...',
# compact JSON payload (externalId, estate, estateImpact, overrideImpact, effectiveImpact, changedFields, daysLeft) and
# a correlation id.
$evName = [ordered]@{}; foreach ($k in $evOpt.Keys) { $evName["$($evOpt[$k])"] = $k }
$impName = [ordered]@{}; foreach ($v in $schema.choices.impact) { $impName["$(Get-Opt 'impact' $v)"] = $v }
$impLevel = [ordered]@{}; $i = 0; foreach ($v in $schema.choices.impact) { $impLevel[$v] = $i; $i++ }
$srcName = [ordered]@{}; foreach ($v in $schema.choices.assetsource) { $srcName["$(Get-Opt 'assetsource' $v)"] = $v }
$sigSrcName = [ordered]@{}; foreach ($v in $schema.choices.signalsource) { $sigSrcName["$(Get-Opt 'signalsource' $v)"] = $v }
$impNameJ = JsonLit $impName; $srcNameJ = JsonLit $srcName; $evNameJ = JsonLit $evName; $impLevelJ = JsonLit $impLevel
function DataverseTrigger([string]$entity, [int]$message, [string]$filtering, [string]$filterExpr) {
    $p = [ordered]@{ 'subscriptionRequest/message' = $message; 'subscriptionRequest/entityname' = $entity; 'subscriptionRequest/scope' = 4 }
    if ($filtering) { $p['subscriptionRequest/filteringattributes'] = $filtering }
    if ($filterExpr) { $p['subscriptionRequest/filterexpression'] = $filterExpr }
    [ordered]@{ type = 'OpenApiConnectionWebhook'; inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_commondataserviceforapps'; operationId = 'SubscribeWebhookTrigger'; apiId = $dvApi }; parameters = $p; authentication = $auth } }
}
$unmatchedOpt = Get-Opt 'exposurestatus' 'unmatched'
$tb = { param($col) "triggerOutputs()?['body/$col']" }

# ---------- Readable text (engine ConvertTo-ReadableText), as a reusable set of actions ----------
# Plain string steps only, so malformed HTML can't fail a flow. $Names: breaks, parts, decoded, readable (action names).
$NL = "decodeUriComponent('%0A')"
# The Watch module loads the Text module itself; import it first, then Text, so both stay visible here.
Import-Module (Join-Path $PSScriptRoot '..' '..' '..' 'engine' 'ChangeRadar.Watch.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' '..' '..' 'engine' 'ChangeRadar.Text.psm1') -Force
function New-ReadableActions([string]$SourceExpr, [hashtable]$Names, [hashtable]$RunAfter) {
    $r = "replace(replace($SourceExpr, decodeUriComponent('%0D'), ' '), $NL, ' ')"
    foreach ($t in '</p>', '</li>', '</div>', '</tr>', '</h1>', '</h2>', '</h3>', '</h4>', '</h5>', '</h6>', '<br />', '<br/>', '<br>') { $r = "replace($r, '$t', $NL)" }
    $r = "replace($r, '<li>', '" + [char]0x2022 + " ')"
    $a = [ordered]@{}
    $a[$Names.breaks] = [ordered]@{ type = 'Compose'; runAfter = $RunAfter; inputs = "@$r" }
    $a[$Names.parts] = [ordered]@{ type = 'Select'; runAfter = (After $Names.breaks); inputs = @{ from = "@skip(split(outputs('$($Names.breaks)'), '<'), 1)"; select = "@if(contains(item(), '>'), join(skip(split(item(), '>'), 1), '>'), concat('<', item()))" } }   # no substring: '>' as the last character would put its start index out of range
    $dec = "concat(first(split(outputs('$($Names.breaks)'), '<')), join(body('$($Names.parts)'), ''))"
    # The engine's table (ChangeRadar.Text Get-ReadableEntities), so the two can't drift; single quotes doubled for WDL.
    $engEnt = Get-ReadableEntities; foreach ($k in $engEnt.Keys) { $dec = "replace($dec, '$k', '$($engEnt[$k].Replace("'", "''"))')" }
    $a[$Names.decoded] = [ordered]@{ type = 'Compose'; runAfter = (After $Names.parts); inputs = "@$dec" }
    $tidy = "outputs('$($Names.decoded)')"
    foreach ($n in 1..4) { $tidy = "replace($tidy, '  ', ' ')" }
    foreach ($n in 1..2) { $tidy = "replace(replace($tidy, concat(' ', $NL), $NL), concat($NL, ' '), $NL)" }
    foreach ($n in 1..3) { $tidy = "replace($tidy, concat($NL, $NL, $NL), concat($NL, $NL))" }
    $a[$Names.readable] = [ordered]@{ type = 'Compose'; runAfter = (After $Names.decoded); inputs = "@trim($tidy)" }
    $a
}
# Watch list text (engine ChangeRadar.Watch ConvertTo-WatchText): lower case, punctuation to spaces, spaces collapsed, padded.
function WatchLit([string]$c) {
    if ($c -eq "`r") { return "decodeUriComponent('%0D')" }
    if ($c -eq "`n") { return "decodeUriComponent('%0A')" }
    if ($c -eq "`t") { return "decodeUriComponent('%09')" }
    if ($c -eq [string][char]0x00A0) { return "decodeUriComponent('%C2%A0')" }
    if ($c -eq "'") { return "''''" }
    "'$c'"
}
function WatchNorm([string]$expr) {
    $x = "toLower(string($expr))"
    foreach ($c in (Get-WatchPunctuation)) { $x = "replace($x, $(WatchLit $c), ' ')" }
    foreach ($n in 1..(Get-WatchSpaceRounds)) { $x = "replace($x, '  ', ' ')" }
    "concat(' ', trim($x), ' ')"
}

# 1. Signal events, from new version rows (message 1 = added).
$ver = [ordered]@{}
$sv = & $tb '_crdr_signal_value'
$ver['Signal'] = Dv 'GetItem' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@$sv"; '$select' = 'crdr_externalid,crdr_title,crdr_source,crdr_horizon,crdr_summary,crdr_products,crdr_watched,_crdr_watch_value' })
$ver['Changed'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Signal'); inputs = "@toLower(coalesce($(& $tb 'crdr_changedfields'), ''))" }
$isHealth = "equals(body('Signal')?['crdr_source'], $(Get-Opt 'signalsource' 'graph_health'))"
$sigPayload = { [ordered]@{ externalId = "@body('Signal')?['crdr_externalid']"; title = "@body('Signal')?['crdr_title']"; source = "@$(JsonLit $sigSrcName)?[string(body('Signal')?['crdr_source'])]"; estate = $null; changedFields = "@outputs('Changed')" } }
$sigName = { param($t) "concat('$t | ', body('Signal')?['crdr_externalid'], ' | ', body('Signal')?['crdr_title'])" }
$sigCorr = { param($t) "concat('$t|', $sv, '|', $(& $tb 'crdr_signalversionid'))" }
$created = [ordered]@{}
Add-Actions $created (New-EventActions 'Raise_new' @{} 'signal.new' $sv $null $null (& $sigPayload) (& $sigCorr 'signal.new') (& $sigName 'signal.new'))
$opened = [ordered]@{}; Add-Actions $opened (New-EventActions 'Raise_opened' @{} 'incident.opened' $sv $null $null (& $sigPayload) (& $sigCorr 'incident.opened') (& $sigName 'incident.opened'))
# engine Get-RecordEvents (tests/events/derive.json derive-15 to 17): a new incident that is already over is not an opening.
$created['If_incident_opened'] = [ordered]@{ type = 'If'; runAfter = (After 'Raise_new'); expression = @{ equals = @("@and($isHealth, not(equals(body('Signal')?['crdr_horizon'], $(Get-Opt 'horizon' 'future'))))", $true) }; actions = $opened; else = @{ actions = @{} } }
$updated = [ordered]@{}
$keyChange = "or(contains(outputs('Changed'), 'title;'), contains(outputs('Changed'), 'key date;'), contains(outputs('Changed'), 'date label;'), contains(outputs('Changed'), 'action required;'))"
$chg = [ordered]@{}; Add-Actions $chg (New-EventActions 'Raise_changed' @{} 'signal.changed' $sv $null $null (& $sigPayload) (& $sigCorr 'signal.changed') (& $sigName 'signal.changed'))
$updated['If_key_change'] = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ equals = @("@$keyChange", $true) }; actions = $chg; else = @{ actions = @{} } }
$res = [ordered]@{}; Add-Actions $res (New-EventActions 'Raise_resolved' @{} 'incident.resolved' $sv $null $null (& $sigPayload) (& $sigCorr 'incident.resolved') (& $sigName 'incident.resolved'))
$updated['If_resolved'] = [ordered]@{ type = 'If'; runAfter = (After 'If_key_change'); expression = @{ equals = @("@and($isHealth, contains(outputs('Changed'), 'horizon;'), equals(body('Signal')?['crdr_horizon'], $($hz.future)))", $true) }; actions = $res; else = @{ actions = @{} } }
$ver['Created_or_updated'] = [ordered]@{ type = 'If'; runAfter = (After 'Changed'); expression = @{ equals = @("@outputs('Changed')", 'created') }; actions = $created; else = @{ actions = $updated } }
# ---------- Watch list (ADR 0015; engine ChangeRadar.Watch Get-WatchEvents) ----------
# After the signal events. Watched: a change (not the create) raises watch.updated. Not watched and never matched: the
# first active watch by name that matches puts it on the watch list (watched, watch link, watched on) and raises
# watch.matched. Not watched but with a watch link means someone switched Watched off: nothing, it is never re-added.
# Text: the title plus the readable summary, normalised as the engine does (WatchNorm); ignore phrases removed first.
$watchSet = 'crdr_watchs'   # entity set name as Dataverse makes it (no 'es'; checked in pp-lab metadata 2026-11-23)
$wSig = "body('Signal')"
Add-Actions $ver (New-ReadableActions "coalesce(${wSig}?['crdr_summary'], '')" @{ breaks = 'Watch_breaks'; parts = 'Watch_parts'; decoded = 'Watch_decoded'; readable = 'Watch_readable' } (After 'Created_or_updated'))
$ver['Watch_text'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Watch_readable'); inputs = "@$(WatchNorm "concat(coalesce(${wSig}?['crdr_title'], ''), ' ', outputs('Watch_readable'))")" }
$ver['Init_watch_text'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Watch_text'); inputs = @{ variables = @(@{ name = 'WatchText'; type = 'string'; value = "@outputs('Watch_text')" }) } }
$ver['Init_matched_id'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_watch_text'); inputs = @{ variables = @(@{ name = 'MatchedWatchId'; type = 'string'; value = '' }) } }
$ver['Init_matched_name'] = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_matched_id'); inputs = @{ variables = @(@{ name = 'MatchedWatchName'; type = 'string'; value = '' }) } }
$ver['Watches'] = Dv 'ListRecords' ([ordered]@{ entityName = $watchSet; '$select' = 'crdr_watchid,crdr_name,crdr_anyof,crdr_alsooneof,crdr_ignorephrases,crdr_products'; '$filter' = 'crdr_active eq true' }) (After 'Init_matched_name')
# Engine Format-WatchChange: the key fields in card order, or 'wording'.
$cw = Get-WatchChangeWords
$wordsExpr = "concat(" + ((@($cw.Keys) | ForEach-Object { "if(contains(outputs('Changed'), '$_'), '$($cw[$_]), ', '')" }) -join ', ') + ")"
$ver['Watch_words'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Watches'); inputs = "@$wordsExpr" }
$ver['Watch_changes'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Watch_words'); inputs = "@if(equals(outputs('Watch_words'), ''), 'wording', substring(outputs('Watch_words'), 0, sub(length(outputs('Watch_words')), 2)))" }
$w = "items('Each_watch')"
function WatchTerms([string]$name, [string]$col, [string]$runAfter) {
    $a = [ordered]@{}
    $a["${name}_terms"] = [ordered]@{ type = 'Select'; runAfter = $(if ($runAfter) { After $runAfter } else { @{} }); inputs = @{ from = "@split(coalesce(${w}?['$col'], ''), ';')"; select = "@$(WatchNorm 'item()')" } }
    $a["${name}_real"] = [ordered]@{ type = 'Query'; runAfter = (After "${name}_terms"); inputs = @{ from = "@body('${name}_terms')"; where = "@not(equals(trim(item()), ''))" } }
    $a
}
$one = [ordered]@{}
$one['Reset_text'] = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'WatchText'; value = "@outputs('Watch_text')" } }
Add-Actions $one (WatchTerms 'Ignore' 'crdr_ignorephrases' 'Reset_text')
$strip = [ordered]@{}
$strip['Strip'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@replace(variables('WatchText'), items('Each_ignore'), ' ')" }
$strip['Set_text'] = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Strip'); inputs = @{ name = 'WatchText'; value = "@outputs('Strip')" } }
$one['Each_ignore'] = [ordered]@{ type = 'Foreach'; foreach = "@body('Ignore_real')"; runAfter = (After 'Ignore_real'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $strip }
Add-Actions $one (WatchTerms 'Any' 'crdr_anyof' 'Each_ignore')
$one['Any_hits'] = [ordered]@{ type = 'Query'; runAfter = (After 'Any_real'); inputs = @{ from = "@body('Any_real')"; where = "@contains(variables('WatchText'), item())" } }
Add-Actions $one (WatchTerms 'Also' 'crdr_alsooneof' 'Any_hits')
$one['Also_hits'] = [ordered]@{ type = 'Query'; runAfter = (After 'Also_real'); inputs = @{ from = "@body('Also_real')"; where = "@contains(variables('WatchText'), item())" } }
$one['Product_terms'] = [ordered]@{ type = 'Select'; runAfter = (After 'Also_hits'); inputs = @{ from = "@split(coalesce(${w}?['crdr_products'], ''), ';')"; select = '@toLower(trim(item()))' } }
$one['Product_real'] = [ordered]@{ type = 'Query'; runAfter = (After 'Product_terms'); inputs = @{ from = "@body('Product_terms')"; where = "@not(equals(item(), ''))" } }
$one['Product_hits'] = [ordered]@{ type = 'Query'; runAfter = (After 'Product_real'); inputs = @{ from = "@body('Product_real')"; where = "@contains(toLower(coalesce(${wSig}?['crdr_products'], '')), item())" } }
$one['If_match'] = [ordered]@{ type = 'If'; runAfter = (After 'Product_hits')
    expression = @{ and = @(
            @{ greater = @("@length(body('Any_hits'))", 0) },
            @{ equals = @("@or(equals(length(body('Also_real')), 0), greater(length(body('Also_hits')), 0))", $true) },
            @{ equals = @("@or(equals(length(body('Product_real')), 0), greater(length(body('Product_hits')), 0))", $true) }) }
    actions = [ordered]@{
        Set_matched_id = [ordered]@{ type = 'SetVariable'; runAfter = @{}; inputs = @{ name = 'MatchedWatchId'; value = "@${w}?['crdr_watchid']" } }
        Set_matched_name = [ordered]@{ type = 'SetVariable'; runAfter = (After 'Set_matched_id'); inputs = @{ name = 'MatchedWatchName'; value = "@${w}?['crdr_name']" } } }
    else = @{ actions = @{} } }
$each = [ordered]@{}
$each['If_none_yet'] = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ equals = @("@variables('MatchedWatchId')", '') }; actions = $one; else = @{ actions = @{} } }
$candidate = [ordered]@{}
$candidate['Each_watch'] = [ordered]@{ type = 'Foreach'; foreach = "@sort(coalesce(body('Watches')?['value'], json('[]')), 'crdr_name')"; runAfter = @{}; runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $each }
$matched = [ordered]@{}
$matched['Mark_watched'] = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@$sv"; 'item/crdr_watched' = $true
        "item/crdr_watch@odata.bind" = "@concat('/$watchSet(', variables('MatchedWatchId'), ')')"; 'item/crdr_watchedon' = '@utcNow()' })
$wmPayload = & $sigPayload; $wmPayload['watchName'] = "@variables('MatchedWatchName')"; $wmPayload['watchId'] = "@variables('MatchedWatchId')"
Add-Actions $matched (New-EventActions 'Raise_watch_matched' (After 'Mark_watched') 'watch.matched' $sv $null $null $wmPayload (& $sigCorr 'watch.matched') "concat('watch.matched | ', body('Signal')?['crdr_externalid'], ' | ', body('Signal')?['crdr_title'], ' | ', variables('MatchedWatchName'))")
$candidate['If_matched'] = [ordered]@{ type = 'If'; runAfter = (After 'Each_watch'); expression = @{ not = @{ equals = @("@variables('MatchedWatchId')", '') } }; actions = $matched; else = @{ actions = @{} } }
$updatedW = [ordered]@{}
$wuPayload = & $sigPayload; $wuPayload['changes'] = "@outputs('Watch_changes')"
Add-Actions $updatedW (New-EventActions 'Raise_watch_updated' @{} 'watch.updated' $sv $null $null $wuPayload (& $sigCorr 'watch.updated') "concat('watch.updated | ', body('Signal')?['crdr_externalid'], ' | ', body('Signal')?['crdr_title'], ' | ', outputs('Watch_changes'))")
$watchedBranch = [ordered]@{ If_changed = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ not = @{ equals = @("@outputs('Changed')", 'created') } }; actions = $updatedW; else = @{ actions = @{} } } }
$notWatchedBranch = [ordered]@{ If_never_matched = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ equals = @("@empty(${wSig}?['_crdr_watch_value'])", $true) }; actions = $candidate; else = @{ actions = @{} } } }
$ver['Watch_list'] = [ordered]@{ type = 'If'; runAfter = (After 'Watch_changes'); expression = @{ equals = @("@equals(${wSig}?['crdr_watched'], true)", $true) }; actions = $watchedBranch; else = @{ actions = $notWatchedBranch } }

$flows['RaiseSignalEvents'] = New-Flow 'Change Radar: raise signal.new, incident.opened, signal.changed and incident.resolved events from new signal version rows (ADR 0011), and the watch list events watch.matched and watch.updated (ADR 0015).' (DataverseTrigger 'crdr_signalversion' 1 $null $null) $ver @{} 'When_a_signal_version_is_added'

# 2. Exposure events, inside the match flow: created, or set back to New from No longer matches.
$assetLoop = $sigLoop['Each_asset_exposure'].actions
$exPayload = { param($estateExpr, $what) [ordered]@{ externalId = "@body('Signal_record')?['crdr_externalid']"; estate = "@$estateExpr"; what = "@$what" } }
$exName = { param($what) "concat('exposure.found | ', body('Signal_record')?['crdr_externalid'], ' | ', $what)" }
$assetEstate = "${srcNameJ}?[string(body('Asset_record')?['crdr_source'])]"
Add-Actions $assetLoop['Is_new_exposure'].actions (New-EventActions 'Raise_found' (After 'Count_created') 'exposure.found' $msg "body('Create_exposure')?['crdr_exposureid']" $null (& $exPayload $assetEstate "body('Asset_record')?['crdr_name']") "concat('exposure.found|', body('Create_exposure')?['crdr_exposureid'], '|', utcNow())" (& $exName "body('Asset_record')?['crdr_name']"))
$refound = [ordered]@{}; Add-Actions $refound (New-EventActions 'Raise_refound' @{} 'exposure.found' $msg "first(body('Existing_one'))?['crdr_exposureid']" $null (& $exPayload $assetEstate "body('Asset_record')?['crdr_name']") "concat('exposure.found|', first(body('Existing_one'))?['crdr_exposureid'], '|', utcNow())" (& $exName "body('Asset_record')?['crdr_name']"))
$assetLoop['Is_new_exposure']['else']['actions']['If_was_unmatched'] = [ordered]@{ type = 'If'; runAfter = (After 'Count_updated'); expression = @{ equals = @("@first(body('Existing_one'))?['crdr_status']", $unmatchedOpt) }; actions = $refound; else = @{ actions = @{} } }
$setLoop = $sigLoop['Each_setting_exposure'].actions
Add-Actions $setLoop['Is_new_setting'].actions (New-EventActions 'Raise_setting_found' (After 'Count_created_setting') 'exposure.found' $msg "body('Create_setting_exposure')?['crdr_exposureid']" $null (& $exPayload "'live'" "outputs('Setting_name')") "concat('exposure.found|', body('Create_setting_exposure')?['crdr_exposureid'], '|', utcNow())" (& $exName "outputs('Setting_name')"))
$setRefound = [ordered]@{}; Add-Actions $setRefound (New-EventActions 'Raise_setting_refound' @{} 'exposure.found' $msg "first(body('Existing_setting'))?['crdr_exposureid']" $null (& $exPayload "'live'" "outputs('Setting_name')") "concat('exposure.found|', first(body('Existing_setting'))?['crdr_exposureid'], '|', utcNow())" (& $exName "outputs('Setting_name')"))
$setLoop['Is_new_setting']['else']['actions']['If_setting_was_unmatched'] = [ordered]@{ type = 'If'; runAfter = (After 'Count_updated_setting'); expression = @{ equals = @("@first(body('Existing_setting'))?['crdr_status']", $unmatchedOpt) }; actions = $setRefound; else = @{ actions = @{} } }
# Existing exposures must carry their status (the match flow reads it already).

# 3. Assessment events, inside the assess flow (created, or estate impact changed) and the override flow.
$as['Assessments'].inputs.parameters['$select'] = 'crdr_assessmentid,_crdr_signal_value,crdr_source,crdr_exposuresummary,crdr_assessedon,crdr_genericimpact,crdr_estateimpact,crdr_overrideimpact'
$exOverride = "${impNameJ}?[string(${ex1}?['crdr_overrideimpact'])]"
$asPayload = { param($newEstateOpt) [ordered]@{ externalId = "@body('Signal')?['crdr_externalid']"; estate = "@${srcI}?['n']"; estateImpact = "@${impNameJ}?[string($newEstateOpt)]"
        overrideImpact = "@$exOverride"; effectiveImpact = "@coalesce($exOverride, ${impNameJ}?[string($newEstateOpt)])" } }
$asName = { param($newEstateOpt) "concat('assessment.rated | ', body('Signal')?['crdr_externalid'], ' | ', ${srcI}?['n'], ' | ', coalesce($exOverride, ${impNameJ}?[string($newEstateOpt)]))" }
$asCorr = { param($id) "concat('assessment.rated|', $id, '|', utcNow())" }
$changedFrom = { param($newEstateOpt) "or(empty(body('Existing')), not(equals(string(coalesce(${ex1}?['crdr_estateimpact'], '')), string($newEstateOpt))))" }
$newPrompt = "outputs('Prompt_fields')?['estateimpact']"
$newId = "coalesce(actions('Create_assessment')?['outputs']?['body']?['crdr_assessmentid'], ${ex1}?['crdr_assessmentid'])"
$rp = [ordered]@{}; Add-Actions $rp (New-EventActions 'Raise_rated' @{} 'assessment.rated' $sid $null $newId (& $asPayload $newPrompt) (& $asCorr $newId) (& $asName $newPrompt))
$pr['Valid'].actions['If_rated'] = [ordered]@{ type = 'If'; runAfter = (After 'Count_prompted'); expression = @{ equals = @("@$(& $changedFrom $newPrompt)", $true) }; actions = $rp; else = @{ actions = @{} } }
$newRescore = "add($base, $(Score "sub(coalesce(body('Signal')?['crdr_genericimpact'], ${ex1}?['crdr_genericimpact']), $base)"))"
$rr = [ordered]@{}; Add-Actions $rr (New-EventActions 'Raise_rerated' @{} 'assessment.rated' $sid $null "${ex1}?['crdr_assessmentid']" (& $asPayload $newRescore) (& $asCorr "${ex1}?['crdr_assessmentid']") (& $asName $newRescore))
$rs['If_rerated'] = [ordered]@{ type = 'If'; runAfter = (After 'Count_rescored'); expression = @{ equals = @("@$(& $changedFrom $newRescore)", $true) }; actions = $rr; else = @{ actions = @{} } }
$noneOpt = "$($impOpt['none'])"
$rc = [ordered]@{}; Add-Actions $rc (New-EventActions 'Raise_cleared' @{} 'assessment.rated' $sid $null "${ex1}?['crdr_assessmentid']" (& $asPayload $noneOpt) (& $asCorr "${ex1}?['crdr_assessmentid']") (& $asName $noneOpt))
$clear['If_was_rated'] = [ordered]@{ type = 'If'; runAfter = (After 'Count_cleared'); expression = @{ equals = @("@$(& $changedFrom $noneOpt)", $true) }; actions = $rc; else = @{ actions = @{} } }
# Override flow: every set, change or clear is an assessment.rated event.
$ovB = { param($c) "triggerOutputs()?['body/$c']" }
$ovOverride = "${impNameJ}?[string($(& $ovB 'crdr_overrideimpact'))]"; $ovEstate = "${impNameJ}?[string($(& $ovB 'crdr_estateimpact'))]"
$ovExt = "first(split($(& $ovB 'crdr_name'), ' | '))"
$ovPayload = [ordered]@{ externalId = "@$ovExt"; estate = "@${srcNameJ}?[string($(& $ovB 'crdr_source'))]"; estateImpact = "@$ovEstate"; overrideImpact = "@$ovOverride"; effectiveImpact = "@coalesce($ovOverride, $ovEstate)" }
Add-Actions $ovActions (New-EventActions 'Raise_override_rated' (After 'Record_who_and_when') 'assessment.rated' (& $ovB '_crdr_signal_value') $null (& $ovB 'crdr_assessmentid') $ovPayload "concat('assessment.rated|', $(& $ovB 'crdr_assessmentid'), '|', utcNow())" "concat('assessment.rated | ', $ovExt, ' | ', ${srcNameJ}?[string($(& $ovB 'crdr_source'))], ' | ', coalesce($ovOverride, $ovEstate), ' (override)')")

# 4. Deadline events: daily, live signals with action required and a key date deadline_days away, open live exposure.
$dlActions = [ordered]@{}
$dlActions['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' })
Add-ConfigQuery $dlActions 'Config_days' 'deadline_days'
$dlActions['Days_list'] = [ordered]@{ type = 'Select'; runAfter = (After 'Config_days'); inputs = @{ from = "@split(coalesce(first(body('Config_days'))?['crdr_value'], '$($config['deadline_days'])'), ';')"; select = '@trim(item())' } }
$dlActions['Open_live'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_exposures'; '$select' = '_crdr_signal_value'
        '$filter' = "(crdr_status eq $($exOpen.new) or crdr_status eq $($exOpen.confirmed)) and crdr_source eq $liveSource" }) (After 'Days_list') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$dlActions['Open_signal_ids'] = [ordered]@{ type = 'Select'; runAfter = (After 'Open_live'); inputs = @{ from = "@body('Open_live')?['value']"; select = "@item()?['_crdr_signal_value']" } }
$ds = "items('Each_deadline_signal')"
$dl = [ordered]@{}
$dl['Deadline_signal'] = Dv 'GetItem' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@$ds"; '$select' = 'crdr_externalid,crdr_title,crdr_actionrequired,crdr_keydate' })
$dkd = "body('Deadline_signal')?['crdr_keydate']"
$dl['Days_left'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Deadline_signal'); inputs = "@if(empty($dkd), -1, div(sub(ticks(startOfDay($dkd)), ticks(startOfDay(utcNow()))), 864000000000))" }
$dl['Deadline_corr'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Days_left'); inputs = "@concat('deadline.approaching|', $ds, '|', string(outputs('Days_left')), '|', formatDateTime(utcNow(), 'yyyy-MM-dd'))" }
$due = [ordered]@{}
$due['Already_raised'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_events'; '$select' = 'crdr_eventid'; '$top' = 1; '$filter' = "@concat('crdr_correlationid eq ''', outputs('Deadline_corr'), '''')" })
$raise = [ordered]@{}
Add-Actions $raise (New-EventActions 'Raise_deadline' @{} 'deadline.approaching' $ds $null $null ([ordered]@{ externalId = "@body('Deadline_signal')?['crdr_externalid']"; estate = 'live'; daysLeft = "@outputs('Days_left')" }) "outputs('Deadline_corr')" "concat('deadline.approaching | ', body('Deadline_signal')?['crdr_externalid'], ' | ', string(outputs('Days_left')), ' days')")
$due['If_not_raised'] = [ordered]@{ type = 'If'; runAfter = (After 'Already_raised'); expression = @{ equals = @("@empty(body('Already_raised')?['value'])", $true) }; actions = $raise; else = @{ actions = @{} } }
$dl['If_due'] = [ordered]@{ type = 'If'; runAfter = (After 'Deadline_corr'); expression = @{ equals = @("@and(equals(body('Deadline_signal')?['crdr_actionrequired'], true), contains(body('Days_list'), string(outputs('Days_left'))))", $true) }; actions = $due; else = @{ actions = @{} } }
$dlActions['Each_deadline_signal'] = [ordered]@{ type = 'Foreach'; foreach = "@union(body('Open_signal_ids'), body('Open_signal_ids'))"; runAfter = (After 'Open_signal_ids'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $dl }
$flows['RaiseDeadlineEvents'] = New-Flow 'Change Radar: raise deadline.approaching for live signals with action required whose key date is deadline_days away (ADR 0011).' (Recurrence 'Day' 1 @{ hours = @('7') }) $dlActions

# 5. Dispatcher: new event -> one queued crdr_handlerrun per matching enabled subscription (live events only).
$dpB = { param($c) "triggerOutputs()?['body/$c']" }
$dp = [ordered]@{}
$dp['Payload'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@json(coalesce($(& $dpB 'crdr_payloadjson'), '{}'))" }
$dp['Is_live'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Payload'); inputs = "@or(equals(string(coalesce(outputs('Payload')?['estate'], '')), ''), equals(outputs('Payload')?['estate'], 'live'))" }
$dp['Effective_level'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Is_live'); inputs = "@coalesce(${impLevelJ}?[toLower(string(coalesce(outputs('Payload')?['effectiveImpact'], '')))], 0)" }
$dp['Subscriptions'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_subscriptions'; '$select' = 'crdr_subscriptionid,crdr_name,crdr_handler,crdr_filterminimpact'
        '$filter' = "@concat('crdr_eventtype eq ', string($(& $dpB 'crdr_eventtype')), ' and crdr_enabled eq true')" }) (After 'Effective_level')
$sb = "items('Each_subscription')"
$dpLoop = [ordered]@{}
$dpLoop['Min_level'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@if(equals(string(coalesce(${sb}?['crdr_filterminimpact'], '')), ''), 0, sub(${sb}?['crdr_filterminimpact'], $base))" }
$dpLoop['If_passes'] = [ordered]@{ type = 'If'; runAfter = (After 'Min_level'); expression = @{ greaterOrEquals = @("@outputs('Effective_level')", "@outputs('Min_level')") }
    actions = @{ Queue_handler = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_handlerruns'; 'item/crdr_name' = "@$(Trunc "concat(${sb}?['crdr_handler'], ' | ', $(& $dpB 'crdr_name'))" 200)"
                'item/crdr_event@odata.bind' = "@concat('/crdr_events(', $(& $dpB 'crdr_eventid'), ')')"; 'item/crdr_subscription@odata.bind' = "@concat('/crdr_subscriptions(', ${sb}?['crdr_subscriptionid'], ')')"
                'item/crdr_outcome' = (Get-Opt 'handleroutcome' 'queued'); 'item/crdr_ranon' = '@utcNow()' }) }
    else = @{ actions = @{} } }
$dp['If_live'] = [ordered]@{ type = 'If'; runAfter = (After 'Subscriptions'); expression = @{ equals = @("@outputs('Is_live')", $true) }
    actions = @{ Each_subscription = [ordered]@{ type = 'Foreach'; foreach = "@body('Subscriptions')?['value']"; runAfter = @{}; actions = $dpLoop } }; else = @{ actions = @{} } }
$flows['DispatchEvents'] = New-Flow 'Change Radar: dispatch each new event to the handlers whose enabled subscriptions match, as queued crdr_handlerrun rows (live events only; ADR 0011).' (DataverseTrigger 'crdr_event' 1 $null $null) $dp @{} 'When_an_event_is_added'

# Engine Get-AssetLabel: OAI_<guid>_<Name>_... -> '<Name> (created by Copilot)'. No regex in WDL and both if() branches are evaluated,
# so the name is padded with 41 underscores (every substring stays in range) and the GUID is checked by its hyphen positions.
function AssetLabel([string]$n) {
    $p = "concat($n, '$('_' * 41)')"
    $isOai = "and(startsWith($n, 'OAI_'), equals(substring($p, 12, 1), '-'), equals(substring($p, 17, 1), '-'), equals(substring($p, 22, 1), '-'), equals(substring($p, 27, 1), '-'), equals(substring($p, 40, 1), '_'))"
    $first = "first(split(substring($p, 41), '_'))"
    "if($isOai, if(empty($first), 'Flow created by Copilot', concat($first, ' (created by Copilot)')), $n)"
}
# Capitalise the first letter; safe on an empty string.
function CapSafe([string]$x) { "concat(toUpper(take($x, 1)), substring($x, min(1, length($x))))" }

# 6. Handlers: Notify-Teams and Notify-Email (spec §7 card, links only). Where alerts go: ADR 0011 addendum
#    (engine Get-AlertDestinations). One run per event per handler; each destination is sent in its own step.
$teamsApi = '/providers/Microsoft.PowerApps/apis/shared_teams'
$outlookApi = '/providers/Microsoft.PowerApps/apis/shared_office365'
function InitArray([string]$name) { [ordered]@{ type = 'InitializeVariable'; runAfter = @{}; inputs = @{ variables = @(@{ name = $name; type = 'array'; value = @() }) } } }
# Destination parsing and email HTML, shared with setup/dev/Test-DestinationParity.ps1 (ADR 0011 addendum).
. (Join-Path $PSScriptRoot 'AlertDelivery.ps1')
function DestLabel([string]$d) { "if(equals(${d}?['kind'], 'channel'), concat('channel:', ${d}?['teamId'], '/', ${d}?['channelId']), concat(${d}?['kind'], ':', ${d}?['address']))" }
# Send to each destination of $kinds in its own step; outputs('Delivery') has sent, ok and a text for the run's detail.
# $send: the actions inside the Send scope (item: items('Each_dest')); $onSent: actions after a send succeeded, the
# first with runAfter Note_sent. Needs variable 'results' (InitArray) at the top level.
function Add-Delivery([Collections.Specialized.OrderedDictionary]$a, [hashtable]$runAfter, [string[]]$kinds, [string]$kindsText, [Collections.Specialized.OrderedDictionary]$send, [string]$errExpr, [Collections.Specialized.OrderedDictionary]$onSent) {
    $conds = @($kinds | ForEach-Object { "equals(item()?['kind'], '$_')" })
    $where = if ($conds.Count -gt 1) { "@or($($conds -join ', '))" } else { "@$($conds[0])" }
    $a['My_dests'] = [ordered]@{ type = 'Query'; runAfter = $runAfter; inputs = @{ from = "@outputs('Destinations')"; where = $where } }
    $a['Bad_dests'] = [ordered]@{ type = 'Query'; runAfter = (After 'My_dests'); inputs = @{ from = "@outputs('Destinations')"; where = "@equals(item()?['kind'], 'invalid')" } }
    $d = "items('Each_dest')"
    $loop = [ordered]@{}
    $loop['Send'] = [ordered]@{ type = 'Scope'; runAfter = @{}; actions = $send }
    $loop['Note_sent'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Send'); inputs = @{ name = 'results'; value = [ordered]@{ to = "@$(DestLabel $d)"; ok = $true; error = '' } } }
    if ($onSent) { foreach ($k in $onSent.Keys) { $loop[$k] = $onSent[$k] } }
    $loop['Note_failed'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Send' @('Failed', 'TimedOut')); inputs = @{ name = 'results'; value = [ordered]@{ to = "@$(DestLabel $d)"; ok = $false; error = "@$(Trunc "string($errExpr)" 300)" } } }
    $a['Each_dest'] = [ordered]@{ type = 'Foreach'; foreach = "@body('My_dests')"; runAfter = (After 'Bad_dests'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $loop }
    $a['Failed_sends'] = [ordered]@{ type = 'Query'; runAfter = (After 'Each_dest' $allStates); inputs = @{ from = "@variables('results')"; where = "@equals(item()?['ok'], false)" } }
    $a['Failed_text'] = [ordered]@{ type = 'Select'; runAfter = (After 'Failed_sends'); inputs = @{ from = "@body('Failed_sends')"; select = "@concat(item()?['to'], ' (', item()?['error'], ')')" } }
    $a['Bad_text'] = [ordered]@{ type = 'Select'; runAfter = (After 'Failed_text'); inputs = @{ from = "@body('Bad_dests')"; select = "@concat(item()?['entry'], ' (', item()?['reason'], ')')" } }
    $n = "length(body('My_dests'))"; $nf = "length(body('Failed_sends'))"; $sent = "sub($n, $nf)"
    $a['Delivery'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Bad_text'); inputs = [ordered]@{
            sent = "@$sent"
            ok = "@and(greater($n, 0), equals($nf, 0), empty(body('Bad_dests')))"
            text = "@concat(if(equals($n, 0), 'No $kindsText destination in alert_destinations or alert_recipient: nothing was sent.', concat('Sent to ', string($sent), ' of ', string($n), ' $kindsText destination', if(equals($n, 1), '', 's'), '.')), if(equals($nf, 0), '', concat(' Failed: ', join(body('Failed_text'), '; '), '.')), if(empty(body('Bad_dests')), '', concat(' Invalid entries in alert_destinations: ', join(body('Bad_text'), '; '), '.')))" } }
}
$dItem = "items('Each_dest')"
function TeamsSend([string]$cardExpr) {
    # chat:<upn>: the Flow bot in a 1:1 chat. channel:<team id>/<channel id>: the Flow bot in that channel.
    $post = { param($loc, $recip) [ordered]@{ type = 'OpenApiConnection'; runAfter = @{}
        inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_teams'; operationId = 'PostCardToConversation'; apiId = $teamsApi }
            parameters = [ordered]@{ poster = 'Flow bot'; location = $loc } + $recip + [ordered]@{ 'body/messageBody' = "@string($cardExpr)" }
            authentication = $auth } } }
    [ordered]@{ If_chat = [ordered]@{ type = 'If'; runAfter = @{}; expression = @{ equals = @("@${dItem}?['kind']", 'chat') }
        actions = @{ Post_chat = (& $post 'Chat with Flow bot' ([ordered]@{ 'body/recipient' = "@${dItem}?['address']" })) }
        else = @{ actions = @{ Post_channel = (& $post 'Channel' ([ordered]@{ 'body/recipient/groupId' = "@${dItem}?['teamId']"; 'body/recipient/channelId' = "@${dItem}?['channelId']" })) } } } }
}
$teamsErr = "coalesce(actions('Post_chat')?['outputs']?['body']?['error']?['message'], actions('Post_channel')?['outputs']?['body']?['error']?['message'], actions('Post_chat')?['error']?['message'], actions('Post_channel')?['error']?['message'], 'the post failed')"
function EmailSend([string]$subjectExpr, [string]$htmlExpr) {
    # email:<address>: Office 365 Outlook, Send an email (V2), as the owner of the crdr_outlook connection.
    [ordered]@{ Send_email = [ordered]@{ type = 'OpenApiConnection'; runAfter = @{}
        inputs = [ordered]@{ host = [ordered]@{ connectionName = 'shared_office365'; operationId = 'SendEmailV2'; apiId = $outlookApi }
            parameters = [ordered]@{ 'emailMessage/To' = "@${dItem}?['address']"; 'emailMessage/Subject' = "@$subjectExpr"; 'emailMessage/Body' = "@$htmlExpr"; 'emailMessage/Importance' = 'Normal' }
            authentication = $auth } } }
}
$emailErr = "coalesce(actions('Send_email')?['outputs']?['body']?['error']?['message'], actions('Send_email')?['outputs']?['body']?['message'], actions('Send_email')?['error']?['message'], 'the email failed')"
$destRunAfter = [ordered]@{ Config_destinations = @('Succeeded'); Config_recipient = @('Succeeded'); Config_app = @('Succeeded') }

$hrB = { param($c) "triggerOutputs()?['body/$c']" }
$runId = & $hrB 'crdr_handlerrunid'
$nt = [ordered]@{}
$nt['Init_results'] = InitArray 'results'
$nt['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' }) (After 'Init_results')
Add-ConfigQuery $nt 'Config_destinations' 'alert_destinations'
Add-ConfigQuery $nt 'Config_recipient' 'alert_recipient'
Add-ConfigQuery $nt 'Config_app' 'app_url'
Add-DestinationActions $nt "first(body('Config_destinations'))?['crdr_value']" "first(body('Config_recipient'))?['crdr_value']" $destRunAfter
$nt['Event'] = Dv 'GetItem' ([ordered]@{ entityName = 'crdr_events'; recordId = "@$(& $hrB '_crdr_event_value')"; '$select' = 'crdr_eventtype,crdr_name,crdr_payloadjson,_crdr_signal_value,_crdr_assessment_value' }) (After 'Destinations')
$nt['Type'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Event'); inputs = "@${evNameJ}?[string(body('Event')?['crdr_eventtype'])]" }
$nt['Payload'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Type'); inputs = "@json(coalesce(body('Event')?['crdr_payloadjson'], '{}'))" }
$nsid = "coalesce(body('Event')?['_crdr_signal_value'], '00000000-0000-0000-0000-000000000000')"  # no signal: asset.modelchanged
$nt['Signal'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_signals'; '$top' = 1; '$select' = 'crdr_externalid,crdr_title,crdr_products,crdr_keydate,crdr_url'; '$expand' = 'crdr_feed($select=crdr_profile)'; '$filter' = "@concat('crdr_signalid eq ', $nsid)" }) (After 'Payload')
$nt['Assessment_rows'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_assessments'; '$top' = 1; '$select' = 'crdr_assessmentid,crdr_estateimpact,crdr_overrideimpact,crdr_affectedcount,crdr_recommendedaction'
        '$filter' = "@if(empty(body('Event')?['_crdr_assessment_value']), concat('_crdr_signal_value eq ', $nsid, ' and crdr_source eq $liveSource'), concat('crdr_assessmentid eq ', body('Event')?['_crdr_assessment_value']))" }) (After 'Signal')
$nt['Asset_rows'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_exposures'; '$select' = '_crdr_asset_value'; '$expand' = 'crdr_asset($select=crdr_name)'
        '$filter' = "@concat('_crdr_signal_value eq ', $nsid, ' and crdr_source eq $liveSource and (crdr_status eq $($exOpen.new) or crdr_status eq $($exOpen.confirmed)) and _crdr_asset_value ne null')" }) (After 'Assessment_rows') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
$nt['Asset_keys'] = [ordered]@{ type = 'Select'; runAfter = (After 'Asset_rows'); inputs = @{ from = "@body('Asset_rows')?['value']"; select = [ordered]@{ k = "@toLower($(AssetLabel "coalesce(item()?['crdr_asset']?['crdr_name'], '')"))"; n = "@$(AssetLabel "coalesce(item()?['crdr_asset']?['crdr_name'], '')")" } } }
$nt['Asset_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Asset_keys'); inputs = @{ from = "@if(empty(body('Asset_keys')), body('Asset_keys'), sort(body('Asset_keys'), 'k'))"; select = "@item()?['n']" } }
$A = "first(body('Assessment_rows')?['value'])"
$t = "outputs('Type')"; $title = "first(body('Signal')?['value'])?['crdr_title']"; $ext = "first(body('Signal')?['value'])?['crdr_externalid']"
$cap = { param($x) "concat(toUpper(substring($x, 0, 1)), substring($x, 1))" }
$estN = "string(coalesce(${impNameJ}?[string(${A}?['crdr_estateimpact'])], ''))"; $ovN = "string(coalesce(${impNameJ}?[string(${A}?['crdr_overrideimpact'])], ''))"
$effN = "if(equals($ovN, ''), $estN, $ovN)"
$cnt = "string(if(equals(string(coalesce(${A}?['crdr_affectedcount'], '')), ''), length(body('Asset_names')), ${A}?['crdr_affectedcount']))"
$kdS = "if(empty(first(body('Signal')?['value'])?['crdr_keydate']), '', formatDateTime(first(body('Signal')?['value'])?['crdr_keydate'], 'yyyy-MM-dd'))"
$appBase = "coalesce(first(body('Config_app'))?['crdr_value'], '')"
$sigLink = "concat($appBase, '&pagetype=entityrecord&etn=crdr_signal&id=', $nsid)"
# ADR 0017 (engine Get-AlertCard): a prompt's callers from the payload, labelled and sorted like other asset names.
$nt['Caller_keys'] = [ordered]@{ type = 'Select'; runAfter = (After 'Asset_names'); inputs = @{ from = "@coalesce(outputs('Payload')?['callers'], json('[]'))"; select = [ordered]@{ k = "@toLower($(AssetLabel "string(item())"))"; n = "@$(AssetLabel "string(item())")" } } }
$nt['Caller_names'] = [ordered]@{ type = 'Select'; runAfter = (After 'Caller_keys'); inputs = @{ from = "@if(empty(body('Caller_keys')), body('Caller_keys'), sort(body('Caller_keys'), 'k'))"; select = "@item()?['n']" } }
$nt['Fields'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Caller_names'); inputs = [ordered]@{
        heading = "@if(equals($t, 'incident.opened'), concat('Incident: ', $title), if(equals($t, 'incident.resolved'), concat('Resolved: ', $title), if(equals($t, 'assessment.rated'), concat($(& $cap $effN), ' for your estate: ', $title), concat('Action due in ', string(outputs('Payload')?['daysLeft']), ' days: ', $title))))"
        why = "@if(equals($t, 'incident.opened'), concat('Service incident affecting ', first(body('Signal')?['value'])?['crdr_products'], ' (', $ext, ').'), if(equals($t, 'incident.resolved'), concat('Service incident affecting ', first(body('Signal')?['value'])?['crdr_products'], ' (', $ext, ') is resolved.'), if(equals($t, 'assessment.rated'), concat($ext, ' affects ', $cnt, ' of your assets', if(equals($ovN, ''), '', concat(' (rated ', $(& $cap $ovN), ' by override; estate rating ', $(& $cap $estN), ')')), '.'), concat($ext, ' requires action by ', $kdS, ' and affects ', $cnt, ' of your assets.'))))"
        assets = "@take(body('Asset_names'), 5)"
        more = "@max(0, sub(length(body('Asset_names')), 5))"
        keyDate = "@$kdS"
        action = "@if(equals($t, 'incident.opened'), 'Follow the incident in the Microsoft 365 admin centre and tell affected users.', if(equals($t, 'incident.resolved'), 'No action needed. Check the post-incident report in the admin centre if users were affected.', if(equals($t, 'assessment.rated'), string(coalesce(${A}?['crdr_recommendedaction'], '')), if(equals(string(coalesce(${A}?['crdr_recommendedaction'], '')), ''), 'Open the signal and check the affected assets.', ${A}?['crdr_recommendedaction']))))"
        links = [ordered]@{ app = "@if(equals($t, 'assessment.rated'), concat($appBase, '&pagetype=entityrecord&etn=crdr_assessment&id=', ${A}?['crdr_assessmentid']), $sigLink)"; source = "@coalesce(first(body('Signal')?['value'])?['crdr_url'], '')" } } }
# asset.modelchanged (ADR 0013, engine Get-AlertCard): no signal; heading, why, assets, action and link from the payload.
$mc = "equals($t, 'asset.modelchanged')"
$P = "outputs('Payload')"
$mcName = AssetLabel "string(coalesce(${P}?['assetName'], ''))"
$nc = "length(body('Caller_names'))"
$mcAll = "union(createArray($mcName), body('Caller_names'))"
$mcFields = [ordered]@{
    heading = "concat('Model changed: ', $mcName, ' now uses ', string(${P}?['toModel']))"
    why = "concat('The ', string(${P}?['assetType']), ' ', $mcName, ' in ', string(${P}?['environmentName']), ' moved from ', string(${P}?['fromModel']), ' to ', string(${P}?['toModel']), ' without anyone editing it. Its answers may differ.', if(equals($nc, 1), ' 1 flow calls it, so its results may change too.', if(greater($nc, 1), concat(' ', string($nc), ' flows call it, so their results may change too.'), '')))"
    assets = "take($mcAll, 5)"
    action = "if(equals($nc, 0), 'Re-test it with your usual questions and check its answers before people notice a change.', concat('Re-test it and the ', if(equals($nc, 1), 'flow that calls', 'flows that call'), ' it with your usual inputs, and check the results before people notice a change.'))"
}
# ADR 0013 step 5 (engine Get-AlertCard): the feed profile's migrationNote follows the why line on rating and deadline cards.
$note = "string(coalesce(json(coalesce(first(body('Signal')?['value'])?['crdr_feed']?['crdr_profile'], '{}'))?['migrationNote'], ''))"
$nt['Fields'].inputs['why'] = "@concat($($nt['Fields'].inputs['why'].Substring(1)), if(and(or(equals($t, 'assessment.rated'), equals($t, 'deadline.approaching')), not(equals($note, ''))), concat(' ', $note), ''))"
foreach ($k in $mcFields.Keys) { $nt['Fields'].inputs[$k] = "@if($mc, $($mcFields[$k]), $($nt['Fields'].inputs[$k].Substring(1)))" }
$nt['Fields'].inputs['more'] = "@if($mc, max(0, sub(length($mcAll), 5)), $($nt['Fields'].inputs['more'].Substring(1)))"
# ADR 0015 (engine Get-AlertCard): watch list cards. The signal's live exposures and the signal link work as on other cards.
$wm = "equals($t, 'watch.matched')"; $wu = "equals($t, 'watch.updated')"
$watchFields = [ordered]@{
    heading = @("concat('On your watch list: ', $title)", "concat('Watched item updated: ', $title)")
    why     = @("concat($ext, ' matches your watch $([char]0x201C)', string(${P}?['watchName']), '$([char]0x201D). Changes to it will be sent too.')", "concat($ext, ' changed: ', string(${P}?['changes']), '.')")
    action  = @("'Read it in Change Radar. To stop following it, switch Watched off on the signal.'", "'Open it in Change Radar to see what changed.'")
}
foreach ($k in $watchFields.Keys) { $nt['Fields'].inputs[$k] = "@if($wm, $($watchFields[$k][0]), if($wu, $($watchFields[$k][1]), $($nt['Fields'].inputs[$k].Substring(1))))" }
$nt['Fields'].inputs['links']['app'] = "@if($mc, concat($appBase, '&pagetype=entityrecord&etn=crdr_asset&id=', string(${P}?['assetId'])), $($nt['Fields'].inputs['links']['app'].Substring(1)))"
$f = "outputs('Fields')"
function Fact([string]$title, [string]$valueExpr) { "addProperty(addProperty(json('{}'), 'title', '$title'), 'value', $valueExpr)" }
function OpenUrl([string]$title, [string]$urlExpr) { "addProperty(addProperty(addProperty(json('{}'), 'type', 'Action.OpenUrl'), 'title', '$title'), 'url', $urlExpr)" }
$affectedFact = "if(equals(length(${f}?['assets']), 0), json('[]'), createArray($(Fact 'Affected' "concat(join(${f}?['assets'], ', '), if(greater(${f}?['more'], 0), concat(' and ', string(${f}?['more']), ' more'), ''))")))"
$footer = AlertFooter $t
# Notify-Email shares every step up to Fields (the same objects; none is changed after this point).
$alertCore = [ordered]@{}; foreach ($k in $nt.Keys) { $alertCore[$k] = $nt[$k] }
$nt['Card'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Fields'); inputs = [ordered]@{
        type = 'AdaptiveCard'; '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; version = '1.4'
        body = @(
            [ordered]@{ type = 'TextBlock'; text = "@${f}?['heading']"; weight = 'Bolder'; size = 'Medium'; wrap = $true }
            [ordered]@{ type = 'TextBlock'; text = "@${f}?['why']"; wrap = $true }
            [ordered]@{ type = 'FactSet'; facts = "@union(createArray($(Fact 'Key date' "if(equals(${f}?['keyDate'], ''), 'none', ${f}?['keyDate'])")), $affectedFact)" }
            [ordered]@{ type = 'TextBlock'; text = 'Recommended action'; weight = 'Bolder'; spacing = 'Medium' }
            [ordered]@{ type = 'TextBlock'; text = "@${f}?['action']"; wrap = $true }
            [ordered]@{ type = 'TextBlock'; text = "@$footer"; isSubtle = $true; size = 'Small'; wrap = $true })
        actions = "@if(equals(${f}?['links']?['source'], ''), createArray($(OpenUrl 'Open in Change Radar' "${f}?['links']?['app']")), createArray($(OpenUrl 'Open in Change Radar' "${f}?['links']?['app']"), $(OpenUrl 'Open source' "${f}?['links']?['source']")))" } }
# The alert log needs a signal: a model-change card is recorded on its handler run only. One row per destination sent.
function LogAlertOnSent([string]$channelExpr) {
    $log = Dv 'CreateRecord' ([ordered]@{ entityName = 'crdr_alertlogs'; 'item/crdr_name' = "@$(Trunc "${f}?['heading']" 200)"; 'item/crdr_signal@odata.bind' = "@concat('/crdr_signals(', $nsid, ')')"
            'item/crdr_channel' = $channelExpr; 'item/crdr_senton' = '@utcNow()'; 'item/crdr_severity' = "@if(equals($t, 'assessment.rated'), $(JsonLit $impOpt)?[$effN], null)" })
    [ordered]@{ Log_alert_if_signal = [ordered]@{ type = 'If'; runAfter = (After 'Note_sent'); expression = @{ not = @{ equals = @("@empty(body('Event')?['_crdr_signal_value'])", $true) } }
        actions = [ordered]@{ Log_alert = $log }; else = @{ actions = @{} } } }
}
function MarkRun([string]$after) {
    Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_handlerruns'; recordId = "@$runId"; 'item/crdr_outcome' = "@if(outputs('Delivery')?['ok'], $(Get-Opt 'handleroutcome' 'succeeded'), $(Get-Opt 'handleroutcome' 'failed'))"
        'item/crdr_detail' = "@$(Trunc "concat(outputs('Delivery')?['text'], ' Card: ', string($f))" 4000)"; 'item/crdr_ranon' = '@utcNow()' }) (After $after)
}
Add-Delivery $nt (After 'Card') @('chat', 'channel') 'Teams' (TeamsSend "outputs('Card')") $teamsErr (LogAlertOnSent "@if(equals(${dItem}?['kind'], 'chat'), $(Get-Opt 'alertchannel' 'teams_chat'), $(Get-Opt 'alertchannel' 'teams_channel'))")
$nt['Mark_run'] = MarkRun 'Delivery'
$flows['NotifyTeams'] = New-Flow 'Change Radar handler Notify-Teams: post the spec §7 card for a queued handler run to each chat: and channel: entry in alert_destinations (and alert_recipient) as the Flow bot, then log it. Posts only (writes = no; ADR 0011 and its addendum).' (DataverseTrigger 'crdr_handlerrun' 1 $null "startswith(crdr_name,'Notify-Teams |')") $nt @{ shared_teams = 'crdr_teams' } 'When_a_Notify_Teams_run_is_queued'

# Notify-Email (engine Get-AlertEmail): the same fields as an HTML email to each email: entry. Ships off.
$ne = [ordered]@{}; foreach ($k in $alertCore.Keys) { $ne[$k] = $alertCore[$k] }
$ne['Email_html'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Fields'); inputs = "@$(EmailHtml $f $footer)" }
Add-Delivery $ne (After 'Email_html') @('email') 'email' (EmailSend "string(${f}?['heading'])" "outputs('Email_html')") $emailErr (LogAlertOnSent (Get-Opt 'alertchannel' 'email'))
$ne['Mark_run'] = MarkRun 'Delivery'
# Handler template (ADR 0023): the contract every handler keeps, as a starting point for your own (docs/extend.md).
# Copy it, rename it 'Change Radar handler: <YourName>', change the trigger's name filter to '<YourName> |', put your work
# in the Handle scope, and add a crdr_subscription with handler = <YourName>. Ships off, with no subscriptions.
$ht = [ordered]@{}
$ht['Handle'] = [ordered]@{ type = 'Scope'; runAfter = @{}; actions = [ordered]@{
        # 1. Read the event this run is for (its type, name, payload and the records it points to).
        Event = Dv 'GetItem' ([ordered]@{ entityName = 'crdr_events'; recordId = "@$(& $hrB '_crdr_event_value')"; '$select' = 'crdr_eventtype,crdr_name,crdr_payloadjson,_crdr_signal_value,_crdr_exposure_value,_crdr_assessment_value' })
        # 2. Your work goes here. Writing outside Change Radar? Ship it off, set the subscription's writes = yes, and
        #    document what it writes, where and as whom (CLAUDE.md, spec §7). Use the event id to avoid doing it twice.
        Your_work_here = [ordered]@{ type = 'Compose'; runAfter = (After 'Event'); inputs = "@concat('Received ', body('Event')?['crdr_name'])" } } }
# 3. Record the outcome on the handler run: Succeeded with what was done, or Failed with why.
$ht['Mark_succeeded'] = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_handlerruns'; recordId = "@$runId"; 'item/crdr_outcome' = (Get-Opt 'handleroutcome' 'succeeded')
        'item/crdr_detail' = "@$(Trunc "string(outputs('Your_work_here'))" 4000)"; 'item/crdr_ranon' = '@utcNow()' }) (After 'Handle')
$ht['Mark_failed'] = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_handlerruns'; recordId = "@$runId"; 'item/crdr_outcome' = (Get-Opt 'handleroutcome' 'failed')
        'item/crdr_detail' = "@$(Trunc "concat('Failed: ', string(coalesce(first(result('Handle'))?['error']?['message'], 'see the flow run')))" 4000)"; 'item/crdr_ranon' = '@utcNow()' }) (After 'Handle' @('Failed', 'TimedOut'))
$flows['HandlerTemplate'] = New-Flow 'Change Radar handler Handler template: a starting point for your own handler (ADR 0023). Triggers on its own queued handler runs, reads the event, does its work in the Handle scope and marks the run Succeeded or Failed. Ships off, with no subscriptions; copy it rather than editing it. Writes nothing outside Change Radar.' (DataverseTrigger 'crdr_handlerrun' 1 $null "startswith(crdr_name,'Handler template |')") $ht @{} 'When_a_Handler_template_run_is_queued'

$flows['NotifyEmail'] = New-Flow 'Change Radar handler Notify-Email: email the spec §7 card for a queued handler run to each email: entry in alert_destinations, as the owner of the Office 365 Outlook connection (crdr_outlook), then log it. Sends only (writes = no; ADR 0011 addendum). Ships off, with its subscriptions disabled.' (DataverseTrigger 'crdr_handlerrun' 1 $null "startswith(crdr_name,'Notify-Email |')") $ne @{ shared_office365 = 'crdr_outlook' } 'When_a_Notify_Email_run_is_queued'

# 7. Handlers: Digest-Weekly and Digest-Email (every queued digest run since the last digest, one card or email).
function New-DigestActions([string]$handler, [bool]$email) {
    $dg = [ordered]@{}
    $dg['Init_results'] = InitArray 'results'
    $dg['List_config'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_configs'; '$select' = 'crdr_key,crdr_value' }) (After 'Init_results')
    Add-ConfigQuery $dg 'Config_destinations' 'alert_destinations'
    Add-ConfigQuery $dg 'Config_recipient' 'alert_recipient'
    Add-ConfigQuery $dg 'Config_app' 'app_url'
    Add-DestinationActions $dg "first(body('Config_destinations'))?['crdr_value']" "first(body('Config_recipient'))?['crdr_value']" $destRunAfter
    $dg['Queued'] = Dv 'ListRecords' ([ordered]@{ entityName = 'crdr_handlerruns'; '$select' = 'crdr_handlerrunid,crdr_name'; '$expand' = 'crdr_event($select=crdr_eventtype,crdr_name)'
            '$filter' = "crdr_outcome eq $(Get-Opt 'handleroutcome' 'queued') and startswith(crdr_name,'$handler |')" }) (After 'Destinations') @{ runtimeConfiguration = @{ paginationPolicy = @{ minimumItemCount = 100000 } } }
    $sections = @(@('watch.matched', 'Added to your watch list'), @('watch.updated', 'Watched items updated'), @('signal.new', 'New signals'), @('signal.changed', 'Changed signals'), @('exposure.found', 'Newly exposed assets'), @('assessment.rated', 'New or changed ratings'), @('asset.modelchanged', 'Model changes'))
    $prevD = 'Queued'; $sectionExprs = @()
    foreach ($sec in $sections) {
        $key = $sec[0].Replace('.', '_')
        $dg["Rows_$key"] = [ordered]@{ type = 'Query'; runAfter = (After $prevD); inputs = @{ from = "@body('Queued')?['value']"; where = "@equals(item()?['crdr_event']?['crdr_eventtype'], $($evOpt[$sec[0]]))" } }
        # Engine Format-DigestLine: parts after the type joined by ' · '; ratings capitalise source and rating; exposures show the asset label.
        $parts = "split(coalesce(item()?['crdr_event']?['crdr_name'], ''), ' | ')"
        $line = switch ($sec[0]) {
            'assessment.rated' { "concat('- ', coalesce(${parts}?[1], ''), ' · ', $(CapSafe "coalesce(${parts}?[2], '')"), ' · ', $(CapSafe "join(skip($parts, 3), ' · ')"))" }
            'exposure.found' { "concat('- ', coalesce(${parts}?[1], ''), ' · ', $(AssetLabel "join(skip($parts, 2), ' | ')"))" }
            'asset.modelchanged' { "concat('- ', $(AssetLabel "coalesce(${parts}?[1], '')"), ' · moved from ', coalesce(${parts}?[2], ''), ' to ', coalesce(${parts}?[3], ''))" }
            'watch.matched' { "concat('- ', coalesce(${parts}?[1], ''), ' · ', coalesce(${parts}?[2], ''), ' · watch: ', coalesce(${parts}?[3], ''))" }
            'watch.updated' { "concat('- ', coalesce(${parts}?[1], ''), ' · ', coalesce(${parts}?[2], ''), ' · changed: ', coalesce(${parts}?[3], ''))" }
            default { "concat('- ', join(skip($parts, 1), ' · '))" }
        }
        $dg["Lines_$key"] = [ordered]@{ type = 'Select'; runAfter = (After "Rows_$key"); inputs = @{ from = "@body('Rows_$key')"; select = "@$line" } }
        $dg["Unique_$key"] = [ordered]@{ type = 'Compose'; runAfter = (After "Lines_$key"); inputs = "@union(body('Lines_$key'), body('Lines_$key'))" }
        $prevD = "Unique_$key"
        $u = "outputs('Unique_$key')"
        if ($email) {
            $dg["Html_$key"] = [ordered]@{ type = 'Select'; runAfter = (After $prevD); inputs = @{ from = "@$u"; select = "@$(HtmlEsc 'item()')" } }
            $prevD = "Html_$key"
            $sectionExprs += "if(empty($u), '', concat('<p><strong>$($sec[1]) (', string(length($u)), ')</strong><br>', join(take(body('Html_$key'), 10), '<br>'), if(greater(length($u), 10), concat('<br>- and ', string(sub(length($u), 10)), ' more'), ''), '</p>'))"
        } else {
            $sectionExprs += "if(empty($u), '', concat('**$($sec[1]) (', string(length($u)), ')**', $nl, join(take($u, 10), $nl), if(greater(length($u), 10), concat($nl, '- and ', string(sub(length($u), 10)), ' more'), ''), $nl, $nl))"
        }
    }
    $appCfg = "coalesce(first(body('Config_app'))?['crdr_value'], '')"
    $intro = "concat('Your live estate, week to ', formatDateTime(utcNow(), 'yyyy-MM-dd'), '. Incidents, High and Critical ratings and deadlines were sent as they happened.')"
    $dg['Digest_text'] = [ordered]@{ type = 'Compose'; runAfter = (After $prevD); inputs = "@concat($($sectionExprs -join ', '))" }
    if ($email) {
        $dg['Digest_html'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Digest_text'); inputs = "@concat('<p><strong>Change Radar weekly digest</strong></p><p style=`"color:#666666`">', $(HtmlEsc $intro), '</p>', outputs('Digest_text'), '<p><a href=`"', $(HtmlEsc $appCfg), '`">Open Change Radar</a></p>')" }
        $last = 'Digest_html'
        $send = EmailSend "concat('Change Radar weekly digest, week to ', formatDateTime(utcNow(), 'yyyy-MM-dd'))" "outputs('Digest_html')"
        $kinds = @('email'); $kindsText = 'email'; $err = $emailErr
    } else {
        $dg['Digest_card'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Digest_text'); inputs = [ordered]@{
                type = 'AdaptiveCard'; '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; version = '1.4'
                body = @(
                    [ordered]@{ type = 'TextBlock'; text = 'Change Radar weekly digest'; weight = 'Bolder'; size = 'Medium'; wrap = $true }
                    [ordered]@{ type = 'TextBlock'; text = "@$intro"; isSubtle = $true; wrap = $true }
                    [ordered]@{ type = 'TextBlock'; text = "@outputs('Digest_text')"; wrap = $true })
                actions = "@createArray($(OpenUrl 'Open Change Radar' $appCfg))" } }
        $last = 'Digest_card'
        $send = TeamsSend "outputs('Digest_card')"
        $kinds = @('chat', 'channel'); $kindsText = 'Teams'; $err = $teamsErr
    }
    $dgSend = [ordered]@{}
    Add-Delivery $dgSend @{} $kinds $kindsText $send $err $null
    # Runs are marked included once at least one destination had the digest; otherwise they stay queued for next week.
    $dgSend['If_delivered'] = [ordered]@{ type = 'If'; runAfter = (After 'Delivery'); expression = @{ greater = @("@outputs('Delivery')?['sent']", 0) }
        actions = @{ Each_included = [ordered]@{ type = 'Foreach'; foreach = "@body('Queued')?['value']"; runAfter = @{}
                actions = @{ Mark_included = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_handlerruns'; recordId = "@items('Each_included')?['crdr_handlerrunid']"; 'item/crdr_outcome' = "@if(outputs('Delivery')?['ok'], $(Get-Opt 'handleroutcome' 'succeeded'), $(Get-Opt 'handleroutcome' 'failed'))"
                            'item/crdr_detail' = "@$(Trunc "concat('Included in the digest of ', formatDateTime(utcNow(), 'yyyy-MM-dd'), '. ', outputs('Delivery')?['text'])" 4000)"; 'item/crdr_ranon' = '@utcNow()' }) } } }
        else = @{ actions = @{} } }
    $dg['If_anything'] = [ordered]@{ type = 'If'; runAfter = (After $last); expression = @{ equals = @("@empty(body('Queued')?['value'])", $false) }; actions = $dgSend; else = @{ actions = @{} } }
    $dg
}
$digestDay = (Get-Culture).TextInfo.ToTitleCase("$($config['digest_day'])".ToLower())
$flows['DigestWeekly'] = New-Flow "Change Radar handler Digest-Weekly: every $digestDay, one card summarising the week's queued digest runs (new and changed signals, exposures, ratings) to each chat: and channel: entry in alert_destinations (and alert_recipient). Posts only (writes = no; ADR 0011 and its addendum)." (Recurrence 'Week' 1 @{ weekDays = @($digestDay); hours = @('8') }) (New-DigestActions 'Digest-Weekly' $false) @{ shared_teams = 'crdr_teams' }
$flows['DigestEmail'] = New-Flow "Change Radar handler Digest-Email: every $digestDay, the week's queued Digest-Email runs as one email to each email: entry in alert_destinations, as the owner of the Office 365 Outlook connection (crdr_outlook). Sends only (writes = no; ADR 0011 addendum). Ships off, with its subscriptions disabled." (Recurrence 'Week' 1 @{ weekDays = @($digestDay); hours = @('8') }) (New-DigestActions 'Digest-Email' $true) @{ shared_office365 = 'crdr_outlook' }

# ---------- Readable summary (engine ConvertTo-ReadableText; Simon, 2026-11-22) ----------
# Plain string steps only, so malformed HTML can't fail the flow. It writes crdr_summarytext, which isn't in its own
# filtering attributes, so it never re-triggers itself.
$rd = New-ReadableActions "coalesce(triggerOutputs()?['body/crdr_summary'], '')" @{ breaks = 'Breaks'; parts = 'Parts'; decoded = 'Decoded'; readable = 'Readable' } @{}
$rd['Write_readable'] = Dv 'UpdateRecord' ([ordered]@{ entityName = 'crdr_signals'; recordId = "@triggerOutputs()?['body/crdr_signalid']"; 'item/crdr_summarytext' = "@$(Trunc "outputs('Readable')" 20000)" }) (After 'Readable')
$flows['ReadableSummary'] = New-Flow 'Change Radar: write a readable plain-text copy of a signal''s summary (crdr_summarytext) whenever the summary is written (engine ConvertTo-ReadableText).' (DataverseTrigger 'crdr_signal' 4 'crdr_summary' $null) $rd @{} 'When_a_summary_is_written'

# ---------- write ----------
# Plain hashtables enumerate in a different order in every process (string hashing is randomised),
# so copy them into sorted ordered dictionaries; ordered dictionaries keep their authored order.
function ConvertTo-Stable($o) {
    if ($o -is [Collections.Specialized.OrderedDictionary]) { $r = [ordered]@{}; foreach ($k in $o.Keys) { $r[$k] = ConvertTo-Stable $o[$k] }; return $r }
    if ($o -is [Collections.IDictionary]) { $r = [ordered]@{}; foreach ($k in ($o.Keys | Sort-Object)) { $r[$k] = ConvertTo-Stable $o[$k] }; return $r }
    if ($o -is [Collections.IList]) { return , @($o | ForEach-Object { ConvertTo-Stable $_ }) }
    $o
}
foreach ($name in $flows.Keys) {
    $path = Join-Path $OutDir "$name.json"
    [IO.File]::WriteAllText($path, ((ConvertTo-Stable $flows[$name] | ConvertTo-Json -Depth 60) -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "wrote $path"
}
