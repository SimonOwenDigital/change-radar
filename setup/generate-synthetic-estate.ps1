#Requires -Version 7.0
<#
.SYNOPSIS
    Generates a synthetic Power Platform estate from a profile file (spec §15).

.DESCRIPTION
    Writes an estate file in the shape described in docs/estate-file-format.md, plus a
    Markdown summary of the distributions it produced. Output is fully determined by the
    profile's seed and asOf date: the script never reads the clock or the tenant.

    Every record is labelled source = synthetic with the profile's synthetic organisation.
    Nothing here talks to Microsoft services.

.EXAMPLE
    pwsh -File setup/generate-synthetic-estate.ps1 -ProfilePath setup/profiles/mid-size-enterprise.json -OutDir samples/synthetic/mid-size-enterprise
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ProfilePath,
    [Parameter(Mandatory)] [string] $OutDir,
    [int] $Seed = 0   # overrides the profile seed when non-zero
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$p = Get-Content -Raw -Path $ProfilePath | ConvertFrom-Json
$seedValue = if ($Seed -ne 0) { $Seed } else { [int]$p.seed }
$rng = [System.Random]::new($seedValue)
$asOf = [datetime]::Parse($p.asOf, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)

# ---------- deterministic helpers ----------

# Live inventory shape for a flow trigger (verified 2026-11-19): { connectorId, operationId }. Built-in triggers have no connector.
function New-Trigger([string]$connector, [string]$operation) {
    [ordered]@{ connectorId = $(if ($connector -like 'shared_*') { $connector } else { '' }); operationId = $operation }
}

function Get-R { $rng.NextDouble() }
# Agent models (ADR 0013) draw from their own stream, so adding them left every other generated value unchanged.
$modelRng = [System.Random]::new($seedValue + 1301)
function Get-AgentModel($weights) {
    $total = ($weights | Measure-Object weight -Sum).Sum; $x = $modelRng.NextDouble() * $total
    foreach ($w in $weights) { $x -= $w.weight; if ($x -le 0) { return $w.model } }
    $weights[-1].model
}
function Test-Chance([double]$p) { (Get-R) -lt $p }
function Get-Int([int]$min, [int]$maxInclusive) { $rng.Next($min, $maxInclusive + 1) }
function Get-Pick($items) { $items[$rng.Next(0, @($items).Count)] }
function Get-WeightedPick($items, [string]$weightProp = 'weight') {
    $total = ($items | Measure-Object -Property $weightProp -Sum).Sum
    $x = (Get-R) * $total
    foreach ($i in $items) { $x -= $i.$weightProp; if ($x -le 0) { return $i } }
    return $items[-1]
}
function New-Id {
    $b = [byte[]]::new(16); $rng.NextBytes($b)
    $b[7] = ($b[7] -band 0x0F) -bor 0x40   # version 4 shape
    $b[8] = ($b[8] -band 0x3F) -bor 0x80
    ([guid]::new($b)).ToString()
}
function Get-DateBack([int]$minDays, [int]$maxDays) {
    $asOf.AddDays(-(Get-Int $minDays $maxDays)).AddMinutes(-(Get-Int 0 1439)).ToString('yyyy-MM-ddTHH:mm:ssZ')
}
function Get-Placement($weights) {
    $items = foreach ($prop in $weights.PSObject.Properties) { [pscustomobject]@{ key = $prop.Name; weight = [double]$prop.Value } }
    $key = (Get-WeightedPick ($items | Where-Object weight -gt 0)).key
    Get-Pick $envByKey[$key]
}

# ---------- name pools (generic, nothing real) ----------
$nouns = 'Expense','Site inspection','Leave','Asset','Supplier','Invoice','Training','Fleet','Claims','Visitor','Shift','Incident','Contract','Budget','Onboarding','Stock','Delivery','Customer','Quote','Audit','Timesheet','Risk','Complaint','Room booking','Purchase order'
$appSuffix = 'tracker','request','app','approvals','log','register','checklist','hub','form','manager'
$flowPatterns = @(
    'Notify {0} owner on new item','Daily {0} reminder','Sync {0} to Dataverse','Archive old {0} records',
    'Send {0} approval','Weekly {0} report','Copy {0} attachments','Escalate overdue {0}')
