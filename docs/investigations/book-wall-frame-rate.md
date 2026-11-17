# Book Wall frame rate on Apple TV

Book Wall reaches 60 fps on the Apple TV 4K (2nd generation, A12) most of the time, but it
still drops frames at transitions, and its design leaves no margin for heavier scenes such as
a domino run. This note records what earlier work measured and ruled out, and the structural
causes a code review on 2026-11-17 found. That review changed no code and ran nothing on the
TV.

The figures below come from session transcripts of 2026-09-28 through 2026-11-04. The
summaries they cite were deleted, so treat them as reported, not as re-derived. See
[Book Wall](../BOOK_WALL.md) for the current design and
[performance diagnosis](../PERFORMANCE_DIAGNOSIS.md) for the measurement procedure.

## What was ruled out

- **`ARView` at 4K.** About 20 fps. Cutting triangles from 2.1 million to 120,000 changed
  nothing, so the scene was never limited by geometry.
- **`ARView` at 1080p.** 20–25 fps with the lit backdrop. It ran at either 60 or 20 fps,
  and flipped between them from run to run at 720p. Its tvOS version can't turn off its
  post-processing.
- **`RealityView`.** It renders at the display's native 4K whatever its size or scale, and
  it drew nothing in the tab view's background.
- **`RealityRenderer` drawing into the layer's drawable.** 59–60 fps at rest, but RealityKit
  lost its later passes on the TV, so the fading wall popped in.
- **Waiting for GPU completion on the main thread before presenting.** About 36 fps.
- **Lower resolution as the fix.** 900p saved 3 of 24 ms of GPU time. 720p halved it, at a
  visible cost in sharpness.
- **Fill lights, page edges, hinge decals, the ribbon, and the focus shadow.** Removing each
  changed no frame rate.
- **4× multisampling.** No measurable cost on `RealityRenderer`.

## What moved the numbers

- **Baking the backdrop's lighting** into an unlit image: GPU time while a book opens fell
  from 24–27 ms to 10.5–13.8 ms per frame. The cost was per-pixel physically based shading,
  not geometry.
- **An opaque Metal layer and fully transparent focus targets:** 10–17 ms of system
  compositor time fell to 1–4 ms.
- **A flat Show more button** instead of glass or a bordered style: 40 fps to 60 fps with a
  book open.
- **Fading the detail text before the return flight:** the return went from 44–49 fps to
  59–60 fps, because SwiftUI's teardown of the panel took 45–50 ms on the main thread.
- **Turning off continuous collision detection on landed books:** removed about 600 ms of
  main-thread logging by the physics engine.

## Latest device run (2026-11-04, 28 books)

- Fall: 60 fps after one 125–145 ms stall at its start.
- Opening a book: 60 fps with one stall, 115–125 ms for the first book and about 70 ms for
  later ones.
- Focus movement: 60 fps, with a worst gap of 55 ms.

No run measured a full 50-book page, GPU time per frame on the current renderer, or the
`wall-no-ibl`, `wall-unlit-shelf`, `wall-warm-light`, and `wall-detail-30` variants. The
`BookWallRendererPipeline` counters have no recorded results.

## Structural causes found in the code

These follow from the code and the measurements above. None has its own device measurement.

- **The render loop shares the main thread with SwiftUI.** `RealityRenderer` must update and
  encode on the main actor, where an earlier profile put 97% of the frame callback. Every
  SwiftUI update longer than a refresh is a dropped frame, which matches the stalls at the
  start of a fall and of a flight.
- **RealityKit's per-pixel cost can't be reduced.** Every lit pixel pays for physically based
  shading with an environment lookup, three point lights, and a directional light. The app
  can't simplify that shader, only remove pixels from it, as the backdrop bake did.
- **Each book is about ten draw calls with its own materials:** the page block, three page
  edges, two headband stripes, the casing, the spine, the cover, and a transparent hinge
  decal. A 50-book page is about 500 draw calls, and nothing is instanced or batched.
- **The wall fades through `OpacityComponent` on every book** during the detail flight, so
  the whole wall draws blended while the selected book flies: the costliest pixels at the
  moment the main thread is busiest.
- **The fall runs a physics engine for one-dimensional motion.** Each book's sideways motion
  and rotation are locked and it lands at a height the layout already computed, so the fall
  is a closed-form function of time. The collision handlers start a task for every contact
  event, every frame, while books fall.
- **The first use of a state can compile shaders.** The first opened book stalls longer than
  later ones, which fits pipeline compilation when the detail light and the opacity fade
  first appear. `wall-warm-light` exists to test the light half of this and has no result.

## Metal prototype on the Apple TV (2026-11-17)

`--wall-renderer=metal` draws the fall and focus with Metal from a display link on its own
thread (`BookMetalWall.swift`). Measured on the Apple TV with a 29-book page, in a Release
build, from the renderer's log and one 40-second Instruments recording of the resting wall
drawn continuously (Time Profiler, Display, Hitches, GPU).

- **The app's share of a frame is small.** The render thread takes about 0.6 ms. The GPU
  draws the wall in about 0.4 ms of vertex work and 3.4 ms of fragment work at 1080p with 4×
  multisampling.
- **The system compositor takes more than the app.** Every frame in which the wall changes,
  `backboardd` spends about 5.9 ms of GPU time composing the app's surface into the
  3840 × 2160 screen, and about 2.6 ms more in two compute passes and two small fragment
  passes that read the composed surface. The wall can't skip the compositor: Instruments
  reports that its surface "cannot go direct to display due to display rejected".
