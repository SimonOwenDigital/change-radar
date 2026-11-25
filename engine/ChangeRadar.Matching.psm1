#Requires -Version 7.0
# Change Radar local matching engine (reference implementation of spec §5).
# Reads the vocabulary, rules, config and asset signatures as data, fingerprints assets from an
# estate file, validates signal fingerprints, and returns exposures with evidence.
# Pure functions over local files: no network, no tenant access.

Set-StrictMode -Version Latest

function Read-JsonFile([string]$Path) {
    Get-Content -Raw -Path $Path | ConvertFrom-Json -DateKind String -Depth 50
}

function Get-OptionalProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value } else { return $null }
}

function Import-ModelMap {
    <# Spelling -> model id, from the model rows of the vocabulary: each row's value and its '|'-separated aliases,
       lower-cased and trimmed (ADR 0013). #>
    param([string]$SeedDir = (Join-Path $PSScriptRoot '..' 'seed'))
    $map = @{}
    foreach ($row in (Import-Csv (Join-Path $SeedDir 'vocabulary.csv') -Encoding utf8 | Where-Object facet -eq 'model')) {
        $map[$row.value.Trim().ToLowerInvariant()] = $row.value
        foreach ($a in @("$(Get-OptionalProperty $row 'aliases')" -split '\|')) { if ($a.Trim()) { $map[$a.Trim().ToLowerInvariant()] = $row.value } }
    }
    $map
}

function Get-ModelId {
    <# Canonical model id for a spelling, or $null when the vocabulary doesn't know it (a gap, never a guess). #>
    param([hashtable]$ModelMap, [AllowEmptyString()][AllowNull()][string]$Text)
    $k = "$Text".Trim().ToLowerInvariant()
    if (-not $k -or -not $ModelMap.ContainsKey($k)) { return $null }
    $ModelMap[$k]
}

function Get-PromptModelType {
    <# ADR 0013: modelParameters.modelType from a prompt's msdyn_customconfiguration, read as text because the stored
       JSON is undocumented and not always valid (tests/models/models.json promptModelTypes). $null when absent or empty. #>
    param([AllowNull()][string]$Configuration)
    if (-not $Configuration) { return $null }
    $m = [regex]::Match($Configuration, '"modelType"\s*:\s*"([^"]*)"')
    if ($m.Success -and $m.Groups[1].Value) { $m.Groups[1].Value } else { $null }
}

function Get-PromptCalls {
    <# ADR 0017: the prompt actions in a flow definition (workflow.clientdata), read as text so the detail flow can do
       exactly the same (tests/models/models.json promptCalls). After each '"operationId":"aibuilderpredict_', the
       operation is the text up to the next quote; its recordId is the first '"recordId":"' value before the next
       '"operationId":"'. A recordId is a prompt id only when it doesn't start with '@' and is 36 characters in 5 parts
       separated by '-' (lower-cased); otherwise the prompt is chosen at run time and promptId is $null. #>
    param([AllowNull()][string]$ClientData)
    if (-not $ClientData) { return }
    $parts = $ClientData -split [regex]::Escape('"operationId":"aibuilderpredict_')
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $op = $parts[$i].Split('"')[0]
        $seg = ($parts[$i] -split [regex]::Escape('"operationId":"'))[0]
        $key = '"recordId":"'; $at = $seg.IndexOf($key, [StringComparison]::Ordinal)
        $rid = if ($at -ge 0) { $seg.Substring($at + $key.Length).Split('"')[0] } else { '' }
        $id = if (-not $rid.StartsWith('@') -and $rid.Length -eq 36 -and $rid.Split('-').Count -eq 5) { $rid.ToLowerInvariant() } else { $null }
        [pscustomobject]@{ operation = $op; promptId = $id }
    }
}

