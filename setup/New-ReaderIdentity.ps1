#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the Change Radar reader identity: a Key Vault holding its certificate, the Entra app
    registration with read-only Graph application permissions, and a read-only application user
    in one Power Platform environment.

.DESCRIPTION
    By default it only PLANS: it reads Azure, Entra ID and Dataverse and prints what it would do.
    Nothing is created unless -Apply is given. It never deletes or changes existing objects; anything
    that exists but differs is reported as a CONFLICT and stops -Apply.

    What it creates (all names are parameters):
      Azure (subscription -SubscriptionId)
        - Resource group, Key Vault (RBAC permission model, soft delete, purge protection off)
        - Role assignments on the vault only:
            signed-in user  : Key Vault Certificates Officer (to create the certificate)
                              Key Vault Secrets User (to create the secret environment variable)
            Dataverse SP    : Key Vault Secrets User (app id 00000007-0000-0000-c000-000000000000;
                              Learn, checked 2026-11-19)
        - Self-signed certificate generated inside the vault; the private key never leaves it
      Entra ID (as the signed-in user, via Microsoft Graph)
        - App registration (single tenant) with the certificate's public key only
        - Service principal, and admin consent for Graph application permissions
          ServiceHealth.Read.All and ServiceMessage.Read.All (nothing else)
      Dataverse (-EnvironmentUrl, guarded by -ExpectedEnvironmentName)
        - Security role with organisation-level READ on the solution's publisher tables, added to the solution
        - Organisation-level READ on the component tables (-ComponentReadPrivileges): solution, solution
          component, bot, bot component, workflow, connection reference, canvas app, publisher (ADR 0008, pp-lab only for now)
        - Application user for the app, with only that role

    Authentication: delegated, as the signed-in user, via Az.Accounts (Connect-AzAccount).

.EXAMPLE
    ./New-ReaderIdentity.ps1 -SubscriptionId <guid> -EnvironmentUrl https://<org>.crm.dynamics.com
    ./New-ReaderIdentity.ps1 -SubscriptionId <guid> -EnvironmentUrl https://<org>.crm.dynamics.com -Apply

.EXAMPLE
    # New tenant: Azure and Entra part only, before the solution is imported (it ships the Reader role)
    ./New-ReaderIdentity.ps1 -SubscriptionId <guid> -SkipDataverse -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$EnvironmentUrl,                  # required unless -SkipDataverse
    [switch]$SkipDataverse,                   # Azure and Entra only: run before the solution is imported (install step 2)
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SolutionUniqueName = 'ChangeRadarCore',
    [string]$ResourceGroup = 'rg-crdr-dev',
    [string]$Location = 'uksouth',
    [string]$VaultName,                       # default: kv-crdr-dev-<4 hex from the subscription id>, stable across runs
    [string]$AppName = 'crdr-reader',
    [string]$CertificateName = 'crdr-reader',
    [int]$ValidityMonths = 12,
    [string]$RoleName = 'Change Radar Reader',
    # Component detail (ADR 0008; names checked in pp-lab 2026-11-20). prvReadSolution covers solution and
    # solutioncomponent. customcontrol has no read privilege. Ask Simon before widening this or using it outside pp-lab.
    # prvReadmsdyn_AIModel (ADR 0013, Simon 2026-11-22): prompts and their models; msdyn_aiconfiguration has no
    # ownership of its own and is read through it (checked in pp-lab 2026-11-22).
    [string[]]$ComponentReadPrivileges = @('prvReadSolution', 'prvReadbot', 'prvReadbotcomponent', 'prvReadWorkflow', 'prvReadconnectionreference', 'prvReadCanvasApp', 'prvReadPublisher', 'prvReadmsdyn_AIModel'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $SkipDataverse -and -not $EnvironmentUrl) { throw 'Give -EnvironmentUrl, or -SkipDataverse to do only the Azure and Entra part.' }
