import CloudKit
import CryptoKit
import Foundation

/// A complete Hardcover account's book IDs, derived from a successfully synced source snapshot.
struct SpineWorklistV1: Codable, Equatable, Sendable {
    let version: Int
    let accountID: String
    let syncedAt: Date
    let bookIDs: [Int]

    init(accountID: String, syncedAt: Date, bookIDs: [Int]) {
        version = 1
        self.accountID = accountID
        self.syncedAt = syncedAt
        self.bookIDs = Array(Set(bookIDs)).sorted()
    }

    var isValid: Bool {
        version == 1 && !accountID.isEmpty && syncedAt.timeIntervalSince1970.isFinite
            && bookIDs.allSatisfy { $0 > 0 } && bookIDs == Array(Set(bookIDs)).sorted()
    }
}

/// A portable spine design from a companion app. Book Wall draws it in place of the book's
/// cover-derived spine while `BookPresentation.showsCompanionSpines` is on.
struct SpineDesignV1: Codable, Equatable, Sendable {
    let version: Int
    let accountID: String
    let bookID: Int
    let workItemHash: String
    let coverHash: String
    let generatorVersion: String
    let generatedAt: Date
    let backgroundHex: String
    let foregroundHex: String
    let accentHex: String
    let typeface: String
    let weight: Int
    let uppercase: Bool
    /// The Google Fonts family, such as "EB Garamond". `typeface` and `weight` are the fallback.
    var fontFamily: String? = nil
    /// The PostScript name of the `fontFamily` instance closest to `weight`.
    var fontPostScriptName: String? = nil
    /// The weight of the `fontPostScriptName` instance (100...900), which can differ from
    /// `weight` when the family lacks that weight.
    var instanceWeight: Int? = nil
    /// How the design was made, in space-separated tokens such as "model:apple/on-device" or
    /// "series-reuse:12". The model token names the companion's model tier; Private Cloud
    /// Compute's designs record none. The Apple TV reads it only to name the model in
    /// **Settings → Spines** (`madeBy`); it draws a valid design whatever its tier.
    var provenance: String? = nil

    func isValid(accountID: String, book: Book) -> Bool {
        version == 1 && self.accountID == accountID && bookID == book.id
            && workItemHash == SpineCloudIdentity.workItemHash(accountID: accountID, book: book)
            && coverHash.count == 64 && coverHash.allSatisfy({ $0.isASCIIHexDigit })
            && !generatorVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && generatedAt.timeIntervalSince1970.isFinite && isValidLook
    }

    /// Whether the colors and type can be drawn: known typeface and weights, short font names,
    /// `#RRGGBB` colors, and text contrast of at least 4.5:1. Series looks follow the same rules.
    var isValidLook: Bool {
        guard ["serif", "sans", "rounded", "monospaced"].contains(typeface),
            [400, 500, 600, 700].contains(weight),
            instanceWeight.map({ (100...900).contains($0) && $0.isMultiple(of: 100) }) ?? true,
            [fontFamily, fontPostScriptName, provenance].allSatisfy(Self.isShortLine),
            let background = Self.color(backgroundHex),
            let foreground = Self.color(foregroundHex),
            Self.color(accentHex) != nil
        else { return false }
        return foreground.contrast(with: background) >= 4.5
    }

    /// Whether `value` is absent or one line of 1 to 80 characters.
    static func isShortLine(_ value: String?) -> Bool {
        guard let value else { return true }
        return (1...80).contains(value.count) && !value.contains(where: \.isNewline)
    }

    private static func color(_ hex: String) -> StyleColor? {
        guard hex.count == 7, hex.first == "#",
            hex.dropFirst().allSatisfy({ $0.isASCIIUppercaseHexDigit })
        else { return nil }
        return try? StyleColor(hex: hex)
    }

