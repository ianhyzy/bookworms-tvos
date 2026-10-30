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
    case invalidToken, invalidAuthorizationCode
    case insufficientScope, forbidden
    case http(Int)
    case rejected, incomplete
    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "The Hardcover login is invalid or expired. Reconnect in Settings."
        case .invalidAuthorizationCode:
            "Hardcover rejected this sign-in code. Select New code to try again."
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

/// The tokens Hardcover's token endpoint returns for a sign-in or a renewal.
///
/// A personal access token has no refresh token or expiry. An OAuth login has both: the access
/// token lasts `expiresIn` seconds, and the refresh token renews it once (`HardcoverSession`).
struct HardcoverTokens: Equatable, Sendable, Decodable {
    var accessToken: String
    var refreshToken: String? = nil
    var expiresIn: Int? = nil

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    init(accessToken: String, refreshToken: String? = nil, expiresIn: Int? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }

    /// Decodes a token response. A malformed refresh token or expiry is dropped rather than
    /// failing a sign-in that already succeeded.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = (try? container.decodeIfPresent(String.self, forKey: .refreshToken))
            .flatMap { try? HardcoverToken($0).value }
        expiresIn = (try? container.decodeIfPresent(Int.self, forKey: .expiresIn)).flatMap { $0 }
    }
}

enum HardcoverDevicePollResult: Equatable, Sendable {
    case pending
    case slowDown
    case expired
    case accessDenied
    case success(HardcoverTokens)
}

