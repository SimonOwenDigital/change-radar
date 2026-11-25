#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the Change Radar Dataverse schema (solutions/design/schema.json) in a DEV environment,
    inside the ChangeRadarCore solution, through the Dataverse Web API.

.DESCRIPTION
    Developer tool, not an installer step: installers get the tables by importing the solution.

    By default it only PLANS: it reads the environment's metadata and prints what it would create.
    Nothing is written unless -Apply is given.

    Safety:
      - -EnvironmentUrl is mandatory and there is no default; the active pac or Az context is never relied on.
      - Refuses to run unless the environment's friendly name equals -ExpectedEnvironmentName.
      - Refuses to run unless the solution's publisher prefix and option value prefix match schema.json.
      - Creates only, with one exception: it sets each primary name column's MaxLength after table creation,
        because creation ignores the requested length (observed 2026-11-19). Existing components are skipped;
        existing components of a different type are reported as conflicts and stop -Apply. Nothing is deleted.

    Authentication: delegated, as the signed-in user, via Az.Accounts (Connect-AzAccount, then
    Get-AzAccessToken -ResourceUrl). See docs/decisions/verified-facts.md (2026-11-19).

.EXAMPLE
    ./Deploy-SchemaToDev.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com
    ./Deploy-SchemaToDev.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SolutionUniqueName = 'ChangeRadarCore',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json'),
    [string]$LabelsPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'labels.json'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$api = "$EnvironmentUrl/api/data/v9.2"
$lang = 1033

# ---------- schema ----------
$validator = Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'Test-Schema.ps1'
& pwsh -NoProfile -File $validator | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'schema.json failed validation; fix it before deploying.' }
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$labels = Get-Content -Raw $LabelsPath | ConvertFrom-Json -Depth 20 -AsHashtable
$prefix = $schema.publisher.prefix
$optionPrefix = [int]$schema.publisher.optionValuePrefix
$external = @($schema.externalTables)

# ---------- HTTP ----------
$script:token = $null; $script:tokenExpires = [datetimeoffset]::MinValue
function Get-Token {
    if ([datetimeoffset]::UtcNow.AddMinutes(5) -ge $script:tokenExpires) {
        if (-not (Get-Module -ListAvailable Az.Accounts)) { throw 'Az.Accounts is required (Install-Module Az.Accounts -Scope CurrentUser).' }
        Import-Module Az.Accounts -ErrorAction Stop
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount | Out-Null }
        $t = Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString
        $script:token = ConvertFrom-SecureString $t.Token -AsPlainText
        $script:tokenExpires = $t.ExpiresOn
    }
    $script:token
}
function Invoke-Dv {
    param([string]$Method = 'GET', [string]$Path, $Body, [switch]$InSolution, [switch]$MergeLabels)
    $headers = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; 'OData-Version' = '4.0'; 'OData-MaxVersion' = '4.0' }
    if ($InSolution) { $headers['MSCRM.SolutionUniqueName'] = $SolutionUniqueName }
    if ($MergeLabels) { $headers['MSCRM.MergeLabels'] = 'true' }
    $uri = if ($Path -like 'http*') { $Path } else { "$api/$Path" }
    $p = @{ Method = $Method; Uri = $uri; Headers = $headers }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-RestMethod @p }
        catch {
            $resp = $_.Exception.Response
            $status = if ($resp) { [int]$resp.StatusCode } else { 0 }
            if ($status -in 429, 503 -and $attempt -lt 5) {
                $wait = 5 * $attempt
                if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $wait = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds }
                Start-Sleep -Seconds $wait; continue
            }
            $detail = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $_.Exception.Message }
            throw "$Method $Path failed ($status): $detail"
        }
    }
}
function New-Label([string]$Text) {
    @{ '@odata.type' = 'Microsoft.Dynamics.CRM.Label'; LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $Text; LanguageCode = $lang }) }
}
function Get-Required($c) { if ($c.PSObject.Properties['required'] -and $c.required) { 'ApplicationRequired' } else { 'None' } }
function Get-Prop($o, $name, $default) { if ($o.PSObject.Properties[$name]) { $o.$name } else { $default } }