    /// The model that made the design and its tier, best 3, named as the iPhone and Mac name it
    /// (`SpineDesignV1.madeBy` and `tier` in the iOS app), from the design alone, so every device
    /// credits the same model: "Google Gemini (gemini-3.8-flash)" for
    /// "model:google/gemini-3.8-flash", or "Private Cloud Compute", "Apple on-device model", or
    /// "Default styling".
    ///
    /// The `model:` token decides, else the generator: any `ios-pcc-` version is Private Cloud
    /// Compute, the retired Mac companion's `mac-foundation-models-` versions are Apple's
    /// on-device model, also with a `model:local` token, and any other generator, such as Book
    /// Wall's `tvos-local-v1` series looks, is default styling.
    var madeBy: (name: String, tier: Int) {
        let isCompanion = generatorVersion.hasPrefix("mac-foundation-models-")
        let token =
            modelToken.map { isCompanion && $0 == "model:local" ? "model:apple/on-device" : $0 }
            ?? (generatorVersion.hasPrefix("ios-pcc-")
                ? nil : isCompanion ? "model:apple/on-device" : "model:local")
        switch token {
        case nil: return ("Private Cloud Compute", 3)
        case "model:apple/on-device": return ("Apple on-device model", 1)
        case "model:local": return ("Default styling", 0)
        case let token?:
            let model = token.dropFirst("model:".count)
            let parts = model.split(separator: "/", maxSplits: 1)
            let providers = [
                "anthropic": "Anthropic", "openAI": "OpenAI", "google": "Google Gemini",
                "custom": "OpenAI-compatible endpoint",
            ]
            guard parts.count == 2, let provider = providers[String(parts[0])] else {
                return (String(model), 2)
            }
            return ("\(provider) (\(parts[1]))", 2)
        }
    }
}

/// Who made the designs the library's books draw, as **Settings → Spines** lists them.
struct SpineDesignMakers: Equatable {
    struct Maker: Equatable {
        /// The model, as `SpineDesignV1.madeBy` names it.
        let name: String
        let books: Int
    }

    /// The models, best tier first, then the most books, as the iPhone and Mac's **Saved
    /// designs** list them.
    var makers: [Maker] = []
    /// How many books draw no design, so Book Wall draws them in its own local look.
    var undesigned = 0

    /// Counts the design each of `books` draws: its series look from `looks`, else, with a
    /// series source in `sources`, the source's design from `designs`, else its own
    /// (`LibraryModel.seriesDrawing`). A book whose source has no design counts as undesigned
    /// even with a design of its own, because Book Wall draws the source's local look on it. It
    /// counts before preparation's glyph checks, which can give a book its own design instead.
    init(
        books: [Book], designs: [Int: SpineDesignV1], sources: [Int: Book],
        looks: [Int: SpineDesignV1]
    ) {
        var counts: [String: (tier: Int, books: Int)] = [:]
        for book in books {
            guard let design = looks[book.id] ?? designs[sources[book.id]?.id ?? book.id] else {
                undesigned += 1
                continue
            }
            let maker = design.madeBy
            counts[maker.name, default: (maker.tier, 0)].books += 1
        }
        makers =
            counts.sorted {
                ($0.value.tier, $0.value.books, $1.key) > ($1.value.tier, $1.value.books, $0.key)
            }
            .map { Maker(name: $0.key, books: $0.value.books) }
    }

    init() {}
}

/// The reader's choice of cover for one book in a companion app. Views try it before the book's
/// default covers. Choosing the default cover deletes the record.
struct CoverChoiceV1: Codable, Equatable, Sendable {
    let version: Int
    let accountID: String
    let bookID: Int
    let coverURL: URL
    /// The Hardcover edition the cover belongs to, when it belongs to one.
    var editionID: Int? = nil
    let chosenAt: Date

    func isValid(accountID: String, book: Book) -> Bool {
        version == 1 && self.accountID == accountID && accountID.count <= 512 && bookID > 0
            && bookID == book.id && Self.allows(coverURL)
            && (editionID.map { $0 > 0 } ?? true) && chosenAt.timeIntervalSince1970.isFinite
    }

    /// Accepts only HTTPS URLs on public host names, as the iPhone companion's `CoverURLPolicy`
    /// does, so a synced record cannot point the TV at a local network address.
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
            url.port == nil, url.fragment == nil, let host = url.host?.lowercased(),
            host.contains("."), !host.hasSuffix("."), !host.hasSuffix(".local"),
            !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"), host != "localhost",
            !host.contains(":"), !host.split(separator: ".").allSatisfy({ Int($0) != nil })
        else { return false }
        return true
    }
}

