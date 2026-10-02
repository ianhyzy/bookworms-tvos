# Book Wall RealityRenderer results — 2026-09-30

The owner chose RealityRenderer as the Book Wall renderer on 2026-10-01, and ARView
was removed. With slot-texture presentation (`2798fdc`) and 4× multisampling, the
1080p renderer holds about 59 fps while navigating, 55–60 fps (median) while a book
opens, and 60 fps during the return flight. The [open-book
section](#open-book-frame-rate) traces the earlier 40 fps open state to the glass
**Show more** button over the moving wall; Book Wall now draws it as a flat platter.

The first comparison below used the earlier queued presentation path, which
sustained only 34–38 fps. All local evidence paths are relative to the tvOS
repository root.

## Settings and measurement

- Renderer: `--wall-host=renderer`, 1920 × 1080 internal and output sizes,
  Display P3 layer tagging with `bgra8Unorm_srgb`, standard dynamic range, opaque
  output, and a 60 Hz display-link request.
- AA-off profiles use `.none`; AA-on profiles use `.multisample4X`. ARView retains
  its existing renderer-controlled antialiasing; the wrapper's AA argument does
  not configure ARView.
- The measured renderer uses two frame slots and three drawables. It renders
  directly into matching-size drawables, then uses an event-ordered presentation
  command buffer in `f143c13`. The current implementation (`edd5196`) presents
  matching-size drawables from RealityRenderer's scheduling callback without a
  separate queue. Its paired measurements are in progress.
- The profiling wrapper builds Release with the `BookwormsDevice` scheme and
  restarts the TV by default. These runs use `wall-hide-statistics`, Time Profiler,
  Points of Interest, Hitches, Display, and GPU instruments. The scripted Book Wall
  sequence is unchanged.
- All six manifests report no LLVM coverage sections, screenshot-only automatic
  capture with `keepNever`, and both test and trace exit codes of 0. The runner
  disables the UI performance checker and removes checker-library injection.
  All six summaries contain `display-surface-swap` and `metal-gpu-intervals`.
- Each ARView pair shares one executable hash (`23aa1f786263…`); all four P3
  renderer runs share another (`6f5d0a4e0f78…`). The full hashes remain in each
  manifest. These are matching binaries within those groups, not one identical
  binary across the entire table.

Frame rates below come from the summaries' Display-derived
`frames_per_second` arrays, which count swaps in complete one-second bins.
Control, slow-navigation, and navigation values are medians. Warm selection is
the mean of all bins in `select-1` and `select-2`; `select-0` is excluded as the
first-open interval. Return is the mean of all bins in `return-0`, `return-1`, and
`return-2`, after the first opening has occurred. These phase means include each
scripted observation interval; they do not isolate only the 1.8-second flight.

## Completed physical results

Each run's source is
`.local/performance-diagnosis/<run folder>/tables/summary.json`, with settings and
exit codes in the adjacent `manifest.json`.

| Configuration | Run folder | Control median | Slow-navigation median | Navigation median | Warm selection mean | Return mean |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| ARView A | `20260930-143315-arview-1080-a` | 24.5 | 26.0 | 27.0 | 25.9 | 23.9 |
| ARView B | `20260930-143954-arview-1080-b` | 25.0 | 25.0 | 26.5 | 25.5 | 23.7 |
| Renderer, AA off, A | `20260930-145644-renderer-1080-off-a-p3` | 34.5 | 34.0 | 37.0 | 42.0 | 35.2 |
| Renderer, AA off, B | `20260930-150434-renderer-1080-off-b-p3` | 36.0 | 34.0 | 37.5 | 42.0 | 35.6 |
| Renderer, 4× MSAA, A | `20260930-151118-renderer-1080-msaa-a-p3` | 32.5 | 33.0 | 35.5 | 35.2 | 34.3 |
| Renderer, 4× MSAA, B | `20260930-151741-renderer-1080-msaa-b-p3` | 31.0 | 32.0 | 35.5 | 36.3 | 34.1 |

All numbers are fps. The required medians are at least 58 fps in each of control,
slow-navigation, and navigation in both renderer runs. Every renderer median in
this table fails that requirement. Warm selection and return must average at
least 55 fps; both renderer settings also fail those checks. Brief 60 fps bins in
one detail-selection interval do not establish sustained 60 fps.

Per-phase means preserve the variation hidden by aggregation:

| Run suffix | Select-1 | Select-2 | Return-0 | Return-1 | Return-2 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `arview-1080-a` | 24.4 | 27.4 | 25.6 | 22.5 | 23.8 |
| `arview-1080-b` | 23.4 | 27.6 | 24.8 | 22.0 | 24.4 |
| `renderer-1080-off-a-p3` | 36.0 | 48.0 | 38.0 | 32.3 | 35.7 |
| `renderer-1080-off-b-p3` | 34.0 | 50.0 | 36.3 | 31.4 | 38.5 |
| `renderer-1080-msaa-a-p3` | 31.0 | 39.4 | 37.0 | 33.2 | 32.8 |
| `renderer-1080-msaa-b-p3` | 32.2 | 40.4 | 36.0 | 32.0 | 34.0 |

The earlier run `20260930-144549-renderer-1080-off-a` completed the scripted test
with exit code 0, but xctrace crashed while stopping/saving (`trace_exit = -11`).
It has no usable summary and is excluded from all performance comparisons.
The host crash was in the kernel-trace decoder; it is not evidence of an app
crash, nor evidence that the renderer passed the frame target. GPU-specific
recorder causality was not established.

## Simulator color evidence

The initial renderer's sRGB layer tag produced a systematic saturation shift.
Changing only the layer tag to Display P3 removed that shift in saved Simulator
captures while retaining the same pixel format, SDR, 1080p size, materials, and
lighting. No backdrop lighting constants were refitted and the ARView rendering
path was not changed by that correction.

Evidence:

- Original comparison:
  `.local/screenshots/20260930-143111-renderer-color-parity/`.
- P3 comparison, capture metadata, images, and sampled-region measurements:
  `.local/screenshots/20260930-144204-renderer-displayp3-candidate/`, especially
  `comparison.md` and `color-comparison.json`.

The P3 resting frame has mean absolute RGB differences of approximately
`[0.672, 0.733, 0.712]` on a 0–255 scale relative to ARView. Its 95th and 99th
percentiles are 2 per channel. The original red-ribbon sample shifted from about
`[161.81, 22.21, 26.32]` to `[148, 38, 34]`; the P3 candidate restores it to
`[161, 21, 26]`. Resting and open-detail captures show matching major geometry,
lighting patterns, text, and materials, with small remaining pixel differences.

These are empirical comparisons of untagged PNGs on one tvOS 27 Simulator model,
not calibrated display measurements. Open-pose differences can include idle
motion timing. The logged projection-error value compares the same projection
helper with itself and is not independent alignment evidence. Physical Apple TV
color, full transition parity, accessibility, and owner visual approval remain
pending in this draft.

## Open-book frame rate

These runs use the direct-presentation renderer at 1080p with antialiasing off and
the reduced Display + Points of Interest capture set (`--capture-set display`).
The open state is the last two one-second bins of `select-1`, after the flight
and text fade. Each row is one run unless noted. Run folders end with the label
shown, under `.local/performance-diagnosis/`; traces were pruned after analysis.

| Variant | Label | `select-1` bins (fps) | Open state |
| --- | --- | --- | ---: |
| Baseline, 2 runs | `renderer-direct-display-a/b` | 58–60, 52–53, 32–45, 40, 40 | 40 |
| Wood corner bounded to 300 × 144 points | `corner-display-a/b` | 59–60, 54, 42–43, 40, 40 | 40 |
| `wall-no-detail-corner` | `corner-no-corner` | 60, 54, 45, 41, 40 | 40 |
| `wall-detail-hide-tabs` | `detail-hide-tabs` | 60, 55, 35, 43, 41 | 41 |
| Back drawn bordered, borderless, or flat (diagnostic styles, since removed) | `back-bordered`, `back-borderless`, `back-flat-a/b` | bordered 40, 40; borderless 53, 55; flat 40, 40 and 40, 52 | 40–55 |
| `wall-no-detail-back` | `detail-no-back` | 60, 54, 36, 44, 60 | 44–60 |
| `wall-no-detail-panel` | `corner-no-panel` | 59, 55, 53, 47, 59 | 47–59 |
| `wall-detail-30` | `detail-30` | 60, 54, 23, 30, 30 | 30 (by design) |

The swap-only runs above were affected by book choice and, later, by an
unreliable entry step. The following full-instrument runs add app and compositor
GPU time per second (`gpu_ms_per_second`) and start from the same entry book. The
open state uses the last two seconds of each `select` phase. Rows list valid runs
only; runs with missing provider data or a different starting book are excluded.

| Variant | Label | Open state (fps) | Compositor GPU (ms/s) |
| --- | --- | ---: | ---: |
| Baseline, `select-1` book, 3 runs | `gpu-baseline-b`, `sms-baseline-a/b` | 40 | 590–660 |
| Baseline, `select-2` book (no **Show more**) | `gpu-baseline-b` | 60 | 260–300 |
| `wall-no-detail-panel` | `gpu-no-panel-a` | 60 | 280–300 |
| `wall-no-show-more` | `sm-no-show-more-a` | 60 | 280–360 |
| `wall-show-more-borderless` | `sms-borderless-b` | no `select-1` data | — |

At rest, the compositor uses about 230 ms of GPU time per second (3.8 ms per frame).
With the glass **Show more** visible, it rises to about 15 ms per frame while the app
needs about 6 ms, which exceeds the 16.7 ms frame budget.

Findings:

- The cost comes from the glass **Show more** button, which appears only when a
  book's description overflows. Hiding it, or opening a book without it, keeps the
  open state at 60 fps with the glass Back button present. Glass samples the wall
  behind it, and the wall changes every frame.
- The earlier Back-style and wood-corner results were confounded by this button;
  none of those changes addressed it.
- A borderless **Show more** has no physical result yet: one run failed to launch
  and the other lost provider data for that phase.
- `toolbarVisibility(.hidden, for: .tabBar)` does not hide the tvOS 26 floating tab
  control; Simulator captures show it behind Back either way.

The owner approved the flat **Show more** platter, which keeps the open state near
60 fps.

## Verification status

The six valid performance runs completed the scripted performance test. That does
not replace the complete Book Wall navigation, lifecycle, Reduce Motion, or
VoiceOver checks.

The local worker at `.local/test-worker/20260930-193105-2697b9df/handoff.md`
reports setup failure: writing the Xcode Devices `enableAudioOutput_tvOS`
preference returned exit code 1. Its counts are empty, visual review is blocked,
and offline-enforcement evidence is missing or failed. No local runtime test pass
can be claimed from that attempt; it is a setup blocker, not a demonstrated test
assertion failure.

All six edited Swift files pass strict formatting. The integrated Simulator app
compiles after the direct-presentation, lighting-diagnostic, and physical-capture
test changes (`edd5196`). The isolated host also compiles in ordinary and
diagnostic Release configurations. These builds do not prove runtime parity
or a performance improvement. Candidate notes are under
`.local/direct-present-candidate/` and `.local/optimization-candidate/`.

## Pending experiments and constraints

1. The queued-path standalone capture at
   `.local/performance-diagnosis/20260930-152250-pipeline-queued-1080/`
   confirms two outstanding frame slots and actual layer scale 1. Window maxima
   for drawable acquisition range from 17 to 50 ms. Outstanding slots do not
   establish simultaneous GPU execution. The direct-presentation pair is in
   progress; retained trace analysis will separate submission and display timing.
2. Measure renderer-only `wall-no-ibl` after the pipeline check. It sets root
   environment-light weight to zero and skips studio environment generation,
   preserving local lights. This is an isolation experiment, not a proven
   appearance-preserving replacement.
3. Measure `wall-unlit-shelf` independently as an upper bound on shelf-material
   savings. It preserves the rounded geometry, label, collision, physics, and
   inherited opacity but uses a constant unlit tint. It is not a fitted bake.
   Negligible savings would not justify a more complex baking implementation.
4. A fitted shelf bake needs additional evidence. The shelf remains fully opaque
   through detail-light level 0.35 while shelf, pool, directional, environment,
   and selected-book-dependent detail lighting change. Current resting and fully
   open captures cannot fit that transition. The smallest future approach would
   use a fitted resting bake and retain the original PBR material whenever the
   detail-light level is nonzero; visual continuity still requires verification.
5. Measure 1600 × 900 internal rendering if the higher-resolution work still
   misses the target. The existing lower-resolution path uses bilinear scaling;
   no result for it is included here and no lower-resolution default is approved.
6. MetalFX spatial upscaling remains unimplemented. Apple's current descriptor,
   scaler, factory, support-check, and encoding metadata specify tvOS 27.1. The
   installed AppleTVOS27 headers omit explicit tvOS availability annotations, and
   no actual tvOS 26 SDK was found. Neither SDK symbol visibility nor the tvOS 26
   release note for a different temporal-scaler API establishes supported spatial
   scaling on tvOS 26. Earlier runtime presence and device support remain
   unverified. See the [spatial-scaler reference](https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerdescriptor)
   and [tvOS 26 release notes](https://developer.apple.com/documentation/tvos-release-notes/tvos-26-release-notes).
7. Complete physical captures and interaction/accessibility checks, obtain owner
   visual approval, and restore the ordinary local build after device work.

With RealityRenderer as the only host, VoiceOver, Reduce Motion, and the Book Wall
navigation tests still need a run.
