#Requires -Version 7.0
<#
.SYNOPSIS
    Solution view parity (ADR 0020): the detail flow's crdr_solution and crdr_solutionmember rows against the engine.
.DESCRIPTION
    For each environment in crdr_config detail_environments (pp-lab today): reads the environment's non-synthetic assets
    and their Dataverse solution components (read-only, as the signed-in user), works out membership with
    engine/ChangeRadar.Solutions.psm1, and compares it with the stored rows: every expected membership stored, nothing
    extra, and each solution's display name, publisher, managed and Microsoft flags as the engine says. Dev only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SignaturesPath = (Join-Path $PSScriptRoot '..' '..' 'seed' 'asset-signatures.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Solutions.psm1') -Force
function Get-Header { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; Prefer = 'odata.maxpagesize=5000' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-Header) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
$org = Invoke-RestMethod -Headers (Get-Header) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$envId = $org.Detail.EnvironmentId
$msPublishers = @((Get-Content -Raw $SignaturesPath | ConvertFrom-Json).pcfMicrosoftPublishers.values)
$synthetic = 169890002

$assets = @(Get-All "crdr_assets?`$select=crdr_assetid,crdr_name,crdr_componentid,crdr_sourceid,crdr_environmentid&`$filter=crdr_environmentid eq '$envId' and crdr_source ne $synthetic")
$engineAssets = @($assets | ForEach-Object { [pscustomobject]@{ assetid = $_.crdr_assetid; environmentid = $_.crdr_environmentid; componentid = $_.crdr_componentid; sourceid = $_.crdr_sourceid } })
$oids = @($engineAssets | ForEach-Object { Get-SolutionObjectId $_ } | Where-Object { $_ } | Sort-Object -Unique)
$components = [Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $oids.Count; $i += 25) {
    $f = (@($oids[$i..([math]::Min($i + 24, $oids.Count - 1))]) | ForEach-Object { "objectid eq $_" }) -join ' or '
    foreach ($c in Get-All "solutioncomponents?`$select=objectid&`$expand=solutionid(`$select=uniquename,friendlyname,ismanaged;`$expand=publisherid(`$select=uniquename))&`$filter=$f") {
        $components.Add([pscustomobject]@{ objectid = $c.objectid; uniquename = $c.solutionid.uniquename; friendlyname = $c.solutionid.friendlyname; publisher = $c.solutionid.publisherid.uniquename; ismanaged = $c.solutionid.ismanaged })
    }
}
$want = @(Get-SolutionMembership -Assets $engineAssets -Components $components -MicrosoftPublishers $msPublishers)

$solutions = @(Get-All "crdr_solutions?`$select=crdr_solutionid,crdr_name,crdr_uniquename,crdr_publisher,crdr_managed,crdr_microsoft&`$filter=crdr_environmentid eq '$envId'")
$members = @(Get-All "crdr_solutionmembers?`$select=_crdr_asset_value,_crdr_solution_value&`$filter=crdr_solution/crdr_environmentid eq '$envId'")
$solById = @{}; foreach ($s in $solutions) { $solById[$s.crdr_solutionid] = $s }
$got = @($members | ForEach-Object { "$($_._crdr_asset_value)|$($solById[$_._crdr_solution_value].crdr_uniquename)" } | Sort-Object)
$exp = @($want | ForEach-Object { "$($_.assetid)|$($_.uniquename)" } | Sort-Object -Unique)
$problems = [Collections.Generic.List[string]]::new()
$name = @{}; foreach ($a in $assets) { $name[$a.crdr_assetid] = $a.crdr_name }
foreach ($k in $exp) { if ($got -notcontains $k) { $p = $k -split '\|'; $problems.Add("missing: '$($name[$p[0]])' in $($p[1])") } }
foreach ($k in $got) { if ($exp -notcontains $k) { $p = $k -split '\|'; $problems.Add("extra: '$($name[$p[0]])' in $($p[1])") } }
if (@($got | Group-Object | Where-Object Count -gt 1).Count) { $problems.Add('duplicate membership rows') }
foreach ($u in @($want | Group-Object uniquename)) {
    $w = $u.Group[0]; $s = @($solutions | Where-Object crdr_uniquename -eq $u.Name)
    if ($s.Count -ne 1) { $problems.Add("solution $($u.Name): $($s.Count) rows"); continue }
    foreach ($pair in @(@('name', $w.displayname, $s[0].crdr_name), @('publisher', $w.publisher, $s[0].crdr_publisher), @('managed', $w.managed, [bool]$s[0].crdr_managed), @('microsoft', $w.microsoft, [bool]$s[0].crdr_microsoft))) {
        if ("$($pair[1])" -cne "$($pair[2])") { $problems.Add("solution $($u.Name) $($pair[0]): engine '$($pair[1])', stored '$($pair[2])'") } }
}
$stale = @($solutions | Where-Object { @($want.uniquename) -notcontains $_.crdr_uniquename })
foreach ($s in $stale) { $problems.Add("solution $($s.crdr_uniquename) stored but holds no asset") }

"$ExpectedEnvironmentName : $($assets.Count) assets, $($oids.Count) with an object id, $($components.Count) solution component rows"
"engine: $($exp.Count) memberships in $(@($want.uniquename | Sort-Object -Unique).Count) solutions; stored: $($got.Count) memberships in $($solutions.Count) solutions"
$inNone = @($engineAssets | Where-Object { @($want.assetid) -notcontains $_.assetid })
"not in a solution: $($inNone.Count) ($(@($inNone | ForEach-Object { $name[$_.assetid] }) -join ', '))"
if ($problems.Count) { $problems | ForEach-Object { "DIFF $_" }; "MISMATCH: $($problems.Count) difference(s)."; exit 1 }
'PARITY: memberships and solutions match the engine.'
