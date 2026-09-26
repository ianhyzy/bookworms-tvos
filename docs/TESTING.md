# Testing Bookworms

The Local test plan combines deterministic service tests with tvOS remote-driven UI tests. Keep live services and device-only checks separate so a routine run cannot spend API credits or change a real library.

## When to run tests

Run tests only when the owner asks. Routine verification after a change is:

1. Lint each edited Swift file with `xcrun swift-format lint --strict`.
2. Build and install on the Apple TV with `python3 scripts/device-build.py`, which compiles a Release build and launches it for manual testing.

Update affected tests alongside behavior changes, list the tests that would add signal, and ask before running them. A Unit run takes about a minute; a Local run adds several minutes of UI tests; `--major` repeats Local on each runtime.

## Local test worker

When the owner asks for a run, use `python3 scripts/test-worker.py --detach`. Return the dispatch-log path and end the agent turn; no polling or model supervision is needed. The worker disables and verifies Device Hub’s tvOS audio-output preference before booting a simulator. Unsupported audio controls block the run. See [operator instructions](../SUBAGENT-TEST-INSTRUCTIONS.md). The worker wraps the runner below, serializes runs, limits build jobs to two, enforces a two-hour timeout, and writes `handoff.md` and `handoff.json`. Read these first instead of streaming build logs into an agent.

`--profile unit` selects Unit; `--profile major` selects the runtime matrix. No profile runs on a device or contacts live providers. Offline builds route all app HTTP requests through fixture protocols followed by a deny-all handler. Real Keychain access is disabled, and CloudKit's existing simulator guard remains active. Unit and UI checks provide offline-enforcement evidence, including app relaunch. This is an application transport boundary, not an operating-system firewall.

The optional `--summarize` flag uses a preloaded local LM Studio model only after failed or blocked runs. Model output cannot change the authoritative result. No model call occurs for a pass. Keep models unloaded during test execution when memory is tight.

For infrastructure maintenance, run `python3 -m unittest discover -s scripts -p 'test_test_*.py'`. Compare already-installed summarizers against saved reports with `python3 scripts/benchmark-test-worker.py`; this unloads idle model instances, loads each candidate sequentially with an 8K context and one slot, then unloads it. It never downloads a model or runs app tests.

## Underlying runner

```sh
python3 scripts/test-local.py
```

The runner creates a disposable Apple TV 4K simulator using the newest installed tvOS runtime. It retains the build log, `.xcresult` bundle, coverage, exported screenshots, and Markdown/JSON reports under `.local/test-results/`, then deletes only the simulator it created. Each run uses its own derived-data directory. It does not read 1Password or configure real accounts. Xcode and the selected tvOS runtimes must already be installed.

For a faster service and model check:

```sh
python3 scripts/test-local.py --plan Unit
```

To select a runtime explicitly or verify a major change:

```sh
python3 scripts/test-local.py --runtime 26.0
python3 scripts/test-local.py --major
```

`--major` runs the complete Local plan on each runtime in [the runtime matrix](../TestPlans/runtime-matrix.json): the minimum tvOS 26.0 and current verification target tvOS 27.0. Update the matrix intentionally when the verification target changes. The runner does not silently substitute a runtime that is missing. A missing runtime is **blocked**, not passed.

Inspect `report.md` and `report.json` after every run. Intermediate reports remain **running** until every requested runtime finishes and the source identity is checked again. The runner compares the selected test methods in the current source and plan with the actual result bundle. Failed tests, unexpected skips, missing or unexpected tests, missing results, failed coverage export, and failed cleanup prevent a passing result. Source changes during verification invalidate the run. Exit codes are `0` for an automated pass, `1` for failure, and `2` for blocked verification. Visual review has a separate status and can remain pending after assertions pass; missing runtime evidence blocks visual verification.

The checked-in plans are also available in Xcode under **Product → Test Plan**:

- **Local:** unit/service tests and fictional-library UI tests, with coverage.
- **Unit:** unit/service tests only, with coverage.
- **Device:** opt-in tests using the paired TV and its existing library. Select it with `scripts/device-build.py --test --test-plan Device --device DEVICE_ID --team TEAM_ID`. These checks require the environment values described in the test files and must not count skipped checks as passing verification.

XcodeGen preserves the plans through `project.yml`. After adding Swift files, run `xcodegen generate`. Inspect failed assertions and attachments in the result bundle; do not accept a run merely because compilation succeeded. Do not retry a failing test until it happens to pass without diagnosing the cause.

For a complete Mac-only cycle:

