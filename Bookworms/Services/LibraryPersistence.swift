import Foundation

/// Serializes local snapshot writes away from the UI actor and discards superseded requests.
actor LibraryPersistence {
    private let sourceStore: SourceLibraryStore
    private let styleCacheURL: URL
    private let writeTopShelf: @Sendable ([TopShelfBook]) throws -> Void
    private var sourceRevision = 0
    private var styleRevision = 0
    private var topShelfRevision = 0
    private var newestTopShelfRequest = 0
    private var publishedTopShelf: [TopShelfBook] = []

    init(
        sourceStore: SourceLibraryStore, styleCacheURL: URL,
        writeTopShelf: @escaping @Sendable ([TopShelfBook]) throws -> Void
    ) {
        self.sourceStore = sourceStore
        self.styleCacheURL = styleCacheURL
        self.writeTopShelf = writeTopShelf
    }

    func saveSources(_ snapshots: [SourceSnapshot], revision: Int) throws {
        guard revision >= sourceRevision else { return }
        sourceRevision = revision
        try sourceStore.save(snapshots)
    }

    /// Removes local Hardcover snapshots without deleting other providers or saved designs.
    func resetHardcoverSnapshot(legacyURL: URL, revision: Int) throws -> [SourceSnapshot] {
        let retained = sourceStore.load().filter { $0.source != .hardcover }
        try saveSources(retained, revision: revision)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try FileManager.default.removeItem(at: legacyURL)
        }
        return retained
    }

    /// Returns encoded designs so preference updates can stay on their owning actor.
    func saveStyleCache(_ records: [Int: AIStyleRecord], revision: Int) throws -> Data? {
        guard revision >= styleRevision else { return nil }
        styleRevision = revision
        let data = try JSONEncoder().encode(records)
        try? FileManager.default.createDirectory(
            at: styleCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: styleCacheURL, options: .atomic)
        return data
    }

    /// Records a Top Shelf render before it writes any poster.
    func beginTopShelf(revision: Int) {
        newestTopShelfRequest = max(newestTopShelfRequest, revision)
    }

    /// Publishes `books` unless a newer snapshot was published. Renders run concurrently, so
    /// only the newest requested render removes unused posters: an older one could otherwise
    /// delete posters that a newer render already wrote. A late render that loses to a newer
    /// snapshot removes its own leftovers when no render is still pending.
    func publishTopShelf(_ books: [TopShelfBook], revision: Int) {
        guard revision >= topShelfRevision else {
            if topShelfRevision == newestTopShelfRequest {
                TopShelfPoster.removeUnused(keeping: publishedTopShelf)
            }
            return
        }
        topShelfRevision = revision
        publishedTopShelf = books
        try? writeTopShelf(books)
        if revision == newestTopShelfRequest { TopShelfPoster.removeUnused(keeping: books) }
    }
}
