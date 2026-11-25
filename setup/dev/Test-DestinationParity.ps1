#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the handlers' alert destination parsing and email HTML against the reference engine (ADR 0011 addendum).
    Dev only.
.DESCRIPTION
    Builds a temporary flow from the same expressions the handlers use (solutions/design/flows/AlertDelivery.ps1),
    feeding it every case in tests/events/destinations.json: the 'parse' cases through the destination steps, the
    'email' cases through the email HTML. It saves the flow in the dev environment (outside the solution, named
    '[TEST] Change Radar destination parity'), runs it once, compares its output with the expected values, and
    deletes it. The flow has no connector actions: it sends nothing and reads or writes no data.
    Exit code 1 on any difference.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][string]$EnvironmentId,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$CasesPath = (Join-Path $PSScriptRoot '..' '..' 'tests' 'events' 'destinations.json'),
    [switch]$Keep   # leave the test flow in place (for looking at the run)
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Get-Token([string]$r) { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $r -AsSecureString).Token -AsPlainText }
function Invoke-Dv([string]$Method = 'GET', [string]$Path, $Body) {
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = @{ Authorization = "Bearer $(Get-Token $EnvironmentUrl)"; Accept = 'application/json'; Prefer = 'return=representation' } }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 80 -Compress)); $p.ContentType = 'application/json; charset=utf-8' }
    Invoke-RestMethod @p
}
$org = Invoke-Dv -Path 'RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType''Default'')'
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'. Stopping." }

# ---------- the flow, from the handlers' own expressions ----------
function After([string]$name, [string[]]$states = @('Succeeded')) { @{ $name = $states } }
. (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'flows' 'AlertDelivery.ps1')
function JsonLit($o) { "json('" + ((ConvertTo-Json -InputObject $o -Depth 10 -Compress) -replace "'", "''") + "')" }
$cases = Get-Content -Raw $CasesPath -Encoding utf8 | ConvertFrom-Json -Depth 20
$appUrl = $cases.email.appUrl
$parseIn = @($cases.parse | ForEach-Object { [ordered]@{ id = $_.id; destinations = $_.destinations; recipient = $_.recipient } })
$mailIn = @($cases.email.cases | ForEach-Object {
        $c = $_.card | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable; $c.links.app = $c.links.app.Replace('{appUrl}', $appUrl)
        [ordered]@{ id = $_.id; type = $_.type; card = $c } })

