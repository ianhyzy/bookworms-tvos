# Sidebar focus at launch

Bookworms opens on My Shelf with the first book focused and the sidebar closed, at launch and after the first sign-in, on tvOS 26.5 and tvOS 27.2. Its shell is a `NavigationSplitView` whose sidebar column starts hidden, so the focus engine's first choice is the view, and the app assigns no focus. A `TabView` with `.sidebarAdaptable` can't do this on tvOS 27.2, and no public API changes that.

See [focus and remote navigation](../FOCUS_NAVIGATION.md) for the app's focus rules.

## What works

A `NavigationSplitView(columnVisibility:)` whose visibility starts at `.detailOnly`, with a `List(selection:)` in the sidebar column:

- tvOS draws the sidebar as the same floating panel, and the same collapsed pill, that it draws for a tab sidebar.
- The system honors the starting visibility, so the sidebar is closed at launch and the first focus update goes to the selected view.
- The system opens the sidebar on Left from the view's leading edge and on Back, and closes it on Select or Right. On tvOS 27, Up from a view's topmost item opens it too, as it does with a tab sidebar.
- `.defaultFocus` on the list names the selected row, so the sidebar opens with focus there instead of on its first row.

The shell needs three things beyond that, each in `ShelfView`:

| Need | Reason |
| --- | --- |
| `.disabled` on the detail while the sidebar is open | tvOS 27 takes the detail out of the focus system while the sidebar is open. tvOS 26 leaves it in, so Right from a sidebar row focuses a far item before the closing sidebar moves focus to the entry item: two focus updates for one press. |
| `.disabled` on the shell while the welcome popup is up | A view that mounts while the popup animates in takes focus from the popup for good. |
| A focus target in every state of every page | Left and Back open the sidebar from the focused item. With nothing focusable, the sidebar is unreachable and Back leaves the app. Loading and empty states use `holdsFocus()`. |

A view enters at its remembered item through `.defaultFocus`, not through a focus assignment in `onAppear`: the page can't take focus while the sidebar is open, so an assignment made as the page appears is lost. A view with a header above its collection declares the entry item at its root, because the focus engine otherwise enters at the header.

## Known limits of the split view

- **Launch fade-in.** On tvOS 27.2, for about 80 ms of the launch fade-in, while the screen is still nearly black, the sidebar's rows are drawn expanded and dim before they shrink into the pill.
- **Returning to the app.** tvOS 27.2 reopens an app that was left through the open sidebar with the sidebar still open and focused. `ShelfView` closes the sidebar when the app moves to the background, so the app returns on its page.
- **A page is rebuilt when its row is selected.** State that outlives a visit lives in `BookwormsCoordinator`, `ShelfFocus`, or `BookWallScene`.
- **Presentations on tvOS 26.5.** When a full-screen cover opens or closes there, focus ignores a row's `.defaultFocus` and lands on another item. The shelf that book details filter, and My Shelf when that filter is cleared, therefore focus their entry book in `onAppear` (`ShelfRow.focusesEntryOnAppear`).
- **No header API.** `tabViewSidebarHeader` belongs to `TabView`. The profile above the rows is a `safeAreaInset` on the list.
- **Row spacing.** On tvOS 27.2 the list's rows sit 66 points apart, and a tab sidebar's sit 76 points apart. On tvOS 26.5 both sit 78 points apart. `defaultMinListRowHeight` changes the spacing; the app keeps the system's.

## Why a tab sidebar can't launch on the view

Three facts combine.

1. **The platform focuses a tab sidebar first.** A `TabView` with `.sidebarAdaptable`, whose content is focusable from the first frame, launches with the sidebar open and focused on tvOS 26.5 and on tvOS 27.2. `defaultFocus` and `prefersDefaultFocus` on the content do not change this on either version. Loading content is not the cause: content that is focusable from the first frame loses launch focus in the same way.
2. **On tvOS 26.5, a focus assignment overrides it.** The content's buttons stay in the focus tree beside the sidebar rows, so a `@FocusState` assignment made as the content appears moves the window's first focus update to the content.
3. **tvOS 27.2 takes the content out of focus while the sidebar is open.** The focus tree holds only the sidebar rows, and the content's container view has `isUserInteractionEnabled` set to `false`. The same assignment runs and has no effect. When the sidebar closes, the content returns to the focus tree and the sidebar rows leave it. The sidebar closes on Right, on Select, or after 8 idle seconds.

