# Book Wall frame rate on Apple TV

Book Wall draws with a [Metal renderer](../BOOK_WALL.md#metal-renderer) because the RealityKit
renderer could not hold 60 frames a second on the Apple TV 4K (2nd generation, A12). The RealityKit renderer has since been removed, so its figures here can't be measured again. This
note records what was measured and ruled out on the way, what caused the Metal renderer's
remaining late frames, and one thing that remains unexplained. See [performance diagnosis](../PERFORMANCE_DIAGNOSIS.md#metal-renderer) for how
to repeat the measurements.

The figures up to 2026-11-04 come from session transcripts, whose summaries were deleted, so
treat them as reported. The rest were measured on 2026-11-17 and 2026-11-25 on that Apple TV,
connected through a Denon AVR-X1800H to a 3840 × 2160 display at 59.94 Hz, with a 29-book page.
On 2026-11-25 it ran tvOS 27.2.1 (24K157).

## Ruled out for the RealityKit renderer

- **`ARView` at 4K.** About 20 fps. Cutting triangles from 2.1 million to 120,000 changed
  nothing, so the scene was never limited by geometry.
- **`ARView` at 1080p.** 20–25 fps with a lit backdrop. It ran at either 60 or 20 fps, and
  flipped between them from run to run at 720p. Its tvOS version can't turn off its
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

## What moved the RealityKit renderer's numbers

- **Baking the backdrop's lighting** into an unlit image: GPU time while a book opens fell
  from 24–27 ms to 10.5–13.8 ms per frame. The cost was per-pixel physically based shading.
- **An opaque Metal layer and fully transparent focus targets:** 10–17 ms of system
  compositor time fell to 1–4 ms.
- **A flat Show more button** instead of glass or a bordered style: 40 fps to 60 fps with a
  book open.
- **Fading the detail text before the return flight:** the return went from 44–49 fps to
  59–60 fps, because SwiftUI's teardown of the panel took 45–50 ms on the main thread.
- **Turning off continuous collision detection on landed books:** removed about 600 ms of
  main-thread logging by the physics engine.

On 2026-11-04, with 28 books, it held 60 fps except for one stall of 125–145 ms at the start
of a fall, one of 70–125 ms when a book opened, and a worst gap of 55 ms while focus moved.

## Why RealityKit left no margin

- **Its render loop shares the main thread with SwiftUI.** `RealityRenderer` updates and
  encodes on the main actor, so a SwiftUI update longer than a refresh is a dropped frame.
- **Its per-pixel cost can't be reduced.** The app can remove pixels from its shader, as the
  backdrop bake did, but can't simplify the shader.
- **The system compositor takes about half of each frame's GPU time on this display**, as the
  next section measures, which leaves a renderer about 8 ms.

## What a frame costs with the Metal renderer

From Instruments recordings of the resting wall drawn continuously, with the Display and GPU
instruments.

- **The app:** about 0.6 ms on the render thread, and on the GPU about 0.3 ms of vertex work
  and 2.6 ms of fragment work at 1920 × 1080 with 4× multisampling when it has the GPU to
  itself. A wall that draws no books costs about the same, so that time is the backdrop and
  the multisample resolve.
- **The system compositor:** `backboardd` spends about 5.9 ms composing the app's surface
  into the 3840 × 2160 screen every frame the wall changes, and about 3.5 ms more on passes
  that disappear when nothing is drawn over the wall. The wall can't skip the compositor:
  Instruments reports that its surface "cannot go direct to display due to display rejected".
- **The two share one GPU.** Both start about 2.5 ms after a refresh. When the compositor's
  pass arrives first, the app's fragment work runs after it in 3.4 ms. When the app's
  arrives first, they overlap and the app's takes about 8 ms. The wall under its overlays
  arrived second in about 90% of refreshes.
- **Load is not the limit.** Drawing and shading every book 20 times a frame still drew 61
  frames a second.

## Ruled out for the Metal renderer's remaining late frames

Before [the fix](#the-fix), the resting wall, drawn continuously with nothing attached, had 3
to 9 late frames a minute, each one repeated refresh, often in clusters a few seconds apart.
With Instruments attached, three 40-second recordings had 5, 2, and 8 composed frames that
stayed on screen for two refreshes or more.

- **The books.** A wall that drew no books had 12 and 13 such frames in two recordings.
- **The render thread.** It ran every callback it got on time, with its usual lead.
- **Overlays on the wall.** Drawing the wall above every other view removed the compositor's
  extra passes and made long frames about 30 times as frequent; see the next section.
- **The race for the GPU.** Holding the app's GPU work back 5 ms made it arrive second in 93%
  of refreshes and left as many long frames.
- **The display link's rate.** Leaving it at the display's 59.94 Hz instead of asking for 60
  left as many long frames.
- **Changes from the main thread reaching a running display link.** Unpausing it again on
  every change, or never, made no difference.
- **The display link's frame latency.** Values of 1, 2, and 3 gave the same lead of two
  refreshes.

## What caused the remaining late frames

The system compositor repeated those frames, because the kernel handled the end of its GPU
work late. Measured on the resting wall drawn continuously, with the renderer's log and with
Instruments recordings of the Display, GPU, and System Trace instruments:

- **The app's frames were on time.** At each late frame, the display link skipped one
  callback: the next one came 33 ms after the last, with the usual lead of two refreshes.
- **So was the compositor's GPU work.** It ended about 3.5 ms before the refresh it was for,
  as on any other frame.
- **The completion reached the CPU late.** The compositor's command buffers normally report
  completion 0.3 to 0.4 ms after their GPU work ends. For the frame that missed, the report
  came 3.8 ms after it, 0.25 ms after the refresh. The app's command buffer, whose GPU work
  ended 0.5 ms earlier, reported at the same moment, 4.4 ms late. In a 60-second recording,
  completions came more than 1.5 ms late 6 times, and a frame repeated once, when the delay
  crossed a refresh.
- **The system's audio thread held it.** `audiomxd`'s real-time audio thread (`audio IO: VAD
  [vdef] AggDev 79`, priority 97) ran a burst of 6.3 ms (at most 6.9 ms) every 20 ms, mostly
  on CPU 0, with no sound playing. In a 40-second System Trace, all 6 of the compositor's
  delayed completions came while a burst ran; none of the 1,720 that ended between bursts was
  delayed, and 715 of the 721 that ended during one weren't. In one of the 6, the GPU finished
  at 10,955.1 ms, CPU 0 ran the audio thread from 10,954.0 to 10,959.5 ms, and the other five
  cores slept. The kernel's GPU work loop (`AGXHardwareWorkLoop`) ran at 10,958.9 ms, on CPU
  3, just after an interrupt woke the other cores, and `backboardd` saw the completion at
  10,959.2 ms.
- **Why the frames come in clusters.** The audio runs at 50 Hz and the display at 59.94 Hz, so
  their timing lines up again every 3.3 seconds. The delayed completions, and the late frames
  in the renderer's log, all fell at one point of a 20 ms cycle of the wall clock.
- **What hides it.** Any thread in the app that wakes every 4 ms prevents the delays. A 4 ms
  timer on the main thread, or on a background queue, left no late frames after launch in two
  189-second runs, against 18 and 27 in runs of about the same length without one. The
  `--wall-metal-trace` switch used to add such a timer on the main thread, so it hid the late
  frames it was meant to log.

Only this Apple TV, receiver, and audio setup were measured. Another HDMI audio format might
run the audio thread for longer or shorter bursts.

## The fix

While its display link draws, the render thread wakes at least every 4 ms
(`BookMetalRenderer.wakeInterval`). It sleeps as before while the link is paused, so a resting
wall costs nothing. That the wake works by keeping a core awake for the kernel's GPU work loop
is inferred from the trace above; Apple doesn't document how the kernel picks that core. In four
alternating runs of about 190 seconds each, of the resting wall drawn continuously with nothing
attached, the renderer had 0 and 0 late frames with the wake, and 21 and 22 with
`--wall-metal-sleeps`, which turns it off. The renderer's longest time on a frame in each
second (median 0.8 ms) and its mean GPU time (9.7 ms) didn't change.

The runs measured the resting wall, not motion. During a fall, a flight, or a focus move, the
link draws the same way, so the same collision could repeat a frame there; that wasn't
measured separately.

## Not explained

- **Why the wall hitches when drawn above every other view.** At the same drawable size, the
  app's work then arrives first in 98% of refreshes, and about four times a second two app
  frames land in one refresh. Don't move the wall's layer above the split view without
  finding out why.

## A display freeze that was not the app

One afternoon every recording showed a freeze of about 100 ms every 2.82 seconds.

- **Not the app or any process's CPU work.** Time Profiler recordings of the app, and of
  every process, show them all quieter during the freezes, and the display's VSync requests
  stop for 55 to 100 ms at each one.
- **Not Instruments.** The app's own log showed the same gaps with nothing attached.
- **It was an HDCP authentication loop.** The system log shows the Apple TV restarting HDCP 2
  authentication with the receiver at each freeze: `AKE_Init`, the receiver's
  `AKE_Send_Cert`, `AKE_No_Stored_km`, then `DP_CP_IRQ_Timeout` one second later, from
  `AppleSEPHDCPManager`, `IODisplayPortFamily`, and `AppleMCDP29XX`. The loop's request count
  dated its start to a wake of the Apple TV, after several sleep and wake cycles that day.
- **Power-cycling the receiver cleared it.** A recording afterward showed no `AKE_` lines,
  and the freezes were gone.
