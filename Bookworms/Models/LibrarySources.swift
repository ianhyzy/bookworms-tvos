import CryptoKit
import Foundation

enum LibrarySource: String, Codable, CaseIterable, Identifiable, Sendable {
    case hardcover, cwa
    var id: String { rawValue }
    var title: String { self == .hardcover ? "Hardcover" : "Calibre Web Automated" }
}

struct SourceSnapshot: Codable, Sendable {
    var source: LibrarySource
    var accountID: String
    var books: [Book]
    var syncedAt: Date
    /// Series that the books belong to; Hardcover only. `nil` in snapshots saved before series
    /// were fetched.
    var series: [SeriesInfo]? = nil
}

struct CWAConfiguration: Codable, Equatable, Sendable {
    var server = ""
    var username = ""
    var credentialAccount: String { "cwa-password" }

    func baseURL() throws -> URL {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil
        else { throw SourceError.invalidServer }
        return url
    }

    var identity: String { "\(server.trimmingCharacters(in: .whitespacesAndNewlines))/\(username)" }

    /// The lowest CWA book ID. CWA IDs take a separate positive range above Hardcover's, which
    /// keeps Hardcover IDs and deep links, so a book's ID tells its source
    /// (`Book.isHardcoverBook`).
    static let firstBookID = 1_000_000_000_000_000

    static func bookID(server: String, identifier: String) -> Int {
        let digest = SHA256.hash(data: Data("cwa:\(server):\(identifier)".utf8))
        let value = digest.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(value) + firstBookID
    }
}

enum SourceError: LocalizedError {
    case invalidServer, invalidCredentials, credentials, forbidden, invalidFeed, incomplete,
        unsafeLink, dailyLimit
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "Enter an HTTPS server address without a username, password, or query in the URL."
        case .invalidCredentials:
            "Enter a CWA username and password. The username cannot contain a colon."
        case .forbidden:
            "CWA denied access to the catalog. Check that this account has OPDS permission."
        case .http(404):
            "The OPDS catalog was not found. Check the CWA server address and OPDS settings."
        case .http(429): "CWA is limiting requests. Try again after the next scheduled check."
        case .http(let status):
            "CWA returned a server error (HTTP \(status)). Saved books are unchanged."
        case .credentials: "CWA rejected the login. Use a local CWA account with OPDS access."
        case .invalidFeed:
            "The server did not return a valid OPDS book catalog. Check the address and OPDS access."
        case .incomplete:
            "The source could not be synced completely. Its saved books are unchanged."
        case .unsafeLink:
            "The catalog linked outside its server. The request was stopped to protect your login."
        case .dailyLimit: "This source was checked recently. Use Sync now to retry sooner."
        }
    }
}

enum ShelfCollection: String, Codable, CaseIterable, Identifiable {
    /// Up to `ShelfPreferences.readingLimit` current reads, then read books.
    case read = "Read Books"
    case owned = "Owned Books"
    case all = "All Books"
    var id: String { rawValue }

    /// Decodes unknown values, including the retired "Default", as `read`.
    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .read
    }
}

enum ShelfSort: String, Codable, CaseIterable, Identifiable {
    case dateRead = "Date Read"
    case rating = "Your Rating"
    case year = "Publication Year"
    case title = "Title"
    case author = "Author"
    case length = "Length"
    /// Largest gap between your rating and the community's first; books missing either go last.
    case hotTakes = "Hot Takes"
    var id: String { rawValue }
}

/// Limits My Shelf to one author or genre, chosen from book details. It lasts until the user
/// clears it or the app relaunches, and never changes the saved shelf preferences.
enum ShelfFilter: Hashable, Sendable {
    case author(String)
    /// A display genre, as `Book.displayGenre` formats it.
    case genre(String)

    var name: String {
        switch self {
        case .author(let name), .genre(let name): name
        }
    }

    func matches(_ book: Book) -> Bool {
        switch self {
        case .author(let name): book.author == name
        case .genre(let name):
            book.genres?.contains { Book.displayGenre($0) == name } ?? false
        }
    }
}

/// How current reads show progress on My Shelf, its ambient shelf, and Top Shelf.
enum ProgressStyle: String, Codable, CaseIterable, Identifiable {
    case hidden = "Don't show"
    /// The system's linear progress bar along the cover's base; Top Shelf's native bar.
    case horizontal = "Horizontal"
    /// A light sweep: the unread part dims right of a soft line at the reader's place.
    case vertical = "Vertical"
    var id: String { rawValue }
}

struct ShelfPreferences: Codable, Equatable {
    /// The most current reads that lead **Read Books** and **All Books**.
    static let readingLimit = 3

    var collection: ShelfCollection
    var sort: ShelfSort
    var reversed: Bool
    var progressStyle: ProgressStyle

    init(
        collection: ShelfCollection = .all, sort: ShelfSort = .dateRead, reversed: Bool = false,
        progressStyle: ProgressStyle = .vertical
    ) {
        self.collection = collection
        self.sort = sort
        self.reversed = reversed
        self.progressStyle = progressStyle
    }

