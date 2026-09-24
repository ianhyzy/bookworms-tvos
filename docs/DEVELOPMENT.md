# Development setup

Read [contributor instructions](../AGENTS.md) for repository rules and implementation entry points. Run commands from the tvOS repository root. Each platform app has its own sibling folder and independent Git repository.

## Build locally

Install Xcode with the tvOS platform and simulator runtime. Install XcodeGen if you need to regenerate the checked-in project.

```sh
xcodegen generate
open Bookworms.xcodeproj
```

Use `Bookworms` for simulator tests and `BookwormsDevice` for Release device builds and archives. `project.yml` is the source of truth for target membership, signing settings, and versions. Inspect generated changes after editing it; Xcode can also modify generated files during signing setup.

Follow [testing procedures](TESTING.md) for deterministic tests and result artifacts. Use `python3 scripts/test-local.py --major` for major changes; it verifies the configured minimum and current tvOS runtimes. Use `BookwormsLive` only for separately authorized read-only service checks on an explicitly configured simulator. Documentation-only edits require accuracy and link checks, not a full app test run.

## Stable identifiers

The public display name differs from internal product names. Preserve these identifiers when changing branding:

| Purpose | Identifier |
| --- | --- |
| App and Swift module | `Bookworms` |
| App bundle | `gay.ian.Bookworms` |
| Top Shelf extension | `gay.ian.Bookworms.TopShelf` |
| App Group | `group.gay.ian.Bookworms` |
| CloudKit container | `iCloud.gay.ian.Bookworms` |
| URL scheme | `bookworms` |
| App Store SKU | `bookworms-tvos` |

Changing bundle IDs can break updates and access to stored data. Follow [the release workflow](RELEASING.md) for signing and distribution.

## Work with a physical Apple TV

Use `BookwormsDevice` for Release builds and archives. Its default test plan disables coverage. Coverage-enabled plans can instrument Release executables; verify the binary as well as build settings.

For an authorized install:

```sh
python3 scripts/device-build.py --device APPLE_TV_UDID --team TEAM_ID
```

The helper defaults to Release for installs and Debug for tests. It removes this project's UI test runner after the operation. Preserve the stable app bundle and install updates in place; do not uninstall the app as routine cleanup.

For pairing, open **Settings → Remotes and Devices → Remote App and Devices** on Apple TV, then use **Window → Devices and Simulators** in Xcode. Follow [performance diagnosis](PERFORMANCE_DIAGNOSIS.md) for profiling. Simulator timings and coverage builds do not establish physical-device performance.

## Handle credentials and external data

Store provider credentials in Keychain. Use fixed read-only Hardcover queries and the scopes in [Hardcover authentication](HARDCOVER_AUTHENTICATION.md). The app accepts personal access tokens; it rejects legacy JWTs and OAuth access tokens. Cached books remain available during reconnection.

For authorized Debug bootstrap, pass a 1Password reference rather than a literal token:

```sh
python3 scripts/connect-development-build.py \
  --secret-ref 'op://VAULT_ID/ITEM_ID/FIELD_ID' \
  --device DEVICE_ID
```

The helper also accepts `--simulator SIMULATOR_ID`. Release builds use the source settings screen. Never place credentials in repository files, command arguments, logs, screenshots, or test fixtures. CWA requires an HTTPS OPDS endpoint; a private server must be reachable from the Apple TV.

Read [privacy behavior](PRIVACY.md) before changing data collection, retention, or external transfers. Optional iCloud storage preserves library metadata and saved designs; credentials stay in Keychain.

## Release preparation

Follow [the release workflow](RELEASING.md) for version changes, candidate archives, and distribution. Keep dated evidence in local candidate artifacts. Report simulator, physical-device, archive, and distribution checks separately.

## Local install branding

`python3 scripts/device-build.py --device DEVICE_ID --team TEAM_ID` builds and installs with a LOCAL badge and the name **Bookworms Local**. It preserves the release bundle identifier and existing library data, so it replaces the installed TestFlight copy rather than installing alongside it. Release archives use the normal icon and name. Regenerate the local assets with `python3 scripts/generate-app-icon.py --local` using Node.js and `sharp`.

## Date display

**Settings → General → Date format** saves the display preference locally. The default is `MMM dd, yyyy` (Jan 01, 2026); alternatives are `MM/dd/yyyy`, `dd/MM/yyyy`, and `yyyy-MM-dd`. Shelf captions, book details, activity cards, and source schedule dates use this choice. Source data and cache timestamps retain their original formats.
