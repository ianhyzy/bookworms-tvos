# Contributor instructions

These instructions apply throughout this repository. Follow explicit user instructions when they change the task's scope or requirements.

`README.md` is reserved for owner-authored public content; leave it blank unless the owner asks you to populate it.

## Start here

This repository contains **Bookworms - eBook Display**, a Swift 6 and SwiftUI app for tvOS 26 and later. It reads Hardcover and Calibre Web Automated libraries without a companion rendering server. Each platform app has its own folder and Git repository; keep tvOS changes here.

| Task | Starting points |
| --- | --- |
| App lifecycle and library state | [BookwormsApp.swift](Bookworms/BookwormsApp.swift), [LibraryModel.swift](Bookworms/Services/LibraryModel.swift) |
| Navigation and view preparation | [ShelfView.swift](Bookworms/Views/ShelfView.swift) |
| Focus and remote navigation | [FOCUS_NAVIGATION.md](docs/FOCUS_NAVIGATION.md), [RemoteNavigation.swift](BookwormsUITests/RemoteNavigation.swift) |
| Year in Review | [YearInReview.swift](Bookworms/Models/YearInReview.swift), [YearInReviewView.swift](Bookworms/Views/YearInReviewView.swift) |
| Social data and comparisons | [SocialLibraryModel.swift](Bookworms/Services/SocialLibraryModel.swift), [SocialPresentation.swift](Bookworms/Models/SocialPresentation.swift) |
| Cover caching and appearance | [ArtworkStore.swift](Bookworms/Services/ArtworkStore.swift), [CoverView.swift](Bookworms/Views/CoverView.swift) |
| Snapshots and iCloud | [SourceLibraryStore.swift](Bookworms/Services/SourceLibraryStore.swift), [CloudLibraryStore.swift](Bookworms/Services/CloudLibraryStore.swift) |
| Home Screen extension | [ContentProvider.swift](BookwormsTopShelf/ContentProvider.swift), [TopShelfSnapshot.swift](Shared/TopShelfSnapshot.swift) |
| Targets and build settings | [project.yml](project.yml) |

Read [architecture](docs/ARCHITECTURE.md) for data flow, [development setup](docs/DEVELOPMENT.md) for local and device workflows, [testing](docs/TESTING.md) for verification, and [release instructions](docs/RELEASING.md) for distribution. Check [privacy](docs/PRIVACY.md) before changing external transfers or retention. Preserve [texture attribution](docs/TEXTURE_CREDITS.md) and [icon source documentation](design/icon/README.md).

Run commands from the repository root:

| Purpose | Command |
| --- | --- |
| Regenerate the Xcode project | `xcodegen generate` |
| Check formatting on an edited file | `xcrun swift-format lint --strict path/to/ChangedFile.swift` |
| Build and install on the Apple TV (default verification) | `python3 scripts/device-build.py` |
| Compile without a TV | `xcodebuild -project Bookworms.xcodeproj -scheme Bookworms -destination 'generic/platform=tvOS Simulator' -derivedDataPath .build-compilecheck build CODE_SIGNING_ALLOWED=NO -quiet` |
| Run tests (only when the user asks) | `python3 scripts/test-worker.py --detach`, with `--profile unit` or `--profile major` when requested |

`device-build.py` reads the Apple TV UDID and team ID from the ignored `.local/device-build.json` (`{"device": "…", "team": "…"}`) when `--device` and `--team` are omitted.

Inspect generated changes after modifying project settings or target membership. Xcode signing edits can cause generated files to differ from `project.yml`.

## View and source reference

Maintain [VIEWS.md](VIEWS.md) for tvOS view options and [DATASOURCES.md](DATASOURCES.md) for providers, merging rules, defaults, and limits. Update these references when behavior changes; link to them instead of duplicating their inventories in technical guides.

## Current feature constraints

