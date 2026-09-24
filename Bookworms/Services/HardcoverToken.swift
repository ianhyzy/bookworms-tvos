import Foundation

/// Validates token format locally. Hardcover verifies validity and permissions.
struct HardcoverToken: Sendable {
    let value: String

    init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty,
            !value.contains(where: { $0.isWhitespace || $0.isNewline }),
            value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw HardcoverError.invalidToken }
        self.value = value
    }
}
