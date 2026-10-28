import Foundation

struct Book: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var author: String
    var description: String?
    /// The reader's own Hardcover review as plain text (`HardcoverClient.plainText(from:)`), the
    /// form the iPhone stores. It travels with the book in the iCloud archive.
    var review: String? = nil
    var coverURL: URL?
    var pages: Int?
    /// The latest finish date, `yyyy-MM-dd` or a timestamp that starts with one.
    var finished: String?
    /// Every finished read's date from Hardcover, newest first, in the format of `finished`, which
    /// equals the first. `nil` when only `finished` is known, as in snapshots saved before rereads
    /// were fetched. The iPhone reads it from the iCloud archive.
    var finishedDates: [String]? = nil
    var rating: Double?
    var format: String?
    var seriesID: Int?
    /// The book's position in `seriesID`, such as 3 for the third book. Companion works can have
    /// fractional positions.
    var seriesPosition: Double? = nil
    /// The name of the `seriesID` series. Snapshots saved before series names were fetched
    /// decode it as `nil` until the next sync. The iPhone reads it from the iCloud archive.
    var seriesName: String? = nil
    /// Every Hardcover series the book belongs to, which decide its series look
    /// (`SeriesDesigns.styleSeries(of:link:)`). Snapshots saved before memberships were fetched
    /// decode it as `nil` until the next sync. The iPhone reads it from the iCloud archive.
    var seriesMemberships: [SeriesMembership]? = nil
    var genres: [String]?
    var communityRating: Double?
    var ratingsCount: Int?
    var ratingDistribution: [RatingBucket]?
    var detailCoverURL: URL?

    var sources: [LibrarySource]?
    var isOwned: Bool?
    var isRead: Bool?
    /// Hardcover's shelf for the book (`user_books.status_id`), such as 1 for **Want to Read**.
    /// Snapshots saved before statuses were fetched decode it as `nil` until the next sync. The
    /// iPhone reads it from the iCloud archive.
    var statusID: Int? = nil
    /// The day the reader shelved a book as **Did Not Finish**, as `yyyy-MM-dd`: the day its
    /// Hardcover entry was last edited when a sync first finds it on that shelf, kept by later
    /// syncs while it stays there. It is `nil` for other shelves. The iPhone's **Dropped** share
    /// image reads it from the iCloud archive.
    var dropped: String? = nil
    var publicationYear: Int?
    /// Whether the book is on the reader's Hardcover **Currently Reading** shelf.
    var isReading: Bool?
    /// The fraction of the current read completed, from 0 to 1, when Hardcover has progress.
    var progress: Double?
    /// The current read's start date, `yyyy-MM-dd`.
    var started: String?
    /// The listening time of the reader's audiobook edition, when Hardcover records it.
    var audioSeconds: Int? = nil
    /// The cover the reader chose in a companion app (`CoverChoiceV1`). The library sets it on
    /// displayed books only; source snapshots and design hashes keep the default covers.
    var chosenCoverURL: URL? = nil

    /// How far your rating is from the community average, when both are recorded.
    var ratingGap: Double? {
        guard let rating, rating > 0, let communityRating, communityRating > 0 else { return nil }
        return abs(rating - communityRating)
    }

    /// The covers to try in order: the reader's choice, then the default covers as fallbacks.
    var coverURLs: [URL] {
        var urls: [URL] = []
        for url in [chosenCoverURL, detailCoverURL, coverURL].compactMap(\.self)
        where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }

    var preferredCoverURL: URL? { chosenCoverURL ?? detailCoverURL ?? coverURL }

    /// Every recorded finish date, newest first: `finishedDates`, else `finished` alone. An empty
    /// `finishedDates` counts as absent, as on the iPhone, so a book with `finished` always has a
    /// finish.
    var finishes: [String] {
        if let finishedDates, !finishedDates.isEmpty { return finishedDates }
        return finished.map { [$0] } ?? []
    }

    /// How many times the reader finished the book.
    var readCount: Int { finishes.count }

    /// The book as one time frame shows it: with `date`, one of its finishes, as `finished`.
    /// Views that group books by finish date use it, so a reread joins each year it was finished
    /// in. Never save the copy; its `finished` no longer matches `finishedDates`.
    func withFinish(_ date: String) -> Book {
        var book = self
        book.finished = date
        return book
    }

    var isHardcoverBook: Bool {
        sources?.contains(.hardcover) ?? (id < CWAConfiguration.firstBookID)
    }

    /// The book's permanent Hardcover page, or `nil` for a book Hardcover doesn't list.
    var hardcoverURL: URL? { isHardcoverBook ? HardcoverLink.book(id) : nil }

    var spineTitle: String { title.components(separatedBy: ":").first ?? title }

    var spineSubtitle: String? {
        guard let colon = title.firstIndex(of: ":") else { return nil }
        return String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    var formatSymbol: String { Self.formatSymbol(forLabel: formatLabel) }

    /// Each format the book was read in, splitting "Physical & audiobook" into both.
    var formatParts: [String] {
        guard let formatLabel else { return [] }
        return formatLabel == "Physical & audiobook" ? ["Physical", "Audiobook"] : [formatLabel]
    }

    /// The SF Symbol for a `formatLabel` value, such as "headphones" for "Audiobook".
    static func formatSymbol(forLabel label: String?) -> String {
        switch label {
        case "Audiobook": "headphones"
        case "Ebook": "ipad"
        case "Physical & audiobook": "books.vertical"
        default: "book.closed"
        }
    }

    /// The book's most-tagged English genre. Hardcover lists a book's genres by how many readers
    /// applied each tag, and the snapshot keeps that order.
    var primaryGenre: String? {
        genres?.first(where: HardcoverClient.isEnglishTag).map(Self.displayGenre)
    }

    /// Capitalizes tags that readers entered in lowercase, such as "litrpg", and keeps any other
    /// capitalization, such as "LGBTQ" or "LitRPG".
    static func displayGenre(_ tag: String) -> String {
        tag == tag.lowercased() ? tag.capitalized : tag
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

    /// The length for display: listening time in whole minutes for an audiobook when Hardcover
    /// records it, otherwise the page count.
    var lengthLabel: String? {
        if formatLabel == "Audiobook", let audioSeconds, audioSeconds > 0 {
            return "\((audioSeconds + 30) / 60) minutes"
        }
        if let pages, pages > 0 { return "\(pages) pages" }
        return nil
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

/// Permanent Hardcover web links by ID. Hardcover redirects them to the current page, so they
/// keep working when a slug or username changes.
enum HardcoverLink {
    static func book(_ id: Int) -> URL { URL(string: "https://hardcover.app/id/books/\(id)")! }
    static func user(_ id: Int) -> URL { URL(string: "https://hardcover.app/id/user/\(id)")! }
}

/// One Hardcover series a book belongs to. The iPhone companion decodes the same keys from the
/// iCloud archive.
struct SeriesMembership: Codable, Hashable, Sendable {
    let seriesID: Int
    let name: String
    /// The book's position in the series, such as 3, or 2.5 for a companion work.
    var position: Double? = nil
    /// Whether Hardcover features this series for the book.
    var featured = false
    /// Whether the book collects other books of the series, such as an omnibus.
    var compilation = false
    /// The series' number of primary books, or of all its books when Hardcover has no primary
    /// count.
    var size: Int? = nil
}

/// A series and its main books in reading order, fetched during sync so details open offline.
struct SeriesInfo: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    /// The series' main books, one per whole-number position, earliest first.
    let books: [SeriesBook]

    struct SeriesBook: Codable, Hashable, Sendable, Identifiable {
        let id: Int
        let title: String
        let position: Double
        let releaseYear: Int?
        let coverURL: URL?
    }

    /// "#3", or "#2.5" for a companion work.
    static func positionLabel(_ position: Double) -> String {
        "#" + position.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// A book's series as its details show them: the series its label names
/// (`SeriesDesigns.shownSeries(of:link:)`) and every series the book belongs to, with each
/// series' main books when the last sync fetched them.
struct ShownSeries: Hashable, Sendable {
    /// The series the label names.
    let membership: SeriesMembership
    /// Every series the book belongs to, once each in Hardcover's order, including `membership`.
    let all: [SeriesMembership]
    /// The main books of the series in `all` that the last sync fetched, by series ID.
    let infos: [Int: SeriesInfo]

    var info: SeriesInfo? { infos[membership.seriesID] }
}

struct LibrarySnapshot: Codable, Sendable {
    let books: [Book]
    let syncedAt: Date
}

enum SampleLibrary {
    /// Fictional community reviews shown for any sample book, including one long enough to
    /// truncate and one with spoilers.
    static let reviews: [BookReview] = [
        BookReview(
            id: 1,
            reader: ReaderProfile(
                id: 1, username: "quietreader", name: "Sam Ellery", avatarURL: nil),
            rating: 4.5,
            text: String(
                repeating:
                    "The pacing rewards patience, and the final chapters gather every thread. ",
                count: 12), hasSpoilers: false, likes: 14),
        BookReview(
            id: 2,
            reader: ReaderProfile(id: 2, username: "margins", name: nil, avatarURL: nil),
            rating: 3, text: "Lovely atmosphere, though the middle drags.", hasSpoilers: false,
            likes: 0),
        BookReview(
            id: 3,
            reader: ReaderProfile(id: 3, username: "endings", name: "Jo Park", avatarURL: nil),
            rating: 5, text: "The archive belonged to the narrator all along.", hasSpoilers: true,
            likes: 1),
    ]

    // Fictional fixtures keep previews and UI tests independent of private reading history.
    static let books: [Book] = [
        Book(
            id: 1, title: "The Orchard at Night", author: "Alex Rowan",
            description: String(
                repeating:
                    "A botanist returns to an island where the trees bloom only after sunset. As the seasons change, a forgotten family archive reveals a different history of the island and the people who call it home. ",
                count: 8), pages: 384, finished: "2026-09-09",
            finishedDates: ["2026-09-09", "2024-03-14"], rating: 4.5, format: "Ebook",
            seriesID: 1, seriesPosition: 1, seriesName: "The Island Cycle",
            seriesMemberships: [
                SeriesMembership(
                    seriesID: 1, name: "The Island Cycle", position: 1, featured: true, size: 3),
                SeriesMembership(
                    seriesID: 2, name: "Tales of the Night Orchard", position: 1, size: 4),
            ],
            genres: ["Fantasy", "Mystery"], communityRating: 4.24,
            ratingsCount: 100,
            ratingDistribution: [
                RatingBucket(rating: 3, count: 10), RatingBucket(rating: 4, count: 56),
                RatingBucket(rating: 5, count: 34),
            ], publicationYear: 2023),
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
            format: "Audiobook", seriesID: 1, seriesPosition: 2, seriesName: "The Island Cycle",
            seriesMemberships: [
                SeriesMembership(
                    seriesID: 1, name: "The Island Cycle", position: 2, featured: true, size: 3)
            ],
            publicationYear: 2025),
    ]
}

extension SampleLibrary {
    /// Sample book 1's series: `series`, its shortest, which its details name, and `tales`.
    static let allSeries = [series, tales]

    /// The sample books 1 and 8, plus a third book the sample reader doesn't own.
    static let series = SeriesInfo(
        id: 1, name: "The Island Cycle",
        books: [
            .init(
                id: 1, title: "The Orchard at Night", position: 1, releaseYear: 2023, coverURL: nil),
            .init(
                id: 8, title: "Winter in the Orchard", position: 2, releaseYear: 2025, coverURL: nil
            ),
            .init(id: 9, title: "The Last Harvest", position: 3, releaseYear: 2027, coverURL: nil),
        ])

    /// A longer series of sample book 1, whose other books the sample reader doesn't own.
    static let tales = SeriesInfo(
        id: 2, name: "Tales of the Night Orchard",
        books: [
            .init(
                id: 1, title: "The Orchard at Night", position: 1, releaseYear: 2023, coverURL: nil),
            .init(
                id: 10, title: "The Lantern Keeper", position: 2, releaseYear: 2024, coverURL: nil),
            .init(id: 11, title: "Seeds of Morning", position: 3, releaseYear: 2025, coverURL: nil),
            .init(id: 12, title: "The Quiet Grove", position: 4, releaseYear: 2026, coverURL: nil),
        ])

    /// Fictional books only the sample reader has read.
    static let friendPicks: [Book] = [
        Book(
            id: 101, title: "The Cartographer's Daughter", author: "Rae Linden", pages: 352,
            finished: "2026-07-14", communityRating: 4.1),
        Book(
            id: 102, title: "Salt and Lanterns", author: "Imogen Hale", pages: 288,
            finished: "2026-06-02", communityRating: 3.9),
    ]
}

struct RatingBucket: Codable, Hashable, Identifiable, Sendable {
    let rating: Double
    let count: Int
    var id: Double { rating }
}
