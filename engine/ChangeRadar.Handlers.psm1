#Requires -Version 7.0
<#
.SYNOPSIS
    Switching handlers on and off (ADR 0023). Pure functions; setup/Set-Handlers.ps1 feeds them the environment's state.
    Cases: tests/handlers/handlers.json (run engine/Invoke-HandlerTests.ps1).
#>
Set-StrictMode -Version Latest

$script:FlowPrefix = 'Change Radar handler: '

function Get-HandlerName([string]$FlowName) {
    <# 'Change Radar handler: Notify-Teams' -> 'Notify-Teams'; anything else -> $null. #>
    if ($FlowName.StartsWith($script:FlowPrefix, [StringComparison]::OrdinalIgnoreCase)) { $FlowName.Substring($script:FlowPrefix.Length) } else { $null }
}

function Get-HandlerPlan {
    <# Installed: objects with flow (name) and on (bool). Subscriptions: objects with name, handler and enabled.
       Returns error (or $null) and steps: 'flow <handler> on|off', then 'subscription <name> enable|disable'. #>
    param([object[]]$Installed = @(), [object[]]$Subscriptions = @(), [string[]]$On = @(), [string[]]$Off = @())
    $flows = @{}
    foreach ($f in @($Installed)) { $n = Get-HandlerName $f.flow; if ($n) { $flows[$n.ToLowerInvariant()] = [pscustomobject]@{ Name = $n; On = [bool]$f.on } } }
    $known = @{}
    foreach ($v in $flows.Values) { $known[$v.Name.ToLowerInvariant()] = $v.Name }
    foreach ($s in @($Subscriptions)) { if (-not $known.ContainsKey("$($s.handler)".ToLowerInvariant())) { $known["$($s.handler)".ToLowerInvariant()] = "$($s.handler)" } }
    $fail = { param($m) [pscustomobject]@{ error = $m; steps = @() } }
    $installedList = (@($flows.Values | ForEach-Object Name) | Sort-Object) -join ', '

    $want = [ordered]@{}
    foreach ($pair in @(@($On, $true), @($Off, $false))) {
        foreach ($raw in @($pair[0] | Where-Object { $_ })) {
            $k = $raw.Trim().ToLowerInvariant()
            if (-not $known.ContainsKey($k)) { return (& $fail "unknown handler: $($raw.Trim()) (installed: $installedList)") }
            if ($want.Contains($k) -and $want[$k] -ne $pair[1]) { return (& $fail "both on and off: $($known[$k])") }
            if (-not $flows.ContainsKey($k)) { return (& $fail "not installed: $($known[$k]) (import ChangeRadarHandlers first)") }
            $want[$k] = $pair[1]
        }
    }
    $flowSteps = foreach ($k in $want.Keys) { $f = $flows[$k]; if ($f.On -ne $want[$k]) { [pscustomobject]@{ Sort = $f.Name; Text = "flow $($f.Name) $(if ($want[$k]) { 'on' } else { 'off' })" } } }
    $subSteps = foreach ($s in @($Subscriptions)) {
        $k = "$($s.handler)".ToLowerInvariant()
        if ($want.Contains($k) -and [bool]$s.enabled -ne $want[$k]) { [pscustomobject]@{ Sort = $s.name; Text = "subscription $($s.name) $(if ($want[$k]) { 'enable' } else { 'disable' })" } }
    }
    [pscustomobject]@{ error = $null; steps = @(@($flowSteps | Sort-Object Sort | ForEach-Object Text) + @($subSteps | Sort-Object Sort | ForEach-Object Text)) }
}

Export-ModuleMember -Function Get-HandlerName, Get-HandlerPlan
