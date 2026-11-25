#Requires -Version 7.0
<#
.SYNOPSIS
    Runs a recurrence-triggered Change Radar flow now, waits for it, and prints failed actions. Dev only.
.DESCRIPTION
    Uses the Flow management API with an Az.Accounts token, because the az CLI isn't installed on the dev machine
    and the Power Automate plugin needs it (observed 2026-11-20). Triggers the flow's Recurrence trigger.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentId,
    [Parameter(Mandatory)][string]$WorkflowId,
    [int]$TimeoutSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
$h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl 'https://service.flow.microsoft.com/' -AsSecureString).Token -AsPlainText)" }
$base = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows/$WorkflowId"
$api = 'api-version=2016-11-01'
$before = @((Invoke-RestMethod "$base/runs?$api&`$top=1" -Headers $h).value | ForEach-Object name)
Invoke-RestMethod -Method POST "$base/triggers/Recurrence/run?$api" -Headers $h | Out-Null
$run = $null
for ($i = 0; $i -lt 30 -and -not $run; $i++) { Start-Sleep 2; $run = @((Invoke-RestMethod "$base/runs?$api&`$top=1" -Headers $h).value | Where-Object { $before -notcontains $_.name }) | Select-Object -First 1 }
if (-not $run) { throw 'The run did not appear.' }
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do { Start-Sleep 5; $r = Invoke-RestMethod "$base/runs/$($run.name)?$api" -Headers $h } while ($r.properties.status -eq 'Running' -and (Get-Date) -lt $deadline)
# A run still going at the timeout has no endTime yet (observed 2026-11-22 on a 30-minute rating pass): say so, don't fail.
$end = $r.properties.PSObject.Properties['endTime']?.Value
"$($run.name) $($r.properties.status) $($r.properties.startTime) -> $(if ($end) { $end } else { "still running after $TimeoutSeconds s; check the run later" })"
if ($r.properties.status -ne 'Succeeded') {
    foreach ($a in @((Invoke-RestMethod "$base/runs/$($run.name)/actions?$api" -Headers $h).value | Where-Object { $_.properties.status -eq 'Failed' })) {
        $msg = $a.properties.PSObject.Properties['error'] ? $a.properties.error.message : ''
        try {
            $rep = @((Invoke-RestMethod "$base/runs/$($run.name)/actions/$($a.name)/repetitions?$api" -Headers $h).value | Where-Object { $_.properties.status -eq 'Failed' }) | Select-Object -First 1
            if ($rep -and $rep.properties.PSObject.Properties['error']) { $msg = $rep.properties.error.message }
        } catch { }
        "  FAILED $($a.name): $msg"
    }
    exit 1
}
