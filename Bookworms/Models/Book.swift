import Foundation

struct Book: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var author: String
    var description: String?
    var coverURL: URL?
    var pages: Int?
    var finished: String?
    var rating: Double?
    var format: String?
    var seriesID: Int?
    var genres: [String]?
    var communityRating: Double?
    var ratingsCount: Int?
    var ratingDistribution: [RatingBucket]?
    var detailCoverURL: URL?

    var sources: [LibrarySource]?
    var isOwned: Bool?
    var isRead: Bool?
    var publicationYear: Int?

    var isHardcoverBook: Bool { sources?.contains(.hardcover) ?? (id < 1_000_000_000_000_000) }

    var spineTitle: String { title.components(separatedBy: ":").first ?? title }

    var spineSubtitle: String? {
        guard let colon = title.firstIndex(of: ":") else { return nil }
        return String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    var formatSymbol: String {
        switch format?.lowercased() {
        case "listened", "audio", "audiobook": "headphones"
        case "ebook", "e-book", "digital": "ipad"
        case "both": "books.vertical"
        default: "book.closed"
        }
    }

    /// The reading format's display name. Hardcover records Read, Listened, Both, or Ebook.
    var formatLabel: String? {
        switch format?.lowercased() {
        case nil: nil
        case "read", "physical": "Physical"
        case "listened", "audio", "audiobook": "Audiobook"
        case "ebook", "e-book", "digital": "Ebook"
        case "both": "Physical & audiobook"
        default: format
        }
    }

    /// The format and finish date joined with a bullet, such as "Audiobook • Sep 17, 2026".
    /// Missing parts are left out.
    func readingSummary(dateFormat: AppDateFormat) -> String {
        var parts = [formatLabel].compactMap(\.self)
        if finished != nil { parts.append(finishedLabel(format: dateFormat)) }
        return parts.joined(separator: " • ")
    }

    var finishedLabel: String { finishedLabel(format: .monthName) }

    func finishedLabel(format: AppDateFormat) -> String {
        guard let finished else { return "Date not recorded" }
        let parts = finished.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = Calendar(identifier: .gregorian)
                .date(
                    from:
                        DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return "Date not recorded" }
        let actual = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else {
            return "Date not recorded"
        }
        return format.string(from: date)
    }

    static func recentFirst(_ lhs: Book, _ rhs: Book) -> Bool {
        if lhs.finished == rhs.finished { return lhs.id > rhs.id }
        return (lhs.finished ?? "") > (rhs.finished ?? "")
    }
}

struct LibrarySnapshot: Codable, Sendable {
    let books: [Book]
    let syncedAt: Date
}

enum SampleLibrary {
    // Fictional fixtures keep previews and UI tests independent of private reading history.
    static let books: [Book] = [
        Book(
            id: 1, title: "The Orchard at Night", author: "Alex Rowan",
            description: String(
                repeating:
                    "A botanist returns to an island where the trees bloom only after sunset. As the seasons change, a forgotten family archive reveals a different history of the island and the people who call it home. ",
                count: 8), pages: 384, finished: "2026-09-09", rating: 4.5, format: "Ebook",
            seriesID: 1, genres: ["Fantasy", "Mystery"], communityRating: 4.24, ratingsCount: 100,
            ratingDistribution: [
                RatingBucket(rating: 3, count: 10), RatingBucket(rating: 4, count: 56),
                RatingBucket(rating: 5, count: 34),
            ]),
        Book(
            id: 2, title: "A Field Guide to Elsewhere", author: "Morgan Vale",
            description:
                "An atlas of imaginary places, told through the lives of the travelers who mapped them.",
            pages: 272, finished: "2026-09-05", rating: 4, format: "Audiobook"),
        Book(
            id: 3, title: "Annihilation", author: "Sample Author",
            description: "A typography fixture for an unbroken title.", pages: 195,
            finished: "2026-09-01", format: "Paperback"),
        Book(
            id: 4, title: "The Long Way Home: A Journey Through the Changing City",
            author: "Sam North", description: nil, pages: 640, finished: nil),
        Book(
            id: 5, title: "Small Hours", author: "Jamie Rivers",
            description:
                "A collection of essays about night work, quiet places, and the lives that unfold while a city sleeps.",
            pages: 224, finished: "2026-08-28", rating: 3.5, format: "Hardcover"),
        Book(
            id: 6, title: "The Last Observatory", author: "Robin Ellis",
            description: "Two astronomers follow a signal across generations.", pages: 432,
            finished: "2026-08-25", rating: 5, format: "Ebook"),
        Book(
            id: 7, title: "Tides", author: "Casey Moon",
            description: "A natural history of a changing coast.", pages: 180,
            finished: "2026-08-20"),
        Book(
            id: 8, title: "Winter in the Orchard", author: "Alex Rowan",
            description: "The island's story continues.", pages: 410, finished: "2026-08-18",
            format: "Audiobook", seriesID: 1),
    ]
}

struct RatingBucket: Codable, Hashable, Identifiable, Sendable {
    let rating: Double
    let count: Int
    var id: Double { rating }
}
