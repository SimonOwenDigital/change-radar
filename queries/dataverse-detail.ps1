#Requires -Version 7.0
<#
.SYNOPSIS
    Adds Dataverse component detail for one environment to a live estate file: which apps use a maker-built code component.
.DESCRIPTION
    Runs as the Change Radar reader app (application user with the read-only 'Change Radar Reader' role; ADR 0008).
    pp-lab only for now (ADR 0008 addendum, 2026-11-20). Reads, never writes:
      customcontrols                        every code component (no read privilege needed)
      solutioncomponents (type 66)          which solutions, and so which publishers, ship each control
      dependencies                          control <- form (60) <- model-driven app (80); control <- canvas app (300)
      msdyn_aimodels, msdyn_aiconfigurations  prompts and their models (ADR 0013; prvReadmsdyn_AIModel)
      workflows (type 1, clientdata)        which flows call which prompt (ADR 0017; prvReadWorkflow): only the operation
                                            and prompt id are kept (engine Get-PromptCalls), never the definition
    A control is maker-built unless one of its solutions belongs to a publisher in
    seed/asset-signatures.json pcfMicrosoftPublishers. Every control also sits in the Default solution.

    Apps match inventory by properties.appModuleId (model-driven) or name = canvasappid (canvas), both verified 2026-11-20.
    Writes codeComponents [{ resourceId, controlName, evidence }] into -EstatePath (replacing rows for this environment).

    Prompts are not in the inventory (ADR 0013). A prompt is an active msdyn_aimodel whose active run configuration
    names modelParameters.modelType (engine Get-PromptModelType); only prompt configurations carry one, so no read on
    msdyn_aitemplate is needed. Each becomes an inventory entry of Change Radar's own type microsoft.aibuilder/prompts,
    with properties.model = the modelType as stored (the engine maps it to a model id).

    Gap: a model-driven app that includes a whole table without listing its forms has no app -> form dependency,
    so a code component on that table's forms is not attributed to the app. The run summary counts such apps.
.EXAMPLE
    pwsh -File queries/inventory.ps1
    pwsh -File queries/dataverse-detail.ps1 -SubscriptionId <guid> -EnvironmentUrl https://<org>.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$EstatePath = (Join-Path ([IO.Path]::GetTempPath()) 'change-radar-live-estate.json'),
    [string]$SignaturesPath = (Join-Path $PSScriptRoot '..' 'seed' 'asset-signatures.json'),
    [string]$FixtureEstatePath = (Join-Path ([IO.Path]::GetTempPath()) 'change-radar-fixture-estate.json'),
    # Default: seed/config.csv fixture_solutions, the same list the detail flow reads from crdr_config.
    [string[]]$FixtureSolutions = @(((Import-Csv (Join-Path $PSScriptRoot '..' 'seed' 'config.csv') | Where-Object key -eq 'fixture_solutions').value -split ';') | Where-Object { $_ })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module (Join-Path $PSScriptRoot '..' 'setup' 'lib' 'ReaderIdentity.psm1') -Force
$sig = Get-Content $SignaturesPath -Raw | ConvertFrom-Json
$estate = Get-Content $EstatePath -Raw | ConvertFrom-Json -Depth 60
if ($estate.meta.source -ne 'live') { throw "Expected a live estate file (queries/inventory.ps1), got source '$($estate.meta.source)'." }

$session = New-ReaderSession -SubscriptionId $SubscriptionId
$token = $session.GetToken("$EnvironmentUrl/.default")
function Get-All([string]$Path) {
    $h = @{ Authorization = "Bearer $token"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' }
    $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Uri "$dv/$Path" -Headers $h
    while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Uri $r.'@odata.nextLink' -Headers $h }
    $rows.ToArray()   # unrolled on purpose: callers wrap in @() and foreach sees rows, not one array
}