$messyFlowNames = 'Untitled','Test flow','My flow','Copy of {0}','{0} - old','{0} (2)','DO NOT USE {0}','{0} v3 FINAL'
$agentTopics = 'IT help','HR policy','Travel','Procurement','Onboarding buddy','Customer FAQ','Sales assistant','Finance close','Safety','Fleet booking','Contract review','Knowledge finder'

function Get-MessyName([string]$base, [double]$copyShare) {
    if (Test-Chance $copyShare) { return ((Get-Pick $messyFlowNames) -f $base) }
    return $base
}

# ---------- environments ----------
$environments = [System.Collections.Generic.List[object]]::new()
$envByKey = @{}
$envSkuById = @{}
foreach ($e in $p.environments) {
    $names = if ($e.PSObject.Properties['names']) { @($e.names) } else { 1..([int]$e.count) | ForEach-Object { $e.namePattern -f $_ } }
    $envByKey[$e.key] = @()
    foreach ($n in $names) {
        $id = New-Id
        $environments.Add([ordered]@{
            name = $id; type = 'microsoft.powerplatform/environments'; location = $p.location
            properties = [ordered]@{ displayName = $n; environmentType = $e.sku; isDefault = [bool]$e.isDefault; isManaged = [bool]$e.isManaged }
        })
        $envByKey[$e.key] += $id
        $envSkuById[$id] = $e.sku
    }
}

# ---------- principals: makers with a skewed (Zipf-like) ownership weight ----------
$principals = [System.Collections.Generic.List[object]]::new()
$makers = @()
for ($i = 1; $i -le [int]$p.makers.count; $i++) {
    $id = New-Id
    $departed = Test-Chance $p.makers.departedShare
    $principals.Add([ordered]@{
        id = $id; kind = 'user'; displayName = ('Maker {0:000}' -f $i)
        userPrincipalName = ('maker{0:000}@{1}' -f $i, $p.org.domain)
        department = (Get-Pick $p.makers.departments); accountEnabled = (-not $departed)
    })
    $makers += [pscustomobject]@{ id = $id; weight = 1.0 / [math]::Pow($i, [double]$p.makers.ownershipSkew); departed = $departed }
}
$spns = @()
foreach ($s in $p.makers.servicePrincipals) {
    $id = New-Id
    $principals.Add([ordered]@{ id = $id; kind = 'servicePrincipal'; displayName = "$s (synthetic)"; userPrincipalName = $null; department = $null; accountEnabled = $true })
    $spns += $id
}
$departedById = @{}; foreach ($m in $makers) { $departedById[$m.id] = $m.departed }
function Get-Maker { (Get-WeightedPick $makers).id }

# ---------- connectors ----------
function Get-Connectors([int]$min, [int]$max, $customIds) {
    $n = Get-Int $min $max
    $chosen = [System.Collections.Generic.List[string]]::new()
    $guard = 0
    while ($chosen.Count -lt $n -and $guard -lt 50) {
        $guard++
        $c = if ($customIds.Count -gt 0 -and (Test-Chance 0.04)) { Get-Pick $customIds } else { (Get-WeightedPick $p.connectors).id }
        if (-not $chosen.Contains($c)) { $chosen.Add($c) }
    }
    , @($chosen | ForEach-Object { [ordered]@{ connectorId = $_; operations = @([ordered]@{ operationId = 'Op' + (Get-Int 1 9) }) } })
}

$inventory = [System.Collections.Generic.List[object]]::new()
$codeComponents = [System.Collections.Generic.List[object]]::new()
$connectorDefinitions = [System.Collections.Generic.List[object]]::new()
$agentKit = [System.Collections.Generic.List[object]]::new()
$flowActivity = [System.Collections.Generic.List[object]]::new()

