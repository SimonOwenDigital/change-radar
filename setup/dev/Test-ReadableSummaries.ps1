#Requires -Version 7.0
<#
.SYNOPSIS
    Checks crdr_signal.crdr_summarytext against engine ConvertTo-ReadableText; with -Backfill, fills the empty ones.
.DESCRIPTION
    Read-only by default: for every active signal, compares the stored readable summary with the engine's output from
    crdr_summary and reports matches, differences and empties. -Backfill writes the engine's text into signals whose
    readable summary is still empty (signals collected before the Readable summary flow existed); it never overwrites a
    value the flow wrote. Only in the environment named -ExpectedEnvironmentName. Exits 1 on any difference.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [switch]$Backfill,
    [switch]$Rewrite   # also rewrite stored text that differs from the engine (after the engine's rules change); writes crdr_summarytext only
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..' '..' 'engine' 'ChangeRadar.Text.psm1') -Force
function Get-AuthHeader { @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'odata.maxpagesize=500' } }
function Get-All([string]$Path) { $rows = [Collections.Generic.List[object]]::new(); $r = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/$Path"; while ($true) { $rows.AddRange(@($r.value)); if (-not $r.PSObject.Properties['@odata.nextLink']) { break }; $r = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri $r.'@odata.nextLink' }; $rows.ToArray() }
$org = Invoke-RestMethod -Headers (Get-AuthHeader) -Uri "$dv/RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }

$signals = @(Get-All 'crdr_signals?$select=crdr_signalid,crdr_externalid,crdr_summary,crdr_summarytext&$filter=statecode eq 0')
$match = 0; $empty = [Collections.Generic.List[object]]::new(); $diff = [Collections.Generic.List[string]]::new(); $differing = [Collections.Generic.List[object]]::new()
foreach ($s in $signals) {
    $want = ConvertTo-ReadableText $s.crdr_summary
    if ($want.Length -gt 20000) { $want = $want.Substring(0, 20000) }
    $have = "$($s.crdr_summarytext)".Replace("`r`n", "`n")
    if (-not $s.crdr_summarytext) { if ($want) { $empty.Add([pscustomobject]@{ id = $s.crdr_signalid; text = $want }) } else { $match++ } }
    elseif ($have -ceq $want) { $match++ }
    else { $differing.Add([pscustomobject]@{ id = $s.crdr_signalid; text = $want }); $i = 0; while ($i -lt [math]::Min($have.Length, $want.Length) -and $have[$i] -eq $want[$i]) { $i++ }; $diff.Add("$($s.crdr_externalid): differs at character $i (stored '...$($have.Substring([math]::Max(0, $i - 20), [math]::Min(40, $have.Length - [math]::Max(0, $i - 20))).Replace("`n", '\n'))...')") }
}
"Signals: $($signals.Count); match the engine: $match; empty: $($empty.Count); differ: $($diff.Count)"
$diff | Select-Object -First 10 | ForEach-Object { "  DIFF $_" }
if ($Backfill -and $empty.Count) {
    $n = 0
    foreach ($e in $empty) { Invoke-RestMethod -Method Patch -Headers (Get-AuthHeader) -Uri "$dv/crdr_signals($($e.id))" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes((@{ crdr_summarytext = $e.text } | ConvertTo-Json))) | Out-Null; $n++ }
    "Backfilled $n signal(s)."
}
if ($Rewrite -and $differing.Count) {
    foreach ($e in $differing) { Invoke-RestMethod -Method Patch -Headers ((Get-AuthHeader) + @{ 'If-Match' = '*' }) -Uri "$dv/crdr_signals($($e.id))" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes((@{ crdr_summarytext = $e.text } | ConvertTo-Json))) | Out-Null }
    "Rewrote $($differing.Count) signal(s)."; exit 0
}
if ($diff.Count) { exit 1 }
