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
        let durableData = defaults.data(forKey: Self.key)
        let cachedData = try? Data(contentsOf: cacheURL)
        let decodedDurable =
            durableData.flatMap { try? JSONDecoder().decode([Int: AIStyleRecord].self, from: $0) }
        let decodedCached =
            cachedData.flatMap { try? JSONDecoder().decode([Int: AIStyleRecord].self, from: $0) }
        let durable = decodedDurable ?? [:]
        let cached = decodedCached ?? [:]
        let merged = CloudLibraryArchive(designs: durable)
            .merging(CloudLibraryArchive(designs: cached)).designs
        // Matching copies need no repair; writing the cache on every launch blocks rendering.
        if durableData != cachedData || (durableData != nil && decodedDurable == nil) {
            try? save(merged)
        }
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
        try savePreferences(data, cloudBacked: cloudBacked)
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    func savePreferences(_ data: Data, cloudBacked: Bool) throws {
        var preferences = defaults.dictionaryRepresentation()
        preferences[Self.key] = data
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: preferences, format: .binary, options: 0)
        // Leave headroom below tvOS's 512 KB preferences warning threshold.
        guard encoded.count < 450_000 || cloudBacked else { throw SaveError.capacity }
        if encoded.count < 450_000 { defaults.set(data, forKey: Self.key) }
    }

    enum SaveError: LocalizedError {
        case capacity
        var errorDescription: String? {
            "Saved spine choices have reached the local storage limit. Existing choices are preserved."
        }
    }
}
