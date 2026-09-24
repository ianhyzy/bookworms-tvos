# Focus and remote navigation

The tvOS focus engine owns all directional movement in Bookworms. App code shapes movement through layout, focus sections, and entry preferences. It assigns focus directly only when content first appears or when the user returns from a modal screen. Every remote press moves focus once, straight to its destination.

Read this guide before changing any view, control, or collection that can receive focus. See [tvOS views](../VIEWS.md) for what each view shows and [social views](SOCIAL_VIEWS_AND_AMBIENT.md) for rendering details.

## Why focus is structured this way

When a focused view handles a move command and also sets focus, the focus engine moves first, to the nearest item in the pressed direction. The handler then moves focus again. The user sees one item highlight briefly before focus jumps elsewhere without further input. Each additional handler, timer, or restoration path creates another way for focus to move twice, so the app has none of them.

## Navigation structure

The app uses a `TabView` with `.sidebarAdaptable`. Pressing Left from the leftmost content item or pressing Back opens the sidebar natively. The app never moves focus to the sidebar itself.

The sidebar is one list: the enabled main views, then **Ambient**, then **Settings**. Every item is a `Tab`, so the list works on tvOS 26. A private `SidebarItem` selection in [ShelfView.swift](../Bookworms/Views/ShelfView.swift) maps main views to `coordinator.current`; **Ambient** and **Settings** leave it on the last main view. **Settings** shows `SettingsView` in place, and Back returns to the sidebar. A native segmented control in a header focus section, level with the sidebar title, chooses the section. Each section lays out its controls in two columns. **Ambient** shows a page whose **Start ambient mode** button starts playback, so moving focus through the sidebar never starts it. On tvOS 27 and later, `tvOSSidebarHeader` also shows the Hardcover profile above the list; tvOS 26 omits it because `tabViewSidebarHeader` requires tvOS 27.

Each view divides its focusable content into focus sections with `.focusSection()`. A press aimed at a gap still reaches the section in that direction. Collections also declare `.defaultFocus(_:_:priority: .userInitiated)`, which chooses the item that receives focus when focus enters the collection from outside.

| View | Sections, top to bottom | Item that receives focus on entry |
| --- | --- | --- |
| **My Shelf** | Book row | The last focused book |
| **Following** | Activity row, in pages of 4; each card can have a **Read review** button below it | The last focused activity |
| **Compare Shelves** | Header (ordering menu, reader picker), your row, the reader's row | The book in the same column as the last focused book, on the entered row's visible page |
| **Book Club** | Header (reader picker, sort menu), cover row, review actions | The selected cover |
| **Ambient** | View interval, session length, view toggles, **Start ambient mode** | The control nearest the sidebar item |

Within a section, the focus engine picks the nearest item in the pressed direction. Up from a Compare Shelves row reaches the nearest header control, and Down from a Book Club cover reaches the nearest review action. Down where no item exists leaves focus unchanged.

## Paged collections

[`PagedRow`](../Bookworms/Views/ShelfView.swift) presents every horizontal collection. It keeps all items (at most 20) mounted in one horizontal `ScrollView` with `.scrollTargetBehavior(.paging)`. Because the next page's items exist, the focus engine crosses page boundaries natively. `PagedRow` pads each item so that every page spans exactly one row width, and keeps items `PagedRowLayout.edgeInset` from each edge so that focus lift and shadows are not clipped. It scrolls to the page that contains `selectedID` and never assigns focus.

[`ShelfRow`](../Bookworms/Views/ShelfView.swift) wraps `PagedRow` for book shelves. My Shelf and both Compare Shelves rows use it. Layouts that pack pages must subtract `2 * PagedRowLayout.edgeInset` from the row width, as `ShelfView` and `SocialViews` do.

Items are keyed by their stable IDs in one flat `ForEach`. Repacking after a pause in input changes only padding, so a focused item keeps its identity and its focus.

## When app code assigns focus

The following entry points are the only places the app assigns focus. Each runs at an entry event, never in response to a directional press or a data change.

| Event | Implementation |
| --- | --- |
| A shelf row appears | `ShelfRow` sets its focus binding in `onAppear` when `activatesOnAppear` is true, with a `task` fallback if focus was not yet available. |
| Following or Book Club appears | The view's `onAppear` focuses the remembered item. |
| The first artwork preparation finishes while a main view is showing | `ShelfView` requests focus on the first shelf book, or advances `socialReturnRevision`, only on the first preparation. |
| The user returns from details or ambient mode to a main view | `ShelfView.restoreSelection` issues a `ShelfBookFocusRequest` or advances `socialReturnRevision`. `SocialViews.restoreContentFocus` acts only when nothing in the content has focus. |

Data changes never move focus. After the first artwork preparation, content stays mounted while later preparations finish; covers reload from the local cache when `artworkGeneration` changes. Sorting, reader changes, and background refreshes update the mounted views in place.

## How to make changes