/// The look a group of series books draws (`SeriesLookKey`), synced so every device draws the
/// same one. The first device to save a group's look decides it; creating one never replaces
/// another (`SpineCloudStore.createSeriesLook(_:)`). A companion app may later remake a look
/// that Apple's on-device model or local defaults made (`provenance`, or the `localOrigin`) and
/// the reader never edited; Book Wall draws the remade look on its next read.
struct SeriesLookV1: Codable, Equatable, Sendable {
    var version = 1
    let accountID: String
    let seriesID: Int
    let group: String
    /// The book whose design or cover the look was made from.
    let sourceBookID: Int
    /// What made the look: the iPhone or Mac generator version of the design it copies, or
    /// "tvos-local-v1" for Book Wall's cover-sampled look.
    let origin: String
    let createdAt: Date
    /// When a companion app last edited the look's colors or type. A look copied from a design
    /// whose colors or font the reader chose counts as edited at `createdAt`, so no companion
    /// upgrade replaces them.
    var editedAt: Date? = nil
    let backgroundHex: String
    let foregroundHex: String
    let accentHex: String
    let typeface: String
    let weight: Int
    let uppercase: Bool
    var fontFamily: String? = nil
    var fontPostScriptName: String? = nil
    var instanceWeight: Int? = nil
    /// The model token of the design the look copies (`SpineDesignV1.modelToken`), which tells
    /// a companion app the model tier that made it, followed by `font:system` when that design
    /// stands in its system typeface for a font that couldn't download, so a companion upgrades
    /// the look once the font downloads. A look copies no other `provenance` token. Private Cloud
    /// Compute's looks and Book Wall's cover-sampled looks record none; the latter's `origin`
    /// marks them.
    var provenance: String? = nil
    /// When a companion app last made the look again from a new design, keeping `createdAt`. The
    /// Apple TV never remakes a look, so it leaves this out of the looks it creates.
    var remadeAt: Date? = nil

    /// The origin of a look made from Book Wall's cover-sampled style.
    static let localOrigin = "tvos-local-v1"

    var key: SeriesLookKey { SeriesLookKey(seriesID: seriesID, group: group) }

    func isValid(accountID: String, key: SeriesLookKey) -> Bool {
        version == 1 && self.accountID == accountID && !accountID.isEmpty
            && accountID.count <= 512 && self.key == key && seriesID > 0 && group.count <= 200
            && sourceBookID > 0 && createdAt.timeIntervalSince1970.isFinite
            && (editedAt?.timeIntervalSince1970.isFinite ?? true)
            && SpineDesignV1.isShortLine(origin) && SpineDesignV1.isShortLine(provenance)
            && !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && design(bookID: sourceBookID, workItemHash: "").isValidLook
    }

    /// The look as `book`'s design, so Book Wall draws it like a companion design and
    /// **Settings → Spines** credits its model (`SpineDesignV1.madeBy`) from the look's
    /// `provenance`. The cover hash is a placeholder; Book Wall never reads it.
    func design(for book: Book) -> SpineDesignV1 {
        design(
            bookID: book.id,
            workItemHash: SpineCloudIdentity.workItemHash(accountID: accountID, book: book))
    }

    private func design(bookID: Int, workItemHash: String) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: bookID, workItemHash: workItemHash,
            coverHash: String(repeating: "0", count: 64), generatorVersion: origin,
            generatedAt: editedAt ?? createdAt, backgroundHex: backgroundHex,
            foregroundHex: foregroundHex, accentHex: accentHex, typeface: typeface,
            weight: weight, uppercase: uppercase, fontFamily: fontFamily,
            fontPostScriptName: fontPostScriptName, instanceWeight: instanceWeight,
            provenance: provenance)
    }
}

extension SeriesLookV1 {
    /// A look for `key` copied from `design`, a group member's saved design, with the design's
    /// tier tokens as its `provenance`. A design the reader recolored or set in another font
    /// (`hasReaderEdits`) gives the look the reader's colors and font, so the look counts as
    /// edited at `createdAt`, as the iPhone's look does, and no upgrade replaces them.
    init(key: SeriesLookKey, design: SpineDesignV1, createdAt: Date) {
        let awaitsFont = design.provenance?.split(separator: " ").contains("font:system") == true
        let tokens = [design.modelToken, awaitsFont ? "font:system" : nil].compactMap(\.self)
        self.init(
            accountID: design.accountID, seriesID: key.seriesID, group: key.group,
            sourceBookID: design.bookID, origin: design.generatorVersion, createdAt: createdAt,
            editedAt: design.hasReaderEdits ? createdAt : nil,
            backgroundHex: design.backgroundHex, foregroundHex: design.foregroundHex,
            accentHex: design.accentHex, typeface: design.typeface, weight: design.weight,
            uppercase: design.uppercase, fontFamily: design.fontFamily,
            fontPostScriptName: design.fontPostScriptName, instanceWeight: design.instanceWeight,
            provenance: tokens.isEmpty ? nil : tokens.joined(separator: " "))
    }

