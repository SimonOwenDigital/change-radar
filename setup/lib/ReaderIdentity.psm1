#Requires -Version 7.0
<#
    Tokens as the Change Radar reader app (setup/New-ReaderIdentity.ps1), for local read-only queries.
    The signed-in Az.Accounts user reads the certificate from Key Vault; the PFX stays in memory (ephemeral key set).
#>
Set-StrictMode -Version Latest

function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function Get-DefaultVaultName([string]$SubscriptionId) {
    $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SubscriptionId))).ToLowerInvariant()
    "kv-crdr-dev-$($h.Substring(0, 4))"
}

function New-ReaderSession {
    <# Returns an object with TenantId, ClientId and a GetToken(scope) script method. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId, [string]$VaultName, [string]$AppName = 'crdr-reader', [string]$CertificateName = 'crdr-reader')
    Import-Module Az.Accounts -ErrorAction Stop
    if (-not $VaultName) { $VaultName = Get-DefaultVaultName $SubscriptionId }
    $user = { param($r) ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $r -AsSecureString).Token -AsPlainText }
    $tenantId = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $(& $user 'https://management.azure.com/')" } -Uri "https://management.azure.com/subscriptions/$($SubscriptionId)?api-version=2022-12-01").tenantId
    $apps = @((Invoke-RestMethod -Headers @{ Authorization = "Bearer $(& $user 'https://graph.microsoft.com/')" } -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppName'&`$select=appId").value)
    if ($apps.Count -ne 1) { throw "Expected one app registration named '$AppName', found $($apps.Count)." }
    $secret = Invoke-RestMethod -Headers @{ Authorization = "Bearer $(& $user 'https://vault.azure.net')" } -Uri "https://$VaultName.vault.azure.net/secrets/$($CertificateName)?api-version=7.4"
    $pfx = [Convert]::FromBase64String($secret.value); $secret = $null
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    $cert = if ('System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]) { [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12($pfx, $null, $flags) }
            else { [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$null, $flags) }
    [Array]::Clear($pfx, 0, $pfx.Length)
    $s = [pscustomobject]@{ TenantId = $tenantId; ClientId = $apps[0].appId; Certificate = $cert }
    $s | Add-Member -MemberType ScriptMethod -Name GetToken -Value {
        param([string]$Scope)
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $tokenUrl = "https://login.microsoftonline.com/$($this.TenantId)/oauth2/v2.0/token"
        $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-B64Url $this.Certificate.GetCertHash()) } | ConvertTo-Json -Compress
        $claims = @{ aud = $tokenUrl; iss = $this.ClientId; sub = $this.ClientId; jti = [guid]::NewGuid().ToString(); nbf = $now; exp = $now + 600 } | ConvertTo-Json -Compress
        $unsigned = "$(ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($header))).$(ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($claims)))"
        $sig = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($this.Certificate).SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $body = @{ client_id = $this.ClientId; scope = $Scope; grant_type = 'client_credentials'
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = "$unsigned.$(ConvertTo-B64Url $sig)" }
        (Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
    }
    $s
}

Export-ModuleMember -Function New-ReaderSession, Get-DefaultVaultName