function Import-MatchingContext {
    <# Loads seed data into one context object. #>
    [CmdletBinding()]
    param([string]$SeedDir = (Join-Path $PSScriptRoot '..' 'seed'))
    $vocab = @{}
    foreach ($row in (Import-Csv (Join-Path $SeedDir 'vocabulary.csv'))) {
        if (-not $vocab.ContainsKey($row.facet)) { $vocab[$row.facet] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$vocab[$row.facet].Add($row.value)
    }
    $rules = @(Import-Csv (Join-Path $SeedDir 'rules.csv') | Where-Object { $_.active -eq 'true' })
    $config = @{}
    foreach ($row in (Import-Csv (Join-Path $SeedDir 'config.csv'))) { $config[$row.key] = $row.value }
    [pscustomobject]@{
        Models     = Import-ModelMap -SeedDir $SeedDir
        Vocabulary = $vocab
        Rules      = $rules
        Config     = $config
        Signatures = Read-JsonFile (Join-Path $SeedDir 'asset-signatures.json')
        Threshold  = [double]$config['fingerprint_confidence_threshold']
    }
}

function Merge-Estate {
    <# Appends the arrays of a fragment onto a base estate (used by tests). Meta comes from the base. #>
    param($Base, $Fragment)
    $merged = [ordered]@{ schemaVersion = $Base.schemaVersion; meta = $Base.meta }
    foreach ($key in 'environments', 'principals', 'inventory', 'codeComponents', 'connectorDefinitions', 'agentKit', 'flowActivity', 'tenantSettings', 'promptCalls') {
        $merged[$key] = @(@(Get-OptionalProperty $Base $key) + @(Get-OptionalProperty $Fragment $key) | Where-Object { $null -ne $_ })
    }
    [pscustomobject]$merged
}

function Assert-SingleSource($Estate) {
    $sources = @(@($Estate.meta.source) | Select-Object -Unique)
    if ($sources.Count -ne 1 -or [string]::IsNullOrWhiteSpace($sources[0])) {
        throw "Estate must carry exactly one meta.source (live, fixture or synthetic); found: $($sources -join ', '). Live and synthetic assets are never mixed (spec §15.2)."
    }
    if ($sources[0] -ne 'live' -and [string]::IsNullOrWhiteSpace((Get-OptionalProperty $Estate.meta 'syntheticOrg'))) {
        throw "Non-live estates must name their synthetic organisation (meta.syntheticOrg)."
    }
}

function Get-AssetFingerprints {
    <# Returns one object per inventory resource with facets and the evidence for each. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Estate, [Parameter(Mandatory)] $Context)
    Assert-SingleSource $Estate
    $sig = $Context.Signatures
    $envById = @{}; foreach ($e in @(Get-OptionalProperty $Estate 'environments') | Where-Object { $_ }) { $envById[$e.name] = $e }
    $principalById = @{}; foreach ($pr in @(Get-OptionalProperty $Estate 'principals') | Where-Object { $_ }) { $principalById[$pr.id] = $pr }
    $codeByRes = @{}; foreach ($c in @(Get-OptionalProperty $Estate 'codeComponents') | Where-Object { $_ }) { if (-not $codeByRes[$c.resourceId]) { $codeByRes[$c.resourceId] = @() }; $codeByRes[$c.resourceId] += $c }
    $defByRes = @{}; foreach ($d in @(Get-OptionalProperty $Estate 'connectorDefinitions') | Where-Object { $_ }) { $defByRes[$d.resourceId] = $d }
    $kitByRes = @{}; foreach ($k in @(Get-OptionalProperty $Estate 'agentKit') | Where-Object { $_ }) { $kitByRes[$k.resourceId] = $k }
    # ADR 0017: prompt calls read from flow definitions; promptId is the prompt's inventory name, $null when chosen at run time.
    $callsByRes = [ordered]@{}; foreach ($pc in @(Get-OptionalProperty $Estate 'promptCalls') | Where-Object { $_ }) { if (-not $callsByRes.Contains($pc.resourceId)) { $callsByRes[$pc.resourceId] = [Collections.Generic.List[object]]::new() }; $callsByRes[$pc.resourceId].Add($pc) }
    $promptByName = @{}; foreach ($pr in @($Estate.inventory | Where-Object { $_.type -eq 'microsoft.aibuilder/prompts' })) { $promptByName[$pr.name] = $pr }
    $customConnectorIds = @($Estate.inventory | Where-Object { $_.type -eq 'microsoft.powerplatformconnector/connectors' -and (Get-OptionalProperty $_.properties 'isCustom') } | ForEach-Object name)

    foreach ($r in $Estate.inventory) {
        $p = $r.properties
        $facets = [System.Collections.Generic.List[object]]::new()
        function Add-Facet([string]$facet, [string]$value, [string]$evidence) {
            $facets.Add([pscustomobject]@{ facet = $facet; value = $value; evidence = $evidence })
        }

        # product
        $createdIn = Get-OptionalProperty $p 'createdIn'
        if ($r.type -eq 'microsoft.copilotstudio/agents' -and $createdIn -and (@($sig.agentBuilderCreatedIn) -contains $createdIn)) {
            Add-Facet 'product' $sig.agentBuilderProduct "inventory.properties.createdIn = '$createdIn'"
        } else {
            foreach ($prod in @(Get-OptionalProperty $sig.productByType $r.type)) { if ($prod) { Add-Facet 'product' $prod "inventory.type = '$($r.type)'" } }
        }
        # resource type
        $rt = Get-OptionalProperty $sig.resourceTypeByType $r.type
        if ($rt) { Add-Facet 'resource_type' $rt "inventory.type = '$($r.type)'" }
        # environment type
        $env = $envById[(Get-OptionalProperty $p 'environmentId')]
        $envType = $null
        if ($env) {
            # Live inventory calls it environmentType (verified 2026-11-19); environmentSku is the pre-verification name, still accepted.
            $envField = (Get-OptionalProperty $env.properties 'environmentType') ? 'environmentType' : 'environmentSku'
            $envValue = Get-OptionalProperty $env.properties $envField
            $envType = Get-OptionalProperty $sig.environmentTypeBySku $envValue
            if ($envType) { Add-Facet 'environment_type' $envType "environments[$($env.name)].properties.$envField = '$envValue'" }
        }
        # connectors
        $connectorIds = @(@(Get-OptionalProperty $p 'powerPlatformConnectors') | Where-Object { $_ } | ForEach-Object connectorId)
        foreach ($cid in $connectorIds) {
            Add-Facet 'connector' $cid "inventory.properties.powerPlatformConnectors[].connectorId = '$cid'"
            if ($customConnectorIds -contains $cid) { Add-Facet 'connector' 'custom' "connector '$cid' is a custom connector in inventory" }
        }
        # harness
        $harness = Get-OptionalProperty $p 'harness'
        if ($harness) {
            $hv = Get-OptionalProperty $sig.harnessByValue $harness
            if ($hv) { Add-Facet 'harness' $hv "inventory.properties.harness = '$harness'" }
        }
        # model (ADR 0013): the inventory's display name mapped to its vocabulary id; an unknown name adds nothing
        $modelName = Get-OptionalProperty $p 'model'
        if ($modelName -and $Context.PSObject.Properties['Models']) {
            $mid = Get-ModelId $Context.Models $modelName
            if ($mid) { Add-Facet 'model' $mid "inventory.properties.model = '$modelName'" }
        }
        # Prompt callers (ADR 0017): capability ai_prompt for any AI Builder action, and the model of each prompt it calls
        # by id whose model is known: one facet per model, the evidence naming the first prompt (definition order) on it.
        # Evidence starts 'flow definition: ', which marks facets the detail flow owns (the estate flow leaves them alone).
        if ($callsByRes.Contains($r.name)) {
            $calls = $callsByRes[$r.name]
            Add-Facet 'capability' 'ai_prompt' "flow definition: $((@($calls | ForEach-Object { "aibuilderpredict_$($_.operation)" }) | Select-Object -Unique) -join ', ')"
            $seenModels = @{}
            foreach ($call in $calls) {
                $prm = if ($call.promptId) { $promptByName[$call.promptId] } else { $null }
                if (-not $prm -or -not $Context.PSObject.Properties['Models']) { continue }
                $raw = Get-OptionalProperty $prm.properties 'model'
                $mid = if ($raw) { Get-ModelId $Context.Models $raw } else { $null }
                if (-not $mid -or $seenModels.ContainsKey($mid)) { continue }
                $seenModels[$mid] = $true
                Add-Facet 'model' $mid "flow definition: calls prompt '$($prm.properties.displayName)' on $raw"
            }
        }
        # capabilities
        if ($codeByRes[$r.name]) {
            Add-Facet 'capability' 'pcf_control' "codeComponents: $(@($codeByRes[$r.name] | ForEach-Object controlName) -join ', ')"
        }
        if ((Get-OptionalProperty $p 'orchestration') -eq $sig.orchestrationGenerative) {
            Add-Facet 'capability' 'generative_orchestration' "inventory.properties.orchestration = '$($sig.orchestrationGenerative)'"
        }
        $channels = @(Get-OptionalProperty $p 'channels') | Where-Object { $_ }
        $webChannels = @($channels | Where-Object { $sig.customWebChannels.values -contains $_ })
        if ($webChannels.Count -gt 0) {
            Add-Facet 'capability' 'custom_web_ui' "inventory.properties.channels contains '$($webChannels -join "', '")' [$($sig.customWebChannels.status)]"
        }
        # Live inventory: trigger = { connectorId, operationId, connectorDisplayName } (verified 2026-11-19). A plain string is the old shape.
        $trigger = Get-OptionalProperty $p 'trigger'
        $triggerOp = if ($trigger -is [string]) { Get-OptionalProperty $p 'triggerOperation' } elseif ($trigger) { Get-OptionalProperty $trigger 'operationId' } else { $null }
        if ($triggerOp -and (@($sig.scheduledPrompt.triggerOperations) -contains $triggerOp)) {
            $hit = @($connectorIds | Where-Object { $sig.scheduledPrompt.connectors -contains $_ })
            if ($hit.Count -gt 0) {
                Add-Facet 'capability' 'scheduled_prompt' "inventory.properties.trigger.operationId = '$triggerOp' and connector '$($hit[0])'"
            }
        }
        $def = $defByRes[$r.name]
        if ($def) {
            $spHosts = @($def.hosts | Where-Object { $_ -match $sig.sharePointHostPattern.pattern })
            if ($spHosts.Count -gt 0) {
                Add-Facet 'capability' 'sharepoint_tempauth' "connectorDefinitions.hosts = '$($spHosts -join "', '")' [$($sig.sharePointHostPattern.status)]"
            }
        }
        $kit = $kitByRes[$r.name]
        if ($kit) {
            foreach ($prop in $sig.agentKitCapabilities.PSObject.Properties) {
                if ((Get-OptionalProperty $kit $prop.Name) -eq $true) { Add-Facet 'capability' $prop.Value "agentKit.$($prop.Name) = true" }
            }
        }
        # Agent knowledge from native inventory (ADR 0008 addendum). No componentsCounts means not reported: no facet.
        $counts = Get-OptionalProperty $p 'componentsCounts'
        $knowledge = if ($counts) { Get-OptionalProperty $counts 'knowledge' } else { $null }
        if ($r.type -eq 'microsoft.copilotstudio/agents' -and $knowledge -and [int]$knowledge -gt 0) {
            $byType = Get-OptionalProperty $counts 'knowledgeByType'
            $types = if ($byType) { @($byType.PSObject.Properties | Where-Object { [int]$_.Value -gt 0 } | ForEach-Object { "$($_.Name) $($_.Value)" }) } else { @() }
            Add-Facet 'capability' $sig.agentKnowledge.capability "inventory.properties.componentsCounts.knowledge = $knowledge$(if ($types) { " ($($types -join ', '))" }) [$($sig.agentKnowledge.status)]"
        }
        # auth mode
        $ownerId = Get-OptionalProperty $p 'ownerId'
        $owner = if ($ownerId) { $principalById[$ownerId] } else { $null }
        if ($owner -and $owner.kind -eq 'servicePrincipal') {
            Add-Facet 'auth_mode' 'service_principal' "inventory.properties.ownerId is service principal '$($owner.displayName)'"
        } elseif ($owner -and $owner.kind -eq 'user' -and ($sig.userOwnedProduction.resourceTypes -contains $rt) -and ($sig.userOwnedProduction.environmentTypes -contains $envType)) {
            Add-Facet 'auth_mode' 'user_owned_production' "inventory.properties.ownerId is user '$($owner.displayName)' and environment type is '$envType'"
        }
        foreach ($c in @(Get-OptionalProperty $p 'powerPlatformConnectors') | Where-Object { $_ }) {
            foreach ($op in @($c.operations) | Where-Object { $_ }) {
                $provider = Get-OptionalProperty $op 'connectionProvider'
                if ($provider -eq 'Maker') { Add-Facet 'auth_mode' 'maker' "connector '$($c.connectorId)' operation '$($op.operationId)' connectionProvider = 'Maker'" }
                elseif ($provider -eq 'User') { Add-Facet 'auth_mode' 'invoker' "connector '$($c.connectorId)' operation '$($op.operationId)' connectionProvider = 'User'" }
            }
        }

        [pscustomobject]@{
            assetId         = $r.name
            name            = $p.displayName
            type            = $r.type
            environmentType = $envType
            source          = $Estate.meta.source
            syntheticOrg    = Get-OptionalProperty $Estate.meta 'syntheticOrg'
            hasAgentKit     = [bool]$kit
            # Shipped by a Microsoft publisher, e.g. a system prompt (Simon, 2026-11-22): matched and shown, never rated or alerted.
            microsoftSystem = [bool](Get-OptionalProperty $p 'microsoftSystem')
            facets          = $facets.ToArray()
        }
    }
}

function Test-SignalFingerprint {
    <# Splits fingerprint rows into accepted, rejected (outside vocabulary) and review (below threshold). #>
    param([Parameter(Mandatory)] $Signal, [Parameter(Mandatory)] $Context)
    $accepted = @(); $rejected = @(); $review = @()
    foreach ($row in $Signal.fingerprint) {
        $group = if (Get-OptionalProperty $row 'group') { $row.group } else { 'A' }
        $item = [pscustomobject]@{ group = $group; facet = $row.facet; value = $row.value; confidence = [double]$row.confidence; extractedBy = (Get-OptionalProperty $row 'extractedBy') }
        if (-not $Context.Vocabulary.ContainsKey($row.facet) -or -not $Context.Vocabulary[$row.facet].Contains([string]$row.value)) {
            $rejected += $item | Add-Member -PassThru NoteProperty reason 'value not in vocabulary'
        } elseif ($item.confidence -lt $Context.Threshold) {
            $review += $item | Add-Member -PassThru NoteProperty reason "confidence $($item.confidence) below threshold $($Context.Threshold)"
        } else {
            $accepted += $item
        }
    }
    [pscustomobject]@{ accepted = $accepted; rejected = $rejected; review = $review }
}

function Find-Exposures {
    <# Matches one signal against fingerprinted assets and tenant settings. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Signal, [Parameter(Mandatory)] $Assets, [Parameter(Mandatory)] $Estate, [Parameter(Mandatory)] $Context)
    $check = Test-SignalFingerprint -Signal $Signal -Context $Context
    $exposures = [ordered]@{}
    $settingFindings = @()
    $notes = @()
    $kitCapabilities = @($Context.Signatures.agentKitCapabilities.PSObject.Properties | ForEach-Object Value)

    foreach ($grp in ($check.accepted | Group-Object group | Sort-Object Name)) {
        $byFacet = @{}
        foreach ($row in $grp.Group) { if (-not $byFacet[$row.facet]) { $byFacet[$row.facet] = @() }; $byFacet[$row.facet] += $row.value }

        $clauses = @()
        foreach ($facet in ($byFacet.Keys | Sort-Object)) {
            $rule = $Context.Rules | Where-Object signal_facet -eq $facet | Select-Object -First 1
            if (-not $rule) { $notes += "Group $($grp.Name): no active rule for facet '$facet'; ignored."; continue }
            $clauses += [pscustomobject]@{ facet = $facet; values = $byFacet[$facet]; rule = $rule }
        }

        # Setting checks (not asset matches)
        foreach ($cl in @($clauses | Where-Object { $_.rule.role -eq 'setting' })) {
            $products = @($byFacet['product'] | Where-Object { $_ })
            foreach ($key in $cl.values) {
                $setting = @($Estate.tenantSettings | Where-Object { $_.key -eq $key -and $_.enabled -eq $true }) | Select-Object -First 1
                $covers = $setting -and ($products.Count -eq 0 -or @($products | Where-Object { @($setting.scope) -contains $_ }).Count -gt 0)
                $finding = [pscustomobject]@{
                    target   = "setting:$key"; group = $grp.Name; state = $(if ($covers) { 'present' } else { 'absent' })
                    rule     = $cl.rule.rule_id
                    evidence = $(if ($covers) { "tenantSettings[$key] enabled, scope '$(@($setting.scope) -join "', '")' covers '$($products -join "', '")'" }
                                 elseif ($setting) { "tenantSettings[$key] enabled but scope '$(@($setting.scope) -join "', '")' doesn't cover '$($products -join "', '")'" }
                                 else { "no enabled tenantSettings row for '$key'" })
                }
                $settingFindings += $finding
                if (-not $covers) {
                    $exposures["setting:$key"] = [pscustomobject]@{
                        signalId = $Signal.id; target = "setting:$key"; assetId = $null; assetName = $key; assetType = 'tenant setting'
                        environmentType = $null; source = $Estate.meta.source; group = $grp.Name; status = 'new'; matchedFacets = @('setting')
                        rules = @($cl.rule.rule_id); evidence = @([pscustomobject]@{ facet = 'setting'; value = $key; field = $finding.evidence; rule = $cl.rule.rule_id })
                    }
                }
            }
        }

        $assetClauses = @($clauses | Where-Object { $_.rule.role -in 'scope', 'trigger' })
        if (@($assetClauses | Where-Object { $_.rule.role -eq 'trigger' }).Count -eq 0) {
            if ($assetClauses.Count -gt 0) { $notes += "Group $($grp.Name): scope facets only ($(@($assetClauses.facet) -join ', ')); no asset exposures by design." }
            continue
        }
        $needsKit = @($assetClauses | Where-Object { $_.facet -eq 'capability' } | ForEach-Object values | Where-Object { $kitCapabilities -contains $_ })
        if ($needsKit.Count -gt 0) {
            $gap = @($Assets | Where-Object { $_.type -eq 'microsoft.copilotstudio/agents' -and -not $_.hasAgentKit }).Count
            if ($gap -gt 0) { $notes += "Group $($grp.Name): $gap agent(s) have no Agent Inventory (Kit) row, so '$($needsKit -join "', '")' is unknown for them and they weren't matched." }
        }

        foreach ($asset in $Assets) {
            $evidence = @()
            $ok = $true
            foreach ($cl in $assetClauses) {
                $hits = @($asset.facets | Where-Object { $_.facet -eq $cl.rule.asset_facet -and $cl.values -contains $_.value })
                if ($hits.Count -eq 0) { $ok = $false; break }
                $evidence += $hits | ForEach-Object { [pscustomobject]@{ facet = $_.facet; value = $_.value; field = $_.evidence; rule = $cl.rule.rule_id } }
            }
            if (-not $ok) { continue }
            if ($exposures.Contains($asset.assetId)) {
                $exposures[$asset.assetId].evidence += $evidence
                continue
            }
            $exposures[$asset.assetId] = [pscustomobject]@{
                signalId = $Signal.id; target = "asset:$($asset.assetId)"; assetId = $asset.assetId; assetName = $asset.name; assetType = $asset.type
                environmentType = $asset.environmentType; source = $asset.source; group = $grp.Name
                status = $(if ($asset.PSObject.Properties['microsoftSystem'] -and $asset.microsoftSystem) { 'system' } else { 'new' })
                matchedFacets = @($assetClauses.facet | Sort-Object -Unique); rules = @($assetClauses | ForEach-Object { $_.rule.rule_id })
                evidence = $evidence
            }
        }
    }

    [pscustomobject]@{
        signalId        = $Signal.id
        title           = Get-OptionalProperty $Signal 'title'
        exposures       = @($exposures.Values)
        settingFindings = $settingFindings
        rejected        = $check.rejected
        review          = $check.review
        notes           = $notes
    }
}

Export-ModuleMember -Function Read-JsonFile, Import-MatchingContext, Import-ModelMap, Get-ModelId, Get-PromptModelType, Get-PromptCalls, Merge-Estate, Assert-SingleSource, Get-AssetFingerprints, Test-SignalFingerprint, Find-Exposures
