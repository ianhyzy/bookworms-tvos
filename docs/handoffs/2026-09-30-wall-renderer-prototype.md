# Book Wall renderer prototype

`RealityRenderer` is the candidate for controlled-resolution device comparison. Both alternative hosts render the shared wall in the tvOS Simulator. `ARView` remains the default. This prototype does not establish a physical Apple TV frame rate or a speedup.

## Isolation and verification

- Branch: `wall-renderer-prototype`; base: `622d9e5`; implementation: `c1c8785`.
- Worktree: `/private/tmp/bookworms-wall-renderer`.
- Xcode 27.0 (`27A266a`), separate tvOS 26.0 Apple TV 4K (2nd generation) Simulator at 4K output. Data came from the Debug `artwork` scenario.
- Simulator build and strict `swift-format` lint passed for all six edited Swift files. `git diff --check` passed. Navigation test sources were extended; tests were not run.
- A final launch without a host argument rendered the default ARView wall, initial bookmark ribbon, shelf label, and native header.
- No physical-device commands, installs, profiling, pushes, merges, or changes to the other agent's worktree occurred.
- Captures, console logs, build log, and binary hashes are in the ignored `.local/wall-renderer-prototype/` folder. `capture.json` identifies the committed comparison candidate.

## Drawable measurements

All measurements below are **Simulator-only**. The native interface and screenshot remain 3840 × 2160 regardless of the scene texture size.

| Host and configuration | Actual drawable | Internal scene texture | Result |
| --- | --- | --- | --- |
| RealityView, `displayScale=1` | 3840 × 2160 | Framework-owned | Shared wall renders; scale override does not produce 1080p. |
| RealityView, `displayScale=2` | 3840 × 2160 | Framework-owned | Same drawable size. |
| RealityRenderer, native 1080p | 1920 × 1080 | 1920 × 1080 | GPU presentation completes. |
| RealityRenderer, 900p to 1080p | 1920 × 1080 | 1600 × 900 | GPU presentation completes; lettering is softer. |
| RealityRenderer, 720p to 1080p | 1920 × 1080 | 1280 × 720 | GPU presentation completes; lettering is visibly softer. |

RealityView's passive `CAMetalLayer.drawableSize` initially reports 0 × 0 for automatic sizing. `--wall-surface-probe` acquires and releases one public drawable without presenting, and records its texture dimensions separately. The acquired texture and layer then report 3840 × 2160 at both scale settings. Exclude these probe runs from timing comparisons. Renderer logs record the actual acquired drawable and allocated internal texture.

ARView's passive layer log also reports 0 × 0 for automatic sizing. Its backing texture was not independently sampled; the existing `contentScaleFactor` cap remains unchanged.

## Host behavior and parity

- **RealityView:** mounted as a sibling behind native tabs, outside `TabView.background`; virtual camera, antialiasing off, standard dynamic range, and `content.project(point:to:)`. The scene's environment is supplied through image-based light components and model receivers.
- **RealityRenderer:** a `CAMetalLayer` view in the existing background; explicit output/internal sizes, shared perspective camera and environment, antialiasing off, and a 30/60 Hz display-link request. A shared GPU event orders the bilinear presentation pass after rendering. One frame remains in flight. MetalFX is not implemented.
- Both reuse the hardcover entities, collision events, fall, motion clock, fades, lighting animation, ribbon, and prepared shelf labels. Captures show the settled stacks, initial focus pull, ribbon, label, and native header with similar framing and appearance. Smaller textures soften artwork and text; pixel-identical output is not claimed.
- Host attachment and first presentation refresh retained focus rectangles. Fatal renderer errors detach the adapter and cancel flights; a later opening fails instead of waiting indefinitely. Leaving and reentering the wall creates a fresh renderer.
- The settled fixture produces eight focus rectangles, all inside the viewport. RealityView projection agrees with the shared camera calculation within 0.0001 point. Renderer projection uses that calculation directly; its zero error is internal consistency, not independent rendered-pixel alignment. This checks geometry, not directional focus-update counts.
- **Pending interaction checks:** directional focus-update counts, edge-book flights, fade/return, replay/header reachability, sidebar return, tab reentry, VoiceOver, and Reduce Motion. The Mac was locked during computer-use checks. Source coverage exists for counted directions, sidebar movement, detail return, reentry, and replay, but it has not executed.

## API constraints and remaining work

RealityView has no public drawable-resolution setter in the installed tvOS SDK. Its camera-control modifier is unavailable on tvOS; `cameraTarget` is an orbit target, so the shared `PerspectiveCamera` defines the view. Neither alternative exposes ARView's statistics overlay or its undocumented frame-rate switches. Those diagnostics remain on the default ARView path; alternatives log surfaces, projection, lifecycle, and first presentation.

Allow roughly 1–2 hours for the pending Simulator interaction matrix and half a day for a matched, optimized Apple TV comparison by the device owner. These are estimates. Compare native 1080p first, then 900p/720p at the same requested cadence. Disable capture/probe/checker overhead for timing. Texture upscaling, color conversion, GPU synchronization, camera selection, and environment/shadow differences remain device risks. Host replacement alone does not remove the measured fragment workload. MetalFX would require a separate implementation and visual/device verification.

See [host arguments and architecture](../BOOK_WALL.md#opt-in-render-host-prototypes) and [comparison procedure](../TESTING.md#render-host-prototype-checks) for repeatable commands. Stop and launch separately when changing hosts; immediate terminate-and-launch attempts left some Simulator runs on the Home Screen and were excluded from successful captures.
