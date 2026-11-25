#Requires -Version 7.0
<#
.SYNOPSIS
    Injects labelled test signals for the phase 5 "done when" test (ADR 0011). Dev environment only; plans by default.
.DESCRIPTION
    Writes what a collector would write: a crdr_signal row and its crdr_signalversion row, so the normal pipeline
    (signal events -> dispatcher -> handlers) runs on it. Every test row has an external id starting TEST- and a
    title starting [TEST]. Remove them with Remove-TestSignals.ps1.
      -Scenario incident  TEST-INC-0001, a service health incident (expect signal.new, incident.opened -> card)
      -Scenario resolve   marks TEST-INC-0001 resolved (expect signal.changed, incident.resolved -> card)
    -Scenario resolvedincident  TEST-INC-0002, an incident first seen already restored (expect signal.new only, no card;
                        install test: the first night collects the last month's incidents, most of them over)
      -Scenario mc        TEST-MC-0001, a Message Center post about Copilot scheduled prompts, action required in 14
                          days, with a manual accepted fingerprint (capability scheduled_prompt + product Power
                          Automate) so it matches deterministically without the fingerprint prompt. Then run the
                          match, assess and deadline flows (expect exposure.found, assessment.rated -> card if
                          High or Critical, deadline.approaching -> card).
      -Scenario watch     ADR 0015 done-when: a test watch topic '[TEST] Zephyrpilot in the UK' (made-up word, so no real
                          topic or signal is involved), TEST-WATCH-0001 that matches it (expect watch.matched -> card) and
                          TEST-WATCH-0002, a near miss about 'Windows Zephyrpilot' in the UK (expect nothing).
      -Scenario watchupdate  moves TEST-WATCH-0001's key date (expect watch.updated -> card, "changed: key date").
      -Scenario promptmodel  ADR 0017 done-when: TEST-PRM-0001, a prompt model retirement for -PromptModel (default
                          gpt-6-sol, the model of Change Radar's own prompts) with the rule fingerprints the Learn tables
                          collector writes: group A (model, resource type prompt) and group B (model, capability
                          ai_prompt). Then run the match flow (expect exposures for the prompts on that model and the
                          flows that call them; signal.new and exposure.found go to the digest only, nothing is posted).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(Mandatory)][ValidateSet('incident', 'resolve', 'resolvedincident', 'mc', 'watch', 'watchupdate', 'promptmodel')][string]$Scenario,
    [string]$PromptModel = 'gpt-6-sol',
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SchemaPath = (Join-Path $PSScriptRoot '..' '..' 'solutions' 'design' 'schema.json'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/'); $dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Invoke-Dv([string]$Path, [string]$Method = 'GET', $Body) {
    $h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0'; Prefer = 'return=representation' }
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = $h }
    if ($null -ne $Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6)); $p.ContentType = 'application/json; charset=utf-8' }
    Invoke-RestMethod @p
}
$org = Invoke-Dv "RetrieveCurrentOrganization(AccessType=Microsoft.Dynamics.CRM.EndpointAccessType'Default')"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
$schema = Get-Content -Raw $SchemaPath | ConvertFrom-Json -Depth 50
$base = [int]"$($schema.publisher.optionValuePrefix)0000"
function Get-Opt([string]$choice, [string]$value) { $i = [array]::IndexOf(@($schema.choices.$choice), $value); if ($i -lt 0) { throw "'$value' is not a $choice choice." }; $base + $i }
$now = [datetime]::UtcNow
function Get-Signal([string]$ext) { @((Invoke-Dv "crdr_signals?`$select=crdr_signalid,crdr_horizon&`$filter=crdr_externalid eq '$ext'").value) | Select-Object -First 1 }
$testWatch = '[TEST] Zephyrpilot in the UK'
function New-TestMc([string]$ext, [string]$title, [string]$body) {
    Invoke-Dv 'crdr_signals' 'POST' @{ crdr_title = $title; crdr_source = (Get-Opt 'signalsource' 'graph_mc'); crdr_externalid = $ext
        crdr_summary = "<p>Test Message Center post injected by setup/dev/New-TestSignals.ps1 (ADR 0015). Not a real post.</p><p>$body</p>"
        crdr_products = 'Microsoft Copilot (Microsoft 365)'; crdr_horizon = (Get-Opt 'horizon' 'future'); crdr_keydate = $now.Date.AddDays(60).ToString('yyyy-MM-dd')
        crdr_datelabel = 'Plan for change'; crdr_actionrequired = $false; crdr_url = 'https://admin.microsoft.com/#/MessageCenter'
        crdr_firstseen = $now.ToString('o'); crdr_lastchanged = $now.ToString('o') }
}
function New-Version([string]$signalId, [string]$ext, [string]$changed) {
    Invoke-Dv 'crdr_signalversions' 'POST' @{ crdr_name = "$ext $($now.ToString('yyyy-MM-ddTHH:mm:ssZ'))"; 'crdr_signal@odata.bind' = "/crdr_signals($signalId)"; crdr_snapshotjson = '{"test":true}'; crdr_capturedon = $now.ToString('o'); crdr_changedfields = $changed } | Out-Null
}

