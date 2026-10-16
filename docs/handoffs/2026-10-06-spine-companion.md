# Spine companion handoff

The Bookworms iPhone and Mac companion designs book spines from Hardcover covers and shares them with the Apple TV app through private CloudKit. Book Wall draws them. The work spans two active repositories. This handoff describes the tvOS integration on `main`.

## Where things are

| Piece | Location | State |
| --- | --- | --- |
| iPhone and Mac companion | `~/Developer/BookwormsApps/ios`, private GitHub repository `ianhyzy/bookworms-ios` | One target builds both the iPhone and Mac apps. It designs spines with Private Cloud Compute by default (generator `ios-pcc-v2`). Its designs add the optional `fontFamily`, `fontPostScriptName`, `instanceWeight`, and `provenance` fields. |
| tvOS integration | `~/Developer/BookwormsApps/tvos`, private GitHub repository `ianhyzy/bookworms-tvos` | `SpineCloudStore`, worklist publication, design, cover-choice, series-link, and series-look fetch and caches, series-look creation, [Book Wall companion designs](../BOOK_WALL.md#companion-designs) and [series looks](../BOOK_WALL.md#series-links-and-looks) behind `BookPresentation.showsCompanionSpines`, and companion cover choices in every view behind `showsCompanionCovers`. |
| Retired Mac app (**Bookworms Spines**) | `~/Developer/BookwormsApps/macos`, archived repository `ianhyzy/bookworms-macos` | Make no changes there. The Apple TV still accepts its existing `mac-foundation-models-v2` designs as ordinary valid designs. |

## How the companion works

1. The Apple TV syncs the full Hardcover library and, with iCloud storage on, saves it to the `library-v1` archive in the private database of `iCloud.gay.ian.Bookworms`. The archive holds the full fetched library, not the displayed limit.
2. After that archive save, the TV publishes a `SpineWorklistV1` record (record name `spine-worklist-v1`, JSON in a `payload` data field) from the snapshot in the uploaded archive, not from memory, so the companion's sync-date match holds. It holds the active Hardcover account ID, the snapshot's sync date, and every book ID, sorted and deduplicated. A snapshot installed during the sync sets the pending flag, so the next loop iteration uploads it and republishes, even after a failed publish.
3. The TV publishes a nonempty list only while the Hardcover source is enabled with a connected, unexpired credential whose authenticated account matches the snapshot. It gates on local state (`hardcoverConnected`, `hardcoverEnabled`, `!hardcoverSessionExpired`, and the uploaded snapshot's account) and makes no Hardcover request before publishing. A connected credential's authenticated validate or fetch sets `activeHardcoverAccountID`; a credential-free restore can adopt the account the cloud worklist names, but that TV never lists work. A TV with an expired session or no credential publishes nothing and leaves the record unchanged. Disabling or disconnecting Hardcover publishes an empty list.
4. The companion subscribes to worklist changes. It reads book metadata from the matching account snapshot in `library-v1`, downloads each cover over HTTPS, and designs it; see the iOS app's README for the steps. It writes one `SpineDesignV1` record per book: background, foreground, and accent colors (`#RRGGBB`), a typeface (`serif`, `sans`, `rounded`, or `monospaced`), a weight (400–700), an uppercase flag, a work-item hash of the book metadata, a cover-content hash, a generator version, and, when one fits, a Google Fonts family and instance.
5. The TV validates designs in bounded batches (matching account, book, and work-item hash; foreground contrast at least 4.5:1; optional font fields bounded as on the iPhone) and caches them in `Caches/Bookworms/spine-designs-v1.json`, separate from the retained API-key design store. It reads designs at launch, on activation, and after each cloud sync, then publishes them to Book Wall, which downloads each design's Google Fonts face during preparation.
6. The TV shows the latest valid design for each book, whichever app made it. The iPhone keeps a design whose work-item and cover hashes still match and whose generator is `ios-pcc-v2`, and keeps a design whose colors the reader chose until the reader chooses another cover. It redesigns any other design, including a legacy Mac design.
7. Each book carries every Hardcover series it belongs to (`seriesMemberships`) in `library-v1`. The TV reads the companion's `SeriesLinkV1` records with the designs, then the `SeriesLookV1` records of the snapshot's look groups. It creates a missing look with a create-only save, from a group member's companion design or, for a group of two or more books without one, from Book Wall's cover-sampled look (origin `tvos-local-v1`). Whichever device saves a group's look first decides it. Book Wall draws the look on every member whose link doesn't keep its own look; see [series links and looks](../BOOK_WALL.md#series-links-and-looks).

The JSON contract lives in `ios/Bookworms/Models/CloudContract.swift` and `Bookworms/Services/SpineCloudStore.swift`. Keep them compatible; both pin the same digests.

## Contract comparison

Both sides encode `Date` with the default `JSONEncoder` strategy (seconds since 2001 as a number). Record types `SpineWorklistV1`, `SpineDesignV1`, `CoverChoiceV1`, `SeriesLinkV1`, and `SeriesLookV1`, the `payload` data field, the container ID, the worklist record name, the design record name (`spine-design-v1-` + SHA-256 of `accountID:bookID`), the cover-choice and series-link record names (`cover-choice-v1-` and `series-link-v1-` + SHA-256 of `accountID:bookID`), the series-look record name (`series-look-v1-` + SHA-256 of `accountID:seriesID:group`, where the group is the Discworld group or nothing, `|`, and the folded first author, such as `City Watch|terrypratchett`), the create-only series-look save, and the work-item hash (SHA-256 of account ID, book ID, title, author, detail cover URL, cover URL, joined by newlines) are identical, and both test suites pin the same digests. The contrast formula is the same WCAG relative-luminance ratio. The TV checks the optional font fields as the iPhone does. The table lists where the validators differ.

| Item | tvOS | iPhone | Effect |
| --- | --- | --- | --- |
| `SpineWorklistV1.accountID` length | No bound | At most 512 characters | None in practice; Hardcover IDs are short. |
| Worklist payload size | No bound | At most 5 MB | None in practice. |
| `coverHash` format | 64 hex digits, either case | 64 lowercase hex digits | None; the iPhone writes lowercase. The TV is looser. |
| `workItemHash` format | Must equal the TV's own lowercase SHA-256 | 64 lowercase hex digits | The TV check is stricter and binds the design to the book. After a metadata edit, the TV shows the local spine and the iPhone keeps showing the old design until the iPhone's next generation run saves a new one: a redesign, or a recolored spine saved again under the new hash. |
| Color hex case | `#` + 6 uppercase hex digits | Same | None; the iPhone emits uppercase. |
| `generatorVersion` | Any non-blank string | Any non-blank string; redesigns a design with the generator's colors unless it is `ios-pcc-v2` | None on the TV, which shows designs from any generator. |
| Archive size the iPhone reads | No bound on the TV | At most 50 MB | A very large archive stops the iPhone; the TV does not warn. |
| Extra `Book` fields | Encoded in `library-v1` | Ignored unless `CloudBook` declares them, such as `seriesName` and `seriesMemberships` | None. |

## Remaining steps

1. **Signed end-to-end check**: a signed iPhone or Mac and the Apple TV on one iCloud account. Confirm the worklist lists every book, a companion design reaches the TV cache with its font fields, and Book Wall shows it while other views show covers. See [testing](../TESTING.md).
2. **Privacy policy**: Book Wall now requests Google Fonts faces. Update the published policy and the [policy text](../RELEASING.md#apple-tv-privacy-policy-text) before uploading a candidate with `showsCompanionSpines` on.
3. **Deploy `SpineWorklistV1`, `SpineDesignV1`, `CoverChoiceV1`, `SeriesLinkV1`, and `SeriesLookV1`** (each with a `payload` Bytes field) to the production CloudKit schema before any TestFlight build uses them. See [releasing](../RELEASING.md).
4. **Design refresh cadence**: the TV refetches every design, cover-choice, series-link, and series-look record on launch, activation, and after each cloud sync. A new design or series look for a current-year book rebuilds Book Wall, even while it is on screen. Consider subscriptions with silent push, as the iPhone uses for the worklist.
5. **Validator alignment**: decide whether the TV should adopt the iPhone's lowercase-only `coverHash` and the account ID length bound.
6. **Live Hardcover check**: confirm that Hardcover accepts the library query's `compilation`, `books_count`, and `primary_books_count` fields. A rejected field fails the whole library query.

## Commands

| Purpose | Command |
| --- | --- |
| tvOS default verification | `xcrun swift-format lint --strict <file>`, then `python3 scripts/device-build.py` |
| tvOS tests (only when the owner asks) | `python3 scripts/test-worker.py --detach` |

## Constraints

- Follow each repository's `AGENTS.md`. The companion stays read-only toward Hardcover and has no tvOS view dependency.
- Keep one active Hardcover account. A worklist or design for another account must never mix into the active shelf.
- A worklist for an older snapshot must not replace a newer one for the same account.
- Unsigned builds prove compilation only, not iCloud access or push delivery.

## Open questions for the owner

- Disabling or disconnecting Hardcover on one Apple TV publishes an empty worklist, which pauses the companion for every TV on the iCloud account until another TV's next cloud sync republishes. Should a local disable clear the shared worklist?
- After a relaunch, a revoked credential can publish one nonempty worklist before the first failed refresh marks the session expired. The account is still the last authenticated one. Is that acceptable?