$org = Invoke-RestMethod -Headers @{ Authorization = "Bearer $token" } -Uri "$dv/RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName' (ADR 0008: pp-lab only)." }
$envId = $org.Detail.EnvironmentId
if ($estate.meta.PSObject.Properties['detail'] -and @($estate.meta.detail | Where-Object { $_.environmentId -eq $envId })) {
    throw "This export already has Dataverse detail for $ExpectedEnvironmentName (its fixtures are already moved out). Re-run queries/inventory.ps1 first."
}

$controls = @(Get-All 'customcontrols?$select=customcontrolid,name')
$owners = @(Get-All 'solutioncomponents?$select=objectid&$filter=componenttype eq 66&$expand=solutionid($select=uniquename;$expand=publisherid($select=uniquename))')
$microsoft = @($sig.pcfMicrosoftPublishers.values)
# Maker-built: shipped by at least one real solution (not Default or Active) and by no Microsoft publisher.
# System controls have no solutioncomponent rows at all (observed 2026-11-20), so they never count.
$shipped = @{}; $byMaker = @{}
foreach ($o in $owners) {
    if ($microsoft -contains $o.solutionid.publisherid.uniquename) { $shipped[$o.objectid] = 1 }
    elseif ($o.solutionid.uniquename -notin 'Default', 'Active') { $byMaker[$o.objectid] = $o.solutionid.uniquename }
}
$maker = @($controls | Where-Object { $byMaker[$_.customcontrolid] -and -not $shipped[$_.customcontrolid] })

$appIds = @{}; foreach ($r in $estate.inventory | Where-Object { $_.properties.PSObject.Properties['environmentId']?.Value -eq $envId }) {
    $amid = if ($r.properties.PSObject.Properties['appModuleId']) { $r.properties.appModuleId } else { $null }
    if ($r.type -eq 'microsoft.powerapps/modeldrivenapps' -and $amid) { $appIds["80|$amid"] = $r.name }
    if ($r.type -eq 'microsoft.powerapps/canvasapps') { $appIds["300|$($r.name)"] = $r.name }
}
$rows = [Collections.Generic.List[object]]::new(); $unmatched = 0
foreach ($c in $maker) {
    foreach ($d in Get-All "dependencies?`$select=dependentcomponenttype,dependentcomponentobjectid&`$filter=requiredcomponentobjectid eq $($c.customcontrolid)") {
        $hits = switch ($d.dependentcomponenttype) {
            300 { @([pscustomobject]@{ key = "300|$($d.dependentcomponentobjectid)"; path = "canvas app $($d.dependentcomponentobjectid)" }) }
            60 {
                Get-All "dependencies?`$select=dependentcomponentobjectid&`$filter=requiredcomponentobjectid eq $($d.dependentcomponentobjectid) and dependentcomponenttype eq 80" |
                    ForEach-Object { [pscustomobject]@{ key = "80|$($_.dependentcomponentobjectid)"; path = "form $($d.dependentcomponentobjectid) -> app module $($_.dependentcomponentobjectid)" } }
            }
            default { @() }
        }
        foreach ($h in @($hits)) {
            if ($appIds[$h.key]) { $rows.Add([pscustomobject]@{ resourceId = $appIds[$h.key]; controlName = $c.name; evidence = "dependency: control '$($c.name)' <- $($h.path)" }) } else { $unmatched++ }
        }
    }
}
$found = @($rows | Sort-Object resourceId, controlName -Unique)
$inEnv = @($estate.inventory | Where-Object { $_.properties.PSObject.Properties['environmentId']?.Value -eq $envId } | ForEach-Object name)
$kept = @(@($estate.PSObject.Properties['codeComponents'] ? $estate.codeComponents : @()) | Where-Object { $_ -and $inEnv -notcontains $_.resourceId })
$estate | Add-Member -NotePropertyName codeComponents -NotePropertyValue @($kept + $found) -Force

