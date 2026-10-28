# Interface design

Bookworms shows book covers on a wooden bookcase. Native tvOS navigation, focus, and system controls handle movement; see [focus and remote navigation](FOCUS_NAVIGATION.md). The shelf's generated spines, AI generation, and AI spine font restoration are disabled while their implementation and saved data remain; see [typography](SPINE_TYPOGRAPHY.md). Book Wall draws companion designs in their downloaded fonts; see [companion designs](BOOK_WALL.md#companion-designs).

## Navigation

A native sidebar lists the enabled views, then **Ambient** and **Settings**. Back, or Left from the leftmost item, opens it. Each view's own choices, such as the comparison reader and order, sit in its top-right header. **Settings** holds library, source, and app-wide choices in two-column sections. See [tvOS views](../VIEWS.md) for every view and option.

## Shelf

Covers stand on a shelf board: a receding top surface with a lit front edge that casts a soft shadow on the wall. A subtle contact shadow grounds each cover. Resting covers have no shadow of their own; the focused cover lifts and gains a shadow and a faint highlight, and Reduce Motion keeps it still. Keep shelf effects subtle and static: fade prebuilt shadows rather than animating blur.

My Shelf spreads full pages across the row. A last page with room to spare starts at the left with standard gaps. Empty shelf space stays empty while `BookPresentation.showsShelfPhotos` is off. Compare Shelves uses equal-width columns so books line up between its two rows.

On My Shelf, the caption shows the selected book's format icons and title, then its author, primary genre, and finish date, then its star rating. On Compare Shelves, the title, author, and a reading line with the format icon, format, and finish date sit beside a column of both readers' profile photos, names, and star ratings. Stars take the surrounding text color.

**Settings → General → Appearance** offers System, Light, and Dark. Light uses pale oak and Dark uses dark walnut, or a plain background when **Wood background** is off. See [texture credits](TEXTURE_CREDITS.md).

## Year in Review

Material tiles show the year's totals above a books-by-month bar chart and a panel of genres, the most-read author, and formats. Bars are gold, the chart's one accent color, and static. The year's covers stand on a shelf board below, in equal-width columns, with a caption for the focused book. The year menu sits in the top-right header.

## Details

Details show the full cover in its original proportions, title, author, description, completion date, personal rating, format, and length when available. Hardcover community ratings appear as an average and distribution chart. A description that doesn't fit ends with **Show more**, which opens the whole text full screen. Missing metadata is left out rather than invented or described as unavailable.

## Home Screen

The Top Shelf extension shows the first ten books of the selected shelf collection that have HTTPS artwork, split into **Now reading** and **Recently read**. **Now reading** follows **Settings → Shelf → Progress bars**: **Vertical** posters are drawn with the My Shelf light sweep, **Horizontal** uses the Top Shelf progress bar, and **Don't show** uses plain covers. Selecting a cover opens that book's details. The extension receives no API credentials.

## Visual review

Check both appearances on Apple TV at normal viewing distance: long titles, missing covers, partial shelves, Compare Shelves alignment, Reduce Motion, and focus restoration. Simulator screenshots help catch layout regressions but do not show real covers or TV-distance readability. See [testing](TESTING.md) and [icon assets](../design/icon/README.md).

See [social views and ambient mode](SOCIAL_VIEWS_AND_AMBIENT.md) for Feed, Compare Shelves, Book Club, Friends' Picks, and ambient playback.
