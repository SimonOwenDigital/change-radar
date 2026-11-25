#Requires -Version 7.0
<#
    Reference implementation of the estate impact score (spec §6, ADR 0010). Pure functions over plain objects:
    no tenant access. The "assess signals" flow must produce the same ratings (checked by a parity script).
#>
Set-StrictMode -Version Latest

$script:ImpactLevels = @('none', 'low', 'medium', 'high', 'critical')
$script:CountedStatuses = @('new', 'confirmed')

# Dates are compared as UTC calendar days, as the flow does (startOfDay on UTC timestamps).
# Date-only strings (e.g. a Dataverse date-only key date) are UTC days, never local time.
function ConvertTo-UtcDay($d) { if ($d -is [datetime]) { if ($d.Kind -eq 'Local') { return $d.ToUniversalTime().Date }; return $d.Date }; [datetimeoffset]::Parse("$d", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime.Date }

function ConvertTo-ImpactValue([string]$Impact) {
    $i = [array]::IndexOf($script:ImpactLevels, "$Impact".ToLowerInvariant())
    if ($i -lt 0) { throw "Unknown impact '$Impact'. Expected one of: $($script:ImpactLevels -join ', ')." }
    $i
}

function Get-EstateImpact {
    <#
    .SYNOPSIS
        Rates one signal per source from its exposures. Returns one result per source that has any exposure rows.
    .PARAMETER Signal
        id, genericImpact (none..critical), actionRequired (bool), keyDate (date string or null).
    .PARAMETER Exposures
        source, kind (asset | setting), assetId or settingKey, environmentType (asset only; null = unknown), status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Signal,
        [object[]]$Exposures = @(),
        [datetime]$Today = [datetime]::UtcNow.Date,
        [int]$EstateImpactMax = 4,
        [int]$ActionWindowDays = 30
    )
    $generic = ConvertTo-ImpactValue $Signal.genericImpact
    $actionBonus = $false
    if ($Signal.actionRequired -and $Signal.keyDate) {
        $days = (ConvertTo-UtcDay $Signal.keyDate).Subtract($Today.Date).TotalDays
        $actionBonus = $days -le $ActionWindowDays   # overdue (negative) counts too
    }
    foreach ($group in @($Exposures | Where-Object { $_ }) | Group-Object source | Sort-Object Name) {
        $counted = @($group.Group | Where-Object { $script:CountedStatuses -contains "$($_.status)".ToLowerInvariant() })
        $assets = @($counted | Where-Object kind -eq 'asset' | Group-Object assetId | ForEach-Object { $_.Group[0] })
        $settings = @($counted | Where-Object kind -eq 'setting' | Group-Object settingKey | ForEach-Object { $_.Group[0] })
        $affected = $assets.Count + $settings.Count
        $unknown = @($assets | Where-Object { -not $_.environmentType }).Count
        $production = [bool](@($assets | Where-Object { "$($_.environmentType)".ToLowerInvariant() -eq 'production' }).Count)
        if ($affected -eq 0) {
            $score = 0; $prodOut = $false; $actOut = $false
        } else {
            $score = $generic + [int]$production + [int]$actionBonus
            $score = [math]::Max(1, [math]::Min($EstateImpactMax, $score))
            $prodOut = $production; $actOut = $actionBonus
        }
        [pscustomobject]@{
            signalId                = $Signal.id
            source                  = $group.Name
            genericImpact           = $script:ImpactLevels[$generic]
            estateImpact            = $script:ImpactLevels[$score]
            affectedCount           = $affected
            unknownEnvironmentCount = $unknown
            productionBonus         = $prodOut
            actionBonus             = $actOut
        }
    }
}

