# Mac spine companion handoff

This handoff restarts work on the Mac spine companion: a menu bar Mac app that designs book spines from Hardcover covers and shares them with the Apple TV app through private CloudKit. The work spans two independent repositories. Neither side is integrated on `main` yet.

## Where things are

| Piece | Location | State |
| --- | --- | --- |
| Mac app (**Bookworms Spines**) | `~/Documents/BookwormsApps/macos` | About 1,300 lines of Swift with tests. **The repository has no commits; every file is untracked.** |
| tvOS integration, original | Branch `spine-display`, commit `5c58281` ("Add Mac spine companion worklist and design cache") | Written on September 25 against a `main` from that week. Not merged. |
| tvOS integration, new work | Branch `spine-companion` at `~/Developer/worktrees/bookworms-tvos-spine-companion`, from `main` at `f234539` | Contains only this handoff. |
| Old worktree | `~/Developer/worktrees/bookworms-tvos-spine-display` | Its other commits (Book Wall, snapshot fix) already reached `main`. Remove it after porting `5c58281`; keep the branch until then. |

## How the companion works

1. The Apple TV syncs the full Hardcover library and, with iCloud storage on, saves it to the `library-v1` archive in the private database of `iCloud.gay.ian.Bookworms`.
2. After that archive save, the TV publishes a `SpineWorklistV1` record (record name `spine-worklist-v1`, JSON in a `payload` data field). It holds the Hardcover account ID, the snapshot's sync date, and every book ID, sorted and deduplicated.
3. The Mac subscribes to worklist changes. It reads book metadata from the matching account snapshot in `library-v1`, downloads each cover over HTTPS, and analyzes it with Vision OCR and the on-device Foundation Models system model. It never receives a Hardcover credential or calls a cloud AI service.
4. The Mac writes one `SpineDesignV1` record per book: background, foreground, and accent colors (`#RRGGBB`), a typeface (`serif`, `sans`, `rounded`, or `monospaced`), a weight (400–700), an uppercase flag, a work-item hash of the book metadata, a cover-content hash, and a generator version.
5. The TV validates designs in bounded batches (matching account, book, and work-item hash; foreground contrast at least 4.5:1) and caches them locally, separate from the retained API-key design store. No tvOS view reads the cache yet.

The JSON contract lives in `macos/BookwormsMac/Models/CloudContract.swift` and, on the TV side, in `Bookworms/Services/SpineCloudStore.swift` from `5c58281`. Keep them identical.

## What `main` already has

Since `5c58281`, `main` gained the account provenance that commit introduced:

- `HardcoverClient.fetchLibrary` returns `HardcoverLibrary` with `accountID`, `books`, and `series`.
- `validateHardcover` returns the account ID.
- `LibraryModel` tracks and persists `activeHardcoverAccountID`, and source snapshots carry the real account ID.

`main` does not have `SpineCloudStore`, worklist publication, design fetching, the companion cache, the `LibraryDependencies` hooks (`readSpineWorklist`, `publishSpineWorklist`, `fetchSpineDesigns`), `SpineCloudTests`, or the doc updates in `5c58281`.

## What changed on `main` that affects the port

- **Book Wall generates its own spines.** `BookWallLocalSpine.swift` samples cover colors and chooses fonts by genre on the Apple TV ([Book Wall](../BOOK_WALL.md)). The companion's designs are the obvious future input for these spines. Decide with the owner whether companion designs replace or refine local spines before wiring any view.
- **Generated-spine views stay disabled.** `BookPresentation.showsGeneratedSpines` and `spineGenerationEnabled` are `false`, and the repository instructions require keeping them off. Do not display companion designs without the owner's go-ahead.
- **`LibraryModel` was heavily reworked** by the Book Wall, Friends' Picks, series, and reading-progress changes. Port `5c58281` by hand; a cherry-pick will conflict.
- **Snapshot size.** Confirm that the cloud archive still stores the full fetched Hardcover library, not the displayed limit, because the Mac selects worklist books from it.

## Suggested order

1. **Commit the Mac app as-is** in `~/Documents/BookwormsApps/macos` so nothing is lost. Exclude `.codex/` and `DerivedData/` unless the owner wants them tracked. Ask before creating a GitHub remote.
2. **Port the tvOS side** onto `spine-companion`: `SpineCloudStore`, the dependency hooks, worklist publication after an archive save, the empty worklist on disable or disconnect, design refresh on launch and activation, cache pruning, and `SpineCloudTests`. Read `git show 5c58281` for the original.
3. **Update the tvOS docs** that `5c58281` changed: `DATASOURCES.md`, `docs/ARCHITECTURE.md`, `docs/PRIVACY.md`, `docs/RELEASING.md`, `docs/SOURCES_AND_ICLOUD.md`, and `docs/TESTING.md`. `AGENTS.md` and `docs/ARCHITECTURE.md` currently say no companion is required; keep that true, since the companion is optional.
4. **Check the contract** by comparing both `SpineWorklistV1` and `SpineDesignV1` definitions field by field and running both test suites.
5. **Signed end-to-end check**: a signed Mac and the Apple TV on the same iCloud account. The worklist lists every book, a Mac design reaches the TV cache, and TV views still show covers.
6. **Decide the display**: with the owner, choose where designs appear (Book Wall spines or shelf spines) and add that behind a presentation switch.

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
- CloudKit production needs `SpineWorklistV1` and `SpineDesignV1`, each with a `payload` data field, deployed before any TestFlight build uses them.
- Unsigned builds prove compilation only, not iCloud access or push delivery.

## Open questions for the owner

- Should companion designs drive Book Wall spines, shelf spines, or both?
- Should the Mac repository get a GitHub remote?
- Is the Foundation Models design quality good enough on the owner's library, or does the analyzer need tuning first?
