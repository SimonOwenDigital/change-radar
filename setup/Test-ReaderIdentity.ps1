#Requires -Version 7.0
<#
.SYNOPSIS
    Proves the Change Radar reader identity works and is read-only. Changes nothing.

.DESCRIPTION
    1. As the signed-in user (Az.Accounts), reads the reader certificate from Key Vault. The PFX is held
       in memory only (ephemeral key set); nothing is written to disk or to the certificate store.
    2. As the app (client credentials, certificate assertion), gets tokens for Graph and Dataverse.
    3. Positive checks: the Graph token carries exactly the expected roles; reads one Message Center post
       and the service health overview; calls WhoAmI and reads a crdr_ table in the environment.
    4. Negative checks: Graph /users is refused (403); the app user holds no create, write, delete,
       append or assign privilege on any table.

    Exits 1 if any check fails.

.EXAMPLE
    ./Test-ReaderIdentity.ps1 -SubscriptionId <guid> -EnvironmentUrl https://<org>.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$VaultName,                       # default as in New-ReaderIdentity.ps1
    [string]$AppName = 'crdr-reader',
    [string]$CertificateName = 'crdr-reader',
    [string[]]$ExpectedGraphRoles = @('ServiceHealth.Read.All', 'ServiceMessage.Read.All')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
if (-not $VaultName) {
    $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SubscriptionId))).ToLowerInvariant()
    $VaultName = "kv-crdr-dev-$($h.Substring(0, 4))"
}
$graph = 'https://graph.microsoft.com/v1.0'
$dv = "$EnvironmentUrl/api/data/v9.2"

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Check, [bool]$Pass, [string]$Detail) { $results.Add([pscustomobject]@{ Result = ($Pass ? 'PASS' : 'FAIL'); Check = $Check; Detail = $Detail }) }
function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function Get-JwtClaims([string]$jwt) {
    $p = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/'); $p += '=' * ((4 - $p.Length % 4) % 4)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}
function Get-Status($err) { $r = $err.Exception.Response; if ($r) { [int]$r.StatusCode } else { 0 } }

# ---------- 1. As the signed-in user: tenant, app id, certificate ----------
Import-Module Az.Accounts -ErrorAction Stop
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount | Out-Null }
function Get-UserToken([string]$Resource) { ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $Resource -AsSecureString).Token -AsPlainText }
$armH = @{ Authorization = "Bearer $(Get-UserToken 'https://management.azure.com/')" }
$tenantId = (Invoke-RestMethod -Headers $armH -Uri "https://management.azure.com/subscriptions/$($SubscriptionId)?api-version=2022-12-01").tenantId
$gH = @{ Authorization = "Bearer $(Get-UserToken 'https://graph.microsoft.com/')" }
$apps = @((Invoke-RestMethod -Headers $gH -Uri "$graph/applications?`$filter=displayName eq '$AppName'&`$select=appId,displayName").value)
if ($apps.Count -ne 1) { throw "Expected one app registration named '$AppName', found $($apps.Count)." }
$clientId = $apps[0].appId

$kvH = @{ Authorization = "Bearer $(Get-UserToken 'https://vault.azure.net')" }
$secret = Invoke-RestMethod -Headers $kvH -Uri "https://$VaultName.vault.azure.net/secrets/$($CertificateName)?api-version=7.4"
$pfx = [Convert]::FromBase64String($secret.value)
$flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
$cert = if ('System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]) {
    [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12($pfx, $null, $flags)
} else { [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$null, $flags) }
[Array]::Clear($pfx, 0, $pfx.Length); $secret = $null
Add-Result 'Certificate loaded from Key Vault (memory only)' $cert.HasPrivateKey "$($cert.Subject), expires $($cert.NotAfter.ToString('yyyy-MM-dd'))"

# ---------- 2. As the app: client credentials with a certificate assertion ----------
function Get-AppToken([string]$Scope) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-B64Url $cert.GetCertHash()) } | ConvertTo-Json -Compress
    $claims = @{ aud = $tokenUrl; iss = $clientId; sub = $clientId; jti = [guid]::NewGuid().ToString(); nbf = $now; exp = $now + 600 } | ConvertTo-Json -Compress
    $unsigned = "$(ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($header))).$(ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($claims)))"
    $sig = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert).SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $body = @{
        client_id = $clientId; scope = $Scope; grant_type = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion = "$unsigned.$(ConvertTo-B64Url $sig)"
    }
    (Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
}
$appGraph = Get-AppToken 'https://graph.microsoft.com/.default'
$roles = @((Get-JwtClaims $appGraph).PSObject.Properties['roles'] ? (Get-JwtClaims $appGraph).roles : @()) | Sort-Object
$expected = $ExpectedGraphRoles | Sort-Object
Add-Result 'Graph token as app, roles exactly as expected' (@(Compare-Object @($roles) @($expected)).Count -eq 0) ($roles -join ', ')
$agH = @{ Authorization = "Bearer $appGraph" }

