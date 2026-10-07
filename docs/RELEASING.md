# Release workflow

## Apple account setup

1. In Xcode → Settings → Apple Accounts, sign in with the Apple Account enrolled in the Apple Developer Program. Verify the membership team is selected for both targets. The current configured team ID is `KSZ7QR8Y88`; confirm it matches the membership before changing it in `project.yml`.
2. Keep automatic signing enabled. In Certificates, Identifiers & Profiles, verify explicit App IDs `gay.ian.Bookworms` and `gay.ian.Bookworms.TopShelf`. Both need App Group `group.gay.ian.Bookworms`; the app also needs CloudKit container `iCloud.gay.ian.Bookworms` and Push Notifications for the required `aps-environment` entitlement. Development signing uses `development`; distribution signing must use `production`. These identifiers must remain stable to preserve app data and Keychain access.
3. In App Store Connect → Apps → + → New App, select tvOS, name `Bookworms - eBook Display`, primary language English, bundle ID `gay.ian.Bookworms`, and a unique internal SKU such as `bookworms-tvos`. The extension does not need a separate store listing. Accept any pending developer agreements.
4. Xcode Organizer can manage distribution signing during distribution. A local Apple Development identity alone does not establish distribution readiness. Never put signing keys or account credentials into this repository.

See Apple's [app record instructions](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app) and [capability setup](https://developer.apple.com/help/account/identifiers/enable-app-capabilities).

## Version policy

`project.yml` is the only version source. Set `MARKETING_VERSION` to a three-component release version, such as `1.0.0`, and `CURRENT_PROJECT_VERSION` to a positive sequential integer from 1 through 9999. Both Info.plists reference these settings; Xcode expands them during the build.

Before an upload, check App Store Connect for existing builds and choose an unused build greater than previous uploads. Earlier TestFlight uploads count. Increment once for each new upload candidate. Routine source edits do not require a bump. Change the marketing version intentionally for a new release.

After changing `project.yml`, run `xcodegen generate`. Verify that both generated Info.plists still contain `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` rather than hardcoded numbers. Keep the generated Xcode project consistent with the specification.

## Automated release commands

Check the highest uploaded build in App Store Connect, then run:

```sh
python3 scripts/release.py prepare --highest-uploaded-build 2
```

Use the actual highest uploaded number. The command increments beyond both that number and the current local build, preserves the marketing version, regenerates the project, runs the complete offline suite, archives Release, and verifies the archive. A failed step stops the pipeline. It records the source snapshot and digest, source commit, tool versions, test output, dSYMs, and verification in a unique ignored `.local/releases/` candidate directory. Do not edit source files while it runs.

Use the printed candidate directory for the next commands:

```sh
python3 scripts/release.py validate .local/releases/CANDIDATE
# Commit the exact candidate sources before an authorized upload.
python3 scripts/release.py upload .local/releases/CANDIDATE
```

`validate` uses Xcode's validation export method to perform Apple distribution checks. `upload` requires successful validation, a clean working tree, and the same source contents used to prepare the candidate. Committing those unchanged contents is allowed. It disables automatic build-number changes and requests production CloudKit signing. An interrupted upload is marked `upload-requested`; check App Store Connect before retrying to avoid duplicate submissions. Apple must finish processing an uploaded build before you can select it for an App Store version.

