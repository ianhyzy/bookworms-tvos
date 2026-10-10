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
    /// How the design was made when not by a model request, such as "series-reuse:12".
    var provenance: String? = nil

    func isValid(accountID: String, book: Book) -> Bool {
        guard version == 1, self.accountID == accountID, bookID == book.id,
            workItemHash == SpineCloudIdentity.workItemHash(accountID: accountID, book: book),
            coverHash.count == 64, coverHash.allSatisfy({ $0.isASCIIHexDigit }),
            !generatorVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            generatedAt.timeIntervalSince1970.isFinite,
            ["serif", "sans", "rounded", "monospaced"].contains(typeface),
            [400, 500, 600, 700].contains(weight),
            instanceWeight.map({ (100...900).contains($0) && $0.isMultiple(of: 100) }) ?? true,
            [fontFamily, fontPostScriptName, provenance].allSatisfy(Self.isShortLine),
            let background = Self.color(backgroundHex),
            let foreground = Self.color(foregroundHex),
            Self.color(accentHex) != nil
        else { return false }
        return foreground.contrast(with: background) >= 4.5
    }

    private static func isShortLine(_ value: String?) -> Bool {
        guard let value else { return true }
        return (1...80).contains(value.count) && !value.contains(where: \.isNewline)
    }

    private static func color(_ hex: String) -> StyleColor? {
        guard hex.count == 7, hex.first == "#",
            hex.dropFirst().allSatisfy({ $0.isASCIIUppercaseHexDigit })
        else { return nil }
        return try? StyleColor(hex: hex)
    }
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
}

