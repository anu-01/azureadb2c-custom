<#
.SYNOPSIS
    Deploys Azure AD B2C custom policies with SSO Takeover support.

.DESCRIPTION
    Uploads all custom policy files to your Azure AD B2C tenant in the correct
    dependency order. Requires the Microsoft.Graph PowerShell module.

.PARAMETER TenantId
    Your Azure AD B2C tenant name (e.g., "contosob2c.onmicrosoft.com")

.PARAMETER IdentityExperienceFrameworkAppId
    The Application (client) ID of the IdentityExperienceFramework app registration.

.PARAMETER ProxyIdentityExperienceFrameworkAppId
    The Application (client) ID of the ProxyIdentityExperienceFramework app registration.

.PARAMETER FacebookClientId
    Your Facebook app's client ID for OAuth integration.

.PARAMETER FacebookSecret
    Your Facebook app's client secret (will be stored as a B2C policy key).

.PARAMETER ExtensionsAppObjectId
    The Object ID of the b2c-extensions-app (from App registrations).
    Required for extension_ssoMigrated attribute storage.

.PARAMETER ExtensionsAppClientId
    The Application (client) ID of the b2c-extensions-app.
    Required for extension_ssoMigrated attribute storage.

.EXAMPLE
    .\Deploy-Policies.ps1 `
        -TenantId "contosob2c.onmicrosoft.com" `
        -IdentityExperienceFrameworkAppId "00000000-0000-0000-0000-000000000000" `
        -ProxyIdentityExperienceFrameworkAppId "00000000-0000-0000-0000-000000000000" `
        -FacebookClientId "your-facebook-app-id" `
        -FacebookSecret "your-facebook-app-secret" `
        -ExtensionsAppObjectId "00000000-0000-0000-0000-000000000000" `
        -ExtensionsAppClientId "00000000-0000-0000-0000-000000000000"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$IdentityExperienceFrameworkAppId,

    [Parameter(Mandatory = $true)]
    [string]$ProxyIdentityExperienceFrameworkAppId,

    [Parameter(Mandatory = $true)]
    [string]$FacebookClientId,

    [Parameter(Mandatory = $false)]
    [string]$FacebookSecret,

    [Parameter(Mandatory = $true)]
    [string]$ExtensionsAppObjectId,

    [Parameter(Mandatory = $true)]
    [string]$ExtensionsAppClientId
)

$ErrorActionPreference = "Stop"

# ============================================================
# Step 1: Validate prerequisites
# ============================================================
Write-Host "`n=== Azure AD B2C Custom Policy Deployment (SSO Takeover) ===" -ForegroundColor Cyan
Write-Host "Tenant: $TenantId`n"

# Check for Microsoft.Graph module
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.SignIns)) {
    Write-Host "Installing Microsoft.Graph module..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# ============================================================
# Step 2: Connect to Microsoft Graph
# ============================================================
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
Connect-MgGraph -TenantId $TenantId -Scopes "Policy.ReadWrite.TrustFramework, TrustFrameworkKeySet.ReadWrite.All" -NoWelcome
Write-Host "Connected successfully.`n" -ForegroundColor Green

# ============================================================
# Step 3: Create Policy Keys (if they don't exist)
# ============================================================
Write-Host "Checking policy keys..." -ForegroundColor Yellow

function Ensure-PolicyKey {
    param(
        [string]$KeySetId,
        [string]$KeyType,
        [string]$KeyUse,
        [string]$Secret
    )
    
    try {
        $existing = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/trustFramework/keySets/$KeySetId"
        Write-Host "  Key '$KeySetId' already exists." -ForegroundColor Gray
    }
    catch {
        Write-Host "  Creating key '$KeySetId'..." -ForegroundColor Yellow
        
        # Create the keyset
        $body = @{ id = $KeySetId } | ConvertTo-Json
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/trustFramework/keySets" -Body $body -ContentType "application/json"
        
        if ($Secret) {
            # Upload a secret
            $secretBody = @{
                use = $KeyUse
                k   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Secret))
            } | ConvertTo-Json
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/trustFramework/keySets/$KeySetId/uploadSecret" -Body $secretBody -ContentType "application/json"
        }
        else {
            # Generate a key
            $genBody = @{
                use = $KeyUse
                kty = $KeyType
            } | ConvertTo-Json
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/trustFramework/keySets/$KeySetId/generateKey" -Body $genBody -ContentType "application/json"
        }
        
        Write-Host "  Key '$KeySetId' created successfully." -ForegroundColor Green
    }
}