1. Before implementation, retain a Local run against the starting source. Keep that result separate from checks of the changed code.
2. Run focused tests while developing. Verify the runner without Xcode using `python3 -m unittest discover -s scripts -p 'test_test_local.py'`. Run `xcrun swift-format lint --strict` on each edited Swift file.
3. Regenerate the project if needed, finish source edits, then run `python3 scripts/test-local.py --major`. Do not edit source while it runs. Review failures before selecting any reruns.
4. Build the ordinary simulator executable with `xcodebuild -project Bookworms.xcodeproj -scheme BookwormsDevice -configuration Release -destination 'generic/platform=tvOS Simulator' -derivedDataPath .local/release-simulator-check/DerivedData CODE_SIGNING_ALLOWED=NO build`. Save the build log. Inspect the app and embedded Top Shelf executable with `xcrun otool -l`; neither may contain `__llvm_prf*` or `__llvm_cov*` sections. This scheme uses a coverage-disabled default plan.
5. Review coverage, accessibility results, screenshots, documentation links, and the final diff. Record any remaining checks alongside the result artifacts. Compile `BookwormsLive` with `build-for-testing` separately when changing its checks; compilation does not verify live-provider compatibility.

This cycle verifies simulator behavior. It does not measure physical Apple TV frame presentation or performance.

## Deterministic scenarios and visual evidence

`LibraryWorkflowTests` exercises normal model startup and refresh using injected service boundaries, isolated preferences, and real local stores. Controlled response completion covers cancellation and late results; injected time covers daily refresh and manual cooldowns. Tests keep the application's state transitions and persistence under test.

`ScenarioNavigationTests` launches Debug simulator scenarios through `--test-scenario=NAME`. These use the real Hardcover client and decoder with fictional wire responses, generated cover images, isolated storage, and a transport that records unexpected requests. The UI tests inspect that evidence and fail on unexpected traffic. Scenario hooks are excluded from ordinary Release builds and physical-device builds.

Hold and release responses explicitly when testing asynchronous work. Advance a test clock when testing scheduled behavior. Wait for observable conditions with a timeout; do not use arbitrary sleeps as synchronization.

The runner exports stable screenshot names and `visual-review.html` for review. With no approved baseline, screenshots remain **review pending**. To compare against an explicitly approved reference directory:

```sh
python3 scripts/test-local.py --major --baseline-dir /absolute/path/to/approved-screenshots
```

Organize references as `tvOS-26.0/*.png` and `tvOS-27.0/*.png`, retaining exported filenames. PNG byte comparisons flag changed images; they do not establish visual correctness. The runner never writes to the reference directory or approves a baseline. Inspect differences, accessibility findings, loaded artwork, and focus evidence before accepting visual changes. Native VoiceOver behavior and TV-distance appearance remain device checks.

## Read-only live-service checks

The separate `BookwormsLive` scheme validates real Hardcover and CWA authentication, request compatibility, and decoding through the production clients. It is excluded from Local, Unit, and `--major`. Use a dedicated simulator with a small, nonempty, explicitly authorized test account configured through the app's Sources settings. Credentials stay in that simulator's Keychain. The checks use ephemeral, uncached sessions and compare decoded records with common fixture assumptions: unique IDs, source provenance, titles, and valid rating/count ranges. They do not assert exact private library contents or exhaustively validate the provider schema. Do not pass literal credentials in commands or retain decoded library data in artifacts.

Choose the provider to check and an unused result path:

```sh
TEST_RUNNER_VERIFY_LIVE_SERVICES=1 xcodebuild \
  -project Bookworms.xcodeproj -scheme BookwormsLive \
  -destination 'platform=tvOS Simulator,id=CONFIGURED_SIMULATOR_ID' \
  -derivedDataPath .local/live-verification/DerivedData \
  -resultBundlePath .local/live-verification/Hardcover.xcresult \
  -only-testing:BookwormsLiveTests/LiveServiceTests/testHardcoverReadOnlyContract \
  CODE_SIGNING_ALLOWED=NO test
```

For CWA, select `BookwormsLiveTests/LiveServiceTests/testCWAReadOnlyContract` and use a distinct result path. Both checks fetch the configured test library read-only; they make no provider mutations or AI requests. Missing authorization or configuration fails the check instead of silently skipping it. Assertions and failures omit tokens, book contents, and raw server responses.

Run these checks separately after changes to provider requests or decoding, or when investigating service compatibility. Compare changed response structures with the fictional fixtures without copying private data. Offline fixture passes do not establish current server compatibility. Production CloudKit still requires signed-device verification.

## Coverage by feature

