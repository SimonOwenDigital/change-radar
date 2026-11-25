#Requires -Version 7.0
<#
.SYNOPSIS
    Collects the public Microsoft Copilot Roadmap (formerly Microsoft 365 / AI at Work Roadmap)
    and writes normalised signal records for in-scope products.
.DESCRIPTION
    Public endpoint, no authentication, no tenant data. Available in every access tier (spec §3.1).
    Product filtering and product facets come from seed/roadmap-product-map.csv.
    Each record is shaped for the signal table (source = roadmap, externalId = RM<id>) plus
    deterministic product facets (extractedBy = rule).

    Endpoint used: https://www.microsoft.com/releasecommunications/api/v1/m365 (JSON, full
    catalogue in one response). Not documented on Microsoft Learn; see spikes/T3-roadmap-schema.md.
.PARAMETER InputPath
    Read a previously downloaded JSON file instead of calling the endpoint (offline/testing).
.EXAMPLE
    pwsh -File queries/roadmap-public.ps1 -OutPath samples/public/roadmap-powerplatform.json
#>
[CmdletBinding()]
param(
    [string]$OutPath = (Join-Path $PSScriptRoot '..' 'samples' 'public' 'roadmap-powerplatform.json'),
    [string]$InputPath,
    [string]$Endpoint = 'https://www.microsoft.com/releasecommunications/api/v1/m365',
    [string]$MapPath = (Join-Path $PSScriptRoot '..' 'seed' 'roadmap-product-map.csv'),
    [int]$SummaryLength = 400
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$map = @(Import-Csv $MapPath)
$inScope = @($map | Where-Object in_scope -eq 'true' | ForEach-Object roadmap_product)
$facetByProduct = @{}; foreach ($m in $map) { if ($m.vocabulary_product) { $facetByProduct[$m.roadmap_product] = $m.vocabulary_product } }

$collectedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
if ($InputPath) {
    $raw = Get-Content -Raw $InputPath
} else {
    $raw = (Invoke-WebRequest -Uri $Endpoint -UserAgent 'change-radar-collector/0.1' -TimeoutSec 120).Content
}
$items = @($raw | ConvertFrom-Json -DateKind String -Depth 20)

function ConvertTo-PlainText([string]$html, [int]$max) {
    if (-not $html) { return '' }
    $t = $html -replace '<br\s*/?>', ' ' -replace '</p>', ' ' -replace '<[^>]+>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t) -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max).TrimEnd() + '…' }
    $t
}
function ConvertTo-Month([string]$label) {
    # "January CY2027" -> "2027-01". Month precision is all the roadmap publishes.
    if ($label -match '^(?<m>[A-Za-z]+) CY(?<y>\d{4})$') {
        $m = [datetime]::ParseExact($Matches.m, 'MMMM', [Globalization.CultureInfo]::InvariantCulture).Month
        return '{0}-{1:00}' -f $Matches.y, $m
    }
    return $null
}
function Get-Tags($item, [string]$key) {
    $tc = $item.tagsContainer
    if ($tc -and $tc.PSObject.Properties[$key]) { return @($tc.$key | ForEach-Object tagName) }
    return @()
}

$records = foreach ($it in $items) {
    $products = @(Get-Tags $it 'products')
    if (-not @($products | Where-Object { $inScope -contains $_ }).Count) { continue }
    $gaMonth = ConvertTo-Month $it.publicDisclosureAvailabilityDate
    $previewMonth = ConvertTo-Month $it.publicPreviewDate
    $facets = @($products | Where-Object { $facetByProduct.ContainsKey($_) } | ForEach-Object { $facetByProduct[$_] } | Sort-Object -Unique |
        ForEach-Object { [ordered]@{ group = 'A'; facet = 'product'; value = $_; confidence = 1.0; extractedBy = 'rule' } })
    [ordered]@{
        id             = "RM$($it.id)"
        source         = 'roadmap'
        externalId     = "RM$($it.id)"
        title          = $it.title
        summary        = ConvertTo-PlainText $it.description $SummaryLength
        products       = $products
        status         = $it.status
        releasePhases  = @(Get-Tags $it 'releasePhase')
        platforms      = @(Get-Tags $it 'platforms')
        cloudInstances = @(Get-Tags $it 'cloudInstances')
        horizon        = 'future'
        previewMonth   = $previewMonth
        gaMonth        = $gaMonth
        keyDate        = $(if ($gaMonth) { "$gaMonth-01" } else { $null })
        dateLabel      = $it.publicDisclosureAvailabilityDate
        actionRequired = $false
        url            = "https://www.microsoft.com/microsoft-365/roadmap?id=$($it.id)"
        moreInfoLink   = $it.moreInfoLink
        created        = $it.created
        lastChanged    = $it.modified
        fingerprint    = $facets
    }
}
$records = @($records | Sort-Object { $_.lastChanged } -Descending)

$doc = [ordered]@{
    meta = [ordered]@{
        source        = 'Microsoft Copilot Roadmap (public)'
        endpoint      = $Endpoint
        collectedAt   = $collectedAt
        catalogueSize = $items.Count
        inScopeCount  = $records.Count
        productsInScope = $inScope
        notice        = 'Public Microsoft roadmap data, normalised. Descriptions truncated. No tenant data.'
    }
    signals = $records
}
New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
[IO.File]::WriteAllText($OutPath, (($doc | ConvertTo-Json -Depth 10) -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Catalogue $($items.Count) items; $($records.Count) in scope; wrote $OutPath"
