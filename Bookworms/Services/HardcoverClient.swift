import Foundation
import NaturalLanguage
import Synchronization

/// Backoff for network failures that may pass: server errors (5xx), timeouts, and dropped
/// connections. Hardcover's API and cover hosts are busy enough that a single failure is common.
enum TransientRetry {
    /// Waits before the second and third attempts. Each wait gains up to a second of random
    /// jitter so concurrent requests don't retry in lockstep.
    static let delays: [Double] = [2, 4]

    /// The wait before retrying `error`, or `nil` when it won't pass by retrying or no retries
    /// remain.
    static func delay(after error: Error, attempt: Int) -> Double? {
        guard attempt < delays.count else { return nil }
        let transient: Bool
        if case HardcoverError.http(let status) = error {
            transient = (500...599).contains(status)
        } else if let code = (error as? URLError)?.code {
            transient = [
                .timedOut, .networkConnectionLost, .cannotConnectToHost, .badServerResponse,
            ]
            .contains(code)
        } else {
            transient = false
        }
        return transient ? delays[attempt] + .random(in: 0..<1) : nil
    }
}

enum HardcoverError: LocalizedError {
    case invalidToken, invalidAuthorizationCode, personalAccessTokenRequired
    case insufficientScope, forbidden
    case http(Int)
    case rejected, incomplete
    case deviceFlowDenied, deviceFlowExpired
    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "The Hardcover login is invalid or expired. Reconnect in Settings."
        case .invalidAuthorizationCode:
            "The authorization code is invalid or expired. Reconnect in Settings."
        case .deviceFlowDenied:
            "Hardcover authorization was denied. Reconnect in Settings."
        case .deviceFlowExpired:
            "The linking code has expired. Generate a new code to reconnect."
        case .personalAccessTokenRequired:
            "Sign in with Hardcover in Settings → Sources. Legacy credentials are no longer supported. Your saved shelf is still available."
        case .insufficientScope:
            "This token needs read:me:content, read:library, and read:catalog:data. Create a token with these read permissions and reconnect."
        case .forbidden:
            "Hardcover denied access to this request. Your saved shelf is unchanged."
        case .http(429):
            "Hardcover is limiting requests. Library sync will retry at the next daily check."
        case .http(500...599):
            "Hardcover is temporarily unavailable. Your saved shelf is unchanged."
        case .http(let status):
            "Hardcover could not complete the request (HTTP \(status)). Your saved shelf is unchanged."
        case .rejected:
            "Hardcover could not provide the requested book data. Your saved shelf is unchanged."
        case .incomplete:
            "The library could not be loaded completely. Your saved shelf is unchanged."
        }
    }
}

