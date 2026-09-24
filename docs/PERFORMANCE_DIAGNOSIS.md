# Diagnose Apple TV navigation performance

Use physical Apple TV measurements to distinguish delayed focus, expensive app updates, rendering hitches, and external waits. Functional tests and simulator timings do not establish hardware responsiveness.

## Build and preserve the baseline

Build an ordinary Release app into a separate derived-data directory before building diagnostics. Keep its app bundle and matching dSYM for restoration and symbolication. Record the source checksum, Xcode version, device OS, library sizes, current settings, and cache state with each investigation. Do not erase real caches, credentials, or cloud data.

Disable coverage explicitly with `CLANG_ENABLE_CODE_COVERAGE=NO` and `-enableCodeCoverage NO` for test builds. For a plain device build, use the `BookwormsDevice` scheme, whose default Device test plan has coverage disabled. `scripts/device-build.py` uses this scheme and rejects coverage-instrumented Release executables before installation. Xcode rejects `-enableCodeCoverage` outside test actions, and the build setting alone does not reliably override a coverage-enabled default test plan. Inspect compiler commands for `-O`, whole-module optimization, and the absence of `-profile-generate` and `-profile-coverage-mapping`. Check the app binary with `otool -l`: it must have no `__llvm_prf*` or `__llvm_cov*` sections. The profiling driver rejects binaries containing these sections. Use `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`. Run without a debugger, sanitizers, or performance checkers. `device-build.py --test` defaults to Debug unless you pass `--configuration Release`.

## Opt-in diagnostic build

Add `SWIFT_ACTIVE_COMPILATION_CONDITIONS=BOOKWORMS_DIAGNOSTICS` only to an optimized local diagnostic build. Generate the project with `xcodegen generate` after adding source files. Build the Device plan with `build-for-testing`, `ENABLE_TESTABILITY=YES`, and coverage disabled.

The app activates diagnostics only with `--performance-diagnostics`. Normal builds ignore all diagnostic arguments. Diagnostic runs block AI generation, including explicit generation actions. Markers include operation names and numeric values, never credentials, review text, or authenticated URLs.

`scripts/profile-device.py` runs `DevicePerformanceTests/testMenuProfile` and attaches Instruments by process ID. Supply the device ID, the generated `.xctestrun` file, and a new output directory:

```sh
python3 scripts/profile-device.py \
  --device DEVICE_ID \
  --xctestrun DERIVED_DATA/Build/Products/BookwormsDevice_appletvos27.0-arm64.xctestrun \
  --diagnostics --scenario sidebar --view 0 \
  --output .local/performance-diagnosis/RUN_NAME
```

Use the actual generated `.xctestrun` filename for the installed SDK. For an ordinary baseline, omit `--diagnostics` and pass `--app` with the preserved Release bundle. Choose one scenario:

| Scenario | Measured input |
| --- | --- |
| `sidebar` (default) | Moves focus to the sidebar, then traverses its items with Up and Down. |
| `books` | Moves between books in the selected view with Left and Right. Use it as the content-navigation control. |
| `settings` | Opens Settings from the sidebar and moves across its section picker. Native segmented selection changes the visible section during this sequence; it is not a focus-only traversal. |
| `longevity` | Runs the sustained sequence described below. |

`--view` accepts 0 through 3 for My Shelf, Following, Compare Shelves, and Book Club, and opens that view from the sidebar before measurement. Keep all views enabled for these sequences.

The driver removes checker injection from its copied test configuration. It sets `PreferredScreenCaptureFormat` to `screenshots` and `SystemAttachmentLifetime` to `keepNever` to disable automatic test video and attachments. Do not compare a screen-recorded capture with a capture-disabled run as if their measurement overhead were equal. Each scenario performs three repetitions of 20 steady and 20 burst directional presses. It does not poll accessibility or take screenshots during the measured sequence. Its setup and final assertions do query accessibility. XCTest adds transport overhead; command durations are not input-to-display latency.

For a sustained run, use `--scenario longevity --diagnostics`. For 20 minutes, the test repeatedly opens and closes Settings from the sidebar and moves between books. It then measures another book traversal, runs ambient mode for 45 minutes, and measures again after exit. The driver adds Activity Monitor for this scenario. Keep enough local disk space for the longer trace. Accessibility queries between navigation cycles add overhead; the short timed traversal blocks avoid them.

## Memory on a wireless Apple TV

