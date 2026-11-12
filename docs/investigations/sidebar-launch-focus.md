# Sidebar focus at launch

Bookworms is meant to open on My Shelf with the first book focused and the sidebar closed, at launch and after the first sign-in. It does on tvOS 26.5. On tvOS 27.2, the sidebar opens with focus first. Sidebar-first is the platform's behavior on both versions, the app overrides it, and tvOS 27.2 leaves the override nothing to focus. No public API changes that, so the app keeps the difference until one does.

See [focus and remote navigation](../FOCUS_NAVIGATION.md) for the app's focus rules.

## What the viewer sees

| tvOS | At launch on My Shelf | Then |
| --- | --- | --- |
| 26.5 | The sidebar is collapsed and the first book has focus. | |
| 27.2 | The sidebar is open with focus on **My Shelf**. | Right or Select closes the sidebar, and it closes by itself after 8 idle seconds. Focus then lands on the first book. |

On tvOS 27.2 the sidebar also takes focus when the focused content goes away, such as when **View example profile** leaves with the welcome popup.

## Cause

Three facts combine.

1. **The platform focuses the sidebar first.** A `TabView` with `.sidebarAdaptable`, whose content is focusable from the first frame, launches with the sidebar open and focused on tvOS 26.5 and on tvOS 27.2. `defaultFocus` and `prefersDefaultFocus` on the content do not change this on either version.
2. **The app moves focus to the first book.** `ShelfRow` assigns its `@FocusState` in `.onAppear` and `.task`, and `prepareArtwork()` in `ShelfView` calls `requestBookFocus(_:)` once after the first artwork preparation. On tvOS 26.5 the window's first focus update then goes straight to the book, as one update. With those three assignments skipped, the app launches sidebar-first on tvOS 26.5 too.
3. **tvOS 27.2 takes the content out of focus while the sidebar is open.** On tvOS 26.5, the book buttons stay in the focus tree beside the sidebar rows, so the assignment has a target. On tvOS 27.2, the focus tree holds only the sidebar rows while the sidebar is open, and the content's container view has `isUserInteractionEnabled` set to `false`. The three assignments still run and have no effect. When the sidebar closes, the books return to the focus tree and the sidebar rows leave it.

The sidebar does not take focus because the shelf is still loading. Content that is focusable from the first frame loses launch focus to the sidebar in the same way, so a focusable loading placeholder does not help.

A direct launch on Book Wall with `--start-view=bookWall` opens sidebar-first on tvOS 26.5 as well.

## What does not move focus off the sidebar on tvOS 27.2

Each of these was tried in a minimal app while the sidebar was open:

- `defaultFocus` on the tab content and on the `TabView`, at the automatic and `.userInitiated` priorities
- `prefersDefaultFocus(in:)` with `focusScope(_:)`
- `@FocusState` assignments in `.onAppear`, in `.task`, and one second after launch
- Changing the `TabView` selection in code
- `.toolbar(.hidden, for: .tabBar)` on the content, then showing it again
- `.disabled(true)` on the `TabView`, then enabling it (the sidebar still takes focus while disabled)
- Presenting a full-screen cover at launch and dismissing it
- A UIKit view in the content that returns `true` from `canBecomeFocused`, with `UIFocusSystem.requestFocusUpdate(to:)`; `UIFocusDebugger` reports that an ancestor has user interaction turned off

The tvOS 27.2 SDK has no API for the sidebar's visibility on tvOS: `AdaptableTabBarPlacement.sidebar` and `tabViewSidebarBottomBar` are unavailable there, and the tvOS 27.2 release notes do not mention the change.

## Reproduce and inspect

Use simulators for tvOS 26.5 and 27.2.

1. Build this app as a single file. It logs every focus update and, after two seconds, whether a content button is in the focus tree.

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

2. To see the focus tree, walk `focusItemContainer.focusItems(in:)` from the window and print each item whose `canBecomeFocused` is `true`. With the sidebar open, tvOS 26.5 lists the content buttons and the sidebar rows; tvOS 27.2 lists only the sidebar rows. `UIFocusDebugger.checkFocusability(for:)` explains why an item cannot take focus.

3. To confirm the app's part, skip the three assignments named under [Cause](#cause) in a local build and launch with `--reset-test-settings --sample-library` on tvOS 26.5. The sidebar takes focus.

## Limits of this record

- tvOS 27.0 was not checked. [Focus and remote navigation](../FOCUS_NAVIGATION.md) records that it launches on the first book.
- A physical Apple TV on tvOS 27.2 was not checked. Nothing in the cause depends on the simulator.
- The three assignments were skipped together, so which of them decides the launch focus on tvOS 26.5 is not known.
- Launches on the social views and Year in Review were not compared between the two versions.

## If this is revisited

- Launching on a book on tvOS 27.2 needs a sidebar that the app draws itself, or a new API from Apple. The minimal app above is a ready reproducer for a Feedback report or a forum question.
- Keep the three launch assignments. Removing them would make every version launch sidebar-first, which is the opposite of the intended behavior.