# Prompts (ADR 0013): see the description. The template's name comes back as a formatted value, for the evidence only.
Import-Module (Join-Path $PSScriptRoot '..' 'engine' 'ChangeRadar.Matching.psm1') -Force
# A prompt shipped by a Microsoft publisher (solution component type 401, same publisher list as code components) is a
# Microsoft system prompt: matched and shown, never rated or alerted (Simon, 2026-11-22).
$msPrompts = @{}; foreach ($o in Get-All 'solutioncomponents?$select=objectid&$filter=componenttype eq 401&$expand=solutionid($select=uniquename;$expand=publisherid($select=uniquename))') { if ($microsoft -contains $o.solutionid.publisherid.uniquename) { $msPrompts[$o.objectid] = 1 } }
$runConfigs = @{}; foreach ($c in Get-All 'msdyn_aiconfigurations?$select=msdyn_aiconfigurationid,msdyn_customconfiguration&$filter=msdyn_type eq 190690001') { $runConfigs[$c.msdyn_aiconfigurationid] = $c.msdyn_customconfiguration }
$promptRows = foreach ($m in Get-All 'msdyn_aimodels?$select=msdyn_aimodelid,msdyn_name,ismanaged,_ownerid_value,_createdby_value,createdon,modifiedon,_msdyn_activerunconfigurationid_value&$filter=statecode eq 1 and _msdyn_activerunconfigurationid_value ne null') {
    $modelType = Get-PromptModelType $runConfigs[$m._msdyn_activerunconfigurationid_value]
    if (-not $modelType) { continue }
    [ordered]@{ name = $m.msdyn_aimodelid; type = 'microsoft.aibuilder/prompts'; location = $null
        properties = [ordered]@{ displayName = $m.msdyn_name; environmentId = $envId; createdAt = $m.createdon; createdBy = $m._createdby_value; ownerId = $m._ownerid_value
            lastModifiedAt = $m.modifiedon; managed = [bool]$m.ismanaged; microsoftSystem = [bool]$msPrompts[$m.msdyn_aimodelid]; model = $modelType; activeRunConfigurationId = $m._msdyn_activerunconfigurationid_value } }
}
$estate.inventory = @(@($estate.inventory | Where-Object { -not ($_.type -eq 'microsoft.aibuilder/prompts' -and $_.properties.PSObject.Properties['environmentId']?.Value -eq $envId) }) + @($promptRows))

