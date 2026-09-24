import Foundation
import Observation

/// Stores presence flags for UI rendering; secrets remain in Keychain.
@MainActor @Observable
final class CredentialAvailability {
    private var available: [String: Bool] = [:]
    @ObservationIgnored private let read: (String) -> String?

    init(read: @escaping (String) -> String? = { CredentialStore.read(account: $0) }) {
        self.read = read
    }

    func contains(_ account: String) -> Bool { available[account] ?? false }

    /// Call at startup, foreground entry, or after an explicit credential change.
    func reload(_ account: String) {
        let present = read(account) != nil
        if available[account] != present { available[account] = present }
    }
}
