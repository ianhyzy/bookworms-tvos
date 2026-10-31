import Foundation

/// Tracks input without publishing a view update or creating a task for every press.
@MainActor
final class InteractionActivity {
    private var lastInput = ContinuousClock.now

    func record() {
        lastInput = .now
    }

    func waitUntilQuiet() async throws {
        while lastInput.duration(to: .now) < .milliseconds(500) {
            try await Task.sleep(
                until: lastInput.advanced(by: .milliseconds(500)), clock: .continuous)
            try Task.checkCancellation()
        }
    }
}
