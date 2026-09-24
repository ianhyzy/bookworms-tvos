# Hardcover authentication

Bookworms uses the OAuth 2.0 Device Authorization Grant (RFC 8628) to connect to Hardcover. The Apple TV requests a device code from Hardcover, displays a short 8-character verification code (e.g. `YSVA-NBK1`), and prompts the user to visit `hardcover.app/link` on their phone or computer. The user enters the code and authorizes Bookworms in their browser. The Apple TV polls Hardcover for approval and automatically completes authentication, storing the bearer access token securely in Keychain. Existing Personal Access Tokens (PATs) and OAuth tokens are accepted by the Bearer token validator.

The OAuth configuration uses:

- **Client ID**: `ca996be3-0df1-4cbf-819a-e17644fbcf38`
- **Verification URL**: `https://hardcover.app/link`
- **Device Authorization Endpoint**: `https://hardcover.app/oauth2/device`
- **Token Endpoint**: `https://hardcover.app/oauth2/token`
- **Requested scopes**: `read:me:content read:library read:catalog:data read:social read:users`
- **Manual Redirect URI (fallback)**: `urn:ietf:wg:oauth:2.0:oob` (and `gay.ian.bookworms:/oauth/callback`)

The GraphQL API endpoint is `https://api.hardcover.app/v1/graphql`, with `Authorization: Bearer <token>`. HTTP 401 indicates an invalid or expired credential. HTTP 403 with `insufficient_scope` asks the user to reconnect with the required read permissions; other 403 responses report denied access without incorrectly calling the token expired.

When connecting or updating login, the app exchanges the approved device code for an access token and validates the account before saving to Keychain. Between scheduled syncs, credential rotation validates the account without refetching the entire library. A rejected connection preserves the displayed shelf and saved credential.

## Verification

Authentication tests cover device authorization initiation, device token polling states (pending, slow down, expired, access denied, success), authorization code exchange, OAuth and PAT token validation, rejection of malformed or invalid codes before transport, Bearer authentication, distinct 401/403 errors, and shelf preservation after a rejected connection.

## Sign in on Apple TV

On the empty start screen, **Choose sources** opens **Settings → Sources**. Select **Connect Hardcover**.

1. On your phone or computer, open a web browser and go to **hardcover.app/link** (or scan the small on-screen QR code).
2. Enter the 8-character code shown on your Apple TV screen and select **Authorize**.
3. Your Apple TV connects automatically as soon as you approve.

The bundled QR image points to `https://hardcover.app/link` and is generated offline with Apple Core Image and verified by decoding it with Vision. To regenerate it on macOS, run `swift scripts/generate-hardcover-qr.swift Bookworms/Assets.xcassets/HardcoverTokenQR.imageset/hardcover-token.png`.
