import Foundation

/// Keeps the saved Hardcover login in Keychain and renews its OAuth access token.
///
/// Hardcover access tokens last a week, and each refresh token works once: a renewal returns a
/// new refresh token, and sending a spent one revokes the whole login. This type is the only
/// code that spends a refresh token, and it runs one renewal at a time, so library sync, social
/// sync, and reviews share each renewal. The Top Shelf extension reads only its snapshot.
///
/// Every method that reads Keychain runs at a sync or credential boundary, never on focus or
/// remote input. A Keychain read that fails returns no token; nothing here deletes a login
/// because of it.
@MainActor
final class HardcoverSession {
    static let accessAccount = "hardcover-token"
    static let refreshAccount = "hardcover-refresh-token"
    /// When the access token is due for renewal, in user defaults; it isn't secret.
    static let renewalKey = "hardcoverTokenRenewal"
    /// The longest time before expiry that a token is renewed, so a daily sync replaces a
    /// week-long token before it lapses. A token that lasts less than twice this is renewed
    /// halfway through its lifetime instead, so each renewal outlasts the requests that follow.
    static let renewalMargin: TimeInterval = 86_400

    private let dependencies: LibraryDependencies
    private var renewal: Task<String?, any Error>?
    /// Changes with every saved or removed login, so a renewal that finishes afterward can't
    /// overwrite it.
    private var generation = 0
    /// Renewed tokens that Keychain refused to save. They replace the saved ones for this launch,
    /// so the spent refresh token is never sent again, and each later boundary retries the save.
    private var unsaved: (tokens: HardcoverTokens, issued: Date)?
    /// A refresh token Hardcover rejected during this launch. It isn't sent again, and the access
    /// token it would have replaced stays in use until Hardcover rejects that too.
    private var rejectedRefreshToken: String?

    init(dependencies: LibraryDependencies) { self.dependencies = dependencies }

    /// The saved access token. Reads Keychain.
    func storedAccessToken() -> String? {
        unsaved?.tokens.accessToken ?? dependencies.readCredential(Self.accessAccount)
    }

    /// Saves a new login in place of the previous one, including its refresh token, if any.
    func save(_ tokens: HardcoverTokens) throws {
        generation += 1
        unsaved = nil
        try write(tokens, issued: dependencies.now())
    }

    /// Removes the saved login and revokes it at Hardcover, so Hardcover's Authorized Apps page
    /// stops listing the Apple TV. Reads Keychain.
    ///
    /// The revocation is one request in its own task, and a failure is ignored: the login is
    /// removed from the Apple TV either way, and the reader can still revoke it on Hardcover. A
    /// personal access token has no refresh token and isn't revoked, since the reader may use it
    /// elsewhere.
    func remove() {
        let refreshToken =
            unsaved?.tokens.refreshToken ?? dependencies.readCredential(Self.refreshAccount)
        generation += 1
        unsaved = nil
        dependencies.removeCredential(Self.refreshAccount)
        dependencies.removeCredential(Self.accessAccount)
        dependencies.defaults.removeObject(forKey: Self.renewalKey)
        if let refreshToken {
            Task { try? await self.dependencies.revokeHardcoverToken(refreshToken) }
        }
    }

    /// The access token for a sync, renewed first when it's due (`renewalDate(of:issued:)`).
    ///
    /// A renewal that fails, even one Hardcover rejects, returns the saved token, which may still
    /// work until it expires. A request that Hardcover rejects renews with `renew(rejected:)`,
    /// which reports a rejected refresh token.
    func accessToken() async -> String? {
        guard let token = storedAccessToken() else { return nil }
        return await renewedIfExpiring(token)
    }

    /// `token`, the saved access token, or its replacement when it's due for renewal. Fails over
    /// to `token` like `accessToken()`.
    func renewedIfExpiring(_ token: String) async -> String {
        if let unsaved, (try? write(unsaved.tokens, issued: unsaved.issued)) != nil {
            self.unsaved = nil
        }
        // The saved date belongs to the spent tokens while Keychain refuses their replacements.
        let renewal =
            if let unsaved {
                Self.renewalDate(of: unsaved.tokens, issued: unsaved.issued)
            } else {
                dependencies.defaults.object(forKey: Self.renewalKey) as? Date
            }
        guard let renewal, dependencies.now() >= renewal else { return token }
        return (try? await renew(rejected: token)) ?? token
    }

    /// An access token to use in place of `rejected`: the saved one when another sync already
    /// replaced it, else a renewed one. Returns `nil` when no login or refresh token is saved,
    /// and throws `HardcoverError.invalidToken` when Hardcover rejects the refresh token, now or
    /// earlier in this launch.
    ///
    /// Concurrent callers share one renewal. The request runs in its own task, so cancelling a
    /// sync never abandons tokens Hardcover already rotated.
    func renew(rejected: String) async throws -> String? {
        if let renewal { return try await renewal.value }
        let task = Task { try await self.performRenewal(rejected: rejected) }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    private func performRenewal(rejected: String) async throws -> String? {
        guard let current = storedAccessToken() else { return nil }
        guard current == rejected,
            let refreshToken = unsaved?.tokens.refreshToken
                ?? dependencies.readCredential(Self.refreshAccount)
        else { return current }
        guard refreshToken != rejectedRefreshToken else { throw HardcoverError.invalidToken }
        let generation = generation
        let issued = dependencies.now()
        var tokens: HardcoverTokens
        do {
            tokens = try await dependencies.refreshHardcoverToken(refreshToken)
        } catch HardcoverError.invalidToken {
            rejectedRefreshToken = refreshToken
            throw HardcoverError.invalidToken
        }
        // RFC 6749 keeps the old refresh token when a response omits a replacement.
        tokens.refreshToken = tokens.refreshToken ?? refreshToken
        guard generation == self.generation else { return storedAccessToken() }
        do {
            try write(tokens, issued: issued)
            unsaved = nil
        } catch {
            unsaved = (tokens, issued)
        }
        return tokens.accessToken
    }

    /// When tokens issued at `issued` are due for renewal: `renewalMargin` before they expire, or
    /// halfway through a shorter lifetime. Returns `nil` for a login that can't be renewed or
    /// doesn't say when it expires.
    static func renewalDate(of tokens: HardcoverTokens, issued: Date) -> Date? {
        guard tokens.refreshToken != nil, let seconds = tokens.expiresIn, seconds > 0 else {
            return nil
        }
        let lifetime = TimeInterval(seconds)
        return issued.addingTimeInterval(lifetime - min(renewalMargin, lifetime / 2))
    }

    /// Saves the refresh token first, since it's the part that can't be recovered.
    private func write(_ tokens: HardcoverTokens, issued: Date) throws {
        if let refreshToken = tokens.refreshToken {
            try dependencies.saveCredential(refreshToken, Self.refreshAccount)
        } else {
            dependencies.removeCredential(Self.refreshAccount)
        }
        try dependencies.saveCredential(tokens.accessToken, Self.accessAccount)
        if let renewal = Self.renewalDate(of: tokens, issued: issued) {
            dependencies.defaults.set(renewal, forKey: Self.renewalKey)
        } else {
            dependencies.defaults.removeObject(forKey: Self.renewalKey)
        }
    }
}
