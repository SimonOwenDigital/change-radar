#Requires -Version 7.0
<#
.SYNOPSIS
    Graph service health issues for the in-scope services (seed/config.csv graph_services), as the crdr-reader app.
.DESCRIPTION
    Endpoint: GET https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/issues (permission ServiceHealth.Read.All, application).
    Same request as the 'Change Radar: collect service health' flow: all pages, then filtered on service.
    Read-only. Prints counts; with -SamplePath, writes the first -SampleCount in-scope items, redacted
    (queries/SampleRedaction.ps1), as a sample for samples/graph/.
.EXAMPLE
    pwsh -File queries/graph-service-health.ps1 -SubscriptionId <guid> -SamplePath samples/graph/service-health-issues.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'seed' 'config.csv'),
    [string]$SamplePath,
    [int]$SampleCount = 5
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReaderAuth.ps1')
. (Join-Path $PSScriptRoot 'SampleRedaction.ps1')

$services = @((Import-Csv $ConfigPath | Where-Object key -eq 'graph_services').value -split ';' | ForEach-Object Trim)
$headers = @{ Authorization = "Bearer $(Get-CrdrReaderToken -SubscriptionId $SubscriptionId -Scope 'https://graph.microsoft.com/.default')" }
$all = [Collections.Generic.List[object]]::new()
$uri = 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/issues'
while ($uri) {
    $page = Invoke-RestMethod -Uri $uri -Headers $headers
    $all.AddRange(@($page.value))
    $uri = $page.PSObject.Properties['@odata.nextLink'] ? $page.'@odata.nextLink' : $null
}
$inScope = @($all | Where-Object { $_.service -in $services })
"fetched $($all.Count), in scope $($inScope.Count)"
if ($SamplePath) {
    $sample = Protect-CrdrSample -Items @($inScope | Select-Object -First $SampleCount)
    [IO.File]::WriteAllText($SamplePath, ($sample | ConvertTo-Json -Depth 30 -AsArray) + "`n", [Text.UTF8Encoding]::new($false))
    "wrote $($sample.Count) redacted item(s) to $SamplePath"
}