$plan = switch ($Scenario) {
    'incident' {
        if (Get-Signal 'TEST-INC-0001') { throw 'TEST-INC-0001 already exists. Run Remove-TestSignals.ps1 first, or -Scenario resolve.' }
        "Create signal TEST-INC-0001 (service health, Now) and its 'created' version row."
    }
    'resolvedincident' {
        if (Get-Signal 'TEST-INC-0002') { throw 'TEST-INC-0002 already exists. Run Remove-TestSignals.ps1 first.' }
        "Create signal TEST-INC-0002 (service health, already restored: Future) and its 'created' version row."
    }
    'resolve' {
        if (-not (Get-Signal 'TEST-INC-0001')) { throw 'TEST-INC-0001 does not exist. Run -Scenario incident first.' }
        "Update TEST-INC-0001 to resolved (horizon Future, label serviceRestored) and write its change version row."
    }
    'mc' {
        if (Get-Signal 'TEST-MC-0001') { throw 'TEST-MC-0001 already exists. Run Remove-TestSignals.ps1 first.' }
        "Create signal TEST-MC-0001 (Message Center, action required by $($now.Date.AddDays(14).ToString('yyyy-MM-dd'))), its 'created' version row and 2 manual accepted fingerprints (group M1)."
    }
    'watch' {
        if (Get-Signal 'TEST-WATCH-0001') { throw 'TEST-WATCH-0001 already exists. Run Remove-TestSignals.ps1 first, or -Scenario watchupdate.' }
        "Create the test watch topic '$testWatch' (if missing), TEST-WATCH-0001 (matches it) and TEST-WATCH-0002 (near miss), each with a 'created' version row."
    }
    'watchupdate' {
        if (-not (Get-Signal 'TEST-WATCH-0001')) { throw 'TEST-WATCH-0001 does not exist. Run -Scenario watch first.' }
        "Move TEST-WATCH-0001's key date and write its change version row."
    }
    'promptmodel' {
        if (Get-Signal 'TEST-PRM-0001') { throw 'TEST-PRM-0001 already exists. Run Remove-TestSignals.ps1 first.' }
        "Create signal TEST-PRM-0001 (prompt model $PromptModel retiring in 30 days), its 'created' version row and 4 rule fingerprints (A: model, resource_type prompt; B: model, capability ai_prompt)."
    }
}
"PLAN ($ExpectedEnvironmentName): $plan"
if (-not $Apply) { 'Plan only. Nothing was changed. Re-run with -Apply.'; return }

