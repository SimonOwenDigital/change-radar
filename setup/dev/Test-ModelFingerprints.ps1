#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the rule fingerprints of the model lifecycle signals against the engine (ADR 0013); -Backfill creates missing ones.
.DESCRIPTION
    For each active learnpage_tables feed: fetches the live page, runs engine Invoke-FeedAdapter with the model map from
    seed/vocabulary.csv, and compares each stored signal's rule fingerprints (extracted by = rule) with the engine's:
    model, resource type, harness. Read-only unless -Backfill, which creates the missing rule fingerprints (group A,
    accepted, confidence 1) for signals created before the collector wrote them, including group B (ADR 0017). Only in -ExpectedEnvironmentName.
    Exits 1 on any difference left.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [switch]$Backfill,
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json'),
    [string]$SeedDir = (Join-Path $PSScriptRoot '..' '..' 'seed')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Matching.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Feeds.psm1') -Force
function Get-AuthHeader { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
$org = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) { $base + [array]::IndexOf(@($schema.choices.$choice), $value) }
function Get-Label([string]$choice, $value) { @($schema.choices.$choice)[[int]$value - $base] }
$map = Import-ModelMap -SeedDir $SeedDir
$config = @{}; Import-Csv (Join-Path $SeedDir 'config.csv') | ForEach-Object { $config[$_.key] = $_.value }
$tables = Get-Opt 'feedkind' 'learnpage_tables'
$bad = 0; $created = 0
foreach ($f in @(Get-All "crdr_feeds?`$select=crdr_feedid,crdr_key,crdr_url,crdr_products,crdr_profile&`$filter=crdr_active eq true and crdr_kind eq $tables")) {
    $content = (Invoke-WebRequest -Uri $f.crdr_url -UserAgent 'change-radar-parity/0.1').Content
    $row = [pscustomobject]@{ key = $f.crdr_key; kind = 'learnpage_tables'; url = $f.crdr_url; products = $f.crdr_products }
    $r = Invoke-FeedAdapter -Content $content -Feed $row -FeedProfile ($f.crdr_profile | ConvertFrom-Json -Depth 20) -Today ([datetime]::UtcNow.Date) -Config $config -ModelMap $map
    $signals = @{}; foreach ($s in @(Get-All "crdr_signals?`$select=crdr_signalid,crdr_externalid&`$filter=_crdr_feed_value eq $($f.crdr_feedid)")) { $signals[$s.crdr_externalid] = $s.crdr_signalid }
    $ok = 0; $missing = 0
    foreach ($id in @($r.fingerprints | ForEach-Object externalid | Sort-Object -Unique)) {
        if (-not $signals.ContainsKey($id)) { continue }
        # Group-qualified (ADR 0017 adds group B for the flows that call a prompt).
        $want = @($r.fingerprints | Where-Object externalid -ceq $id | ForEach-Object { "$($_.group):$($_.facet)=$($_.value)" } | Sort-Object)
        $stored = @(Get-All "crdr_signalfingerprints?`$select=crdr_group,crdr_facet,crdr_value&`$filter=_crdr_signal_value eq $($signals[$id]) and crdr_extractedby eq $(Get-Opt 'extractedby' 'rule')" | ForEach-Object { "$($_.crdr_group):$(Get-Label 'facet' $_.crdr_facet)=$($_.crdr_value)" } | Sort-Object)
        $absent = @($r.fingerprints | Where-Object { $_.externalid -ceq $id -and $stored -cnotcontains "$($_.group):$($_.facet)=$($_.value)" })
        $extra = @($stored | Where-Object { $want -cnotcontains $_ })
        if ($absent.Count -and -not $extra.Count -and $Backfill) {
            foreach ($fp in $absent) {
                $reason = if ($fp.group -eq 'B') { 'Rule fingerprint from the Learn model lifecycle table (ADR 0017): the model and the capability of the flows that call such a prompt.' } else { "Rule fingerprint from the Learn model lifecycle table (ADR 0013): the model and the table's scope." }
                $body = @{ crdr_name = "$($fp.facet): $($fp.value)"; 'crdr_signal@odata.bind' = "/crdr_signals($($signals[$id]))"; crdr_group = $fp.group; crdr_facet = (Get-Opt 'facet' $fp.facet); crdr_value = $fp.value
                    crdr_extractedby = (Get-Opt 'extractedby' 'rule'); crdr_confidence = 1; crdr_status = (Get-Opt 'fingerprintstatus' 'accepted'); crdr_reason = $reason }
                Invoke-RestMethod -Method Post -Headers (Get-AuthHeader) -Uri "$dv/crdr_signalfingerprints" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json))) | Out-Null; $created++
            }
            $ok++; continue
        }
        if (($stored -join ', ') -ceq ($want -join ', ')) { $ok++ } elseif (-not $stored.Count) { $missing++ } else { $bad++; "  DIFF ${id}: stored [$($stored -join ', ')], engine [$($want -join ', ')]" }
    }
    "== $($f.crdr_key): $ok match$(if ($missing) { ", $missing without rule fingerprints" })$(if ($r.gaps.Count) { "; engine gaps: $($r.gaps -join '; ')" })"
    $bad += $missing
}
if ($Backfill) { "Created $created rule fingerprint(s)." }
if ($bad) { "MISMATCH: $bad"; exit 1 }
