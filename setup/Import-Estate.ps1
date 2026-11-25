#Requires -Version 7.0
<#
.SYNOPSIS
    Loads a synthetic or fixture estate file into crdr_asset and crdr_assetfingerprint, in an evaluation,
    training or development environment (ADR 0008: phase 1b folded into phase 2). Plans by default; -Apply to write.

.DESCRIPTION
    Fingerprints the estate with the reference engine (engine/ChangeRadar.Matching.psm1, Get-AssetFingerprints),
    then upserts one asset per inventory resource and one fingerprint per facet, with its evidence.

    - Refuses live estates. The 'collect estate inventory' flow writes live assets, so there's one writer per source.
    - Every row is labelled: source = synthetic or fixture, plus the synthetic organisation (spec §15.2).
    - Row ids are derived from the source id, so a rerun updates in place. Fingerprints that are no longer
      produced, and assets of the same organisation that are no longer in the file, are deleted.
    - Writes only to the environment named by -ExpectedEnvironmentName.
    - Refuses a Production environment (checked with the Power Platform admin API when the signed-in user can read it;
      otherwise -NotProduction must be given to confirm). setup/Import-DemoData.ps1 calls this script.
.EXAMPLE
    pwsh -File setup/Import-Estate.ps1 -EnvironmentUrl <url> -EstatePath samples/synthetic/mid-size-enterprise/estate.json -ExpectedEnvironmentName '<friendly name>' -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$EstatePath,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' 'solutions' 'design' 'schema.json'),
    [int]$BatchSize = 500,
    [switch]$NotProduction,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' 'engine' 'ChangeRadar.Matching.psm1') -Force

function Get-OptionalProperty($Object, [string]$Name) { if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } }
function Get-Token { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText }
function Invoke-Dv([string]$Path) {
    $h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'odata.maxpagesize=5000' }
    Invoke-RestMethod -Uri "$dv/$Path" -Headers $h
}
function Get-All([string]$Path) {
    $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-Dv $Path
    while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Uri $r.'@odata.nextLink' -Headers @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json' } }
    $rows.ToArray()   # unrolled: callers wrap in @()
}
function New-StableGuid([string]$text) {
    # Name-based id (SHA-256, first 16 bytes, RFC 4122 version and variant bits): same input, same row.
    $b = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("change-radar|$text"))[0..15]
    $b[6] = ($b[6] -band 0x0F) -bor 0x50; $b[8] = ($b[8] -band 0x3F) -bor 0x80
    $hex = -join ($b | ForEach-Object { $_.ToString('x2') })
    '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}
function Invoke-Batch([object[]]$Requests) {
    # Requests: @{ Method; Path; Body }. Independent operations (no change set), so one failure doesn't roll back the rest.
    for ($i = 0; $i -lt $Requests.Count; $i += $BatchSize) {
        $chunk = $Requests[$i..([Math]::Min($i + $BatchSize, $Requests.Count) - 1)]
        $id = "batch_$([guid]::NewGuid())"; $sb = [Text.StringBuilder]::new()
        foreach ($rq in $chunk) {
            [void]$sb.Append("--$id`r`nContent-Type: application/http`r`nContent-Transfer-Encoding: binary`r`n`r`n$($rq.Method) $dv/$($rq.Path) HTTP/1.1`r`n")
            if ($null -ne $rq.Body) { [void]$sb.Append("Content-Type: application/json; charset=utf-8`r`n`r`n$($rq.Body | ConvertTo-Json -Depth 10 -Compress)`r`n") } else { [void]$sb.Append("`r`n") }
        }
        [void]$sb.Append("--$id--`r`n")
        $h = @{ Authorization = "Bearer $(Get-Token)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'odata.continue-on-error' }
        $resp = Invoke-WebRequest -Method POST -Uri "$dv/`$batch" -Headers $h -ContentType "multipart/mixed; boundary=$id" -Body ([Text.Encoding]::UTF8.GetBytes($sb.ToString()))
        $text = [Text.Encoding]::UTF8.GetString($resp.Content)
        $bad = @([regex]::Matches($text, 'HTTP/1\.1 (4\d\d|5\d\d)[^\r\n]*') | ForEach-Object Value)
        if ($bad.Count) { $msg = [regex]::Match($text, '"message":"([^"]+)"').Groups[1].Value; throw "Batch had $($bad.Count) failed request(s), first: $($bad[0]) $msg" }
        Write-Host "  batch $([Math]::Floor($i / $BatchSize) + 1): $($chunk.Count) request(s) ok"
    }
}

# ---------- guard and inputs ----------
$org = Invoke-Dv 'RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType''Default'')'
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Stopping." }
$sku = $null
try {
    $bapToken = ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl 'https://service.powerapps.com/' -AsSecureString).Token -AsPlainText
    $sku = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $bapToken" } -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($org.Detail.EnvironmentId)?api-version=2020-10-01").properties.environmentSku
} catch { $sku = $null }
if ($sku -eq 'Production') { throw "'$ExpectedEnvironmentName' is a Production environment. Synthetic and fixture data is never loaded in production." }
if (-not $sku -and -not $NotProduction) { throw "Couldn't read the environment type. If '$ExpectedEnvironmentName' is not a production environment, re-run with -NotProduction." }
$estate = Get-Content -Raw $EstatePath | ConvertFrom-Json -Depth 50
$source = $estate.meta.source
if ($source -eq 'live') { throw "Live estates are written by the 'collect estate inventory' flow, not this loader (ADR 0008)." }
$org = $estate.meta.syntheticOrg
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) { $i = [array]::IndexOf(@($schema.choices.$choice), $value); if ($i -lt 0) { throw "'$value' isn't a $choice option." }; $base + $i }

