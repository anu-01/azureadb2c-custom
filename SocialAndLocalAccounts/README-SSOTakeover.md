# SSO Takeover for Azure AD B2C Custom Policies

## Overview

This solution implements **automatic SSO takeover** of existing local accounts in Azure AD B2C. When a user who signed up with email+password later signs in via an SSO provider (e.g., Facebook) using the same email, the SSO identity is **linked to the existing account** and local login is **logically blocked** via the `extension_ssoMigrated` flag.

### What happens during takeover

| Step | Action | Result |
|------|--------|--------|
| 1 | User signs up with email + password | Local account created |
| 2 | User signs in via Facebook (same email) | SSO identity linked to existing account |
| 3 | `extension_ssoMigrated` set to `true` | Persisted in directory as extension attribute |
| 4 | Token includes `extension_ssoMigrated: true` | App is notified of the migration |

### Post-takeover behavior

| Action | Result |
|--------|--------|
| Sign in via Facebook | ✅ Works (linked to existing account) |
| Sign in with email+password | ❌ Blocked ("This account has been migrated to SSO") |
| Password reset | ❌ Blocked ("Password reset is not available") |
| Switch back to password | ❌ Not possible (flag is permanent) |
| Duplicate accounts | ❌ None (same objectId preserved) |

---

## Prerequisites