# ---------- guards ----------
Write-Host "`nChecking target environment..."
$org = Invoke-Dv -Path "RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'"
$friendly = $org.Detail.FriendlyName
if ($friendly -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$friendly', expected '$ExpectedEnvironmentName'." }
$sol = (Invoke-Dv -Path "solutions?`$select=uniquename,version&`$filter=uniquename eq '$SolutionUniqueName'&`$expand=publisherid(`$select=uniquename,customizationprefix,customizationoptionvalueprefix)").value
if (-not $sol) { throw "Refusing: solution '$SolutionUniqueName' doesn't exist in '$friendly'." }
$pub = $sol[0].publisherid
if ($pub.customizationprefix -ne $prefix -or [int]$pub.customizationoptionvalueprefix -ne $optionPrefix) {
    throw "Refusing: publisher '$($pub.uniquename)' has prefix '$($pub.customizationprefix)'/$($pub.customizationoptionvalueprefix); schema.json expects '$prefix'/$optionPrefix."
}
Write-Host "Target: '$friendly', solution $SolutionUniqueName $($sol[0].version), publisher $($pub.uniquename) ($prefix, $optionPrefix)."

# ---------- read existing metadata ----------
Write-Host 'Reading existing metadata...'
$existingChoices = @{}
foreach ($o in (Invoke-Dv -Path 'GlobalOptionSetDefinitions?$select=Name').value) { $existingChoices[$o.Name] = $true }
$existingTables = @{}
foreach ($e in (Invoke-Dv -Path 'EntityDefinitions?$select=LogicalName').value) { if ($e.LogicalName -like "${prefix}_*" -or $external -contains $e.LogicalName) { $existingTables[$e.LogicalName] = $true } }
$existingAttrs = @{}; $existingKeys = @{}; $existingPnLength = @{}
foreach ($t in $schema.tables) {
    $ln = "${prefix}_$($t.name)"
    if (-not $existingTables.ContainsKey($ln)) { continue }
    try { $existingPnLength[$ln] = (Invoke-Dv -Path "EntityDefinitions(LogicalName='$ln')/Attributes(LogicalName='${prefix}_$($t.primaryName)')/Microsoft.Dynamics.CRM.StringAttributeMetadata?`$select=MaxLength").MaxLength } catch { }
    $md = Invoke-Dv -Path "EntityDefinitions(LogicalName='$ln')?`$select=LogicalName&`$expand=Attributes(`$select=LogicalName,AttributeType),Keys(`$select=LogicalName,EntityKeyIndexStatus)"
    $existingAttrs[$ln] = @{}; foreach ($a in $md.Attributes) { $existingAttrs[$ln][$a.LogicalName] = "$($a.AttributeType)" }
    $existingKeys[$ln] = @{}; foreach ($k in $md.Keys) { $existingKeys[$ln][$k.LogicalName] = "$($k.EntityKeyIndexStatus)" }
}

# ---------- plan ----------
$typeMap = @{ string = 'String'; url = 'String'; memo = 'Memo'; choice = 'Picklist'; bool = 'Boolean'; int = 'Integer'; decimal = 'Decimal'; datetime = 'DateTime'; lookup = 'Lookup' }
$plan = [System.Collections.Generic.List[object]]::new()
function Add-Step($Kind, $Name, $Status, $Detail, $Body, $Path) { $plan.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Status = $Status; Detail = $Detail; Body = $Body; Path = $Path }) }

