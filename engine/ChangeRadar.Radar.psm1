#Requires -Version 7.0
<#
    Reference implementation of the radar home page logic (ADR 0012): time-to-land buckets, the impact shown for an
    item, its timeline row, and the headline and tile counts. Pure functions; the generative page must agree.
#>
Set-StrictMode -Version Latest

$script:High = @('high', 'critical')
$script:Retiring = @('deprecation', 'breaking')

function Get-Prop($o, [string]$name) { if ($null -eq $o) { return $null }; if ($o -is [hashtable]) { return $o[$name] }; $p = $o.PSObject.Properties[$name]; if ($p) { $p.Value } else { $null } }
# Date-only strings (e.g. a Dataverse date-only key date) are UTC days, never local time.
function ConvertTo-UtcDay($d) { if (-not $d) { return $null }; if ($d -is [datetime]) { return $d.ToUniversalTime().Date }; [datetimeoffset]::Parse("$d", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime.Date }
function Get-DaysToLand($KeyDate, [datetime]$Today) { $kd = ConvertTo-UtcDay $KeyDate; if (-not $kd) { return $null }; [int]$kd.Subtract($Today.Date).TotalDays }

function Get-TimeBucket {
    <# landed (past), next30 (0-30 days), m1to3 (31-91), m3to6 (92-183), later (184 or more), nodate (no key date). #>
    param($KeyDate, [datetime]$Today = [datetime]::UtcNow.Date)
    $d = Get-DaysToLand $KeyDate $Today
    if ($null -eq $d) { 'nodate' } elseif ($d -lt 0) { 'landed' } elseif ($d -le 30) { 'next30' } elseif ($d -le 91) { 'm1to3' } elseif ($d -le 183) { 'm3to6' } else { 'later' }
}

function Get-ItemImpact {
    <# Live override, else live estate rating (when the estate still has exposure), else the signal's generic rating. #>
    param($Signal, $Live)
    $ov = Get-Prop $Live 'overrideImpact'; $est = Get-Prop $Live 'estateImpact'; $gen = Get-Prop $Signal 'genericImpact'
    if ($ov) { [pscustomobject]@{ impact = "$ov"; basis = 'override' } }
    elseif ($est -and $est -ne 'none') { [pscustomobject]@{ impact = "$est"; basis = 'estate' } }
    elseif ($gen) { [pscustomobject]@{ impact = "$gen"; basis = 'generic' } }
    else { [pscustomobject]@{ impact = 'unrated'; basis = 'none' } }
}

function Get-TimelineRow {
    <# shipped, retiring, imminent, future; 'none' for incidents (they stay in the Now tile). #>
    param($Signal, [datetime]$Today = [datetime]::UtcNow.Date)
    if ((Get-Prop $Signal 'source') -eq 'graph_health') { return 'none' }
    $d = Get-DaysToLand (Get-Prop $Signal 'keyDate') $Today
    $launched = (Get-Prop $Signal 'source') -eq 'roadmap' -and "$(Get-Prop $Signal 'dateLabel')" -like 'Launched*'
    if ($launched -or ($null -ne $d -and $d -lt 0 -and -not (Get-Prop $Signal 'actionRequired'))) { return 'shipped' }
    if ($script:Retiring -contains "$(Get-Prop $Signal 'nature')") { return 'retiring' }
    if (@('now', 'imminent') -contains "$(Get-Prop $Signal 'horizon')") { return 'imminent' }
    'future'
}

function Format-RadarHeadline {
    param([int]$ActionRequired, [int]$HighImpact, $Next)
    $a = if ($ActionRequired -eq 0) { 'No items need action' } elseif ($ActionRequired -eq 1) { '1 item needs action' } else { "$ActionRequired items need action" }
    $h = if ($HighImpact -eq 0) { 'none are rated high impact' } elseif ($HighImpact -eq 1) { '1 is rated high impact' } else { "$HighImpact are rated high impact" }
    $n = if ($Next) { "The next deadline is $(Get-Prop $Next 'keyDate'): $(Get-Prop $Next 'title')." } else { 'No upcoming deadline.' }
    "$a, and $h. $n"
}

function Get-RadarSummary {
    <# Tile counts and headline over active signals (each may carry a 'live' assessment). #>
    param([object[]]$Signals = @(), [datetime]$Today = [datetime]::UtcNow.Date)
    $items = @($Signals | Where-Object { (Get-Prop $_ 'source') -ne 'graph_health' })
    $incidents = @($Signals | Where-Object { (Get-Prop $_ 'source') -eq 'graph_health' -and (Get-Prop $_ 'horizon') -eq 'now' }).Count
    $action = @($items | Where-Object { Get-Prop $_ 'actionRequired' })
    $high = @($items | Where-Object { $script:High -contains (Get-ItemImpact $_ (Get-Prop $_ 'live')).impact }).Count
    $retiring = @($items | Where-Object {
            $script:Retiring -contains "$(Get-Prop $_ 'nature')" -and ((Get-Prop $_ 'actionRequired') -or ($null -eq ($d = Get-DaysToLand (Get-Prop $_ 'keyDate') $Today)) -or $d -ge 0) }).Count
    $future = @($items | Where-Object { (Get-Prop $_ 'source') -eq 'roadmap' -and (Get-Prop $_ 'horizon') -eq 'future' }).Count
    $next = @($action | Where-Object { ($d = Get-DaysToLand (Get-Prop $_ 'keyDate') $Today) -ne $null -and $d -ge 0 } |
            Sort-Object { ConvertTo-UtcDay (Get-Prop $_ 'keyDate') }, { Get-Prop $_ 'title' }) | Select-Object -First 1
    $nextOut = if ($next) { [pscustomobject]@{ id = (Get-Prop $next 'id'); keyDate = (ConvertTo-UtcDay (Get-Prop $next 'keyDate')).ToString('yyyy-MM-dd'); title = (Get-Prop $next 'title') } } else { $null }
    [pscustomobject]@{ incidentsActive = $incidents; actionRequired = $action.Count; highImpact = $high; retiring = $retiring; futureRoadmap = $future; nextDeadline = $nextOut
        headline = (Format-RadarHeadline $action.Count $high $nextOut) }
}

function Test-InPatternWindow {
    <# Patterns (ADR 0012 addendum, 2026-11-22): key date on or after today minus 90 UTC days, or no key date; everything with -ShowOlder. #>
    param($KeyDate, [datetime]$Today = [datetime]::UtcNow.Date, [switch]$ShowOlder)
    if ($ShowOlder) { return $true }
    $d = Get-DaysToLand $KeyDate $Today
    $null -eq $d -or $d -ge -90
}

Export-ModuleMember -Function Get-TimeBucket, Get-ItemImpact, Get-TimelineRow, Format-RadarHeadline, Get-RadarSummary, Test-InPatternWindow