# Fixture labelling (spec §15.2, ADR 0008 addendum 2): resources in a fixture solution move to their own estate file
# with source = fixture, so the engine never rates them with live assets. Same rule as the detail flow.
$fixtureFilter = (@($FixtureSolutions | Where-Object { $_ }) | ForEach-Object { "solutionid/uniquename eq '$_'" }) -join ' or '
$fixtureIds = if ($fixtureFilter) { @(Get-All "solutioncomponents?`$select=objectid&`$filter=(componenttype eq 29 or componenttype eq 80 or componenttype eq 300) and ($fixtureFilter)" | ForEach-Object objectid) } else { @() }
function Get-ComponentId($r) {
    if ($r.type -eq 'microsoft.powerapps/canvasapps') { return $r.name }
    foreach ($f in 'appModuleId', 'workflowEntityId') { if ($r.properties.PSObject.Properties[$f] -and $r.properties.$f) { return $r.properties.$f } }
    $null
}
# Prompt calls (ADR 0017): flow definitions with an AI Builder action, matched to inventory by workflow id.
$flowByWorkflow = @{}; foreach ($r in $estate.inventory | Where-Object { $_.properties.PSObject.Properties['environmentId']?.Value -eq $envId }) { $cid = Get-ComponentId $r; if ($cid -and $r.type -ne 'microsoft.powerapps/canvasapps') { $flowByWorkflow["$cid".ToLowerInvariant()] = $r.name } }
$calls = foreach ($w in Get-All "workflows?`$select=workflowid,name,clientdata&`$filter=type eq 1 and contains(clientdata,'aibuilderpredict_')") {
    $res = $flowByWorkflow["$($w.workflowid)".ToLowerInvariant()]
    if (-not $res) { continue }
    foreach ($c in @(Get-PromptCalls $w.clientdata)) { [ordered]@{ resourceId = $res; operation = $c.operation; promptId = $c.promptId } }
}
$inEnvNow = @($estate.inventory | Where-Object { $_.properties.PSObject.Properties['environmentId']?.Value -eq $envId } | ForEach-Object name)
$keptCalls = @(@($estate.PSObject.Properties['promptCalls'] ? $estate.promptCalls : @()) | Where-Object { $_ -and $inEnvNow -notcontains $_.resourceId })
$estate | Add-Member -NotePropertyName promptCalls -NotePropertyValue @($keptCalls + @($calls)) -Force
$fixtures = @($estate.inventory | Where-Object { $_.properties.PSObject.Properties['environmentId']?.Value -eq $envId -and $fixtureIds -contains (Get-ComponentId $_) })
$fixtureNames = @($fixtures | ForEach-Object name)
$fixtureEstate = if (Test-Path $FixtureEstatePath) { Get-Content $FixtureEstatePath -Raw | ConvertFrom-Json -Depth 60 } else { $null }
$otherFixtures = if ($fixtureEstate) { @($fixtureEstate.inventory | Where-Object { $_.properties.PSObject.Properties['environmentId']?.Value -ne $envId }) } else { @() }
$otherFixtureCode = if ($fixtureEstate -and $fixtureEstate.PSObject.Properties['codeComponents']) { @($fixtureEstate.codeComponents | Where-Object { $_ -and @($otherFixtures.name) -contains $_.resourceId }) } else { @() }
$fixtureOut = [ordered]@{
    schemaVersion  = $estate.schemaVersion
    meta           = [ordered]@{ source = 'fixture'; syntheticOrg = 'Change Radar fixtures (FIXTURE: test assets, not real)'; asOf = $estate.meta.asOf; collector = 'queries/dataverse-detail.ps1'; fixtureSolutions = @($FixtureSolutions) }
    environments   = $estate.environments; principals = @()
    inventory      = @($otherFixtures + $fixtures)
    codeComponents = @($otherFixtureCode + @($estate.codeComponents | Where-Object { $fixtureNames -contains $_.resourceId }))
    promptCalls    = @(@($estate.promptCalls | Where-Object { $fixtureNames -contains $_.resourceId }))
}
$estate.inventory = @($estate.inventory | Where-Object { $fixtureNames -notcontains $_.name })
$estate.codeComponents = @($estate.codeComponents | Where-Object { $fixtureNames -notcontains $_.resourceId })
$estate.promptCalls = @($estate.promptCalls | Where-Object { $fixtureNames -notcontains $_.resourceId })

$detail = [ordered]@{ environmentId = $envId; collector = 'queries/dataverse-detail.ps1'; asOf = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); fixturesMoved = $fixtureNames.Count; prompts = @($promptRows).Count; promptCalls = @($calls).Count }
$estate.meta | Add-Member -NotePropertyName detail -NotePropertyValue @(@(@($estate.meta.PSObject.Properties['detail'] ? $estate.meta.detail : @()) | Where-Object { $_ -and $_.environmentId -ne $envId }) + $detail) -Force
[IO.File]::WriteAllText($EstatePath, ($estate | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($FixtureEstatePath, ($fixtureOut | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false))
$session.Certificate.Dispose()

"controls $($controls.Count), maker-built $($maker.Count): $(@($maker.name) -join ', ')"
"apps using a maker-built control: $(@($found.resourceId | Select-Object -Unique).Count); dependencies to apps not in inventory: $unmatched"
$found | ForEach-Object { "  $($_.resourceId)  $($_.controlName)  [$($_.evidence)]" }
"fixtures moved to the fixture estate: $($fixtureNames.Count) ($(@($fixtures | ForEach-Object { $_.properties.displayName }) -join ', '))"
"-> $EstatePath"
"-> $FixtureEstatePath"
