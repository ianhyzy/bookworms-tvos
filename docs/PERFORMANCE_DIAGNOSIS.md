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
| `description` | Opens details for the first My Shelf book, then opens and closes **Show more** three times, 3 seconds apart. Adds the Display instrument and marks each open and close as a `PERFORMANCE_PHASE` in `test.log`. Requires `--view 0` and a first book whose description shows **Show more**. |
| `bookWall` | Launches directly into Book Wall with `--start-view=bookWall`, opens and closes details three times, returns to the starting book, then moves through the stacks in short bursts. Adds the Display and GPU instruments. Use `scripts/profile-book-wall.py`, which builds, records, summarizes per phase, and restores the local build. |

`--view` accepts 0 through 3 for My Shelf, Feed, Compare Shelves, and Book Club, and opens that view from the sidebar before measurement. Keep all views enabled for these sequences.

For Book Wall, both drivers accept `--wall-antialiasing off|on` (default `on`, matching the
app). The baseline renders at 1920 × 1080;
add `--variant wall-900p` for 1600 × 900. The Book Wall wrapper enables diagnostics for
variants; add `--diagnostics` explicitly for matching baselines. Change one render setting
at a time, and keep diagnostics and the input sequence fixed for each
baseline–variant–baseline comparison.
The manifest records these requested settings as `wall_antialiasing` and `wall_resolution`;
check the app's `BookWallRendererViewport` log to confirm the actual render surface.

```sh
python3 scripts/profile-book-wall.py --diagnostics --label renderer-1080p
python3 scripts/profile-book-wall.py --skip-build --variant wall-900p --label renderer-900p
```

The driver removes checker injection from its copied test configuration. It sets `PreferredScreenCaptureFormat` to `screenshots` and `SystemAttachmentLifetime` to `keepNever` to disable automatic test video and attachments. Do not compare a screen-recorded capture with a capture-disabled run as if their measurement overhead were equal. Each scenario performs three repetitions of 20 steady and 20 burst directional presses. It does not poll accessibility or take screenshots during the measured sequence. Its setup and final assertions do query accessibility. XCTest adds transport overhead; command durations are not input-to-display latency.

For a sustained run, use `--scenario longevity --diagnostics`. For 20 minutes, the test repeatedly opens and closes Settings from the sidebar and moves between books. It then measures another book traversal, runs ambient mode for 45 minutes, and measures again after exit. The driver adds Activity Monitor for this scenario. Keep enough local disk space for the longer trace. Accessibility queries between navigation cycles add overhead; the short timed traversal blocks avoid them.

## Memory on a wireless Apple TV

When Instruments cannot attach to the TV, launch any build with `--memory-report` while the app is on screen:

```sh
xcrun devicectl device process launch --device UDID --terminate-existing --console gay.ian.Bookworms --memory-report
```

Every five seconds the app writes its physical footprint, peak footprint, and remaining memory before tvOS ends it (`os_proc_available_memory`) to standard error. Samples stop while the app is in the background.

## Book Wall motion