    /// A look for `key` from Book Wall's cover-sampled `style` of `book`, the group's
    /// best-ranked member. The genre face becomes the look's PostScript name, with its closest
    /// portable typeface; only Bebas Neue is a Google Fonts family the iPhone can download.
    init(
        key: SeriesLookKey, localStyle style: BookWallLocalSpine.Style, book: Book,
        accountID: String, createdAt: Date
    ) {
        let face = style.typography.fontName
        self.init(
            accountID: accountID, seriesID: key.seriesID, group: key.group, sourceBookID: book.id,
            origin: Self.localOrigin, createdAt: createdAt, backgroundHex: style.background.hex,
            foregroundHex: style.foreground.hex, accentHex: style.foreground.hex,
            typeface: face.map(BookWallLocalSpine.typeface(ofGenreFace:)) ?? "sans", weight: 700,
            uppercase: style.typography.uppercase,
            fontFamily: face == SpineFontPolicy.impactReplacement ? "Bebas Neue" : nil,
            fontPostScriptName: face)
    }
}

/// The reader's series choice for one book: a series to draw its look from, no series, or its own
/// look instead of its series'. The iPhone and Mac app saves every kind; picking a series in this
/// app's book details saves the first (`SpineCloudStore.setSeriesLink(_:accountID:bookID:)`).
/// Choosing the default deletes the record.
struct SeriesLinkV1: Codable, Equatable, Sendable {
    var version = 1
    let accountID: String
    let bookID: Int
    /// The series whose look the book draws, in place of its shortest series.
    var linkedSeriesID: Int? = nil
    /// Whether the book draws as if it belonged to no series.
    var standsAlone = false
    /// Whether the book draws its own design instead of its series' look.
    var ownLook = false
    let chosenAt: Date

    func isValid(accountID: String, book: Book) -> Bool {
        isValid(accountID: accountID, bookID: book.id)
    }

    func isValid(accountID: String, bookID: Int) -> Bool {
        version == 1 && self.accountID == accountID && !accountID.isEmpty
            && accountID.count <= 512 && self.bookID > 0 && self.bookID == bookID
            && (linkedSeriesID.map { $0 > 0 } ?? true) && chosenAt.timeIntervalSince1970.isFinite
    }
}

extension Character {
    fileprivate var isASCIIHexDigit: Bool {
        isASCIIUppercaseHexDigit || ("0"..."9").contains(self) || ("a"..."f").contains(self)
    }
    fileprivate var isASCIIUppercaseHexDigit: Bool {
        ("0"..."9").contains(self) || ("A"..."F").contains(self)
    }
}

enum SpineCloudIdentity {
    static let worklistRecordID = CKRecord.ID(recordName: "spine-worklist-v1")

