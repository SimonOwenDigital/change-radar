#Requires -Version 7.0
<#
.SYNOPSIS
    See the estate by solution (ADR 0020): which solutions each asset belongs to, how assets are grouped, and the
    per-solution summary on the Radar page. Pure functions; the detail flow and the Radar page are checked against them.
#>
Set-StrictMode -Version Latest

$script:ImpactRank = @{ none = 0; low = 1; medium = 2; high = 3; critical = 4 }
$script:NotInSolution = '(not in a solution)'
$script:NotKnown = '(solution not known)'

function Get-Prop($o, [string]$name) {
    if ($null -eq $o) { return $null }
    if ($o -is [hashtable]) { return $o[$name] }
    $p = $o.PSObject.Properties[$name]; if ($p) { $p.Value } else { $null }
}

function Get-SolutionObjectId {
    <# The id Dataverse solutioncomponents uses for an asset: its component id, or for agents (no component id in the
       inventory) the resource id, the second part of the source id (environment|resource|solution). #>
    param($Asset)
    $c = "$(Get-Prop $Asset 'componentid')".Trim()
    if ($c) { return $c.ToLowerInvariant() }
    $parts = "$(Get-Prop $Asset 'sourceid')" -split '\|'
    if ($parts.Count -ge 2 -and $parts[1].Trim()) { return $parts[1].Trim().ToLowerInvariant() }
    $null
}

function Test-CountedSolution {
    <# Default, Active and the Common Data Services Default Solution contain everything, so they are not counted.
       The last is recognised by its display name, or (any language) by a Cr-hex unique name with a Cr-hex publisher. #>
    param($Solution)
    $u = "$(Get-Prop $Solution 'uniquename')"; $f = "$(Get-Prop $Solution 'friendlyname')"; $p = "$(Get-Prop $Solution 'publisher')"
    if ($u -in 'Default', 'Active') { return $false }
    if ($f -eq 'Common Data Services Default Solution') { return $false }
    if ($u -cmatch '^Cr[0-9a-f]{4,}$' -and $p -cmatch '^Cr[0-9a-f]{4,}$') { return $false }
    $true
}

function Get-SolutionMembership {
    <# One row per asset and counted solution: assetid, uniquename, displayname, publisher, managed, microsoft. Sorted by
       asset id, then unique name; duplicates (the same component listed twice) collapse. #>
    param([object[]]$Assets, [object[]]$Components, [string[]]$MicrosoftPublishers)
    $byObject = @{}
    foreach ($a in @($Assets)) { $o = Get-SolutionObjectId $a; if ($o) { if (-not $byObject[$o]) { $byObject[$o] = [Collections.Generic.List[string]]::new() }; $byObject[$o].Add("$(Get-Prop $a 'assetid')") } }
    $seen = @{}
    $rows = foreach ($c in @($Components)) {
        $o = "$(Get-Prop $c 'objectid')".ToLowerInvariant()
        if (-not $byObject[$o] -or -not (Test-CountedSolution $c)) { continue }
        foreach ($aid in $byObject[$o]) {
            $k = "$aid|$(Get-Prop $c 'uniquename')"; if ($seen[$k]) { continue }; $seen[$k] = $true
            [pscustomobject][ordered]@{ assetid = $aid; uniquename = "$(Get-Prop $c 'uniquename')"; displayname = "$(Get-Prop $c 'friendlyname')"
                publisher = "$(Get-Prop $c 'publisher')"; managed = [bool](Get-Prop $c 'ismanaged'); microsoft = (@($MicrosoftPublishers) -contains "$(Get-Prop $c 'publisher')") }
        }
    }
    @($rows | Sort-Object assetid, uniquename)
}

function Get-SolutionGroups {
    <# Each asset's group keys: its solutions' unique names (makers' first, each part by display name), else
       '(not in a solution)' when its environment has Dataverse detail, else '(solution not known)'. #>
    param([object[]]$Assets, [object[]]$Membership, [string[]]$DetailEnvironments)
    $out = [ordered]@{}
    foreach ($a in @($Assets)) {
        $id = "$(Get-Prop $a 'assetid')"
        $mine = @(@($Membership) | Where-Object { "$(Get-Prop $_ 'assetid')" -eq $id } | Sort-Object @{ e = { [bool](Get-Prop $_ 'microsoft') } }, @{ e = { "$(Get-Prop $_ 'displayname')" } })
        $out[$id] = if ($mine.Count) { @($mine | ForEach-Object { "$(Get-Prop $_ 'uniquename')" }) }
            elseif (@($DetailEnvironments) -contains "$(Get-Prop $a 'environmentid')") { @($script:NotInSolution) } else { @($script:NotKnown) }
    }
    $out
}