- **Add a view:** Group its controls into focus sections. Use `PagedRow` or `ShelfRow` for horizontal collections. Declare the entry item with `.defaultFocus(_:_:priority: .userInitiated)`. Add a navigation test for every direction out of every section, as described in [testing navigation](#testing-navigation).
- **Change which item receives focus on entry:** Change the value passed to `.defaultFocus`, such as `entryBookID` or `entryColumn` for `ShelfRow`.
- **Fix a direction that reaches the wrong item:** Change the layout or the sections. The focus engine chooses geometrically, so align the intended target with its source, or wrap the target group in `.focusSection()` so it catches presses aimed at a gap.
- **Add a modal screen:** Rely on native focus restoration after dismissal. If content needs a specific item afterward, issue the request from the dismissal callback and act only when nothing in the content has focus.
- **Add a control to a header:** Place it inside the header's existing `HStack`, which is already a full-width focus section.
- **Add a per-view choice:** Put it in that view's header, not in Settings, so users can change it without leaving the view. Settings holds the comparison limit, library, source, and app-wide choices.

`.onMoveCommand` is acceptable only for actions that do not change focus. For example, `ReviewReadingView` scrolls long reviews in response to Up and Down.

## Patterns to avoid

| Pattern | Problem | Instead |
| --- | --- | --- |
| Setting `@FocusState`, calling `resetFocus`, or requesting a focus update in `.onMoveCommand` | The engine moves first, so focus visibly moves twice. | Use layout, `.focusSection()`, and `.defaultFocus`. |
| Showing only the current page and swapping it on a boundary press | The next item does not exist, so the press escapes to the sidebar or header before code corrects it. | Use `PagedRow`, which keeps every item mounted. |
| Invisible focusable views that redirect focus when focused | They add a second focus update to every crossing. | Use `.focusSection()` or change the layout. |
| Timers or debounces on remote input | They hide a conflict instead of removing it and add input latency. | Remove the conflicting focus writer. |
| Searching the UIKit view hierarchy for a focus target, or adding `UIFocusGuide` bridges | Coordinates and view order change with system updates. | Rely on native sidebar and section behavior. |
| Moving focus in `onChange` or `task` in response to data, revisions, or loading completion | Focus moves while the user is idle or using another control. | Assign focus only at the entry events listed above. |
| Replacing mounted content with a loading view after the first load | Focus is destroyed and restored elsewhere. | Keep content mounted and update it in place. |
| Changing `.id(_:)` on a container that can hold focus | SwiftUI recreates its children and focus is lost. | Keep identity stable and change content. |
| A sidebar item that performs an action when selected | Selection can follow focus in the sidebar, so the action can run while the user is only moving past it. | Make the item a destination page with a button, as **Ambient** does. |
| `.onExitCommand` in main content | It blocks Back from opening the sidebar. | Let Back use its native behavior. |
| Tests that check only the final focused element | A bounce ends on a plausible item and passes. | Use `RemoteNavigation.press(_:in:expecting:)`. |

## Testing navigation

UI tests launch the app with `--focus-probe`. In Debug simulator builds, this installs `FocusTransitionProbe` from [ScenarioRuntime.swift](../Bookworms/Testing/ScenarioRuntime.swift). The probe counts `UIFocusSystem.didUpdateNotification` in an accessibility value without changing SwiftUI state.

[RemoteNavigation.swift](../BookwormsUITests/RemoteNavigation.swift) provides the shared helpers:

- `press(_:in:expecting:)` presses a direction, waits for the expected element, observes a one-second settle window, and requires exactly one focus update. A second update is a bounce.
- `pressWithoutMoving(_:in:from:)` requires zero focus updates where no item exists in that direction.
- `visibleButtons(_:prefix:in:)` returns fully visible items from left to right, because offscreen pages are mounted too.
- `open(_:arguments:)` launches on My Shelf and selects a view from the sidebar, which is how users reach every other view. Use it for view-entry tests. `launch(view:arguments:)` opens a view directly with `--start-view=`; initial focus on that path can land in the header or sidebar, so do not use it to test entry focus. `selectView`, `focusSidebarItem`, and `openSettings` navigate through the sidebar.
- `moveFocus(to:in:)` presses toward a target from the focused element, changing columns before moving vertically. From the Settings section bar it presses Down first, because Left or Right would switch sections. Use it in two-column layouts such as Settings and the Ambient page.
- `hasFocus(labeled:in:)` checks sidebar rows and menu items by label, because they report focus on a container rather than on the element a name query returns.

The settle window is an observation period for late focus updates, not synchronization. Do not shorten it to speed up a test or lengthen it to make a failing test pass.

[ShelfNavigationTests](../BookwormsUITests/ShelfNavigationTests.swift) and [SocialNavigationTests](../BookwormsUITests/SocialNavigationTests.swift) cover the current views. Use `openSettings`, `showShelf`, and `startAmbient` to reach sidebar destinations.

Simulator tests use discrete remote presses. Verify Siri Remote swipes, rapid input, and paging animation on the physical Apple TV.
