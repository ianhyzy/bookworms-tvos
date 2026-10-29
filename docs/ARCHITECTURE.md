# Architecture

Bookworms is a Swift 6 application for tvOS 26 and later. SwiftUI provides the shelf, settings, and details. UIKit and Core Text measure and render the retained spine implementation. Generated-spine views and AI provider generation remain disabled. No companion rendering service is required. Optional iPhone and Mac companions prepare spine design records in private CloudKit. On supported Apple TV models, Book Wall draws a book's spine from its companion design when one exists and otherwise generates the spine texture from genre metadata and the selected cover image. See [Book Wall models, animation, and local spines](BOOK_WALL.md).

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
| `BookWallPreparation`, `BookWallRasterizer` | Prepare companion fonts, the current-year layout, companion or local spine textures, cover textures, and reusable hardcover entities before presentation. |
| `BookWallScene`, `BookWallHardcoverMesh` | Construct shared hardcover models; own physics, camera geometry, synchronized camera/book motion, baked backdrops, shadow planes, and point and directional lighting. |
| `BookWallRenderHost`, `BookWallRendererView`, `BookWallRendererCoordinator` | Render the shared wall through RealityRenderer with explicit Metal texture dimensions. See the [renderer host](BOOK_WALL.md#renderer-host). |
| `AIStyleGenerator`, `GoogleFontLibrary` | Match covers against the full font catalog and download licensed fonts for retained AI designs and Book Wall companion designs. |
| `AutomaticSpineGeneration`, `AIStyleStore` | Select missing designs, record attempt cooldowns, and retain completed designs. |
| `CloudLibraryStore`, `SourceLibraryStore` | Merge cloud archives and persist source snapshots and sync schedules. |
| `SpineCloudStore` | Publish the complete Hardcover worklist; validate and cache companion designs, series links, and series looks for Book Wall and companion cover choices for every view; create missing series looks without replacing saved ones; and save or delete the series link a reader picks in book details. |
| `TopShelfSnapshot`, `ContentProvider` | Share public cover metadata with the Home Screen extension and open book details through validated links. |

Source code is in [Bookworms](../Bookworms), [BookwormsTopShelf](../BookwormsTopShelf), and [Shared](../Shared). The [XcodeGen configuration](../project.yml) defines targets, signing identifiers, and test plans.

## Data flow

1. Load settings and cached source snapshots, clamping displayed collections to their configured limits.
2. Refresh enabled sources and social datasets when due or explicitly requested. With iCloud storage on, a due automatic library check reads the cloud archive first, for up to 10 seconds, and fetches only the sources still due. Missing caches recover independently of daily freshness; failed requests use a short backoff.
3. Merge source metadata and compute the selected shelves and shared-book intersections.
4. Prepare covers and feed avatars for enabled bounded collections using existing cover URLs. Book Wall preparation starts from the loaded current-year snapshot; opening the wall waits if its textures and models are not ready. Share source downloads and persist one reusable image per URL.
5. Mount library views. Paging, details, and ambient playback read caches without network calls; selecting the details ratings fetches community reviews.
6. Save snapshots and queue cloud updates. After a complete Hardcover snapshot reaches CloudKit, publish its account-specific spine worklist. With iCloud storage on, read and cache companion designs, cover choices, series links, and series looks separately at launch, on activation, and after each cloud save, then create missing series looks. A cover choice becomes the displayed book's first cover. Spine generation for the retained views and spine font restoration remain disabled; their implementation and data are retained. Book Wall draws spines from series looks and the active companion designs and generates the rest locally from cover pixels and genre metadata.

Service actors own asynchronous I/O and caches. The main-actor library model publishes UI state. Internal task handles and caches are excluded from Observation to avoid unrelated view updates.

`ShelfView` retains one `BookWallScene` across tab and detail presentations. Its RealityRenderer host mounts behind the native `TabView` in its background, keeps native focus controls in `BookWallView`, uses full-screen point coordinates, and shares prepared scene entities. The host adapter supplies events, projection, and environment intensity. Resolution and comparison settings are launch arguments, not saved user options.

The RealityRenderer adapter owns a display link and an opaque Metal layer tagged as Display P3 with the sRGB transfer curve. RealityRenderer renders into one of three slot textures, never into a layer drawable: on Apple TV, rendering straight into drawables dropped much of the scene during detail flights. Each frame signals its slot's Metal event after RealityKit's work; a background queue then takes a drawable, draws the texture into it, scaled when the internal size is smaller, and presents it. Taking the drawable only then keeps drawables available while RealityKit finishes a frame as it encodes the next. The presentation buffer's completion releases the slot. Standard dynamic range and 4× multisampling are the defaults; `--wall-antialiasing=off` disables multisampling. The display link requests 60 Hz, but actual presentation requires [separate verification](TESTING.md#renderer-host-checks).

`BookwormsCoordinator` owns enabled views and per-view navigation. `HardcoverSocialClient` uses fixed read queries; `SocialLibraryModel` keeps reader-specific snapshots and daily attempt gates outside iCloud. `AmbientController` advances an injectable clock without source or AI dependencies. See [social views and ambient mode](SOCIAL_VIEWS_AND_AMBIENT.md).

## Boundaries

Credentials stay in Keychain and are not included in cloud archives, worklists, designs, or Top Shelf snapshots. Hardcover exposes fixed GraphQL read queries and returns the authenticated account ID with each complete library fetch. CWA fetches OPDS metadata and covers, not ebook files. Sample-library tests use fictional books and local responses.

Operational errors and generation progress appear in Settings. The shelf remains available from cached data when a network service fails. See [sources and iCloud](SOURCES_AND_ICLOUD.md), [storage policies](STORAGE_AND_PERFORMANCE.md), and [testing](TESTING.md).
