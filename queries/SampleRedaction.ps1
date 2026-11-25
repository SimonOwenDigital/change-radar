#Requires -Version 7.0
<#
.SYNOPSIS
    Dot-source this to get Protect-CrdrSample: redacts a Graph response before it is written under samples/.
.DESCRIPTION
    CLAUDE.md: no tenant identifiers, user emails or client data in the repo. Removes per-tenant state
    (viewPoint: read, archived, favourite, dismissed), replaces GUIDs, email addresses and *.onmicrosoft.com
    or *.sharepoint.com host names, and truncates long bodies. Microsoft's published text is kept otherwise.
#>
function Protect-CrdrSample {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Items, [int]$MaxBody = 1500)
    $json = $Items | ForEach-Object {
        if ($_.PSObject.Properties['viewPoint']) { $_.PSObject.Properties.Remove('viewPoint') }
        $_
    } | ConvertTo-Json -Depth 30 -AsArray
    $json = $json -replace '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '00000000-0000-0000-0000-000000000000'
    $json = $json -replace '(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}', 'user@contoso.example'
    $json = $json -replace '(?i)\b[a-z0-9-]+\.(onmicrosoft\.com|sharepoint\.com)\b', 'contoso.$1'
    $out = $json | ConvertFrom-Json -Depth 30
    foreach ($o in @($out)) {
        foreach ($p in @($o.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value.Length -gt $MaxBody })) { $p.Value = $p.Value.Substring(0, $MaxBody) + '…' }
        if ($o.PSObject.Properties['body'] -and $o.body.content.Length -gt $MaxBody) { $o.body.content = $o.body.content.Substring(0, $MaxBody) + '…' }
        if ($o.PSObject.Properties['posts']) { foreach ($post in @($o.posts)) { if ($post.description.content.Length -gt $MaxBody) { $post.description.content = $post.description.content.Substring(0, $MaxBody) + '…' } } }
    }
    , @($out)
}
