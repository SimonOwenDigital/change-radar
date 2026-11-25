#Requires -Version 7.0
<#
.SYNOPSIS
    Refreshes solutions/<SolutionName>/src (ChangeRadarCore by default; also ChangeRadarAsk) from the dev environment: exports unmanaged and managed, unpacks both,
    scans for tenant identifiers, checks every flow against the generator, then replaces src and repacks. Dev only.
.DESCRIPTION
    Read-only against the environment (pac solution export). Nothing in src changes unless the scan is clean and every
    exported flow's definition equals a generated one in solutions/design/flows (CLAUDE.md: no tenant identifiers in
    the repo; flows are generated, never hand-edited).
    The tenant id is taken from the signed-in az account at run time, never stored.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$EnvironmentId,
    [string]$SolutionName = 'ChangeRadarCore',
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$src = Join-Path $repo "solutions/$SolutionName/src"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("crdr-export-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

"Exporting $SolutionName (unmanaged and managed) to $work"
pac solution export --environment $EnvironmentUrl --name $SolutionName --path "$work/$SolutionName.zip" --overwrite | Out-Null
if ($LASTEXITCODE) { throw 'Unmanaged export failed.' }
pac solution export --environment $EnvironmentUrl --name $SolutionName --path "$work/${SolutionName}_managed.zip" --managed --overwrite | Out-Null
if ($LASTEXITCODE) { throw 'Managed export failed.' }
pac solution unpack --zipfile "$work/$SolutionName.zip" --folder "$work/src" --packagetype Both --allowDelete --allowWrite | Out-Null
if ($LASTEXITCODE) { throw 'Unpack failed.' }

# 1. Scan for tenant identifiers.
$tenantId = (az account show --query tenantId -o tsv)
$envHost = ([uri]$EnvironmentUrl).Host
$needles = @($tenantId, $envHost, $EnvironmentId) | Where-Object { $_ }
$hits = foreach ($f in Get-ChildItem "$work/src" -Recurse -File) {
    $text = Get-Content $f.FullName -Raw
    foreach ($n in $needles) { if ($text -and $text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { "$($f.FullName.Substring($work.Length)): environment or tenant identifier" } }
    if ($text -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') {
        $m = [regex]::Matches($text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') | ForEach-Object Value | Where-Object { $_ -notmatch '@(odata|Microsoft\.Dynamics|example\.)' } | Select-Object -Unique
        if ($m) { "$($f.FullName.Substring($work.Length)): email-like text $($m -join ', ')" }
    }
}
if ($hits) { $hits; throw "Scan found $(@($hits).Count) possible identifiers; src left unchanged. Export kept in $work." }
'Scan: no tenant id, environment URL or id, or email addresses.'

# 2. Every exported flow equals a generated one.
$generated = @{}
foreach ($g in Get-ChildItem (Join-Path $repo 'solutions/design/flows') -Filter *.json) {
    $d = (Get-Content $g.FullName -Raw | ConvertFrom-Json -Depth 100).properties.definition | ConvertTo-Json -Depth 100 -Compress
    $generated[$d] = $g.Name
}
$flows = @(if (Test-Path "$work/src/Workflows") { Get-ChildItem "$work/src/Workflows" -Filter *.json })
$bad = foreach ($f in $flows) {
    $d = (Get-Content $f.FullName -Raw | ConvertFrom-Json -Depth 100).properties.definition | ConvertTo-Json -Depth 100 -Compress
    if (-not $generated.ContainsKey($d)) { $f.Name }
}
if ($bad) { $bad | ForEach-Object { "Differs from the generator: $_" }; throw 'Flows differ from the generator; src left unchanged.' }
"Flows: $($flows.Count) of $($flows.Count) match the generator."

# 3. Every role's table privileges name the solution's own tables, and every role reads all of them (install test
#    finding 6: a dev-only fixture table in the Reader role was dropped at import, and a new table was missing).
$tables = @(@(if (Test-Path "$work/src/Entities") { Get-ChildItem "$work/src/Entities" -Directory }) | ForEach-Object { $_.Name.ToLowerInvariant() } | Where-Object { $_ -like 'crdr_*' })
$roleFiles = @(if (Test-Path "$work/src/Roles") { Get-ChildItem "$work/src/Roles" -Filter *.xml })
$roleBad = foreach ($r in $roleFiles) {
    $names = @(([xml](Get-Content $r.FullName -Raw)).Role.RolePrivileges.RolePrivilege.name)
    $own = @($names | ForEach-Object { if ($_ -match '^prv(?:Create|Read|Write|Delete|Append|AppendTo|Assign|Share)(crdr_\w+)$') { $Matches[1].ToLowerInvariant() } })
    foreach ($t in @($own | Where-Object { $tables -notcontains $_ } | Select-Object -Unique)) { "$($r.BaseName): privilege on $t, which isn't in the solution" }
    $reads = @($names | Where-Object { $_ -like 'prvReadcrdr_*' } | ForEach-Object { $_.Substring(7).ToLowerInvariant() })
    foreach ($t in @($tables | Where-Object { $reads -notcontains $_ })) { "$($r.BaseName): no read on $t" }
}
# 4. ADR 0023: Core holds no handler and no Teams or Outlook connection reference; Handlers ships every flow off
#    (a managed import brings a flow in the state it was exported in), whatever state it is in here.
if ($SolutionName -eq 'ChangeRadarCore') {
    $leak = @(Get-ChildItem "$work/src" -Recurse -File | Where-Object { $_.Name -match 'ChangeRadarhandler' -or ($_.Extension -in '.xml', '.json' -and (Select-String -Path $_.FullName -Pattern 'crdr_teams|crdr_outlook' -Quiet)) } | ForEach-Object { $_.FullName.Substring($work.Length) })
    if ($leak) { $leak | ForEach-Object { Write-Host "In Core, belongs in ChangeRadarHandlers: $_" }; throw 'Core contains handler components (ADR 0023); src left unchanged.' }
    'Core: no handler flows, no Teams or Outlook connection reference.'
}
if ($SolutionName -eq 'ChangeRadarHandlers') {
    $n = 0
    foreach ($d in @(if (Test-Path "$work/src/Workflows") { Get-ChildItem "$work/src/Workflows" -Filter *.data.xml })) {
        $t = [IO.File]::ReadAllText($d.FullName)
        $t2 = $t -replace '<StateCode>\d+</StateCode>', '<StateCode>0</StateCode>' -replace '<StatusCode>\d+</StatusCode>', '<StatusCode>1</StatusCode>'
        if ($t2 -ne $t) { [IO.File]::WriteAllText($d.FullName, $t2, [Text.UTF8Encoding]::new($t.Length -gt 0 -and [IO.File]::ReadAllBytes($d.FullName)[0] -eq 0xEF)); $n++ }
    }
    "Handlers: every flow ships off ($n switched off in the source; their state in $EnvironmentUrl is unchanged)."
}

if ($roleBad) { $roleBad | ForEach-Object { Write-Host $_ }; throw 'Role privileges differ from the solution''s tables; src left unchanged.' }
if ($roleFiles) { "Roles: $($roleFiles.Count) roles, each reads all $($tables.Count) tables and names no others." } else { 'Roles: none in this solution.' }

if (-not $Apply) { "Dry run: src unchanged. Re-run with -Apply to replace it. Export kept in $work."; return }

# 3. Replace src and repack.
Get-ChildItem $src -Force | Remove-Item -Recurse -Force
Copy-Item "$work/src/*" $src -Recurse -Force
pac solution pack --zipfile "$work/repack.zip" --folder $src --packagetype Both | Out-Null
if ($LASTEXITCODE) { throw 'Repack failed.' }
"src replaced from $EnvironmentUrl and repacked cleanly."
Remove-Item $work -Recurse -Force
