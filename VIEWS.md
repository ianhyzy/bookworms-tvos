# tvOS views

This file defines the available views and user options for tvOS. See [data sources](DATASOURCES.md) for data rules and limits.

## Main views

All five views are enabled by default. **Settings → Views** shows or hides every view except **My Shelf** in the sidebar. Preferences saved before **Year in Review** existed gain it once; turning it off afterward persists. The Ambient page chooses ambient views separately. Navigation uses native tvOS sidebar navigation (`TabView` with `.sidebarAdaptable`): a collapsed pill at the top left displays the current screen title and icon, expanding into a frosted glass sidebar overlay when navigating left from the leading item or pressing Back (<). The sidebar lists all enabled views, then **Ambient** and **Settings**. On tvOS 27 and later, the user's Hardcover avatar and display name appear above the list. Per-view choices appear on the view itself, in the top-right header for Year in Review, Compare Shelves, and Book Club, so they can change without leaving the view. **Settings** holds library, source, and app-wide choices in four sections: **Views**, **Shelf**, **Sources**, and **General**.

| View | Data source and content | User options |
| --- | --- | --- |
| **My Shelf** | Combined library from enabled Hardcover and Calibre Web Automated (CWA) sources. | In **Settings → Shelf**, choose **Read Books** (default), **Owned Books**, or **All Books**. Sort by **Date Read** (default), **Your Rating**, **Publication Year**, **Title**, **Author**, or **Length**; reverse the order; change **Books shown** with the minus and plus buttons in steps of five, from 5 to 40 (default 40). |
| **Year in Review** | Books from enabled sources with a recorded finish date, grouped by calendar year. Shows the year's books read, page total, average rating, busiest month, books per month, top genres, most-read author (when one has at least two books), and formats. A cover shelf below lists the year's books earliest first, with the focused book's title, rating, author, and reading line underneath. | In the top-right header, choose a year from every year with a finished book. The view opens on the most recent year each session. Open details from a cover. Enable or disable the view. Not available in ambient mode. |
| **Following** | Hardcover activity from followed readers. Shows the latest update per book, including available reader, status, rating, date, and review data. Displayed edge-to-edge in paged groups of 4 with directional paging chevrons and complete, non-truncated book titles. | Enable or disable the view. Open available reviews. Ordering is fixed: newest first. |
| **Compare Shelves** | Your Hardcover library and one followed reader's library, in independently paged rows. The caption shows the selected book's title, author, and reading line beside a card with both readers' profile photos, names, and star ratings. | In the top-right header, choose a reader (defaults to a random followed reader if unconfigured) and **Top rated · All time** (default) or **Recently read**. In **Settings → Views**, set the comparison limit with the minus and plus buttons in steps of five, from 5 to 40 (default 40). Enable or disable the view. |
| **Book Club** | Hardcover books that both you and the selected reader rated, with separate ratings and reviews. | Uses the same reader and count as **Compare Shelves** (synced across both screens). In the top-right header, choose a reader and sort by **Rating agreement** (default: highest average rating first) or **Rating disagreement** (largest rating difference first) via on-screen menu buttons; both options prioritize books with written review text from both readers before filling with other shared books. Review cards fill the bottom with uncluttered breathing room. Enable or disable the view; open long reviews or reveal spoilers. Spoiler visibility is an app-wide choice in **Settings → General**. |

My Shelf and Compare Shelves captions show a reading line: the format icon and name (**Physical**, **Audiobook**, **Ebook**, or **Physical & audiobook**), then the finish date.

Year in Review uses each book's most recent finish date, so a reread counts once, in the year of its latest finish. Page totals and averages skip books without page counts or ratings, and the tiles say how many books they cover. It ignores the **Settings → Shelf** collection and count.

My Shelf sorts dates and ratings highest first, titles and authors A–Z, and length shortest first. Missing values stay last, including when you reverse the order. CWA-only books appear under **Owned Books** or **All Books** because CWA does not provide reading history.

Social views require a connected, enabled Hardcover source and social permissions. Compare Shelves and Book Club default to a random followed reader when unconfigured, or you can choose a reader with the on-screen picker. In **Settings → General**, **Show spoilers for read books** controls whether review spoilers are always hidden (default) or automatically revealed for books marked as read in your connected Hardcover account. See [Hardcover setup](docs/HARDCOVER_AUTHENTICATION.md).

## Other displays

| Display | Data source | User options |
| --- | --- | --- |
| **Book details** | The selected book's prepared metadata and cached artwork. | Open from a cover. No independent source, filter, or ordering settings. |
| **Ambient mode** | Prepared content from the views chosen on the Ambient page that have content. | Select **Ambient** in the sidebar. On that page, choose which social views to include (all by default; Year in Review is not offered; **My Shelf** always plays, and hiding a view from the sidebar does not remove it), a view interval of 5, 10 (default), or 15 minutes and a session of 30 minutes, 1 hour, 2 hours, or **Until stopped** (default). Content changes every minute. Select **Start ambient mode** to begin. |
| **Home Screen Top Shelf** | Eligible books from the current shelf snapshot. CWA-only authenticated covers are excluded. | Uses My Shelf choices; no separate app settings. |

## Shared appearance

**Settings → General** provides **Serif** (default; New York, with regular text set at medium weight because it reads lighter than SF) or **Sans-serif** text throughout the app except Settings, which always uses the system font and shows a serif sample sentence beside the choice, **System** (default), **Light**, or **Dark** appearance, **Wood background** (enabled by default; toggle off for a plain dark or light background across all views), and four date formats: **Jan 01, 2026** (default), **01/31/2026**, **31/01/2026**, and **2026-01-31**. Dates use the selected format throughout the app. Ambient mode always uses a dark, dimmed presentation.

All views use covers. Generated-spine views and AI provider configuration remain disabled. See [navigation and rendering](docs/SOCIAL_VIEWS_AND_AMBIENT.md) for review and ambient behavior, and [focus and remote navigation](docs/FOCUS_NAVIGATION.md) for how the remote moves between items.
