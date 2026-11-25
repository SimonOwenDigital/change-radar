#Requires -Version 7.0
<#
    Change Radar reference engine: readable text from a collected summary (HTML for Message Center and blog items).
    Plain string steps only, no XML or regex, so the Readable summary flow can run exactly the same steps in WDL and
    malformed HTML can't make it fail. Cases: tests/text/readable.json.
#>
Set-StrictMode -Version Latest

# Each step is (find, replace), applied in order with ordinal, case-sensitive replacement, as WDL replace() does.
$script:BlockBreaks = @('</p>', '</li>', '</div>', '</tr>', '</h1>', '</h2>', '</h3>', '</h4>', '</h5>', '</h6>', '<br />', '<br/>', '<br>')
$script:Entities = [ordered]@{ '&nbsp;' = ' '; '&lt;' = '<'; '&gt;' = '>'; '&quot;' = '"'; '&#39;' = "'"; '&rsquo;' = [string][char]0x2019; '&lsquo;' = [string][char]0x2018
    '&ldquo;' = [string][char]0x201C; '&rdquo;' = [string][char]0x201D; '&mdash;' = [string][char]0x2014; '&ndash;' = [string][char]0x2013; '&hellip;' = [string][char]0x2026
    # Numeric forms WordPress feeds use (the Power Platform blog, 2026-11-22). The flow takes this table from Get-ReadableEntities.
    '&#160;' = ' '; '&#8216;' = [string][char]0x2018; '&#8217;' = [string][char]0x2019; '&#8220;' = [string][char]0x201C; '&#8221;' = [string][char]0x201D
    '&#8211;' = [string][char]0x2013; '&#8212;' = [string][char]0x2014; '&#8230;' = [string][char]0x2026
    '&#038;' = '&'; '&amp;' = '&' }

function Get-ReadableEntities { <# The entity table, in decoding order (ampersands last), for the readable summary flow. #> $script:Entities }

function ConvertTo-ReadableText {
    param([AllowEmptyString()][AllowNull()][string]$Html)
    $s = "$Html"
    $s = $s.Replace("`r", ' ').Replace("`n", ' ')
    foreach ($b in $script:BlockBreaks) { $s = $s.Replace($b, "`n") }
    $s = $s.Replace('<li>', [string][char]0x2022 + ' ')
    # Remove the remaining tags: everything from '<' up to the next '>'.
    $parts = $s.Split('<')
    $s = $parts[0] + (($parts | Select-Object -Skip 1 | ForEach-Object { $i = $_.IndexOf('>'); if ($i -ge 0) { $_.Substring($i + 1) } else { '<' + $_ } }) -join '')
    foreach ($k in $script:Entities.Keys) { $s = $s.Replace($k, $script:Entities[$k]) }
    foreach ($n in 1..4) { $s = $s.Replace('  ', ' ') }
    foreach ($n in 1..2) { $s = $s.Replace(" `n", "`n").Replace("`n ", "`n") }
    foreach ($n in 1..3) { $s = $s.Replace("`n`n`n", "`n`n") }
    $s.Trim()
}

Export-ModuleMember -Function ConvertTo-ReadableText, Get-ReadableEntities
