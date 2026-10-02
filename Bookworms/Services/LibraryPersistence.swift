import Foundation

/// Serializes local snapshot writes away from the UI actor and discards superseded requests.
actor LibraryPersistence {
    private let sourceStore: SourceLibraryStore
    private let styleCacheURL: URL
    private let writeTopShelf: @Sendable ([TopShelfBook]) throws -> Void
    private var sourceRevision = 0
    private var styleRevision = 0
    private var topShelfRevision = 0

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

    func publishTopShelf(_ books: [TopShelfBook], revision: Int) {
        guard revision >= topShelfRevision else { return }
        topShelfRevision = revision
        try? writeTopShelf(books)
    }
}
