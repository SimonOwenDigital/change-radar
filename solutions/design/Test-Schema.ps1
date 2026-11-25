#Requires -Version 7.0
<#
.SYNOPSIS
    Validates solutions/design/schema.json and renders it to schema.md. Never deploys anything.
.PARAMETER Prefix
    Publisher prefix to render with. Defaults to the prefix in schema.json.
#>
[CmdletBinding()]
param(
    [string]$SchemaPath = (Join-Path $PSScriptRoot 'schema.json'),
    [string]$OutMarkdown = (Join-Path $PSScriptRoot 'schema.md'),
    [string]$Prefix
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$s = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$prefix = if ($Prefix) { $Prefix } else { $s.publisher.prefix }
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if ($prefix -eq 'PREFIX') { $warnings.Add("Prefix is the placeholder 'PREFIX' (ADR 0003 not accepted).") }
elseif ($prefix -notmatch '^[a-z][a-z0-9]{1,7}$' -or $prefix -like 'mscrm*') { $errors.Add("Prefix '$prefix' must be 2-8 lowercase alphanumerics starting with a letter, not 'mscrm' (max length 8 verified; other rules assumed).") }

$tableNames = @($s.tables.name)
$known = $tableNames + @($s.externalTables)
$choiceNames = @($s.choices.PSObject.Properties.Name)
$validTypes = 'string', 'memo', 'choice', 'lookup', 'datetime', 'bool', 'int', 'decimal', 'url'

foreach ($dup in ($tableNames | Group-Object | Where-Object Count -gt 1)) { $errors.Add("Duplicate table '$($dup.Name)'.") }
foreach ($t in $s.tables) {
    if ($t.name -cnotmatch '^[a-z][a-z0-9]*$') { $errors.Add("Table '$($t.name)' must be lowercase alphanumeric.") }
    $cols = @($t.columns.name)
    foreach ($dup in ($cols | Group-Object | Where-Object Count -gt 1)) { $errors.Add("$($t.name): duplicate column '$($dup.Name)'.") }
    if ($cols -notcontains $t.primaryName) { $errors.Add("$($t.name): primary name '$($t.primaryName)' isn't a column.") }
    foreach ($c in $t.columns) {
        if ($c.name -cnotmatch '^[a-z][a-z0-9]*$') { $errors.Add("$($t.name).$($c.name): column names must be lowercase alphanumeric.") }
        if ($c.name -eq "$($t.name)id") { $errors.Add("$($t.name).$($c.name): clashes with the table's own primary key column '${prefix}_$($t.name)id'.") }
        if ($validTypes -notcontains $c.type) { $errors.Add("$($t.name).$($c.name): unknown type '$($c.type)'.") }
        if ($c.type -eq 'lookup' -and $known -notcontains $c.target) { $errors.Add("$($t.name).$($c.name): lookup target '$($c.target)' doesn't exist.") }
        if ($c.type -eq 'choice' -and $choiceNames -notcontains $c.choice) { $errors.Add("$($t.name).$($c.name): choice '$($c.choice)' isn't defined.") }
        if ($c.type -in 'string', 'memo', 'url' -and -not $c.PSObject.Properties['maxLength']) { $errors.Add("$($t.name).$($c.name): text columns need maxLength.") }
        $full = "${prefix}_$($c.name)".ToLowerInvariant()
        if ($full.Length -gt 50) { $warnings.Add("$($t.name).$($c.name): '$full' is long; check the logical name limit.") }
    }
    foreach ($k in @($t.PSObject.Properties['alternateKeys'] ? $t.alternateKeys : @())) {
        $bytes = 0
        foreach ($kc in $k.columns) {
            $kcol = $t.columns | Where-Object name -eq $kc
            if (-not $kcol) { $errors.Add("$($t.name): alternate key '$($k.name)' uses unknown column '$kc'."); continue }
            if ($kcol.type -notin 'string', 'int', 'decimal', 'datetime', 'lookup', 'choice') { $errors.Add("$($t.name): alternate key '$($k.name)' column '$kc' has type '$($kcol.type)', which keys don't support.") }
            if (-not ($kcol.PSObject.Properties['required'] -and $kcol.required)) { $warnings.Add("$($t.name): alternate key '$($k.name)' column '$kc' is optional; uniqueness isn't enforced when it's null (verified 2026-11-19).") }
            $bytes += switch ($kcol.type) { 'string' { 2 * $kcol.maxLength } 'lookup' { 16 } default { 8 } }
        }
        # Observed in pp-lab 2026-11-19: primary name columns are always created at 850 chars (1700 bytes in the database),
        # whatever MaxLength is requested, and the key index limit enforced is 1700 bytes. So a primary name column can
        # only be a key on its own.
        if ($k.columns -contains $t.primaryName) {
            if (@($k.columns).Count -gt 1) { $errors.Add("$($t.name): alternate key '$($k.name)' combines the primary name column with others; primary name columns are stored at 1700 bytes, so the key would exceed the limit.") }
            else { $warnings.Add("$($t.name): alternate key '$($k.name)' is the primary name column alone (1700 bytes, exactly at the limit).") }
            continue
        }
        if ($bytes -gt 900) { $errors.Add("$($t.name): alternate key '$($k.name)' is about $bytes bytes; Learn documents 900 (verified 2026-11-19).") }
    }
}
# Display labels (labels.json)
$labelsPath = Join-Path $PSScriptRoot 'labels.json'
$labels = if (Test-Path $labelsPath) { Get-Content -Raw $labelsPath | ConvertFrom-Json -Depth 20 -AsHashtable } else { $errors.Add('labels.json is missing.'); $null }
if ($labels) {
    foreach ($t in $s.tables) {
        if (-not $labels.tables.ContainsKey($t.name)) { $errors.Add("labels.json: no plural label for table '$($t.name)'.") }
        foreach ($c in $t.columns) { if (-not $labels.columns.ContainsKey($c.name)) { $errors.Add("labels.json: no label for column '$($c.name)'.") } }
    }
    foreach ($p in $s.choices.PSObject.Properties) {
        if (-not $labels.choices.ContainsKey($p.Name)) { $errors.Add("labels.json: no labels for choice '$($p.Name)'."); continue }
        foreach ($v in $p.Value) { if (-not $labels.choices[$p.Name].values.ContainsKey($v)) { $errors.Add("labels.json: no label for '$($p.Name).$v'.") } }
    }
}
# Facet choice must match the vocabulary facets
$vocabPath = Join-Path $PSScriptRoot '..' '..' 'seed' 'vocabulary.csv'
if (Test-Path $vocabPath) {
    $vocabFacets = @(Import-Csv $vocabPath | ForEach-Object facet | Sort-Object -Unique)
    $missing = @($vocabFacets | Where-Object { @($s.choices.facet) -notcontains $_ })
    if ($missing) { $errors.Add("Choice 'facet' lacks vocabulary facets: $($missing -join ', ').") }
}
# Unused choices
$used = @($s.tables.columns | Where-Object type -eq 'choice' | ForEach-Object choice | Sort-Object -Unique)
foreach ($ch in $choiceNames) { if ($used -notcontains $ch) { $warnings.Add("Choice '$ch' isn't used by any column.") } }

# Render
$md = @('# Change Radar Dataverse schema (design)', '',
    "> Generated from ``schema.json`` by ``Test-Schema.ps1``. Design only: **not deployed**. Prefix: ``$prefix`` ($($s.publisher.prefixStatus)).", '',
    'Rows marked *proposed* aren''t in spec §4; they close gaps listed in `docs/overnight/summary.md`.', '',
    '## Relationships', '', '```mermaid', 'erDiagram')
foreach ($t in $s.tables) {
    foreach ($c in @($t.columns | Where-Object type -eq 'lookup')) {
        $tgt = if (@($s.externalTables) -contains $c.target) { $c.target } else { "$($prefix)_$($c.target)" }
        $md += "    $tgt ||--o{ $($prefix)_$($t.name) : `"$($c.name) ($($c.PSObject.Properties['cascade'] ? $c.cascade : 'referential'))`""
    }
}
$md += '```', ''
foreach ($t in $s.tables) {
    $flag = if ($t.PSObject.Properties['proposed'] -and $t.proposed) { ' *(proposed)*' } else { '' }
    $md += "## ``$($prefix)_$($t.name)``: $($t.displayName)$flag", ''
    if ($t.PSObject.Properties['description']) { $md += $t.description, '' }
    $md += '| Column | Label | Type | Req | Notes |', '|---|---|---|---|---|'
    foreach ($c in $t.columns) {
        $type = switch ($c.type) { 'choice' { "choice ``$($c.choice)``" } 'lookup' { "lookup → ``$($c.target)``" } { $_ -in 'string', 'memo', 'url' } { "$($c.type)($($c.maxLength))" } default { $c.type } }
        $notes = @()
        if ($c.PSObject.Properties['description']) { $notes += $c.description }
        if ($c.PSObject.Properties['proposed'] -and $c.proposed) { $notes += '*proposed*' }
        $req = if ($c.PSObject.Properties['required'] -and $c.required) { 'yes' } else { '' }
        $label = if ($labels -and $labels.columns.ContainsKey($c.name)) { $labels.columns[$c.name] } else { '' }
        $md += "| ``$($prefix)_$($c.name)`` | $label | $type | $req | $($notes -join '; ') |"
    }
    if ($t.PSObject.Properties['alternateKeys']) { $md += '', "Alternate keys: $(($t.alternateKeys | ForEach-Object { "``$($_.name)`` ($($_.columns -join ', '))" }) -join '; ')" }
    $md += ''
}
$md += '## Choices', '', '| Choice | Values (ordinal order) |', '|---|---|'
foreach ($p in $s.choices.PSObject.Properties) { $md += "| ``$($prefix)_$($p.Name)`` | $($p.Value -join ', ') |" }
[IO.File]::WriteAllText($OutMarkdown, (($md -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

$warnings | ForEach-Object { Write-Host "WARN  $_" }
$errors | ForEach-Object { Write-Host "ERROR $_" }
Write-Host ("{0} tables, {1} columns, {2} choices: {3} error(s), {4} warning(s)" -f $s.tables.Count, @($s.tables.columns).Count, $choiceNames.Count, $errors.Count, $warnings.Count)
if ($errors.Count -gt 0) { exit 1 }
