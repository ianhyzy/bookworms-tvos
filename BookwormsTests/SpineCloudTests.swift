import CloudKit
import XCTest

@testable import Bookworms

final class SpineCloudTests: XCTestCase {
    private func book(id: Int = 7) -> Book {
        Book(
            id: id, title: "Dune", author: "Frank Herbert",
            coverURL: URL(string: "https://example.test/catalog.jpg"),
            detailCoverURL: URL(string: "https://example.test/edition.jpg"))
    }

    private func design(
        for book: Book, accountID: String = "42", typeface: String = "serif",
        foregroundHex: String = "#FFFFFF"
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: book.id,
            workItemHash: SpineCloudIdentity.workItemHash(accountID: accountID, book: book),
            coverHash: String(repeating: "a", count: 64), generatorVersion: "local-1",
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            backgroundHex: "#123456", foregroundHex: foregroundHex,
            accentHex: "#ABCDEF", typeface: typeface, weight: 600, uppercase: false)
    }

    func testRecordIdentityAndMetadataHashMatchMacContract() {
        let book = book()
        XCTAssertEqual(
            SpineCloudIdentity.designRecordID(accountID: "42", bookID: 7).recordName,
            "spine-design-v1-755dac3729029e2e2976249c4e03b160c699ef71f296c346e22183dc23503c33")
        XCTAssertEqual(
            SpineCloudIdentity.workItemHash(accountID: "42", book: book),
            "386ce6995b77bb7377a199ec8f0b506e04fb5d0c14b995b6e8287b5bd65ff6ee")
    }

    func testDesignRejectsWrongAccountMetadataAndUnreadableStyle() {
        let book = book()
        XCTAssertTrue(design(for: book).isValid(accountID: "42", book: book))
        XCTAssertFalse(design(for: book).isValid(accountID: "other", book: book))
        XCTAssertFalse(
            design(for: book, typeface: "external-font").isValid(accountID: "42", book: book))
        XCTAssertFalse(
            design(for: book, foregroundHex: "#112233")
                .isValid(
                    accountID: "42", book: book))
        var changed = book
        changed.detailCoverURL = URL(string: "https://example.test/replaced.jpg")
        XCTAssertFalse(design(for: book).isValid(accountID: "42", book: changed))
    }

    func testValidatedDesignPersistsForOfflineReadAndPrunesOtherAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let database = FakeSpineDatabase()
        try await database.put(design(for: book))
        let online = SpineCloudStore(database: database, cacheURL: cacheURL)
        let fetched = try await online.designs(accountID: "42", books: [book])
        XCTAssertEqual(fetched[7]?.typeface, "serif")

        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let retained = try await offline.designs(accountID: "42", books: [book])
        XCTAssertEqual(retained[7]?.coverHash, String(repeating: "a", count: 64))
        let other = try await offline.designs(accountID: "other", books: [book])
        XCTAssertTrue(other.isEmpty)
        let cache = try JSONDecoder()
            .decode(
                [String: SpineDesignV1].self, from: Data(contentsOf: cacheURL))
        XCTAssertTrue(cache.isEmpty)
    }

    func testCompanionFontFieldsSurviveCacheAndBoundValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        var styled = design(for: book)
        styled.fontFamily = "EB Garamond"
        styled.fontPostScriptName = "EBGaramond-SemiBold"
        styled.instanceWeight = 600
        styled.provenance = "series-reuse:12"
        let database = FakeSpineDatabase()
        try await database.put(styled)
        _ = try await SpineCloudStore(database: database, cacheURL: cacheURL)
            .designs(accountID: "42", books: [book])
        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let retained = try await offline.designs(accountID: "42", books: [book])
        XCTAssertEqual(retained[7], styled)

        var unbounded = styled
        unbounded.instanceWeight = 650
        XCTAssertFalse(unbounded.isValid(accountID: "42", book: book))
        unbounded = styled
        unbounded.fontFamily = String(repeating: "A", count: 81)
        XCTAssertFalse(unbounded.isValid(accountID: "42", book: book))
        unbounded = styled
        unbounded.provenance = "two\nlines"
        XCTAssertFalse(unbounded.isValid(accountID: "42", book: book))
    }

    func testEmptyAccountSelectionPrunesPriorAccountCacheWhileOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let database = FakeSpineDatabase()
        try await database.put(design(for: book))
        let online = SpineCloudStore(database: database, cacheURL: cacheURL)
        let populated = try await online.designs(accountID: "42", books: [book])
        XCTAssertEqual(populated.count, 1)

        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let pruned = try await offline.designs(accountID: "other", books: [])
        XCTAssertTrue(pruned.isEmpty)
        let cache = try JSONDecoder()
            .decode(
                [String: SpineDesignV1].self, from: Data(contentsOf: cacheURL))
        XCTAssertTrue(cache.isEmpty)
    }

    func testInvalidCachedMetadataIsPrunedWithoutCloudAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let database = FakeSpineDatabase()
        try await database.put(design(for: book))
        let online = SpineCloudStore(database: database, cacheURL: cacheURL)
        let populated = try await online.designs(accountID: "42", books: [book])
        XCTAssertEqual(populated.count, 1)

        var changed = book
        changed.detailCoverURL = URL(string: "https://example.test/replaced.jpg")
        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let pruned = try await offline.designs(accountID: "42", books: [changed])
        XCTAssertTrue(pruned.isEmpty)
        let cache = try JSONDecoder()
            .decode(
                [String: SpineDesignV1].self, from: Data(contentsOf: cacheURL))
        XCTAssertTrue(cache.isEmpty)
    }

    func testOlderCloudReadCannotRestoreCacheAfterHardcoverIsCleared() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let database = FakeSpineDatabase()
        try await database.put(design(for: book))
        await database.holdNextBatch()
        let store = SpineCloudStore(database: database, cacheURL: cacheURL)
        let olderRead = Task { try await store.designs(accountID: "42", books: [book]) }
        await database.waitForHeldBatch()

        _ = try await store.designs(accountID: "", books: [])
        await database.releaseHeldBatch()
        do {
            _ = try await olderRead.value
            XCTFail("An older account read must not return after the cache is cleared")
        } catch is CancellationError {
            // The newer selection supersedes the suspended read.
        }

        let cache = try JSONDecoder()
            .decode(
                [String: SpineDesignV1].self, from: Data(contentsOf: cacheURL))
        XCTAssertTrue(cache.isEmpty)
    }

    func testMalformedCurrentRecordEvictsPreviouslyCachedDesign() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let database = FakeSpineDatabase()
        let store = SpineCloudStore(database: database, cacheURL: cacheURL)
        try await database.put(design(for: book))
        let initial = try await store.designs(accountID: "42", books: [book])
        XCTAssertEqual(initial.count, 1)

        try await database.put(design(for: book, typeface: "external-font"))
        let refreshed = try await store.designs(accountID: "42", books: [book])
        XCTAssertTrue(refreshed.isEmpty)
        let cache = try JSONDecoder()
            .decode(
                [String: SpineDesignV1].self, from: Data(contentsOf: cacheURL))
        XCTAssertTrue(cache.isEmpty)
    }

    func testLatestSavedDesignReplacesCachedDesignFromAnotherGenerator() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let database = FakeSpineDatabase()
        let store = SpineCloudStore(database: database, cacheURL: cacheURL)
        try await database.put(design(for: book))
        _ = try await store.designs(accountID: "42", books: [book])

        let base = design(for: book, typeface: "sans", foregroundHex: "#000000")
        let latest = SpineDesignV1(
            version: 1, accountID: "42", bookID: book.id, workItemHash: base.workItemHash,
            coverHash: base.coverHash, generatorVersion: "ios-pcc-v1",
            generatedAt: base.generatedAt.addingTimeInterval(60), backgroundHex: "#40FFC0",
            foregroundHex: "#000000", accentHex: "#123456", typeface: "sans", weight: 700,
            uppercase: true, fontFamily: "Inter", fontPostScriptName: "Inter-Bold",
            instanceWeight: 700)
        try await database.put(latest)
        let refreshed = try await store.designs(accountID: "42", books: [book])
        XCTAssertEqual(refreshed[7], latest)
        let cache = try JSONDecoder()
            .decode([String: SpineDesignV1].self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(Array(cache.values), [latest])
    }

    func testIndividualFailureDoesNotHideLaterValidDesign() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = book(id: 1)
        let second = book(id: 2)
        let database = FakeSpineDatabase()
        await database.failRecord(for: first, with: CKError(.permissionFailure))
        try await database.put(design(for: second))

        let fetched = try await SpineCloudStore(database: database, cacheURL: cacheURL)
            .designs(accountID: "42", books: [first, second])
        XCTAssertEqual(fetched.keys.sorted(), [2])
        let persisted = try JSONDecoder()
            .decode([String: SpineDesignV1].self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(persisted.count, 1)
    }

    func testCompletedBatchPersistsWhenFollowingBatchIsCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = (1...101).map { book(id: $0) }
        let database = FakeSpineDatabase()
        try await database.put(design(for: books[0]))
        await database.failBatch(number: 2, with: CancellationError())
        let store = SpineCloudStore(database: database, cacheURL: cacheURL)
        do {
            _ = try await store.designs(accountID: "42", books: books)
            XCTFail("Expected a cancelled second batch")
        } catch is CancellationError {
            let offline = SpineCloudStore(
                database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
            let retained = try await offline.designs(accountID: "42", books: books)
            XCTAssertEqual(retained.keys.sorted(), [1])
        }
    }

    func testWorklistPublishesFixedDataRecordWithoutReupload() async throws {
        let database = FakeSpineDatabase()
        let store = SpineCloudStore(database: database)
        let worklist = SpineWorklistV1(
            accountID: "42", syncedAt: Date(timeIntervalSince1970: 1_780_000_000),
            bookIDs: [7, 3, 7])
        try await store.publish(worklist)
        try await store.publish(worklist)
        let saved = try await store.worklist()
        let saveCount = await database.saveCount()
        let savedType = await database.savedType()
        XCTAssertEqual(saved?.bookIDs, [3, 7])
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(savedType, "SpineWorklistV1")
    }

    func testOlderSameAccountWorklistCannotReplaceNewerButEqualDateCanClear() async throws {
        let database = FakeSpineDatabase()
        let store = SpineCloudStore(database: database)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try await store.publish(SpineWorklistV1(accountID: "42", syncedAt: date, bookIDs: [7]))
        try await store.publish(
            SpineWorklistV1(
                accountID: "42", syncedAt: date.addingTimeInterval(-1), bookIDs: [3]))
        let afterOlder = try await store.worklist()
        let firstSaveCount = await database.saveCount()
        XCTAssertEqual(afterOlder?.bookIDs, [7])
        XCTAssertEqual(firstSaveCount, 1)

        try await store.publish(SpineWorklistV1(accountID: "42", syncedAt: date, bookIDs: []))
        let afterDisable = try await store.worklist()
        let finalSaveCount = await database.saveCount()
        XCTAssertEqual(afterDisable?.bookIDs, [])
        XCTAssertEqual(finalSaveCount, 2)
    }
}

