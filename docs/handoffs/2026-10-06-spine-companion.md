# Spine companion handoff

The iPhone and Mac spine companions design book spines from Hardcover covers and share them with the Apple TV app through private CloudKit. Book Wall draws them. The work spans three independent repositories. This handoff describes the tvOS integration on the `spine-companion` branch, which includes `main` through `8eb58e8`.

## Where things are

| Piece | Location | State |
| --- | --- | --- |
| iPhone app | `~/Documents/BookwormsApps/ios`, private GitHub repository `ianhyzy/bookworms-ios` | Generates designs with Private Cloud Compute (generator `ios-pcc-v1`). Its designs add the optional `fontFamily`, `fontPostScriptName`, `instanceWeight`, and `provenance` fields. |
| Mac app (**Bookworms Spines**) | `~/Documents/BookwormsApps/macos`, private GitHub repository `ianhyzy/bookworms-macos` | About 1,300 lines of Swift with contract tests. Committed on `main`. |
| tvOS integration | Branch `spine-companion`, worktree `~/Developer/worktrees/bookworms-tvos-spine-companion` | `SpineCloudStore`, worklist publication, design fetch and cache, and [Book Wall companion designs](../BOOK_WALL.md#companion-designs) behind `BookPresentation.showsCompanionSpines`. |
| Original tvOS integration | Branch `spine-display`, commit `5c58281` | The port supersedes it. Its worktree is removed; keep the branch until `spine-companion` merges. |

## How the companion works

1. The Apple TV syncs the full Hardcover library and, with iCloud storage on, saves it to the `library-v1` archive in the private database of `iCloud.gay.ian.Bookworms`. The archive holds the full fetched library, not the displayed limit.
2. After that archive save, the TV publishes a `SpineWorklistV1` record (record name `spine-worklist-v1`, JSON in a `payload` data field) from the snapshot in the uploaded archive. It holds the active Hardcover account ID, the snapshot's sync date, and every book ID, sorted and deduplicated. The TV publishes a nonempty list only while the Hardcover source is enabled with a connected, unexpired credential whose authenticated account matches the snapshot. A TV with an expired session or no credential publishes nothing and leaves the record unchanged. Disabling or disconnecting Hardcover publishes an empty list.
3. The Mac subscribes to worklist changes. It reads book metadata from the matching account snapshot in `library-v1`, downloads each cover over HTTPS, and analyzes it with Vision OCR and the on-device Foundation Models system model. It never receives a Hardcover credential or calls a cloud AI service.
4. The Mac writes one `SpineDesignV1` record per book: background, foreground, and accent colors (`#RRGGBB`), a typeface (`serif`, `sans`, `rounded`, or `monospaced`), a weight (400–700), an uppercase flag, a work-item hash of the book metadata, a cover-content hash, and a generator version. The iPhone app follows the same steps with Private Cloud Compute and also names a Google Fonts family and instance.
5. The TV validates designs in bounded batches (matching account, book, and work-item hash; foreground contrast at least 4.5:1; optional font fields bounded as on the iPhone) and caches them in `Caches/Bookworms/spine-designs-v1.json`, separate from the retained API-key design store. It reads designs at launch, on activation, and after each cloud sync, then publishes them to Book Wall, which downloads each design's Google Fonts face during preparation.

The JSON contract lives in `ios/Bookworms/Models/CloudContract.swift`, `macos/BookwormsMac/Models/CloudContract.swift`, and `Bookworms/Services/SpineCloudStore.swift`. Keep them compatible; all three pin the same digests.

## How the port differs from `5c58281`

- **No Hardcover request before publishing.** `5c58281` validated the saved token against Hardcover inside the cloud sync whenever the process had no verified account cached, such as after a relaunch. The port gates on local state instead: `hardcoverConnected`, `hardcoverEnabled`, `!hardcoverSessionExpired`, and the uploaded snapshot's account. A connected credential's authenticated validate or fetch set `activeHardcoverAccountID`; a credential-free restore can adopt the account the cloud worklist names, but that TV never lists work. The port drops `verifiedHardcoverAccountID` and `verifiesHardcoverAccount`.
- **Worklist source.** The port publishes from the snapshot in the archive that the sync just uploaded, not from memory, so the Mac's sync-date match holds. A snapshot installed during the sync sets the pending flag, so the next loop iteration uploads it and republishes, even after a failed publish.
- **Account provenance** (`HardcoverLibrary.accountID`, `validateHardcover` returning the account ID, account-specific snapshots) already existed on `main`, so the port leaves it alone.
- **Validators** keep `5c58281`'s rules. The table below lists the differences from the Mac validators. The two sides do not yet share these rules.

## Contract comparison

Both sides encode `Date` with the default `JSONEncoder` strategy (seconds since 2001 as a number). Record types `SpineWorklistV1` and `SpineDesignV1`, the `payload` data field, the container ID, the worklist record name, the design record name (`spine-design-v1-` + SHA-256 of `accountID:bookID`), and the work-item hash (SHA-256 of account ID, book ID, title, author, detail cover URL, cover URL, joined by newlines) are identical, and both test suites pin the same digests. The contrast formula is the same WCAG relative-luminance ratio.

| Item | tvOS | Mac | Effect |
| --- | --- | --- | --- |
| `SpineWorklistV1.accountID` length | No bound | At most 512 characters | None in practice; Hardcover IDs are short. |
| Worklist payload size | No bound | At most 5 MB | None in practice. |
| `coverHash` format | 64 hex digits, either case | 64 lowercase hex digits | None; the Mac writes lowercase. The TV is looser. |
| `workItemHash` format | Must equal the TV's own lowercase SHA-256 | 64 lowercase hex digits | None; the TV check is stricter and binds the design to the book. |
| Color hex case | `#` + 6 uppercase hex digits | Same | None; the Mac emits uppercase. |
| `generatorVersion` | Any non-blank string | Must equal `mac-foundation-models-v1` to skip regeneration | None on the TV. |
| Archive size the Mac reads | No bound on the TV | At most 50 MB | A very large archive stops the Mac; the TV does not warn. |

The iPhone app validates like the Mac, plus the optional font fields, which the TV checks the same way. Unlike the TV, the iPhone keeps showing a design whose work-item hash no longer matches the book, so after a metadata edit the TV shows the local spine until a companion regenerates the design.
| Extra `Book` fields | Encoded in `library-v1` | Ignored by `CloudBook` | None. |

## Remaining steps

1. **Signed end-to-end check**: a signed iPhone or Mac and the Apple TV on one iCloud account. Confirm the worklist lists every book, a companion design reaches the TV cache with its font fields, and Book Wall shows it while other views show covers. See [testing](../TESTING.md).
2. **Privacy policy**: Book Wall now requests Google Fonts faces. Update the published policy and the [policy text](../RELEASING.md#apple-tv-privacy-policy-text) before uploading a candidate with `showsCompanionSpines` on.
3. **Deploy `SpineWorklistV1` and `SpineDesignV1`** (each with a `payload` data field) to the production CloudKit schema before any TestFlight build uses them. See [releasing](../RELEASING.md).
4. **Design refresh cadence**: the TV refetches every design record on launch, activation, and after each cloud sync. A new design for a current-year book rebuilds Book Wall, even while it is on screen. Consider a `SpineDesignV1` subscription with silent push, as the Mac does for the worklist.
5. **Latest design wins**: the owner wants each resource to use its latest version, whichever app made it. The Apple TV already does this for designs. The iPhone regenerates any design whose generator is not `ios-pcc-v1`, and the Mac regenerates any design whose generator is not `mac-foundation-models-v1`, so the companions overwrite each other. Change both to keep a valid design whose work-item and cover hashes still match.
6. **Validator alignment**: decide whether the TV should adopt the Mac's lowercase-only `coverHash` and the account ID length bound.

## Commands

| Purpose | Command |
| --- | --- |
| Mac unsigned tests (run in `macos`) | `xcodebuild -project BookwormsMac.xcodeproj -scheme BookwormsMac -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-disable-sandbox' test` |
| Mac build and launch | `./script/build_and_run.sh` |
| tvOS default verification | `xcrun swift-format lint --strict <file>`, then `python3 scripts/device-build.py` |
| tvOS tests (only when the owner asks) | `python3 scripts/test-worker.py --detach` |

## Constraints

- Follow each repository's `AGENTS.md`. The Mac app requires macOS 27 and Apple Intelligence, stays read-only toward Hardcover, holds no provider credentials, and has no tvOS view dependency.
- Keep one active Hardcover account. A worklist or design for another account must never mix into the active shelf.
- A worklist for an older snapshot must not replace a newer one for the same account.
- Unsigned builds prove compilation only, not iCloud access or push delivery.

## Open questions for the owner

- Disabling or disconnecting Hardcover on one Apple TV publishes an empty worklist, which pauses the companion for every TV on the iCloud account until another TV's next cloud sync republishes. Should a local disable clear the shared worklist?
- After a relaunch, a revoked credential can publish one nonempty worklist before the first failed refresh marks the session expired. The account is still the last authenticated one. Is that acceptable?
- Is the Foundation Models design quality good enough on the owner's library, or does the analyzer need tuning first?
