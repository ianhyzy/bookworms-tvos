# Storage and performance

The app reuses source metadata, paid design choices, images, fonts, and text measurements. These policies limit repeated work; they do not guarantee a particular frame rate or provider billing discount.

## Storage policies

| Data | Policy |
| --- | --- |
| Social snapshots | Local account-specific snapshots, outside iCloud. Fetch only datasets required by views in the sidebar or ambient mode. Successful datasets stay fresh for a day; missing caches can recover sooner and failed attempts back off five minutes. |
| Source snapshots | Cached per source. Successful snapshots stay fresh for 24 hours. Both explicit Refresh controls bypass freshness, with a ten-second manual cooldown. Failed attempts preserve the complete snapshot. |
| AI design records | Small collections are copied to preferences and disk. Larger collections require a successful cloud save before relying on storage beyond the preferences budget. |
| Cloud archive | Source snapshots and designs in a private CloudKit asset. Conditional saves merge concurrent changes; unchanged archives skip upload. Credentials and font/image binaries are excluded. |
| Credentials | Device-only Keychain entries. Custom AI credentials are scoped to the exact endpoint. |
| Artwork | One reusable source per URL, downsampled to at most 2400 pixels, with a 180 MB disk pruning budget. |
| Decoded covers | `NSCache` with a 120 MB cost limit and 64-image count limit, keyed by cover and size bucket (400, 800, 1200, 1800, or 2400 pixels). The system may evict entries sooner. |
| Google Fonts catalog | Seven-day disk cache. A validated stale catalog can serve as a fallback after a network failure. |
| Downloaded fonts | Reconstructible files and licenses. Spine font restoration is disabled; existing files and paid choices are retained. |
| API usage | The latest 200 recorded requests, including status, duration, and provider-reported token counts. No credentials, prompts, or book data. CWA catalog requests are not included. |

The design store checks capacity before a paid request and checks the serialized size when saving. Local cache files are purgeable. Preferences are not an uninstall recovery mechanism; iCloud restoration requires the same Apple account and an available archive.

## Request reuse

Concurrent artwork requests share the source download. Smaller render sizes are derived from the same disk source, including after relaunch. Preparation reuses legacy cached files. Cover URLs come from source snapshots; there are no rendering-time Hardcover lookups. Each book has a preferred cover and, when available, an alternate that is tried if the preferred one fails. Failed downloads back off five minutes.

The app prepares artwork and feed avatars for complete enabled collections before mounting the interactive content. Preparation stores each cover on disk and reads its proportions from the image header without decoding pixels. Each shelf, comparison row, feed, and shared-read collection is capped at 20 items. Rendering and ambient playback are cache-only, so scrolling and opening details cannot start downloads. Covers that fail are retried once, 30 seconds after preparation, and the failure count is logged in the **Artwork** category. Missing images show placeholders; preparation runs again when data changes or the app refreshes/reactivates. Complete library snapshots are still needed to rank books and compute intersections correctly.

All automatic and explicit spine generation is disabled. Provider implementations, prompt construction, saved design records, and their tests are retained but cannot be invoked through the app's generation entry points.

## Rendering

Artwork decoding runs away from the main actor and the artwork actor. Each cover decodes at the smallest size bucket that covers its on-screen height in pixels, so ambient covers on a 4K display use larger images than shelf rows. A cover shows the nearest cached size at once and replaces a smaller one with the exact size. Typography, shaped author lines, and page layouts use bounded caches that include font-registration revisions in their keys. Focus changes reuse those layouts. Shadows apply to the simple book shape, and focus lighting uses a gradient.

Profile optimized Release builds on Apple TV. Capture a repeatable sequence of launch, paging, detail opening, scrolling, and Back navigation. Compare the same workload and retain Instruments traces with the tested build. Coverage-instrumented tests and simulator timings do not establish device performance.

See [testing](TESTING.md) and [Apple's SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).

## Ambient availability

Ambient mode reuses its eligible-view list until the source book IDs or social snapshot revision changes. The one-second timing check does not repeat comparison sorting or full-library intersections. This preserves content updates while avoiding work during idle playback.