The signed-in Xcode account provides authentication on this Mac. For unattended execution, set `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID` together. Keep the private `.p8` key outside the repository, preferably supplied through a secret manager. Never put it in a command argument as literal key content, commit it, or include it in release artifacts. API-key authentication and upload must be verified with the intended account before enabling unattended CI. See [Apple's command-line distribution guidance](https://developer.apple.com/videos/play/wwdc2021/10204/).

No GitHub workflow or recurring upload is enabled by these commands. Source changes are not automatically committed or pushed.

## Archive verification

Both targets must provide `CFBundleDisplayName` and require `arm64` in their Info.plists. Keep these values and the app's push entitlement in `project.yml` so regeneration preserves them.

The verifier checks display names, the arm64 requirement, the CloudKit push entitlement against its profile, both executable images for LLVM coverage, both packaged versions, signatures, entitlements, privacy manifests, and extension packaging. Development signing is reported, not treated as App Store approval. Preserve the complete candidate directory. Local verification does not replace Apple distribution validation.

## App Store submission

Local preparation ends before upload. Before uploading, deploy any new CloudKit record type or field to production. The production schema contains `LibraryArchive` with its `archive` asset.

After an authorized upload:

1. Wait for Apple to finish processing the build.
2. In App Store Connect, open the tvOS version whose number matches `MARKETING_VERSION`, or create it. Under **Build**, select the uploaded build. If Xcode changed the build number, record and verify the final number.
3. Complete the listing, **App Privacy**, **Age Rating**, **App Review Information**, and **Pricing and Availability** from [App Store information](#app-store-information).
4. Under **App Store Version Release**, choose **Manually release this version** so an approved build goes live only when you release it.
5. Select **Add for Review**, then **Submit to App Review**.

To check the exact candidate with production signing and production CloudKit before submission, export it from Xcode Organizer with **Release Testing** and install it on the registered Apple TV. Verify launch, navigation, source credentials, refresh and cache behavior, Top Shelf, offline recovery, and production iCloud.

Compilation and local signature verification do not establish distribution or physical-device readiness.

## App Store information

| Field | Value |
| --- | --- |
| Name | Bookworms - eBook Display |
| Privacy policy URL | https://ian.gay/bookworms-privacy-policy/ |
| Apple TV privacy policy | Required for tvOS, because Apple TV has no browser. Paste the plain text from [Apple TV privacy policy text](#apple-tv-privacy-policy-text). App Review reviews it, and the Apple TV App Store displays it. |
| Support and marketing URL | https://ian.gay/bookworms-an-app-to-show-off-your-e-books/ |
| Contact | bookworms@ian.gay |
| Version | Same as `MARKETING_VERSION` in `project.yml` |
| Price | Free, with no in-app purchases. Bookworms is free and open source. |
| Apple TV screenshots | 1920×1080 or 3840×2160 only. The README images in `screenshots/` are 2560×1440 and are rejected; create the output folder with `mkdir -p .local/app-store-screenshots`, then resize them with `sips -z 1080 1920 screenshots/*.jpg --out .local/app-store-screenshots` |
| App Privacy | **Data Not Collected**; see [privacy implementation](PRIVACY.md) |
| Age rating | The app shows Hardcover reviews, which are user-generated content. Answer the questionnaire accordingly. |
| Content rights | The app shows third-party content: Hardcover metadata, covers, profile photos, and reviews. |
| App Review sign-in | A demo Hardcover account with finished books, a current read, and followed readers. Enter its credentials only in App Store Connect. |

Use these App Review notes, adjusted to the build:

```text
Bookworms shows a Hardcover (hardcover.app) reading library on Apple TV. It only reads the account; it never changes it.

Without an account: on the start screen, select "Explore a sample shelf".

With the demo account: open Settings > Sources > Connect Hardcover. Scan the QR code, or open hardcover.app/link on a phone or computer, sign in with the demo account, enter the code shown on the TV, and select Authorize. The TV connects automatically.

Social views show only readers the account follows. Book details can also show public Hardcover reviews of that book. Hardcover moderates all reviews; users report and block readers in the Hardcover app and website. Bookworms reads the account's block list and never shows readers the account blocked.

Book Wall is off by default. Turn it on in Settings > Views. It requires Apple TV 4K (2nd generation) or later.
```

### Apple TV privacy policy text

Paste this text into the **Apple TV Privacy Policy** field. Update it with the published policy, and change the effective date when either changes.

```text
Bookworms privacy policy

Effective October 1, 2026. Contact: bookworms@ian.gay
Web version: ian.gay/bookworms-privacy-policy

Summary
Bookworms shows your Hardcover reading library on your Apple TV. The developer doesn't operate a server and doesn't receive your data. There's no account with the developer, and no advertising, analytics, or tracking.

Information Bookworms uses
When you connect Hardcover, Bookworms saves your sign-in in the Apple TV's Keychain and uses it to read the following directly from Hardcover:
- Your library and reading history, such as books, reading status and progress, dates, and ratings.
- Social information from readers you follow, such as profiles, profile photos, libraries, activity, ratings, and reviews. Bookworms also shows public Hardcover reviews of a book when you choose to view them.
- The list of readers you blocked, so Bookworms can hide them.

Bookworms only reads this information and never changes your Hardcover account. Hardcover's policies govern the data Hardcover holds, including the moderation of reviews.

Covers and profile photos download from the addresses Hardcover provides. Those servers receive standard connection information, such as your IP address. Your settings are stored in the app.

Where data is stored
Downloaded information, images, and settings stay on your Apple TV. Bookworms may remove cached data when space is needed and download it again at the next sync. A troubleshooting log records the status and timing of recent requests. It excludes credentials and book content, and it never leaves your Apple TV.

iCloud storage is optional and off by default. If you turn it on, Bookworms saves a copy of your library information to your private iCloud database so your Apple TVs can restore it. The developer can't access that copy. It excludes your Hardcover sign-in, images, and social information. Apple's privacy policy governs iCloud.

Your choices
- Settings > Sources > Disconnect Hardcover removes your saved sign-in from the Apple TV.
- Revoke Bookworms' access at any time on Hardcover's Authorized Apps page.
- Turning off iCloud storage in Settings > General stops syncing. The existing copy stays in iCloud until you remove Bookworms' data in your Apple Account's iCloud storage settings.
- Deleting Bookworms from your Apple TV removes all local data.

Children
Bookworms isn't directed to children and doesn't knowingly collect information from them.

Changes
Changes will be posted here and at ian.gay/bookworms-privacy-policy with a new effective date.
```

Keep the published privacy policy and this text consistent with the build: it describes Hardcover as the only source, iCloud storage as off by default, and no AI or font requests. Update both before enabling CWA (`BookPresentation.offersCWA`), generated spines, or iCloud by default. iCloud storage is opt-in.

## Verify the release candidate

Follow [the testing procedure](TESTING.md) and keep results with the exact candidate build:

- The minimum/current simulator matrix (`python3 scripts/test-worker.py --detach --profile major`). Missing runtimes and unexpected skips block verification.
- On Apple TV: navigation and focus, covers and shelf layout, both appearances, VoiceOver, Reduce Motion, Top Shelf, and ambient sessions.
- Hardcover connection, explicit sync, automatic daily limits, offline recovery, and social views with spoiler controls.
- Release-build launch and interaction profiling without coverage instrumentation.

## Encryption declaration

The app declares `ITSAppUsesNonExemptEncryption: false` in `project.yml`, which generates a Boolean `false` in its Info.plist. The current implementation relies on Apple-provided cryptography and includes no custom or third-party encryption implementation. Reassess this declaration when adding cryptography or dependencies. It applies to future builds; answer the compliance questions separately for an already uploaded build that lacks the declaration.
