# Social views and ambient mode

See [tvOS views](../VIEWS.md) for available views and user options, and [tvOS data sources](../DATASOURCES.md) for dataset rules, defaults, limits, and refresh behavior. This guide covers rendering and view-specific navigation. [Focus and remote navigation](FOCUS_NAVIGATION.md) defines how focus moves in every view and which patterns to avoid.

## Artwork

Generated-spine presentation and the AI provider settings tab are temporarily hidden. Every view uses full covers, including My Shelf and ambient playback, even when saved designs, fonts, and a provider key are present. All generation entry points and font restoration are disabled. The implementations, saved designs, fonts, and credentials remain intact.

Reader names appear with the reader's Hardcover profile photo, as on Hardcover, through the shared `ReaderLabel`; readers without a photo show a person symbol. Preparation downloads the owner's, feed readers', and the selected reader's photos. Covers retain their original proportions and remain uncropped. A shared cover component applies proportional corners and shadows in every view, including details and ambient playback. Interactive covers share the same focus lift, scale, highlight, shadow, and pressed dimming at every size; surrounding activity text does not scale. Reduce Motion suppresses movement and focus animation. The shared loader uses saved cover choices or catalog artwork from the source snapshot without extra Hardcover queries. CWA-only books use their source covers and authenticated source requests. Missing artwork uses a neutral title-and-author placeholder. Local analysis does not produce display fallback spines.

Shelf packing uses natural cover proportions and bounded spine dimensions. My Shelf and ambient shelves pack covers by width and spread full pages from edge to edge. Compare Shelves rows instead use equal-width columns sized for a typical 2:3 cover, so each book lines up with the book above or below it; a cover keeps its proportions and stands centered in its column. A last page with room to spare starts at the left edge with the standard gap. When at least 40% of that shelf is empty, a framed photo from the `ShelfPhoto` assets stands centered in the empty space. Each view picks a random photo when it appears, and ambient mode picks one for each content change. The two Compare Shelves shelves always show different photos. Focus fades between two fixed cover shadows instead of animating a blur, and a page change that follows another within 0.3 seconds jumps instead of animating, so fast input does not stack scroll animations. A single book is centered. Interactive rows keep a small inset from each edge so that focus lift is not clipped, and covers rest on the shelf's bottom edge. Packing waits for a pause in remote input and preserves book identity. Artwork requests share pending work, decode at the display's requested size, and use bounded memory and disk caches.

## Social navigation

- **Following:** Cards page horizontally in groups of four. Reader avatars stay beside names, with dates on a separate line. A separate button below a card opens written reviews; Down reaches it when present. Unknown events receive a generic reading-update summary.
- **Compare Shelves:** Ordering and reader selection menus appear in the top-right header, aligned vertically with the sidebar menu pill. Reader labels sit directly above the covers. Each row pages separately. Up and Down between rows keep the column: from the third book on one row, focus reaches the third book on the other row's visible page. Up from your row reaches the nearest header control. Captions place reader ratings below the author and include the other reader's cached rating even when the book is outside their displayed row.
- **Book Club:** A horizontal cover row sits above a title card and two review cards. Short reviews appear in full; longer reviews offer **Read review**. Spoilers require **Reveal review** unless automatically revealed by the user's spoiler policy for books read on Hardcover. That one press opens the review with spoilers shown; there is no second confirmation. Absent reviews say **No written review**. Down from a cover reaches the nearest review action when one exists; Up from a review action returns to the selected cover. Changing the sort order reorders the covers in place and shows the start of the list.

Missing social access leaves My Shelf available and places recovery instructions in Settings. Temporary failures preserve complete snapshots. Confirmed access denial removes inaccessible social content; refreshed follow lists remove unfollowed readers' cached data.

## Ambient mode

Select **Ambient** in the sidebar, then **Start ambient mode**. Stopping playback returns to that page. Ordinary inactivity does not disable Apple TV's screensaver or sleep behavior. Ambient playback rotates enabled views with usable content; it skips setup and empty screens.

Choose timing on the **Ambient** page; see [ambient options](../VIEWS.md#other-displays).

Ambient playback hides controls and selection markers, uses a dark palette with a 35% black overlay, and moves content within safe margins. Bookshelf textures change crop and orientation. Movement uses brief transitions; Reduce Motion removes animation. VoiceOver prevents or stops automatic playback. Spoilers remain hidden unless the spoiler policy is set to show for read books.

The first directional, Select, Back, or Play/Pause press exits without activating content. Exit, backgrounding, and session expiry restore the system idle timer. Playback does not sync source metadata, look up alternate covers, or generate spines. It reads artwork and avatars from the cache prepared for enabled collections, without starting downloads.

This is an in-app display mode, not a system screensaver replacement. Dimming and changing content reduce static exposure but cannot guarantee prevention of OLED burn-in.