function Add-Resource([string]$type, [string]$name, [string]$envId, [string]$owner, $extra) {
    $id = New-Id
    $created = Get-DateBack 20 1700
    $createdDt = [datetime]::Parse($created, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    $ageDays = [int]($asOf - $createdDt).TotalDays
    $props = [ordered]@{
        displayName = $name; environmentId = $envId; createdAt = $created; createdBy = $owner; ownerId = $owner
        lastModifiedAt = $asOf.AddDays(-(Get-Int 0 ([math]::Max(0, $ageDays - 1)))).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if ($extra) { foreach ($k in $extra.Keys) { $props[$k] = $extra[$k] } }
    $inventory.Add([ordered]@{ name = $id; type = $type; location = $p.location; properties = $props })
    return $id
}

# custom connectors first, so apps and flows can reference them
$customIds = @()
for ($i = 1; $i -le [int]$p.counts.customConnectors; $i++) {
    $env = Get-Placement $p.placement.customConnectors
    $isSp = Test-Chance $p.customConnectors.sharePointHostShare
    $label = if ($isSp) { "Document loader $i" } else { "Line of business API $i" }
    $id = Add-Resource 'microsoft.powerplatformconnector/connectors' "$label (custom)" $env (Get-Maker) ([ordered]@{ isCustom = $true; tier = 'Premium' })
    $hosts = if ($isSp) { @("harbourline.sharepoint.example") } else { @(Get-Pick $p.customConnectors.hosts) }
    # Live SharePoint hosts end in .sharepoint.com; the synthetic estate uses a reserved .example
    # domain but keeps the sharepoint label so the signature still fires (see asset-signatures.json).
    $connectorDefinitions.Add([ordered]@{ resourceId = $id; hosts = $hosts })
    $customIds += $id
}

# canvas, model-driven and code apps
foreach ($spec in @(
        @{ type = 'microsoft.powerapps/canvasapps'; count = $p.counts.canvasApps; place = $p.placement.canvasApps; pcf = $true },
        @{ type = 'microsoft.powerapps/modeldrivenapps'; count = $p.counts.modelDrivenApps; place = $p.placement.modelDrivenApps; pcf = $true },
        @{ type = 'microsoft.powerapps/codeapps'; count = $p.counts.codeApps; place = $p.placement.codeApps; pcf = $false })) {
    for ($i = 1; $i -le [int]$spec.count; $i++) {
        $env = Get-Placement $spec.place
        $name = Get-MessyName ("{0} {1}" -f (Get-Pick $nouns), (Get-Pick $appSuffix)) $p.apps.copyOfShare
        $id = Add-Resource $spec.type $name $env (Get-Maker) ([ordered]@{ powerPlatformConnectors = (Get-Connectors 1 4 $customIds) })
        if ($spec.pcf -and (Test-Chance $p.apps.canvasPcfShare)) {
            $codeComponents.Add([ordered]@{ resourceId = $id; controlName = ('syn_' + (Get-Pick 'ImageViewer', 'SignaturePad', 'RichGrid', 'MapPicker', 'FileViewer')) })
        }
    }
}

# cloud flows, including abandoned ones
function Add-FlowActivity([string]$id, [string]$owner) {
    $ownerDeparted = [bool]$departedById[$owner]
    $abandoned = $ownerDeparted -or (Test-Chance $p.flows.abandonedShare)
    if ($abandoned) {
        $state = if (Test-Chance ($p.flows.suspendedShare / ($p.flows.suspendedShare + $p.flows.stoppedShare + 0.25))) { 'Suspended' } elseif (Test-Chance 0.4) { 'Stopped' } else { 'Started' }
        $lastRun = if (Test-Chance 0.2) { $null } else { Get-DateBack 181 1400 }
    } else {
        $state = 'Started'; $lastRun = Get-DateBack 0 30
    }
    $flowActivity.Add([ordered]@{ resourceId = $id; state = $state; lastRunAt = $lastRun })
}

for ($i = 1; $i -le [int]$p.counts.cloudFlows; $i++) {
    $env = Get-Placement $p.placement.cloudFlows
    $trig = Get-WeightedPick $p.flows.triggers
    $owner = if ($envSkuById[$env] -eq 'Production' -and (Test-Chance $p.flows.productionServicePrincipalOwnedShare)) { Get-Pick $spns } else { Get-Maker }
    $name = Get-MessyName (((Get-Pick $flowPatterns) -f (Get-Pick $nouns).ToLowerInvariant())) 0.15
    $id = Add-Resource 'microsoft.powerautomate/cloudflows' $name $env $owner ([ordered]@{
            trigger = (New-Trigger $trig.trigger $trig.operation); powerPlatformConnectors = (Get-Connectors 1 3 $customIds) })
    Add-FlowActivity $id $owner
}

# scheduled-prompt flows (T5 placeholder signature), mostly in the default environment
for ($i = 1; $i -le [int]$p.counts.scheduledPromptFlows; $i++) {
    $env = Get-Pick $envByKey['default']
    $owner = Get-Maker
    $id = Add-Resource 'microsoft.powerautomate/cloudflows' ("Scheduled prompt: " + (Get-Pick 'Monday priorities', 'Inbox digest', 'Meeting prep', 'Project status', 'Team news')) $env $owner ([ordered]@{
            trigger = (New-Trigger 'recurrence' 'Recurrence')
            powerPlatformConnectors = @([ordered]@{ connectorId = 'shared_m365copilotautomations'; operations = @([ordered]@{ operationId = 'OfficeAIActionExecution' }) }) })
    Add-FlowActivity $id $owner
}

# agent flows (Copilot Studio) and workflow agent flows (M365 Copilot)
for ($i = 1; $i -le [int]$p.counts.agentFlows; $i++) {
    $env = Get-Placement $p.placement.agentFlows
    $owner = if ($envSkuById[$env] -eq 'Production' -and (Test-Chance 0.2)) { Get-Pick $spns } else { Get-Maker }
    $id = Add-Resource 'microsoft.powerautomate/agentflows' ("{0} agent flow" -f (Get-Pick $agentTopics)) $env $owner ([ordered]@{
            trigger = (New-Trigger 'shared_microsoftcopilotstudio' 'OnAgentInvoke'); powerPlatformConnectors = (Get-Connectors 1 3 $customIds) })
    Add-FlowActivity $id $owner
}
for ($i = 1; $i -le [int]$p.counts.workflowAgentFlows; $i++) {
    $owner = Get-Maker
    $id = Add-Resource 'microsoft.powerautomate/m365agentflows' ("{0} workflow" -f (Get-Pick $nouns)) (Get-Pick $envByKey['default']) $owner ([ordered]@{
            trigger = (New-Trigger 'manual' 'manual'); powerPlatformConnectors = (Get-Connectors 1 2 @()) })
    Add-FlowActivity $id $owner
}

# Copilot Studio agents: classic vs generative, Standard vs Microsoft Copilot harness
for ($i = 1; $i -le [int]$p.counts.copilotStudioAgents; $i++) {
    $env = Get-Placement $p.placement.copilotStudioAgents
    $generative = Test-Chance $p.agents.generativeShare
    $harness = if (Test-Chance $p.agents.microsoftCopilotHarnessShare) { 'Copilot Chat' } else { 'Standard' }
    $channels = @($p.agents.channels | Where-Object { $_ -ne 'Custom website' } | Where-Object { Test-Chance 0.35 })
    if (Test-Chance $p.agents.customWebsiteChannelShare) { $channels += 'Custom website' }
    $published = -not (Test-Chance $p.agents.unpublishedShare)
    $id = Add-Resource 'microsoft.copilotstudio/agents' ("{0} agent" -f (Get-Pick $agentTopics)) $env (Get-Maker) ([ordered]@{
            harness = $harness; orchestration = $(if ($generative) { 'Generative' } else { 'Classic' }); createdIn = 'Copilot Studio'
            channels = $(if ($published) { , $channels } else { , @() })
            lastPublishedAt = $(if ($published) { Get-DateBack 0 400 } else { $null })
            powerPlatformConnectors = (Get-Connectors 0 3 $customIds) })
    # Generative agents have a primary model; classic agents report none (tests/cases mdl-05).
    if ($generative) { $inventory[-1].properties['model'] = Get-AgentModel $(if ($harness -eq 'Standard') { $p.agents.modelsStandard } else { $p.agents.modelsMicrosoftCopilot }) }
    if (Test-Chance $p.agents.agentKitCoverage) {
        $agentKit.Add([ordered]@{
            resourceId = $id
            usesMcp = ($generative -and (Test-Chance $p.agents.mcpShareOfGenerative))
            hasAutonomousTriggers = (Test-Chance $p.agents.autonomousTriggerShare)
            hasHttpActions = (Test-Chance $p.agents.httpActionShare) })
    }
}
# Agent Builder agents: default environment, Microsoft Copilot harness, no Kit coverage
for ($i = 1; $i -le [int]$p.counts.agentBuilderAgents; $i++) {
    $null = Add-Resource 'microsoft.copilotstudio/agents' ("{0} helper" -f (Get-Pick $agentTopics)) (Get-Pick $envByKey['default']) (Get-Maker) ([ordered]@{
            harness = 'Copilot Chat'; orchestration = 'Generative'; createdIn = 'Copilot Studio Lite'; model = 'Microsoft 365 Copilot'
            channels = @('Microsoft 365 Copilot'); lastPublishedAt = (Get-DateBack 0 300); powerPlatformConnectors = (Get-Connectors 0 1 @()) })
}

# The model demo agent (ADR 0013 done-when 1): a fixed, labelled agent on the Microsoft Copilot harness and
# Claude Sonnet 4.6, so the model retirement signal shows an exposure end to end. Generated last, so it moves nothing.
foreach ($d in @($p.demoAgents)) {
    $null = Add-Resource 'microsoft.copilotstudio/agents' $d.displayName (Get-Pick $envByKey[$d.environment]) (Get-Maker) ([ordered]@{
            harness = $d.harness; orchestration = 'Generative'; createdIn = 'Copilot Studio'; model = $d.model
            channels = @($d.channels); lastPublishedAt = (Get-DateBack 0 30); powerPlatformConnectors = @() })
}

# Solutions (ADR 0020): their own random stream, so adding them moved no other generated value. Business solutions in
# the named environments, a maker solution in developer environments, rarely one in the default environment; a few
# assets are also in the shared "Core components" solution. Agent Builder agents are never in a solution.
$solutionMembership = [System.Collections.Generic.List[object]]::new()
if ($p.PSObject.Properties['solutions']) {
    $sp = $p.solutions
    $solRng = [System.Random]::new($seedValue + [int]$sp.seedOffset)
    function Get-SolutionRow([string]$display) {
        [ordered]@{ uniqueName = $sp.uniquePrefix + (($display -split '[^A-Za-z0-9]+' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')
            displayName = $display; publisher = $sp.publisher; managed = $false; microsoft = $false }
    }
    $envName = @{}; foreach ($e in $environments) { $envName[$e.name] = $e.properties.displayName }
    foreach ($r in $inventory) {
        if ($r.properties['createdIn'] -eq 'Copilot Studio Lite') { continue }
        $eid = $r.properties.environmentId; $en = $envName[$eid]
        $choices = @(if ($sp.byEnvironment.PSObject.Properties[$en]) { $sp.byEnvironment.$en })   # @(if ...): an if expression unwraps arrays
        $pick = $null
        if ($choices.Count) { if ($solRng.NextDouble() -lt [double]$sp.inSolutionShare) { $pick = $choices[$solRng.Next(0, $choices.Count)] } }
        elseif ($eid -eq $envByKey['default'][0]) { if ($solRng.NextDouble() -lt [double]$sp.defaultShare) { $pick = $sp.defaultSolution } }
        elseif (@($envByKey['dev']) -contains $eid) { if ($solRng.NextDouble() -lt [double]$sp.makerShare) { $pick = $sp.makerSolution } }
        if ($pick) { $solutionMembership.Add(([ordered]@{ resourceId = $r.name } + (Get-SolutionRow $pick))) }
        if ($choices.Count -and $solRng.NextDouble() -lt [double]$sp.sharedShare) { $solutionMembership.Add(([ordered]@{ resourceId = $r.name } + (Get-SolutionRow $sp.shared))) }
    }
}

$tenantSettings = @($p.tenantSettings | ForEach-Object { [ordered]@{ key = $_.key; enabled = $_.enabled; scope = @($_.scope); evidence = 'synthetic profile' } })

$estate = [ordered]@{
    schemaVersion = '0.2'
    meta = [ordered]@{
        source = 'synthetic'; syntheticOrg = $p.org.name; profile = $p.id; seed = $seedValue
        asOf = $asOf.ToString('yyyy-MM-ddTHH:mm:ssZ'); generator = 'setup/generate-synthetic-estate.ps1'
        notice = 'SYNTHETIC DATA. Generated from a profile; does not describe any real organisation. Never mix with live assets.'
    }
    environments = $environments; principals = $principals; inventory = $inventory
    codeComponents = $codeComponents; connectorDefinitions = $connectorDefinitions; agentKit = $agentKit
    flowActivity = $flowActivity; tenantSettings = $tenantSettings; solutionMembership = $solutionMembership
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$estatePath = Join-Path $OutDir 'estate.json'
$json = $estate | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($estatePath, ($json -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---------- distribution summary ----------
$inv = $inventory
$envDefault = $envByKey['default'][0]
$byType = $inv | Group-Object { $_.type } | Sort-Object Name
$ownerCounts = $inv | Group-Object { $_.properties.ownerId } | Sort-Object Count -Descending
$userOwned = $ownerCounts | Where-Object { $makers.id -contains $_.Name }
$top10 = ($userOwned | Select-Object -First 10 | Measure-Object Count -Sum).Sum
$userTotal = ($userOwned | Measure-Object Count -Sum).Sum
$inDefault = @($inv | Where-Object { $_.properties.environmentId -eq $envDefault }).Count
$abandoned = @($flowActivity | Where-Object { $_.state -ne 'Started' -or $null -eq $_.lastRunAt -or ([datetime]::Parse($_.lastRunAt, [Globalization.CultureInfo]::InvariantCulture) -lt $asOf.AddDays(-180)) }).Count
$departedOwned = @($inv | Where-Object { [bool]$departedById[$_.properties.ownerId] }).Count
$agents = @($inv | Where-Object type -eq 'microsoft.copilotstudio/agents')

$lines = @(
    "# Synthetic estate: $($p.org.name)", '',
    '> **Synthetic data.** Generated from a profile; it doesn''t describe any real organisation. Never mix with live assets.', '',
    "Profile ``$($p.id)``, seed $seedValue, as of $($asOf.ToString('yyyy-MM-dd')). Regenerate with:", '',
    '```powershell',
    "pwsh -File setup/generate-synthetic-estate.ps1 -ProfilePath setup/profiles/$($p.id).json -OutDir $($OutDir -replace '\\','/')",
    '```', '',
    '## Shape', '',
    '| Measure | Value |', '|---|---|',
    "| Environments | $($environments.Count) |",
    "| Principals (makers + service principals) | $($principals.Count) |",
    "| Inventory resources | $($inv.Count) |",
    "| Resources in the default environment | $inDefault ($([math]::Round(100 * $inDefault / $inv.Count))%) |",
    "| Share of user-owned resources held by the top 10 of $($makers.Count) makers | $([math]::Round(100 * $top10 / $userTotal))% |",
    "| Resources owned by departed makers (account disabled) | $departedOwned |",
    "| Flows that look abandoned (not started, never run, or no run in 180 days) | $abandoned of $($flowActivity.Count) |",
    "| Copilot Studio agents: generative / classic / Agent Builder (Copilot Studio Lite) | $(@($agents | Where-Object { $_.properties.orchestration -eq 'Generative' -and $_.properties.createdIn -ne 'Copilot Studio Lite' }).Count) / $(@($agents | Where-Object { $_.properties.orchestration -eq 'Classic' }).Count) / $(@($agents | Where-Object { $_.properties.createdIn -eq 'Copilot Studio Lite' }).Count) |",
    "| Agents with Agent Inventory (Kit) coverage | $($agentKit.Count) |",
    "| Agents using MCP (Kit) | $(@($agentKit | Where-Object usesMcp).Count) |",
    "| Apps with code components (PCF) | $($codeComponents.Count) |",
    "| Custom connectors (SharePoint-hosted) | $($connectorDefinitions.Count) ($(@($connectorDefinitions | Where-Object { $_.hosts -match 'sharepoint' }).Count)) |",
    "| Solutions / resources in at least one solution | $(@($solutionMembership | ForEach-Object { $_.uniqueName } | Sort-Object -Unique).Count) / $(@($solutionMembership | ForEach-Object { $_.resourceId } | Sort-Object -Unique).Count) |",
    '', '## Resources by type', '', '| Type | Count |', '|---|---|'
) + ($byType | ForEach-Object { "| ``$($_.Name)`` | $($_.Count) |" })
[IO.File]::WriteAllText((Join-Path $OutDir 'README.md'), (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

Write-Host "Wrote $estatePath ($($inv.Count) resources, $($environments.Count) environments, $($principals.Count) principals)"
