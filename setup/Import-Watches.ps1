#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the example watch list topics (ADR 0015) from seed/watches.csv. Plans by default.
.DESCRIPTION
    Watches are the installer's own data: people edit their words in the app. So this script only creates a watch whose
    name doesn't exist yet, and never changes an existing one, except to switch it on or off with -Activate or
    -Deactivate (by name). A new watch is created switched OFF, whatever the seed says. Never deletes.
    Runs as the signed-in user (Az.Accounts), only in the environment named -ExpectedEnvironmentName.
.EXAMPLE
    ./Import-Watches.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>'
    ./Import-Watches.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>' -Apply -Activate 'Copilot Autopilot in the UK'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string[]]$Activate = @(),
    [string[]]$Deactivate = @(),
    [string]$WatchesPath = (Join-Path $PSScriptRoot '..' 'seed' 'watches.csv'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Invoke-Dv([string]$Path, [string]$Method = 'GET', $Body) {
    $h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' }
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = $h }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5)); $p.ContentType = 'application/json; charset=utf-8' }
    Invoke-RestMethod @p
}
$org = Invoke-Dv "RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$set = (Invoke-Dv "EntityDefinitions(LogicalName='crdr_watch')?`$select=EntitySetName").EntitySetName

$current = @{}; foreach ($r in @((Invoke-Dv "${set}?`$select=crdr_watchid,crdr_name,crdr_active").value)) { $current[$r.crdr_name] = $r }
$steps = [Collections.Generic.List[object]]::new()
foreach ($w in Import-Csv $WatchesPath -Encoding utf8) {
    $cur = $current[$w.name]
    if (-not $cur) {
        $steps.Add([pscustomobject]@{ Name = $w.name; Status = 'create'; Path = $set; Method = 'POST'
                Body = [ordered]@{ crdr_name = $w.name; crdr_anyof = $w.any_of; crdr_alsooneof = $w.also_one_of; crdr_ignorephrases = $w.ignore_phrases
                    crdr_products = $w.products; crdr_description = $w.description; crdr_active = ($Activate -contains $w.name) } })
        continue
    }
    $want = if ($Activate -contains $w.name) { $true } elseif ($Deactivate -contains $w.name) { $false } else { [bool]$cur.crdr_active }
    if ($want -ne [bool]$cur.crdr_active) { $steps.Add([pscustomobject]@{ Name = $w.name; Status = 'update'; Path = "$set($($cur.crdr_watchid))"; Method = 'PATCH'; Body = @{ crdr_active = $want } }) }
    else { $steps.Add([pscustomobject]@{ Name = $w.name; Status = 'exists'; Path = $null; Method = $null; Body = $null }) }
}
"PLAN ($ExpectedEnvironmentName; entity set $set)"
$steps | ForEach-Object { "  {0,-8} {1}{2}" -f $_.Status, $_.Name, $(if ($_.Body) { "  (active=$($_.Body.crdr_active))" }) }
if (-not $Apply) { 'Plan only. Nothing was changed. Re-run with -Apply.'; return }
$i = 0
foreach ($s in @($steps | Where-Object Status -in 'create', 'update')) { $i++; Invoke-Dv $s.Path $s.Method $s.Body | Out-Null }
"Done: $i change(s)."
