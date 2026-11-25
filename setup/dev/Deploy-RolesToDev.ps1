#Requires -Version 7.0
<#
.SYNOPSIS
    Creates Change Radar's security roles for people (solutions/design/roles.json) in a dev environment, inside the
    ChangeRadarCore solution, and links them to the Change Radar app (ADR 0022). Plans by default; -Apply to change.
.DESCRIPTION
    Additive only: creates a missing role, and adds missing privileges to an existing one. Never removes a privilege or a
    role; a privilege a role has but the design doesn't list is reported, not removed. Privileges are organisation-level
    (Global) on Change Radar's own tables (prefix crdr_). The roles ship in the solution, so installers get them by
    importing it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SolutionUniqueName = 'ChangeRadarCore',
    [string]$RolesPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'roles.json'),
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Get-Header { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-Header) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
function Invoke-Dv([string]$Method, [string]$Path, $Body) { Invoke-RestMethod -Method $Method -Uri "$dv/$Path" -Headers ((Get-Header) + @{ 'MSCRM.SolutionUniqueName' = $SolutionUniqueName }) -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10))) }

$org = Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Nothing changed." }
$design = Get-Content -Raw $RolesPath | ConvertFrom-Json -Depth 10
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$prefix = $schema.publisher.prefix
$tables = @($schema.tables | ForEach-Object { "$($prefix)_$($_.name)" })
$rootBu = @(Get-All 'businessunits?$select=businessunitid&$filter=_parentbusinessunitid_value eq null')[0].businessunitid
$allPrivs = @{}; foreach ($p in Get-All "privileges?`$select=privilegeid,name&`$filter=contains(name,'$($prefix)_')") { $allPrivs[$p.name] = $p.privilegeid }
$verbs = [ordered]@{ read = 'Read'; write = 'Write'; create = 'Create'; delete = 'Delete'; append = 'Append'; appendTo = 'AppendTo' }
function Get-Wanted($role) {
    foreach ($k in $verbs.Keys) {
        $spec = if ($role.PSObject.Properties[$k]) { $role.$k } else { @() }
        $list = if ("$spec" -eq 'all') { $tables } else { @($spec | ForEach-Object { "$($prefix)_$_" }) }
        foreach ($t in $list) { "prv$($verbs[$k])$t" }
    }
}

$plan = foreach ($role in $design.roles) {
    $existing = @(Get-All "roles?`$select=roleid,name&`$filter=name eq '$($role.name.Replace("'", "''"))' and _businessunitid_value eq $rootBu")
    $have = if ($existing) { @(Get-All "roles($($existing[0].roleid))/roleprivileges_association?`$select=name" | ForEach-Object name) } else { @() }
    $want = @(Get-Wanted $role | Sort-Object -Unique)
    $missing = @($want | Where-Object { $have -notcontains $_ })
    $unknown = @($missing | Where-Object { -not $allPrivs.ContainsKey($_) })
    $extra = @($have | Where-Object { $_ -like "prv*$($prefix)_*" -and $want -notcontains $_ })
    [pscustomobject]@{ Role = $role; Id = $(if ($existing) { $existing[0].roleid }); Missing = @($missing | Where-Object { $allPrivs.ContainsKey($_) }); Unknown = $unknown; Extra = $extra; Want = $want.Count }
}
Write-Host "`nPLAN ($ExpectedEnvironmentName / $SolutionUniqueName): security roles from $RolesPath"
foreach ($p in $plan) {
    Write-Host ("  {0,-20} {1}: {2} privileges wanted, {3} to add{4}{5}" -f $p.Role.name, $(if ($p.Id) { 'exists' } else { 'create' }), $p.Want, $p.Missing.Count, $(if ($p.Unknown) { "; UNKNOWN: $($p.Unknown -join ', ')" } else { '' }), $(if ($p.Extra) { "; has but not designed (left alone): $($p.Extra -join ', ')" } else { '' }))
}
if (@($plan | Where-Object { $_.Unknown }).Count) { throw 'Some designed privileges do not exist in this environment. Nothing changed.' }
if (-not $Apply) { Write-Host "`nPlan only. Nothing was changed. Re-run with -Apply."; return }

foreach ($p in $plan) {
    $id = $p.Id
    if (-not $id) {
        Invoke-Dv POST 'roles' @{ name = $p.Role.name; description = $p.Role.description; 'businessunitid@odata.bind' = "/businessunits($rootBu)" } | Out-Null
        $id = @(Get-All "roles?`$select=roleid&`$filter=name eq '$($p.Role.name.Replace("'", "''"))' and _businessunitid_value eq $rootBu")[0].roleid
        Write-Host "Created $($p.Role.name)"
    }
    if ($p.Missing.Count) {
        Invoke-Dv POST "roles($id)/Microsoft.Dynamics.CRM.AddPrivilegesRole" @{ Privileges = @($p.Missing | ForEach-Object { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.RolePrivilege'; PrivilegeId = $allPrivs[$_]; Depth = 'Global' } }) } | Out-Null
        Write-Host "  added $($p.Missing.Count) privileges"
    }
    Invoke-Dv POST 'AddSolutionComponent' @{ ComponentId = $id; ComponentType = 20; SolutionUniqueName = $SolutionUniqueName; AddRequiredComponents = $false; DoNotIncludeSubcomponents = $false } | Out-Null
    foreach ($app in @($p.Role.appModules)) {
        $am = @(Get-All "appmodules?`$select=appmoduleid&`$filter=uniquename eq '$app'")
        if ($am) {
            $linked = @(Get-All "appmodules($($am[0].appmoduleid))/appmoduleroles_association?`$select=roleid" | Where-Object roleid -eq $id)
            if (-not $linked) {
                Invoke-RestMethod -Method POST -Uri "$dv/appmodules($($am[0].appmoduleid))/appmoduleroles_association/`$ref" -Headers (Get-Header) -ContentType 'application/json' -Body (@{ '@odata.id' = "$dv/roles($id)" } | ConvertTo-Json) | Out-Null
                Write-Host "  linked to app $app"
            }
        }
    }
}
Write-Host 'Done.'