$EnvironmentUrl = "$EnvironmentUrl".TrimEnd('/')
if (-not $VaultName) {
    $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SubscriptionId))).ToLowerInvariant()
    $VaultName = "kv-crdr-dev-$($h.Substring(0, 4))"
}
$graphAppId = '00000003-0000-0000-c000-000000000000'
$dataverseAppId = '00000007-0000-0000-c000-000000000000'
$graphRoles = 'ServiceHealth.Read.All', 'ServiceMessage.Read.All'
$arm = 'https://management.azure.com'
$graph = 'https://graph.microsoft.com/v1.0'
$vaultUri = "https://$VaultName.vault.azure.net"
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$vaultId = "$rgId/providers/Microsoft.KeyVault/vaults/$VaultName"

# ---------- HTTP ----------
Import-Module Az.Accounts -ErrorAction Stop
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount | Out-Null }
$script:tokens = @{}
function Get-Token([string]$Resource) {
    $c = $script:tokens[$Resource]
    if (-not $c -or [datetimeoffset]::UtcNow.AddMinutes(5) -ge $c.Expires) {
        $t = Get-AzAccessToken -ResourceUrl $Resource -AsSecureString
        $c = @{ Token = (ConvertFrom-SecureString $t.Token -AsPlainText); Expires = $t.ExpiresOn }; $script:tokens[$Resource] = $c
    }
    $c.Token
}
function Invoke-Api {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body, [hashtable]$Headers = @{}, [switch]$AllowNotFound, [int]$Retries = 1)
    $resource = switch -Regex ($Uri) { '^https://management\.azure\.com' { "$arm/" } '^https://graph\.microsoft\.com' { 'https://graph.microsoft.com/' } '\.vault\.azure\.net' { 'https://vault.azure.net' } default { $EnvironmentUrl } }
    $hdr = @{ Authorization = "Bearer $(Get-Token $resource)"; Accept = 'application/json' } + $Headers
    $p = @{ Method = $Method; Uri = $Uri; Headers = $hdr }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    for ($i = 1; ; $i++) {
        try { return Invoke-RestMethod @p }
        catch {
            $resp = $_.Exception.Response; $status = if ($resp) { [int]$resp.StatusCode } else { 0 }
            if ($status -eq 404 -and $AllowNotFound) { return $null }
            # 400/403/404 straight after creating something is usually replication delay; 429/5xx is throttling.
            if ($i -lt $Retries -and $status -in 400, 403, 404, 409, 429, 500, 502, 503) { Start-Sleep -Seconds ([Math]::Min(10 * $i, 60)); continue }
            $detail = try { $e = $_.ErrorDetails.Message | ConvertFrom-Json; if ($e.error.message) { $e.error.message } else { $e.error } } catch { $_.Exception.Message }
            throw "$Method $Uri failed ($status): $detail"
        }
    }
}
function Get-DvRoot { "$EnvironmentUrl/api/data/v9.2" }

# ---------- discovery (read-only) ----------
Write-Host "`nReading current state (read-only)..."
$me = Invoke-Api -Uri "$graph/me?`$select=id,userPrincipalName,mail"
$sub = Invoke-Api -Uri "$arm/subscriptions/$($SubscriptionId)?api-version=2022-12-01"
$tenantId = $sub.tenantId
$provider = (Invoke-Api -Uri "$arm/subscriptions/$SubscriptionId/providers/Microsoft.PowerPlatform?api-version=2021-04-01").registrationState
$kvProvider = (Invoke-Api -Uri "$arm/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault?api-version=2021-04-01").registrationState
$rg = Invoke-Api -Uri "$($arm)$($rgId)?api-version=2021-04-01" -AllowNotFound
$vault = Invoke-Api -Uri "$($arm)$($vaultId)?api-version=2023-07-01" -AllowNotFound
$nameFree = $true
if (-not $vault) { $nameFree = (Invoke-Api -Method POST -Uri "$arm/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01" -Body @{ name = $VaultName; type = 'Microsoft.KeyVault/vaults' }).nameAvailable }

