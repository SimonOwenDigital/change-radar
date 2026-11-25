#Requires -Version 7.0
<#
.SYNOPSIS
    Counts the actions Change Radar's flows executed in a time window, to estimate what they would cost as
    Copilot Studio agent flows (ADR 0016). Read-only: reads run history through the Flow management API.
.DESCRIPTION
    For every flow whose display name starts with "Change Radar", reads the runs that started in the window. For each
    run, every action is counted once per repetition (actions inside loops run many times), plus one for the trigger.
    Skipped actions are counted separately, because whether a skipped action is billed isn't documented.
    Flows with more runs than -MaxRunsPerFlow are sampled and the total is extrapolated (marked "est.").
    Agent flow rate used: 13 Copilot credits per 100 actions (Learn, "Billing rates and management", checked 2026-11-23).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentId,
    [Parameter(Mandatory)][datetime]$Since,
    [datetime]$Until = (Get-Date).ToUniversalTime(),
    [int]$MaxRunsPerFlow = 5,
    [string]$OutFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
$script:h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl 'https://service.flow.microsoft.com/' -AsSecureString).Token -AsPlainText)" }
$api = 'api-version=2016-11-01'
$root = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments/$EnvironmentId"

function Get-All([string]$Url) {
    $items = [System.Collections.Generic.List[object]]::new()
    while ($Url) {
        $page = Invoke-RestMethod $Url -Headers $script:h
        foreach ($v in @($page.value)) { $items.Add($v) }
        $Url = $page.PSObject.Properties['nextLink'] ? $page.nextLink : $null
    }
    , $items
}

function Measure-Run([string]$FlowUrl, [string]$RunName) {
    $executed = 1; $skipped = 0   # 1 = the trigger
    foreach ($a in (Get-All "$FlowUrl/runs/$RunName/actions?$api")) {
        $reps = $null
        try { $reps = Get-All "$FlowUrl/runs/$RunName/actions/$($a.name)/repetitions?$api" } catch { $reps = $null }
        if ($reps -and $reps.Count -gt 0) {
            $s = @($reps | Where-Object { $_.properties.status -eq 'Skipped' }).Count
            $executed += $reps.Count - $s; $skipped += $s
        } elseif ($a.properties.status -eq 'Skipped') { $skipped++ }
        else { $executed++ }
    }
    [pscustomobject]@{ Executed = $executed; Skipped = $skipped }
}

$rows = foreach ($f in (Get-All "$root/flows?$api") | Where-Object { $_.properties.displayName -like 'Change Radar*' } | Sort-Object { $_.properties.displayName }) {
    $fu = "$root/flows/$($f.name)"
    $runs = @((Get-All "$fu/runs?$api") | Where-Object {
        $t = [datetime]$_.properties.startTime; $t -ge $Since -and $t -lt $Until })
    $sample = @($runs | Select-Object -First $MaxRunsPerFlow)
    $ex = 0; $sk = 0
    foreach ($r in $sample) { $m = Measure-Run $fu $r.name; $ex += $m.Executed; $sk += $m.Skipped }
    $factor = if ($sample.Count) { $runs.Count / $sample.Count } else { 0 }
    [pscustomobject]@{
        Flow      = $f.properties.displayName -replace '^Change Radar(: | handler: )', ''
        Runs      = $runs.Count
        Measured  = $sample.Count
        Executed  = [int][math]::Round($ex * $factor)
        Skipped   = [int][math]::Round($sk * $factor)
        PerRun    = if ($sample.Count) { [int][math]::Round($ex / $sample.Count) } else { 0 }
        Estimated = $factor -gt 1
    }
}
$total = ($rows | Measure-Object Executed -Sum).Sum
$totalSk = ($rows | Measure-Object Skipped -Sum).Sum
$rows | Sort-Object Executed -Descending | Format-Table -AutoSize | Out-String -Width 200
"Window: $($Since.ToString('u')) to $($Until.ToString('u'))"
"Executed actions: $total (plus $totalSk skipped). As agent flows: $([math]::Round($total * 0.13)) Copilot credits ($([math]::Round(($total + $totalSk) * 0.13)) if skipped actions count)."
if ($OutFile) { $rows | ConvertTo-Json | Set-Content $OutFile }