# 1. Global choices
foreach ($p in $schema.choices.PSObject.Properties) {
    $name = "${prefix}_$($p.Name)"; $lab = $labels.choices[$p.Name]
    $i = 0
    $options = foreach ($v in $p.Value) { @{ Value = $optionPrefix * 10000 + $i; Label = (New-Label $lab.values[$v]) }; $i++ }
    $body = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.OptionSetMetadata'; Name = $name; DisplayName = (New-Label $lab.label); IsGlobal = $true; OptionSetType = 'Picklist'; Options = @($options) }
    $detail = "$(@($p.Value).Count) values, $($optionPrefix * 10000)..$($optionPrefix * 10000 + @($p.Value).Count - 1)"
    Add-Step 'Choice' $name ($existingChoices.ContainsKey($name) ? 'exists' : 'create') $detail $body 'GlobalOptionSetDefinitions'
    if ($existingChoices.ContainsKey($name)) {
        # Values are appended to the end of a choice in schema.json, never inserted or reordered, so existing option
        # values never move. A value the environment lacks is added with InsertOptionValue.
        $have = @((Invoke-Dv -Path "GlobalOptionSetDefinitions(Name='$name')/Microsoft.Dynamics.CRM.OptionSetMetadata").Options | ForEach-Object { [int]$_.Value })
        foreach ($o in $options | Where-Object { $have -notcontains $_.Value }) {
            Add-Step 'Option' "$name $($o.Value)" 'create' $o.Label.LocalizedLabels[0].Label @{ OptionSetName = $name; Value = $o.Value; Label = $o.Label; SolutionUniqueName = $SolutionUniqueName } 'InsertOptionValue'
        }
    }
}

