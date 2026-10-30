# Spine typography

Shelf spines letter by the iPhone and Mac app's rule (`SpineView.lettering(length:thickness:)` and its `SpineLettering` layout in that app), with the Apple TV's minimum sizes. `SpineTextMetrics` in [SpineTextMetrics.swift](../Bookworms/Services/SpineTextMetrics.swift) measures the rule with UIKit. Keep the shares and the author forms the same in both apps; each copy names the other.

The spine reads top to bottom: the title at the head, the author at the tail, both centered across the spine. A book with a format reserves the format icon's room at the tail (`formatIconRoom`, 38 points) before lettering the rest of the length. In that lettered length:

- Each end keeps a margin of 3.5% of the length plus 25% of the thickness. The title and author share a box 88% of the thickness tall, 30% of the thickness apart.
- The title stops at its first colon; the shelf spine draws no subtitle. It starts at the box's size, with no other cap, and shrinks on a half-point grid to the largest size that fits on one line or two, whichever is larger. Lines break only between words, at the break whose widest line is narrowest, so no word splits and a title without spaces keeps to one line. A title takes a third line only when one or two lines can't reach 23 points.
- The title first claims the width its one line needs at the box's size. The author gets the rest: at least 24% of the length, or its surname's width at the minimum size if that is wider, at most 40%, and no more than its form needs. The title takes back what the author leaves.
- The author lists the first name and "et al." for more than two names, or for two names longer than 32 characters. It takes the first form that fits: the name on one line, on two lines (two names one over the other, or one name broken before its surname), then the surname alone. Its large size, half the thickness, applies only where the title loses no size to it and stays at least 1.4 times its size; otherwise it letters at a little over a quarter of the thickness. Both sizes stop at 4% of the length and never fall below 16 points. The author is trailing-aligned.
- The title stays at least 4 points larger than the author: the author drops to the title's size less 4 points, but not below 16 points. A surname too long for the author's widest room truncates with an ellipsis; no other form truncates.

Titles target at least 23 points. When a title would letter smaller, `readableDimensions` lengthens the spine within the shelf's height and the book-shape bounds, then thickens it. Page packing uses the adjusted dimensions. Unusually long unbreakable text can still fall below 23 points in the bounded layout.

Lettering is measured once, when shelf pages are prepared (`BookPresentation.pages`), and carried in `ShelfPage.letterings`. `SpineView` draws each measured line at its measured size and face, without rewrapping or scaling, so focus changes and view updates never measure text. A face registered after preparation draws once the pages are prepared again for the new font revision; until then the spine draws the face it was measured in. Page layouts, per-book dimensions, and letterings are cached in bounded caches keyed by text, resolved face, and geometry.

UIKit supplies fonts at their rendered point size, retaining native optical sizing when a custom font supports it. The fitter confirms each size by measuring at that size.

## Design references

- [Apple typography guidance](https://developer.apple.com/design/human-interface-guidelines/typography): tvOS minimum sizes and testing custom fonts at viewing distance.
- [Apple: The details of UI typography](https://developer.apple.com/videos/play/wwdc2020/10175/): native optical sizing, tracking, and leading.

## Shelf controls and focus

Shelf focus, paging, and returns follow [focus and remote navigation](FOCUS_NAVIGATION.md). Settings and Ambient are sidebar items; the shelf has no controls below it.

The physical paging test accepts the current page boundary through `TEST_RUNNER_SHELF_LAST_BOOK_ID`, `TEST_RUNNER_SHELF_NEXT_BOOK_ID` in the xcodebuild environment. It starts a Debug build on page 2 using `--start-shelf-page=1`, uses the real library, checks both directions twice, verifies that backward focus persists, and checks that Right from the sidebar returns to the same book. Without those values it skips. The simulator navigation tests cover page transitions with sample data.