function Get-SolutionSummary {
    <# Per solution: exposed assets (distinct), items (distinct signals), highest impact, next deadline (key date from
       today on), items needing action. Sorted by highest impact, then items, then display name. #>
    param([object[]]$Solutions, [object[]]$Membership, [object[]]$Exposures, [datetime]$Today)
    $rows = foreach ($s in @($Solutions)) {
        $u = "$(Get-Prop $s 'uniquename')"
        $assets = @(@($Membership) | Where-Object { "$(Get-Prop $_ 'uniquename')" -eq $u } | ForEach-Object { "$(Get-Prop $_ 'assetid')" })
        $ex = @(@($Exposures) | Where-Object { $assets -contains "$(Get-Prop $_ 'assetid')" })
        $rated = @($ex | Where-Object { $script:ImpactRank.ContainsKey("$(Get-Prop $_ 'impact')") })
        $highest = if ($rated.Count) { ($rated | Sort-Object @{ e = { $script:ImpactRank["$(Get-Prop $_ 'impact')"] }; Descending = $true } | Select-Object -First 1).impact } else { $null }
        $future = @($ex | Where-Object { Get-Prop $_ 'keyDate' } | ForEach-Object { [datetime]"$(Get-Prop $_ 'keyDate')" } | Where-Object { $_.Date -ge $Today.Date } | Sort-Object)
        [pscustomobject][ordered]@{ uniquename = $u; displayname = "$(Get-Prop $s 'displayname')"; microsoft = [bool](Get-Prop $s 'microsoft')
            assets = @($ex | ForEach-Object { "$(Get-Prop $_ 'assetid')" } | Sort-Object -Unique).Count
            items = @($ex | ForEach-Object { "$(Get-Prop $_ 'signal')" } | Sort-Object -Unique).Count
            highest = $highest
            nextDeadline = $(if ($future.Count) { $future[0].ToString('yyyy-MM-dd') } else { $null })
            action = @($ex | Where-Object { [bool](Get-Prop $_ 'actionRequired') } | ForEach-Object { "$(Get-Prop $_ 'signal')" } | Sort-Object -Unique).Count }
    }
    @($rows | Sort-Object @{ e = { if ($_.highest) { $script:ImpactRank[$_.highest] } else { -1 } }; Descending = $true }, @{ e = { $_.items }; Descending = $true }, displayname)
}

function Get-RelatedSignals {
    <# Signals related to a solution (Simon, 2026-11-24): an accepted signal fingerprint on one of -Facets (connector,
       capability, model, setting, harness, auth_mode) whose value a component of the solution also has (values compared
       without case). Signals in -Affects (an exposure on the solution) are left out. One row per signal with its distinct
       links 'facet: value' (value lower-cased), sorted; rows sorted by signal. #>
    param([string[]]$SolutionAssets, [object[]]$AssetFingerprints, [object[]]$SignalFingerprints, [string[]]$Affects, [string[]]$Facets)
    $have = @{}
    foreach ($f in @($AssetFingerprints)) {
        if (@($SolutionAssets) -notcontains "$(Get-Prop $f 'assetid')") { continue }
        $facet = "$(Get-Prop $f 'facet')"; if (@($Facets) -notcontains $facet) { continue }
        $have["$facet|$("$(Get-Prop $f 'value')".ToLowerInvariant())"] = $true
    }
    $links = @{}
    foreach ($f in @($SignalFingerprints)) {
        if ("$(Get-Prop $f 'status')" -ne 'accepted') { continue }
        $sid = "$(Get-Prop $f 'signal')"; if (@($Affects) -contains $sid) { continue }
        $k = "$(Get-Prop $f 'facet')|$("$(Get-Prop $f 'value')".ToLowerInvariant())"
        if (-not $have[$k]) { continue }
        if (-not $links[$sid]) { $links[$sid] = [Collections.Generic.HashSet[string]]::new() }
        [void]$links[$sid].Add($k.Replace('|', ': '))
    }
    @($links.Keys | Sort-Object | ForEach-Object { [pscustomobject][ordered]@{ signal = $_; links = @($links[$_] | Sort-Object) } })
}

Export-ModuleMember -Function Get-SolutionObjectId, Test-CountedSolution, Get-SolutionMembership, Get-SolutionGroups, Get-SolutionSummary, Get-RelatedSignals
