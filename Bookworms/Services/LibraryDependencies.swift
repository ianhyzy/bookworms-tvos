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
    var fetchHardcover: @MainActor (String) async throws -> [Book] = {
        try await HardcoverClient.shared.fetchBooks(token: $0)
    }
    var validateHardcover: @MainActor (String) async throws -> Void = {
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
    var now: () -> Date = { Date() }
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var readTopShelf: () -> [TopShelfBook] = { TopShelfSnapshot.read() }
    var writeTopShelf: ([TopShelfBook]) throws -> Void = { try TopShelfSnapshot.write($0) }

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
