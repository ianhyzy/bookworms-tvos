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
    private var cacheGeneration: UInt64 = 0

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

        private func writeReadStatus(_ status: ReadStatus) {
            let url = cacheURL.deletingLastPathComponent()
                .appending(path: "spine-design-read-status.json")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(status).write(to: url, options: .atomic)
        }
    #endif

    init(
        database: (any SpineCloudDatabase)? = nil,
        cacheURL: URL = URL.cachesDirectory.appending(path: "Bookworms/spine-designs-v1.json")
    ) {
        suppliedDatabase = database
        self.cacheURL = cacheURL
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

    /// Reads current records in bounded batches and keeps a separate validated disk cache.
    func designs(accountID: String, books: [Book]) async throws -> [Int: SpineDesignV1] {
        // A later account selection owns the cache even if an older CloudKit read resumes.
        cacheGeneration &+= 1
        let generation = cacheGeneration
        guard !accountID.isEmpty else {
            try Task.checkCancellation()
            try saveCache([:], generation: generation)
            return [:]
        }
        let selected = Dictionary(
            books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #if DEBUG
            var status = ReadStatus(phase: "loading_cache", requestedCount: selected.count)
            writeReadStatus(status)
        #endif
        let selectedRecordNames = Set(
            selected.keys.map {
                SpineCloudIdentity.designRecordID(accountID: accountID, bookID: $0).recordName
            })
        let bookIDByRecordName = Dictionary(
            uniqueKeysWithValues: selected.keys.map {
                (SpineCloudIdentity.designRecordID(accountID: accountID, bookID: $0).recordName, $0)
            })
        var cache = loadCache().filter { selectedRecordNames.contains($0.key) }
        var accepted: [Int: SpineDesignV1] = [:]
        for book in selected.values {
            let key = SpineCloudIdentity.designRecordID(accountID: accountID, bookID: book.id)
                .recordName
            if let design = cache[key], design.isValid(accountID: accountID, book: book) {
                accepted[book.id] = design
            } else {
                cache.removeValue(forKey: key)
            }
        }
        #if DEBUG
            status.acceptedCount = accepted.count
            status.phase = "checking_cloud"
            writeReadStatus(status)
        #endif
        if selected.isEmpty {
            try checkCurrentGeneration(generation)
            try saveCache(cache, generation: generation)
            #if DEBUG
                status.phase = "complete"
                writeReadStatus(status)
            #endif
            return [:]
        }
        let database: any SpineCloudDatabase
        do {
            database = try await availableDatabase()
        } catch is CancellationError {
            #if DEBUG
                status.phase = "cancelled"
                writeReadStatus(status)
            #endif
            throw CancellationError()
        } catch {
            #if DEBUG
                status.phase = "cloud_unavailable"
                status.ckErrorCode = cloudKitErrorCode(error)
                writeReadStatus(status)
            #endif
            try checkCurrentGeneration(generation)
            try? saveCache(cache, generation: generation)
            return accepted
        }
        try checkCurrentGeneration(generation)
        let ids = selected.keys.sorted()
            .map {
                SpineCloudIdentity.designRecordID(accountID: accountID, bookID: $0)
            }
        for start in stride(from: 0, to: ids.count, by: 100) {
            try checkCurrentGeneration(generation)
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            #if DEBUG
                status.phase = "fetching_batch"
                status.batchIndex = start / 100 + 1
                writeReadStatus(status)
            #endif
            let fetched: [CKRecord.ID: Result<CKRecord, any Error>]
            do {
                fetched = try await database.records(for: batch)
            } catch is CancellationError {
                #if DEBUG
                    status.phase = "cancelled"
                    writeReadStatus(status)
                #endif
                throw CancellationError()
            } catch {
                #if DEBUG
                    status.phase = "batch_failed"
                    status.ckErrorCode = cloudKitErrorCode(error)
                    writeReadStatus(status)
                #endif
                try checkCurrentGeneration(generation)
                try? saveCache(cache, generation: generation)
                return accepted
            }
            try checkCurrentGeneration(generation)
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
                    guard record.recordType == "SpineDesignV1",
                        let payload = record["payload"] as? Data,
                        let design = try? JSONDecoder().decode(SpineDesignV1.self, from: payload),
                        let book = selected[design.bookID],
                        id
                            == SpineCloudIdentity.designRecordID(
                                accountID: accountID, bookID: design.bookID),
                        design.isValid(accountID: accountID, book: book)
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
                    accepted[design.bookID] = design
                    cache[id.recordName] = design
                }
            }
            // A later batch may fail or be cancelled after this one has valid designs.
            try saveCache(cache, generation: generation)
            #if DEBUG
                status.acceptedCount = accepted.count
                status.phase = "batch_complete"
                writeReadStatus(status)
            #endif
            if cancelled || Task.isCancelled {
                #if DEBUG
                    status.phase = "cancelled"
                    writeReadStatus(status)
                #endif
                throw CancellationError()
            }
        }
        #if DEBUG
            status.phase = "complete"
            writeReadStatus(status)
        #endif
        try checkCurrentGeneration(generation)
        return accepted
    }

    private func checkCurrentGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == cacheGeneration else { throw CancellationError() }
    }

    #if DEBUG
        private func cloudKitErrorCode(_ error: any Error) -> Int? {
            let value = error as NSError
            return value.domain == CKErrorDomain ? value.code : nil
        }
    #endif

    private func loadCache() -> [String: SpineDesignV1] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SpineDesignV1].self, from: data)) ?? [:]
    }

    private func saveCache(_ cache: [String: SpineDesignV1], generation: UInt64) throws {
        guard generation == cacheGeneration else { return }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(cache).write(to: cacheURL, options: .atomic)
    }
}
