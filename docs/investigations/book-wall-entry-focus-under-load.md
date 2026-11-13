# Book Wall entry focus under load

Entering Book Wall from the sidebar can take three focus updates instead of one when the Mac that runs the simulator is heavily loaded. The cause isn't known, and no code changed because of this investigation. On an idle Mac, the same build passes.

See [focus and remote navigation](../FOCUS_NAVIGATION.md) for the app's focus rules.

## What happened

On 2026-11-13, the release plan for build 16 failed two of its 535 tests:

- `BookWallNavigationTests/testAYearOnOnePageShowsNoPageMenu`
- `BookWallNavigationTests/testBackFromDetailFilterReturnsToDetailsWithoutAnotherFlight`

Both failed with `("Optional(8)") is not equal to ("Optional(6)") - One remote press must produce 1 focus update(s)`. While the plan ran, the same Mac ran two `xcodebuild archive` jobs for the iPhone and Mac app and several Blender renders. A second run of the whole plan on the idle Mac, from the same sources, passed all 535 tests.

## What the failure measures

- `RemoteNavigation.press(_:in:expecting:)` reads the app-wide count of native focus updates before a press, waits for focus and a one-second settle window, and expects the count to have risen by one.
- Both failures are at the same line of the shared `openWall()` helper in `BookWallNavigationTests.swift`: the Select press on the sidebar's **Book Wall** entry. The count was 5 before the press and 8 after, so that one press produced three focus updates. Neither test's own steps had run.
- The extra updates were real focus updates in the app, not a stale read of the counter.

## What was ruled out

- **A regression in the build.** Both tests failed only in the tvOS 27.2 lane with Reduce Motion. They passed in the standard tvOS 27.2 lane of the same run, on the same binary.
- **The helper itself.** Other tests that call `openWall()` passed in the failing lane, such as `testBackThroughDetailsOnAFilteredShelfKeepsTheWallDetails` and `testDropAgainIsReachableAndRestoresTheWall`.
- **The change under test.** The only change since the last passing run replaced the app icon and Top Shelf images. No Swift changed, Book Wall and the UI tests don't read those assets, and UI scenarios stub Top Shelf reads and writes.
- **Test retries or extra presses.** The sidebar step was one Menu press and one Down press in both the failing run and the earlier passing run.
- **A known flaky test.** No earlier recorded run failed either test.

## What points to load

In the failing lane, Select took 2.2 seconds to return, and the test polled for about two more seconds before `book-wall-8` had focus. In the passing run of the same lane that morning, `book-wall-8` had focus at the first check.

## What isn't known

- Where the two intermediate focus updates landed. The logs don't record the focused element for each update, and the result bundles weren't opened.
- Whether app code or the tvOS focus engine causes the extra updates. `BookWallView` places the spines from their planned resting frames so that they exist in the page's first render and `.defaultFocus` finds the entry book in one update; under load, something in that handoff takes two more steps.
- Whether the Reduce Motion lane is more exposed, or simply ran while the load was heaviest.

## If it happens again

- Check what else the Mac was running. A failure of these tests on an idle Mac is new information; a failure under load matches this note.
- To find where focus lands, record the focused element with each native focus update in the failing lane and compare it with a passing run.
- Don't run other builds or renders while the release plan runs.
