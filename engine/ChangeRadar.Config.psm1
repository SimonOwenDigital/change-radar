#Requires -Version 7.0
<#
.SYNOPSIS
    Configuration switches shared by flows and the Radar page. Pure functions; the flows and the page mirror them.
#>
Set-StrictMode -Version Latest

function Test-DemoDataOn {
    <# demo_data (ADR 0022): 'off', 'false', 'no' or '0' (any case, trimmed) switch demo data off; anything else, or no
       value, leaves it on, so an install from before the switch behaves as it did. #>
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $v = "$Value".Trim().ToLowerInvariant()
    -not ($v -in 'off', 'false', 'no', '0')
}

function Get-EstateShown {
    <# Which estate the Radar page shows (Simon 2026-11-24): 'synthetic' (the demo organisation) while demo data is on,
       'live' while it's off. One estate at a time, so live and synthetic ratings are never mixed. #>
    param([AllowNull()][AllowEmptyString()][string]$Value, [bool]$Loaded = $true)
    # With no demo data loaded the live estate is shown whatever the setting, never an empty demo one.
    if ($Loaded -and (Test-DemoDataOn $Value)) { 'synthetic' } else { 'live' }
}

function Get-DemoDataValue {
    <# The value the Radar page's demo data switch writes to demo_data (Simon 2026-11-24): 'on' or 'off'. #>
    param([bool]$On)
    if ($On) { 'on' } else { 'off' }
}

function Get-AssessmentStep {
    <# assessment_max_per_run (install test finding 15): what the assess flow does with one exposed signal and source.
       'prompt' under the cap; 'defer' at the cap (nothing written, so it is prompted on a later run); 'rescore' when no
       prompt is needed (no call, never capped). Max 0 or less = no cap. #>
    param([bool]$NeedsPrompt, [int]$Prompted, [int]$Max)
    if (-not $NeedsPrompt) { return 'rescore' }
    if ($Max -gt 0 -and $Prompted -ge $Max) { return 'defer' }
    'prompt'
}

function Get-EffectiveCap {
    <# Catch-up (install test finding 14): before catchup_until ('yyyy-MM-dd', textual comparison as in the flows), a
       per-run cap is raised to catchup_max_per_run. Anything not of that form is ignored. Never lowers a cap; 0 (no cap)
       stays 0; CatchupCap 0 or less = no catch-up. Today is the UTC date as 'yyyy-MM-dd'. #>
    param([int]$Cap, [int]$CatchupCap, [AllowNull()][AllowEmptyString()][string]$Until, [string]$Today)
    # The same textual checks the flows make (they can't test digits): ten characters, '20' first, dashes at 4 and 7,
    # after today and before today + 120 days. The bound stops a malformed value meaning catch-up forever.
    $u = "$Until".Trim()
    $limit = ([datetime]::ParseExact($Today, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).AddDays(120).ToString('yyyy-MM-dd')
    $shape = $u.Length -eq 10 -and $u.StartsWith('20') -and $u[4] -eq '-' -and $u[7] -eq '-'
    $active = $CatchupCap -gt 0 -and $Cap -gt 0 -and $shape -and [string]::CompareOrdinal($Today, $u) -lt 0 -and [string]::CompareOrdinal($u, $limit) -lt 0
    if ($active) { [Math]::Max($Cap, $CatchupCap) } else { $Cap }
}

function Get-SeedStep {
    # What the matching data importer does with one row: create, exists, keep, update or deactivate. A plain run only
    # adds what is missing; changing or deactivating an existing row needs -Reset (Import-MatchingData -UpdateToSeed).
    param([bool]$InSeed, [bool]$Exists, [bool]$Same, [bool]$Active, [bool]$Reset)
    if (-not $Exists) { return 'create' }
    if ($InSeed) { if ($Same) { return 'exists' }; return $(if ($Reset) { 'update' } else { 'keep' }) }
    if (-not $Active) { return 'exists' }
    if ($Reset) { 'deactivate' } else { 'keep' }
}

Export-ModuleMember -Function Test-DemoDataOn, Get-EstateShown, Get-DemoDataValue, Get-AssessmentStep, Get-EffectiveCap, Get-SeedStep
