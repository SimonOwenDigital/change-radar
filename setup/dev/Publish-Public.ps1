#Requires -Version 7.0
<#
.SYNOPSIS
    Copies the public part of this repository into a checkout of the public one (ADR 0026). Maintainers only.
.DESCRIPTION
    Plans by default: lists what would be held back, and checks every public file, inside and out, for identifiers,
    links to files that aren't public, and the tenant's own ids. -Apply also replaces the contents of -Target, commits
    there and tags v<version>. It never pushes: it prints the commands, for a person to run.

    The ids to look for are read from the signed-in Azure CLI and pac (tenant, subscription, user, reader app, Key Vault
    names, environments). They are passed in memory, and never printed or stored. If any can't be read, it refuses.
    Text inside images can't be checked: look at new screenshots yourself.
.EXAMPLE
    pwsh -File setup/dev/Publish-Public.ps1 -Version 0.3.0
    pwsh -File setup/dev/Publish-Public.ps1 -Version 0.3.0 -Target C:/Dev/change-radar-public -Apply
    pwsh -File setup/dev/Publish-Public.ps1 -Version 0.3.0 -Assets
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$Target,
    [string]$ReaderAppName = 'crdr-reader',
    [switch]$Assets,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
if ($Apply -and -not $Target) { throw '-Apply needs -Target, a checkout of the public repository.' }

# Forbidden values
$forbid = [System.Collections.Generic.List[string]]::new()
function Add-Forbidden([string]$What, $Values) {
    $kept = @($Values | Where-Object { $_ -and "$_".Length -ge 5 })
    if (-not $kept) { throw "Can't read the $What to check for (az login, and pac auth)." }
    $kept | ForEach-Object { $forbid.Add("$_") }
}
$account = az account show -o json | ConvertFrom-Json
Add-Forbidden 'account' @($account.tenantId, $account.id, $account.user.name)
Add-Forbidden 'user id' @(az ad signed-in-user show --query id -o tsv)
Add-Forbidden 'reader app id' @(az ad app list --filter "displayName eq '$ReaderAppName'" --query '[].[appId,id]' -o tsv | ForEach-Object { $_ -split '\s+' })
Add-Forbidden 'Key Vault names' @(az keyvault list --query '[].name' -o tsv)
$envs = @(pac env list --json | ConvertFrom-Json)
Add-Forbidden 'environments' @($envs | ForEach-Object { $_.OrganizationId; $_.EnvironmentIdentifier; ([uri]$_.EnvironmentUrl).Host; $_.UniqueName })
$env:CRDR_FORBID = $forbid -join "`n"

try {
    $python = @('run', '--no-project', '--python', '3.13', '--with', 'pypdf==7.1.1', 'python')
    $publish = Join-Path $repo 'tools' 'publish' 'publish.py'
    if ($Assets) {
        $out = Join-Path $repo 'out' 'release' $Version
        $files = @(Get-ChildItem $out -File | Where-Object Name -notlike '*-DRAFT.zip')
        if (-not $files) { throw "No release files in $out." }
        uv @python $publish --files @($files.FullName)
        if ($LASTEXITCODE) { throw 'The release files were refused.' }
        return
    }
    uv @python (Join-Path $repo 'tools' 'publish' 'test_publish.py') | Select-Object -Last 1
    if ($LASTEXITCODE) { throw 'The publish tests fail.' }
    $cmd = @($publish, '--repo', $repo, '--allow', (Join-Path $repo 'tools' 'publish' 'public-paths.txt'), '--require-link', 'empoweryour.world')
    if ($Apply) {
        if (git -C $Target tag --list "v$Version") { throw "Refusing: v$Version is already tagged in the target." }
        $cmd += '--target', $Target
    } else { $cmd += '--show-held' }
    uv @python @cmd
    if ($LASTEXITCODE) { throw 'Refused. Nothing was published.' }
} finally { $env:CRDR_FORBID = $null }

if (-not $Apply) { Write-Host 'Plan only. Re-run with -Target and -Apply.'; return }
git -C $Target add -A
git -C $Target commit -q -m "Change Radar $Version"
if ($LASTEXITCODE) { throw 'Nothing to commit in the target, or the commit failed.' }
git -C $Target tag "v$Version"
Write-Host "Committed and tagged v$Version in the target. Look through it, then, by a person:"
Write-Host "  git -C $Target push origin main v$Version"