1. **Azure AD B2C tenant** ([Create one](https://learn.microsoft.com/azure/active-directory-b2c/tutorial-create-tenant))

2. **IdentityExperienceFramework app registration**
   - Type: Web app
   - Redirect URI: `https://your-tenant-name.b2clogin.com/your-tenant-name.onmicrosoft.com`
   - API permissions: `openid`, `offline_access`
   - Expose an API with scope `user_impersonation`

3. **ProxyIdentityExperienceFramework app registration**
   - Type: Native/public client
   - Redirect URI: `myapp://auth`
   - API permissions: Grant access to IdentityExperienceFramework's `user_impersonation` scope
   - Enable implicit grant: ID tokens

4. **Facebook app** ([Setup guide](https://learn.microsoft.com/azure/active-directory-b2c/identity-provider-facebook))
   - Create at [developers.facebook.com](https://developers.facebook.com)
   - Note the App ID and App Secret
   - Add `https://your-tenant-name.b2clogin.com/your-tenant-name.onmicrosoft.com/oauth2/authresp` as a valid OAuth redirect URI

5. **b2c-extensions-app** (required for `extension_ssoMigrated` attribute)
   - This app is **auto-created** in your B2C tenant under **App registrations > All applications**
   - Search for `b2c-extensions-app. Do not modify. Used by AADB2C for storing user data.`
   - Note the **Application (client) ID** and **Object ID**

6. **B2C Policy keys** (the deployment script creates these automatically):
   - `B2C_1A_TokenSigningKeyContainer` (RSA, sig)
   - `B2C_1A_TokenEncryptionKeyContainer` (RSA, enc)
   - `B2C_1A_FacebookSecret` (secret)

---

## Configuration

Before deploying, replace these placeholders across all policy files:

| Placeholder | Replace with | Example |
|---|---|---|
| `yourtenant.onmicrosoft.com` | Your B2C tenant name | `contosob2c.onmicrosoft.com` |
| `ProxyIdentityExperienceFrameworkAppId` | Proxy IEF app client ID | `00000000-0000-0000-0000-000000000001` |
| `IdentityExperienceFrameworkAppId` | IEF app client ID | `00000000-0000-0000-0000-000000000002` |
| `facebook_clientid` | Facebook app ID | `123456789012345` |
| `INSERT_EXTENSIONS_APP_OBJECT_ID` | b2c-extensions-app Object ID | `00000000-0000-0000-0000-000000000003` |
| `INSERT_EXTENSIONS_APP_CLIENT_ID` | b2c-extensions-app Client ID | `00000000-0000-0000-0000-000000000004` |

> **Tip**: The `Deploy-Policies.ps1` script handles all replacements automatically.

---

## Deployment

### Option A: Automated (PowerShell)

```powershell
cd SocialAndLocalAccounts

.\Deploy-Policies.ps1 `
    -TenantId "contosob2c.onmicrosoft.com" `
    -IdentityExperienceFrameworkAppId "your-ief-app-id" `
    -ProxyIdentityExperienceFrameworkAppId "your-proxy-ief-app-id" `
    -FacebookClientId "your-facebook-app-id" `
    -FacebookSecret "your-facebook-app-secret" `
    -ExtensionsAppObjectId "your-extensions-app-object-id" `
    -ExtensionsAppClientId "your-extensions-app-client-id"
```

### Option B: Manual (Azure Portal)

Upload policies **in this exact order** via Azure Portal > Azure AD B2C > Identity Experience Framework > Custom policies:

1. `TrustFrameworkBase.xml`
2. `TrustFrameworkLocalization.xml`
3. `TrustFrameworkExtensions.xml`
4. `SignUpOrSignin.xml`
5. `PasswordReset.xml`
6. `ProfileEdit.xml`

> **Important**: Replace all placeholders in each file before uploading.

---

## Testing

### 1. Create a local account

1. Navigate to the `B2C_1A_signup_signin` policy
2. Click **Sign up now**
3. Create an account with an email address (e.g., `testuser@example.com`)
4. Complete the sign-up (set password, enter name)
5. Verify the token contains `identityProvider: local`

### 2. Trigger SSO takeover

1. Sign out
2. Navigate to the same `B2C_1A_signup_signin` policy
3. Click the **Facebook** button
4. Sign in with a Facebook account that uses the **same email** (`testuser@example.com`)
5. Verify the token:
   - `sub` = same objectId as step 1 (no duplicate!)
   - `identityProvider` = `facebook.com`
   - `extension_ssoMigrated` = `true`

### 3. Verify local login is blocked

1. Sign out
2. Navigate to the same policy
3. Enter the email and original password
4. Result: **"This account has been migrated to SSO. Please sign in with your identity provider instead."**

### 4. Verify password reset is blocked

1. Click **Forgot your password?**
2. Enter the same email and verify it
3. Result: **"This account has been migrated to SSO. Password reset is not available."**

### 5. Verify SSO still works

1. Click Facebook again → should sign in successfully
2. `extension_ssoMigrated` = `true` persists on every subsequent SSO sign-in

### Test URL

```
https://YOUR-TENANT.b2clogin.com/YOUR-TENANT.onmicrosoft.com/B2C_1A_signup_signin/oauth2/v2.0/authorize?client_id=YOUR_APP_CLIENT_ID&response_type=id_token&redirect_uri=https://jwt.ms&scope=openid&nonce=defaultNonce
```

Replace `YOUR-TENANT` and `YOUR_APP_CLIENT_ID` with your values. Use [jwt.ms](https://jwt.ms) to inspect the returned token.

---

## Architecture

### Policy hierarchy

```
TrustFrameworkBase.xml               ← Standard B2C base (unmodified)
  └─ TrustFrameworkLocalization.xml  ← Localization (unmodified)
       └─ TrustFrameworkExtensions.xml  ← SSO TAKEOVER LOGIC LIVES HERE
            ├─ SignUpOrSignin.xml       ← Relying party (extension_ssoMigrated output)
            ├─ PasswordReset.xml        ← Unmodified (blocking via TP override in extensions)
            └─ ProfileEdit.xml          ← Unmodified
```

### User journey flow (SignUpOrSignIn)

```
Step 1:  Combined Sign-in Page (Facebook button + email/password form)
           │
Step 2:  ├── Facebook OAuth ──────────────────┐
         └── Local Signup (email+password) ──► objectId set → Skip to Step 7
           │                                   │
Step 3:  Read by alternativeSecurityId         │ (social only, returning user check)
         ├── Found → objectId set ──────────► Skip to Step 9
         └── Not found ─────────────────────┐
           │                                 │
Step 4:  [SSO TAKEOVER] Read local by email  │ (first-time SSO, has email, no objectId)
         ├── Found → objectId set ──────────┐
         └── Not found ──────────────────► Step 6 (new social user)
           │                               │
Step 5:  [SSO TAKEOVER] Link social ID     │ (objectId found, not already migrated)
         + Set extension_ssoMigrated=true  │
         → Same objectId preserved         │
           │                               │
Step 6:  Self-asserted (brand-new social   │
         users who have no local account) ─┘
           │
Step 7:  Read user attributes (local only)
           │
Step 8:  Fallback: write new social account (no objectId yet)
           │
Step 9:  Issue JWT token
```

### Local login blocking flow

```
User enters email + password
  │
  ├─ login-NonInteractive validates credentials → objectId
  │
  ├─ AAD-ReadSsoMigratedFlag reads extension_ssoMigrated
  │
  └─ ThrowSsoMigratedError (only if extension_ssoMigrated == True)
     → "This account has been migrated to SSO."
```

### Key technical profiles

| Profile | Purpose |
|---------|---------|
| `AAD-UserReadUsingEmailAddress-Takeover` | Reads local account by email (no error if not found); used for SSO takeover matching |
| `AAD-LinkSSOToExistingUser` | Links `alternativeSecurityId` + sets `extension_ssoMigrated=true` on existing account |
| `AAD-ReadSsoMigratedFlag` | Reads `extension_ssoMigrated` by objectId (used in validation chains) |
| `ThrowSsoMigratedError` | ClaimsTransformation TP that asserts `extension_ssoMigrated == false`; raises error when true |
| `SelfAsserted-LocalAccountSignin-Email` (override) | Adds migration check to local login validation chain |
| `LocalAccountDiscoveryUsingEmailAddress` (override) | Adds migration check to password reset validation chain |

### Key claims

| Claim | Type | Purpose |
|-------|------|---------|
| `extension_ssoMigrated` | boolean | Persisted flag indicating the account has been migrated to SSO |

### Claims transformations

| Transformation | Method | Purpose |
|---------------|--------|---------|
| `AssertNotSsoMigrated` | `AssertBooleanClaimIsEqualToValue` | Asserts `extension_ssoMigrated == false`; fails with error when true |

---

## How the blocking works

### Logical blocking via `extension_ssoMigrated`

Unlike approaches that randomize passwords or delete sign-in names, this solution blocks local login **logically**:

1. The password is **NOT changed** — it remains in the directory
2. The `signInNames.emailAddress` is **NOT deleted** — the account is still discoverable by email
3. Instead, `extension_ssoMigrated` is set to `true` as a persisted extension attribute
4. The local login and password reset flows check this flag and **reject the attempt with a clear error message**

This approach is:
- **Reversible**: An admin can set `extension_ssoMigrated=false` via Graph API to re-enable local login
- **Auditable**: The flag is inspectable in the directory
- **Transparent**: Users see a clear error message explaining why their local login was blocked

### Extension attributes

The `extension_ssoMigrated` attribute is stored in Azure AD as `extension_{AppId}_ssoMigrated` where `{AppId}` is the b2c-extensions-app's client ID (without hyphens). The B2C policy engine handles this mapping automatically when `AAD-Common` metadata includes the correct `ApplicationObjectId` and `ClientId`.

---

## Edge cases

| Scenario | Behavior |
|----------|----------|
| SSO email differs from local email | No merge (different accounts, new social user created) |
| Social IDP doesn't provide email | No merge (Step 4 skipped, new social user flow) |
| User already has social account linked | Normal social sign-in (Step 3 finds by alternativeSecurityId) |
| Already migrated user signs in via SSO | Normal sign-in (Step 5 skipped due to `extension_ssoMigrated == True`) |
| Multiple social IDPs with same email | First SSO triggers takeover; second IDP would need additional linking logic |

---

## Adding more SSO providers

To add another SSO provider (e.g., Google, Azure AD), add it to the `ClaimsProviders` section in `TrustFrameworkExtensions.xml` and the user journey's Step 1 and Step 2. The takeover logic in Steps 4-5 is **provider-agnostic** — it works based on email matching, not the specific SSO provider.

Example for adding Google:

```xml
<!-- In Step 1, add: -->
<ClaimsProviderSelection TargetClaimsExchangeId="GoogleExchange" />

<!-- In Step 2, add: -->
<ClaimsExchange Id="GoogleExchange" TechnicalProfileReferenceId="Google-OAUTH" />
```
