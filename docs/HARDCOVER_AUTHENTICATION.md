# Hardcover authentication

Bookworms uses the OAuth 2.0 Device Authorization Grant (RFC 8628) to connect to Hardcover. The Apple TV requests a device code from Hardcover, displays a short 8-character verification code (e.g. `YSVA-NBK1`), and prompts the user to visit `hardcover.app/link` on their phone or computer. The user enters the code and authorizes Bookworms in their browser. The Apple TV polls Hardcover for approval and automatically completes authentication, saving the access token and refresh token in Keychain. Existing Personal Access Tokens (PATs) and OAuth tokens are accepted by the Bearer token validator.

The OAuth configuration uses:

- **Client ID**: `ca996be3-0df1-4cbf-819a-e17644fbcf38`
- **Verification URL**: `https://hardcover.app/link`
- **Device Authorization Endpoint**: `https://hardcover.app/oauth2/device`
- **Token Endpoint**: `https://hardcover.app/oauth2/token`
- **Requested scopes**: `read:me:content read:library read:catalog:data read:social read:users`
- **Manual Redirect URI (fallback)**: `urn:ietf:wg:oauth:2.0:oob` (and `gay.ian.bookworms:/oauth/callback`)

The GraphQL API endpoint is `https://api.hardcover.app/v1/graphql`, with `Authorization: Bearer <token>`. HTTP 401 indicates an invalid or expired credential. HTTP 403 with `insufficient_scope` asks the user to reconnect with the required read permissions; other 403 responses report denied access without incorrectly calling the token expired.

When connecting or updating login, the app exchanges the approved device code for an access token and refresh token and validates the account before saving to Keychain. Between scheduled syncs, credential rotation validates the account without refetching the entire library. A rejected connection preserves the displayed shelf and saved credential.

## Token renewal

Hardcover access tokens last one week. Refresh tokens last six months and work once: a renewal returns a new access token and a new refresh token, and sending a spent refresh token revokes the login. Bookworms keeps the Apple TV signed in this way:

- Keychain holds the access token (`hardcover-token`) and the refresh token (`hardcover-refresh-token`). User defaults hold the date the access token is due for renewal, which isn't secret.
- Library sync, social sync, and opening community reviews renew a token before using it when it's due: a day before it expires, or halfway through its lifetime when Hardcover issues a token that lasts less than two days. Each of them renews the token once and retries when Hardcover rejects a request with HTTP 401.
- `HardcoverSession` is the only code that spends a refresh token, and it runs one renewal at a time. Syncs that need a token during a renewal wait for it and use its result. The renewal request never retries. It runs in its own task, so cancelling a sync doesn't lose the tokens Hardcover rotated. The Top Shelf extension never holds a credential.
- The new refresh token is saved before the access token. If Keychain refuses the save, the app uses the new tokens, and their renewal date, for the rest of the launch and retries the save at the next sync.
- When Hardcover rejects the refresh token, the app keeps using the access token, which can work until it expires, and doesn't send the rejected refresh token again during that launch. Once Hardcover rejects the access token too, Settings shows **Reconnect Hardcover**, as it does for an expired login. A renewal that fails for another reason, such as a timeout, keeps the saved token for that sync and tries again at the next one.
- A Keychain read that fails returns no token. The app then skips the renewal or shows **Reconnect Hardcover**, but it never deletes the saved login, and the next sync that reads Keychain recovers.
- A login without a refresh token, such as a personal access token, works until Hardcover rejects it and then shows **Reconnect Hardcover**.
- Social sync keys its cache on the Hardcover account rather than the token, so a renewed token keeps cached social data.
- **Disconnect Hardcover** removes both tokens from the Apple TV but doesn't revoke them at Hardcover. To end the session there too, revoke Bookworms on Hardcover's Authorized Apps page.

## Verification

Authentication tests cover device authorization initiation, device token polling states (pending, slow down, expired, access denied, success), authorization code exchange, OAuth and PAT token validation, rejection of malformed or invalid codes before transport, Bearer authentication, distinct 401/403 errors, and shelf preservation after a rejected connection. Renewal tests cover the refresh request and its form encoding, renewal before expiry (halfway through a short-lived token's lifetime) and after HTTP 401, refresh token rotation, one shared renewal for concurrent library and social syncs, revoked and unavailable renewals in library and social sync, an access token kept after a rejected renewal, unreadable refresh tokens, Keychain save failures, disconnection during a renewal, and social sync continuing with a renewed token.

## Sign in on Apple TV

On a fresh launch without a saved account or library snapshot, a welcome popup offers **Connect Hardcover** and **Explore sample library**. **Connect Hardcover** receives focus by default. Down moves to the sample choice; Up returns to Hardcover. The popup appears after startup checks saved state. Choosing the sample library completes the welcome flow without contacting Hardcover.

Select **Connect Hardcover** in the popup, or open **Settings → Sources → Connect Hardcover**, to use the same sign-in card.

1. Scan the QR code with your phone, or open **hardcover.app/link** in a browser.
2. Enter the 8-character code shown beside it and select **Authorize**.
3. Your Apple TV checks the account, downloads the library, and saves it automatically after you approve.

The card requests a code as soon as it opens. **New code** replaces an expired code, and **Enter a code instead** shows a text field for an authorization code typed with the remote. A loading card shows account validation, library download, and saving progress. A failed connection returns to the sign-in card with an error and controls to try again.

If authorization completes while another library operation is running, the app clears the consumed code and asks you to try again after that operation finishes. Select **Get link code** to request a fresh code. The app keeps the existing account and shelf until a new connection succeeds.

The welcome popup then shows **Preparing your library** while the app loads covers and arranges the shelf. It closes when that preparation finishes. Transitions fade between stages and respect Reduce Motion. Back from sign-in returns to the two welcome choices. Back from the initial choices closes the popup without completing setup, so it appears again on the next launch. Back during preparation completes setup and closes the popup. Choosing a sample library or completing setup persists the welcome completion flag. Saved accounts and snapshots also prevent the popup from appearing, including accounts whose source is disabled.

In Settings, Back closes the sign-in card. The empty shelf still offers **Choose sources**, which opens **Settings → Sources**, and **Explore a sample shelf**.

While a login works, **Settings → Sources** shows **Disconnect Hardcover** instead of opening the card. When a sync reports the saved login as invalid or expired, the button becomes **Reconnect Hardcover** and **Sync now** is unavailable until you sign in again, unless another source can sync. The saved login stays in Keychain until a new link replaces it or you disconnect.

The bundled QR image points to `https://hardcover.app/link` and is generated offline with Apple Core Image and verified by decoding it with Vision. To regenerate it on macOS, run `swift scripts/generate-hardcover-qr.swift Bookworms/Assets.xcassets/HardcoverTokenQR.imageset/hardcover-token.png`.

## Repeat first-launch setup on a development install

After the owner authorizes removing the TV's saved Hardcover account, build and launch with:

```sh
python3 scripts/device-build.py --device APPLE_TV_UDID --team TEAM_ID --reset-hardcover-setup
```

This launch removes the local Hardcover login, Hardcover and legacy snapshots, account identity, Hardcover sync history and error, and welcome completion flag. It preserves CWA accounts and snapshots, cached artwork, saved designs, and display settings. iCloud restoration waits until welcome setup completes when the popup is needed. A retained CWA account or snapshot suppresses the popup and allows normal iCloud sync to resume after startup. The flag resets only this launch; subsequent launches keep the newly connected account. See [device development](DEVELOPMENT.md#work-with-a-physical-apple-tv).
