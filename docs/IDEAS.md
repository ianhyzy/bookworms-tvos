# Feature ideas

This file lists proposed features. None of them is implemented unless [views](../VIEWS.md) or [data sources](../DATASOURCES.md) describe it. When a feature ships, document it there and remove it here.

Each idea notes the data it needs. "Synced" means the Hardcover library or social sync already fetches it; "New query" means a new request or field, which must keep library access read-only and stay out of browsing and focus handling.

## Current reads

- **Progress on the Book Wall.** The wall's ribbon currently marks focus. Proposed: current reads always carry a ribbon whose length shows progress, and focus uses a different cue. Alternative: a brass spine tab shows the percentage. Data: synced.
- **Audiobook progress.** Divide `progress_seconds` by the edition's audio length. Data: new field; confirm the edition length field in Hardcover's schema first.

## Reading goal worm

A small worm crawls along the My Shelf board from left to right as you progress toward your yearly reading goal. For example, it shows 18 of 30 books at 60% of the shelf width. The worm stays static between syncs and respects Reduce Motion. Data: new query for the Hardcover reading goal; books finished this year are synced.

## Split-flap board

A 3D split-flap display, like a Vestaboard, spells out the titles of your most recently read books. Each title flips in letter by letter, and the board suits ambient mode. Reduce Motion replaces the flips with a fade. Data: synced.

## Series

Book details show the series and its books. Still open: a series shelf that groups your series with progress, such as "3 of 7 read", and the next unread book.

## Authors

- Select an author in book details to see their bio, photo, and the other books in your library.
- Show the author's other works you haven't read.

Data: library books by author are synced; bios, photos, and other works need a new query.

## Year in Review

- An all-time view and a comparison of two years.
- Your ratings compared with community ratings, such as "you rated this ★5, the community ★3.2."
- A fullscreen "Wrapped" slideshow at the end of the year, which could also play in ambient mode.

Data: synced.

## Reader leaderboard

Rank readers by books and pages read this year. Include only people you follow, or only mutuals. Data: followed readers' libraries are synced; mutuals need a new query for followers.

## Other ideas

- **Taste match:** a rating-overlap score for each followed reader, used to sort the reader picker.
- **Want to read shelf** with a **Pick for me** button.
- **Ambient overlays,** such as a clock or date.
- **Multiple Apple TV users:** follow the tvOS user profile so each household member sees their own Hardcover shelf.
