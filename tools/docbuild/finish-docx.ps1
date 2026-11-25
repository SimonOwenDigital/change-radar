#Requires -Version 7.0
<#
.SYNOPSIS
    Finishes a built Word document with Word itself: fills the table of contents and page numbers, saves it, exports a
    PDF beside it, removes the tenant's sensitivity label from both (clean-output.py), and (with -PagesDir) renders every page to PNG for checking. Needs Microsoft Word on this machine.
.EXAMPLE
    pwsh -File tools/docbuild/finish-docx.ps1 -Docx docs/word/Change-Radar-Architecture.docx -PagesDir $env:TEMP/pages
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Docx, [string]$PagesDir, [int]$Dpi = 80)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Docx = (Resolve-Path $Docx).Path
$pdf = [IO.Path]::ChangeExtension($Docx, '.pdf')
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
try {
    $doc = $word.Documents.Open($Docx, $false, $false)
    foreach ($toc in $doc.TablesOfContents) { $toc.Update() }
    $doc.Fields.Update() | Out-Null
    foreach ($toc in $doc.TablesOfContents) { $toc.Update() }
    $doc.Save()
    $doc.ExportAsFixedFormat($pdf, 17)   # wdExportFormatPDF
    $pages = $doc.ComputeStatistics(2)   # wdStatisticPages
    $doc.Close($false)
} finally { $word.Quit() }
Write-Host "finished $(Split-Path $Docx -Leaf): $pages pages; PDF $(Split-Path $pdf -Leaf)"
# Word adds the tenant's sensitivity label (with the tenant id) on save and export: remove it, and prove it is gone.
uv run --no-project --python 3.13 --with pypdf==7.1.1 python (Join-Path $PSScriptRoot 'clean-output.py') $Docx $pdf
if ($LASTEXITCODE) { throw "$(Split-Path $Docx -Leaf): a sensitivity label or identifier is still in the output." }
if ($PagesDir) {
    New-Item -ItemType Directory -Force $PagesDir | Out-Null
    $py = @"
import sys, pypdfium2 as pdfium
d = pdfium.PdfDocument(sys.argv[1])
for i in range(len(d)):
    d[i].render(scale=int(sys.argv[3]) / 72).to_pil().save(f"{sys.argv[2]}/page-{i + 1:02d}.png")
print(f"rendered {len(d)} pages")
"@
    $script = Join-Path $PagesDir 'render-pages.py'
    Set-Content $script $py -Encoding utf8
    uv run --no-project --python 3.13 --with pypdfium2 --with pillow python $script $pdf $PagesDir $Dpi
}
