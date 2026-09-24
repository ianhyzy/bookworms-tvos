import Foundation

/// Fixed read documents keep social browsing separate from account mutations.
enum SocialQuery: String {
    case owner = "query SocialOwner { me { id username name image { url } } }"
    case following = """
        query SocialFollowing($user: Int!, $offset: Int!) {
          followed_users(where: {user_id: {_eq: $user}}, order_by: {id: asc}, limit: 100, offset: $offset) {
            followed_user { id username name image { url } }
          }
        }
        """
    case feed = """
        query SocialFeed($users: [Int!]!) {
          activities(where: {user_id: {_in: $users}}, order_by: [{created_at: desc}, {id: desc}], limit: 100) {
            id created_at event data likes_count user { id username name image { url } }
            book { id title description pages cached_contributors image { url width height } }
          }
        }
        """
    case library = """
        query SocialLibrary($user: Int!, $offset: Int!) {
          user_books(where: {user_id: {_eq: $user}, _or: [{rating: {_is_null: false}}, {last_read_date: {_is_null: false}}]},
            order_by: {id: asc}, limit: 100, offset: $offset) {
            id rating review review_has_spoilers last_read_date
            book { id title description pages cached_contributors image { url width height } }
            edition { id image { url width height } reading_format { format } }
          }
        }
        """
}

struct SocialVariables: Encodable, Sendable {
    var user: Int? = nil
    var offset: Int? = nil
    var users: [Int]? = nil
}

protocol SocialLibraryFetching: Sendable {
    func owner(token: String) async throws -> ReaderProfile
    func following(owner: Int, token: String) async throws -> [ReaderProfile]
    func feed(users: [Int], token: String) async throws -> [FeedActivity]
    func library(user: Int, token: String) async throws -> [ReaderBook]
}

