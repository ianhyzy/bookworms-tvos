import Foundation

/// Selects missing designs and limits automatic batch attempts to once per day.
@MainActor
struct AutomaticSpineGeneration {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private let key = "automaticSpineAttempts"

    func candidates(in books: [Book], savedIDs: Set<Int>, now: Date = Date()) -> [Book] {
        let attempts = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return books.filter { book in
            guard !savedIDs.contains(book.id), (book.detailCoverURL ?? book.coverURL) != nil else {
                return false
            }
            guard let attempt = attempts[String(book.id)] else { return true }
            return now.timeIntervalSince1970 - attempt >= 86400
        }
    }

    func recordAttempt(_ books: [Book], now: Date = Date()) {
        var attempts = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        attempts = attempts.filter { now.timeIntervalSince1970 - $0.value < 86400 }
        for book in books { attempts[String(book.id)] = now.timeIntervalSince1970 }
        defaults.set(attempts, forKey: key)
    }
}
