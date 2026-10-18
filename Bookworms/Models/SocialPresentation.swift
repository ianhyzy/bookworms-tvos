import Foundation

/// Prepared rows shared by interactive views and ambient playback.
struct SocialPresentation {
    var reader: ReaderProfile?
    var mine: [ReaderBook] = []
    var theirs: [ReaderBook] = []
    var shared: [SharedRead] = []
    var myRatings: [Int: Double] = [:]
    var theirRatings: [Int: Double] = [:]
    var picks: [FriendPick] = []
    /// Followed readers with each book in their synced libraries, by book ID, for book details.
    var friendReads: [Int: [FriendRead]] = [:]
    /// Followed readers whose libraries are synced, whose photos `friendReads` shows.
    var libraryReaders: [ReaderProfile] = []

    init() {}

    init(snapshot: SocialSnapshot?, preferences: ViewPreferences) {
        guard let snapshot else { return }
        picks = FriendPick.ranked(snapshot, limit: BookLimit.maximum)
        (friendReads, libraryReaders) = FriendRead.byBook(snapshot)
        reader = snapshot.following.first { $0.id == preferences.readerID }
        guard let reader else { return }
        let other = snapshot.readerBooks[reader.id] ?? []
        // Index complete libraries so a rating remains available outside either visible top 20.
        myRatings = snapshot.mine.reduce(into: [:]) { $0[$1.id] = $1.rating }
        theirRatings = other.reduce(into: [:]) { $0[$1.id] = $1.rating }
        mine = preferences.comparisonOrder.select(snapshot.mine, limit: preferences.comparisonCount)
        theirs = preferences.comparisonOrder.select(other, limit: preferences.comparisonCount)
        shared = SharedRead.ranked(
            mine: snapshot.mine, theirs: other, sort: preferences.sharedReadsSort,
            limit: preferences.comparisonCount)
    }
}

/// A book that people you follow rated highly and you haven't read.
struct FriendPick: Identifiable, Hashable, Sendable {
    let book: Book
    /// Readers who rated it at least `minimumRating`, highest rating first.
    let fans: [ReaderProfile]
    let averageRating: Double
    var id: Int { book.id }

    static let minimumRating = 4.0

    /// Ranks books by how many followed readers rated them highly, then by their average rating.
    ///
    /// Uses every synced reader library and the ratings in the feed. Books you finished or marked
    /// read are left out; books on your other shelves, such as Want to Read, stay.
    static func ranked(_ snapshot: SocialSnapshot, limit: Int) -> [FriendPick] {
        let measurement = PerformanceDiagnostics.begin("FriendPicks")
        defer { measurement.end() }
        let read = Set(
            snapshot.mine.filter { $0.finished != nil || $0.book.isRead == true }.map(\.id))
        let following = Dictionary(
            snapshot.following.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ratings: [Int: [Int: Double]] = [:]
        var books: [Int: Book] = [:]
        func add(_ book: Book, reader: Int, rating: Double?) {
            guard let rating, rating >= minimumRating, rating <= 5, following[reader] != nil,
                !read.contains(book.id)
            else { return }
            ratings[book.id, default: [:]][reader] = rating
            books[book.id] = books[book.id] ?? book
        }
        for (reader, library) in snapshot.readerBooks {
            for item in library { add(item.book, reader: reader, rating: item.rating) }
        }
        for activity in snapshot.activities {
            if let book = activity.book {
                add(book, reader: activity.reader.id, rating: activity.rating)
            }
        }
        let picks = ratings.compactMap { id, byReader -> FriendPick? in
            guard let book = books[id] else { return nil }
            let fans =
                byReader.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .compactMap { following[$0.key] }
            let average = byReader.values.reduce(0, +) / Double(byReader.count)
            return FriendPick(book: book, fans: fans, averageRating: average)
        }
        return Array(
            picks.sorted { lhs, rhs in
                if lhs.fans.count != rhs.fans.count { return lhs.fans.count > rhs.fans.count }
                if lhs.averageRating != rhs.averageRating {
                    return lhs.averageRating > rhs.averageRating
                }
                return lhs.book.title == rhs.book.title
                    ? lhs.id < rhs.id : lhs.book.title < rhs.book.title
            }
            .prefix(max(0, limit)))
    }

    /// Up to `limit` followed readers, most active in the feed first, then in following order.
    static func readersToSync(_ snapshot: SocialSnapshot, limit: Int) -> [Int] {
        var activity: [Int: Int] = [:]
        for item in snapshot.activities { activity[item.reader.id, default: 0] += 1 }
        let order = Dictionary(
            snapshot.following.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return snapshot.following.map(\.id)
            .sorted {
                (activity[$0] ?? 0, -(order[$0] ?? 0)) > (activity[$1] ?? 0, -(order[$1] ?? 0))
            }
            .prefix(limit).map(\.self)
    }
}

/// A followed reader's copy of a book: who has it in their library, and their rating.
struct FriendRead: Hashable, Sendable {
    let reader: ReaderProfile
    let rating: Double?

    /// Every synced followed-reader library, indexed by book. A book's readers come rated first,
    /// highest rating first, then by name. Libraries of readers you no longer follow, including
    /// readers you blocked, are left out.
    static func byBook(_ snapshot: SocialSnapshot) -> (
        reads: [Int: [FriendRead]], readers: [ReaderProfile]
    ) {
        let measurement = PerformanceDiagnostics.begin("FriendReads")
        defer { measurement.end() }
        var reads: [Int: [FriendRead]] = [:]
        var readers: [ReaderProfile] = []
        for reader in snapshot.following {
            guard let library = snapshot.readerBooks[reader.id], !library.isEmpty else { continue }
            readers.append(reader)
            for item in library {
                let rating = item.rating.flatMap { (0.5...5).contains($0) ? $0 : nil }
                reads[item.id, default: []].append(FriendRead(reader: reader, rating: rating))
            }
        }
        let ranked = reads.mapValues { list in
            list.sorted { lhs, rhs in
                if lhs.rating != rhs.rating { return (lhs.rating ?? -1) > (rhs.rating ?? -1) }
                return lhs.reader.displayName.localizedStandardCompare(rhs.reader.displayName)
                    == .orderedAscending
            }
        }
        return (ranked, readers)
    }
}
