# Spine typography

Spine titles target at least 23 points. The fitter first wraps the main title and borrows label space, then increases book height within the shelf bounds. If height is insufficient, it increases width within the existing book-shape limits. Page packing includes these adjusted dimensions. Unusually long unbreakable text can still exceed the bounded layout; subtitles retain their separate sizing policy.

Font matching preserves the cover's selected family. Apparent-size adjustment compares the font's x-height with the system font for mixed-case labels, or cap height for uppercase labels. Partial normalization preserves differences between faces. Ink density supplies a smaller secondary adjustment; its five buckets measure visual weight, not reading ability. Final adjustments are bounded to 6% for authors and 3% for titles, and cannot shrink a title across its minimum.

Author names use Core Text shaping and word wrapping. Each line is positioned using its actual glyph bounds, with a visible gap of 12% of the font size (at least 2 points). This avoids font-wide blank space reserved for unused accents or flourishes. It preserves kerning and ligatures instead of changing tracking in connected scripts. Author labels use their own fitting bounds; the 23-point title target does not apply to author labels or subtitles.

UIKit supplies fonts at their rendered point size, retaining native optical sizing when a custom font supports it. Static fonts have no optical-size or grade axes to adjust.

Page layouts, per-book dimensions, fitted sizes, shaped author lines, and ink measurements are cached. Page-layout cache keys include book metadata, style choices, geometry, and font-registration revision. Focus and idle-control changes reuse the layout.

## Design references

- [Apple typography guidance](https://developer.apple.com/design/human-interface-guidelines/typography): tvOS minimum sizes and testing custom fonts at viewing distance.
- [Apple: The details of UI typography](https://developer.apple.com/videos/play/wwdc2020/10175/): native optical sizing, tracking, and leading.
- [W3C font-size-adjust](https://www.w3.org/TR/css-fonts-5/#font-size-adjust-prop): apparent-size normalization using x-height or cap height.
- [Adobe: Using Type in Design](https://blog.adobe.com/en/publish/2018/01/11/using-type-design-avoid-common-mistakes): preserve connections in script fonts and allow sufficient space between lines.

## Shelf controls and focus

Shelf focus, paging, and returns follow [focus and remote navigation](FOCUS_NAVIGATION.md). Settings and Ambient are sidebar items; the shelf has no controls below it.

The physical paging test accepts the current page boundary through `TEST_RUNNER_SHELF_LAST_BOOK_ID`, `TEST_RUNNER_SHELF_NEXT_BOOK_ID` in the xcodebuild environment. It starts a Debug build on page 2 using `--start-shelf-page=1`, uses the real library, checks both directions twice, verifies that backward focus persists, and checks that Right from the sidebar returns to the same book. Without those values it skips. The simulator navigation tests cover page transitions with sample data.