# ---------- 3. Positive reads ----------
try {
    $m = @((Invoke-RestMethod -Headers $agH -Uri "$graph/admin/serviceAnnouncement/messages?`$top=1&`$select=id,title,lastModifiedDateTime").value)
    Add-Result 'Graph: read Message Center' $true ($m.Count ? "$($m[0].id): $($m[0].title)" : 'no messages returned')
} catch { Add-Result 'Graph: read Message Center' $false "HTTP $(Get-Status $_)" }
try {
    $ho = @((Invoke-RestMethod -Headers $agH -Uri "$graph/admin/serviceAnnouncement/healthOverviews?`$select=service,status").value)
    $pp = @($ho | Where-Object service -match 'Power|Dynamics|Copilot' | ForEach-Object { "$($_.service)=$($_.status)" })
    Add-Result 'Graph: read service health' ($ho.Count -gt 0) "$($ho.Count) services; $($pp -join '; ')"
} catch { Add-Result 'Graph: read service health' $false "HTTP $(Get-Status $_)" }

$appDv = Get-AppToken "$EnvironmentUrl/.default"
$adH = @{ Authorization = "Bearer $appDv"; Accept = 'application/json' }
$who = $null
try {
    # The role can't read systemuser (by design), so identity comes from the token, not the user row.
    $who = Invoke-RestMethod -Headers $adH -Uri "$dv/WhoAmI"
    $appid = (Get-JwtClaims $appDv).appid
    Add-Result 'Dataverse: WhoAmI as app' ($appid -eq $clientId -and $who.UserId) "token appid matches $AppName; UserId returned"
} catch { Add-Result 'Dataverse: WhoAmI as app' $false "HTTP $(Get-Status $_)" }
try {
    $null = Invoke-RestMethod -Headers $adH -Uri "$dv/crdr_configs?`$top=1&`$select=crdr_configid"
    Add-Result 'Dataverse: read crdr_config' $true 'query allowed'
} catch { Add-Result 'Dataverse: read crdr_config' $false "HTTP $(Get-Status $_)" }
# Component detail (ADR 0008). A count of 0 still passes: the read was allowed.
$componentTables = [ordered]@{ solutions = 'solutionid'; solutioncomponents = 'solutioncomponentid'; bots = 'botid'; botcomponents = 'botcomponentid'
    workflows = 'workflowid'; connectionreferences = 'connectionreferenceid'; customcontrols = 'customcontrolid'; canvasapps = 'canvasappid'; publishers = 'publisherid'
    msdyn_aimodels = 'msdyn_aimodelid'; msdyn_aiconfigurations = 'msdyn_aiconfigurationid' }  # prompts and their models (ADR 0013)
foreach ($t in $componentTables.GetEnumerator()) {
    try {
        $n = @((Invoke-RestMethod -Headers $adH -Uri "$dv/$($t.Key)?`$top=50&`$select=$($t.Value)").value).Count
        Add-Result "Dataverse: read $($t.Key)" $true "query allowed ($n row(s) in first page)"
    } catch { Add-Result "Dataverse: read $($t.Key)" $false "HTTP $(Get-Status $_)" }
}

# ---------- 4. Negative checks ----------
try {
    $null = Invoke-RestMethod -Headers $agH -Uri "$graph/users?`$top=1&`$select=id"
    Add-Result 'Graph: /users refused' $false 'read was allowed; the app has more than it should'
} catch { $s = Get-Status $_; Add-Result 'Graph: /users refused' ($s -eq 403) "HTTP $s" }
if ($who) {
    try {
        $priv = @((Invoke-RestMethod -Headers $adH -Uri "$dv/systemusers($($who.UserId))/Microsoft.Dynamics.CRM.RetrieveUserPrivileges()").RolePrivileges)
        $names = @{}
        foreach ($chunk in ($priv.PrivilegeId | Select-Object -Unique | ForEach-Object -Begin { $b = @() } -Process { $b += $_; if ($b.Count -eq 50) { , $b; $b = @() } } -End { if ($b) { , $b } })) {
            $f = ($chunk | ForEach-Object { "privilegeid eq $_" }) -join ' or '
            (Invoke-RestMethod -Headers $adH -Uri "$dv/privileges?`$select=name&`$filter=$f").value | ForEach-Object { $names[$_.name] = 1 }
        }
        # Dataverse adds these to every new security role (observed 2026-11-19, see docs/decisions/verified-facts.md).
        $platformDefaults = 'prvCreateSharePointData', 'prvWriteSharePointData'
        $risky = @($names.Keys | Where-Object { $_ -match '^prv(Create|Write|Delete|Append|AppendTo|Assign|Share)' -and $_ -notin $platformDefaults } | Sort-Object)
        $crdrRead = @($names.Keys | Where-Object { $_ -like 'prvReadcrdr_*' }).Count
        $detail = $risky.Count ? ($risky -join ', ') : "$($names.Count) privileges, $crdrRead prvReadcrdr_*; platform defaults allowed: $($platformDefaults -join ', ')"
        Add-Result 'Dataverse: no create/write/delete/append/assign/share privileges' ($risky.Count -eq 0) $detail
    } catch { Add-Result 'Dataverse: privilege check' $false "HTTP $(Get-Status $_)" }
}
$cert.Dispose()

$results | Format-Table -AutoSize -Wrap
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host ("{0} check(s), {1} failed." -f $results.Count, $failed)
if ($failed) { exit 1 }