struct HardcoverDeviceAuth: Equatable, Sendable, Codable {
    var deviceCode: String
    var userCode: String
    var verificationURI: URL
    var verificationURIComplete: URL?
    var expiresIn: Int
    var interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

enum HardcoverDevicePollResult: Equatable, Sendable {
    case pending
    case slowDown
    case expired
    case accessDenied
    case success(token: String)
}

actor HardcoverClient {
    static let shared = HardcoverClient()

    static let clientID = "ca996be3-0df1-4cbf-819a-e17644fbcf38"
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    static let callbackScheme = "gay.ian.bookworms"
    static let scopes = "read:me:content read:library read:catalog:data read:social read:users"

    static func authorizationURL() -> URL {
        var components = URLComponents(string: "https://hardcover.app/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
        ]
        return components.url!
    }

    private var retryAfter = Date.distantPast
    private var nextRequestAt = Date.distantPast
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    /// Reports whether a community tag reads as English. Readers tag in their own languages, so
    /// Hardcover can return tags such as "Féminisme" beside "Feminism". A strong English prior
    /// keeps short or ambiguous English tags; only clearly foreign tags fall below the threshold.
    static func isEnglishTag(_ tag: String) -> Bool {
        if let known = englishTags.withLock({ $0[tag] }) { return known }
        let isEnglish = recognizesEnglish(tag)
        englishTags.withLock { $0[tag] = isEnglish }
        return isEnglish
    }

    /// Results by tag. Views and Year in Review preparation check the same few hundred tags
    /// repeatedly. ponytail: unbounded, but limited by the library's distinct tags.
    private static let englishTags = Mutex<[String: Bool]>([:])

    private static func recognizesEnglish(_ tag: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        let languages: [NLLanguage] = [
            .english, .french, .spanish, .german, .italian, .portuguese, .dutch, .swedish, .polish,
        ]
        recognizer.languageConstraints = languages
        recognizer.languageHints = Dictionary(
            uniqueKeysWithValues: languages.map { ($0, $0 == .english ? 0.9 : 0.1 / 8) })
        recognizer.processString(tag)
        return recognizer.languageHypotheses(withMaximum: 1)[.english, default: 0] >= 0.7
    }

    func requestDeviceAuth() async throws -> HardcoverDeviceAuth {
        var request = URLRequest(url: URL(string: "https://hardcover.app/oauth2/device")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bookworms/1.0 (read-only tvOS client)", forHTTPHeaderField: "User-Agent")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]
        guard let bodyString = bodyComponents.percentEncodedQuery else {
            throw HardcoverError.rejected
        }
        request.httpBody = Data(bodyString.utf8)

        let (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw HardcoverError.incomplete
        }
        guard http.statusCode == 200 else {
            throw HardcoverError.http(http.statusCode)
        }

        guard let auth = try? JSONDecoder().decode(HardcoverDeviceAuth.self, from: data) else {
            throw HardcoverError.rejected
        }
        return auth
    }

    func pollDeviceToken(deviceCode: String) async throws -> HardcoverDevicePollResult {
        var request = URLRequest(url: URL(string: "https://hardcover.app/oauth2/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bookworms/1.0 (read-only tvOS client)", forHTTPHeaderField: "User-Agent")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code"),
            URLQueryItem(name: "device_code", value: deviceCode),
            URLQueryItem(name: "client_id", value: Self.clientID),
        ]
        guard let bodyString = bodyComponents.percentEncodedQuery else {
            throw HardcoverError.rejected
        }
        request.httpBody = Data(bodyString.utf8)

        let (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw HardcoverError.incomplete
        }

        if http.statusCode == 200 {
            struct TokenResponse: Decodable {
                let accessToken: String
                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                }
            }
            guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data)
            else {
                throw HardcoverError.rejected
            }
            let token = try HardcoverToken(tokenResponse.accessToken).value
            return .success(token: token)
        }

        struct ErrorResponse: Decodable {
            let error: String?
        }
        let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        switch errorResponse?.error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "expired_token":
            return .expired
        case "access_denied":
            return .accessDenied
        default:
            if http.statusCode == 400 || http.statusCode == 401 {
                throw HardcoverError.invalidAuthorizationCode
            }
            throw HardcoverError.http(http.statusCode)
        }
    }

    func exchangeAuthorizationCode(
        _ code: String,
        redirectURI: String = HardcoverClient.redirectURI
    ) async throws -> String {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty,
            !code.contains(where: { $0.isWhitespace || $0.isNewline }),
            code.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw HardcoverError.invalidAuthorizationCode
        }

        var request = URLRequest(url: URL(string: "https://hardcover.app/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bookworms/1.0 (read-only tvOS client)", forHTTPHeaderField: "User-Agent")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        guard let bodyString = bodyComponents.percentEncodedQuery else {
            throw HardcoverError.invalidAuthorizationCode
        }
        request.httpBody = Data(bodyString.utf8)

        let (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw HardcoverError.incomplete
        }

        if http.statusCode == 400 || http.statusCode == 401 {
            throw HardcoverError.invalidAuthorizationCode
        }
        guard http.statusCode == 200 else {
            throw HardcoverError.http(http.statusCode)
        }

        struct TokenResponse: Decodable {
            let accessToken: String
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
            }
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw HardcoverError.rejected
        }
        return try HardcoverToken(tokenResponse.accessToken).value
    }

    // The client owns its query documents so callers cannot submit mutations.
    private enum Query: String {
        case account = "query ShelfAccount { me { id } }"
        case library = """
            query ShelfLibrary($user: Int!, $offset: Int!, $language: String!) {
              user_books(where: {user_id: {_eq: $user}}, order_by: {id: asc}, limit: 100, offset: $offset) {
                id last_read_date rating status_id
                book { id title description pages release_year cached_contributors cached_tags rating ratings_count ratings_distribution image { url width height }
                  book_series { featured position series { id } }
                  editions(where: {image_id: {_is_null: false},
                      _or: [{language_id: {_is_null: true}}, {language: {code2: {_eq: $language}}}]},
                    order_by: {users_count: desc}, limit: 5) {
                    image { url width height }
                  }
                }
                edition { id pages audio_seconds image { url width height } reading_format { format } language { code2 } }
                user_book_reads(where: {finished_at: {_is_null: false}},
                  order_by: [{finished_at: desc}, {id: desc}], limit: 1) {
                  finished_at edition { id pages audio_seconds image { url width height } reading_format { format } language { code2 } }
                }
                current_read: user_book_reads(where: {finished_at: {_is_null: true}},
                  order_by: [{id: desc}], limit: 1) {
                  started_at progress progress_pages progress_seconds edition { pages audio_seconds }
                }
              }
            }
            """
        case series = """
            query ShelfSeries($ids: [Int!]!) {
              series(where: {id: {_in: $ids}}) {
                id name
                book_series(where: {position: {_is_null: false}},
                  order_by: [{position: asc}, {book: {users_count: desc}}]) {
                  position book { id title release_year image { url width height } }
                }
              }
            }
            """
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let errors: [APIError]?
        struct APIError: Decodable { let message: String }
    }
    private struct Failure: Decodable { let error: String? }
    private struct Account: Decodable { let me: [User] }
    private struct User: Decodable { let id: Int }
    private struct Library: Decodable {
        let userBooks: [UserBook]
        enum CodingKeys: String, CodingKey { case userBooks = "user_books" }
    }

    private func request<T: Decodable>(_ query: Query, variables: [String: Any], token: String)
        async throws -> T
    {
        let body = try JSONSerialization.data(withJSONObject: [
            "query": query.rawValue, "variables": variables,
        ])
        let data = try await response(body: body, token: token)
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.errors?.isEmpty != false, let result = envelope.data else {
            throw HardcoverError.rejected
        }
        return result
    }

    func socialData(_ query: SocialQuery, variables: SocialVariables, token: String) async throws
        -> Data
    {
        struct Body: Encodable {
            let query: String
            let variables: SocialVariables
        }
        let body = try JSONEncoder().encode(Body(query: query.rawValue, variables: variables))
        let data = try await response(body: body, token: token)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HardcoverError.rejected
        }
        if let errors = envelope["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: " ")
                .lowercased()
            if messages.contains("permission") || messages.contains("scope")
                || messages.contains("not found in type")
            {
                throw HardcoverError.insufficientScope
            }
            throw HardcoverError.rejected
        }
        guard let result = envelope["data"] as? [String: Any] else { throw HardcoverError.rejected }
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// Sends a query, retrying failures that may pass. Server errors, timeouts, and dropped
    /// connections retry after about 2 and then 4 seconds. A rate limit retries once its
    /// Retry-After passes if that is at most 30 seconds away; a longer limit ends the request.
    private func response(body: Data, token: String) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await send(body: body, token: token)
            } catch {
                let delay: Double?
                if case HardcoverError.http(429) = error {
                    let wait = retryAfter.timeIntervalSinceNow
                    delay = wait <= 30 ? max(0, wait) : nil
                } else {
                    delay = TransientRetry.delay(after: error, attempt: attempt)
                }
                guard attempt < TransientRetry.delays.count, let delay else { throw error }
                attempt += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func send(body: Data, token: String) async throws -> Data {
        let token = try HardcoverToken(token).value
        guard Date() >= retryAfter else { throw HardcoverError.http(429) }
        // Reserve a slot before suspending so concurrent catalog and social calls share a budget.
        if session === URLSession.shared {
            let start = max(Date(), nextRequestAt)
            nextRequestAt = start.addingTimeInterval(1.1)
            let delay = start.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        try Task.checkCancellation()
        guard Date() >= retryAfter else { throw HardcoverError.http(429) }
        var request = URLRequest(url: URL(string: "https://api.hardcover.app/v1/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bookworms/1.0 (read-only tvOS client)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let started = Date()
        let (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else { throw HardcoverError.incomplete }
        await APIUsageStore.shared.record(
            service: "hardcover", status: http.statusCode,
            duration: Date().timeIntervalSince(started))
        if http.statusCode == 429 {
            let delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            retryAfter = Date().addingTimeInterval(min(3600, max(1, delay)))
        }
        if http.statusCode == 401 { throw HardcoverError.invalidToken }
        if http.statusCode == 403 {
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw failure?.error == "insufficient_scope"
                ? HardcoverError.insufficientScope : HardcoverError.forbidden
        }
        guard http.statusCode == 200 else { throw HardcoverError.http(http.statusCode) }
        return data
    }

    func validateToken(_ token: String) async throws -> String {
        let account: Account = try await request(.account, variables: [:], token: token)
        guard account.me.count == 1, let user = account.me.first else {
            throw HardcoverError.invalidToken
        }
        return String(user.id)
    }

    func fetchBooks(token: String) async throws -> [Book] {
        try await fetchLibrary(token: token).books
    }

    /// Returns the authenticated account with its complete library so saved books keep provenance.
    func fetchLibrary(token: String) async throws -> HardcoverLibrary {
        let account: Account = try await request(.account, variables: [:], token: token)
        guard account.me.count == 1, let user = account.me.first else {
            throw HardcoverError.invalidToken
        }
        var rows: [UserBook] = []
        for offset in stride(from: 0, to: 10000, by: 100) {
            try Task.checkCancellation()
            let result: Library = try await request(
                .library,
                variables: ["user": user.id, "offset": offset, "language": Self.coverLanguage],
                token: token)
            rows += result.userBooks
            if result.userBooks.count < 100 {
                let books = Self.normalize(rows)
                // Series are an enhancement: a failure keeps the library sync complete.
                let series = try? await fetchSeries(Set(books.compactMap(\.seriesID)), token: token)
                return HardcoverLibrary(accountID: String(user.id), books: books, series: series)
            }
            // Pace full pages to avoid exhausting the read API rate limit during large syncs.
            try await Task.sleep(for: .seconds(1.1))
        }
        throw HardcoverError.incomplete
    }

    /// Fetches series names and main books in batches of 50, paced like library pages.
    private func fetchSeries(_ ids: Set<Int>, token: String) async throws -> [SeriesInfo] {
        var result: [SeriesInfo] = []
        let sorted = ids.sorted()
        for start in stride(from: 0, to: sorted.count, by: 50) {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1.1))
            let batch = Array(sorted[start..<min(start + 50, sorted.count)])
            let response: SeriesResponse = try await request(
                .series, variables: ["ids": batch], token: token)
            result += response.series.map(Self.normalize)
        }
        return result
    }

    /// Keeps one book per whole-number position: the most-read, which the query lists first.
    static func normalize(_ series: SeriesResponse.Series) -> SeriesInfo {
        var seen = Set<Double>()
        let books = series.bookSeries.compactMap { entry -> SeriesInfo.SeriesBook? in
            guard let position = entry.position, position >= 0,
                position == position.rounded(), let book = entry.book,
                seen.insert(position).inserted
            else { return nil }
            return SeriesInfo.SeriesBook(
                id: book.id, title: book.title ?? "Untitled", position: position,
                releaseYear: book.releaseYear,
                coverURL: book.image?.url.flatMap { $0.scheme == "https" ? $0 : nil })
        }
        return SeriesInfo(id: series.id, name: series.name, books: books)
    }

    /// The sharpest portrait cover: portrait shapes beat other shapes, then height wins.
    ///
    /// Rejects images under 300 pixels on their shorter side and nearly square images, which are
    /// usually author photos or audiobook art rather than covers. Images without dimensions stay
    /// eligible.
    ///
    /// `preferred` (the reader's edition) scores as if 20% taller, so it wins unless another image
    /// is clearly larger. Ties go to the earlier image.
    static func bestCover(in images: [CoverImage], preferring preferred: CoverImage? = nil)
        -> CoverImage?
    {
        func score(_ image: CoverImage) -> Double {
            guard let width = image.width, let height = image.height, width > 0, height > 0
            else { return 0 }
            let ratio = Double(width) / Double(height)
            let portrait = (0.5...0.82).contains(ratio)
            let boost = preferred != nil && image.url == preferred?.url ? 1.2 : 1
            return (portrait ? 1_000_000 : 0) + min(Double(height) * boost, 2400) * 100
                - abs(ratio - 0.67) * 1000
        }
        return images.filter(isCover).max { score($0) < score($1) }
    }

    /// Whether `image` can serve as a cover: HTTPS, at least 300 pixels on its shorter side, and
    /// not nearly square. Images without dimensions pass.
    static func isCover(_ image: CoverImage) -> Bool {
        guard image.url?.scheme == "https" else { return false }
        guard let width = image.width, let height = image.height else { return true }
        let ratio = Double(width) / Double(max(1, height))
        return min(width, height) >= 300 && abs(ratio - 1) > 0.03
    }

    /// The two-letter ISO 639-1 code of the Apple TV's preferred language, such as "en". Cover
    /// choice considers other editions only in this language or with no language recorded;
    /// Hardcover stores the same code in `languages.code2`.
    static var coverLanguage: String {
        Locale.preferredLanguages.first
            .flatMap { Locale.Language(identifier: $0).languageCode?.identifier(.alpha2) }
            ?? "en"
    }

    /// The preferred cover and a fallback for when it fails to download.
    ///
    /// Candidates are the reader's edition, the book's default image, and `otherEditions`, the
    /// book's most-read editions. The reader's edition wins unless another is clearly better; a
    /// square audiobook image, for example, loses to any portrait cover. When no candidate is a
    /// portrait-shaped cover, the largest square image of at least 300 pixels is used rather than
    /// no cover.
    static func coverURLs(
        edition: CoverImage?, book: CoverImage?, otherEditions: [CoverImage] = [],
        editionIsInLanguage: Bool = true
    ) -> (preferred: URL?, alternate: URL?) {
        // A reader's edition in another language loses its preference and is used only when no
        // other image can serve as a cover.
        if !editionIsInLanguage, edition != nil {
            let choice = coverURLs(edition: nil, book: book, otherEditions: otherEditions)
            if choice.preferred != nil { return choice }
        }
        var seen = Set<URL>()
        let images = ([edition, book].compactMap(\.self) + otherEditions)
            .filter { $0.url.map { seen.insert($0).inserted } ?? false }
        guard let best = bestCover(in: images, preferring: edition) else {
            let square =
                images.filter { image in
                    guard image.url?.scheme == "https", let width = image.width,
                        let height = image.height
                    else { return false }
                    return min(width, height) >= 300
                }
                .max { ($0.height ?? 0) < ($1.height ?? 0) }
            return (square?.url, nil)
        }
        let alternate = images.first { isCover($0) && $0.url != best.url }?.url
        return (best.url, alternate)
    }

    /// Hardcover's `status_id` for **Currently Reading**.
    static let currentlyReadingStatus = 2
    /// Hardcover's `status_id` for **Read**.
    static let readStatus = 3

    /// The fraction of an unfinished read completed, from 0 to 1, or `nil` when the read logs no
    /// progress.
    ///
    /// Prefers Hardcover's percentage, which it records whether progress was logged as a
    /// percentage, pages, or listening time. Otherwise divides pages, then seconds, by the total
    /// from the read's edition, falling back to `pages` or `audioSeconds` from the library edition.
    static func progress(of read: CurrentRead?, pages: Int?, audioSeconds: Int?) -> Double? {
        guard let read else { return nil }
        let fraction: Double
        if let percent = read.progress {
            fraction = percent / 100
        } else if let done = read.progressPages, let total = read.edition?.pages ?? pages,
            total > 0
        {
            fraction = Double(done) / Double(total)
        } else if let done = read.progressSeconds,
            let total = read.edition?.audioSeconds ?? audioSeconds, total > 0
        {
            fraction = Double(done) / Double(total)
        } else {
            return nil
        }
        return fraction.isFinite ? min(1, max(0, fraction)) : nil
    }

    static func normalize(_ rows: [UserBook]) -> [Book] {
        var unique: [Int: Book] = [:]
        for row in rows {
            let source = row.book
            let read = row.userBookReads?.first
            let edition = read?.edition ?? row.edition
            let author = (source.cachedContributors ?? [])
                .filter {
                    $0.contribution == nil || $0.contribution == "Author"
                }
                .compactMap { $0.author?.name }.joined(separator: ", ")
            let covers = Self.coverURLs(
                edition: edition?.image, book: source.image,
                otherEditions: (source.editions ?? []).compactMap(\.image),
                editionIsInLanguage: edition?.isInLanguage(Self.coverLanguage) ?? true)
            let membership = source.bookSeries?
                .sorted { ($0.featured ?? false) && !($1.featured ?? false) }.first
            let book = Book(
                id: source.id, title: source.title ?? "Untitled",
                author: author.isEmpty ? "Unknown author" : author,
                description: source.description, coverURL: covers.alternate,
                pages: edition?.pages ?? source.pages,
                finished: read?.finishedAt ?? row.lastReadDate, rating: row.rating,
                format: edition?.readingFormat?.format,
                seriesID: membership?.series?.id,
                seriesPosition: membership?.position,
                genres: source.genres,
                communityRating: source.rating, ratingsCount: source.ratingsCount,
                ratingDistribution: source.validRatingDistribution,
                detailCoverURL: covers.preferred, sources: [.hardcover],
                isRead: row.statusID == Self.readStatus || read?.finishedAt != nil
                    || row.lastReadDate != nil,
                publicationYear: source.releaseYear,
                isReading: row.statusID == Self.currentlyReadingStatus ? true : nil,
                progress: row.statusID == Self.currentlyReadingStatus
                    ? Self.progress(
                        of: row.currentRead, pages: row.edition?.pages ?? source.pages,
                        audioSeconds: row.edition?.audioSeconds)
                    : nil,
                started: row.statusID == Self.currentlyReadingStatus
                    ? row.currentRead?.startedAt : nil,
                audioSeconds: edition?.audioSeconds)
            if let previous = unique[book.id], !Book.recentFirst(book, previous) { continue }
            unique[book.id] = book
        }
        return unique.values.sorted(by: Book.recentFirst)
    }
}

struct HardcoverLibrary: Sendable {
    let accountID: String
    let books: [Book]
    /// `nil` when series couldn't be fetched, so the previous snapshot's series stay.
    var series: [SeriesInfo]? = nil
}

struct SeriesResponse: Decodable, Sendable {
    let series: [Series]
    struct Series: Decodable, Sendable {
        let id: Int
        let name: String
        let bookSeries: [Entry]
        enum CodingKeys: String, CodingKey {
            case id, name
            case bookSeries = "book_series"
        }
    }
    struct Entry: Decodable, Sendable {
        let position: Double?
        let book: Member?
    }
    struct Member: Decodable, Sendable {
        let id: Int
        let title: String?
        let releaseYear: Int?
        let image: CoverImage?
        enum CodingKeys: String, CodingKey {
            case id, title, image
            case releaseYear = "release_year"
        }
    }
}

// Decode wire fields explicitly; normalization keeps API-specific choices out of the UI.
struct UserBook: Decodable, Sendable {
    let id: Int
    let statusID: Int?
    let lastReadDate: String?
    let rating: Double?
    let book: SourceBook
    let edition: Edition?
    let userBookReads: [ReadEvent]?
    var currentReads: [CurrentRead]? = nil
    var currentRead: CurrentRead? { currentReads?.first }
    enum CodingKeys: String, CodingKey {
        case id
        case statusID = "status_id"
        case lastReadDate = "last_read_date"
        case rating
        case book
        case edition
        case userBookReads = "user_book_reads"
        case currentReads = "current_read"
    }

}
struct SourceBook: Decodable, Sendable {
    let id: Int
    let title: String?
    let description: String?
    let releaseYear: Int?
    let pages: Int?
    let cachedContributors: [Contributor]?
    let image: CoverImage?
    let bookSeries: [SeriesMembership]?
    let cachedTags: [String: [BookTag]]?
    let rating: Double?
    let ratingsCount: Int?
    let ratingsDistribution: [RatingBucket]?
    /// The book's most-read editions that have images, for cover choice. Only the library query
    /// requests them.
    var editions: [EditionImage]? = nil
    struct EditionImage: Decodable, Sendable { let image: CoverImage? }
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case pages
        case releaseYear = "release_year"
        case cachedContributors = "cached_contributors"
        case image
        case bookSeries = "book_series"
        case cachedTags = "cached_tags"
        case rating
        case ratingsCount = "ratings_count"
        case ratingsDistribution = "ratings_distribution"
        case editions
    }

}
struct Contributor: Decodable, Sendable {
    let contribution: String?
    let author: Author?
    struct Author: Decodable, Sendable { let name: String? }
}
struct CoverImage: Codable, Sendable {
    let url: URL?
    var width: Int? = nil
    var height: Int? = nil
}
extension SourceBook {
    /// Genre tags, most tagged first, without spoiler-heavy tags or the broad Fiction and
    /// Nonfiction tags.
    var genres: [String]? {
        cachedTags?["Genre"]?
            .filter { ($0.spoilerRatio ?? 0) < 0.2 && !["Fiction", "Nonfiction"].contains($0.tag) }
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }.map(\.tag)
    }

    /// Rating buckets from half a star to five stars with nonnegative counts.
    var validRatingDistribution: [RatingBucket]? {
        ratingsDistribution?.filter { (0.5...5).contains($0.rating) && $0.count >= 0 }
    }
}

