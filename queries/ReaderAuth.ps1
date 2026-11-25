#Requires -Version 7.0
<#
.SYNOPSIS
    Dot-source this to get Get-CrdrReaderToken: an app-only token for crdr-reader, signed with the certificate
    held in Key Vault. The PFX is loaded in memory only (EphemeralKeySet) and never written to disk.
.DESCRIPTION
    Reads, as the signed-in user (Az.Accounts): the tenant (from the subscription), the app id (by display
    name) and the certificate (vault secret). Defaults match setup/New-ReaderIdentity.ps1.
.EXAMPLE
    . ./queries/ReaderAuth.ps1
    $token = Get-CrdrReaderToken -SubscriptionId <guid> -Scope 'https://graph.microsoft.com/.default'
#>
if (-not (Get-Variable -Name CrdrReader -Scope Script -ErrorAction SilentlyContinue)) { $script:CrdrReader = $null }

function ConvertTo-CrdrB64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function Get-CrdrReaderToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Scope,
        [string]$VaultName,
        [string]$AppName = 'crdr-reader',
        [string]$CertificateName = 'crdr-reader'
    )
    if (-not $script:CrdrReader) {
        Import-Module Az.Accounts -ErrorAction Stop
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount -UseDeviceAuthentication | Out-Null }
        $userToken = { param($r) ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $r -AsSecureString).Token -AsPlainText }
        if (-not $VaultName) {
            $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SubscriptionId))).ToLowerInvariant()
            $VaultName = "kv-crdr-dev-$($h.Substring(0, 4))"
        }
        $tenantId = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $(& $userToken 'https://management.azure.com/')" } -Uri "https://management.azure.com/subscriptions/$($SubscriptionId)?api-version=2022-12-01").tenantId
        $apps = @((Invoke-RestMethod -Headers @{ Authorization = "Bearer $(& $userToken 'https://graph.microsoft.com/')" } -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppName'&`$select=appId").value)
        if ($apps.Count -ne 1) { throw "Expected one app registration named '$AppName', found $($apps.Count)." }
        $secret = Invoke-RestMethod -Headers @{ Authorization = "Bearer $(& $userToken 'https://vault.azure.net')" } -Uri "https://$VaultName.vault.azure.net/secrets/$($CertificateName)?api-version=7.4"
        $pfx = [Convert]::FromBase64String($secret.value)
        $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        $cert = if ('System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]) {
            [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12($pfx, $null, $flags)
        } else { [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$null, $flags) }
        [Array]::Clear($pfx, 0, $pfx.Length)
        $script:CrdrReader = @{ TenantId = $tenantId; ClientId = $apps[0].appId; Cert = $cert; Tokens = @{} }
    }
    $r = $script:CrdrReader
    $cached = $r.Tokens[$Scope]
    if ($cached -and $cached.Expires -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $cached.Token }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $tokenUrl = "https://login.microsoftonline.com/$($r.TenantId)/oauth2/v2.0/token"
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-CrdrB64Url $r.Cert.GetCertHash()) } | ConvertTo-Json -Compress
    $claims = @{ aud = $tokenUrl; iss = $r.ClientId; sub = $r.ClientId; jti = [guid]::NewGuid().ToString(); nbf = $now; exp = $now + 600 } | ConvertTo-Json -Compress
    $unsigned = "$(ConvertTo-CrdrB64Url ([Text.Encoding]::UTF8.GetBytes($header))).$(ConvertTo-CrdrB64Url ([Text.Encoding]::UTF8.GetBytes($claims)))"
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($r.Cert)
    $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $resp = Invoke-RestMethod -Method POST -Uri $tokenUrl -ContentType 'application/x-www-form-urlencoded' -Body @{
        client_id = $r.ClientId; scope = $Scope; grant_type = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = "$unsigned.$(ConvertTo-CrdrB64Url $sig)"
    }
    $r.Tokens[$Scope] = @{ Token = $resp.access_token; Expires = [DateTimeOffset]::UtcNow.AddSeconds([int]$resp.expires_in) }
    $resp.access_token
}
