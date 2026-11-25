#Requires -Version 7.0
<#
.SYNOPSIS
    Checks every active signal's theme and nature against the rules (engine Get-RuleTheme, Get-RuleNature,
    seed/theme-rules.csv); -Backfill writes the rule value where it differs.
.DESCRIPTION
    ADR 0012 addendum (2026-11-22). Read-only unless -Backfill, which updates crdr_theme only, on Change Radar's own
    signals, only in -ExpectedEnvironmentName. Also reports the themes in use, and any theme not in seed/themes.csv.
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
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Assessment.psm1') -Force
function Get-AuthHeader { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
$org = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
$themes = @(Import-Csv (Join-Path $SeedDir 'themes.csv') | ForEach-Object theme)
$rules = Import-ThemeRules -Rules @(Import-Csv (Join-Path $SeedDir 'theme-rules.csv')) -Themes $themes -Natures @($schema.choices.nature)
$signals = @(Get-All "crdr_signals?`$select=crdr_signalid,crdr_externalid,crdr_source,crdr_theme,crdr_nature&`$expand=crdr_feed(`$select=crdr_key)&`$filter=statecode eq 0")
$ok = 0; $diff = 0; $written = 0; $natDiff = 0; $natWritten = 0
foreach ($s in $signals) {
    $sig = [pscustomobject]@{ source = @($schema.choices.signalsource)[[int]$s.crdr_source - $base]; feedKey = $(if ($s.crdr_feed) { $s.crdr_feed.crdr_key } else { $null }); theme = $s.crdr_theme }
    # ADR 0013 step 5: the rule nature (a choice value) wins too.
    $wantNature = Get-RuleNature -Signal $sig -Rules $rules
    if ($wantNature) {
        $opt = $base + [array]::IndexOf(@($schema.choices.nature), $wantNature)
        if ($s.crdr_nature -ne $opt) {
            if ($Backfill) { Invoke-RestMethod -Method Patch -Headers ((Get-AuthHeader) + @{ 'If-Match' = '*' }) -Uri "$dv/crdr_signals($($s.crdr_signalid))" -ContentType 'application/json' -Body (@{ crdr_nature = $opt } | ConvertTo-Json) | Out-Null; $natWritten++ }
            else { $natDiff++; if ($natDiff -le 5) { "  DIFF $($s.crdr_externalid): nature $($s.crdr_nature), rule $wantNature" } }
        }
    }
    $want = Get-RuleTheme -Signal $sig -Rules $rules
    if (-not $want -or $s.crdr_theme -ceq $want) { $ok++; continue }
    if ($Backfill) {
        Invoke-RestMethod -Method Patch -Headers ((Get-AuthHeader) + @{ 'If-Match' = '*' }) -Uri "$dv/crdr_signals($($s.crdr_signalid))" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes((@{ crdr_theme = $want } | ConvertTo-Json))) | Out-Null
        $written++; $s.crdr_theme = $want; $ok++
    } else { $diff++; if ($diff -le 10) { "  DIFF $($s.crdr_externalid): theme '$($s.crdr_theme)', rule '$want'" } }
}
"Signals: $($signals.Count); match the rules: $ok$(if ($diff) { "; differ: $diff" })$(if ($Backfill) { "; written: $written" })"
$signals | Group-Object { if ($_.crdr_theme) { $_.crdr_theme } else { '(no theme)' } } | Sort-Object Count -Descending | ForEach-Object { '  {0,4}  {1}{2}' -f $_.Count, $_.Name, $(if ($_.Name -ne '(no theme)' -and $themes -cnotcontains $_.Name) { '  (NOT IN themes.csv)' }) }
"Natures: $(if ($Backfill) { "written $natWritten" } else { "$natDiff differ from the rules" })"
if ($diff -or $natDiff) { "MISMATCH: $($diff + $natDiff)"; exit 1 }
