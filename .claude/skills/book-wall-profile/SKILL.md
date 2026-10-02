---
name: book-wall-profile
description: Profile Book Wall performance on the physical Apple TV without user help. Builds an optimized test build, launches directly into Book Wall, drives the Siri Remote through three select/return cycles and fast stack navigation, records Display + Points of Interest in Instruments (or Time Profiler, Hitches, and GPU too with `--capture-set full`), and summarizes frame pacing, renderer throughput, and, when recorded, GPU time and main-thread CPU per phase. Use when asked to profile, trace, or measure Book Wall smoothness, stutter, or timing, or to compare performance before and after a change.
---

# Book Wall performance profile

Running this is a test run: do it only when the user asks for profiling or measurement in the
current request (see `AGENTS.md`). It installs a test build over the local app and reinstalls
the ordinary local build afterward; app data is preserved.

## Run

From the repository root, in the background (a build plus the run takes 5–10 minutes):

```sh
python3 scripts/profile-book-wall.py --label baseline
```

- `--skip-build` reuses `.build-profile` when only scripts changed since the last build.
  Rebuild after any app or UI-test source change.
- `--label` names the output folder, for example `baseline` and `after-fix`.
- `--keep-test-build` leaves the profiled build installed.
- The default `--capture-set display` records Display + Points of Interest, which loses the least data over the network and skips symbolication. `--capture-set full` adds Time Profiler, Hitches, and GPU, for GPU or CPU questions; `--capture-set cpu` records Time Profiler + Points of Interest. Compare matching capture sets and executables.
- `--sequence details` records only the three detail open/close cycles, for a shorter, more complete recording. A recorder exit of 0 does not establish complete phase data.
- `--keep-trace` keeps the trace and exported tables for drill-down. Otherwise the run deletes
  them after writing `summary.json`; each run's trace and tables take about 240 MB.
- `--prune` deletes the traces and tables from every run and any leftover `xctrace` buffers, then
  exits. Run it when an analysis that used `--keep-trace` is done.
- `--diagnostics` builds with `BOOKWORMS_DIAGNOSTICS` into `.build-profile-diagnostics` and
  launches with markers.
- `--variant NAME` runs one diagnostic isolation, such as `wall-720p`, `wall-no-fill-lights`,
  or `wall-no-details` (see `docs/PERFORMANCE_DIAGNOSIS.md`). Bracket variants with
  `--diagnostics` baselines, not the ordinary build: diagnostic markers add their own cost.
  Build once, then pass `--skip-build` and `--keep-test-build` to the runs in between.

The script needs `.local/device-build.json` (`device`, `team`, optional `traceDevice`, default
`Living Room`). It then, without user input:

1. Builds (step 2), restarts the TV before every fourth recording and waits 90 seconds, then wakes the Instruments connection. `xctrace` often lists the TV under **Devices Offline** even
   when installs work; a `devicectl device info details` call brings it online. It stops if the
   TV stays offline.
2. Builds `BookwormsDevice` Release for testing with coverage off and dSYMs into `.build-profile`.
3. Runs `scripts/profile-device.py --scenario bookWall`, which runs
   `DevicePerformanceTests/testBookWallProfile`. Setup (launch, wait for preparation, focus the
   **Book Wall** sidebar item) happens before Instruments attaches by process ID. The measured
   sequence then opens Book Wall, waits 10 seconds for the fall, navigates in 12 short bursts,
   selects and returns three times, presses Play/Pause 24 times as a control, and moves focus every
   2 seconds (`slow-navigate`). It makes no accessibility queries until the end.
4. Symbolicates the trace with the matching dSYM, writes `summary.json`, deletes the trace, its
   exported tables, and the 1–2 GB kernel-trace buffer that `xctrace` leaves in the Mac's
   temporary folder, removes the UI-test runner, and reinstalls the local build.

Wait for the background task to finish; do not poll.

## Read the results

Output: `.local/performance-diagnosis/<timestamp>-<label>/`.

| File | Contents |
| --- | --- |
| `tables/summary.json` | Per-phase report under `phases`, plus whole-trace hitches, hangs, and CPU. |
| `phases.json` | Phase markers (`select-N`, `return-N`, `reposition`, `navigate`, `control`, `slow-navigate`, `end`) with wall-clock times. |
| `recording-symbolicated.trace`, `tables/*.xml` | Only with `--keep-trace`: open the trace in Instruments; the tables hold exported rows. |
| `test.log`, `trace.log`, `manifest.json` | Test output, recorder output, build hashes, and options. |

For each phase, report:

