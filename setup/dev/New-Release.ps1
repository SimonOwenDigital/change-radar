#Requires -Version 7.0
<#
.SYNOPSIS
    Builds a versioned managed release of Change Radar (ADR 0022, 0023): ChangeRadarCore, ChangeRadarHandlers and ChangeRadarAsk. Maintainers only.
.DESCRIPTION
    Plans by default; -Apply builds. Refuses unless the git working tree is clean and every engine test suite passes,
    and unless -Version is higher than every solution's current version (a managed upgrade needs a higher version).
    With -Apply:
      1. sets the version on each solution in the dev environment (pac solution online-version), so later exports
         keep it, and in the repo's unpacked Solution.xml
      2. packs each solution as managed into out/release/<version>/ (out/ is ignored by git)
      3. runs the solution checker on each zip (pac solution check; it sends the zip to Microsoft's checker service),
         unless -SkipCheck
      4. writes SHA256SUMS next to the zips, and adds a release entry to docs/releases.md (commit it with the version)
    It never tags, pushes or publishes: it prints the gh command for that, for a person to run.
.EXAMPLE
    ./setup/dev/New-Release.ps1 -Version 0.2.0 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName pp-lab
    ./setup/dev/New-Release.ps1 -Version 0.2.0 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName pp-lab -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$ExpectedEnvironmentName,
    [string[]]$Solutions = @('ChangeRadarCore', 'ChangeRadarHandlers', 'ChangeRadarAsk'),   # install order (ADR 0023)
    [switch]$SkipCheck,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$full = "$Version.0"
$out = Join-Path $repo 'out' 'release' $Version

# Guards
$who = pac org who --environment $EnvironmentUrl 2>&1 | Out-String
if ($who -notmatch [regex]::Escape($ExpectedEnvironmentName)) { throw "Refusing: '$EnvironmentUrl' isn't '$ExpectedEnvironmentName' (pac org who)." }
$dirty = git -C $repo status --porcelain
if ($dirty) { throw "Refusing: the working tree has uncommitted changes. Commit or stash them first.`n$($dirty -join "`n")" }
$current = foreach ($s in $Solutions) {
    $xml = Join-Path $repo 'solutions' $s 'src' 'Other' 'Solution.xml'
    if (-not (Test-Path $xml)) { throw "No unpacked solution at $xml." }
    $v = ([xml](Get-Content $xml -Raw)).ImportExportXml.SolutionManifest.Version
    # A rebuild of a version not yet recorded in docs/releases.md is allowed (a failed or interrupted build).
    $notesFile = Join-Path $repo 'docs' 'releases.md'
    $recorded = (Test-Path $notesFile) -and (Select-String -Path $notesFile -Pattern "^## $([regex]::Escape($Version)) " -Quiet)
    if ([version]$full -lt [version]$v -or ([version]$full -eq [version]$v -and $recorded)) { throw "Refusing: $s is already at $v$(if ($recorded) { ', released' }); -Version must be higher." }
    [pscustomobject]@{ Solution = $s; Xml = $xml; From = $v }
}
Write-Host 'Running the engine test suites...'
$failed = foreach ($t in Get-ChildItem (Join-Path $repo 'engine') -Filter 'Invoke-*Tests.ps1') {
    pwsh -NoProfile -File $t.FullName *> $null
    if ($LASTEXITCODE) { $t.Name }
}
if ($failed) { throw "Refusing: test suites failing: $($failed -join ', ')." }
$commit = git -C $repo rev-parse --short HEAD

Write-Host "`nPLAN: release $Version from commit $commit"
foreach ($c in $current) { Write-Host ("  {0,-16} {1} -> {2}   out/release/{3}/{0}_{3}_managed.zip" -f $c.Solution, $c.From, $full, $Version) }
Write-Host "  solution checker: $(if ($SkipCheck) { 'skipped' } else { 'each zip' })"
Write-Host '  docs/releases.md: new entry'
if (-not $Apply) { Write-Host 'Plan only. Nothing was changed. Re-run with -Apply.'; return }

# 1. Versions
foreach ($c in $current) {
    pac solution online-version --environment $EnvironmentUrl --solution-name $c.Solution --solution-version $full | Out-Null
    if ($LASTEXITCODE) { throw "Setting the version of $($c.Solution) in $ExpectedEnvironmentName failed." }
    # Only when it changes, keeping the file's byte-order mark (pac writes one), so a rebuild leaves the tree clean.
    if ($c.From -ne $full) {
        $bytes = [IO.File]::ReadAllBytes($c.Xml); $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $text = [IO.File]::ReadAllText($c.Xml) -replace '<Version>[^<]+</Version>', "<Version>$full</Version>"
        [IO.File]::WriteAllText($c.Xml, $text, [Text.UTF8Encoding]::new($bom))
    }
}

# 2. Pack, 3. check
New-Item -ItemType Directory -Force $out | Out-Null
$built = foreach ($c in $current) {
    $zip = Join-Path $out "$($c.Solution)_$($Version)_managed.zip"
    pac solution pack --zipfile $zip --folder (Join-Path $repo 'solutions' $c.Solution 'src') --packagetype Managed | Out-Null
    if ($LASTEXITCODE) { throw "Packing $($c.Solution) failed." }
    $issues = 'not run'
    if (-not $SkipCheck) {
        $chk = Join-Path $out "check-$($c.Solution)"
        if (Test-Path $chk) { Remove-Item $chk -Recurse -Force }
        $res = pac solution check --path $zip --outputDirectory $chk --geo UnitedKingdom 2>&1 | Out-String
        if ($LASTEXITCODE) { throw "Solution checker failed for $($c.Solution):`n$res" }
        # The checker's result is a SARIF file in a zip: count results by severity, and name each rule and where.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $rz = [IO.Compression.ZipFile]::OpenRead((Get-ChildItem $chk -Filter *.zip | Select-Object -First 1).FullName)
        try { $sarif = [IO.StreamReader]::new(($rz.Entries | Where-Object FullName -like '*.sarif' | Select-Object -First 1).Open()).ReadToEnd() | ConvertFrom-Json -Depth 50 } finally { $rz.Dispose() }
        $found = @($sarif.runs | ForEach-Object { if ($_.PSObject.Properties['results']) { $_.results } })
        $issues = if (-not $found) { 'no issues' } else { (($found | Group-Object { $_.properties.severity } | ForEach-Object { "$($_.Count) $($_.Name.ToLowerInvariant())" }) -join ', ') + ': ' + (($found | ForEach-Object { "$($_.ruleId) ($(($_.locations[0].logicalLocations.fullyQualifiedName | Select-Object -First 1) -replace '^Change Radar: ', ''))" } | Select-Object -Unique) -join '; ') }
    }
    [pscustomobject]@{ Solution = $c.Solution; Zip = $zip; Sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant(); Bytes = (Get-Item $zip).Length; Check = $issues }
}

# 4. Checksums and notes
($built | ForEach-Object { "$($_.Sha)  $(Split-Path $_.Zip -Leaf)" }) -join "`n" | Set-Content (Join-Path $out 'SHA256SUMS') -Encoding utf8
# The licence and its NOTICE travel with every release (Apache 2.0 section 4, ADR 0024).
foreach ($f in 'LICENSE', 'NOTICE') { Copy-Item (Join-Path $repo $f) (Join-Path $out $f) -Force }
$core = Join-Path $repo 'solutions' 'ChangeRadarCore' 'src'
$counts = "$(@(Get-ChildItem (Join-Path $core 'Entities') -Directory | Where-Object Name -like 'crdr_*').Count) tables, $(@(Get-ChildItem (Join-Path $core 'Workflows') -Filter *.json).Count) flows, $(@(Get-ChildItem (Join-Path $core 'Roles') -Filter *.xml).Count) security roles"
$notesPath = Join-Path $repo 'docs' 'releases.md'
if (-not (Test-Path $notesPath)) { Set-Content $notesPath "# Releases`n`n> **For:** whoever installs or upgrades Change Radar. **Kind:** reference.`n> Each release is a set of managed solutions built by ``setup/dev/New-Release.ps1`` from the commit named. Check a download against its SHA-256 before importing. Newest first.`n" -NoNewline -Encoding utf8 }
$entry = @"

## $Version ($(Get-Date -Format 'd MMMM yyyy'))

Built from commit ``$commit``. ChangeRadarCore: $counts.

| File | Size | SHA-256 | Solution checker |
|---|---|---|---|
$(($built | ForEach-Object { "| ``$(Split-Path $_.Zip -Leaf)`` | $([Math]::Round($_.Bytes / 1KB)) KB | ``$($_.Sha)`` | $($_.Check) |" }) -join "`n")

**Install or upgrade:** [``install.md``](install.md). Upgrading keeps your settings and data; import with ``--async``.

**What's new:** (write before publishing)
"@
$notes = Get-Content $notesPath -Raw
$i = $notes.IndexOf("`n## ")
$notes = if ($i -ge 0) { $notes.Insert($i, $entry.TrimEnd() + "`n") } else { $notes.TrimEnd() + "`n" + $entry }
Set-Content $notesPath $notes -NoNewline -Encoding utf8

$built | Format-Table Solution, @{ n = 'KB'; e = { [Math]::Round($_.Bytes / 1KB) } }, Sha, Check -AutoSize | Out-String -Width 220
Write-Host "Built in out/release/$Version. Next, by a person:"
Write-Host "  1. Write 'What's new' in docs/releases.md, then commit the version change and the notes."
Write-Host "  2. Documentation pack: pwsh -File setup/dev/New-DocsPack.ps1 -Version $Version -Apply   (after the notes: it includes them)"
Write-Host "  3. Publish: gh release create v$Version $(($built | ForEach-Object { "out/release/$Version/$(Split-Path $_.Zip -Leaf)" }) -join ' ') out/release/$Version/SHA256SUMS out/release/$Version/LICENSE out/release/$Version/NOTICE out/release/$Version/Change-Radar-Docs-$Version.zip --title 'Change Radar $Version' --notes-file <notes>"
