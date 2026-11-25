#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the whole client-facing document set: draws the diagrams once, then builds and finishes each Word document
    (with its PDF) from its Markdown. Needs uv, Microsoft Edge, Node and Microsoft Word (see README.md).
.EXAMPLE
    pwsh -File tools/docbuild/build-all.ps1 -PagesDir $env:TEMP/pages
#>
[CmdletBinding()]
param([string]$PagesDir, [string[]]$Only)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '../..')
# 'pwsh -File' passes -Only a,b as one string: split it.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
# documents.csv: Markdown source, Word file name, and stage (its folder in the docs pack). Add a document once it is
# written, not while it is a skeleton.
$set = [ordered]@{}
foreach ($d in Import-Csv (Join-Path $PSScriptRoot 'documents.csv')) { $set[$d.source] = $d.file }
& pwsh -File (Join-Path $repo 'tools/diagrams/render.ps1')
if ($LASTEXITCODE) { throw 'diagram render failed' }
foreach ($k in $set.Keys) {
    if ($Only -and $k -notin $Only) { continue }
    $md = Join-Path $repo "docs/$k.md"
    $docx = Join-Path $repo "docs/word/$($set[$k]).docx"
    node (Join-Path $PSScriptRoot 'build-docx.mjs') $md $docx
    if ($LASTEXITCODE) { throw "build failed: $k" }
    $finish = @{ Docx = $docx }
    if ($PagesDir) { $finish.PagesDir = Join-Path $PagesDir $k }
    & (Join-Path $PSScriptRoot 'finish-docx.ps1') @finish
}
