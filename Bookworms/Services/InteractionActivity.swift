import Foundation
import Observation

/// Tracks input without publishing a view update or creating a task for every press.
@MainActor @Observable
final class InteractionActivity {
    private(set) var controlsVisible = true
    @ObservationIgnored private var lastInput = ContinuousClock.now
    @ObservationIgnored private var hidingTask: Task<Void, Never>?

    func record() {
        lastInput = .now
        if !controlsVisible { controlsVisible = true }
    }

    func scheduleHiding(allowed: Bool) {
        hidingTask?.cancel()
        hidingTask = nil
        guard allowed else { return }
        hidingTask = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try await Task.sleep(
                        until: lastInput.advanced(by: .seconds(4)), clock: .continuous)
                    try Task.checkCancellation()
                    if lastInput.duration(to: .now) >= .seconds(4) { break }
                }
                controlsVisible = false
            } catch {}
        }
    }

    func waitUntilQuiet() async throws {
        while lastInput.duration(to: .now) < .milliseconds(500) {
            try await Task.sleep(
                until: lastInput.advanced(by: .milliseconds(500)), clock: .continuous)
            try Task.checkCancellation()
        }
    }
}