    static func designRecordID(accountID: String, bookID: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "spine-design-v1-" + sha256("\(accountID):\(bookID)"))
    }

    static func coverChoiceRecordID(accountID: String, bookID: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "cover-choice-v1-" + sha256("\(accountID):\(bookID)"))
    }

    static func seriesLinkRecordID(accountID: String, bookID: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "series-link-v1-" + sha256("\(accountID):\(bookID)"))
    }

    static func seriesLookRecordID(accountID: String, key: SeriesLookKey) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "series-look-v1-" + sha256("\(accountID):\(key.seriesID):\(key.group)"))
    }

    static func workItemHash(accountID: String, book: Book) -> String {
        sha256(
            [
                accountID, String(book.id), book.title, book.author,
                book.detailCoverURL?.absoluteString ?? "", book.coverURL?.absoluteString ?? "",
            ]
            .joined(separator: "\n"))
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Makes the CloudKit boundary replaceable for deterministic record and conflict checks.
protocol SpineCloudDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func record(for id: CKRecord.ID) async throws -> CKRecord
    func records(for ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    func save(_ record: CKRecord) async throws
    /// Deletes the record, and succeeds when it doesn't exist.
    func delete(_ id: CKRecord.ID) async throws
}

private struct AppleSpineCloudDatabase: SpineCloudDatabase {
    private var database: CKDatabase {
        CKContainer(identifier: "iCloud.gay.ian.Bookworms").privateCloudDatabase
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await CKContainer(identifier: "iCloud.gay.ian.Bookworms").accountStatus()
    }

    func record(for id: CKRecord.ID) async throws -> CKRecord {
        try await database.record(for: id)
    }

    func records(for ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    {
        try await database.records(for: ids, desiredKeys: ["payload"])
    }

    func save(_ record: CKRecord) async throws {
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let saved = result.saveResults[record.recordID] else {
            throw CloudStorageError.incomplete
        }
        _ = try saved.get()
    }

    func delete(_ id: CKRecord.ID) async throws {
        do {
            _ = try await database.deleteRecord(withID: id)
        } catch let error as CKError where error.code == .unknownItem {}
    }
}

actor SpineCloudStore {
    static let shared = SpineCloudStore()

    private let suppliedDatabase: (any SpineCloudDatabase)?
    private let cacheURL: URL
    private let coverChoiceCacheURL: URL
    private let seriesLinkCacheURL: URL
    private let seriesLookCacheURL: URL
    /// The latest read per record type. A later account selection owns that type's cache even
    /// if an older CloudKit read resumes.
    private var cacheGenerations: [String: UInt64] = [:]

    #if DEBUG
        private struct ReadStatus: Encodable {
            var phase: String
            let requestedCount: Int
            var batchIndex = 0
            var returnedCount = 0
            var acceptedCount = 0
            var unknownCount = 0
            var failedCount = 0
            var missingCount = 0
            var invalidCount = 0
            var ckErrorCode: Int?
        }

        private func writeReadStatus(_ status: ReadStatus, name: String) {
            let url = cacheURL.deletingLastPathComponent().appending(path: name)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(status).write(to: url, options: .atomic)
        }
    #endif

    /// Creates a store whose design cache is `cacheURL`. The cover-choice, series-link, and
    /// series-look caches, `cover-choices-v1.json`, `series-links-v1.json`, and
    /// `series-looks-v1.json`, sit in the same directory.
    init(
        database: (any SpineCloudDatabase)? = nil,
        cacheURL: URL = URL.cachesDirectory.appending(path: "Bookworms/spine-designs-v1.json")
    ) {
        suppliedDatabase = database
        self.cacheURL = cacheURL
        let directory = cacheURL.deletingLastPathComponent()
        coverChoiceCacheURL = directory.appending(path: "cover-choices-v1.json")
        seriesLinkCacheURL = directory.appending(path: "series-links-v1.json")
        seriesLookCacheURL = directory.appending(path: "series-looks-v1.json")
    }

    private func database() throws -> any SpineCloudDatabase {
        if let suppliedDatabase { return suppliedDatabase }
        #if targetEnvironment(simulator)
            throw CloudStorageError.simulator
        #else
            return AppleSpineCloudDatabase()
        #endif
    }

    private func availableDatabase() async throws -> any SpineCloudDatabase {
        let database = try database()
        switch try await database.accountStatus() {
        case .available: return database
        case .noAccount: throw CloudStorageError.unavailable
        case .restricted: throw CloudStorageError.restricted
        default: throw CloudStorageError.temporarilyUnavailable
        }
    }

    func worklist() async throws -> SpineWorklistV1? {
        let database = try await availableDatabase()
        let record: CKRecord
        do {
            record = try await database.record(for: SpineCloudIdentity.worklistRecordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard record.recordType == "SpineWorklistV1",
            let payload = record["payload"] as? Data,
            let value = try? JSONDecoder().decode(SpineWorklistV1.self, from: payload),
            value.isValid
        else { throw CloudStorageError.incomplete }
        return value
    }

    func publish(_ worklist: SpineWorklistV1) async throws {
        guard worklist.isValid else { throw CloudStorageError.incomplete }
        let database = try await availableDatabase()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(worklist)
        for _ in 0..<3 {
            let record: CKRecord
            do {
                record = try await database.record(for: SpineCloudIdentity.worklistRecordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(
                    recordType: "SpineWorklistV1", recordID: SpineCloudIdentity.worklistRecordID)
            }
            try Task.checkCancellation()
            guard record.recordType == "SpineWorklistV1" else {
                throw CloudStorageError.incomplete
            }
            if let saved = record["payload"] as? Data {
                guard let current = try? JSONDecoder().decode(SpineWorklistV1.self, from: saved),
                    current.isValid
                else { throw CloudStorageError.incomplete }
                if current.accountID == worklist.accountID,
                    current.syncedAt > worklist.syncedAt
                {
                    return
                }
                if saved == payload { return }
            }
            record["payload"] = payload as NSData
            do {
                try await database.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw CloudStorageError.conflict
    }

    /// Reads the active books' companion designs, and whether CloudKit answered for every book.
    /// See `records(_:accountID:subjects:)`.
    func designs(accountID: String, books: [Book]) async throws
        -> (values: [Int: SpineDesignV1], isComplete: Bool)
    {
        try await records(
            .designs(cacheURL: cacheURL), accountID: accountID, subjects: Self.byID(books))
    }

    /// Reads the active books' companion cover choices, and whether CloudKit answered for every
    /// book. See `records(_:accountID:subjects:)`.
    func coverChoices(accountID: String, books: [Book]) async throws
        -> (values: [Int: CoverChoiceV1], isComplete: Bool)
    {
        try await records(
            .coverChoices(cacheURL: coverChoiceCacheURL), accountID: accountID,
            subjects: Self.byID(books))
    }

    /// Reads the active books' companion series links, and whether CloudKit answered for every
    /// book. See `records(_:accountID:subjects:)`.
    func seriesLinks(accountID: String, books: [Book]) async throws
        -> (values: [Int: SeriesLinkV1], isComplete: Bool)
    {
        try await records(
            .seriesLinks(cacheURL: seriesLinkCacheURL), accountID: accountID,
            subjects: Self.byID(books))
    }

    /// Reads the series looks of the active books' look groups. See
    /// `records(_:accountID:subjects:)`.
    func seriesLooks(accountID: String, keys: [SeriesLookKey]) async throws
        -> [SeriesLookKey: SeriesLookV1]
    {
        try await records(
            .seriesLooks(cacheURL: seriesLookCacheURL), accountID: accountID,
            subjects: Dictionary(keys.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        )
        .values
    }

    /// Saves `look` as its group's look unless another device saved one first, and returns the
    /// look that decides the group: `look`, or the existing one. Never replaces a saved look.
    ///
    /// Throws when CloudKit is unavailable, the save fails, or the existing look is invalid.
    func createSeriesLook(_ look: SeriesLookV1) async throws -> SeriesLookV1 {
        guard look.isValid(accountID: look.accountID, key: look.key) else {
            throw CloudStorageError.incomplete
        }
        let database = try await availableDatabase()
        let id = SpineCloudIdentity.seriesLookRecordID(accountID: look.accountID, key: look.key)
        let record = CKRecord(recordType: "SeriesLookV1", recordID: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        record["payload"] = try encoder.encode(look) as NSData
        var saved = look
        do {
            // A new record without a change tag fails when the record already exists.
            try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            let existing = try await database.record(for: id)
            guard existing.recordType == "SeriesLookV1",
                let payload = existing["payload"] as? Data,
                let value = try? JSONDecoder().decode(SeriesLookV1.self, from: payload),
                value.isValid(accountID: look.accountID, key: look.key)
            else { throw CloudStorageError.incomplete }
            saved = value
        }
        let kind = CompanionRecordKind.seriesLooks(cacheURL: seriesLookCacheURL)
        var cache = loadCache(kind)
        cache[id.recordName] = saved
        try? saveCache(cache, to: kind, generation: cacheGenerations[kind.recordType, default: 0])
        return saved
    }

    /// Saves `link` as its book's series choice, or deletes the book's `SeriesLinkV1` record when
    /// `link` is `nil`, as the iPhone and Mac do, then caches the result for offline reads. The
    /// last writer wins: a save replaces the record another device saved.
    ///
    /// Throws when CloudKit is unavailable, the save fails, or the record holds another type.
    func setSeriesLink(_ link: SeriesLinkV1?, accountID: String, bookID: Int) async throws {
        guard
            link?.isValid(accountID: accountID, bookID: bookID)
                ?? (!accountID.isEmpty && bookID > 0)
        else {
            throw CloudStorageError.incomplete
        }
        let database = try await availableDatabase()
        let id = SpineCloudIdentity.seriesLinkRecordID(accountID: accountID, bookID: bookID)
        if let link {
            let payload = try JSONEncoder().encode(link)
            var saved = false
            for _ in 0..<3 where !saved {
                let record: CKRecord
                do {
                    record = try await database.record(for: id)
                } catch let error as CKError where error.code == .unknownItem {
                    record = CKRecord(recordType: "SeriesLinkV1", recordID: id)
                }
                guard record.recordType == "SeriesLinkV1" else {
                    throw CloudStorageError.incomplete
                }
                record["payload"] = payload as NSData
                do {
                    try await database.save(record)
                    saved = true
                } catch let error as CKError where error.code == .serverRecordChanged {}
            }
            guard saved else { throw CloudStorageError.conflict }
        } else {
            try await database.delete(id)
        }
        let kind = CompanionRecordKind.seriesLinks(cacheURL: seriesLinkCacheURL)
        var cache = loadCache(kind)
        cache[id.recordName] = link
        try? saveCache(cache, to: kind, generation: cacheGenerations[kind.recordType, default: 0])
    }

    private static func byID(_ books: [Book]) -> [Int: Book] {
        Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads one record per subject, such as a book, in bounded batches and keeps a separate
    /// validated disk cache.
    ///
    /// Returns cached records when CloudKit is unavailable, a batch fails, or a record fails for
    /// a reason other than not existing; `isComplete` is then `false`, so callers that make
    /// lasting decisions, such as creating a series look, can wait for a full read. A missing or
    /// invalid current record evicts the cached one, and an empty `accountID` clears the cache.
    private func records<Key: Comparable & Hashable, Subject, Value: Codable & Sendable>(
        _ kind: CompanionRecordKind<Key, Subject, Value>, accountID: String,
        subjects selected: [Key: Subject]
    ) async throws -> (values: [Key: Value], isComplete: Bool) {
        let generation = (cacheGenerations[kind.recordType] ?? 0) &+ 1
        cacheGenerations[kind.recordType] = generation
        guard !accountID.isEmpty else {
            try Task.checkCancellation()
            try saveCache([String: Value](), to: kind, generation: generation)
            return ([:], true)
        }
        #if DEBUG
            var status = ReadStatus(phase: "loading_cache", requestedCount: selected.count)
            writeReadStatus(status, name: kind.statusName)
        #endif
        let selectedRecordNames = Set(
            selected.keys.map {
                kind.recordID(accountID, $0).recordName
            })
        let keyByRecordName = Dictionary(
            uniqueKeysWithValues: selected.keys.map {
                (kind.recordID(accountID, $0).recordName, $0)
            })
        var cache = loadCache(kind).filter { selectedRecordNames.contains($0.key) }
        var accepted: [Key: Value] = [:]
        for (key, subject) in selected {
            let name = kind.recordID(accountID, key).recordName
            if let value = cache[name], kind.isValid(value, accountID, subject) {
                accepted[key] = value
            } else {
                cache.removeValue(forKey: name)
            }
        }
        #if DEBUG
            status.acceptedCount = accepted.count
            status.phase = "checking_cloud"
            writeReadStatus(status, name: kind.statusName)
        #endif
        if selected.isEmpty {
            try checkCurrentGeneration(generation, of: kind)
            try saveCache(cache, to: kind, generation: generation)
            #if DEBUG
                status.phase = "complete"
                writeReadStatus(status, name: kind.statusName)
            #endif
            return ([:], true)
        }
        let database: any SpineCloudDatabase
        do {
            database = try await availableDatabase()
        } catch is CancellationError {
            #if DEBUG
                status.phase = "cancelled"
                writeReadStatus(status, name: kind.statusName)
            #endif
            throw CancellationError()
        } catch {
            #if DEBUG
                status.phase = "cloud_unavailable"
                status.ckErrorCode = cloudKitErrorCode(error)
                writeReadStatus(status, name: kind.statusName)
            #endif
            try checkCurrentGeneration(generation, of: kind)
            try? saveCache(cache, to: kind, generation: generation)
            return (accepted, false)
        }
        try checkCurrentGeneration(generation, of: kind)
        var isComplete = true
        let ids = selected.keys.sorted()
            .map { kind.recordID(accountID, $0) }
        for start in stride(from: 0, to: ids.count, by: 100) {
            try checkCurrentGeneration(generation, of: kind)
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            #if DEBUG
                status.phase = "fetching_batch"
                status.batchIndex = start / 100 + 1
                writeReadStatus(status, name: kind.statusName)
            #endif
            let fetched: [CKRecord.ID: Result<CKRecord, any Error>]
            do {
                fetched = try await database.records(for: batch)
            } catch is CancellationError {
                #if DEBUG
                    status.phase = "cancelled"
                    writeReadStatus(status, name: kind.statusName)
                #endif
                throw CancellationError()
            } catch {
                #if DEBUG
                    status.phase = "batch_failed"
                    status.ckErrorCode = cloudKitErrorCode(error)
                    writeReadStatus(status, name: kind.statusName)
                #endif
                try checkCurrentGeneration(generation, of: kind)
                try? saveCache(cache, to: kind, generation: generation)
                return (accepted, false)
            }
            try checkCurrentGeneration(generation, of: kind)
            #if DEBUG
                status.returnedCount += fetched.count
            #endif
            var cancelled = false
            for id in batch {
                guard let result = fetched[id] else {
                    #if DEBUG
                        status.missingCount += 1
                    #endif
                    isComplete = false
                    continue
                }
                switch result {
                case .failure(let error as CKError) where error.code == .unknownItem:
                    #if DEBUG
                        status.unknownCount += 1
                    #endif
                    if let key = keyByRecordName[id.recordName] {
                        accepted.removeValue(forKey: key)
                    }
                    cache.removeValue(forKey: id.recordName)
                    continue
                case .failure(let error):
                    if error is CancellationError { cancelled = true }
                    isComplete = false
                    #if DEBUG
                        status.failedCount += 1
                        status.ckErrorCode = status.ckErrorCode ?? cloudKitErrorCode(error)
                    #endif
                    continue
                case .success(let record):
                    guard record.recordType == kind.recordType,
                        let payload = record["payload"] as? Data,
                        let value = try? JSONDecoder().decode(Value.self, from: payload),
                        let subject = selected[kind.key(value)],
                        id == kind.recordID(accountID, kind.key(value)),
                        kind.isValid(value, accountID, subject)
                    else {
                        #if DEBUG
                            status.invalidCount += 1
                        #endif
                        if let key = keyByRecordName[id.recordName] {
                            accepted.removeValue(forKey: key)
                        }
                        cache.removeValue(forKey: id.recordName)
                        continue
                    }
                    accepted[kind.key(value)] = value
                    cache[id.recordName] = value
                }
            }
            // A later batch may fail or be cancelled after this one has valid designs.
            try saveCache(cache, to: kind, generation: generation)
            #if DEBUG
                status.acceptedCount = accepted.count
                status.phase = "batch_complete"
                writeReadStatus(status, name: kind.statusName)
            #endif
            if cancelled || Task.isCancelled {
                #if DEBUG
                    status.phase = "cancelled"
                    writeReadStatus(status, name: kind.statusName)
                #endif
                throw CancellationError()
            }
        }
        #if DEBUG
            status.phase = "complete"
            writeReadStatus(status, name: kind.statusName)
        #endif
        try checkCurrentGeneration(generation, of: kind)
        return (accepted, isComplete)
    }

    private func checkCurrentGeneration<Key, Subject, Value>(
        _ generation: UInt64, of kind: CompanionRecordKind<Key, Subject, Value>
    ) throws {
        try Task.checkCancellation()
        guard generation == cacheGenerations[kind.recordType] else { throw CancellationError() }
    }

    #if DEBUG
        private func cloudKitErrorCode(_ error: any Error) -> Int? {
            let value = error as NSError
            return value.domain == CKErrorDomain ? value.code : nil
        }
    #endif

    private func loadCache<Key, Subject, Value>(_ kind: CompanionRecordKind<Key, Subject, Value>)
        -> [String: Value]
    {
        guard let data = try? Data(contentsOf: kind.cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Value].self, from: data)) ?? [:]
    }

    private func saveCache<Key, Subject, Value>(
        _ cache: [String: Value], to kind: CompanionRecordKind<Key, Subject, Value>,
        generation: UInt64
    ) throws {
        guard generation == cacheGenerations[kind.recordType, default: 0] else { return }
        try FileManager.default.createDirectory(
            at: kind.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(cache).write(to: kind.cacheURL, options: .atomic)
    }
}

/// One companion record type: its CloudKit names, local cache, and validation. Each subject,
/// such as a book, has at most one record, named from the account and the subject's key.
private struct CompanionRecordKind<Key, Subject, Value: Codable & Sendable> {
    let recordType: String
    let cacheURL: URL
    /// The DEBUG read-status file name, beside the cache.
    let statusName: String
    let recordID: (_ accountID: String, Key) -> CKRecord.ID
    let key: (Value) -> Key
    let isValid: (Value, _ accountID: String, Subject) -> Bool
}

extension CompanionRecordKind where Key == Int, Subject == Book, Value == SpineDesignV1 {
    static func designs(cacheURL: URL) -> Self {
        Self(
            recordType: "SpineDesignV1", cacheURL: cacheURL,
            statusName: "spine-design-read-status.json",
            recordID: SpineCloudIdentity.designRecordID, key: \.bookID,
            isValid: { $0.isValid(accountID: $1, book: $2) })
    }
}

extension CompanionRecordKind where Key == Int, Subject == Book, Value == CoverChoiceV1 {
    static func coverChoices(cacheURL: URL) -> Self {
        Self(
            recordType: "CoverChoiceV1", cacheURL: cacheURL,
            statusName: "cover-choice-read-status.json",
            recordID: SpineCloudIdentity.coverChoiceRecordID, key: \.bookID,
            isValid: { $0.isValid(accountID: $1, book: $2) })
    }
}

extension CompanionRecordKind where Key == Int, Subject == Book, Value == SeriesLinkV1 {
    static func seriesLinks(cacheURL: URL) -> Self {
        Self(
            recordType: "SeriesLinkV1", cacheURL: cacheURL,
            statusName: "series-link-read-status.json",
            recordID: SpineCloudIdentity.seriesLinkRecordID, key: \.bookID,
            isValid: { $0.isValid(accountID: $1, book: $2) })
    }
}

extension CompanionRecordKind
where Key == SeriesLookKey, Subject == SeriesLookKey, Value == SeriesLookV1 {
    static func seriesLooks(cacheURL: URL) -> Self {
        Self(
            recordType: "SeriesLookV1", cacheURL: cacheURL,
            statusName: "series-look-read-status.json",
            recordID: SpineCloudIdentity.seriesLookRecordID, key: \.key,
            isValid: { $0.isValid(accountID: $1, key: $2) })
    }
}