- Keep the CWA source hidden in Settings (`BookPresentation.offersCWA`) while preserving its client, configuration, credentials, and tests.
- Keep generated-spine views, AI provider settings, generation entry points, and spine font restoration disabled. Preserve retained implementations, designs, and credentials. The feature switches live in [BookPresentation.swift](Bookworms/Models/BookPresentation.swift).
- Use shared cover components for consistent focus effects across sizes and views. Respect Reduce Motion. On shelves, stand covers on `ShelfBoard` and pass `standsOnShelf: true` to `CoverView`. Keep shelf effects subtle and static: fade prebuilt shadows with opacity instead of animating a blur radius.
- Show a reader's name with `ReaderLabel`, which adds their Hardcover profile photo. Include any new reader's avatar URL in artwork preparation so photos never download while browsing.
- Keep sidebar visibility (`ViewPreferences.enabled`) and ambient views (`ambientViews`, chosen on the Ambient page) independent. Load data and artwork for `activeViews`, which covers both. Per-view choices belong on their views, not in Settings.
- Set app text with `appFont(size:weight:)`, not `.font(.system(size:))`, so the serif style (New York) uses medium weight for regular text. Settings always uses the system font.
- Limit displayed collections to `BookLimit.maximum` (40) items, except Following at 20, while retaining complete metadata for sorting and intersections. Prepare artwork for enabled views before browsing; do not introduce per-cover Hardcover queries or network calls during scrolling or detail rendering.
- Preserve refresh gates, download sharing, and cache bounds. Consult [storage and performance](docs/STORAGE_AND_PERFORMANCE.md), [sources and iCloud](docs/SOURCES_AND_ICLOUD.md), and [social views](docs/SOCIAL_VIEWS_AND_AMBIENT.md) for detailed behavior.

## Writing