function New-AttributeBody($c, [bool]$IsPrimary) {
    $common = @{ SchemaName = "${prefix}_$($c.name)"; DisplayName = (New-Label $labels.columns[$c.name]); RequiredLevel = @{ Value = (Get-Required $c); CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings' } }
    if ($c.PSObject.Properties['description']) { $common.Description = New-Label $c.description }
    $b = switch ($c.type) {
        'string'   { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'; MaxLength = $c.maxLength; FormatName = @{ Value = 'Text' } } }
        'url'      { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'; MaxLength = $c.maxLength; FormatName = @{ Value = 'Url' } } }
        'memo'     { $m = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'; MaxLength = $c.maxLength; Format = 'TextArea' }; if ((Get-Prop $c 'format' '') -eq 'richtext') { $m.FormatName = @{ Value = 'RichText' } }; $m }
        # The bind needs the choice's MetadataId, not its name (Learn, 2026-11-19); resolved at apply time.
        'choice'   { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'; 'GlobalOptionSet@odata.bind' = "__choice__:${prefix}_$($c.choice)" } }
        'bool'     { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.BooleanAttributeMetadata'; DefaultValue = [bool](Get-Prop $c 'default' $false)
                        OptionSet = @{ TrueOption = @{ Value = 1; Label = (New-Label 'Yes') }; FalseOption = @{ Value = 0; Label = (New-Label 'No') } } } }
        'int'      { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.IntegerAttributeMetadata'; Format = 'None'; MinValue = (Get-Prop $c 'min' ([int]::MinValue)); MaxValue = (Get-Prop $c 'max' ([int]::MaxValue)) } }
        'decimal'  { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.DecimalAttributeMetadata'; Precision = (Get-Prop $c 'precision' 2); MinValue = (Get-Prop $c 'min' (-100000000000)); MaxValue = (Get-Prop $c 'max' 100000000000) } }
        'datetime' { $dateOnly = (Get-Prop $c 'format' '') -eq 'dateonly'
                     @{ '@odata.type' = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'; Format = ($dateOnly ? 'DateOnly' : 'DateAndTime'); DateTimeBehavior = @{ Value = ($dateOnly ? 'DateOnly' : 'UserLocal') } } }
    }
    if ($IsPrimary) { $b.IsPrimaryName = $true }
    $common + $b
}

# 2. Tables (with primary name column)
foreach ($t in $schema.tables) {
    $ln = "${prefix}_$($t.name)"
    $pn = $t.columns | Where-Object name -eq $t.primaryName
    if ($pn.type -ne 'string') { throw "$($t.name): primary name '$($t.primaryName)' must be a string column." }
    $body = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.EntityMetadata'; SchemaName = $ln; DisplayName = (New-Label $t.displayName); DisplayCollectionName = (New-Label $labels.tables[$t.name].plural)
        Description = (New-Label (Get-Prop $t 'description' $t.displayName)); OwnershipType = 'OrganizationOwned'; IsActivity = $false; HasActivities = $false; HasNotes = $false
        Attributes = @(New-AttributeBody $pn $true) }
    Add-Step 'Table' $ln ($existingTables.ContainsKey($ln) ? 'exists' : 'create') "primary name ${prefix}_$($t.primaryName); $(@($t.columns).Count) columns" $body 'EntityDefinitions'
}

# 2b. Primary name length. Table creation ignores the requested MaxLength and uses 850 (observed 2026-11-19),
#     so set it afterwards. This is the only update the script makes. It changes the column's limit only;
#     the database column stays at 850 characters.
foreach ($t in $schema.tables) {
    $ln = "${prefix}_$($t.name)"; $an = "${prefix}_$($t.primaryName)"
    $want = ($t.columns | Where-Object name -eq $t.primaryName).maxLength
    $have = if ($existingPnLength.ContainsKey($ln)) { $existingPnLength[$ln] } else { $null }
    $status = if ($null -ne $have -and $have -eq $want) { 'exists' } else { 'update' }
    Add-Step 'Length' "$ln.$an" $status "max length $(if ($null -ne $have) { "$have → " })$want" @{ Table = $ln; Attribute = $an; MaxLength = $want } $null
}

# 3. Columns (non-lookup, non-primary)   4. Lookups (relationships)
foreach ($t in $schema.tables) {
    $ln = "${prefix}_$($t.name)"
    foreach ($c in $t.columns) {
        if ($c.name -eq $t.primaryName) { continue }
        $an = "${prefix}_$($c.name)"
        $have = if ($existingAttrs.ContainsKey($ln) -and $existingAttrs[$ln].ContainsKey($an)) { $existingAttrs[$ln][$an] } else { $null }
        $status = if (-not $have) { 'create' } elseif ($have -eq $typeMap[$c.type]) { 'exists' } else { "CONFLICT (is $have)" }
        if ($c.type -eq 'lookup') {
            $target = if ($external -contains $c.target) { $c.target } else { "${prefix}_$($c.target)" }
            $cascade = Get-Prop $c 'cascade' 'referential'
            $cc = if ($cascade -eq 'parental') { @{ Assign = 'NoCascade'; Delete = 'Cascade'; Merge = 'NoCascade'; Reparent = 'NoCascade'; Share = 'NoCascade'; Unshare = 'NoCascade'; RollupView = 'NoCascade' } }
                  else { @{ Assign = 'NoCascade'; Delete = 'RemoveLink'; Merge = 'NoCascade'; Reparent = 'NoCascade'; Share = 'NoCascade'; Unshare = 'NoCascade'; RollupView = 'NoCascade' } }
            $lookup = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.LookupAttributeMetadata'; SchemaName = $an; DisplayName = (New-Label $labels.columns[$c.name])
                RequiredLevel = @{ Value = (Get-Required $c); CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings' } }
            if ($c.PSObject.Properties['description']) { $lookup.Description = New-Label $c.description }
            $body = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata'; SchemaName = "${prefix}_$($c.target)_$($t.name)_$($c.name)"
                ReferencedEntity = $target; ReferencedAttribute = "$($target)id"; ReferencingEntity = $ln; CascadeConfiguration = $cc; Lookup = $lookup }
            Add-Step 'Lookup' "$ln.$an" $status "→ $target ($cascade$(if ((Get-Required $c) -ne 'None') { ', required' }))" $body 'RelationshipDefinitions'
        }
        else {
            $detail = switch ($c.type) { 'choice' { "choice ${prefix}_$($c.choice)" } { $_ -in 'string', 'memo', 'url' } { "$($c.type)($($c.maxLength))" } default { $c.type } }
            if ((Get-Required $c) -ne 'None') { $detail += ', required' }
            Add-Step 'Column' "$ln.$an" $status $detail (New-AttributeBody $c $false) "EntityDefinitions(LogicalName='$ln')/Attributes"
        }
    }
}

# 5. Alternate keys
foreach ($t in $schema.tables) {
    $ln = "${prefix}_$($t.name)"
    foreach ($k in @(Get-Prop $t 'alternateKeys' @())) {
        $kn = "${prefix}_$($k.name)_ak"   # suffix keeps key names distinct from column names (e.g. crdr_key)
        $status = if ($existingKeys.ContainsKey($ln) -and $existingKeys[$ln].ContainsKey($kn)) { "exists ($($existingKeys[$ln][$kn]))" } else { 'create' }
        $body = @{ SchemaName = $kn; DisplayName = (New-Label (($k.columns | ForEach-Object { $labels.columns[$_] }) -join ' + ')); KeyAttributes = @($k.columns | ForEach-Object { "${prefix}_$_" }) }
        Add-Step 'Key' "$ln.$kn" $status "($($k.columns -join ', '))" $body "EntityDefinitions(LogicalName='$ln')/Keys"
    }
}

# ---------- report ----------
Write-Host "`nPLAN for '$friendly' / $SolutionUniqueName"
foreach ($kind in 'Choice', 'Option', 'Table', 'Length', 'Column', 'Lookup', 'Key') {
    $steps = @($plan | Where-Object Kind -eq $kind)
    $n = @($steps | Where-Object Status -in 'create', 'update').Count
    Write-Host ("`n{0}s: {1} to create or update, {2} existing, {3} conflicts" -f $kind, $n, @($steps | Where-Object Status -like 'exists*').Count, @($steps | Where-Object Status -like 'CONFLICT*').Count)
    foreach ($s in $steps) { Write-Host ("  {0,-8} {1,-55} {2}" -f $s.Status, $s.Name, $s.Detail) }
}
$conflicts = @($plan | Where-Object Status -like 'CONFLICT*')
$todo = @($plan | Where-Object Status -in 'create', 'update')
Write-Host "`nTotal: $($todo.Count) to create or update, $($conflicts.Count) conflict(s)."

if (-not $Apply) { Write-Host 'Plan only. Nothing was changed. Re-run with -Apply to create.'; return }
if ($conflicts) { throw 'Refusing to apply: resolve the conflicts above first (this script never changes existing components).' }

# ---------- apply ----------
$choiceIds = @{}
function Resolve-ChoiceBind($body) {
    $bind = $body['GlobalOptionSet@odata.bind']
    if ($bind -and $bind.StartsWith('__choice__:')) {
        $name = $bind.Substring(11)
        if (-not $choiceIds.ContainsKey($name)) { $choiceIds[$name] = (Invoke-Dv -Path "GlobalOptionSetDefinitions(Name='$name')?`$select=MetadataId").MetadataId }
        $body['GlobalOptionSet@odata.bind'] = "/GlobalOptionSetDefinitions($($choiceIds[$name]))"
    }
}
$done = 0
foreach ($s in $todo) {
    Write-Host ("[{0}/{1}] {2} {3}" -f ($done + 1), $todo.Count, $s.Kind, $s.Name)
    if ($s.Kind -eq 'Length') {
        # Full-definition PUT: GET the attribute, change MaxLength, PUT it back (MSCRM.MergeLabels keeps other labels).
        $apath = "EntityDefinitions(LogicalName='$($s.Body.Table)')/Attributes(LogicalName='$($s.Body.Attribute)')"
        $def = Invoke-Dv -Path "$apath/Microsoft.Dynamics.CRM.StringAttributeMetadata"
        $def.PSObject.Properties.Remove('@odata.context')
        $def | Add-Member -NotePropertyName '@odata.type' -NotePropertyValue 'Microsoft.Dynamics.CRM.StringAttributeMetadata' -Force
        $def.MaxLength = $s.Body.MaxLength
        Invoke-Dv -Method PUT -Path $apath -Body $def -InSolution -MergeLabels | Out-Null
        $done++; continue
    }
    if ($s.Kind -eq 'Column') { Resolve-ChoiceBind $s.Body }
    Invoke-Dv -Method POST -Path $s.Path -Body $s.Body -InSolution | Out-Null
    $done++
}
Write-Host 'Publishing customisations...'
Invoke-Dv -Method POST -Path 'PublishAllXml' -Body @{} | Out-Null   # needs a JSON content type even with no parameters
Write-Host "Created $done component(s). Alternate keys build their indexes asynchronously: re-run without -Apply to see their status (Active when ready)."
