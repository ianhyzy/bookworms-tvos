import Foundation

/// The owner's recent Hardcover reading, which **View example profile** shows read-only: books,
/// their series, and the companion designs and series looks they draw, all under the account ID
/// `example`, which no Hardcover account matches.
///
/// `scripts/export-example-profile.py` writes it into the Git-ignored `ExampleProfile/` folder,
/// in the shapes of the iCloud archive (`library-v1.json`) and the companion record caches
/// (`spine-designs-v1.json`, `series-looks-v1.json`). It is real reading history shipped with the
/// owner's consent, unlike the fictional `SampleLibrary`; tests load fictional folders only.
struct ExampleProfile: Sendable {
    static let accountID = "example"

    var books: [Book]
    var series: [SeriesInfo]
    var designs: [Int: SpineDesignV1]
    var looks: [SeriesLookKey: SeriesLookV1]
    var syncedAt: Date

    /// The bundled profile's folder, or `nil` in builds without its data.
    static let bundledFolder: URL? = {
        guard let folder = Bundle.main.url(forResource: "ExampleProfile", withExtension: nil),
            FileManager.default.fileExists(atPath: folder.appending(path: "library-v1.json").path)
        else { return nil }
        return folder
    }()

    /// Reads the bundled profile, or `nil` in builds without its data.
    static var bundledLoader: (@MainActor () async -> ExampleProfile?)? {
        guard let folder = bundledFolder else { return nil }
        return { await load(from: folder) }
    }

    /// Reads the profile in `folder` off the main actor. Returns `nil` when its library is
    /// missing or can't be decoded. Designs and looks that fail validation are left out, and a
    /// missing record file reads as none.
    @concurrent nonisolated static func load(from folder: URL) async -> ExampleProfile? {
        // The archive's own shape, without the Apple TV's `designs`, which the export leaves out.
        struct Archive: Decodable {
            let version: Int
            let sources: [SourceSnapshot]
        }
        func records<Value: Decodable>(_ name: String) -> [Value] {
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                let values = try? JSONDecoder().decode([String: Value].self, from: data)
            else { return [] }
            return Array(values.values)
        }
        guard let data = try? Data(contentsOf: folder.appending(path: "library-v1.json")),
            let archive = try? JSONDecoder().decode(Archive.self, from: data),
            archive.version == 1,
            let source = archive.sources.first(where: {
                $0.source == .hardcover && $0.accountID == accountID
            })
        else { return nil }
        let books = Dictionary(
            source.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var designs: [Int: SpineDesignV1] = [:]
        for design: SpineDesignV1 in records("spine-designs-v1.json") {
            if let book = books[design.bookID], design.isValid(accountID: accountID, book: book) {
                designs[book.id] = design
            }
        }
        var looks: [SeriesLookKey: SeriesLookV1] = [:]
        for look: SeriesLookV1 in records("series-looks-v1.json")
        where look.isValid(accountID: accountID, key: look.key) {
            looks[look.key] = look
        }
        return ExampleProfile(
            books: source.books, series: source.series ?? [], designs: designs, looks: looks,
            syncedAt: source.syncedAt)
    }
}
