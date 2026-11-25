#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the document diagrams: runs figures.py (SVG), then renders each SVG to a 2x PNG with Microsoft Edge headless,
    which uses the same Segoe UI fonts as Word. Word embeds the SVG and uses the PNG as its fallback.
.EXAMPLE
    pwsh -File tools/diagrams/render.ps1
#>
[CmdletBinding()]
param([string]$OutDir = (Join-Path $PSScriptRoot '..' '..' 'docs' 'diagrams'), [int]$Scale = 2)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$OutDir = (Resolve-Path $OutDir).Path
uv run --no-project --python 3.13 (Join-Path $PSScriptRoot 'figures.py') $OutDir
if ($LASTEXITCODE) { throw 'figures.py failed.' }
$edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found.' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('crdr-diagrams-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
foreach ($svg in Get-ChildItem $OutDir -Filter *.svg) {
    $text = [IO.File]::ReadAllText($svg.FullName)
    if ($text -notmatch 'width="(\d+)" height="(\d+)"') { throw "No size in $($svg.Name)." }
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    $html = Join-Path $tmp ($svg.BaseName + '.html')
    [IO.File]::WriteAllText($html, "<!doctype html><html><head><meta charset='utf-8'><style>html,body{margin:0;padding:0;background:#fff;overflow:hidden}</style></head><body>$text</body></html>")
    $png = Join-Path $OutDir ($svg.BaseName + '.png')
    & $edge --headless=new --disable-gpu --hide-scrollbars --no-first-run --force-device-scale-factor=$Scale "--window-size=$w,$h" "--screenshot=$png" ("file:///" + ($html -replace '\\', '/')) 2>$null | Out-Null
    for ($i = 0; $i -lt 40 -and -not (Test-Path $png); $i++) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path $png)) { throw "Rendering $($svg.Name) failed." }
    Write-Host ("{0,-34} {1}x{2} -> {3}" -f $svg.Name, $w, $h, (Split-Path $png -Leaf))
}
Remove-Item $tmp -Recurse -Force
