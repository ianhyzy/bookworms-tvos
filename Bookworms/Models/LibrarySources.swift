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

    static func bookID(server: String, identifier: String) -> Int {
        // Reserve a separate positive range, preserving existing Hardcover IDs and deep links.
        let digest = SHA256.hash(data: Data("cwa:\(server):\(identifier)".utf8))
        let value = digest.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(value) + 1_000_000_000_000_000
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
    case read = "Read Books"
    case owned = "Owned Books"
    case all = "All Books"
    var id: String { rawValue }
}

enum ShelfSort: String, Codable, CaseIterable, Identifiable {
    case dateRead = "Date Read"
    case rating = "Your Rating"
    case year = "Publication Year"
    case title = "Title"
    case author = "Author"
    case length = "Length"
    var id: String { rawValue }
}

struct ShelfPreferences: Codable, Equatable {
    var collection = ShelfCollection.read
    var sort = ShelfSort.dateRead
    var reversed = false

    func select(_ books: [Book], limit: Int) -> [Book] {
        let eligible = books.filter {
            switch collection {
            case .read: $0.isRead == true || $0.finished != nil
            case .owned: $0.isOwned == true
            case .all: true
            }
        }
        return Array(
            eligible.sorted { lhs, rhs in
                func compare<T: Comparable>(_ a: T?, _ b: T?, descending: Bool) -> Bool? {
                    if a == b { return nil }
                    guard let a else { return false }
                    guard let b else { return true }
                    return descending != reversed ? a > b : a < b
                }
                let order: Bool?
                switch sort {
                case .dateRead: order = compare(lhs.finished, rhs.finished, descending: true)
                case .rating: order = compare(lhs.rating, rhs.rating, descending: true)
                case .year:
                    order = compare(lhs.publicationYear, rhs.publicationYear, descending: true)
                case .length: order = compare(lhs.pages, rhs.pages, descending: false)
                case .title:
                    order = compare(
                        lhs.title.lowercased(), rhs.title.lowercased(), descending: false)
                case .author:
                    order = compare(
                        lhs.author.lowercased(), rhs.author.lowercased(), descending: false)
                }
                return order ?? (lhs.id < rhs.id)
            }
            .prefix(min(BookLimit.maximum, max(1, limit))))
    }
}

enum LibraryMerge {
    static func books(from snapshots: [SourceSnapshot]) -> [Book] {
        var result: [String: Book] = [:]
        // Hardcover supplies personal reading data; CWA adds ownership without replacing it.
        for snapshot in snapshots.sorted(by: { $0.source.rawValue > $1.source.rawValue }) {
            for var book in snapshot.books {
                book.sources = [snapshot.source]
                let key = matchingKey(book)
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

    private static func matchingKey(_ book: Book) -> String {
        func normalized(_ text: String) -> String {
            text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard book.author != "Unknown author", !book.title.isEmpty else { return "id:\(book.id)" }
        return normalized(book.title) + "|" + normalized(book.author)
    }
}
