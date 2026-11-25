#Requires -Version 7.0
<#
    Change Radar reference engine: the watch list (ADR 0015). Which signals a topic watch matches, and which watch
    events a new signal version raises. Plain string steps only (no regex), so the raise signal events flow can run
    exactly the same steps in WDL. Cases: tests/watch/watch.json.

    Text is the title plus the readable summary (ConvertTo-ReadableText), lower-cased, with every character in the
    punctuation table turned into a space, runs of spaces collapsed in six halving rounds (as the flow does), and a
    space added at each end. A term (normalised the same way) matches when ' term ' occurs in the text, so it matches
    whole words only. Ignore phrases are removed from the text first. Lists are semicolon-separated.
#>
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ChangeRadar.Text.psm1') -Force

# Turned into spaces. The flow takes this table from Get-WatchPunctuation, so the two can't drift.
$script:Punctuation = @("`r", "`n", "`t", [string][char]0x00A0, '.', ',', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}', '"', "'",
    [string][char]0x2018, [string][char]0x2019, [string][char]0x201C, [string][char]0x201D, '/', '\', '|', '-', [string][char]0x2013, [string][char]0x2014,
    '_', '&', '+', '*', '#', '@', '<', '>', '=', '~', '`', '^', '%', '$', [string][char]0x2026, [string][char]0x2022)
$script:SpaceRounds = 6
# Changed fields (crdr_signalversion.crdr_changedfields) in the order the card lists them, with the words it uses.
$script:ChangeWords = [ordered]@{ 'title;' = 'title'; 'horizon;' = 'horizon'; 'date label;' = 'status'; 'action required;' = 'action required'; 'key date;' = 'key date' }

function Get-Prop($o, [string]$name) { if ($null -eq $o) { return $null }; if ($o -is [hashtable]) { return $o[$name] }; $p = $o.PSObject.Properties[$name]; if ($p) { $p.Value } else { $null } }
function Get-WatchPunctuation { <# The punctuation table, for the flow generator. #> , $script:Punctuation }
function Get-WatchSpaceRounds { $script:SpaceRounds }
function Get-WatchChangeWords { $script:ChangeWords }

function ConvertTo-WatchText {
    <# ' words separated by single spaces ' (lower case, punctuation removed, padded). An empty input gives '  '. #>
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $s = "$Text".ToLowerInvariant()
    foreach ($c in $script:Punctuation) { $s = $s.Replace($c, ' ') }
    foreach ($n in 1..$script:SpaceRounds) { $s = $s.Replace('  ', ' ') }
    ' ' + $s.Trim() + ' '
}

function Get-WatchTerms {
    <# A semicolon-separated list as normalised, padded terms; blanks dropped. #>
    param([AllowEmptyString()][AllowNull()][string]$List)
    @("$List".Split(';') | ForEach-Object { ConvertTo-WatchText $_ } | Where-Object { $_.Trim() })
}

function Test-WatchMatch {
    <# True when an active watch matches the signal: one of anyOf; and one of alsoOneOf when it's set; and one of
       products (contained in the signal's products, case-insensitive) when it's set. Ignore phrases are removed first. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Watch, [Parameter(Mandatory)]$Signal)
    if (-not (Get-Prop $Watch 'active')) { return $false }
    $any = @(Get-WatchTerms (Get-Prop $Watch 'anyOf'))
    if ($any.Count -eq 0) { return $false }
    $text = ConvertTo-WatchText ("$(Get-Prop $Signal 'title') " + (ConvertTo-ReadableText "$(Get-Prop $Signal 'summary')"))
    foreach ($t in @(Get-WatchTerms (Get-Prop $Watch 'ignore'))) { $text = $text.Replace($t, ' ') }
    if (-not ($any | Where-Object { $text.Contains($_) })) { return $false }
    $also = @(Get-WatchTerms (Get-Prop $Watch 'alsoOneOf'))
    if ($also.Count -gt 0 -and -not ($also | Where-Object { $text.Contains($_) })) { return $false }
    $products = @("$(Get-Prop $Watch 'products')".Split(';') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $signalProducts = "$(Get-Prop $Signal 'products')".ToLowerInvariant()
    if ($products.Count -gt 0 -and -not ($products | Where-Object { $signalProducts.Contains($_) })) { return $false }
    $true
}

function Format-WatchChange {
    <# What changed, for a watch.updated card: the key fields in card order, or 'wording' when only the text moved. #>
    param([AllowEmptyString()][AllowNull()][string]$ChangedFields)
    $c = "$ChangedFields".ToLowerInvariant()
    $words = @(foreach ($k in $script:ChangeWords.Keys) { if ($c.Contains($k)) { $script:ChangeWords[$k] } })
    if ($words.Count -eq 0) { return 'wording' }
    $words -join ', '
}

function Get-WatchEvents {
    <# Watch events for one new signal version. An unwatched signal that matches a topic raises watch.matched for the
       first matching watch by name (ordinal); a watched signal that changed (not created) raises watch.updated.
       Returns the event objects; wrap the call in @(). #>
    [CmdletBinding()]
    param([object[]]$Watches = @(), [Parameter(Mandatory)]$Signal, [bool]$Created, [bool]$WasWatched, [bool]$OptedOut, [string]$ChangedFields)
    # Opted out: a topic matched it once (the watch link is kept) and someone switched Watched off. Never re-added.
    if ($OptedOut) { return }
    if (-not $WasWatched) {
        $sorted = [Collections.Generic.List[object]]::new(); foreach ($w in $Watches) { $sorted.Add($w) }
        $sorted.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal("$(Get-Prop $a 'name')", "$(Get-Prop $b 'name')") })
        foreach ($w in $sorted) { if (Test-WatchMatch -Watch $w -Signal $Signal) { return [pscustomobject]@{ type = 'watch.matched'; watch = "$(Get-Prop $w 'name')" } } }
        return
    }
    if ($Created) { return }
    [pscustomobject]@{ type = 'watch.updated'; changes = (Format-WatchChange $ChangedFields) }
}

Export-ModuleMember -Function ConvertTo-WatchText, Get-WatchTerms, Test-WatchMatch, Format-WatchChange, Get-WatchEvents, Get-WatchPunctuation, Get-WatchSpaceRounds, Get-WatchChangeWords