- `frames_per_second`: frames shown in each second of the phase, which locates slow stretches.
  Several seconds of 0 with no hitches usually means the Display instrument lost data, not a
  frozen screen; don't count those seconds.
- `frame_intervals`: gaps between on-screen frame swaps on the main display. At 60 Hz the budget
  is 16.7 ms; `frames_over_20ms` and `frames_over_34ms` count missed frames. A static screen
  also swaps less often, so judge pacing in phases with motion.
- `hitches`: Instruments' hitch durations.
- `observations`: per-phase provider status and sample count, plus the first/last display-swap offsets. `samples_present` does not prove complete phase coverage. Missing schemas produce null metrics, not measured zero work.
- `gpu_busy_ms` and `compositor_gpu_ms`: GPU execution time for the app and for `backboardd`,
  the system compositor, attributed by the `process` column. The GPU instrument's buffer can fill
  partway through the run; a later phase reading exactly 0 ms means missing data, not idle.
- `gpu_ms_per_second`: app and compositor GPU time in each second of the phase, as two lists
  aligned with `frames_per_second`. Divide by that second's frames for time per frame.
- `renderer_max_tick_gap_ms`: the longest gap between display-link callbacks in the phase; well over 17 ms means the main thread stalled.
- `renderer_submitted_per_second`, `renderer_skipped_per_second`: with diagnostics, the frames the app submitted and the display ticks it skipped in each one-second
  pipeline window. They come from `pipeline.jsonl`, which the app writes on the TV, or else from
  its Points of Interest events, so they survive Display and GPU data gaps. They measure app throughput, not frames shown: tvOS has no presented-frame
  callback.
- `main_thread_ms`, `main_self_top`, `app_inclusive_top`: where the main thread spent its time.
  `re::` symbols are RealityKit; `BookWall` symbols are app code.

Compare runs phase by phase with the same label scheme, and repeat a run before calling a
difference real. State the conditions: build, TV, and that XCTest drives input.

## Known limits

- The RealityKit Frames and Metrics instruments record only on visionOS. Use Display and GPU.
- `devicectl device capture screen-record` is not supported on this Apple TV, so there is no
  video. Use the frame data, or ask the user for a QuickTime or phone slow-motion recording.
- Attach by process ID. Attaching by name is ambiguous because of the Top Shelf extension.
- SwiftUI update lanes are empty on this device.
- Frame intervals measure display swaps, not input-to-photon latency. XCTest adds input
  transport overhead.
- After a run, Instruments may show the TV offline again. The next run wakes it.
- Each recording leaves data on the TV that only a restart clears. After 6 to 25 recordings,
  the recorder crashed or saved empty traces, and installs failed with "Insufficient storage".
  The script therefore restarts the TV with `devicectl device reboot` and waits 90 seconds before
  every fourth recording; `--reboot-every N` changes the interval, and `--no-reboot` skips it. If installs still report insufficient storage, restart with
  `xcrun devicectl device reboot --device <UDID> --wait-for-device`, then reinstall with
  `python3 scripts/device-build.py`.
- `trace_exit` can be nonzero when one data source reports errors while the trace still saves. The
  script summarizes any trace from a passing test; check that the phases have frames before
  using the numbers.
- The CoreDevice connection to an idle TV drops, so restarts and launches can fail with
  CoreDeviceError 4000 or 4016. The script wakes the connection and retries a restart once. A run
  that fails with "Instruments exited before the sequence finished" or a Mercury launch error is
  a connection failure; rerun it.
- Check direct-to-display with `--keep-trace`: export the `displayed-surfaces-interval` table
  and count `direct-to-display` and `detachment-reason`.
- Don't ask the user to drive the remote or read values off the TV. Script the input as a test
  phase. The `control` phase presses Play/Pause, which changes nothing on the wall, at the
  navigation pace to measure XCTest's own overhead; `slow-navigate` moves focus every 2 seconds.
- XCTest delivers presses about 0.4 seconds apart, not at the scripted 80 ms, so the navigate
  phase is continuous movement. Compare navigate across variants, not with a hand-driven session.
- Keep scripted Left presses inside the stacks. Left from the first column moves focus to the
  sidebar, where Select changes views and Menu exits to the Home screen; later phases then
  measure the Home screen. A test that ends without any `book-wall-` button has this problem.
  The app's GPU time dropping to 0 ms mid-run is the same symptom.
- To find who calls a hot symbol, rerun with `--keep-trace`, load `tables/time-profile.xml` with `rows()` from
  `scripts/summarize-performance-trace.py` and group stacks whose first frame matches it.

See `docs/PERFORMANCE_DIAGNOSIS.md` for the general device-profiling procedure.
