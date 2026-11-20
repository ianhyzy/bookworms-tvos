# Architecture

Bookworms is a Swift 6 application for tvOS 26 and later. SwiftUI provides the shelf, settings, and details. UIKit measures spine lettering by one rule for the retained shelf spines, which SwiftUI draws, and for Book Wall's spine textures. Generated-spine views and AI provider generation remain disabled. No companion rendering service is required. Optional iPhone and Mac companions prepare spine design records in private CloudKit. On supported Apple TV models, Book Wall draws a book's spine from its companion design when one exists and otherwise generates the spine texture from genre metadata and the selected cover image. See [Book Wall models, animation, and local spines](BOOK_WALL.md).

## Components

| Component | Responsibility |
| --- | --- |
| `BookwormsApp` | Own the library model, apply appearance settings, and respond to app and iCloud account changes. |
| `LibraryModel` | Coordinate source snapshots, shelf selection, font restoration, generation, and cloud sync. |
| `HardcoverClient`, `CWAClient` | Fetch read-only metadata and normalize transport responses into books. |
| `HardcoverSession` | Keep the Hardcover login in Keychain and run one token renewal at a time for library sync, social sync, and reviews. See [token renewal](HARDCOVER_AUTHENTICATION.md#token-renewal). |
| `ShelfPreferences`, `ShelfLayout`, `BookPresentation` | Filter and sort cached books, size them to bounded shapes, then pack them into pages. |
| `PagedRow`, `ShelfRow` | Present paged collections with every item mounted so that native focus crosses pages. See [focus and remote navigation](FOCUS_NAVIGATION.md). |
| `ArtworkStore` | Cache and downsample artwork, share downloads, and select suitable full covers. |
| `BookWallPreparation`, `BookWallRasterizer` | Prepare companion fonts, the current-year layout, companion or local spine textures, cover textures, and each page's meshes and uploaded textures (`BookMetalPage`) before presentation. Drawing, mesh building, and uploads run off the main actor. |
| `BookWallScene`, `BookWallFall`, `BookWallFlight` | Hold the wall's state as plain values: camera framing, focus frames, the focused and open book, flight planning, and where the label, ribbon, and shadows go. Give the fall and a flight as functions of time. |
| `BookMetalWallView`, `BookMetalWallHost`, `BookMetalRenderer`, `BookMetalPage`, `BookWallHardcoverMesh` | Build each book's mesh, and draw the wall with Metal from a display link on its own thread. See the [Metal renderer](BOOK_WALL.md#metal-renderer). |
| `AIStyleGenerator`, `GoogleFontLibrary` | Match covers against the full font catalog and download licensed fonts for retained AI designs and Book Wall companion designs. |
| `AutomaticSpineGeneration`, `AIStyleStore` | Select missing designs, record attempt cooldowns, and retain completed designs. |
| `CloudLibraryStore`, `SourceLibraryStore` | Merge cloud archives and persist source snapshots and sync schedules. |
| `SpineCloudStore` | Publish the complete Hardcover worklist without replacing another account's; copy another account's records for **Merge**; validate and cache companion designs, series links, and series looks for Book Wall and companion cover choices for every view; create missing series looks without replacing saved ones; and save or delete the series link a reader picks in book details. |
| `TopShelfSnapshot`, `ContentProvider` | Share public cover metadata with the Home Screen extension and open book details through validated links. |

Source code is in [Bookworms](../Bookworms), [BookwormsTopShelf](../BookwormsTopShelf), and [Shared](../Shared). The [XcodeGen configuration](../project.yml) defines targets, signing identifiers, and test plans.

## Data flow

1. Load settings and cached source snapshots, clamping displayed collections to their configured limits.
2. Refresh enabled sources and social datasets when due or explicitly requested. With iCloud storage on, a due automatic library check reads the cloud archive first, for up to 10 seconds, and fetches only the sources still due. Missing caches recover independently of daily freshness; failed requests use a short backoff.
3. Merge source metadata and compute the selected shelves and shared-book intersections.
4. Prepare covers and feed avatars for enabled bounded collections using existing cover URLs. Book Wall preparation starts from the loaded current-year snapshot; opening the wall waits if its textures and models are not ready. Share source downloads and persist one reusable image per URL.
5. Mount library views. Paging, details, and ambient playback read caches without network calls; selecting the details ratings fetches community reviews.
6. Save snapshots and queue cloud updates. Each sync checks that iCloud holds no other, unmerged Hardcover account's data, and pauses for the reader's answer when it does. After a complete Hardcover snapshot reaches CloudKit, publish its account-specific spine worklist. With iCloud storage on and the account check clear, read and cache companion designs, cover choices, series links, and series looks separately at launch, on activation, and after each cloud save, then create missing series looks. Before the check clears, show only the disk cache of this Apple TV's own account. A cover choice becomes the displayed book's first cover. Spine generation for the retained views and spine font restoration remain disabled; their implementation and data are retained. Book Wall draws spines from series looks and the active companion designs and generates the rest locally from cover pixels and genre metadata.

Service actors own asynchronous I/O and caches. The main-actor library model publishes UI state. Internal task handles and caches are excluded from Observation to avoid unrelated view updates.

`ShelfView` retains one `BookWallScene` across views and detail presentations. Its renderer mounts behind the native `NavigationSplitView` in its background, keeps native focus controls in `BookWallView`, and uses full-screen point coordinates. The scene holds state and draws nothing; `BookMetalWallHost` hands the renderer what the scene shows, as plain values.

The Metal renderer owns a `CAMetalDisplayLink` on its own thread and draws into the drawables of an opaque Metal layer tagged as Display P3 with the sRGB transfer curve. It takes each page's buffers and textures as preparation made them, plays the fall, flights, and drift by presentation time, and reports landings and flight ends back to the main actor. Its link pauses while nothing moves, so a still wall keeps its last frame.

`BookwormsCoordinator` owns enabled views and per-view navigation. `HardcoverSocialClient` uses fixed read queries; `SocialLibraryModel` keeps reader-specific snapshots and daily attempt gates outside iCloud. `AmbientController` advances an injectable clock without source or AI dependencies. See [social views and ambient mode](SOCIAL_VIEWS_AND_AMBIENT.md).

## Boundaries

Credentials stay in Keychain and are not included in cloud archives, worklists, designs, or Top Shelf snapshots. Hardcover exposes fixed GraphQL read queries and returns the authenticated account ID with each complete library fetch. CWA fetches OPDS metadata and covers, not ebook files. Sample-library tests use fictional books and local responses.

Operational errors appear in Settings. The shelf remains available from cached data when a network service fails. See [sources and iCloud](SOURCES_AND_ICLOUD.md), [storage policies](STORAGE_AND_PERFORMANCE.md), and [testing](TESTING.md).