struct BookTag: Decodable, Sendable {
    let tag: String
    let count: Int?
    let spoilerRatio: Double?
}
struct Edition: Decodable, Sendable {
    let id: Int
    let pages: Int?
    var audioSeconds: Int? = nil
    let image: CoverImage?
    let readingFormat: ReadingFormat?
    var language: Language? = nil
    enum CodingKeys: String, CodingKey {
        case id
        case pages
        case audioSeconds = "audio_seconds"
        case image
        case readingFormat = "reading_format"
        case language
    }
    struct Language: Decodable, Sendable { let code2: String? }

    /// Whether the edition is in `code`, an ISO 639-1 code; editions without a recorded language
    /// count as matching.
    func isInLanguage(_ code: String) -> Bool {
        language?.code2.map { $0.lowercased() == code.lowercased() } ?? true
    }
}
struct ReadingFormat: Decodable, Sendable { let format: String? }
struct ReadEvent: Decodable, Sendable {
    let finishedAt: String?
    let edition: Edition?
    enum CodingKeys: String, CodingKey {
        case finishedAt = "finished_at"
        case edition
    }

}
/// An unfinished read, which carries reading progress.
struct CurrentRead: Decodable, Sendable {
    let startedAt: String?
    /// Percent complete, from 0 to 100.
    var progress: Double? = nil
    var progressPages: Int? = nil
    var progressSeconds: Int? = nil
    var edition: Length? = nil
    struct Length: Decodable, Sendable {
        var pages: Int? = nil
        var audioSeconds: Int? = nil
        enum CodingKeys: String, CodingKey {
            case pages
            case audioSeconds = "audio_seconds"
        }
    }
    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case progress
        case progressPages = "progress_pages"
        case progressSeconds = "progress_seconds"
        case edition
    }
}
struct SeriesMembership: Decodable, Sendable {
    let featured: Bool?
    let position: Double?
    let series: SeriesIdentity?
    struct SeriesIdentity: Decodable, Sendable { let id: Int }
}