actor SpineCloudStore {
    static let shared = SpineCloudStore()

    private let suppliedDatabase: (any SpineCloudDatabase)?
    private let cacheURL: URL
    private let coverChoiceCacheURL: URL
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

    /// Creates a store whose design cache is `cacheURL`. The cover-choice cache,
    /// `cover-choices-v1.json`, sits in the same directory.
    init(
        database: (any SpineCloudDatabase)? = nil,
        cacheURL: URL = URL.cachesDirectory.appending(path: "Bookworms/spine-designs-v1.json")
    ) {
        suppliedDatabase = database
        self.cacheURL = cacheURL
        coverChoiceCacheURL = cacheURL.deletingLastPathComponent()
            .appending(path: "cover-choices-v1.json")
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

    /// Reads the active books' companion designs. See `records(_:accountID:books:)`.
    func designs(accountID: String, books: [Book]) async throws -> [Int: SpineDesignV1] {
        try await records(.designs(cacheURL: cacheURL), accountID: accountID, books: books)
    }

    /// Reads the active books' companion cover choices. See `records(_:accountID:books:)`.
    func coverChoices(accountID: String, books: [Book]) async throws -> [Int: CoverChoiceV1] {
        try await records(
            .coverChoices(cacheURL: coverChoiceCacheURL), accountID: accountID, books: books)
    }

    /// Reads one record per book in bounded batches and keeps a separate validated disk cache.
    ///
    /// Returns cached records when CloudKit is unavailable. A missing or invalid current record
    /// evicts the cached one, and an empty `accountID` clears the cache.
    private func records<Value: Codable & Sendable>(
        _ kind: CompanionRecordKind<Value>, accountID: String, books: [Book]
    ) async throws -> [Int: Value] {
        let generation = (cacheGenerations[kind.recordType] ?? 0) &+ 1
        cacheGenerations[kind.recordType] = generation
        guard !accountID.isEmpty else {
            try Task.checkCancellation()
            try saveCache([String: Value](), to: kind, generation: generation)
            return [:]
        }
        let selected = Dictionary(
            books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #if DEBUG
            var status = ReadStatus(phase: "loading_cache", requestedCount: selected.count)
            writeReadStatus(status, name: kind.statusName)
        #endif
        let selectedRecordNames = Set(
            selected.keys.map {
                kind.recordID(accountID, $0).recordName
            })
        let bookIDByRecordName = Dictionary(
            uniqueKeysWithValues: selected.keys.map {
                (kind.recordID(accountID, $0).recordName, $0)
            })
        var cache = loadCache(kind).filter { selectedRecordNames.contains($0.key) }
        var accepted: [Int: Value] = [:]
        for book in selected.values {
            let key = kind.recordID(accountID, book.id).recordName
            if let value = cache[key], kind.isValid(value, accountID, book) {
                accepted[book.id] = value
            } else {
                cache.removeValue(forKey: key)
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
            return [:]
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
            return accepted
        }
        try checkCurrentGeneration(generation, of: kind)
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
                return accepted
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
                    continue
                }
                switch result {
                case .failure(let error as CKError) where error.code == .unknownItem:
                    #if DEBUG
                        status.unknownCount += 1
                    #endif
                    if let bookID = bookIDByRecordName[id.recordName] {
                        accepted.removeValue(forKey: bookID)
                    }
                    cache.removeValue(forKey: id.recordName)
                    continue
                case .failure(let error):
                    if error is CancellationError { cancelled = true }
                    #if DEBUG
                        status.failedCount += 1
                        status.ckErrorCode = status.ckErrorCode ?? cloudKitErrorCode(error)
                    #endif
                    continue
                case .success(let record):
                    guard record.recordType == kind.recordType,
                        let payload = record["payload"] as? Data,
                        let value = try? JSONDecoder().decode(Value.self, from: payload),
                        let book = selected[kind.bookID(value)],
                        id == kind.recordID(accountID, book.id),
                        kind.isValid(value, accountID, book)
                    else {
                        #if DEBUG
                            status.invalidCount += 1
                        #endif
                        if let bookID = bookIDByRecordName[id.recordName] {
                            accepted.removeValue(forKey: bookID)
                        }
                        cache.removeValue(forKey: id.recordName)
                        continue
                    }
                    accepted[book.id] = value
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
        return accepted
    }

    private func checkCurrentGeneration<Value>(
        _ generation: UInt64, of kind: CompanionRecordKind<Value>
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

    private func loadCache<Value>(_ kind: CompanionRecordKind<Value>) -> [String: Value] {
        guard let data = try? Data(contentsOf: kind.cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Value].self, from: data)) ?? [:]
    }

    private func saveCache<Value>(
        _ cache: [String: Value], to kind: CompanionRecordKind<Value>, generation: UInt64
    ) throws {
        guard generation == cacheGenerations[kind.recordType] else { return }
        try FileManager.default.createDirectory(
            at: kind.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(cache).write(to: kind.cacheURL, options: .atomic)
    }
}

/// One companion record type: its CloudKit names, local cache, and validation. Each book has at
/// most one record, named from the account and book IDs.
private struct CompanionRecordKind<Value: Codable & Sendable> {
    let recordType: String
    let cacheURL: URL
    /// The DEBUG read-status file name, beside the cache.
    let statusName: String
    let recordID: (_ accountID: String, _ bookID: Int) -> CKRecord.ID
    let bookID: (Value) -> Int
    let isValid: (Value, _ accountID: String, Book) -> Bool
}

extension CompanionRecordKind where Value == SpineDesignV1 {
    static func designs(cacheURL: URL) -> Self {
        Self(
            recordType: "SpineDesignV1", cacheURL: cacheURL,
            statusName: "spine-design-read-status.json",
            recordID: SpineCloudIdentity.designRecordID, bookID: \.bookID,
            isValid: { $0.isValid(accountID: $1, book: $2) })
    }
}

extension CompanionRecordKind where Value == CoverChoiceV1 {
    static func coverChoices(cacheURL: URL) -> Self {
        Self(
            recordType: "CoverChoiceV1", cacheURL: cacheURL,
            statusName: "cover-choice-read-status.json",
            recordID: SpineCloudIdentity.coverChoiceRecordID, bookID: \.bookID,
            isValid: { $0.isValid(accountID: $1, book: $2) })
    }
}
