#Requires -Version 7.0
<#
.SYNOPSIS
    Credit forecast (docs/requirements.md 3.1). Pure functions; setup/Get-CreditEstimate.ps1 feeds them measured inputs.
    Cases: tests/credits/credits.json (run engine/Invoke-CreditTests.ps1).
#>
Set-StrictMode -Version Latest

function Get-Whole([double]$x) { [int][Math]::Round($x, [MidpointRounding]::AwayFromZero) }

function Get-CreditForecast {
    <# Signals: prompt-eligible signals still to fingerprint (S in requirements.md); ToRate: of them, still to rate (W); ToAssess: exposed signals not yet assessed (E before an install);
       Exposed: signals with open exposures in the estate (E); Daily: new or changed eligible signals a day (D);
       WindowShare: share of those in the rating window (w); ReassessShare: share of exposed signals re-assessed a night (c). Caps are the per-run settings (0 = no cap); each stage is capped at cap x 30 calls a month. #>
    param(
        [double]$Signals, [double]$ToRate, [double]$ToAssess, [double]$Exposed, [double]$Daily, [double]$WindowShare, [double]$ReassessShare,
        [int]$FingerprintCap, [int]$RatingCap, [int]$AssessmentCap,
        [int]$CatchupCap = 0, [int]$CatchupNights = 0,   # catch-up (finding 14): first nights at a higher cap
        [double]$AibPerCall = 5.5, [double]$CopilotPerCall = 0.46,
        [int]$Days = 30
    )
    $caps = [ordered]@{ fingerprint = $FingerprintCap; rating = $RatingCap; assessment = $AssessmentCap }
    $backlog = [ordered]@{ fingerprint = Get-Whole $Signals; rating = Get-Whole $ToRate; assessment = Get-Whole $ToAssess }
    $month = [ordered]@{ fingerprint = Get-Whole ($Days * $Daily); rating = Get-Whole ($Days * $Daily * $WindowShare); assessment = Get-Whole ($Days * $Exposed * $ReassessShare) }
    # Catch-up raises a cap for the first nights, never lowers it; 0 (no cap) stays 0.
    $cn = [Math]::Min([Math]::Max($CatchupNights, 0), $Days)
    function Catch($cap) { if ($cap -gt 0 -and $CatchupCap -gt $cap -and $cn -gt 0) { $CatchupCap } else { $cap } }
    function Limit($stage, $calls) { if ($caps[$stage] -gt 0) { [Math]::Min($calls, $caps[$stage] * $Days) } else { $calls } }
    function FirstLimit($stage, $calls) { $cap = $caps[$stage]; if ($cap -gt 0) { [Math]::Min($calls, (Catch $cap) * $cn + $cap * ($Days - $cn)) } else { $calls } }
    $monthCapped = [ordered]@{}; $peakCapped = [ordered]@{}; $capped = @(); $peakCappedStages = @()
    foreach ($k in $caps.Keys) {
        $monthCapped[$k] = Limit $k $month[$k]
        if ($monthCapped[$k] -lt $month[$k]) { $capped += $k }
        $p = $backlog[$k] + $month[$k]
        $peakCapped[$k] = FirstLimit $k $p
        if ($peakCapped[$k] -lt $p) { $peakCappedStages += $k }
    }
    $sum = { param($h) ($h.Values | Measure-Object -Sum).Sum }
    $monthly = & $sum $monthCapped; $peak = & $sum $peakCapped; $backlogCalls = & $sum $backlog
    $ceiling = if (@($caps.Values | Where-Object { $_ -le 0 }).Count) { $null } else { (& $sum $caps) * $Days }
    $firstCeiling = if ($null -eq $ceiling) { $null } else { [int](@($caps.Values | ForEach-Object { (Catch $_) * $cn + $_ * ($Days - $cn) }) | Measure-Object -Sum).Sum }
    $nights = if ($backlog.fingerprint -eq 0) { 0 }
        elseif ($FingerprintCap -le 0) { 1 }
        else {
            # Catch-up nights first, at (catch-up cap - Daily) a night; then the normal cap.
            $fast = (Catch $FingerprintCap) - $Daily; $left = $backlog.fingerprint; $n = 0
            if ($cn -gt 0 -and $fast -gt 0) { $need = [int][Math]::Ceiling($left / $fast); if ($need -le $cn) { $n = $need; $left = 0 } else { $n = $cn; $left -= $fast * $cn } }
            if ($left -le 0) { $n } elseif ($FingerprintCap -le $Daily) { $null } else { $n + [int][Math]::Ceiling($left / ($FingerprintCap - $Daily)) }
        }
    [pscustomobject][ordered]@{
        backlogCalls = [int]$backlogCalls; monthlyCalls = [int]$monthly; peakCalls = [int]$peak; ceilingCalls = $ceiling; firstMonthCeilingCalls = $firstCeiling
        monthlyAib = Get-Whole ($monthly * $AibPerCall); monthlyCopilot = Get-Whole ($monthly * $CopilotPerCall)
        peakAib = Get-Whole ($peak * $AibPerCall); peakCopilot = Get-Whole ($peak * $CopilotPerCall)
        ceilingAib = $(if ($null -ne $ceiling) { Get-Whole ($ceiling * $AibPerCall) }); ceilingCopilot = $(if ($null -ne $ceiling) { Get-Whole ($ceiling * $CopilotPerCall) })
        nightsToClear = $nights; cappedStages = $capped; peakCappedStages = $peakCappedStages
        stages = [pscustomobject]@{ backlog = [pscustomobject]$backlog; month = [pscustomobject]$monthCapped; peak = [pscustomobject]$peakCapped }
    }
}

Export-ModuleMember -Function Get-CreditForecast