- Follow [Google's technical writing guidance](https://developers.google.com/style/highlights) in responses, documentation, and code comments. Use [Google's Swift comment guidance](https://google.github.io/swift/#documentation-comments) for Swift documentation comments.
- Use active voice, precise terms, short sentences, and sentence-case headings. Prefer plain language to jargon. Use descriptive links, code formatting for identifiers, and bold text for UI labels.
- State the outcome first. Explain relevant limitations and distinguish verified results from assumptions or pending checks.

## Documentation accuracy

- Describe the current implementation. Verify behavior, defaults, commands, paths, and limits against the code before documenting them.
- Update affected documentation when behavior changes. Check this entry point and the affected reference documents together.
- Remove obsolete instructions, resolved-issue narratives, superseded plans, and historical before-and-after descriptions. Retain a compatibility constraint or pitfall only when it still affects correct use or maintenance.
- Keep proposed features and release requirements separate from implemented behavior. Never describe a planned capability as available.
- Keep test logs, traces, and dated measurements in result artifacts. Document repeatable testing procedures instead of presenting an old successful run as evidence for the current build.
- Preserve applicable license notices and attribution. Check relative links after moving or replacing documents.

## Code comments

- Explain intent, constraints, invariants, and non-obvious behavior. Document coordinate conversions, focus timing, credential boundaries, and recovery behavior when the code alone does not explain them.
- Do not narrate obvious operations or record the history of an edit. Avoid comments such as “now fixed” or “changed from the old implementation.”
- Describe a type or function's responsibility in documentation comments. Add details about side effects or failure behavior when callers need them.
- Keep comments consistent with the code. Do not add comments to compensate for an unclear name or unnecessarily complex implementation; improve the code when the task includes that change.

## Review and verification

- **Do not run tests unless the user asks in the current request.** Test plans, individual tests, `scripts/test-local.py`, `scripts/test-worker.py`, and `device-build.py --test` all require that request. Default verification is: lint each edited Swift file with `xcrun swift-format lint --strict`, then install on the Apple TV with `python3 scripts/device-build.py`, which compiles a Release build. If the TV is unreachable, compile with the simulator build command instead. Report which checks ran and name any tests that would add signal, then ask before running them.
- When the user asks for a test run, follow [the local test worker instructions](SUBAGENT-TEST-INSTRUCTIONS.md): start `python3 scripts/test-worker.py --detach` once, end the turn with the dispatch-log path, and do not poll. Read only `handoff.md` afterward. Do not open `build.log`, `coverage.json`, `test-tree.json`, or result bundles unless the user asks; search them with bounded `grep` output instead of reading them whole. Do not retry or rerun single tests to investigate; report the failure.

- Keep review findings distinct from fixes. Track store and TestFlight requirements in [the release workflow](docs/RELEASING.md).
- Keep [the testing procedure](docs/TESTING.md) current when behavior changes, and update affected tests without running them unless asked. For documentation-only changes, check accuracy and links; do not claim runtime verification that was not performed.
- Use the repository's `.swift-format` configuration when editing Swift. Report which checks ran and any material checks that remain pending.

## tvOS architecture and performance

- Target tvOS 26 and later. Prefer current, nondeprecated Apple APIs and verify tvOS availability; an API available on iOS is not necessarily available on tvOS. Do not add compatibility branches for older tvOS versions.
- Use native SwiftUI controls, navigation, focus, and system materials where they fit the interaction. Follow [Apple's tvOS design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos) and [focus guidance](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection). Keep UIKit bridges narrow and explain why they are needed.
- Design for Siri Remote input and TV viewing distance. Preserve stable book identity, directional page entry, and focus when returning from details. Verify that every control is reachable. Respect VoiceOver, Reduce Motion, and system appearance unless the user selects an override.
- Let the tvOS focus engine own directional movement; follow [focus and remote navigation](docs/FOCUS_NAVIGATION.md). Shape movement with layout, `.focusSection()`, and `.defaultFocus`, and show horizontal collections with `PagedRow` so every item stays mounted. Never set focus from `.onMoveCommand`, timers, data changes, or loading completion; assign it only at the entry events that guide lists. If a focus bug survives one fix, report the conflicting focus writers instead of adding another.
- Keep the sidebar reachable with Left from the leftmost item and with Back; do not intercept either. Add a navigation test using `RemoteNavigation.press(_:in:expecting:)` for every direction out of every section whenever introducing or changing a view.
- Treat the library as a read-only snapshot between explicit syncs. Prepare sorting, intersections, eligibility, and page layouts when their data or configuration changes. Remote movement and focus changes must not query Keychain, poll sources, sort libraries, or restart layout preparation. Cache credential-presence flags, not secrets, and refresh them at lifecycle or credential-change boundaries.
- Track idle deadlines without publishing an observed revision for each press. Defer pending artwork repacking until input settles, but do not create new repacking work merely because input occurred.
- Verify ordinary Release executables have no LLVM coverage sections; disabling the build setting alone can be insufficient when the default test plan enables coverage. Use the BookwormsDevice scheme for device builds. Disable XCTest video and checker injection for timing comparisons. Separate focus-notification latency from animation hitches and actual frame presentation; preserve comparable input sequences and measurement overhead.
- Keep view bodies cheap and dependencies narrow. Move networking, decoding, image analysis, and repeated text measurement out of view rendering. Use Observation deliberately; exclude internal caches and task handles from observed state.
- Use Swift concurrency with explicit isolation. Keep UI state on the main actor; isolate service state in actors. Do not assume that creating a `Task` moves expensive work off the main actor. Handle cancellation and prevent stale asynchronous results from replacing newer state.
- Bound memory and disk caches, downsample images, share duplicate in-flight requests, and reuse computed layouts. Preserve saved design choices when reconstructible images or fonts are evicted. Avoid new timers, blur layers, offscreen rendering, or whole-view rasterization without evidence that they improve the experience.
- Measure performance in optimized Release builds on Apple TV. Use Instruments and a repeatable interaction sequence to assess launch time, hitches, CPU, and memory. Do not infer physical-device performance from simulator or coverage-instrumented timings. Follow [Apple's SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
- Keep local tests deterministic and independent of live credentials or paid AI. Install on the Apple TV for the owner's manual check of focus, typography, rendering, and performance changes.
- When the user asks to verify a major change, run the minimum/current simulator matrix with `python3 scripts/test-worker.py --detach --profile major`. An unexpected skip, missing evidence, or blocked runtime is not a pass. Report pending visual, live-service, and device checks separately.
- Control asynchronous completion and inject clocks in tests. Keep real parsing, application state, rendering, and local persistence under test; substitute external services at their boundaries. Do not add arbitrary sleeps or retry a failing test until it passes. Keep simulator scenario hooks inside `DEBUG && targetEnvironment(simulator)`.

## Source account scope

- Support one active account per provider, with books from multiple enabled providers combined into one shelf. Do not add multiple simultaneous Hardcover accounts or an account-switching interface unless requested.
- Hardcover and CWA are implemented providers. Treat other providers, including Bookorbit, as future integrations until their code and tests exist.
- Keep literal credentials out of repository files, command arguments, logs, screenshots, and test fixtures. Use Keychain and authorized 1Password references; see [Hardcover authentication](docs/HARDCOVER_AUTHENTICATION.md).
- Keep credentials provider-specific and library access read-only. Preserve source provenance when merging books. A credential replacement is not permission to combine unrelated accounts from the same provider.

## Versioning and releases

- Follow [the release workflow](docs/RELEASING.md). `project.yml` is the sole source for `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; both app and extension Info.plists must reference these settings. Never edit generated version literals or change bundle IDs for a release.
- Use three numeric components for the marketing version. Use a positive sequential build integer (1–9999). Check the highest uploaded build in App Store Connect before selecting the next number; never claim a local number is available without that check. Build 1 is the initial local candidate, not a confirmed available upload number.
- Increment the build for every new upload candidate, not every code edit. Do not silently change the marketing version. Regenerate with `xcodegen generate` and inspect both generated Info.plists and the packaged app and extension.
- Archive Release with `BookwormsDevice`, whose default test plan disables coverage. Run `scripts/verify-release-archive.py` with explicit expected version and build; it rejects coverage sections and version mismatches. A passing development-signed archive is not distribution validation.
- Keep each candidate archive and dSYMs in a unique ignored `.local/releases/` directory. Record the source commit, Xcode and XcodeGen versions, test results, expected version/build, and archive verification there. Never overwrite an uploaded candidate or commit signing credentials, provisioning profiles, archives, or private test data.
- Test the exact candidate; prior test passes do not validate later changes. Use Xcode Organizer validation for distribution signing and App Store checks. Verify CloudKit production separately.
- Local preparation does not authorize an upload, external invitation, or production CloudKit deployment. Follow the user's explicit release scope; do not ask again for actions already authorized.

- Use `python3 scripts/release.py prepare --highest-uploaded-build N` for new candidates after checking App Store Connect. This increments the build, runs tests, archives, and verifies; do not separately bump the number first. Do not modify candidate sources while preparation runs.
- Use the release script's `validate` command for Apple checks. Run `upload` only with user authorization; it requires validation, a clean working tree, and the recorded source digest. Treat `upload-requested` as uncertain and check App Store Connect before retrying. The signed-in Xcode account or a private API key outside the repository supplies credentials.

## Visual revision evidence

- For each major visual revision, capture the main views on the owner’s Apple TV with the real library: launch with `--start-view=shelf|yearInReview|following|comparison|shared` and use `xcrun devicectl device capture screenshot`. Store the original PNGs and a `capture.json` (commit, date, device) in a new dated folder under the ignored `.local/screenshots/`; never overwrite prior captures. These images contain real library and reader data; do not publish them without authorization.
- The tracked `screenshots/` folder holds only images the README displays.
- Local installs through `scripts/device-build.py` use the LOCAL icon and Bookworms Local display name. Keep the standard icon and public name for release archives.
