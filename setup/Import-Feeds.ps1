#Requires -Version 7.0
<#
.SYNOPSIS
    Loads the generic feeds (ADR 0014) into crdr_feed. Plans by default; -Apply to change.
.DESCRIPTION
    Upserts crdr_feed from seed/feeds.csv, with each row's profile JSON from seed/feed-profiles/ (key: crdr_key), as
    the signed-in user (Az.Accounts), only in the environment named -ExpectedEnvironmentName.
    A new feed is created switched OFF, so nothing is collected or spent until you choose; -UseSeedActive creates new
    feeds with the seed's 'active' column instead (the feeds the project recommends). An existing feed's 'active' is an installer choice and is never changed, except
    for the keys passed with -Activate or -Deactivate. Never deletes; a feed no longer in the seed is reported only.
.EXAMPLE
    ./Import-Feeds.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>'
    ./Import-Feeds.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<name>' -Apply -Activate ML-CSM
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string[]]$Activate = @(),
    [string[]]$Deactivate = @(),
    [switch]$UseSeedActive,     # new feeds take the seed's 'active' column instead of starting off
    [string]$FeedsPath = (Join-Path $PSScriptRoot '..' 'seed' 'feeds.csv'),
    [string]$ProfileDir = (Join-Path $PSScriptRoot '..' 'seed' 'feed-profiles'),
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' 'solutions' 'design' 'schema.json'),
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

$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) { $i = [array]::IndexOf(@($schema.choices.$choice), $value); if ($i -lt 0) { throw "'$value' is not a $choice choice." }; $base + $i }

$cols = 'crdr_feedid,crdr_key,crdr_name,crdr_kind,crdr_url,crdr_products,crdr_horizonrule,crdr_profile,crdr_active,crdr_description,crdr_unrated'
$current = @{}; foreach ($r in @((Invoke-Dv "crdr_feeds?`$select=$cols").value)) { $current[$r.crdr_key] = $r }
$steps = [Collections.Generic.List[object]]::new()
$seedKeys = @()
foreach ($f in Import-Csv $FeedsPath -Encoding utf8) {
    $seedKeys += $f.key
    $profile = Get-Content -Raw (Join-Path $ProfileDir $f.profile) -Encoding utf8 | ConvertFrom-Json -Depth 20 | ConvertTo-Json -Depth 20 -Compress
    $want = [ordered]@{ crdr_key = $f.key; crdr_name = $f.name; crdr_kind = (Get-Opt 'feedkind' $f.kind); crdr_url = $f.url; crdr_products = $f.products
        crdr_horizonrule = (Get-Opt 'horizonrule' $f.horizon_rule); crdr_profile = $profile; crdr_description = $f.description
        # ADR 0018/0019: signals from an unrated feed are never fingerprinted or rated.
        crdr_unrated = ($f.PSObject.Properties['unrated'] -and $f.unrated -eq 'true') }
    $cur = $current[$f.key]
    $active = if ($Activate -contains $f.key) { $true } elseif ($Deactivate -contains $f.key) { $false } elseif ($cur) { [bool]$cur.crdr_active } else { [bool]($UseSeedActive -and $f.active -eq 'true') }
    if (-not $cur) { $steps.Add([pscustomobject]@{ Key = $f.key; Status = 'create'; Path = 'crdr_feeds'; Method = 'POST'; Body = ($want + @{ crdr_active = $active }) }); continue }
    $diff = @($want.Keys | Where-Object { "$($cur.$_)" -ne "$($want[$_])" })
    if ([bool]$cur.crdr_active -ne $active) { $diff += 'crdr_active' }
    if ($diff) { $steps.Add([pscustomobject]@{ Key = $f.key; Status = 'update'; Path = "crdr_feeds($($cur.crdr_feedid))"; Method = 'PATCH'; Body = ($want + @{ crdr_active = $active }); Detail = ($diff -join ', ') }) }
    else { $steps.Add([pscustomobject]@{ Key = $f.key; Status = 'exists'; Path = $null; Method = $null; Body = $null }) }
}
foreach ($k in $current.Keys) { if ($seedKeys -notcontains $k) { $steps.Add([pscustomobject]@{ Key = $k; Status = 'not in seed (left alone)'; Path = $null; Method = $null; Body = $null }) } }

"PLAN ($ExpectedEnvironmentName)"
$steps | ForEach-Object { "  {0,-26} {1,-8} {2}" -f $_.Status, $_.Key, $(if ($_.Body) { "active=$($_.Body.crdr_active)" + $(if ($_.PSObject.Properties['Detail']) { "; changes: $($_.Detail)" }) }) }
if (-not $Apply) { 'Plan only. Nothing was changed. Re-run with -Apply.'; return }
$i = 0
foreach ($s in @($steps | Where-Object Status -in 'create', 'update')) { $i++; Invoke-Dv $s.Path $s.Method $s.Body | Out-Null }
"Done: $i change(s)."
