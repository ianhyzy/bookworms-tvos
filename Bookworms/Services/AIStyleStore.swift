import Foundation

/// Stores design records in preferences and cache, with support for cloud-backed collections.
@MainActor
struct AIStyleStore {
    static let key = "savedSpineChoices.v1"
    let defaults: UserDefaults
    let cacheURL: URL

    init(
        defaults: UserDefaults = .standard,
        cacheURL: URL = URL.cachesDirectory.appending(path: "Bookworms/ai-styles.json")
    ) {
        self.defaults = defaults
        self.cacheURL = cacheURL
    }

    func load() -> [Int: AIStyleRecord] {
        let durable =
            defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Int: AIStyleRecord].self, from: $0) } ?? [:]
        let cached =
            (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONDecoder().decode([Int: AIStyleRecord].self, from: $0) } ?? [:]
        let merged = CloudLibraryArchive(designs: durable)
            .merging(CloudLibraryArchive(designs: cached)).designs
        // Repair the preferences copy from cached records when they fit the local budget.
        try? save(merged)
        return merged
    }

    // Reserve room for one response before making a paid request. Saving checks the exact size.
    func checkGenerationCapacity() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: defaults.dictionaryRepresentation(), format: .binary, options: 0)
        guard data.count < 410_000 else { throw SaveError.capacity }
    }

    func save(_ records: [Int: AIStyleRecord], cloudBacked: Bool = false) throws {
        let measurement = PerformanceDiagnostics.begin("DesignPersistence")
        defer { measurement.end() }
        let data = try JSONEncoder().encode(records)
        var preferences = defaults.dictionaryRepresentation()
        preferences[Self.key] = data
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: preferences, format: .binary, options: 0)
        // Leave headroom below tvOS's 512 KB preferences warning threshold.
        guard encoded.count < 450_000 || cloudBacked else { throw SaveError.capacity }
        if encoded.count < 450_000 { defaults.set(data, forKey: Self.key) }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    enum SaveError: LocalizedError {
        case capacity
        var errorDescription: String? {
            "Saved spine choices have reached the local storage limit. Existing choices are preserved."
        }
    }
}