    /// Fills choices missing from older saved preferences with their defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            collection: try container.decodeIfPresent(ShelfCollection.self, forKey: .collection)
                ?? .all,
            sort: (try? container.decodeIfPresent(ShelfSort.self, forKey: .sort)) ?? .dateRead,
            reversed: try container.decodeIfPresent(Bool.self, forKey: .reversed) ?? false,
            progressStyle: (try? container.decodeIfPresent(
                ProgressStyle.self, forKey: .progressStyle)) ?? .vertical)
    }

    /// Books for the shelf, in display order. **Read Books** and **All Books** lead with the most
    /// recently started current reads, regardless of sort, and they count toward `limit`.
    func select(_ books: [Book], limit: Int) -> [Book] {
        let reading =
            collection == .owned
            ? []
            : books.filter { $0.isReading == true }
                .sorted { ($0.started ?? "", $0.id) > ($1.started ?? "", $1.id) }
                .prefix(Self.readingLimit)
        let pinned = Set(reading.map(\.id))
        let limit = min(BookLimit.maximum, max(1, limit))
        let eligible = books.filter {
            guard !pinned.contains($0.id) else { return false }
            switch collection {
            case .read: return $0.isReading != true && ($0.isRead == true || $0.finished != nil)
            case .owned: return $0.isOwned == true
            case .all: return true
            }
        }
        let sorted = eligible.sorted { lhs, rhs in
            func compare<T: Comparable>(_ a: T?, _ b: T?, descending: Bool) -> Bool? {
                if a == b { return nil }
                guard let a else { return false }
                guard let b else { return true }
                return descending != reversed ? a > b : a < b
            }
            // Numbers in text compare by value, so "Volume 2" comes before "Volume 10", as on
            // the iPhone and Mac.
            func compareText(_ a: String, _ b: String) -> Bool? {
                let result = a.localizedStandardCompare(b)
                return result == .orderedSame ? nil : (result == .orderedAscending) != reversed
            }
            let order: Bool?
            switch sort {
            case .dateRead: order = compare(lhs.finished, rhs.finished, descending: true)
            case .rating: order = compare(lhs.rating, rhs.rating, descending: true)
            case .year:
                order = compare(lhs.publicationYear, rhs.publicationYear, descending: true)
            case .length: order = compare(lhs.pages, rhs.pages, descending: false)
            case .hotTakes: order = compare(lhs.ratingGap, rhs.ratingGap, descending: true)
            case .title: order = compareText(lhs.title, rhs.title)
            case .author: order = compareText(lhs.author, rhs.author)
            }
            return order ?? (lhs.id < rhs.id)
        }
        return Array((Array(reading) + sorted).prefix(limit))
    }
}

enum LibraryMerge {
    /// Books from every snapshot, one per Hardcover ID. Hardcover books never merge with each
    /// other, even with the same title and author, because Hardcover can list one real book
    /// under two IDs and cleaning that up isn't the app's job. A CWA book has no Hardcover ID, so
    /// it joins the Hardcover book with its title and author (`matchingKey(_:)`), else stands
    /// alone.
    static func books(from snapshots: [SourceSnapshot]) -> [Book] {
        var result: [String: Book] = [:]
        /// The result key of the first Hardcover book with each title and author.
        var hardcoverKeys: [String: String] = [:]
        // Hardcover supplies personal reading data; CWA adds ownership without replacing it.
        for snapshot in snapshots.sorted(by: { $0.source.rawValue > $1.source.rawValue }) {
            for var book in snapshot.books {
                book.sources = [snapshot.source]
                let ownKey = "\(snapshot.source.rawValue):\(book.id)"
                let titleKey = matchingKey(book)
                let key: String
                if snapshot.source == .hardcover {
                    key = ownKey
                    if let titleKey, hardcoverKeys[titleKey] == nil {
                        hardcoverKeys[titleKey] = key
                    }
                } else {
                    key = titleKey.flatMap { hardcoverKeys[$0] } ?? ownKey
                }
                if var existing = result[key] {
                    existing.isOwned = existing.isOwned == true || book.isOwned == true
                    existing.isRead = existing.isRead == true || book.isRead == true
                    existing.publicationYear = existing.publicationYear ?? book.publicationYear
                    existing.pages = existing.pages ?? book.pages
                    existing.description = existing.description ?? book.description
                    existing.coverURL = existing.coverURL ?? book.coverURL
                    existing.sources = Array(Set((existing.sources ?? []) + [snapshot.source]))
                        .sorted { $0.rawValue < $1.rawValue }
                    result[key] = existing
                } else {
                    result[key] = book
                }
            }
        }
        return result.values.sorted(by: Book.recentFirst)
    }

    /// The normalized title and author, or `nil` when the title is empty or the author unknown.
    private static func matchingKey(_ book: Book) -> String? {
        func normalized(_ text: String) -> String {
            text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard book.author != "Unknown author", !book.title.isEmpty else { return nil }
        return normalized(book.title) + "|" + normalized(book.author)
    }
}