function Get-RoleDefinitionId([string]$Name) {
    $r = (Invoke-Api -Uri "$arm/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&`$filter=roleName eq '$Name'").value
    if (-not $r) { throw "Azure role '$Name' not found." }; $r[0].id
}
$roleCertOfficer = Get-RoleDefinitionId 'Key Vault Certificates Officer'
$roleSecretsUser = Get-RoleDefinitionId 'Key Vault Secrets User'
$dvSp = @((Invoke-Api -Uri "$graph/servicePrincipals?`$filter=appId eq '$dataverseAppId'&`$select=id,displayName").value)
if ($dvSp.Count -ne 1) { throw "Expected one Dataverse service principal ($dataverseAppId), found $($dvSp.Count)." }
$existingAssignments = if ($vault) { @((Invoke-Api -Uri "$($arm)$($vaultId)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()").value) } else { @() }
function Test-Assigned($PrincipalId, $RoleDefId) { [bool]($existingAssignments | Where-Object { $_.properties.principalId -eq $PrincipalId -and $_.properties.roleDefinitionId -eq $RoleDefId }) }

$cert = $null
if ($vault) { try { $cert = Invoke-Api -Uri "$vaultUri/certificates/$($CertificateName)?api-version=7.4" -AllowNotFound } catch { Write-Host "  (can't read certificates in the vault yet: $($_.Exception.Message))" } }

$graphSp = (Invoke-Api -Uri "$graph/servicePrincipals?`$filter=appId eq '$graphAppId'&`$select=id,appRoles").value[0]
$graphRoleIds = @{}; foreach ($r in $graphRoles) { $graphRoleIds[$r] = ($graphSp.appRoles | Where-Object { $_.value -eq $r -and $_.allowedMemberTypes -contains 'Application' }).id; if (-not $graphRoleIds[$r]) { throw "Graph app role $r not found." } }
$app = @((Invoke-Api -Uri "$graph/applications?`$filter=displayName eq '$AppName'&`$select=id,appId,displayName,keyCredentials,requiredResourceAccess,signInAudience").value)
if ($app.Count -gt 1) { throw "More than one app registration is named '$AppName'; resolve that by hand." }
$app = if ($app.Count) { $app[0] } else { $null }
$sp = if ($app) { @((Invoke-Api -Uri "$graph/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id").value) | Select-Object -First 1 } else { $null }
$assigned = if ($sp) { @((Invoke-Api -Uri "$graph/servicePrincipals/$($sp.id)/appRoleAssignments").value | ForEach-Object appRoleId) } else { @() }