function Get-ExposureSummary {
    <#
    .SYNOPSIS
        The text the assessment prompt receives about one signal's exposures in one source (ADR 0010 decision 2).
        Facets and counts only: asset, environment and owner names are never included, whatever the input carries.
    .PARAMETER Exposures
        One source's exposures: kind, assetId, resourceType (inventory type), environmentType (null = unknown),
        settingKey, group, status. Only New and Confirmed count.
    .PARAMETER Groups
        Accepted fingerprint groups: group, facets ("facet: value" strings, in display order).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)]$Signal,
        [object[]]$Exposures = @(),
        [object[]]$Groups = @(),
        [hashtable]$ResourceTypeMap = @{},
        [datetime]$Today = [datetime]::UtcNow.Date
    )
    $envOrder = 'production', 'sandbox', 'developer', 'default', 'trial'
    $counted = @($Exposures | Where-Object { $_ -and $script:CountedStatuses -contains "$($_.status)".ToLowerInvariant() })
    $assets = @($counted | Where-Object kind -eq 'asset' | Group-Object assetId | ForEach-Object { $_.Group[0] })
    $settings = @($counted | Where-Object kind -eq 'setting' | ForEach-Object settingKey | Sort-Object -Unique)
    $plural = { param($n, $word) "$n $word$(if ($n -ne 1) { 's' })" }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("Estate: $Source")
    $parts = @(); if ($assets.Count) { $parts += & $plural $assets.Count 'asset' }; if ($settings.Count) { $parts += & $plural $settings.Count 'tenant setting' }
    $lines.Add("Affected: $(if ($parts) { $parts -join ', ' } else { 'none' })")
    $byType = $assets | Group-Object { $t = "$($_.resourceType)".ToLowerInvariant(); if ($ResourceTypeMap.ContainsKey($t)) { $ResourceTypeMap[$t] } else { $t } } |
        Sort-Object @{ Expression = 'Count'; Descending = $true }, Name
    foreach ($t in $byType) {
        $envs = foreach ($e in $envOrder) { $n = @($t.Group | Where-Object { "$($_.environmentType)".ToLowerInvariant() -eq $e }).Count; if ($n) { "$e $n" } }
        $unknown = @($t.Group | Where-Object { -not $_.environmentType -or $envOrder -notcontains "$($_.environmentType)".ToLowerInvariant() }).Count
        if ($unknown) { $envs = @($envs) + "environment unknown $unknown" }
        $lines.Add("- $($t.Name): $($t.Count) ($(@($envs) -join ', '))")
    }
    $usedGroups = @($counted | ForEach-Object group | Sort-Object -Unique)
    $matched = foreach ($g in @($Groups | Where-Object { $usedGroups -contains $_.group } | Sort-Object group)) { "group $($g.group) ($(@($g.facets) -join ' + '))" }
    if ($matched) { $lines.Add("Matched on: $(@($matched) -join '; ')") }
    if ($settings.Count) { $lines.Add("Tenant settings not in place: $($settings -join ', ')") }
    $action = if (-not $Signal.actionRequired) { 'no' }
    elseif (-not $Signal.keyDate) { 'yes, no date given' }
    else {
        $d = ConvertTo-UtcDay $Signal.keyDate; $days = [int]$d.Subtract($Today.Date).TotalDays
        # No day count: the summary must only change when the inputs do, because the flow uses it to decide whether
        # to call the prompt again (ADR 0010).
        if ($days -lt 0) { "yes, overdue since $($d.ToString('yyyy-MM-dd'))" } else { "yes, by $($d.ToString('yyyy-MM-dd'))" }
    }
    $lines.Add("Action required: $action")
    $lines -join "`n"
}

# Rule themes (ADR 0012 addendum, 2026-11-22): seed/theme-rules.csv rows, checked against seed/themes.csv at load.
function Import-ThemeRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Rules, [Parameter(Mandatory)][string[]]$Themes, [string[]]$Natures = @())
    foreach ($r in $Rules) {
        # Optional nature (ADR 0013 step 5): checked against the schema's nature choice when -Natures is given.
        $n = if ($r.PSObject.Properties['nature']) { "$($r.nature)" } else { '' }
        if ($n -and $Natures.Count -and $Natures -cnotcontains $n) { throw "Theme rule for $($r.match) '$($r.value)' names nature '$n', which is not a nature choice." }
        if (@('source', 'feed') -cnotcontains $r.match) { throw "Theme rule match '$($r.match)' is not 'source' or 'feed'." }
        if ($Themes -cnotcontains $r.theme) { throw "Theme rule for $($r.match) '$($r.value)' names '$($r.theme)', which is not in themes.csv." }
    }
    , @($Rules)
}

function Get-RuleTheme {
    <#
    .SYNOPSIS
        The rule theme for a signal (source label, feedKey or null), or $null when no rule matches. First match wins.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Signal, [object[]]$Rules = @())
    foreach ($r in $Rules) {
        if ($r.match -ceq 'source' -and "$($Signal.source)" -ceq $r.value) { return $r.theme }
        if ($r.match -ceq 'feed' -and $Signal.feedKey -and "$($Signal.feedKey)" -ceq $r.value) { return $r.theme }
    }
    $null
}

function Get-RuleNature {
    <# The rule nature for a signal (ADR 0013 step 5), or $null: the first rule that matches decides, and an empty nature means none. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Signal, [object[]]$Rules = @())
    foreach ($r in $Rules) {
        $hit = ($r.match -ceq 'source' -and "$($Signal.source)" -ceq $r.value) -or ($r.match -ceq 'feed' -and $Signal.feedKey -and "$($Signal.feedKey)" -ceq $r.value)
        if ($hit) { $n = if ($r.PSObject.Properties['nature']) { "$($r.nature)" } else { '' }; if ($n) { return $n } else { return $null } }
    }
    $null
}

Export-ModuleMember -Function ConvertTo-ImpactValue, Get-EstateImpact, Get-ExposureSummary, Import-ThemeRules, Get-RuleTheme, Get-RuleNature