$fps = @(Get-AssetFingerprints -Estate $estate -Context (Import-MatchingContext))   # also asserts one source and a named organisation
$envById = @{}; foreach ($e in $estate.environments) { $envById[$e.name] = $e }
$principalById = @{}; foreach ($p in @($estate.principals)) { $principalById[$p.id] = $p }
$invById = @{}; foreach ($r in $estate.inventory) { $invById[$r.name] = $r }

# ---------- desired rows ----------
$assets = [ordered]@{}; $fingerprints = [ordered]@{}
foreach ($fp in $fps) {
    $r = $invById[$fp.assetId]; $p = $r.properties
    $envId = [string](Get-OptionalProperty $p 'environmentId')
    $sourceId = "$source/$org|$envId|$($r.name)|"
    $assetId = New-StableGuid $sourceId
    $owner = $principalById[[string](Get-OptionalProperty $p 'ownerId')]
    $env = $envById[$envId]
    $assets[$assetId] = [ordered]@{
        crdr_name = [string]$p.displayName; crdr_resourcetype = $r.type; crdr_sourceid = $sourceId
        crdr_environmentid = $envId; crdr_environmentname = $(if ($env) { [string]$env.properties.displayName } else { $null })
        crdr_environmenttype = $(if ($fp.environmentType) { Get-Opt 'environmenttype' $fp.environmentType } else { $null })
        crdr_ownerobjectid = [string](Get-OptionalProperty $p 'ownerId'); crdr_ownerkind = $(if ($owner) { [string]$owner.kind } else { $null })
        crdr_lastmodified = Get-OptionalProperty $p 'lastModifiedAt'; crdr_lastseen = $estate.meta.asOf
        crdr_source = Get-Opt 'assetsource' $source; crdr_syntheticorg = $org
    }
    foreach ($f in $fp.facets) {
        $fid = New-StableGuid "$sourceId|$($f.facet)|$($f.value)"
        if ($fingerprints.Contains($fid)) { continue }   # the same facet value from two fields: keep the first evidence
        $fingerprints[$fid] = [ordered]@{
            crdr_name = "$($f.facet): $($f.value)".Substring(0, [Math]::Min(200, "$($f.facet): $($f.value)".Length)); crdr_facet = Get-Opt 'facet' $f.facet
            crdr_value = [string]$f.value; crdr_evidence = ([string]$f.evidence).Substring(0, [Math]::Min(1000, ([string]$f.evidence).Length))
            'crdr_asset@odata.bind' = "/crdr_assets($assetId)"
        }
    }
}

# Solutions (ADR 0020): the file's solutionMembership through the engine's rule (engine/ChangeRadar.Solutions.psm1),
# one crdr_solution per environment and unique name, one crdr_solutionmember per asset and solution.
Import-Module (Join-Path $PSScriptRoot '..' 'engine' 'ChangeRadar.Solutions.psm1') -Force
$memberIn = @(if ($estate.PSObject.Properties['solutionMembership']) { $estate.solutionMembership })
$solAssets = @($assets.Keys | ForEach-Object { $res = ($assets[$_].crdr_sourceid -split '\|')[2]; [pscustomobject]@{ assetid = $_; componentid = $res; sourceid = $assets[$_].crdr_sourceid } })
$solComponents = @($memberIn | ForEach-Object { [pscustomobject]@{ objectid = $_.resourceId; uniquename = $_.uniqueName; friendlyname = $_.displayName; publisher = $_.publisher; ismanaged = [bool]$_.managed } })
$membership = @(Get-SolutionMembership -Assets $solAssets -Components $solComponents -MicrosoftPublishers @())
$solutions = [ordered]@{}; $members = [ordered]@{}
foreach ($m in $membership) {
    $a = $assets[$m.assetid]; $envId = $a.crdr_environmentid
    $sid = New-StableGuid "$source/$org|solution|$envId|$($m.uniquename)"
    if (-not $solutions.Contains($sid)) {
        $solutions[$sid] = [ordered]@{ crdr_name = $m.displayname; crdr_uniquename = $m.uniquename; crdr_environmentid = $envId; crdr_environmentname = $a.crdr_environmentname
            crdr_publisher = $m.publisher; crdr_managed = $m.managed; crdr_microsoft = $m.microsoft; crdr_source = Get-Opt 'assetsource' $source; crdr_syntheticorg = $org }
    }
    $members[(New-StableGuid "$($a.crdr_sourceid)|solution|$($m.uniquename)")] = [ordered]@{
        crdr_name = "$($a.crdr_name) in $($m.displayname)".Substring(0, [Math]::Min(400, "$($a.crdr_name) in $($m.displayname)".Length))
        'crdr_asset@odata.bind' = "/crdr_assets($($m.assetid))"; 'crdr_solution@odata.bind' = "/crdr_solutions($sid)"; crdr_source = Get-Opt 'assetsource' $source }
}

