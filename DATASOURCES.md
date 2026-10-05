# tvOS data sources

This file defines selectable sources, data preparation rules, and limits for tvOS. See [views](VIEWS.md) for display options.

## Available sources

Choose sources in **Settings → Sources**. The app supports one active account per provider and reads data without modifying either account or downloading ebook files.

| Source | Connection and default | Available data |
| --- | --- | --- |
| **Hardcover** | Personal access token. Enabled by default; requires connection. | Library books, authors, descriptions, covers, completion dates, reading status, page progress and start date of current reads, personal ratings, publication years, page counts, audiobook listening times, formats, series, genres, and community ratings when available. Social access adds followed-reader profiles, avatars, activity, ratings, and reviews. |
| **Calibre Web Automated (CWA)** | HTTPS server and local username/password with OPDS access. Disabled by default, and hidden in Settings while `BookPresentation.offersCWA` is false; the client, saved configuration, and sync remain. | Owned ebooks, authors, descriptions, categories, publication dates, and authenticated cover URLs. No personal ratings or completion dates; catalog modification times are not reading dates. |

Hardcover library access requires `read:me:content`, `read:library`, and `read:catalog:data`. Social views also require `read:social` and `read:users`. See [authentication](docs/HARDCOVER_AUTHENTICATION.md) for token setup.

Credentials stay in Keychain. Disabling a source hides its books but retains its snapshot. Complete Hardcover snapshots carry the authenticated account ID, so a replacement credential cannot combine books from different Hardcover accounts. iCloud is optional storage, off by default, rather than another selectable book provider; it stores source snapshots and saved designs, excluding credentials, images, and social snapshots. See [iCloud behavior](docs/SOURCES_AND_ICLOUD.md).

## Combining and deduplicating data

- **Hardcover library:** Deduplicate by Hardcover book ID, retaining the most recent reading record. Prefer the read edition's metadata, then the library edition or catalog metadata where available. For covers, consider the reader's edition, the book's default image, and the book's five most-read editions with images that are in the Apple TV's language or have no language recorded. Skip images under 300 pixels on their shorter side and nearly square images, which are usually author photos or audiobook art, then prefer portrait art and the larger image; the reader's edition counts as 20% taller, so it wins unless another cover is clearly sharper. A reader's edition in another language gets no preference and is used only when nothing else can serve as a cover. When no portrait cover remains, use the largest square image of at least 300 pixels rather than none. Reader libraries in Compare Shelves and Book Club, including yours, choose covers the same way.
- **Current reads:** A book is a current read when its Hardcover status is **Currently Reading**. Progress is the latest unfinished read's logged pages divided by the page count of that read's edition, then the library edition, then the book, capped at 100%. Reads logged only in audio time have no progress.
- **CWA catalog:** Derive stable IDs from the server address and catalog identifier in a separate ID range. Keep the first entry for each ID.
- **Combined shelf:** Match the full title and author string after normalizing case, accents, and whitespace. Use IDs instead when the title is empty or the author is unknown. Hardcover takes precedence; CWA adds ownership and missing metadata. Different normalized titles or author strings remain separate. Matching does not infer edition differences.
- **Following:** Deduplicate activity IDs, then retain the newest event per book across all followed readers. Break timestamp ties by descending activity ID. Events without books remain separate. Apply the display limit after deduplication.
- **Reader libraries:** Deduplicate profiles by reader ID and books by Hardcover book ID. For duplicate reader-library rows, the later row in ascending record-ID order wins. Fetch books with a rating or completion date. **Top rated · All time** requires a rating; **Recently read** requires a completion date. Ties use title, then book ID.
- **Year in Review:** Group the combined library by the year and month of each book's finish date; skip books without a valid date. Statistics use every book in the year. Genres count the first three genres of each book. The cover shelf keeps every book when the year has at most 40; otherwise it keeps the 40 highest rated (unrated last, ties by most recent finish), in reading order. The app recomputes all years when the library changes.
- **Series:** The library query records each book's featured series and position. Each sync then fetches those series' names and main books in batches of 50, keeping the most-read book at each whole-number position and only HTTPS covers. A failed series request leaves the library sync complete and keeps the previously synced series. Their covers go to the browsing artwork tier in the background after library covers are prepared; see [storage and performance](docs/STORAGE_AND_PERFORMANCE.md).
- **Friends' Picks:** Combine ratings of 4–5 from synced followed-reader libraries and feed activity, one rating per reader and book. Leave out books in your Hardcover library that you finished or marked read. Friends' Picks downloads the feed even when Following is off. Rank by the number of readers, then average rating, then title and ID. Each day, download the libraries of up to 10 followed readers, most feed activity first, then following order; each library uses the same daily gate as Compare Shelves.
- **Book Club:** Intersect complete fetched reader libraries by Hardcover book ID before limiting results. Both ratings must be in the range 0–5. Sort by their sum, highest first, then title and ID. Keep each reader's review separate. CWA data does not supply social ratings.

## Display limits

Counts apply to each collection, not to the total cached library. Available data can produce fewer results. `BookLimit` in [ViewPreferences.swift](Bookworms/Models/ViewPreferences.swift) sets the default and maximum of 40 books. Users on older Apple TVs can lower the count.

| Collection | Default | Maximum and controls |
| --- | --- | --- |
| My Shelf | 40 books | 40; count controls step by five. |
| Following | Up to 20 activities | 20; fixed. Four cards fit in the viewport. |
| Compare Shelves | 40 books per reader | 40 per reader; count controls step by five. |
| Book Club | 40 books | 40; shares the comparison count. |
| Friends' Picks | 40 books from up to 10 readers' libraries | 40 books and 10 readers; fixed. |
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

Hardcover requests that fail with a server error, timeout, or dropped connection retry after about 2 and then 4 seconds; a rate limit retries once its Retry-After passes if that is at most 30 seconds away. Successful datasets stay fresh for 24 hours. Automatic checks run at startup or activation; failed attempts back off five minutes. **Settings → Sources → Sync now** syncs the library and then social data, bypassing freshness. It is unavailable while Hardcover rejects the saved login and no other source can sync; reconnect Hardcover first. Manual requests have a ten-second cooldown.

Only views shown in the sidebar or chosen for ambient mode request their required social datasets. Year in Review needs no social data; the app prepares covers for the chosen year, and choosing another year prepares that year's covers. The app prepares artwork for entire displayed collections before browsing. Sorting, scrolling, details, and ambient playback use prepared data; they do not trigger per-book Hardcover queries. The one exception is an explicit request: selecting the rating histogram in details fetches that book's community reviews. Concurrent requests share work. See [storage and performance](docs/STORAGE_AND_PERFORMANCE.md) for image-cache budgets and eviction rules.