Ensure-PolicyKey -KeySetId "B2C_1A_TokenSigningKeyContainer" -KeyType "RSA" -KeyUse "sig"
Ensure-PolicyKey -KeySetId "B2C_1A_TokenEncryptionKeyContainer" -KeyType "RSA" -KeyUse "enc"

if ($FacebookSecret) {
    Ensure-PolicyKey -KeySetId "B2C_1A_FacebookSecret" -KeyType "oct" -KeyUse "sig" -Secret $FacebookSecret
}

Write-Host "Policy keys ready.`n" -ForegroundColor Green

# ============================================================
# Step 4: Prepare policy files with tenant-specific values
# ============================================================
Write-Host "Preparing policy files..." -ForegroundColor Yellow

$scriptDir = $PSScriptRoot
$tempDir = Join-Path $env:TEMP "b2c-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# Policy files in upload order (dependency chain)
$policyFiles = @(
    "TrustFrameworkBase.xml",
    "TrustFrameworkLocalization.xml",
    "TrustFrameworkExtensions.xml",
    "SignUpOrSignin.xml",
    "PasswordReset.xml",
    "ProfileEdit.xml"
)

foreach ($file in $policyFiles) {
    $sourcePath = Join-Path $scriptDir $file
    if (-not (Test-Path $sourcePath)) {
        Write-Warning "  File not found: $file - skipping"
        continue
    }
    
    $content = Get-Content $sourcePath -Raw
    
    # Replace placeholder values
    $content = $content -replace "yourtenant\.onmicrosoft\.com", $TenantId
    $content = $content -replace "ProxyIdentityExperienceFrameworkAppId", $ProxyIdentityExperienceFrameworkAppId
    $content = $content -replace "IdentityExperienceFrameworkAppId", $IdentityExperienceFrameworkAppId
    $content = $content -replace "facebook_clientid", $FacebookClientId
    $content = $content -replace "INSERT_EXTENSIONS_APP_OBJECT_ID", $ExtensionsAppObjectId
    $content = $content -replace "INSERT_EXTENSIONS_APP_CLIENT_ID", $ExtensionsAppClientId
    
    $destPath = Join-Path $tempDir $file
    Set-Content -Path $destPath -Value $content -Encoding UTF8
    Write-Host "  Prepared: $file" -ForegroundColor Gray
}

Write-Host "Files prepared in: $tempDir`n" -ForegroundColor Green

# ============================================================
# Step 5: Upload policies in order
# ============================================================
Write-Host "Uploading policies to Azure AD B2C..." -ForegroundColor Yellow

$policyIdMap = @{
    "TrustFrameworkBase.xml"         = "B2C_1A_TrustFrameworkBase"
    "TrustFrameworkLocalization.xml" = "B2C_1A_TrustFrameworkLocalization"
    "TrustFrameworkExtensions.xml"   = "B2C_1A_TrustFrameworkExtensions"
    "SignUpOrSignin.xml"             = "B2C_1A_signup_signin"
    "PasswordReset.xml"             = "B2C_1A_PasswordReset"
    "ProfileEdit.xml"               = "B2C_1A_ProfileEdit"
}

foreach ($file in $policyFiles) {
    $filePath = Join-Path $tempDir $file
    if (-not (Test-Path $filePath)) {
        continue
    }
    
    $policyId = $policyIdMap[$file]
    Write-Host "  Uploading: $policyId ($file)..." -ForegroundColor Yellow -NoNewline
    
    try {
        $content = Get-Content $filePath -Raw -Encoding UTF8
        $uri = "https://graph.microsoft.com/beta/trustFramework/policies/$policyId/`$value"
        Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $content -ContentType "application/xml"
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
        
        # Try to extract more specific error from response
        if ($_.ErrorDetails) {
            Write-Host "    Details: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
        
        Write-Host "`n  Stopping deployment. Fix the error above and re-run." -ForegroundColor Red
        break
    }
}

# ============================================================
# Step 6: Cleanup and summary
# ============================================================
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host @"

Your policies are now deployed. Test the SSO takeover flow:

  1. Sign up with email + password at:
     https://$($TenantId.Split('.')[0]).b2clogin.com/$TenantId/B2C_1A_signup_signin/oauth2/v2.0/authorize?client_id=YOUR_APP_CLIENT_ID&response_type=id_token&redirect_uri=https://jwt.ms&scope=openid&nonce=defaultNonce

  2. Sign out, then sign in via Facebook with the SAME email.
     The SSO identity should be linked - check for "extension_ssoMigrated: true" in the token.

  3. Try signing in with email + password again.
     It should fail with "This account has been migrated to SSO."

  4. Try password reset with the same email.
     It should also be blocked for migrated accounts.

"@ -ForegroundColor White

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