# ---------- current rows for this organisation ----------
$orgFilter = { param($prefix) "${prefix}crdr_source eq $(Get-Opt 'assetsource' $source) and ${prefix}crdr_syntheticorg eq '$($org.Replace("'", "''"))'" }
$curAssets = @(Get-All "crdr_assets?`$select=crdr_assetid&`$filter=$(& $orgFilter '')")
$curFps = @(Get-All "crdr_assetfingerprints?`$select=crdr_assetfingerprintid&`$filter=$(& $orgFilter 'crdr_asset/')")
$staleAssets = @($curAssets | Where-Object { -not $assets.Contains($_.crdr_assetid) })
$staleFps = @($curFps | Where-Object { -not $fingerprints.Contains($_.crdr_assetfingerprintid) })
$curSolutions = @(Get-All "crdr_solutions?`$select=crdr_solutionid&`$filter=$(& $orgFilter '')")
$curMembers = @(Get-All "crdr_solutionmembers?`$select=crdr_solutionmemberid&`$filter=$(& $orgFilter 'crdr_asset/')")
$staleSolutions = @($curSolutions | Where-Object { -not $solutions.Contains($_.crdr_solutionid) })
$staleMembers = @($curMembers | Where-Object { -not $members.Contains($_.crdr_solutionmemberid) })

Write-Host "`nPLAN ($ExpectedEnvironmentName): $source estate '$org' from $EstatePath"
Write-Host ("  assets:       {0} in file, {1} in Dataverse, {2} to delete" -f $assets.Count, $curAssets.Count, $staleAssets.Count)
Write-Host ("  fingerprints: {0} in file, {1} in Dataverse, {2} to delete" -f $fingerprints.Count, $curFps.Count, $staleFps.Count)
$fps.facets | Group-Object facet | Sort-Object Name | ForEach-Object { Write-Host ("    {0,-18} {1}" -f $_.Name, $_.Count) }
Write-Host ("  solutions:    {0} in file, {1} in Dataverse, {2} to delete" -f $solutions.Count, $curSolutions.Count, $staleSolutions.Count)
Write-Host ("  memberships:  {0} in file, {1} in Dataverse, {2} to delete" -f $members.Count, $curMembers.Count, $staleMembers.Count)
if (-not $Apply) { return }

Write-Host 'Upserting assets...'
Invoke-Batch @($assets.Keys | ForEach-Object { @{ Method = 'PATCH'; Path = "crdr_assets($_)"; Body = $assets[$_] } })
Write-Host 'Upserting fingerprints...'
Invoke-Batch @($fingerprints.Keys | ForEach-Object { @{ Method = 'PATCH'; Path = "crdr_assetfingerprints($_)"; Body = $fingerprints[$_] } })
if ($staleFps.Count) { Write-Host 'Deleting stale fingerprints...'; Invoke-Batch @($staleFps | ForEach-Object { @{ Method = 'DELETE'; Path = "crdr_assetfingerprints($($_.crdr_assetfingerprintid))" } }) }
if ($solutions.Count) { Write-Host 'Upserting solutions...'; Invoke-Batch @($solutions.Keys | ForEach-Object { @{ Method = 'PATCH'; Path = "crdr_solutions($_)"; Body = $solutions[$_] } }) }
if ($members.Count) { Write-Host 'Upserting solution memberships...'; Invoke-Batch @($members.Keys | ForEach-Object { @{ Method = 'PATCH'; Path = "crdr_solutionmembers($_)"; Body = $members[$_] } }) }
if ($staleMembers.Count) { Write-Host 'Deleting stale memberships...'; Invoke-Batch @($staleMembers | ForEach-Object { @{ Method = 'DELETE'; Path = "crdr_solutionmembers($($_.crdr_solutionmemberid))" } }) }
if ($staleAssets.Count) { Write-Host 'Deleting stale assets...'; Invoke-Batch @($staleAssets | ForEach-Object { @{ Method = 'DELETE'; Path = "crdr_assets($($_.crdr_assetid))" } }) }
if ($staleSolutions.Count) { Write-Host 'Deleting stale solutions...'; Invoke-Batch @($staleSolutions | ForEach-Object { @{ Method = 'DELETE'; Path = "crdr_solutions($($_.crdr_solutionid))" } }) }
Write-Host 'Done.'