$parseLoop = [ordered]@{}
Add-DestinationActions $parseLoop "items('Each_case')?['destinations']" "items('Each_case')?['recipient']" @{}
$parseLoop['Note_case'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Destinations'); inputs = @{ name = 'parsed'; value = [ordered]@{ id = "@items('Each_case')?['id']"; dests = "@outputs('Destinations')" } } }
$mailLoop = [ordered]@{}
$mailLoop['Fields'] = [ordered]@{ type = 'Compose'; runAfter = @{}; inputs = "@items('Each_mail')?['card']" }
$mailLoop['Type'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Fields'); inputs = "@items('Each_mail')?['type']" }
$mailLoop['Email_html'] = [ordered]@{ type = 'Compose'; runAfter = (After 'Type'); inputs = "@$(EmailHtml "outputs('Fields')" (AlertFooter "outputs('Type')"))" }
$mailLoop['Note_mail'] = [ordered]@{ type = 'AppendToArrayVariable'; runAfter = (After 'Email_html'); inputs = @{ name = 'mails'; value = [ordered]@{ id = "@items('Each_mail')?['id']"; subject = "@string(outputs('Fields')?['heading'])"; html = "@outputs('Email_html')" } } }
$actions = [ordered]@{
    Init_parsed = [ordered]@{ type = 'InitializeVariable'; runAfter = @{}; inputs = @{ variables = @(@{ name = 'parsed'; type = 'array'; value = @() }) } }
    Init_mails  = [ordered]@{ type = 'InitializeVariable'; runAfter = (After 'Init_parsed'); inputs = @{ variables = @(@{ name = 'mails'; type = 'array'; value = @() }) } }
    Each_case   = [ordered]@{ type = 'Foreach'; foreach = "@$(JsonLit $parseIn)"; runAfter = (After 'Init_mails'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $parseLoop }
    Each_mail   = [ordered]@{ type = 'Foreach'; foreach = "@$(JsonLit $mailIn)"; runAfter = (After 'Each_case'); runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }; actions = $mailLoop }
    All         = [ordered]@{ type = 'Compose'; runAfter = (After 'Each_mail'); inputs = [ordered]@{ parsed = "@variables('parsed')"; mails = "@variables('mails')" } }
}
$definition = [ordered]@{ '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'; contentVersion = '1.0.0.0'
    parameters = [ordered]@{ '$connections' = @{ defaultValue = @{}; type = 'Object' }; '$authentication' = @{ defaultValue = @{}; type = 'SecureObject' } }
    triggers = @{ Recurrence = [ordered]@{ type = 'Recurrence'; recurrence = [ordered]@{ frequency = 'Month'; interval = 12 } } }
    actions = $actions }
$clientdata = [ordered]@{ properties = [ordered]@{ connectionReferences = @{}; definition = $definition; templateName = '' }; schemaVersion = '1.0.0.0' } | ConvertTo-Json -Depth 80 -Compress

# ---------- save, run, read, delete ----------
$name = '[TEST] Change Radar destination parity'
foreach ($old in @((Invoke-Dv -Path "workflows?`$select=workflowid&`$filter=name eq '$name' and category eq 5").value)) {
    Invoke-Dv -Method PATCH -Path "workflows($($old.workflowid))" -Body @{ statecode = 0; statuscode = 1 } | Out-Null
    Invoke-Dv -Method DELETE -Path "workflows($($old.workflowid))" | Out-Null
}
$wfId = (Invoke-Dv -Method POST -Path 'workflows' -Body @{ name = $name; category = 5; type = 1; primaryentity = 'none'; clientdata = $clientdata; description = 'Temporary: Test-DestinationParity.ps1 (ADR 0011 addendum). Sends nothing; deleted after the check.' }).workflowid
try {
    Invoke-Dv -Method PATCH -Path "workflows($wfId)" -Body @{ statecode = 1; statuscode = 2 } | Out-Null
    $h = @{ Authorization = "Bearer $(Get-Token 'https://service.flow.microsoft.com/')" }
    $base = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows/$wfId"; $api = 'api-version=2016-11-01'
    Invoke-RestMethod -Method POST "$base/triggers/Recurrence/run?$api" -Headers $h | Out-Null
    $run = $null
    for ($i = 0; $i -lt 30 -and -not $run; $i++) { Start-Sleep 2; $run = @((Invoke-RestMethod "$base/runs?$api&`$top=1" -Headers $h).value) | Select-Object -First 1 }
    if (-not $run) { throw 'The run did not appear.' }
    do { Start-Sleep 3; $r = Invoke-RestMethod "$base/runs/$($run.name)?$api" -Headers $h } while ($r.properties.status -eq 'Running')
    if ($r.properties.status -ne 'Succeeded') {
        $failed = @((Invoke-RestMethod "$base/runs/$($run.name)/actions?$api" -Headers $h).value | Where-Object { $_.properties.status -eq 'Failed' } | ForEach-Object {
                $msg = "$($_.properties.PSObject.Properties['code']?.Value)"
                try {
                    $rep = @((Invoke-RestMethod "$base/runs/$($run.name)/actions/$($_.name)/repetitions?$api" -Headers $h).value | Where-Object { $_.properties.status -eq 'Failed' }) | Select-Object -First 1
                    if ($rep) { $msg = "[item $($rep.properties.repetitionIndexes[0].itemIndex)] $($rep.properties.error.message)" }
                } catch { }
                "$($_.name): $msg" })
        throw "The test flow run $($r.properties.status): $($failed -join '; ')"
    }
    $all = Invoke-RestMethod "$base/runs/$($run.name)/actions/All?$api" -Headers $h
    $o = Invoke-RestMethod $all.properties.outputsLink.uri
    $out = if ($o.PSObject.Properties['body']) { $o.body } else { $o }
} finally {
    if (-not $Keep) {
        Invoke-Dv -Method PATCH -Path "workflows($wfId)" -Body @{ statecode = 0; statuscode = 1 } | Out-Null
        Invoke-Dv -Method DELETE -Path "workflows($wfId)" | Out-Null
    }
}

# ---------- compare ----------
$problems = [Collections.Generic.List[string]]::new()
foreach ($c in $cases.parse) {
    $got = @(($out.parsed | Where-Object id -eq $c.id).dests | ForEach-Object {
            $x = $_; switch ($x.kind) { 'channel' { "channel:$($x.teamId)/$($x.channelId)" } 'invalid' { "invalid:$($x.entry) ($($x.reason))" } default { "$($x.kind):$($x.address)" } } })
    if (($got -join ' ; ') -cne (@($c.expected) -join ' ; ')) { $problems.Add("$($c.id): flow [$($got -join ' ; ')] / expected [$(@($c.expected) -join ' ; ')]") }
}
foreach ($c in $cases.email.cases) {
    $m = $out.mails | Where-Object id -eq $c.id
    $want = $c.expected.html.Replace('{appUrl}', [Net.WebUtility]::HtmlEncode($appUrl))
    if ($m.subject -cne $c.expected.subject) { $problems.Add("$($c.id) subject: flow '$($m.subject)'") }
    if ($m.html -cne $want) { $problems.Add("$($c.id) html: flow '$($m.html)'") }
}
"cases: $(@($cases.parse).Count) destination, $(@($cases.email.cases).Count) email; run $($run.name)"
if ($problems.Count) { "MISMATCHES ($($problems.Count)):"; $problems | ForEach-Object { "  $_" }; exit 1 }
'PARITY: the handlers'' destination steps and email HTML agree with the engine on every case.'