actor HardcoverClient {
    static let shared = HardcoverClient()

    static let clientID = "ca996be3-0df1-4cbf-819a-e17644fbcf38"
    static let scopes = "read:me:content read:library read:catalog:data read:social read:users"

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
        let (data, http) = try await postForm(
            Self.deviceAuthorizationURL,
            ["client_id": Self.clientID, "scope": Self.scopes])
        guard http.statusCode == 200 else {
            throw HardcoverError.http(http.statusCode)
        }

        guard let auth = try? JSONDecoder().decode(HardcoverDeviceAuth.self, from: data) else {
            throw HardcoverError.rejected
        }
        return auth
    }

    func pollDeviceToken(deviceCode: String) async throws -> HardcoverDevicePollResult {
        let (data, http) = try await postForm(
            Self.tokenURL,
            [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": deviceCode,
                "client_id": Self.clientID,
            ])

        if http.statusCode == 200 { return .success(try Self.tokens(from: data)) }

        let errorResponse = try? JSONDecoder().decode(OAuthErrorReply.self, from: data)
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

    /// Spends `refreshToken` for a new access token and the refresh token that replaces it.
    ///
    /// Hardcover accepts each refresh token once and revokes the whole login if one is sent
    /// twice, so this request never retries: a response lost after Hardcover accepted the token
    /// can't be recovered by resending it. Only `HardcoverSession` calls it.
    ///
    /// Throws `HardcoverError.invalidToken` only for an HTTP 400 or 401 reply with the OAuth
    /// error `invalid_grant`, which RFC 6749 sends for a token that expired, was revoked, or was
    /// spent; the iPhone, Mac, and Android apps apply the same rule. Any other reply, such as a
    /// rate limit, a server error, another 4xx status, another OAuth error such as
    /// `invalid_client`, or a body that isn't an OAuth error, throws `HardcoverError.http(_:)` and
    /// leaves the token unspent or unknown.
    func refreshTokens(_ refreshToken: String) async throws -> HardcoverTokens {
        let refreshToken = try HardcoverToken(refreshToken).value
        // Omitting `scope` keeps the scopes the reader approved.
        let (data, http) = try await postForm(
            Self.tokenURL,
            [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": Self.clientID,
            ])
        if http.statusCode == 400 || http.statusCode == 401,
            (try? JSONDecoder().decode(OAuthErrorReply.self, from: data))?.error == "invalid_grant"
        {
            throw HardcoverError.invalidToken
        }
        guard http.statusCode == 200 else { throw HardcoverError.http(http.statusCode) }
        return try Self.tokens(from: data)
    }

    /// Asks Hardcover to end the OAuth login that `refreshToken` belongs to, which also ends its
    /// access token, so Hardcover's Authorized Apps page stops listing it. Sends one request and
    /// never retries.
    func revoke(refreshToken: String) async throws {
        let refreshToken = try HardcoverToken(refreshToken).value
        let (_, http) = try await postForm(
            Self.revocationURL,
            [
                "token": refreshToken,
                "token_type_hint": "refresh_token",
                "client_id": Self.clientID,
            ])
        guard http.statusCode == 200 else { throw HardcoverError.http(http.statusCode) }
    }

    /// The `error` code of an OAuth error reply (RFC 6749, section 5.2).
    private struct OAuthErrorReply: Decodable {
        let error: String?
    }

    /// Decodes a successful token response and checks the access token's format.
    private static func tokens(from data: Data) throws -> HardcoverTokens {
        guard var tokens = try? JSONDecoder().decode(HardcoverTokens.self, from: data) else {
            throw HardcoverError.rejected
        }
        tokens.accessToken = try HardcoverToken(tokens.accessToken).value
        return tokens
    }

    // The endpoints Hardcover's discovery document names. The token endpoint serves device-code
    // polling and token renewal.
    static let deviceAuthorizationURL = URL(string: "https://api.hardcover.app/oauth2/device")!
    static let tokenURL = URL(string: "https://api.hardcover.app/oauth2/token")!
    static let revocationURL = URL(string: "https://api.hardcover.app/oauth2/revoke")!

    /// Posts a form to an OAuth endpoint. Values are encoded with only RFC 3986 unreserved
    /// characters left literal, so a `+` or `/` in a token reaches Hardcover unchanged.
    private func postForm(_ url: URL, _ form: KeyValuePairs<String, String>) async throws
        -> (Data, HTTPURLResponse)
    {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bookworms/1.0 (read-only tvOS client)", forHTTPHeaderField: "User-Agent")
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(
            form.map { key, value in
                key + "=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
            }
            .joined(separator: "&").utf8)
        let (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else { throw HardcoverError.incomplete }
        return (data, http)
    }

    // The client owns its query documents so callers cannot submit mutations.
    private enum Query: String {
        case account = "query ShelfAccount { me { id } }"
        case library = """
            query ShelfLibrary($user: Int!, $offset: Int!, $language: String!) {
              user_books(where: {user_id: {_eq: $user}}, order_by: {id: asc}, limit: 100, offset: $offset) {
                id last_read_date rating status_id review updated_at
                book { id title description pages release_year cached_contributors cached_tags rating ratings_count ratings_distribution image { url width height }
                  book_series { featured position compilation series { id name books_count primary_books_count } }
                  editions(where: {image_id: {_is_null: false},
                      _or: [{language_id: {_is_null: true}}, {language: {code2: {_eq: $language}}}]},
                    order_by: {users_count: desc}, limit: 5) {
                    image { url width height }
                  }
                }
                edition { id pages audio_seconds edition_format image { url width height } reading_format { format } language { code2 } }
                user_book_reads(where: {finished_at: {_is_null: false}},
                  order_by: [{finished_at: desc}, {id: desc}]) {
                  finished_at edition { id pages audio_seconds edition_format image { url width height } reading_format { format } language { code2 } }
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
    ///
    /// `previous` is the newest saved snapshot the caller knows for the account. Its books keep
    /// their covers (`coverURLs(edition:book:otherEditions:editionIsInLanguage:previous:)`) only
    /// when its account is the authenticated one; a snapshot of another account is ignored.
    func fetchLibrary(token: String, previous: SourceSnapshot? = nil) async throws
        -> HardcoverLibrary
    {
        let account: Account = try await request(.account, variables: [:], token: token)
        guard account.me.count == 1, let user = account.me.first else {
            throw HardcoverError.invalidToken
        }
        let accountID = String(user.id)
        let previousBooks = Dictionary(
            (previous?.accountID == accountID ? previous?.books ?? [] : []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var rows: [UserBook] = []
        for offset in stride(from: 0, to: 10000, by: 100) {
            try Task.checkCancellation()
            let result: Library = try await request(
                .library,
                variables: ["user": user.id, "offset": offset, "language": Self.coverLanguage],
                token: token)
            rows += result.userBooks
            if result.userBooks.count < 100 {
                let books = Self.normalize(rows, previous: previousBooks)
                // Series are an enhancement: a failure keeps the library sync complete.
                let series = try? await fetchSeries(
                    Self.seriesIDs(of: books), token: token,
                    previous: previous?.accountID == accountID ? previous?.series : nil)
                return HardcoverLibrary(accountID: accountID, books: books, series: series)
            }
        }
        throw HardcoverError.incomplete
    }

    /// Every series the books belong to: each featured series and membership, so book details in
    /// both apps can list whichever series a book's label names.
    static func seriesIDs(of books: [Book]) -> Set<Int> {
        Set(
            books.flatMap { book in
                [book.seriesID].compactMap(\.self) + (book.seriesMemberships ?? []).map(\.seriesID)
            })
    }

    /// Fetches series names and main books in batches of 50. `send` paces each batch like
    /// every other request.
    ///
    /// When a batch fails after earlier ones succeeded, returns the fetched series and
    /// `previous`'s copies of the series still to fetch, so a partial download never discards
    /// series the last sync had. Throws when the first batch fails or the task is cancelled.
    private func fetchSeries(_ ids: Set<Int>, token: String, previous: [SeriesInfo]?)
        async throws -> [SeriesInfo]
    {
        var result: [SeriesInfo] = []
        let sorted = ids.sorted()
        for start in stride(from: 0, to: sorted.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(sorted[start..<min(start + 50, sorted.count)])
            do {
                let response: SeriesResponse = try await request(
                    .series, variables: ["ids": batch], token: token)
                result += response.series.map(Self.normalize)
            } catch {
                try Task.checkCancellation()
                guard !result.isEmpty else { throw error }
                let remaining = Set(sorted[start...])
                return result + (previous ?? []).filter { remaining.contains($0.id) }
            }
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

    /// The reported height, in pixels, below which a saved cover counts as low quality and may be
    /// replaced by a sharper one.
    static let lowQualityCoverHeight = 1000

    /// The preferred cover and a fallback for when it fails to download.
    ///
    /// `previous` holds the covers the book had in the account's last sync. They stay fixed, so
    /// spine designs and cached images keep matching even when the reader's edition changes,
    /// unless an upgrade applies: this sync's candidates include the previous preferred cover
    /// with a reported height below `lowQualityCoverHeight`, and the new choice reports a height
    /// of at least that. A cover without a reported height is never replaced and never replaces
    /// another. Without `previous`, or without a previous preferred cover, the new choice is used.
    static func coverURLs(
        edition: CoverImage?, book: CoverImage?, otherEditions: [CoverImage] = [],
        editionIsInLanguage: Bool = true, previous: (preferred: URL?, alternate: URL?)? = nil
    ) -> (preferred: URL?, alternate: URL?) {
        let choice = bestCoverURLs(
            edition: edition, book: book, otherEditions: otherEditions,
            editionIsInLanguage: editionIsInLanguage)
        guard let previous, let kept = previous.preferred else { return choice }
        let candidates = [edition, book].compactMap(\.self) + otherEditions
        func height(_ url: URL?) -> Int? {
            candidates.filter { url != nil && $0.url == url }.compactMap(\.height).max()
        }
        if let old = height(kept), old < lowQualityCoverHeight,
            let new = height(choice.preferred), new >= lowQualityCoverHeight
        {
            return choice
        }
        return previous
    }

    /// The best covers among this sync's candidates.
    ///
    /// Candidates are the reader's edition, the book's default image, and `otherEditions`, the
    /// book's most-read editions. The reader's edition wins unless another is clearly better; a
    /// square audiobook image, for example, loses to any portrait cover. When no candidate is a
    /// portrait-shaped cover, the largest square image of at least 300 pixels is used rather than
    /// no cover.
    private static func bestCoverURLs(
        edition: CoverImage?, book: CoverImage?, otherEditions: [CoverImage],
        editionIsInLanguage: Bool
    ) -> (preferred: URL?, alternate: URL?) {
        // A reader's edition in another language loses its preference and is used only when no
        // other image can serve as a cover.
        if !editionIsInLanguage, edition != nil {
            let choice = bestCoverURLs(
                edition: nil, book: book, otherEditions: otherEditions, editionIsInLanguage: true)
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
    /// Hardcover's `status_id` for **Ignored**, books the reader chose not to see.
    static let ignoredStatus = 6
    /// Hardcover's `status_id` for **Did Not Finish**.
    static let didNotFinishStatus = 5

    /// The `yyyy-MM-dd` day in the reader's time zone of a Hardcover timestamp, which Hardcover
    /// writes with or without fractional seconds.
    static func localDay(_ timestamp: String?) -> String? {
        guard let timestamp else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: timestamp)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: timestamp)
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return date.map(day.string(from:))
    }

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

    /// Turns a review into plain text: HTML tags and Markdown markers are removed, entities are
    /// decoded, and paragraphs stay separated by one blank line. Returns `nil` for empty text.
    ///
    /// A port of the iPhone app's `HardcoverClient.plainText(from:)`. Either app can upload the
    /// shared iCloud snapshot, so both must store the same text.
    static func plainText(from markup: String?) -> String? {
        guard var text = markup else { return nil }
        text = text.replacing(/(?i)<br\s*\/?>|<\/li>/, with: "\n")
            .replacing(/(?i)<\/(p|div|blockquote|h[1-6])>/, with: "\n\n")
            // Only tag-shaped text goes, so "I <3 it" keeps its heart.
            .replacing(/<\/?[a-zA-Z][^>]*>/, with: "")
            .replacing(/(?m)^ {0,3}(?:#{1,6} +|> ?)/, with: "")
        // Inline Markdown parsing drops emphasis and link markup and decodes HTML entities.
        if let parsed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            text = String(parsed.characters)
        }
        text = text.replacing(/[ \t]*\n[ \t]*\n\s*/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Whether a Hardcover edition format names a hardcover or a paperback, such as "Library
    /// Binding" or "Mass Market Paperback".
    ///
    /// A port of the keywords of the iPhone app's `BookBinding(editionFormat:)`. Either app can
    /// upload the shared iCloud snapshot, so both must pick the same `editionFormat`.
    static func namesPrintBinding(_ format: String) -> Bool {
        let format = format.lowercased()
        return [
            "paperback", "softcover", "soft cover", "hardcover", "hardback", "hard cover",
            "library binding",
        ]
        .contains { format.contains($0) }
    }

    /// Turns library rows into books, one per Hardcover book, leaving out books the reader marked
    /// **Ignored**. `previous` holds the account's books from its last sync, by ID, whose covers
    /// stay fixed unless an upgrade applies
    /// (`coverURLs(edition:book:otherEditions:editionIsInLanguage:previous:)`), and whose drop
    /// dates stay while the book stays on **Did Not Finish**, so a later edit doesn't move them.
    ///
    /// Each finished read's date goes into `finishedDates`, newest first, and the newest is
    /// `finished`. A book without finished reads keeps `last_read_date` as `finished` alone. Each
    /// book keeps its shelf in `statusID`.
    static func normalize(_ rows: [UserBook], previous: [Int: Book] = [:]) -> [Book] {
        var unique: [Int: Book] = [:]
        for row in rows where row.statusID != Self.ignoredStatus {
            let source = row.book
            let read = row.userBookReads?.first
            let finishes = (row.userBookReads ?? []).compactMap(\.finishedAt).sorted(by: >)
            let edition = read?.edition ?? row.edition
            // A newer audiobook or ebook read doesn't hide a print edition on the library entry.
            let editionFormat =
                [read?.edition, row.edition].compactMap { $0?.editionFormat }
                .first(where: Self.namesPrintBinding) ?? edition?.editionFormat
            let author = (source.cachedContributors ?? [])
                .filter {
                    $0.contribution == nil || $0.contribution == "Author"
                }
                .compactMap { $0.author?.name }.joined(separator: ", ")
            let covers = Self.coverURLs(
                edition: edition?.image, book: source.image,
                otherEditions: (source.editions ?? []).compactMap(\.image),
                editionIsInLanguage: edition?.isInLanguage(Self.coverLanguage) ?? true,
                previous: previous[source.id].map { ($0.detailCoverURL, $0.coverURL) })
            let membership = source.bookSeries?
                .sorted { ($0.featured ?? false) && !($1.featured ?? false) }.first
            let seriesName = membership?.series?.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let book = Book(
                id: source.id, title: source.title ?? "Untitled",
                author: author.isEmpty ? "Unknown author" : author,
                description: source.description, review: Self.plainText(from: row.review),
                coverURL: covers.alternate,
                pages: edition?.pages ?? source.pages,
                finished: finishes.first ?? row.lastReadDate,
                finishedDates: finishes.isEmpty ? nil : finishes, rating: row.rating,
                format: edition?.readingFormat?.format,
                editionFormat: editionFormat,
                seriesID: membership?.series?.id,
                seriesPosition: membership?.position,
                seriesName: seriesName?.isEmpty == false ? seriesName : nil,
                seriesMemberships: source.bookSeries?.compactMap(\.membership),
                genres: source.genres,
                communityRating: source.rating, ratingsCount: source.ratingsCount,
                ratingDistribution: source.validRatingDistribution,
                detailCoverURL: covers.preferred, sources: [.hardcover],
                isRead: row.statusID == Self.readStatus || !finishes.isEmpty
                    || row.lastReadDate != nil,
                statusID: row.statusID,
                dropped: row.statusID == Self.didNotFinishStatus
                    ? previous[source.id]?.dropped ?? Self.localDay(row.updatedAt) : nil,
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
    /// The reader's review, which may hold Markdown or HTML.
    var review: String? = nil
    let book: SourceBook
    let edition: Edition?
    let userBookReads: [ReadEvent]?
    var currentReads: [CurrentRead]? = nil
    var currentRead: CurrentRead? { currentReads?.first }
    /// When the reader last edited the entry, such as `2025-08-14T21:03:11.123456+00:00`. The
    /// app's scopes can read no shelf-change date, so this stands in for the day a book was
    /// dropped. Only the library query asks for it.
    var updatedAt: String? = nil
    enum CodingKeys: String, CodingKey {
        case id
        case statusID = "status_id"
        case lastReadDate = "last_read_date"
        case rating
        case review
        case book
        case edition
        case userBookReads = "user_book_reads"
        case currentReads = "current_read"
        case updatedAt = "updated_at"
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
    let bookSeries: [BookSeriesRow]?
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
    /// Only the reader's own library query asks for it.
    var editionFormat: String? = nil
    let image: CoverImage?
    let readingFormat: ReadingFormat?
    var language: Language? = nil
    enum CodingKeys: String, CodingKey {
        case id
        case pages
        case audioSeconds = "audio_seconds"
        case editionFormat = "edition_format"
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
/// One row of a book's Hardcover `book_series`.
struct BookSeriesRow: Decodable, Sendable {
    let featured: Bool?
    let position: Double?
    var compilation: Bool? = nil
    let series: SeriesIdentity?
    struct SeriesIdentity: Decodable, Sendable {
        let id: Int
        let name: String?
        var booksCount: Int? = nil
        var primaryBooksCount: Int? = nil
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case booksCount = "books_count"
            case primaryBooksCount = "primary_books_count"
        }
    }

    /// The row as a `Book` membership, or `nil` without a series or a series name.
    var membership: SeriesMembership? {
        guard let series,
            let name = series.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return nil }
        return SeriesMembership(
            seriesID: series.id, name: name, position: position, featured: featured ?? false,
            compilation: compilation ?? false, size: series.primaryBooksCount ?? series.booksCount)
    }
}
