# Architecture

Bookworms is a Swift 6 application for tvOS 26 and later. SwiftUI provides the shelf, settings, and details. UIKit and Core Text measure and render custom spine lettering. Core Graphics prepares cover and font samples for the selected AI provider. No companion rendering service is required.

## Components

| Component | Responsibility |
| --- | --- |
| `BookwormsApp` | Own the library model, apply appearance settings, and respond to app and iCloud account changes. |
| `LibraryModel` | Coordinate source snapshots, shelf selection, font restoration, generation, and cloud sync. |
| `HardcoverClient`, `CWAClient` | Fetch read-only metadata and normalize transport responses into books. |
| `ShelfPreferences`, `ShelfLayout` | Filter and sort cached books, then pack bounded book shapes into pages. |
| `PagedRow`, `ShelfRow` | Present paged collections with every item mounted so that native focus crosses pages. See [focus and remote navigation](FOCUS_NAVIGATION.md). |
| `ArtworkStore` | Cache and downsample artwork, share downloads, and select suitable full covers. |
| `AIStyleGenerator`, `GoogleFontLibrary` | Match covers against the full font catalog and download licensed font candidates. |
| `AutomaticSpineGeneration`, `AIStyleStore` | Select missing designs, record attempt cooldowns, and retain completed designs. |
| `CloudLibraryStore`, `SourceLibraryStore` | Merge cloud archives and persist source snapshots and sync schedules. |
| `TopShelfSnapshot`, `ContentProvider` | Share public cover metadata with the Home Screen extension and open book details through validated links. |

Source code is in [Bookworms](../Bookworms), [BookwormsTopShelf](../BookwormsTopShelf), and [Shared](../Shared). The [XcodeGen configuration](../project.yml) defines targets, signing identifiers, and test plans.

## Data flow

1. Load settings and cached source snapshots, clamping displayed collections to 20 items.
2. Refresh enabled sources and social datasets when due or explicitly requested. Missing caches recover independently of daily freshness; failed requests use a short backoff.
3. Merge source metadata and compute the selected shelves and shared-book intersections.
4. Prepare covers and feed avatars for every enabled bounded collection using existing cover URLs. Share source downloads and persist one reusable image per URL.
5. Mount cover-only views. Paging, details, and ambient playback read caches without network calls.
6. Save snapshots and queue cloud updates. Spine generation and spine font restoration remain disabled; their implementation and data are retained.

Service actors own asynchronous I/O and caches. The main-actor library model publishes UI state. Internal task handles and caches are excluded from Observation to avoid unrelated view updates.

`BookwormsCoordinator` owns enabled views and per-view navigation. `HardcoverSocialClient` uses fixed read queries; `SocialLibraryModel` keeps reader-specific snapshots and daily attempt gates outside iCloud. `AmbientController` advances an injectable clock without source or AI dependencies. See [social views and ambient mode](SOCIAL_VIEWS_AND_AMBIENT.md).

## Boundaries

Credentials stay in Keychain and are not included in cloud archives or Top Shelf snapshots. Hardcover exposes fixed GraphQL read queries. CWA fetches OPDS metadata and covers, not ebook files. Sample-library tests use fictional books and local responses.

Operational errors and generation progress appear in Settings. The shelf remains available from cached data when a network service fails. See [sources and iCloud](SOURCES_AND_ICLOUD.md), [storage policies](STORAGE_AND_PERFORMANCE.md), and [testing](TESTING.md).