On tvOS 27.2 a tab sidebar also takes focus when the focused content goes away, such as when a sheet that had focus closes.

## What does not move focus off a tab sidebar on tvOS 27.2

Each of these was tried in a minimal app while the sidebar was open:

- `defaultFocus` on the tab content and on the `TabView`, at the automatic and `.userInitiated` priorities
- `prefersDefaultFocus(in:)` with `focusScope(_:)`
- `@FocusState` assignments in `.onAppear`, in `.task`, and one second after launch
- Changing the `TabView` selection in code
- `.toolbar(.hidden, for: .tabBar)` on the content, then showing it again
- `.disabled(true)` on the `TabView`, then enabling it (the sidebar still takes focus while disabled)
- Presenting a full-screen cover at launch and dismissing it
- A UIKit view in the content that returns `true` from `canBecomeFocused`, with `UIFocusSystem.requestFocusUpdate(to:)`; `UIFocusDebugger` reports that an ancestor has user interaction turned off

The tvOS 27.2 SDK has no API for a tab sidebar's visibility on tvOS: `AdaptableTabBarPlacement.sidebar` and `tabViewSidebarBottomBar` are unavailable there, and the tvOS 27.2 release notes do not mention the change.

## Reproduce and inspect

Use simulators for tvOS 26.5 and 27.2.

1. Build this app as a single file. It logs every focus update.

   ```swift
   import SwiftUI
   import UIKit

   @main
   struct ProbeApp: App {
       init() {
           NotificationCenter.default.addObserver(
               forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
           ) { note in
               let context =
                   note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
               print("focus:", context?.nextFocusedItem.map { "\(type(of: $0)) \($0.frame)" } ?? "nil")
           }
       }
       var body: some Scene {
           WindowGroup {
               TabView {
                   ForEach(0..<3, id: \.self) { tab in
                       Tab("View \(tab)", systemImage: "book") {
                           HStack { ForEach(0..<5, id: \.self) { Button("Item \($0)") {} } }
                       }
                   }
               }
               .tabViewStyle(.sidebarAdaptable)
           }
       }
   }
   ```

   ```sh
   xcrun -sdk appletvsimulator swiftc -target arm64-apple-tvos26.0-simulator \
     -parse-as-library Probe.swift -o Probe.app/Probe
   codesign -s - --force Probe.app
   xcrun simctl install <udid> Probe.app
   xcrun simctl launch --console-pty <udid> <bundle identifier>
   ```

   `Probe.app` also needs an `Info.plist` with `CFBundleIdentifier`, `CFBundleExecutable`, `UIDeviceFamily` 3, and `MinimumOSVersion`. On both runtimes the first focused item is a sidebar row.

2. Replace the `TabView` with a split view that starts closed. On both runtimes the first focused item is a button in the detail.

   ```swift
   struct Root: View {
       @State private var selection: Int? = 0
       @State private var visibility = NavigationSplitViewVisibility.detailOnly

       var body: some View {
           NavigationSplitView(columnVisibility: $visibility) {
               List(0..<3, id: \.self, selection: $selection) { view in
                   NavigationLink(value: view) { Label("View \(view)", systemImage: "book") }
               }
           } detail: {
               HStack { ForEach(0..<5, id: \.self) { Button("Item \($0)") {} } }
                   .disabled(visibility != .detailOnly)
           }
       }
   }
   ```

3. To see the focus tree, walk `focusItemContainer.focusItems(in:)` from the window and print each item whose `canBecomeFocused` is `true`. With a tab sidebar open, tvOS 26.5 lists the content buttons and the sidebar rows; tvOS 27.2 lists only the sidebar rows. `UIFocusDebugger.checkFocusability(for:)` explains why an item cannot take focus.

In the app, `ShelfNavigationTests.testLaunchFocusesTheFirstBookWithTheSidebarClosed` checks the launch on each runtime the test plan runs.

## Limits of this record

- tvOS 27.0 was not checked.
- A physical Apple TV was not checked. Nothing in the cause depends on the simulator.
- Siri Remote swipes were not checked; simulator tests use discrete presses.