private actor FakeSpineDatabase: SpineCloudDatabase {
    let status: CKAccountStatus
    private var payloads: [String: Data] = [:]
    private var recordTypes: [String: String] = [:]
    private var recordFailures: [String: CKError] = [:]
    private var batchFailure: (number: Int, error: any Error)?
    private var batchCount = 0
    private var saves = 0
    private var holdNext = false
    private var heldBatch: CheckedContinuation<Void, Never>?
    private var holdObserver: CheckedContinuation<Void, Never>?

    init(status: CKAccountStatus = .available) { self.status = status }

    func accountStatus() -> CKAccountStatus { status }

    func put(_ design: SpineDesignV1) throws {
        let name =
            SpineCloudIdentity.designRecordID(
                accountID: design.accountID, bookID: design.bookID
            )
            .recordName
        payloads[name] = try JSONEncoder().encode(design)
        recordTypes[name] = "SpineDesignV1"
    }

    func failRecord(for book: Book, with error: CKError) {
        let name = SpineCloudIdentity.designRecordID(accountID: "42", bookID: book.id).recordName
        recordFailures[name] = error
    }

    func failBatch(number: Int, with error: any Error) {
        batchFailure = (number, error)
    }

    func holdNextBatch() { holdNext = true }

    func waitForHeldBatch() async {
        if heldBatch != nil { return }
        await withCheckedContinuation { holdObserver = $0 }
    }

    func releaseHeldBatch() {
        heldBatch?.resume()
        heldBatch = nil
    }

    func record(for id: CKRecord.ID) throws -> CKRecord {
        if let error = recordFailures[id.recordName] { throw error }
        guard let payload = payloads[id.recordName], let type = recordTypes[id.recordName]
        else { throw CKError(.unknownItem) }
        let record = CKRecord(recordType: type, recordID: id)
        record["payload"] = payload as NSData
        return record
    }

    func records(for ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    {
        batchCount += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                heldBatch = continuation
                holdObserver?.resume()
                holdObserver = nil
            }
        }
        if let batchFailure, batchFailure.number == batchCount { throw batchFailure.error }
        return Dictionary(
            uniqueKeysWithValues: ids.map { id in
                (id, Result { try record(for: id) })
            })
    }

    func save(_ record: CKRecord) throws {
        guard let payload = record["payload"] as? Data else {
            throw CloudStorageError.incomplete
        }
        payloads[record.recordID.recordName] = payload
        recordTypes[record.recordID.recordName] = record.recordType
        saves += 1
    }

    func saveCount() -> Int { saves }
    func savedType() -> String? { recordTypes[SpineCloudIdentity.worklistRecordID.recordName] }
}