| Feature | Local automated checks | Additional device or visual check |
| --- | --- | --- |
| Hardcover PAT authentication | Required token format, Bearer header, invalid/expired token, insufficient scope versus other denial, replacement validation, preservation after rejected input | Read-only key with the configured scopes; verify Keychain survives an app update |
| Hardcover library and metadata | Edition precedence, completion date, reread deduplication, genres, personal/community ratings, high-resolution portrait selection, edition-versus-default cover choice, small and square image rejection, reading line format and date, reader edition format | Newly synced catalog data and unusual server schema responses |
| CWA | OPDS fields, unknown read/rating data, nested description text, pagination, cycles, stable IDs, HTTP errors, HTTPS origin and base-path restrictions | Tailscale connected/disconnected, valid OPDS account, protected cover rendering |
| Multiple sources | Matching and merged ownership, source provenance, persisted freshness, cache-loss recovery, failed-attempt backoff, partial provider failure, rejected replacement, stale response rejection, visible source toggles and relaunch persistence | Real provider compatibility and combined catalogs |
| Shelf choices | Read/owned/all filters, every sort and reverse order, unknown values last, the 40-book limit, five-book steps, visible reverse order and relaunch persistence | Very large real catalogs and missing metadata |
| Shelf navigation | One focus update per press within and across pages, Select/Back focus restoration, Left to the sidebar and back, no movement below the shelf, covers resting on the shelf, and Year in Review covers, year menu, details return, and sidebar | Siri Remote swipes, rapid input, and paging animation on the physical TV |
| Details | Title, long-description scrolling without scrollbar focus, rating chart, cover-choice ranking | Real cover sharpness and extremely long titles/authors |
| Typography and book shape | Title target and author hierarchy, ink density, subtle size bounds, author line spacing, title-height borrowing, cache keys, page packing and size variation | Downloaded calligraphy/decorative fonts, overhanging glyphs, subtitles, viewing distance |
| Light/dark appearance | Appearance mapping, visible settings changes and relaunch persistence, deterministic screenshot exports, accessibility audits of shelf, social views, details, settings, empty and error states | Approve screenshot references; both wood textures, Reduce Motion, actual VoiceOver |
| Four AI providers | Request formats and headers, endpoint validation, key exclusion from URLs, valid/malformed/empty responses, color contrast and font restrictions | Explicitly authorized generation on each provider; cancellation and partial success on a real connection |
| Automatic generation | Missing-design selection, cover requirement, saved-design exclusion, and persisted retry cooldown | Expand the collection, restore cloud designs, stop a batch, and confirm completed designs persist |
| Google Fonts | Entire catalog decoding/caching, anti-XSSI prefix, unsupported-license rejection | Actual downloaded font registration and variable-font appearance |
| Local artwork | Concurrent download sharing, downsampling, disk reuse, size buckets and nearest-size cache fallback, fallback to the alternate cover, failed-cover reporting, cover presentation policy, portrait/square/landscape/missing/corrupt fixtures, and navigation during controlled delayed loading | Cache eviction under tvOS storage pressure |
| Saved designs | Cache removal, corrupt preferences, preferences capacity guard, durable recovery | Upgrade/reinstall restoration from iCloud with the same Apple account |
| iCloud | Fake database tests for account states, no-op uploads, conflict refetch/merge, newer archive rejection; model failure retention, storage toggle, cancellation, and stale completion rejection | Signed-device save/restore, offline recovery, account switching, quota, development/production schema |
| Top Shelf | Poster content and validated deep links, malformed link rejection | Home Screen publishing and cold/warm launch into details |
| User-facing errors | Authentication/permission distinctions, network and certificate guidance, CloudKit account/quota/temporary errors, unknown-error redaction, invalid dates | Confirm each message fits its screen and is understandable with VoiceOver |
| Performance | Cache reuse assertions; no wall-clock timing in simulator tests | Optimized Release build, Instruments, launch/navigation/description scrolling on Apple TV |

Feature coverage is not exhaustive path coverage. Tests with generated responses validate app behavior, not whether an external service currently accepts a specific key or model. A green simulator run does not establish visual quality, production CloudKit readiness, or physical-device performance.

## Device release procedure

1. Run Local and inspect the result and coverage report. Check newly uncovered branches against the feature table.
2. Build and install with `scripts/device-build.py`. Use the stable bundle ID to preserve Keychain and app data. The script removes the project's UI-test runner.
3. Browse forward and backward across at least two pages. Confirm each press highlights only its destination, with no intermediate highlight. Open a book, scroll a long description, and return. Confirm the same book remains selected.
4. Check Views, Shelf, Sources, and General, and the Ambient page. Confirm AI spines is absent and My Shelf and ambient playback show covers even with saved designs. Verify count changes, ordering, both appearance modes, sidebar access, VoiceOver, and Reduce Motion. Use Accessibility Inspector on each screen to check labels, clipped text, and contrast.
5. For source changes, use read-only credentials. Verify offline data remains visible when a server is unreachable and that automatic refreshes respect the daily gate. Verify **Settings → Sources → Sync now** bypasses it. For a Tailscale-only CWA server, connect Tailscale on the TV.
6. For storage changes, verify a signed-device cloud save and a later fetch, then test account unavailable/offline recovery with a test account. Do not erase the user's caches or cloud archive as a routine test. After changing the CloudKit schema, deploy it to production before TestFlight and repeat the production-environment checks.
7. For generation changes, use fake provider responses locally first. Use an authorized test key and a bounded shelf collection. Generation is currently disabled. Verify automatic and explicit entry points cannot start a batch, including with saved credentials. Retained provider request tests use local fixtures.
8. Profile meaningful performance changes in Release on Apple TV. Simulator timing and coverage-instrumented timing are not device performance measurements.