switch ($Scenario) {
    'incident' {
        $s = Invoke-Dv 'crdr_signals' 'POST' @{ crdr_title = "[TEST] Users can't open model-driven apps"; crdr_source = (Get-Opt 'signalsource' 'graph_health'); crdr_externalid = 'TEST-INC-0001'
            crdr_summary = 'Test incident injected by setup/dev/New-TestSignals.ps1 (ADR 0011). Not a real incident.'; crdr_products = 'Power Apps'; crdr_horizon = (Get-Opt 'horizon' 'now')
            crdr_keydate = $now.ToString('yyyy-MM-dd'); crdr_datelabel = 'Incident · serviceDegradation'; crdr_actionrequired = $false; crdr_url = 'https://admin.microsoft.com/#/servicehealth'
            crdr_firstseen = $now.ToString('o'); crdr_lastchanged = $now.ToString('o') }
        New-Version $s.crdr_signalid 'TEST-INC-0001' 'created'
        "Created TEST-INC-0001 ($($s.crdr_signalid))."
    }
    'resolvedincident' {
        $s = Invoke-Dv 'crdr_signals' 'POST' @{ crdr_title = '[TEST] Some users saw slow flow runs (restored)'; crdr_source = (Get-Opt 'signalsource' 'graph_health'); crdr_externalid = 'TEST-INC-0002'
            crdr_summary = 'Test incident injected by setup/dev/New-TestSignals.ps1, already restored when first seen. Not a real incident.'; crdr_products = 'Power Automate'; crdr_horizon = (Get-Opt 'horizon' 'future')
            crdr_keydate = $now.AddDays(-5).ToString('yyyy-MM-dd'); crdr_datelabel = 'Incident · serviceRestored'; crdr_actionrequired = $false; crdr_url = 'https://admin.microsoft.com/#/servicehealth'
            crdr_firstseen = $now.ToString('o'); crdr_lastchanged = $now.ToString('o') }
        New-Version $s.crdr_signalid 'TEST-INC-0002' 'created'
        "Created TEST-INC-0002 ($($s.crdr_signalid))."
    }
    'resolve' {
        $s = Get-Signal 'TEST-INC-0001'
        Invoke-Dv "crdr_signals($($s.crdr_signalid))" 'PATCH' @{ crdr_horizon = (Get-Opt 'horizon' 'future'); crdr_datelabel = 'Incident · serviceRestored'; crdr_lastchanged = $now.ToString('o') } | Out-Null
        New-Version $s.crdr_signalid 'TEST-INC-0001' 'horizon; date label; last modified'
        'Resolved TEST-INC-0001.'
    }
    'mc' {
        $s = Invoke-Dv 'crdr_signals' 'POST' @{ crdr_title = '[TEST] Scheduled prompts in Microsoft 365 Copilot are moving to native Copilot scheduling'; crdr_source = (Get-Opt 'signalsource' 'graph_mc'); crdr_externalid = 'TEST-MC-0001'
            crdr_summary = '<p>Test Message Center post injected by setup/dev/New-TestSignals.ps1 (ADR 0011). Not a real post.</p><p>Scheduled prompts created in Microsoft 365 Copilot currently run as Power Automate flows. They are moving to native Copilot scheduling and the Tasks view. Flows created by scheduled prompts stop running after the key date; users must recreate schedules that do not migrate.</p>'
            crdr_products = 'Microsoft Copilot (Microsoft 365)'; crdr_horizon = (Get-Opt 'horizon' 'now'); crdr_keydate = $now.Date.AddDays(14).ToString('yyyy-MM-dd')   # crdr_keydate is date-only
            crdr_datelabel = 'Plan for change · action required'; crdr_actionrequired = $true; crdr_url = 'https://admin.microsoft.com/#/MessageCenter'
            crdr_firstseen = $now.ToString('o'); crdr_lastchanged = $now.ToString('o'); crdr_fingerprintedon = $now.ToString('o') }
        foreach ($f in @(@('capability', 'scheduled_prompt'), @('product', 'Power Automate'))) {
            Invoke-Dv 'crdr_signalfingerprints' 'POST' @{ crdr_name = "$($f[0]): $($f[1])"; 'crdr_signal@odata.bind' = "/crdr_signals($($s.crdr_signalid))"; crdr_group = 'M1'; crdr_facet = (Get-Opt 'facet' $f[0]); crdr_value = $f[1]
                crdr_extractedby = (Get-Opt 'extractedby' 'manual'); crdr_confidence = 1; crdr_status = (Get-Opt 'fingerprintstatus' 'accepted'); crdr_reason = 'Test fingerprint (New-TestSignals.ps1).' } | Out-Null
        }
        New-Version $s.crdr_signalid 'TEST-MC-0001' 'created'
        "Created TEST-MC-0001 ($($s.crdr_signalid)) with a manual fingerprint. Next: run the match, assess and deadline flows."
    }
    'watch' {
        $set = (Invoke-Dv "EntityDefinitions(LogicalName='crdr_watch')?`$select=EntitySetName").EntitySetName
        if (-not @((Invoke-Dv "${set}?`$select=crdr_watchid&`$filter=crdr_name eq '$($testWatch.Replace("'", "''"))'").value).Count) {
            Invoke-Dv $set 'POST' @{ crdr_name = $testWatch; crdr_anyof = 'Zephyrpilot'; crdr_alsooneof = 'UK; United Kingdom'; crdr_ignorephrases = 'Windows Zephyrpilot'; crdr_active = $true
                crdr_description = 'Test topic for the ADR 0015 done-when (New-TestSignals.ps1). Removed by Remove-TestSignals.ps1.' } | Out-Null
        }
        $a = New-TestMc 'TEST-WATCH-0001' '[TEST] Copilot Zephyrpilot rolling out to tenants in the UK' 'Zephyrpilot reaches general availability for tenants in the UK and Europe.'
        New-Version $a.crdr_signalid 'TEST-WATCH-0001' 'created'
        $b = New-TestMc 'TEST-WATCH-0002' '[TEST] Windows Zephyrpilot device preparation in the UK' 'Windows Zephyrpilot device preparation is now available for devices in the UK.'
        New-Version $b.crdr_signalid 'TEST-WATCH-0002' 'created'
        "Created '$testWatch', TEST-WATCH-0001 ($($a.crdr_signalid)) and TEST-WATCH-0002 ($($b.crdr_signalid)). Expect one watch.matched card, for TEST-WATCH-0001 only."
    }
    'promptmodel' {
        $s = Invoke-Dv 'crdr_signals' 'POST' @{ crdr_title = "[TEST] $PromptModel retires from prompts in Copilot Studio, Power Automate and Power Apps"; crdr_source = (Get-Opt 'signalsource' 'graph_mc'); crdr_externalid = 'TEST-PRM-0001'
            crdr_summary = "<p>Test signal injected by setup/dev/New-TestSignals.ps1 (ADR 0017). Not a real retirement.</p><p>Prompts on $PromptModel move to their tier's replacement automatically.</p>"
            crdr_products = 'Microsoft Copilot Studio; Power Automate; Power Apps'; crdr_horizon = (Get-Opt 'horizon' 'imminent'); crdr_keydate = $now.Date.AddDays(30).ToString('yyyy-MM-dd')
            crdr_datelabel = 'Retiring · replacement (test)'; crdr_actionrequired = $false; crdr_url = 'https://learn.microsoft.com/microsoft-copilot-studio/prompt-model-availability'
            crdr_firstseen = $now.ToString('o'); crdr_lastchanged = $now.ToString('o'); crdr_fingerprintedon = $now.ToString('o') }
        foreach ($f in @(@('A', 'model', $PromptModel), @('A', 'resource_type', 'prompt'), @('B', 'model', $PromptModel), @('B', 'capability', 'ai_prompt'))) {
            Invoke-Dv 'crdr_signalfingerprints' 'POST' @{ crdr_name = "$($f[1]): $($f[2])"; 'crdr_signal@odata.bind' = "/crdr_signals($($s.crdr_signalid))"; crdr_group = $f[0]; crdr_facet = (Get-Opt 'facet' $f[1]); crdr_value = $f[2]
                crdr_extractedby = (Get-Opt 'extractedby' 'rule'); crdr_confidence = 1; crdr_status = (Get-Opt 'fingerprintstatus' 'accepted'); crdr_reason = 'Test rule fingerprint (New-TestSignals.ps1, ADR 0017).' } | Out-Null
        }
        New-Version $s.crdr_signalid 'TEST-PRM-0001' 'created'
        "Created TEST-PRM-0001 ($($s.crdr_signalid)). Next: run the match flow."
    }
    'watchupdate' {
        $s = Get-Signal 'TEST-WATCH-0001'
        Invoke-Dv "crdr_signals($($s.crdr_signalid))" 'PATCH' @{ crdr_keydate = $now.Date.AddDays(90).ToString('yyyy-MM-dd'); crdr_lastchanged = $now.ToString('o') } | Out-Null
        New-Version $s.crdr_signalid 'TEST-WATCH-0001' 'key date; last modified'
        'Moved TEST-WATCH-0001 key date. Expect one watch.updated card ("changed: key date").'
    }
}
