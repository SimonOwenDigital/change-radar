#Requires -Version 7.0
<#
.SYNOPSIS
    Exports the tenant's Power Platform inventory as an estate file (docs/estate-file-format.md, source = live).
.DESCRIPTION
    Endpoint: POST https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01
    (PowerPlatformResources). Delegated only: runs as the signed-in Az.Accounts user; service principals get
    403 (ADR 0008). Same query as the 'Change Radar: collect estate inventory' flow: every resource except
    the connector catalogue and usage records, all pages.

    The full export holds real names and ids, so -OutPath must be outside the repo (default: temp folder).
    -SamplePath writes a redacted copy for samples/: names become '<type> NN', ids are replaced by stable
    hashes, owners and creators are dropped.

    Read-only. Owner kind (user or service principal) needs a directory lookup that phase 2 doesn't make
    yet, so principals is empty and owner-based facets don't fire (ADR 0008).
.EXAMPLE
    pwsh -File queries/inventory.ps1 -SamplePath samples/live/estate-redacted.json
#>
[CmdletBinding()]
param(
    [string]$OutPath = (Join-Path ([IO.Path]::GetTempPath()) 'change-radar-live-estate.json'),
    [string]$SamplePath,
    [string]$Endpoint = 'https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([IO.Path]::GetFullPath($OutPath).StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { throw "OutPath is inside the repo. The full export holds tenant data; write it elsewhere and use -SamplePath for a redacted copy." }

Import-Module Az.Accounts -ErrorAction Stop
$token = ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl 'https://api.powerplatform.com' -AsSecureString).Token -AsPlainText
function Invoke-InventoryQuery([object[]]$Clauses) {
    # '$type' must be the first key of every clause (verified 2026-11-19), hence [ordered].
    $rows = [Collections.Generic.List[object]]::new(); $skip = ''
    do {
        $body = [ordered]@{ TableName = 'PowerPlatformResources'; Clauses = $Clauses; Options = [ordered]@{ Top = 1000; SkipToken = $skip } } | ConvertTo-Json -Depth 20
        $r = Invoke-RestMethod -Method POST -Uri $Endpoint -Headers @{ Authorization = "Bearer $token" } -Body $body -ContentType 'application/json'
        $rows.AddRange(@($r.data)); $skip = $r.PSObject.Properties['skipToken'] ? $r.skipToken : $null
    } while ($skip)
    , $rows.ToArray()
}
$excluded = @("'microsoft.powerplatformconnector/connectors'", "'microsoft.powerplatformusage/usagerecords'", "'microsoft.powerplatform/environmentgroups'")  # groups: tenant structure, not maker assets (seen 2026-11-22; also excluded by the estate flow)
$rows = Invoke-InventoryQuery @([ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = '!in~'; Values = $excluded })
$keep = 'name', 'type', 'location', 'properties'
$environments = @($rows | Where-Object type -eq 'microsoft.powerplatform/environments' | Select-Object $keep)
$inventory = @($rows | Where-Object type -ne 'microsoft.powerplatform/environments' | Select-Object $keep)
$estate = [ordered]@{
    schemaVersion = '0.2'
    meta          = [ordered]@{ source = 'live'; asOf = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); collector = 'queries/inventory.ps1' }
    environments  = $environments; principals = @(); inventory = $inventory
}
[IO.File]::WriteAllText($OutPath, ($estate | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
"environments $($environments.Count), resources $($inventory.Count) -> $OutPath"
$inventory | Group-Object type | Sort-Object Name | ForEach-Object { "  {0,4}  {1}" -f $_.Count, $_.Name }

if ($SamplePath) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = { param($s) if (-not $s) { return $s }; 'id-' + (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s.ToLower()))[0..5] | ForEach-Object { $_.ToString('x2') })) }
    $n = @{}
    $label = { param($type) $short = ($type -split '/')[-1]; $n[$short] = 1 + ($n[$short] ?? 0); '{0} {1:00}' -f $short, $n[$short] }
    $drop = 'createdBy', 'lastModifiedBy', 'ownerId', 'entraAgentId', 'entraAgentBlueprintId', 'titleId', 'schemaName', 'logicalName', 'appModuleId', 'workflowEntityId', 'environmentGroupId', 'sharedWithEditors', 'sharedWithViewers', 'flows'
    $redact = {
        param($r)
        $p = $r.properties | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        foreach ($d in $drop) { if ($p.PSObject.Properties[$d]) { $p.PSObject.Properties.Remove($d) } }
        $p.displayName = & $label $r.type
        if ($p.PSObject.Properties['environmentId']) { $p.environmentId = & $hash $p.environmentId }
        [ordered]@{ name = (& $hash $r.name); type = $r.type; location = $r.location; properties = $p }
    }
    $sample = [ordered]@{
        schemaVersion = '0.2'
        meta          = [ordered]@{ source = 'live'; asOf = $estate.meta.asOf; collector = 'queries/inventory.ps1'; redacted = 'names replaced, ids hashed, owners and creators dropped (queries/inventory.ps1 -SamplePath)' }
        environments  = @($environments | ForEach-Object { & $redact $_ }); principals = @()
        inventory     = @($inventory | ForEach-Object { & $redact $_ })
    }
    [IO.File]::WriteAllText($SamplePath, ($sample | ConvertTo-Json -Depth 40) + "`n", [Text.UTF8Encoding]::new($false))
    "redacted sample -> $SamplePath"
}
