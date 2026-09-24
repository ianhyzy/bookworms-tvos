import Foundation

struct ReaderProfile: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let username: String
    let name: String?
    let avatarURL: URL?
    var displayName: String { name?.isEmpty == false ? name! : "@\(username)" }
}

struct ReaderBook: Codable, Identifiable, Hashable, Sendable {
    let book: Book
    let rating: Double?
    let review: String?
    let hasSpoilers: Bool
    let finished: String?
    var id: Int { book.id }
    var reviewText: String? { ReviewText.clean(review) }
}

struct SharedRead: Identifiable, Hashable, Sendable {
    let mine: ReaderBook
    let theirs: ReaderBook
    var id: Int { mine.id }
    var combinedRating: Double { (mine.rating ?? 0) + (theirs.rating ?? 0) }

    static func ranked(
        mine: [ReaderBook], theirs: [ReaderBook], sort: SharedReadsSort = .agreement, limit: Int
    ) -> [SharedRead] {
        let measurement = PerformanceDiagnostics.begin("SharedRanking")
        defer { measurement.end() }
        let other = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let common = mine.compactMap { own -> SharedRead? in
            guard let a = own.rating, (0...5).contains(a), let match = other[own.id],
                let b = match.rating, (0...5).contains(b)
            else { return nil }
            return SharedRead(mine: own, theirs: match)
        }
        func reviewPriority(_ shared: SharedRead) -> Int {
            let myHasText = shared.mine.reviewText != nil
            let theirHasText = shared.theirs.reviewText != nil
            if myHasText && theirHasText { return 2 }
            if myHasText || theirHasText { return 1 }
            return 0
        }
        return Array(
            common.sorted { lhs, rhs in
                let lPrio = reviewPriority(lhs)
                let rPrio = reviewPriority(rhs)
                if lPrio != rPrio { return lPrio > rPrio }
                switch sort {
                case .agreement:
                    if lhs.combinedRating != rhs.combinedRating {
                        return lhs.combinedRating > rhs.combinedRating
                    }
                    let lDiff = abs((lhs.mine.rating ?? 0) - (lhs.theirs.rating ?? 0))
                    let rDiff = abs((rhs.mine.rating ?? 0) - (rhs.theirs.rating ?? 0))
                    if lDiff != rDiff { return lDiff < rDiff }
                case .disagreement:
                    let lDiff = abs((lhs.mine.rating ?? 0) - (lhs.theirs.rating ?? 0))
                    let rDiff = abs((rhs.mine.rating ?? 0) - (rhs.theirs.rating ?? 0))
                    if lDiff != rDiff { return lDiff > rDiff }
                    if lhs.combinedRating != rhs.combinedRating {
                        return lhs.combinedRating > rhs.combinedRating
                    }
                }
                if lhs.mine.book.title != rhs.mine.book.title {
                    return lhs.mine.book.title < rhs.mine.book.title
                }
                return lhs.id < rhs.id
            }
            .prefix(max(0, min(BookLimit.maximum, limit))))
    }
}

enum ComparisonOrder: String, Codable, CaseIterable, Identifiable {
    case rating = "Top rated · All time"
    case recent = "Recently read"
    var id: String { rawValue }
    func select(_ books: [ReaderBook], limit: Int) -> [ReaderBook] {
        let measurement = PerformanceDiagnostics.begin("ComparisonSorting")
        defer { measurement.end() }
        let eligible = books.filter { self == .rating ? $0.rating != nil : $0.finished != nil }
        return Array(
            eligible.sorted { lhs, rhs in
                if self == .rating, lhs.rating != rhs.rating {
                    return (lhs.rating ?? -1) > (rhs.rating ?? -1)
                }
                if self == .recent, lhs.finished != rhs.finished {
                    return (lhs.finished ?? "") > (rhs.finished ?? "")
                }
                if lhs.book.title != rhs.book.title { return lhs.book.title < rhs.book.title }
                return lhs.id < rhs.id
            }
            .prefix(max(1, min(BookLimit.maximum, limit))))
    }
}

struct FeedActivity: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let reader: ReaderProfile
    let createdAt: String?
    let summary: String
    let book: Book?
    let likes: Int
    let rating: Double?
    let review: String?
    let hasSpoilers: Bool
    /// Keep the newest network update for each book before applying the display limit.
    static func latestPerBook(_ activities: [FeedActivity], limit: Int = 20) -> [FeedActivity] {
        guard limit > 0 else { return [] }
        let dated: [(activity: FeedActivity, date: Date)] = activities.map {
            (activity: $0, date: $0.date ?? Date.distantPast)
        }
        let ordered = dated.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.activity.id > rhs.activity.id }
            return lhs.date > rhs.date
        }
        var books = Set<Int>()
        var events = Set<Int>()
        var result: [FeedActivity] = []
        for (activity, _) in ordered {
            guard events.insert(activity.id).inserted else { continue }
            if let book = activity.book, !books.insert(book.id).inserted { continue }
            result.append(activity)
            if result.count >= limit { break }
        }
        return result
    }

    var date: Date? {
        guard let createdAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

/// Render external reviews as inert text; never execute markup or load embedded resources.
enum ReviewText {
    static func clean(_ value: String?) -> String? {
        let measurement = PerformanceDiagnostics.begin("ReviewSanitization")
        defer { measurement.end() }
        guard var text = value else { return nil }
        text = String(text.prefix(30_000))
        for pattern in ["(?is)<script\\b[^>]*>.*?</script>", "(?is)<style\\b[^>]*>.*?</style>"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: "(?i)<(?:br\\s*/?|/p|/div)>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

struct SocialSnapshot: Codable, Sendable {
    let owner: ReaderProfile
    var following: [ReaderProfile] = []
    var activities: [FeedActivity] = []
    var mine: [ReaderBook] = []
    var readerBooks: [Int: [ReaderBook]] = [:]
    var dates: [String: Date] = [:]
}