## Social and ambient checks

`SocialFeatureTests` covers presentation policy, ambient views chosen separately from the sidebar, consistent shelf presentation, full-library intersections, stable ordering, review sanitization, view settings, daily gates, manual overrides, cache restoration, access denial, unfollow cleanup, and injected-clock ambient cancellation. `YearInReviewTests` covers year grouping, malformed dates, totals that skip missing values, genre and author ranking, the 40-cover shelf for large years, and adding the view to preferences saved before it existed. `SocialClientTests` uses fictional published-format payloads to verify decoding and complete pagination without live credentials. `SocialNavigationTests` requires one focus update per press for activity cards and review buttons, Compare Shelves column preservation, independent row paging, header entry from each row, and Book Club covers, header, and review actions. It also covers sidebar view switching, detail return, the Book Club sort choice, reader-picker sizing, spoiler reveal, the Ambient page's view toggles, the Compare Shelves ratings card, and ambient input consumption. See [testing navigation](FOCUS_NAVIGATION.md#testing-navigation) for the focus probe and helpers. Native List rows can own focus; verify the selected result rather than requiring their nested buttons to report `hasFocus`.

On Apple TV, verify both comparison rows and independent paging, cover/spine repacking, square covers, unavailable artwork, CWA authentication, and missing-key behavior with saved designs retained. Compare the signed-in reader with a followed reader resolved by username. Inspect spoiler gating in both interactive and ambient views. Profile a Release build through sustained rotation, checking memory growth, focus responsiveness, and the request ledger. Confirm that rotation causes no source sync or AI requests and that the idle timer returns to its normal state after exit or backgrounding.

## Error-writing rules

State what failed and what the user can do next. Distinguish invalid input from rejected credentials, missing permissions, temporary network failures, and storage failures. Do not claim data is current when no sync occurred. Do not display raw server bodies, credentials, CloudKit diagnostics, or file paths. Missing metadata means unavailable; it does not prove a book has no ratings or no description anywhere.

## Primary references

- [Apple: Organizing tests into test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)
- [Apple: XCUIRemote button presses](https://developer.apple.com/documentation/xcuiautomation/xcuiremote/press(_:))
- [Apple: Measuring code coverage](https://developer.apple.com/documentation/xcode/determining-how-much-code-your-tests-cover)
- [Apple: Writing and running performance tests](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)
- [Apple: Accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)
- [Apple: Testing CloudKit apps](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html) (archived guidance on development versus production environments)

For the authorized physical-device social check, set `TEST_RUNNER_VERIFY_DEVICE_SOCIAL=1` and run the Device plan with `--only-testing BookwormsUITests/DeviceSocialTests`. This selects @adam from the fetched follow list; it does not hardcode a reader ID or follow an account. It requires @adam to be followed already.

For a three-minute untouched ambient profiling session, set `TEST_RUNNER_VERIFY_DEVICE_AMBIENT_SOAK=1` and select `BookwormsUITests/DeviceAmbientProfileTests/testSustainedAmbientPlayback` in the Release Device plan. Attach app-only Instruments recording after the log prints `Ambient profiling ready`. The test validates directional exit after several content changes; clock tests cover the longer view and session deadlines.

For a repeatable shelf and detail profile, set `TEST_RUNNER_VERIFY_DEVICE_NAVIGATION_PROFILE=1` and select `BookwormsUITests/DeviceAmbientProfileTests/testShelfNavigationProfile` in the Release Device plan. Attach Instruments after `Navigation profiling ready`; the test allows 20 seconds before paging horizontally, opening the selected book, and checking focus restoration. This test uses the saved library without requiring a specific title.

## Diagnose navigation lag

Follow [the performance diagnosis procedure](PERFORMANCE_DIAGNOSIS.md) for clean Release baselines, opt-in menu tests, timing markers, controlled isolation, and restoration. Diagnostic markers remain opt-in; normal builds use the same prepared-data and focus behavior without instrumentation. `PreparedPresentationTests` verifies credential-presence reads and comparison invalidation without real credentials or network access.
