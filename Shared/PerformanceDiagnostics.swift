import Foundation

#if BOOKWORMS_DIAGNOSTICS
    import os
#endif

/// Opt-in measurements and isolation controls; normal builds compile these calls away.
enum PerformanceDiagnostics {
    #if BOOKWORMS_DIAGNOSTICS
        private static let arguments = Set(ProcessInfo.processInfo.arguments)
        static let enabled = arguments.contains("--performance-diagnostics")
    #else
        static let enabled = false
    #endif

    static func isolates(_ name: String) -> Bool {
        #if BOOKWORMS_DIAGNOSTICS
            enabled && arguments.contains("--isolate=\(name)")
        #else
            false
        #endif
    }

    #if BOOKWORMS_DIAGNOSTICS
        private static let signposter = OSSignposter(
            subsystem: "gay.ian.Bookworms.performance", category: .pointsOfInterest)
    #endif

    struct Interval {
        #if BOOKWORMS_DIAGNOSTICS
            fileprivate let name: StaticString
            fileprivate let state: OSSignpostIntervalState?
        #endif
        func end() {
            #if BOOKWORMS_DIAGNOSTICS
                if let state { signposter.endInterval(name, state) }
            #endif
        }
    }

    static func begin(_ name: StaticString) -> Interval {
        #if BOOKWORMS_DIAGNOSTICS
            return Interval(
                name: name,
                state: enabled
                    ? signposter.beginInterval(name, id: signposter.makeSignpostID()) : nil)
        #else
            return Interval()
        #endif
    }

    static func event(_ name: StaticString, _ value: Int = 0) {
        #if BOOKWORMS_DIAGNOSTICS
            if enabled { signposter.emitEvent(name, "value=\(value)") }
        #endif
    }
}

#if BOOKWORMS_DIAGNOSTICS
    /// Aggregates scene-update intervals and app callback cost, not displayed frame timing.
    @MainActor
    struct BookWallMotionMetrics {
        private static let capacity = 240
        private var phase: String?
        private var deltas: [Double] = []
        private var callbacks: [Double] = []
        private var elapsed: TimeInterval = 0

        init() {
            deltas.reserveCapacity(Self.capacity)
            callbacks.reserveCapacity(Self.capacity)
        }

        /// Starts a new measurement without retaining samples from an earlier presentation.
        mutating func reset() {
            phase = nil
            deltas.removeAll(keepingCapacity: true)
            callbacks.removeAll(keepingCapacity: true)
            elapsed = 0
        }

        /// Records seconds from a scene update and the app's work inside its callback.
        mutating func record(delta: TimeInterval, callbackSeconds: TimeInterval, phase: String) {
            guard PerformanceDiagnostics.enabled,
                delta.isFinite, delta >= 0, callbackSeconds.isFinite, callbackSeconds >= 0
            else { return }
            if self.phase != phase {
                flush()
                self.phase = phase
            }
            deltas.append(delta * 1_000)
            callbacks.append(callbackSeconds * 1_000)
            elapsed += delta
            if elapsed >= 2 || deltas.count == Self.capacity { flush() }
        }

        /// Writes one bounded batch to stderr; call when motion stops to include its final samples.
        mutating func flush() {
            guard PerformanceDiagnostics.enabled, let phase, !deltas.isEmpty else { return }
            let intervals = statistics(deltas)
            let work = statistics(callbacks)
            let summary: [String: Any] = [
                "metric": "scene_update_cadence",
                "phase": phase,
                "samples": deltas.count,
                "uptime_seconds": ProcessInfo.processInfo.systemUptime,
                "scene_delta_mean_ms": intervals.mean,
                "scene_delta_p95_ms": intervals.p95,
                "scene_delta_max_ms": intervals.maximum,
                "callback_p95_ms": work.p95,
                "callback_max_ms": work.maximum,
                "presentation_timing_measured": false,
            ]
            if let json = try? JSONSerialization.data(withJSONObject: summary, options: .sortedKeys)
            {
                var line = Data("BOOK_WALL_MOTION ".utf8)
                line.append(json)
                line.append(0x0A)
                try? FileHandle.standardError.write(contentsOf: line)
            }
            deltas.removeAll(keepingCapacity: true)
            callbacks.removeAll(keepingCapacity: true)
            elapsed = 0
        }

        private func statistics(_ samples: [Double]) -> (mean: Double, p95: Double, maximum: Double)
        {
            let sorted = samples.sorted()
            let percentileIndex = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
            return (
                samples.reduce(0, +) / Double(samples.count),
                sorted[percentileIndex], sorted[sorted.count - 1]
            )
        }
    }
#endif
