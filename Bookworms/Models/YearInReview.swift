import Foundation

/// Reading statistics for one calendar year, computed from the finish dates in the library
/// snapshot.
///
/// The library keeps each book's most recent read, so a reread counts once, in the year of its
/// latest finish. Books without a finish date are left out.
struct YearInReview: Equatable, Identifiable, Sendable {
    /// A name and how many books it applies to, such as a genre or format.
    struct Tally: Equatable, Sendable {
        let name: String
        let count: Int
    }

    let year: Int
    /// Every book finished this year, earliest first.
    let books: [Book]
    /// The books the view's cover row shows, earliest first: every book, or the
    /// `BookLimit.maximum` highest rated when the year has more.
    let shelf: [Book]
    /// The page total across books with a recorded page count.
    let pages: Int
    let booksWithPages: Int
    let averageRating: Double?
    let ratedBooks: Int
    /// Books finished in each month, January first.
    let monthlyCounts: [Int]
    /// The month (1–12) with the most finished books; the earliest wins a tie.
    let busiestMonth: Int?
    /// Recorded reading formats, most common first.
    let formats: [Tally]
    /// Up to five genres, most common first.
    let genres: [Tally]
    /// The author with the most finished books, when at least two share an author.
    let topAuthor: Tally?

    var id: Int { year }

    /// Genres counted per book; Hardcover lists a book's most-tagged genres first.
    static let genresPerBook = 3

    /// One review for each year with a finished book, most recent year first.
    static func all(from books: [Book]) -> [YearInReview] {
        var byYear: [Int: [(book: Book, month: Int)]] = [:]
        for book in books {
            guard let finish = book.finishedYearMonth else { continue }
            byYear[finish.year, default: []].append((book, finish.month))
        }
        return byYear.keys.sorted(by: >).map { year in
            YearInReview(year: year, entries: byYear[year] ?? [])
        }
    }

    private init(year: Int, entries: [(book: Book, month: Int)]) {
        self.year = year
        let books = entries.map(\.book).sorted { lhs, rhs in
            lhs.finished == rhs.finished
                ? lhs.id < rhs.id : (lhs.finished ?? "") < (rhs.finished ?? "")
        }
        self.books = books
        if books.count > BookLimit.maximum {
            let favorites = books.sorted { lhs, rhs in
                (lhs.rating ?? -1) == (rhs.rating ?? -1)
                    ? Book.recentFirst(lhs, rhs) : (lhs.rating ?? -1) > (rhs.rating ?? -1)
            }
            let kept = Set(favorites.prefix(BookLimit.maximum).map(\.id))
            shelf = books.filter { kept.contains($0.id) }
        } else {
            shelf = books
        }

        let paged = books.compactMap(\.pages).filter { $0 > 0 }
        pages = paged.reduce(0, +)
        booksWithPages = paged.count
        let ratings = books.compactMap(\.rating).filter { (0...5).contains($0) }
        ratedBooks = ratings.count
        averageRating = ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)

        var months = Array(repeating: 0, count: 12)
        for entry in entries { months[entry.month - 1] += 1 }
        monthlyCounts = months
        let most = months.max() ?? 0
        busiestMonth = most > 0 ? months.firstIndex(of: most).map { $0 + 1 } : nil

        formats = Self.tally(books.compactMap(\.formatLabel))
        genres = Array(
            Self.tally(books.flatMap { Array(($0.genres ?? []).prefix(Self.genresPerBook)) })
                .prefix(5))
        topAuthor = Self.tally(books.map(\.author).filter { !$0.isEmpty })
            .first { $0.count >= 2 }
    }

    /// Counts each distinct name, most common first, then alphabetically.
    private static func tally(_ names: [String]) -> [Tally] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return counts.map { Tally(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
}

extension Book {
    /// The year and month (1–12) of the recorded finish date, or `nil` when it is missing or
    /// malformed.
    var finishedYearMonth: (year: Int, month: Int)? {
        guard let finished else { return nil }
        let parts = finished.prefix(10).split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
            year > 0, (1...12).contains(month)
        else { return nil }
        return (year, month)
    }
}
