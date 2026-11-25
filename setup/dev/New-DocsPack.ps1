#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the documentation pack for a release: Change-Radar-Docs-<version>.zip (ADR 0025). Maintainers only.
.DESCRIPTION
    Run it after New-Release.ps1 and after writing "What's new", because the pack includes the Release Notes. Plans by
    default; -Apply builds. With -Apply:
      1. rebuilds every document in tools/docbuild/documents.csv (Word and PDF), unless -SkipBuild
      2. checks every file: no sensitivity label, tenant id, environment address or sign-in domain. The tenant id comes
         from the signed-in Azure CLI and is never printed or stored
      3. zips them by stage, with LICENSE, NOTICE and a README listing the documents, into out/release/<version>/
      4. adds the zip's line to SHA256SUMS there
    Refuses if a document is missing or names another release, if the Release Notes have no entry for the version, or
    if they still hold a placeholder. -Draft allows the placeholders, names the zip -DRAFT and leaves SHA256SUMS alone.
    It never tags, pushes or publishes.
.EXAMPLE
    pwsh -File setup/dev/New-DocsPack.ps1 -Version 0.3.0
    pwsh -File setup/dev/New-DocsPack.ps1 -Version 0.3.0 -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [switch]$Draft,
    [switch]$SkipBuild,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$out = Join-Path $repo 'out' 'release' $Version
$word = Join-Path $repo 'docs' 'word'
$zip = Join-Path $out "Change-Radar-Docs-$Version$(if ($Draft) { '-DRAFT' }).zip"
$docs = @(Import-Csv (Join-Path $repo 'tools' 'docbuild' 'documents.csv'))

# Guards
$problems = @(foreach ($d in $docs) {
        $md = Join-Path $repo 'docs' "$($d.source).md"
        if (-not (Test-Path $md)) { "$($d.source).md is missing"; continue }
        $release = (Select-String -Path $md -Pattern '^release:\s*Change Radar (\S+)' | Select-Object -First 1)
        if (-not $release -or $release.Matches[0].Groups[1].Value -ne $Version) { "$($d.source).md: front matter 'release' isn't Change Radar $Version" }
    })
$notes = Get-Content (Join-Path $repo 'docs' 'releases.md') -Raw
if ($notes -notmatch "(?m)^## $([regex]::Escape($Version)) ") { $problems += "docs/releases.md has no entry for $Version" }
$placeholders = @([regex]::Matches($notes, '\((write before publishing|draft: [^)]*)\)') | ForEach-Object Value)
if ($placeholders -and -not $Draft) { $problems += "docs/releases.md still holds $($placeholders.Count) placeholder(s): $(($placeholders | Select-Object -Unique) -join ', '). Edit the notes, or use -Draft" }
if ($Apply -and -not $Draft -and $SkipBuild) { $problems += '-SkipBuild is only for a -Draft pack: a release pack is always built from the current Markdown' }
$sums = Join-Path $out 'SHA256SUMS'
if (-not $Draft -and -not (Test-Path $sums)) { $problems += "no $sums (run New-Release.ps1 first)" }

Write-Host "PLAN: $(Split-Path $zip -Leaf), $($docs.Count) documents as Word and PDF"
$docs | Group-Object stage | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-24} {1}" -f $_.Name, $_.Count) }
if ($problems) { throw "Refusing:`n  $($problems -join "`n  ")" }
if (-not $Apply) { Write-Host 'Plan only. Nothing was built. Re-run with -Apply.'; return }

# 1. Build
if (-not $SkipBuild) {
    & pwsh -NoProfile -File (Join-Path $repo 'tools' 'docbuild' 'build-all.ps1')
    if ($LASTEXITCODE) { throw 'The document build failed.' }
}
$files = @(foreach ($d in $docs) { foreach ($ext in 'docx', 'pdf') { Join-Path $word "$($d.file).$ext" } })
$missing = @($files | Where-Object { -not (Test-Path $_) })
if ($missing) { throw "Missing after the build: $(($missing | Split-Path -Leaf) -join ', ')." }

# 2. Check
$tenant = (az account show --query tenantId -o tsv)
if (-not $tenant) { throw "Can't read the tenant id to check for (az login first)." }
uv run --no-project --python 3.13 --with pypdf==7.1.1 python (Join-Path $repo 'tools' 'docbuild' 'clean-output.py') --check --forbid $tenant @files
if ($LASTEXITCODE) { throw 'The identifier check failed. No pack was written.' }

# 3. Zip
New-Item -ItemType Directory -Force $out | Out-Null
$stageDir = Join-Path ([IO.Path]::GetTempPath()) "crdr-docs-$([guid]::NewGuid())"
try {
    foreach ($d in $docs) {
        $to = Join-Path $stageDir $d.stage
        New-Item -ItemType Directory -Force $to | Out-Null
        foreach ($ext in 'docx', 'pdf') { Copy-Item (Join-Path $word "$($d.file).$ext") $to }
    }
    foreach ($f in 'LICENSE', 'NOTICE') { Copy-Item (Join-Path $repo $f) (Join-Path $stageDir "$f.txt") }
    $readme = @("Change Radar documentation, release $Version$(if ($Draft) { ' (DRAFT)' })", '',
        'Each document is a PDF to read and a Word file to adapt (for example the sign-off in the Governance Approval Checklist).',
        'Start with the Solution Brief, then Prerequisites. Licence: Apache 2.0 (LICENSE.txt, NOTICE.txt).')
    foreach ($g in $docs | Group-Object stage | Sort-Object Name) {
        $readme += '', $g.Name
        $readme += $g.Group | ForEach-Object { "  $($_.file -replace '^Change-Radar-', '' -replace '-', ' ')" }
    }
    $readme -join "`r`n" | Set-Content (Join-Path $stageDir 'README.txt') -Encoding utf8
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zip
} finally { if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force } }

# 4. Checksum
$name = Split-Path $zip -Leaf
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $Draft) {
    $lines = @(Get-Content $sums | Where-Object { $_ -and $_ -notlike "*  $name" }) + "$sha  $name"
    $lines -join "`n" | Set-Content $sums -Encoding utf8
}
Write-Host "Built $name ($([Math]::Round((Get-Item $zip).Length / 1MB, 1)) MB, $($files.Count) files). SHA-256 $sha"
Write-Host $(if ($Draft) { 'A draft: not for publishing, and not in SHA256SUMS.' } else { "Add out/release/$Version/$name to the gh release command." })
