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