# Dataverse guards
$role = $null; $appUser = $null; $org = $null; $prefix = $null
if (-not $SkipDataverse) {
$dv = Get-DvRoot
$org = Invoke-Api -Uri "$dv/RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
if ($org.Detail.TenantId -and $org.Detail.TenantId -ne $tenantId) { throw 'Refusing: the environment and the subscription are in different tenants.' }
$sol = @((Invoke-Api -Uri "$dv/solutions?`$select=solutionid,uniquename&`$filter=uniquename eq '$SolutionUniqueName'&`$expand=publisherid(`$select=customizationprefix)").value)
if (-not $sol) { throw "Refusing: solution '$SolutionUniqueName' doesn't exist." }
$prefix = $sol[0].publisherid.customizationprefix
$rootBu = (Invoke-Api -Uri "$dv/businessunits?`$select=businessunitid,name&`$filter=_parentbusinessunitid_value eq null").value[0]
$role = @((Invoke-Api -Uri "$dv/roles?`$select=roleid,name,ismanaged&`$filter=name eq '$($RoleName.Replace("'", "''"))' and _businessunitid_value eq $($rootBu.businessunitid)").value) | Select-Object -First 1
# Read on the solution's own tables (install test finding 6): the tables come from the solution's components, not from the
# publisher prefix, so a dev-only table with the same prefix (a fixture) never gets into the role.
$tableIds = @((Invoke-Api -Uri "$dv/solutioncomponents?`$select=objectid&`$filter=_solutionid_value eq $($sol[0].solutionid) and componenttype eq 1").value | ForEach-Object objectid)
$tableNames = @((Invoke-Api -Uri "$dv/EntityDefinitions?`$select=SchemaName,MetadataId").value | Where-Object { $tableIds -contains $_.MetadataId } | ForEach-Object { "prvRead$($_.SchemaName)" })
$prefixPrivs = @((Invoke-Api -Uri "$dv/privileges?`$select=privilegeid,name&`$filter=startswith(name,'prvRead$($prefix)_')").value)
$readPrivs = @($prefixPrivs | Where-Object { $tableNames -contains $_.name })
$componentFilter = ($ComponentReadPrivileges | ForEach-Object { "name eq '$_'" }) -join ' or '
$componentPrivs = @((Invoke-Api -Uri "$dv/privileges?`$select=privilegeid,name&`$filter=$componentFilter").value)
$notFound = @($ComponentReadPrivileges | Where-Object { @($componentPrivs.name) -notcontains $_ })
if ($notFound) { throw "Privilege(s) not found in this environment: $($notFound -join ', ')." }
$rolePrivs = if ($role) { @((Invoke-Api -Uri "$dv/roles($($role.roleid))/roleprivileges_association?`$select=name").value | ForEach-Object name) } else { @() }
$extraPrivs = @($rolePrivs | Where-Object { $_ -like "prvRead$($prefix)_*" -and $tableNames -notcontains $_ })
$appUser = if ($app) { @((Invoke-Api -Uri "$dv/systemusers?`$select=systemuserid,fullname&`$filter=applicationid eq $($app.appId)").value) | Select-Object -First 1 } else { $null }
$appUserRoles = if ($appUser) { @((Invoke-Api -Uri "$dv/systemusers($($appUser.systemuserid))/systemuserroles_association?`$select=name").value | ForEach-Object name) } else { @() }
}

# ---------- plan ----------
$plan = [System.Collections.Generic.List[object]]::new()
$state = @{ AppId = ${app}?.appId; AppObjectId = ${app}?.id; SpId = ${sp}?.id; RoleId = ${role}?.roleid; UserId = ${appUser}?.systemuserid }
function Add-Step($Area, $Name, $Status, $Detail, [scriptblock]$Action, $Data) { $plan.Add([pscustomobject]@{ Area = $Area; Name = $Name; Status = $Status; Detail = $Detail; Action = $Action; Data = $Data }) }

# Azure
Add-Step 'Azure' 'Resource provider Microsoft.PowerPlatform' ($provider -eq 'Registered' ? 'exists' : 'CONFLICT (not registered)') 'needed for Key Vault secret environment variables' $null
Add-Step 'Azure' 'Resource provider Microsoft.KeyVault' ($kvProvider -eq 'Registered' ? 'exists' : 'create') 'subscription-wide registration; enables the service, creates nothing' {
    Invoke-Api -Method POST -Uri "$arm/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault/register?api-version=2021-04-01" | Out-Null
    for ($i = 0; $i -lt 60; $i++) { if ((Invoke-Api -Uri "$arm/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault?api-version=2021-04-01").registrationState -eq 'Registered') { break }; Start-Sleep 5 } }
Add-Step 'Azure' "Resource group $ResourceGroup" ($rg ? 'exists' : 'create') "$Location, tag app=change-radar" {
    Invoke-Api -Method PUT -Uri "$($arm)$($rgId)?api-version=2021-04-01" -Body @{ location = $Location; tags = @{ app = 'change-radar'; purpose = 'reader identity (dev)' } } | Out-Null }
$vaultStatus = if ($vault) { if ($vault.properties.enableRbacAuthorization) { 'exists' } else { 'CONFLICT (uses access policies, not RBAC)' } } elseif (-not $nameFree) { 'CONFLICT (name taken, possibly soft-deleted)' } else { 'create' }
Add-Step 'Azure' "Key Vault $VaultName" $vaultStatus 'standard, RBAC, soft delete 90 days, purge protection off, public network' {
    Invoke-Api -Method PUT -Uri "$($arm)$($vaultId)?api-version=2023-07-01" -Body @{ location = $Location; tags = @{ app = 'change-radar' }
        properties = @{ tenantId = $tenantId; sku = @{ family = 'A'; name = 'standard' }; enableRbacAuthorization = $true; enableSoftDelete = $true; softDeleteRetentionInDays = 90 } } | Out-Null
    for ($i = 0; $i -lt 30; $i++) { $v = Invoke-Api -Uri "$($arm)$($vaultId)?api-version=2023-07-01" -AllowNotFound; if ($v -and $v.properties.provisioningState -eq 'Succeeded') { break }; Start-Sleep 5 } }
foreach ($ra in @(
        @{ Who = "you ($($me.userPrincipalName))"; Principal = $me.id; Type = 'User'; Role = $roleCertOfficer; RoleName = 'Key Vault Certificates Officer' },
        @{ Who = "you ($($me.userPrincipalName))"; Principal = $me.id; Type = 'User'; Role = $roleSecretsUser; RoleName = 'Key Vault Secrets User' },
        @{ Who = "Dataverse service principal"; Principal = $dvSp[0].id; Type = 'ServicePrincipal'; Role = $roleSecretsUser; RoleName = 'Key Vault Secrets User' })) {
    Add-Step 'Azure' "Role: $($ra.RoleName) → $($ra.Who)" ((Test-Assigned $ra.Principal $ra.Role) ? 'exists' : 'create') 'scope: this vault only' {
        param($r)
        Invoke-Api -Method PUT -Uri "$($arm)$($vaultId)/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())?api-version=2022-04-01" `
            -Body @{ properties = @{ roleDefinitionId = $r.Role; principalId = $r.Principal; principalType = $r.Type } } -Retries 6 | Out-Null } $ra
}
$certStatus = if ($cert) { 'exists' } else { 'create' }
Add-Step 'Azure' "Certificate $CertificateName" $certStatus "CN=$CertificateName, RSA 2048, $ValidityMonths months, email $([int]30) days before expiry, generated in the vault" {
    Invoke-Api -Method PUT -Uri "$vaultUri/certificates/contacts?api-version=7.4" -Body @{ contacts = @(@{ email = ($me.mail ?? $me.userPrincipalName) }) } -Retries 12 | Out-Null
    Invoke-Api -Method POST -Uri "$vaultUri/certificates/$CertificateName/create?api-version=7.4" -Retries 12 -Body @{ policy = @{
            key_props = @{ exportable = $true; kty = 'RSA'; key_size = 2048; reuse_key = $false }
            secret_props = @{ contentType = 'application/x-pkcs12' }
            x509_props = @{ subject = "CN=$CertificateName"; validity_months = $ValidityMonths; key_usage = @('digitalSignature', 'keyEncipherment') }
            issuer = @{ name = 'Self' }
            lifetime_actions = @(@{ trigger = @{ days_before_expiry = 30 }; action = @{ action_type = 'EmailContacts' } }) } } | Out-Null
    for ($i = 0; $i -lt 30; $i++) { $op = Invoke-Api -Uri "$vaultUri/certificates/$CertificateName/pending?api-version=7.4" -AllowNotFound; if (-not $op -or $op.status -eq 'completed') { break }; if ($op.status -eq 'failed') { throw "Certificate creation failed: $($op.error.message)" }; Start-Sleep 3 } }

# Entra
$appStatus = if ($app) { if ($app.signInAudience -eq 'AzureADMyOrg') { 'exists' } else { 'CONFLICT (not single tenant)' } } else { 'create' }
Add-Step 'Entra' "App registration $AppName" $appStatus "single tenant; certificate public key only; requests $($graphRoles -join ', ')" {
    $c = Invoke-Api -Uri "$vaultUri/certificates/$($CertificateName)?api-version=7.4"
    $a = Invoke-Api -Method POST -Uri "$graph/applications" -Body @{ displayName = $AppName; signInAudience = 'AzureADMyOrg'
        notes = 'Change Radar read-only reader. Created by setup/New-ReaderIdentity.ps1. Certificate held in Azure Key Vault.'
        requiredResourceAccess = @(@{ resourceAppId = $graphAppId; resourceAccess = @($graphRoles | ForEach-Object { @{ id = $graphRoleIds[$_]; type = 'Role' } }) })
        keyCredentials = @(@{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $c.cer; displayName = "CN=$CertificateName (Key Vault $VaultName)" }) }
    $state.AppId = $a.appId; $state.AppObjectId = $a.id }
if ($app) {
    # The certificate in the vault must be one of the app's credentials; customKeyIdentifier is the SHA-1 thumbprint (hex).
    $thumb = if ($cert) { [Convert]::ToHexString([Convert]::FromBase64String($cert.x5t.Replace('-', '+').Replace('_', '/').PadRight([Math]::Ceiling($cert.x5t.Length / 4) * 4, '='))) } else { $null }
    $has = $thumb -and @($app.keyCredentials | Where-Object { $_.customKeyIdentifier -eq $thumb }).Count
    Add-Step 'Entra' "Certificate credential on $AppName" ($has ? 'exists' : 'CONFLICT (vault certificate not on the app; rotate by hand)') 'public key only' $null
}
Add-Step 'Entra' "Service principal for $AppName" ($sp ? 'exists' : 'create') 'enterprise application' {
    $s = Invoke-Api -Method POST -Uri "$graph/servicePrincipals" -Body @{ appId = $state.AppId } -Retries 6; $state.SpId = $s.id }
foreach ($rn in $graphRoles) {
    Add-Step 'Entra' "Admin consent: Graph $rn" ((@($assigned) -contains $graphRoleIds[$rn]) ? 'exists' : 'create') 'application permission, read-only' {
        param($n)
        Invoke-Api -Method POST -Uri "$graph/servicePrincipals/$($graphSp.id)/appRoleAssignedTo" -Retries 6 -Body @{ principalId = $state.SpId; resourceId = $graphSp.id; appRoleId = $graphRoleIds[$n] } | Out-Null } $rn
}

# Dataverse
if (-not $SkipDataverse) {
Add-Step 'Dataverse' "Security role '$RoleName'" ($role ? 'exists' : 'create') "root business unit; added to $SolutionUniqueName" {
    $r = Invoke-Api -Method POST -Uri "$dv/roles" -Headers @{ Prefer = 'return=representation' } -Body @{ name = $RoleName; description = 'Change Radar read-only reader: organisation-level read on Change Radar tables.'; 'businessunitid@odata.bind' = "/businessunits($($rootBu.businessunitid))" }
    $state.RoleId = $r.roleid
    Invoke-Api -Method POST -Uri "$dv/AddSolutionComponent" -Body @{ ComponentId = $r.roleid; ComponentType = 20; SolutionUniqueName = $SolutionUniqueName; AddRequiredComponents = $false } | Out-Null }
$missingPrivs = @($readPrivs | Where-Object { $rolePrivs -notcontains $_.name })
# A managed role ships in the solution: never layer over it (an unmanaged layer blocks every later update of the role).
$managedNote = 'MISSING (managed role: fix the solution and re-import; not changed here)'
Add-Step 'Dataverse' "Role privileges: read on $SolutionUniqueName tables" ($missingPrivs.Count ? ($role -and $role.ismanaged ? $managedNote : 'create') : 'exists') "$($readPrivs.Count) read privileges, organisation level; no create/write/delete$(if ($missingPrivs) { "; missing: $($missingPrivs.name -join ', ')" })" {
    Invoke-Api -Method POST -Uri "$dv/roles($($state.RoleId))/Microsoft.Dynamics.CRM.AddPrivilegesRole" -Body @{ Privileges = @($missingPrivs | ForEach-Object { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.RolePrivilege'; PrivilegeId = $_.privilegeid; Depth = 'Global' } }) } | Out-Null }
$missingComponent = @($componentPrivs | Where-Object { $rolePrivs -notcontains $_.name })
Add-Step 'Dataverse' 'Role privileges: read on component tables (ADR 0008)' ($missingComponent.Count ? ($role -and $role.ismanaged ? $managedNote : 'create') : 'exists') "$($ComponentReadPrivileges -join ', '); organisation level, read only" {
    Invoke-Api -Method POST -Uri "$dv/roles($($state.RoleId))/Microsoft.Dynamics.CRM.AddPrivilegesRole" -Body @{ Privileges = @($missingComponent | ForEach-Object { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.RolePrivilege'; PrivilegeId = $_.privilegeid; Depth = 'Global' } }) } | Out-Null }
if ($extraPrivs) { Add-Step 'Dataverse' 'Role privileges: read on tables outside the solution' 'EXTRA' "$($extraPrivs -join ', '): remove by hand; this script never removes" $null }
Add-Step 'Dataverse' "Application user for $AppName" ($appUser ? 'exists' : 'create') "root business unit" {
    Invoke-Api -Method POST -Uri "$dv/systemusers" -Retries 6 -Body @{ applicationid = $state.AppId; 'businessunitid@odata.bind' = "/businessunits($($rootBu.businessunitid))" } | Out-Null
    $state.UserId = (Invoke-Api -Uri "$dv/systemusers?`$select=systemuserid&`$filter=applicationid eq $($state.AppId)").value[0].systemuserid }
Add-Step 'Dataverse' "Assign '$RoleName' to the application user" (($appUserRoles -contains $RoleName) ? 'exists' : 'create') 'only role it holds' {
    Invoke-Api -Method POST -Uri "$dv/systemusers($($state.UserId))/systemuserroles_association/`$ref" -Body @{ '@odata.id' = "$dv/roles($($state.RoleId))" } | Out-Null }
}

# ---------- report ----------
Write-Host "`nPLAN"
Write-Host "  Signed in as : $($me.userPrincipalName)"
Write-Host "  Subscription : $($sub.displayName) ($($sub.state))"
if ($SkipDataverse) { Write-Host '  Environment  : skipped (-SkipDataverse): run again with -EnvironmentUrl after the solution is imported' }
else { Write-Host "  Environment  : $($org.Detail.FriendlyName), solution $SolutionUniqueName (prefix $prefix)" }
foreach ($area in @('Azure', 'Entra') + @(if (-not $SkipDataverse) { 'Dataverse' })) {
    Write-Host "`n$area"
    foreach ($s in @($plan | Where-Object Area -eq $area)) { Write-Host ("  {0,-8} {1,-62} {2}" -f $s.Status, $s.Name, $s.Detail) }
}
$conflicts = @($plan | Where-Object Status -like 'CONFLICT*'); $todo = @($plan | Where-Object Status -eq 'create')
Write-Host "`nTotal: $($todo.Count) to create, $($conflicts.Count) conflict(s)."
if (-not $Apply) { Write-Host 'Plan only. Nothing was changed. Re-run with -Apply to create.'; return }
if ($conflicts) { throw 'Refusing to apply: resolve the conflicts above first. This script never changes existing objects.' }

# ---------- apply ----------
$n = 0
foreach ($s in $todo) { $n++; Write-Host ("[{0}/{1}] {2}: {3}" -f $n, $todo.Count, $s.Area, $s.Name); & $s.Action $s.Data }
Write-Host "`nDone. Application (client) ID: $($state.AppId). Verify with setup/Test-ReaderIdentity.ps1."
