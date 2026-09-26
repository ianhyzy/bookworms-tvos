# tvOS data sources

This file defines selectable sources, data preparation rules, and limits for tvOS. See [views](VIEWS.md) for display options.

## Available sources

Choose sources in **Settings → Sources**. The app supports one active account per provider and reads data without modifying either account or downloading ebook files.

| Source | Connection and default | Available data |
| --- | --- | --- |
| **Hardcover** | Personal access token. Enabled by default; requires connection. | Library books, authors, descriptions, covers, completion dates, reading status, personal ratings, publication years, page counts, formats, series, genres, and community ratings when available. Social access adds followed-reader profiles, avatars, activity, ratings, and reviews. |
| **Calibre Web Automated (CWA)** | HTTPS server and local username/password with OPDS access. Disabled by default, and hidden in Settings while `BookPresentation.offersCWA` is false; the client, saved configuration, and sync remain. | Owned ebooks, authors, descriptions, categories, publication dates, and authenticated cover URLs. No personal ratings or completion dates; catalog modification times are not reading dates. |

Hardcover library access requires `read:me:content`, `read:library`, and `read:catalog:data`. Social views also require `read:social` and `read:users`. See [authentication](docs/HARDCOVER_AUTHENTICATION.md) for token setup.

Credentials stay in Keychain. Disabling a source hides its books but retains its snapshot. iCloud is optional storage, off by default, rather than another selectable book provider; it stores source snapshots and saved designs, excluding credentials, images, and social snapshots. See [iCloud behavior](docs/SOURCES_AND_ICLOUD.md).

## Combining and deduplicating data

- **Hardcover library:** Deduplicate by Hardcover book ID, retaining the most recent reading record. Prefer the read edition's metadata, then the library edition or catalog metadata where available. For covers, skip images under 300 pixels on their shorter side and nearly square images, which are usually author photos or audiobook art, then prefer portrait art and the larger image; the reader's edition counts as 20% taller, so it wins unless the book's default cover is clearly sharper. Reader libraries choose covers the same way.
- **CWA catalog:** Derive stable IDs from the server address and catalog identifier in a separate ID range. Keep the first entry for each ID.
- **Combined shelf:** Match the full title and author string after normalizing case, accents, and whitespace. Use IDs instead when the title is empty or the author is unknown. Hardcover takes precedence; CWA adds ownership and missing metadata. Different normalized titles or author strings remain separate. Matching does not infer edition differences.
- **Following:** Deduplicate activity IDs, then retain the newest event per book across all followed readers. Break timestamp ties by descending activity ID. Events without books remain separate. Apply the display limit after deduplication.
- **Reader libraries:** Deduplicate profiles by reader ID and books by Hardcover book ID. For duplicate reader-library rows, the later row in ascending record-ID order wins. Fetch books with a rating or completion date. **Top rated · All time** requires a rating; **Recently read** requires a completion date. Ties use title, then book ID.
- **Year in Review:** Group the combined library by the year and month of each book's finish date; skip books without a valid date. Statistics use every book in the year. Genres count the first three genres of each book. The cover shelf keeps every book when the year has at most 40; otherwise it keeps the 40 highest rated (unrated last, ties by most recent finish), in reading order. The app recomputes all years when the library changes.
- **Book Club:** Intersect complete fetched reader libraries by Hardcover book ID before limiting results. Both ratings must be in the range 0–5. Sort by their sum, highest first, then title and ID. Keep each reader's review separate. CWA data does not supply social ratings.

## Display limits

Counts apply to each collection, not to the total cached library. Available data can produce fewer results. `BookLimit` in [ViewPreferences.swift](Bookworms/Models/ViewPreferences.swift) sets the default and maximum of 40 books. Users on older Apple TVs can lower the count.

| Collection | Default | Maximum and controls |
| --- | --- | --- |
| My Shelf | 40 books | 40; count controls step by five. |
| Following | Up to 20 activities | 20; fixed. Four cards fit in the viewport. |
| Compare Shelves | 40 books per reader | 40 per reader; count controls step by five. |
| Book Club | 40 books | 40; shares the comparison count. |
| Year in Review | Up to 40 covers for the chosen year | 40; fixed. Statistics include every book finished that year. |
| Home Screen Top Shelf | Up to 10 eligible books | 10; fixed. |
| Details and ambient | Selected book or prepared collection | No additional collection allowance. |

## Fetch limits and caching

These are implementation bounds, not user settings or provider quotas.

| Dataset | Request size | Safety bound |
| --- | --- | --- |
| Hardcover library | 100 rows per page | 100 pages / 10,000 rows. |
| Followed readers and each social reader library | 100 rows per page | 1,000 pages / 100,000 rows per dataset. |
| Following activity | Latest 100 events per group of up to 200 followed readers | One request per group; merge groups before deduplicating and selecting 20. Repeated books can leave fewer than 20 results. |
| CWA catalog | Server-defined OPDS page size | 500 pages and 50,000 entries before deduplication; reject paging loops. |

Hardcover pagination requires a short final page to confirm completion. Reaching its page bound with only full pages fails the sync. Incomplete or failed syncs preserve the previous complete snapshot.

Successful datasets stay fresh for 24 hours. Automatic checks run at startup or activation; failed attempts back off five minutes. **Settings → Sources → Sync now** bypasses freshness; **Settings → General → Sync social data** refreshes social datasets only. Manual requests have a ten-second cooldown.

Only views shown in the sidebar or chosen for ambient mode request their required social datasets. Year in Review needs no social data; the app prepares covers for the chosen year, and choosing another year prepares that year's covers. The app prepares artwork for entire displayed collections before browsing. Sorting, scrolling, details, and ambient playback use prepared data; they do not trigger per-book Hardcover queries. Concurrent requests share work. See [storage and performance](docs/STORAGE_AND_PERFORMANCE.md) for image-cache budgets and eviction rules.