When Instruments cannot attach to the TV, launch any build with `--memory-report` while the app is on screen:

```sh
xcrun devicectl device process launch --device UDID --terminate-existing --console gay.ian.Bookworms --memory-report
```

Every five seconds the app writes its physical footprint, peak footprint, and remaining memory before tvOS ends it (`os_proc_available_memory`) to standard error. Samples stop while the app is in the background.

## Isolation variants

Pass exactly one `--variant` with `--diagnostics`:

| Variant | Diagnostic change |
| --- | --- |
| `glass` | Uses native bordered buttons instead of glass for Settings controls, the Compare Shelves and Book Club header menus, and Book Club review actions. Native style geometry and focus animation may differ. |
| `background` | Reads cached data but suppresses source refresh, social transport, and CloudKit sync. Artwork and font restoration remain active. |

These variants are experiments, not approved fixes. Run baseline–variant–baseline comparisons. Attribute a cause only when the traces and repeatable behavior agree.

## Verify prepared data

The focus engine owns directional movement; see [focus and remote navigation](FOCUS_NAVIGATION.md). Input updates an unobserved idle deadline; it does not invalidate prepared library data. Comparison ordering and shared-read intersections update only when the relevant social snapshot, reader, ordering, or limit changes. Shelf pages update when books, designs, fonts, cover dimensions, or available geometry change. Pending artwork layout changes wait for input to settle. Credential-presence flags refresh at startup, foreground entry, provider selection, or credential changes; actual requests read secrets only when needed.

After preparation settles, profile the same sidebar, book, and Settings sequences. Expect no `KeychainRead`, `ComparisonSorting`, `SharedRanking`, or `DeferredRepack` intervals during sidebar or book movement. A data completion during recording must be identified separately. Preserve cold-load and focus-restoration tests: avoiding repeated work must not leave stale rows, credentials, or page selection.

## Interpret measurements

Start with the SwiftUI template. Verify that exported update and hitch tables contain rows; a listed track or a successful recording is insufficient. Correlate long updates and cause graphs with Time Profiler stacks. Use separate recordings for allocation growth, file activity, concurrency contention, or rendering details to limit overhead.

The diagnostic observer records public UIKit focus notifications and observes discrete remote presses with a recognizer that immediately fails. Validate marker-enabled behavior against the unmodified baseline. Swipe gestures do not have the same press boundary. Some controls, including segmented pickers, change their internal selection without emitting one UIKit focus notification per press. An unpaired press is not evidence of dropped input. `NativeFocusChanged` reports focus notification delivery, not frame presentation; do not call it input-to-photon latency. A failed focus move at a collection boundary is expected and is not automatically lost input.

Report sample counts, median/p95/worst app-side intervals, update counts, hitch durations, CPU stacks, and memory growth. Identify instrument overhead and unavailable measurements. Do not infer fluid rendering from zero hangs or low average CPU.

Prioritize sidebar movement, Settings sections, and action activation. Compare immediate launch with prolonged use. Use book movement as a control. Expand to 20/50/100-book fixtures, large social libraries, artwork cache states, accessibility settings, and source completion only when they distinguish competing explanations. Test cold caches in isolated fixture storage, not the user's container. Replay AI completions instead of making paid requests.

## Finish the investigation

Keep dated traces, manifests, test results, and findings under `.local/performance-diagnosis/`. Label each finding confirmed, probable, not reproduced, or ruled out under stated conditions. List unperformed scenarios and the evidence needed to resolve uncertainty.

Restore the ordinary Release app, preserve its data, and remove only this project's UI-test runner. Keep diagnostic switches disabled in distributable builds. No TestFlight upload is part of this procedure.

## References

- [Apple: Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)
- [Apple: Profile, fix, and verify app responsiveness](https://developer.apple.com/videos/play/wwdc2026/268/)
- [Apple: UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/)
- [Airbnb: Understanding and improving SwiftUI performance](https://airbnb.tech/web/understanding-and-improving-swiftui-performance/)

If the SwiftUI track is empty on the device, retain that limitation and use the runner's Time Profiler + Hitches + Points of Interest recording. `--template SwiftUI` remains available for devices that supply update data. Supply `--trace-device` when the paired Apple TV's Instruments name differs from the default `Living Room`. Instruments and `devicectl` can resolve the same UDID differently; the runner uses the device ID for XCTest and the name plus current process ID for tracing.
