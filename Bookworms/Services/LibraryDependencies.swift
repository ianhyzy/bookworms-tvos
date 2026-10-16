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
    var removeCredential: (String) -> Void = { CredentialStore.remove(account: $0) }
    /// Fetches the library for a token. The snapshot is the newest one saved for the account the
    /// caller expects, whose covers stay fixed when the token's account matches it.
    var fetchHardcover: @MainActor (String, SourceSnapshot?) async throws -> HardcoverLibrary = {
        try await HardcoverClient.shared.fetchLibrary(token: $0, previous: $1)
    }
    var validateHardcover: @MainActor (String) async throws -> String = {
        try await HardcoverClient.shared.validateToken($0)
    }
    var exchangeHardcoverCode: @MainActor (String) async throws -> String = {
        try await HardcoverClient.shared.exchangeAuthorizationCode($0)
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
    var readSpineWorklist: @MainActor () async throws -> SpineWorklistV1? = {
        try await SpineCloudStore.shared.worklist()
    }
    var publishSpineWorklist: @MainActor (SpineWorklistV1) async throws -> Void = {
        try await SpineCloudStore.shared.publish($0)
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
        @MainActor (String, [SeriesLookKey]) async throws -> [SeriesLookKey: SeriesLookV1] = {
            try await SpineCloudStore.shared.seriesLooks(accountID: $0, keys: $1)
        }
    var createSeriesLook: @MainActor (SeriesLookV1) async throws -> SeriesLookV1 = {
        try await SpineCloudStore.shared.createSeriesLook($0)
    }
    var now: () -> Date = { Date() }
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
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