For a manual Book Wall capture, build `BookwormsDevice` in Release with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=BOOKWORMS_DIAGNOSTICS` and coverage disabled.
Use a separate derived-data directory to preserve the ordinary Release app. A
manual capture uses a plain build and does not require a test runner. Launch with
`--console`, `--start-view=bookWall`, and `--performance-diagnostics`.

The diagnostic build writes `BOOK_WALL_MOTION` summaries to standard error. Each summary covers at most 240
scene updates or two seconds, with separate flight and idle phases. The summaries
report scene-update intervals and the app's transform-callback cost. They do not
measure frame presentation or input-to-display latency. `BookWallPlan` reports
the synchronous flight-planning time; `BookWallRendererViewport` records the
viewport, output, and internal sizes. No book titles or reader data are logged.

Open a book, leave its detail view visible, then return to the wall. Compare the
renderer's pipeline windows with the callback measurements to distinguish rendering
cost from app animation work. Capture screenshots separately from the measured movement. Restore the ordinary
Release app when the investigation finishes.

## Isolation variants

Pass one `--variant` with `--diagnostics`. `profile-device.py` accepts several Book Wall isolations joined with `+`; `scripts/profile-book-wall.py --variant NAME` builds the diagnostic app and adds the diagnostics flag itself:

| Variant | Diagnostic change |
| --- | --- |
| `glass` | Uses native bordered buttons instead of glass for Settings controls, the Compare Shelves and Book Club header menus, and Book Club review actions. Native style geometry and focus animation may differ. |
| `background` | Reads cached data but suppresses source refresh, social transport, and CloudKit sync. Artwork and font restoration remain active. |
| `wall-no-fill-lights` | Turns off Book Wall's shelf and pool point lights. The detail key light still works. |
| `wall-raw-backdrop` | Shows Book Wall's backdrop image without baked lighting, for refitting the lighting factors against Simulator captures. |
| `wall-720p` | Caps Book Wall's 3D rendering at 1280 × 720 pixels instead of 1920 × 1080. |
| `wall-no-details` | Builds books without page-edge planes and hinge decals, removing four of eight meshes per book. |
| `wall-900p` | Caps Book Wall's 3D rendering at 1600 × 900 pixels. |
| `wall-no-ribbon` | Never shows the bookmark ribbon on the focused book. |
| `wall-warm-light` | Keeps the detail key light enabled at zero intensity, so opening a book does not change the scene's light count. |
| `wall-no-replay` | Hides Book Wall's glass **Drop again** button. |
| `wall-no-detail-panel` | Hides the SwiftUI book details while a Book Wall book is open. The wall, Back button, and Menu handling remain. |
| `wall-no-detail-corner` | Hides the wood corner that covers the tab control while a Book Wall book is open. The Back button remains. |
| `wall-no-detail-back` | Hides Book Wall's glass **Back to view** button while a book is open. Menu still closes the details. |
| `wall-no-show-more` | Hides Book Wall's **Show more** button under long book descriptions. |
| `wall-show-more-glass`, `wall-show-more-bordered` | Draws Book Wall's **Show more** with glass or the native bordered style instead of its flat platter. |
| `wall-instant-panel-exit`, `wall-instant-cover-exit` | Removes Book Wall's detail text, or its Back overlay, at once when details close, instead of fading it out. |
| `wall-late-replay` | Shows **Drop again** only after a returning book lands, instead of fading it in as the return starts. |
| `wall-detail-30` | Skips every other display-link tick while an open book only drifts, rendering that state at 30 fps. |

These variants are experiments, not approved fixes. Run baseline–variant–baseline comparisons. Attribute a cause only when the traces and repeatable behavior agree.

## Verify prepared data

The focus engine owns directional movement; see [focus and remote navigation](FOCUS_NAVIGATION.md). Input updates an unobserved idle deadline; it does not invalidate prepared library data. Comparison ordering and shared-read intersections update only when the relevant social snapshot, reader, ordering, or limit changes. Shelf pages update when books, designs, fonts, cover dimensions, or available geometry change. Pending artwork layout changes wait for input to settle. Credential-presence flags refresh at startup, foreground entry, provider selection, or credential changes; actual requests read secrets only when needed.

After preparation settles, profile the same sidebar, book, and Settings sequences. Expect no `KeychainRead`, `ComparisonSorting`, `SharedRanking`, or `DeferredRepack` intervals during sidebar or book movement. A data completion during recording must be identified separately. Preserve cold-load and focus-restoration tests: avoiding repeated work must not leave stale rows, credentials, or page selection.

## Interpret measurements

Start with the SwiftUI template. Verify that exported update and hitch tables contain rows; a listed track or a successful recording is insufficient. Correlate long updates and cause graphs with Time Profiler stacks. Use separate recordings for allocation growth, file activity, concurrency contention, or rendering details to limit overhead.

The diagnostic observer records public UIKit focus notifications and observes discrete remote presses with a recognizer that immediately fails. Validate marker-enabled behavior against the unmodified baseline. Swipe gestures do not have the same press boundary. Some controls, including segmented pickers, change their internal selection without emitting one UIKit focus notification per press. An unpaired press is not evidence of dropped input. `NativeFocusChanged` reports focus notification delivery, not frame presentation; do not call it input-to-photon latency. A failed focus move at a collection boundary is expected and is not automatically lost input.

Report sample counts, median/p95/worst app-side intervals, update counts, hitch durations, CPU stacks, and memory growth. Identify instrument overhead and unavailable measurements. Do not infer fluid rendering from zero hangs or low average CPU.

Prioritize sidebar movement, Settings sections, and action activation. Compare immediate launch with prolonged use. Use book movement as a control. Expand to 20/50/100-book fixtures, large social libraries, artwork cache states, accessibility settings, and source completion only when they distinguish competing explanations. Test cold caches in isolated fixture storage, not the user's container. Replay AI completions instead of making paid requests.

## Reduced Book Wall recordings

Both profiling entry points accept `--capture-set full|display|cpu`. `full` keeps Time Profiler, Points of Interest, Hitches, Display, and GPU for Book Wall; `display` selects only Display and Points of Interest; `cpu` selects Time Profiler and Points of Interest. `scripts/profile-book-wall.py` defaults to `display`, because Instruments streams kernel-trace data from the TV over the network and loses less of it with fewer instruments; `scripts/profile-device.py` defaults to `full`. Book Wall profiles also accept `--sequence details`, which records only the three detail open/close cycles. With diagnostics, the app writes its one-second renderer windows to `Library/Caches/BookWallPipeline.jsonl`, and the script copies that file into the run folder as `pipeline.jsonl` so the counts do not depend on streamed data. Reduced sets require the Book Wall scenario and keep its input sequence unchanged. The manifest records the effective set, template, and instruments.

Use a reduced set when the full recorder crashes or loses providers, then compare the same app variants with the same capture set. Different instrumentation overhead makes cross-set timing comparisons unreliable. A successful recorder exit is insufficient: inspect required phases for actual samples, gaps, and truncated intervals. Per-phase `observations` distinguishes an absent schema, no samples, and samples present, and records the first/last display-swap offsets. Sample presence does not establish complete phase coverage. Omitted CPU/GPU/hitch providers produce null metrics; empty or interrupted providers are not evidence of zero work.

## Renderer pipeline and lighting diagnostics

The renderer emits `BookWallRendererPipeline` windows in diagnostic builds when launched with `--performance-diagnostics`. Each window reports submitted/completed frames, skipped and idle ticks, occupied slots, callback duration, and the actual view/layer scale. The same bounded message is an Instruments point-of-interest event. A slot lifetime includes CPU submission, GPU work, and callback dispatch; it is not GPU execution time or a displayed-frame interval. Use the Display instrument for acceptance.

After confirming slot overlap, compare `--variant wall-no-ibl` and `--variant wall-unlit-shelf` against a matched renderer baseline. The first gives root descendants zero environment-lighting weight and skips the studio environment; the second replaces the shelf's PBR material with a constant unlit tint while retaining geometry and physics. They deliberately change appearance to isolate cost. An unlit tint is not a fitted shelf bake; validate any replacement against resting, opening, and return lighting before adopting it.

## Finish the investigation

Keep dated manifests, summaries, test results, and findings under `.local/performance-diagnosis/`. Traces and their exported tables take about 240 MB per run; delete them when the analysis is done with `python3 scripts/profile-book-wall.py --prune`. `profile-device.py` deletes the kernel-trace buffer, 1–2 GB, that `xctrace` leaves in the Mac's temporary folder after each recording. Label each finding confirmed, probable, not reproduced, or ruled out under stated conditions. List unperformed scenarios and the evidence needed to resolve uncertainty.

Restore the ordinary Release app, preserve its data, and remove only this project's UI-test runner. Keep diagnostic switches disabled in distributable builds. No App Store upload is part of this procedure.

## References

- [Apple: Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)
- [Apple: Profile, fix, and verify app responsiveness](https://developer.apple.com/videos/play/wwdc2026/268/)
- [Apple: UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/)
- [Airbnb: Understanding and improving SwiftUI performance](https://airbnb.tech/web/understanding-and-improving-swiftui-performance/)

If the SwiftUI track is empty on the device, retain that limitation and use the runner's Time Profiler + Hitches + Points of Interest recording. `--template SwiftUI` remains available for devices that supply update data. Supply `--trace-device` when the paired Apple TV's Instruments name differs from the default `Living Room`. Instruments and `devicectl` can resolve the same UDID differently; the runner uses the device ID for XCTest and the name plus current process ID for tracing.
