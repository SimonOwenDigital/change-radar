#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the handler switching cases (tests/handlers/handlers.json) against engine/ChangeRadar.Handlers.psm1. Exit code 1 on any failure.
#>
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot '..' 'tests' 'handlers' 'handlers.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Handlers.psm1') -Force
$d = Get-Content -Raw $Path -Encoding utf8 | ConvertFrom-Json -Depth 10
$rows = foreach ($c in $d.cases) {
    $installed = if ($c.PSObject.Properties['installed']) { @($c.installed) } else { @($d.installed) }
    $flowsOn = if ($c.PSObject.Properties['state']) { @($c.state.flowsOn) } else { @() }
    $subsOn = if ($c.PSObject.Properties['state']) { @($c.state.subscriptionsEnabled) } else { @() }
    $inst = @($installed | ForEach-Object { [pscustomobject]@{ flow = $_.flow; on = ($flowsOn -contains ($_.flow -replace '^Change Radar handler: ', '')) -or [bool]$_.on } })
    $subs = @($d.subscriptions | ForEach-Object { [pscustomobject]@{ name = $_.name; handler = $_.handler; enabled = ($subsOn -contains $_.name) -or [bool]$_.enabled } })
    $got = Get-HandlerPlan -Installed $inst -Subscriptions $subs -On @($c.on) -Off @($c.off)
    $ok = "$($got.error)" -eq "$($c.expected.error)" -and ((@($got.steps) -join '|') -eq (@($c.expected.steps) -join '|'))
    [pscustomobject]@{ Case = $c.id; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Got = $(if ($got.error) { $got.error } else { @($got.steps) -join '; ' }) }
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220
$failed = @($rows | Where-Object Result -eq 'FAIL').Count
"$(@($rows).Count - $failed) passed, $failed failed, $(@($rows).Count) cases"
if ($failed) { exit 1 }
