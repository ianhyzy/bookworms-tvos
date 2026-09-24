# Release workflow

## Apple account setup

1. In Xcode → Settings → Apple Accounts, sign in with the Apple Account enrolled in the Apple Developer Program. Verify the membership team is selected for both targets. The current configured team ID is `KSZ7QR8Y88`; confirm it matches the membership before changing it in `project.yml`.
2. Keep automatic signing enabled. In Certificates, Identifiers & Profiles, verify explicit App IDs `gay.ian.Bookworms` and `gay.ian.Bookworms.TopShelf`. Both need App Group `group.gay.ian.Bookworms`; the app also needs CloudKit container `iCloud.gay.ian.Bookworms` and Push Notifications for the required `aps-environment` entitlement. Development signing uses `development`; distribution signing must use `production`. These identifiers must remain stable to preserve app data and Keychain access.
3. In App Store Connect → Apps → + → New App, select tvOS, name `Bookworms - eBook Display`, primary language English, bundle ID `gay.ian.Bookworms`, and a unique internal SKU such as `bookworms-tvos`. The extension does not need a separate store listing. Accept any pending developer agreements.
4. Xcode Organizer can manage distribution signing during distribution. A local Apple Development identity alone does not establish distribution readiness. Never put signing keys or account credentials into this repository.

See Apple's [app record instructions](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app) and [capability setup](https://developer.apple.com/help/account/identifiers/enable-app-capabilities).

## Version policy

`project.yml` is the only version source. Set `MARKETING_VERSION` to a three-component release version, such as `1.0.0`, and `CURRENT_PROJECT_VERSION` to a positive sequential integer from 1 through 9999. Both Info.plists reference these settings; Xcode expands them during the build.

The initial local candidate is 1.0.0 (1). Before an upload, check App Store Connect for existing builds and choose an unused build greater than previous uploads. Do not assume a reset to 1 is safe if this bundle has already been uploaded. Increment once for each new upload candidate. Routine source edits do not require a bump. Change the marketing version intentionally for a new release.

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

`validate` uses Xcode's validation export method to perform Apple distribution checks. `upload` requires successful validation, a clean working tree, and the same source contents used to prepare the candidate. Committing those unchanged contents is allowed. It disables automatic build-number changes and requests production CloudKit signing. An interrupted upload is marked `upload-requested`; check App Store Connect before retrying to avoid duplicate submissions. Successful upload still requires Apple processing before TestFlight availability.

The signed-in Xcode account provides authentication on this Mac. For unattended execution, set `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID` together. Keep the private `.p8` key outside the repository, preferably supplied through a secret manager. Never put it in a command argument as literal key content, commit it, or include it in release artifacts. API-key authentication and upload must be verified with the intended account before enabling unattended CI. See [Apple's command-line distribution guidance](https://developer.apple.com/videos/play/wwdc2021/10204/).

No GitHub workflow or recurring upload is enabled by these commands. Source changes are not automatically committed or pushed.

## Archive verification

Both targets must provide `CFBundleDisplayName` and require `arm64` in their Info.plists. Keep these values and the app's push entitlement in `project.yml` so regeneration preserves them.

The verifier checks display names, the arm64 requirement, the CloudKit push entitlement against its profile, both executable images for LLVM coverage, both packaged versions, signatures, entitlements, privacy manifests, and extension packaging. Development signing is reported, not treated as App Store approval. Preserve the complete candidate directory. Local verification does not replace Apple distribution validation.

## Distribution boundary

Local preparation ends before upload. When distribution is authorized, open the archive in Xcode Organizer, validate and distribute through App Store Connect. Verify production entitlements after distribution signing. Keep the manually selected build number consistent; if Xcode changes it, record and verify the final uploaded number.

The production CloudKit schema contains `LibraryArchive` with its `archive` asset. Deploy any new record type or field to production before a TestFlight build uses it. Complete beta metadata and export compliance in App Store Connect. Start with internal testing; external testing requires Apple's beta review. Verify launch, navigation, source credentials, refresh/cache behavior, Top Shelf, offline recovery, and production iCloud on the exact distributed candidate.

Compilation and local signature verification do not establish distribution or physical-device readiness.

## Store and TestFlight information

| Field | Value |
| --- | --- |
| Privacy policy URL | https://ian.gay/bookworms-privacy-policy/ |
| Support and marketing URL | https://ian.gay/bookworms-an-app-to-show-off-your-e-books/ |
| Contact | bookworms@ian.gay |
| App Store Connect version | 1.0.0, matching `MARKETING_VERSION` |

Keep the published privacy policy consistent with the build: it describes Hardcover as the only source, iCloud storage as off by default, and no AI or font requests. Update it before enabling CWA (`BookPresentation.offersCWA`), generated spines, or iCloud by default. iCloud storage is opt-in.

## Verify the release candidate

Follow [the testing procedure](TESTING.md) and keep results with the exact candidate build:

- The minimum/current simulator matrix (`python3 scripts/test-worker.py --detach --profile major`). Missing runtimes and unexpected skips block verification.
- On Apple TV: navigation and focus, covers and shelf layout, both appearances, VoiceOver, Reduce Motion, Top Shelf, and ambient sessions.
- Hardcover connection, explicit sync, automatic daily limits, offline recovery, and social views with spoiler controls.
- Release-build launch and interaction profiling without coverage instrumentation.

## Encryption declaration

The app declares `ITSAppUsesNonExemptEncryption: false` in `project.yml`, which generates a Boolean `false` in its Info.plist. The current implementation relies on Apple-provided cryptography and includes no custom or third-party encryption implementation. Reassess this declaration when adding cryptography or dependencies. It applies to future builds; answer the compliance questions separately for an already uploaded build that lacks the declaration.
