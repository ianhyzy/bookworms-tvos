import CloudKit
import XCTest

@testable import Bookworms

final class CloudStorageTests: XCTestCase {
    func testUnchangedArchiveDoesNotUploadAgain() async throws {
        let database = FakeCloudDatabase()
        let store = CloudLibraryStore(database: database)
        let archive = CloudLibraryArchive(sources: [
            SourceSnapshot(
                source: .hardcover, accountID: "test", books: SampleLibrary.books, syncedAt: Date())
        ])
        let first = try await store.sync(archive)
        let second = try await store.sync(archive)
        XCTAssertEqual(first.sources.first?.books, second.sources.first?.books)
        let saves = await database.saves
        XCTAssertEqual(saves, 1)
        await database.cleanUp()
    }

    func testConflictRefetchesAndPreservesBothSources() async throws {
        let remote = SourceSnapshot(
            source: .cwa, accountID: "test", books: [SampleLibrary.books[1]], syncedAt: Date())
        let database = FakeCloudDatabase(conflictArchive: CloudLibraryArchive(sources: [remote]))
        let local = SourceSnapshot(
            source: .hardcover, accountID: "test", books: [SampleLibrary.books[0]], syncedAt: Date()
        )
        let result = try await CloudLibraryStore(database: database)
            .sync(CloudLibraryArchive(sources: [local]))
        XCTAssertEqual(Set(result.sources.map(\.source)), [.hardcover, .cwa])
        let attempts = await database.saves
        XCTAssertEqual(attempts, 2)
        await database.cleanUp()
    }

    func testNoAccountAndRestrictionDoNotReadOrWriteCloudRecords() async {
        for status in [CKAccountStatus.noAccount, .restricted, .temporarilyUnavailable] {
            let database = FakeCloudDatabase(status: status)
            do {
                _ = try await CloudLibraryStore(database: database).sync(CloudLibraryArchive())
                XCTFail("Unavailable accounts must not sync.")
            } catch {
                let text = UserFacingError.message(error)
                XCTAssertEqual(text.contains("Sign in"), status == .noAccount)
            }
            let reads = await database.reads
            let saves = await database.saves
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(saves, 0)
        }
    }

    func testNewerArchiveIsNotOverwritten() async throws {
        let database = FakeCloudDatabase()
        try await database.setArchive(CloudLibraryArchive(version: 2))
        do {
            _ = try await CloudLibraryStore(database: database).sync(CloudLibraryArchive())
            XCTFail("A newer archive requires a compatible app.")
        } catch CloudStorageError.newerVersion {} catch { XCTFail("Unexpected error: \(error)") }
        let saves = await database.saves
        XCTAssertEqual(saves, 0)
        await database.cleanUp()
    }
}

private actor FakeCloudDatabase: CloudLibraryDatabase {
    let status: CKAccountStatus
    var conflictArchive: CloudLibraryArchive?
    var stored: Data?
    var reads = 0
    var saves = 0
    private var files: [URL] = []
    init(status: CKAccountStatus = .available, conflictArchive: CloudLibraryArchive? = nil) {
        self.status = status
        self.conflictArchive = conflictArchive
    }
    func accountStatus() -> CKAccountStatus { status }
    func setArchive(_ archive: CloudLibraryArchive) throws {
        stored = try JSONEncoder().encode(archive)
    }
    func record(for id: CKRecord.ID) throws -> CKRecord {
        reads += 1
        guard let stored else { throw CKError(.unknownItem) }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        files.append(file)
        try stored.write(to: file)
        let record = CKRecord(recordType: "LibraryArchive", recordID: id)
        record["archive"] = CKAsset(fileURL: file)
        return record
    }
    func save(_ record: CKRecord) throws {
        saves += 1
        if let conflictArchive {
            self.conflictArchive = nil
            try setArchive(conflictArchive)
            throw CKError(.serverRecordChanged)
        }
        let asset = try XCTUnwrap(record["archive"] as? CKAsset)
        stored = try Data(contentsOf: XCTUnwrap(asset.fileURL))
    }
    func cleanUp() {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
