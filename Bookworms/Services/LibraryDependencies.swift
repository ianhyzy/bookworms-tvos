import Foundation

/// Supplies external boundaries while library workflows, decoding, and local persistence stay real.
@MainActor
struct LibraryDependencies {
    var defaults: UserDefaults
    var sourceStore: SourceLibraryStore
    var styleStore: AIStyleStore
    var legacySnapshotURL: URL
    var diagnosticsDirectory: URL
    var allowLaunchOverrides = true
    var readCredential: (String) -> String? = { CredentialStore.read(account: $0) }
    var saveCredential: (String, String) throws -> Void = {
        try CredentialStore.save($0, account: $1)
    }
    var removeCredential: (String) throws -> Void = { try CredentialStore.remove(account: $0) }
    /// Fetches the library for a token. The snapshot is the newest one saved for the account the
    /// caller expects, whose covers stay fixed when the token's account matches it.
    var fetchHardcover: @MainActor (String, SourceSnapshot?) async throws -> HardcoverLibrary = {
        try await HardcoverClient.shared.fetchLibrary(token: $0, previous: $1)
    }
    var validateHardcover: @MainActor (String) async throws -> String = {
        try await HardcoverClient.shared.validateToken($0)
    }
    /// Spends a refresh token. Only `HardcoverSession` calls it.
    var refreshHardcoverToken: @MainActor (String) async throws -> HardcoverTokens = {
        try await HardcoverClient.shared.refreshTokens($0)
    }
    /// Ends the OAuth login a refresh token belongs to, at Hardcover.
    var revokeHardcoverToken: @MainActor (String) async throws -> Void = {
        try await HardcoverClient.shared.revoke(refreshToken: $0)
    }
    var requestHardcoverDeviceAuth: @MainActor () async throws -> HardcoverDeviceAuth = {
        try await HardcoverClient.shared.requestDeviceAuth()
    }
    var pollHardcoverDeviceToken: @MainActor (String) async throws -> HardcoverDevicePollResult = {
        try await HardcoverClient.shared.pollDeviceToken(deviceCode: $0)
    }
    var fetchCWA: @MainActor (CWAConfiguration, String) async throws -> [Book] = {
        try await CWAClient.shared.fetchBooks(configuration: $0, password: $1)
    }
    var syncCloud: @MainActor (CloudLibraryArchive) async throws -> CloudLibraryArchive = {
        try await CloudLibraryStore.shared.sync($0)
    }
    /// Reads the stored archive without saving, for the Hardcover account check.
    var readCloudArchive: @MainActor () async throws -> CloudLibraryArchive? = {
        try await CloudLibraryStore.shared.read()
    }
    /// The signed-in iCloud user's record name, or `nil` when it can't be read.
    var cloudUserRecordName: @MainActor () async -> String? = {
        await CloudLibraryStore.shared.userRecordName()
    }
    var readSpineWorklist: @MainActor () async throws -> SpineWorklistV1? = {
        try await SpineCloudStore.shared.worklist()
    }
    /// Publishes a worklist unless the stored one names an account that the merges don't
    /// absorb into the new one's (`SpineCloudStore.publish(_:merges:)`).
    var publishSpineWorklist: @MainActor (SpineWorklistV1, [String: String]) async throws -> Void =
        { try await SpineCloudStore.shared.publish($0, merges: $1) }
    /// Copies an old account's companion records into the current account for `books`
    /// (`SpineCloudStore.copyRecords(from:into:books:)`).
    var copyAccountRecords: @MainActor (String, String, [Book]) async throws -> Void = {
        try await SpineCloudStore.shared.copyRecords(from: $0, into: $1, books: $2)
    }
    var fetchSpineDesigns:
        @MainActor (String, [Book]) async throws -> (
            values: [Int: SpineDesignV1], isComplete: Bool
        ) = { try await SpineCloudStore.shared.designs(accountID: $0, books: $1) }
    var fetchCoverChoices:
        @MainActor (String, [Book]) async throws -> (
            values: [Int: CoverChoiceV1], isComplete: Bool
        ) = { try await SpineCloudStore.shared.coverChoices(accountID: $0, books: $1) }
    var fetchSeriesLinks:
        @MainActor (String, [Book]) async throws -> (
            values: [Int: SeriesLinkV1], isComplete: Bool
        ) = { try await SpineCloudStore.shared.seriesLinks(accountID: $0, books: $1) }
    var fetchSeriesLooks:
        @MainActor (String, [SeriesLookKey]) async throws -> (
            values: [SeriesLookKey: SeriesLookV1], isComplete: Bool
        ) = { try await SpineCloudStore.shared.seriesLooks(accountID: $0, keys: $1) }
    /// Reads an account's companion records from the disk caches, without CloudKit
    /// (`SpineCloudStore.cachedRecords(accountID:books:)`).
    var readCachedCompanionRecords: @MainActor (String, [Book]) async -> CachedCompanionRecords = {
        await SpineCloudStore.shared.cachedRecords(accountID: $0, books: $1)
    }
    var createSeriesLook: @MainActor (SeriesLookV1) async throws -> SeriesLookV1 = {
        try await SpineCloudStore.shared.createSeriesLook($0)
    }
    /// Saves a book's series choice for an account and book ID, or deletes it when the merged
    /// choice changes nothing (`SpineCloudStore.setSeriesLink(_:accountID:bookID:)`).
    var saveSeriesLink: @MainActor (SeriesLinkV1, String, Int) async throws -> Void = {
        try await SpineCloudStore.shared.setSeriesLink($0, accountID: $1, bookID: $2)
    }
    /// Reads the bundled example profile, or `nil` in builds without it, which then don't offer
    /// **View example profile**.
    var exampleProfile: (@MainActor () async -> ExampleProfile?)? = ExampleProfile.bundledLoader
    var now: () -> Date = { Date() }
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Returns once Book Wall has waited long enough for launch's companion record read
    /// (`LibraryModel.hasReadCompanionRecords`). Separate from `sleep`, whose calls tests count.
    var companionReadLimit: @MainActor () async -> Void = {
        try? await Task.sleep(for: .seconds(10))
    }
    var readTopShelf: () -> [TopShelfBook] = { TopShelfSnapshot.read() }
    var writeTopShelf: @Sendable ([TopShelfBook]) throws -> Void = {
        try TopShelfSnapshot.write($0)
    }

    init(
        defaults: UserDefaults = .standard,
        storageDirectory: URL = URL.cachesDirectory.appending(path: "Bookworms")
    ) {
        self.defaults = defaults
        sourceStore = SourceLibraryStore(url: storageDirectory.appending(path: "sources.json"))
        styleStore = AIStyleStore(
            defaults: defaults, cacheURL: storageDirectory.appending(path: "ai-styles.json"))
        legacySnapshotURL = storageDirectory.appending(path: "library.json")
        diagnosticsDirectory = storageDirectory
    }
}