actor HardcoverSocialClient: SocialLibraryFetching {
    private let client: HardcoverClient
    init(client: HardcoverClient = .shared) { self.client = client }

    private func fetch<T: Decodable>(
        _ query: SocialQuery, variables: SocialVariables, token: String
    ) async throws -> T {
        let data = try await client.socialData(query, variables: variables, token: token)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func owner(token: String) async throws -> ReaderProfile {
        struct Result: Decodable { let me: [Profile] }
        let result: Result = try await fetch(.owner, variables: SocialVariables(), token: token)
        guard result.me.count == 1, let profile = result.me.first else {
            throw HardcoverError.invalidToken
        }
        return profile.model
    }

    func following(owner: Int, token: String) async throws -> [ReaderProfile] {
        struct Row: Decodable {
            let followedUser: Profile
            enum CodingKeys: String, CodingKey { case followedUser = "followed_user" }
        }
        struct Result: Decodable {
            let followedUsers: [Row]
            enum CodingKeys: String, CodingKey { case followedUsers = "followed_users" }
        }
        var profiles: [Int: ReaderProfile] = [:]
        for offset in stride(from: 0, to: 100_000, by: 100) {
            try Task.checkCancellation()
            let result: Result = try await fetch(
                .following, variables: SocialVariables(user: owner, offset: offset), token: token)
            for row in result.followedUsers {
                profiles[row.followedUser.id] = row.followedUser.model
            }
            if result.followedUsers.count < 100 {
                return profiles.values.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            }
        }
        throw HardcoverError.incomplete
    }

    func feed(users: [Int], token: String) async throws -> [FeedActivity] {
        guard !users.isEmpty else { return [] }
        struct Result: Decodable { let activities: [Activity] }
        var activities: [Int: FeedActivity] = [:]
        // Fetch a bounded window per chunk, then deduplicate books across the network.
        for start in stride(from: 0, to: users.count, by: 200) {
            let result: Result = try await fetch(
                .feed,
                variables: SocialVariables(
                    users: Array(users[start..<min(start + 200, users.count)])), token: token)
            for activity in result.activities { activities[activity.id] = activity.model }
        }
        return FeedActivity.latestPerBook(Array(activities.values))
    }

    func library(user: Int, token: String) async throws -> [ReaderBook] {
        struct Row: Decodable {
            let id: Int
            let rating: Double?
            let review: String?
            let reviewHasSpoilers: Bool
            let lastReadDate: String?
            let book: SourceBook
            let edition: Edition?
            enum CodingKeys: String, CodingKey {
                case id, rating, review, book, edition
                case reviewHasSpoilers = "review_has_spoilers"
                case lastReadDate = "last_read_date"
            }
        }
        struct Result: Decodable {
            let userBooks: [Row]
            enum CodingKeys: String, CodingKey { case userBooks = "user_books" }
        }
        var books: [Int: ReaderBook] = [:]
        for offset in stride(from: 0, to: 100_000, by: 100) {
            try Task.checkCancellation()
            let result: Result = try await fetch(
                .library, variables: SocialVariables(user: user, offset: offset), token: token)
            for row in result.userBooks {
                books[row.book.id] = ReaderBook(
                    book: Self.book(row.book, edition: row.edition), rating: row.rating,
                    review: ReviewText.clean(row.review), hasSpoilers: row.reviewHasSpoilers,
                    finished: row.lastReadDate)
            }
            if result.userBooks.count < 100 { return books.values.sorted { $0.id < $1.id } }
        }
        throw HardcoverError.incomplete
    }

    /// Maps a Hardcover book, choosing its cover as the shelf does: the reader's edition image when
    /// it is not clearly lower quality than the book's default image.
    static func book(_ source: SourceBook, edition: Edition? = nil) -> Book {
        let covers = HardcoverClient.coverURLs(edition: edition?.image, book: source.image)
        let authors = (source.cachedContributors ?? [])
            .filter { $0.contribution == nil || $0.contribution == "Author" }
            .compactMap { $0.author?.name }.joined(separator: ", ")
        return Book(
            id: source.id, title: source.title ?? "Untitled",
            author: authors.isEmpty ? "Unknown author" : authors,
            description: source.description, coverURL: covers.alternate, pages: source.pages,
            format: edition?.readingFormat?.format, detailCoverURL: covers.preferred,
            sources: [.hardcover])
    }

    private struct Profile: Decodable {
        let id: Int
        let username: String
        let name: String?
        let image: CoverImage?
        var model: ReaderProfile {
            ReaderProfile(id: id, username: username, name: name, avatarURL: image?.url)
        }
    }

    private struct Activity: Decodable {
        let id: Int
        let createdAt: String?
        let event: String
        let data: JSONValue
        let likesCount: Int
        let user: Profile
        let book: SourceBook?
        enum CodingKeys: String, CodingKey {
            case id, event, data, user, book
            case createdAt = "created_at"
            case likesCount = "likes_count"
        }
        var model: FeedActivity {
            let status = (data.value("statusId") ?? data.value("status_id"))?.number
            let progress = data.value("progress")?.number
            let summary: String
            if event.lowercased().contains("review") {
                summary = "Reviewed a book"
            } else if event.lowercased().contains("list") {
                summary =
                    data.value("list")?.value("name")?.string.map { "Updated list: \($0)" }
                    ?? "Updated a reading list"
            } else if event == "UserBookActivity", status == 2, let progress,
                (0...100).contains(progress)
            {
                summary = "Reading progress: \(Int(progress))%"
            } else if let status {
                summary =
                    [
                        1: "Wants to read", 2: "Is reading", 3: "Finished reading",
                        4: "Paused reading", 5: "Did not finish",
                    ][Int(status)] ?? "Updated a book"
            } else if event.lowercased().contains("rating") {
                summary = "Rated a book"
            } else {
                summary = "Shared a reading update"
            }
            return FeedActivity(
                id: id, reader: user.model, createdAt: createdAt, summary: summary,
                book: book.map { HardcoverSocialClient.book($0) }, likes: max(0, likesCount),
                rating: data.value("rating")?.number,
                review: ReviewText.clean(
                    data.value("review")?.string ?? data.value("reviewSlate")?.plainText),
                hasSpoilers: (data.value("reviewHasSpoilers") ?? data.value("review_has_spoilers"))?
                    .bool ?? true)
        }
    }
}

/// Activity payloads vary by event; unknown fields remain data rather than executable markup.
indirect enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let v = try? value.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? value.decode(Double.self) {
            self = .number(v)
        } else if let v = try? value.decode(String.self) {
            self = .string(v)
        } else if let v = try? value.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .array(try value.decode([JSONValue].self))
        }
    }
    func value(_ key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key] ?? values["userBook"]?.value(key) ?? values["user_book"]?.value(key)
            ?? values["attributes"]?.value(key)
    }
    var number: Double? {
        if case .number(let value) = self { return value }
        if case .string(let value) = self { return Double(value) }
        return nil
    }
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    /// Slate stores paragraphs as nested children; read only their text leaves.
    var plainText: String? {
        switch self {
        case .object(let values):
            if let text = values["text"]?.string { return text }
            if case .array(let children) = values["children"] {
                return children.compactMap(\.plainText).joined()
            }
            return nil
        case .array(let values):
            let text = values.compactMap(\.plainText).joined(separator: "\n")
            return text.isEmpty ? nil : text
        default: return nil
        }
    }
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