- **The two share one GPU.** The app's fragment pass often waits behind the compositor's
  pass for the previous frame, so the time from a frame's first GPU work to its last reads
  8 to 9 ms in the app's own log. That figure is not the wall's cost.
- **Load is not the limit.** Drawing and shading every book 20 times a frame
  (`--wall-metal-stress=20`) still drew 61 frames a second.
- **Hitches remain.** In the 40 seconds, five composed frames stayed on screen for two
  refreshes or more (one for 50 ms), and the compositor showed an app frame twice five times
  and skipped one. The Hitches instrument recorded no rows for this Metal layer.
- **What was ruled out for those hitches:** the render thread, whose callbacks kept arriving
  every 16.7 ms, and the app's GPU work, at a fifth of a frame.
- **What wasn't separated:** whether the compute passes are the glass on **Drop again** and
  the sidebar's pill, how many hitches a main-thread stall causes (about half of the late
  frames in the app's log followed a main-thread gap of 16 ms or more), and how much the
  recording itself added.
- **Measurement pitfalls.** A drawable's `presentedTime` reads zero for whole seconds while
  Instruments shows those frames on screen, so it can't count drops.
  `preferredFrameLatency` values of 1, 2, and 3 gave the same lead of two refreshes.

### Overlay and no-book controls (2026-11-17)

Seven more 40-second recordings of the resting wall drawn continuously, with the Display and
GPU instruments only. "Long frames" are composed frames that stayed on screen for two
refreshes or more.

| Run | Long frames | App frames shown twice / skipped | App GPU per frame | Compositor GPU per frame |
| --- | --- | --- | --- | --- |
| Books, overlays (3 runs) | 4, 4, 5 | 5 / 3 to 5 | 4.1 ms | 9.4 ms |
| No books, overlays (`--wall-metal-stress=0`, 2 runs) | 12, 13 | 5 / 4 to 9 | 3.0 to 4.2 ms | 7.5 ms |
| Books above every other view (`--wall-metal-bare`, 2 runs) | 145, 170 | 15 to 21 / 79 to 100 | 8.1 ms | 5.7 ms |

- **The books don't cause the hitches.** A wall that draws no books hitches at least as
  often.
- **The books are almost free.** The app's GPU time is about the same with no books, so it is
  the backdrop and the 4× multisample resolve, not the books.
- **The overlays cost about 3.5 ms of compositor time** (the compute passes disappear without
  them), but they don't cause the hitches either.
- **Not explained:** drawing the wall above every other view doubled the app's GPU time per
  frame at the same 1920 × 1080 size and made hitches about 30 times as frequent. Don't move
  the wall's layer above the split view without finding out why.
- **Not done:** the main thread's stacks at rest. The first recording had them and was
  deleted before they were read.

### A periodic display freeze outside the app (2026-11-17, afternoon)

Later the same day, every recording of the resting wall showed a freeze of about 100 ms
(six refreshes) every 2.82 seconds, which the morning's recordings did not have.

- **It is not the app.** A Time Profiler recording of the app shows its threads quieter
  during the freezes than between them, and the main thread idle.
- **It is not another process's CPU work.** A Time Profiler recording of every process shows
  the app, `backboardd`, and the kernel all quieter during the freezes.
- **The display stops asking for frames.** The Display instrument's VSync requests stop for
  55 to 100 ms at each freeze.
- **It is not Instruments.** The app's own log shows the same 100 ms gaps with nothing
  attached.
- **Between freezes the wall is clean.** One 41-second recording had 16 freezes and one
  other long frame, of 33 ms.
- **Not found:** what stops the display. Home Assistant reported the Sony TV off and the
  receiver on throughout, and `audiomxd` used about 30% of a core with AirPlay daemons
  running. Neither was tested as the cause. Check the HDMI chain and the TV's power before
  reading any frame-pacing result from this Apple TV.

### What decides the app's GPU time per frame

- **Two patterns.** When the compositor's 5.9 ms pass reaches the GPU first, the app's
  fragment work runs after it in 3.4 ms. When the app's work arrives first, the two overlap,
  the compositor's pass keeps its length, and the app's takes about 8 ms. Alone on the GPU it
  takes 2.6 ms.
- **A race decides it.** Both start about 2.5 ms after a refresh. The wall under its overlays
  arrived second in about 90% of refreshes, and the wall above every other view arrived
  first in 98%.
- **Holding the app's work back removes the overlap but not the hitches.**
  `--wall-metal-commit-delay=5` made the bare wall arrive second in 93% of refreshes, at
  2.6 ms a frame, with as many long frames as before. The bare wall's hitches, about four a
  second with two app frames in one refresh, are still unexplained.
- **No effect on long frames:** leaving the display link at the display's rate, 59.94 Hz,
  instead of asking for 60 (`--wall-metal-rate=display`), and unpausing the running link on
  every main-thread change (`--wall-metal-poke`).

## If this is taken up again

- Measure a full page first with `scripts/profile-book-wall.py --capture-set full`, so that
  GPU time per frame and the transition stalls on the current renderer are known.
- The iPhone and Mac Desk can't move to the Apple TV as written: it simulates up to 300
  bodies live, draws every book into a spot light's shadow map, and issues 1,200–1,500 draw
  calls.
