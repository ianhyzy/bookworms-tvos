# Interface design

Bookworms shows book covers on a wooden bookcase. Native tvOS navigation, focus, and system controls handle movement; see [focus and remote navigation](FOCUS_NAVIGATION.md). Generated spines, spine fonts, and AI generation are disabled while their implementation and saved data remain; see [typography](SPINE_TYPOGRAPHY.md).

## Navigation

A native sidebar lists the enabled views, then **Ambient** and **Settings**. Back, or Left from the leftmost item, opens it. Each view's own choices, such as the comparison reader and order, sit in its top-right header. **Settings** holds library, source, and app-wide choices in two-column sections. See [tvOS views](../VIEWS.md) for every view and option.

## Shelf

Covers stand on a shelf board: a receding top surface with a lit front edge that casts a soft shadow on the wall. A subtle contact shadow grounds each cover. Resting covers have no shadow of their own; the focused cover lifts and gains a shadow and a faint highlight, and Reduce Motion keeps it still. Keep shelf effects subtle and static: fade prebuilt shadows rather than animating blur.

My Shelf spreads full pages across the row. A last page with room to spare starts at the left with standard gaps, and when at least 40% of it is empty, a random framed photo stands in the space. Compare Shelves uses equal-width columns so books line up between its two rows.

The caption shows the selected title, the author (with genres on My Shelf), and a reading line with the format icon, format, and finish date. On Compare Shelves, a material card beside the caption shows both readers' profile photos, names, and gold star ratings.

**Settings → General → Appearance** offers System, Light, and Dark. Light uses pale oak and Dark uses dark walnut, or a plain background when **Wood background** is off. See [texture credits](TEXTURE_CREDITS.md).

## Details

Details show the full cover in its original proportions, title, author, description, completion date, personal rating, format, and length when available. Hardcover community ratings appear as an average and distribution chart. Up and Down scroll long descriptions directly. Missing metadata is described as unavailable rather than invented.

## Home Screen

The Top Shelf extension shows the first ten books of the selected shelf collection that have HTTPS artwork. Selecting a cover opens that book's details. The extension receives no API credentials.

## Visual review

Check both appearances on Apple TV at normal viewing distance: long titles, missing covers, partial shelves with photos, Compare Shelves alignment, VoiceOver labels, Reduce Motion, and focus restoration. Simulator screenshots help catch layout regressions but do not show real covers or TV-distance readability. See [testing](TESTING.md) and [icon assets](../design/icon/README.md).

See [social views and ambient mode](SOCIAL_VIEWS_AND_AMBIENT.md) for Following, Compare Shelves, Book Club, and ambient playback.
