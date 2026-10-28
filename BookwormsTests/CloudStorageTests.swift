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
        // A newer format may change the archive's shape as well as its version.
        for newer in [
            try JSONEncoder().encode(CloudLibraryArchive(version: 2)),
            Data(#"{"version": 2, "sources": {"hardcover": "a newer shape"}}"#.utf8),
        ] {
            let database = FakeCloudDatabase()
            await database.setArchiveData(newer)
            do {
                _ = try await CloudLibraryStore(database: database).sync(CloudLibraryArchive())
                XCTFail("A newer archive requires a compatible app.")
            } catch CloudStorageError.newerVersion {} catch {
                XCTFail("Unexpected error: \(error)")
            }
            let saves = await database.saves
            XCTAssertEqual(saves, 0)
            await database.cleanUp()
        }
    }

    func testAFailedReadThrowsWithoutReplacingTheArchive() async throws {
        let database = FakeCloudDatabase(readError: CKError(.networkFailure))
        do {
            _ = try await CloudLibraryStore(database: database).sync(CloudLibraryArchive())
            XCTFail("A failed read is a failure, never an empty archive.")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .networkFailure)
        }
        let saves = await database.saves
        XCTAssertEqual(saves, 0)
    }

    /// An archive in the shape the iPhone's `CloudLibraryArchive.splice(_:into:)` writes: sorted
    /// keys, `JSONSerialization` numbers, empty `designs`, and books without `isOwned` that carry
    /// `sources` and every field the iPhone downloads. The book and series are invented.
    private static let iPhoneArchive = #"""
        {"designs":{},"sources":[{"accountID":"fixture-account","books":[{"audioSeconds":36000,\#
        "author":"Fictional Author","communityRating":4.25,\#
        "coverURL":"https://covers.example.test/1.jpg","description":"<p>An invented book.</p>",\#
        "detailCoverURL":"https://covers.example.test/1-detail.jpg","dropped":"2026-03-04",\#
        "finished":"2026-02-01","finishedDates":["2026-02-01","2025-01-05"],\#
        "format":"Hardcover","genres":["Fantasy"],"id":101,"isRead":true,"isReading":false,\#
        "pages":320,"progress":0.5,"publicationYear":2020,"rating":4.5,\#
        "ratingDistribution":[{"count":3,"rating":4.5}],"ratingsCount":12,\#
        "review":"An invented review.","seriesID":7,"seriesMemberships":[{"compilation":false,\#
        "featured":true,"name":"Fictional Saga","position":1,"seriesID":7,"size":3}],\#
        "seriesName":"Fictional Saga","seriesPosition":1,"sources":["hardcover"],\#
        "started":"2026-01-02","statusID":3,"title":"Fictional Book: A Subtitle"}],\#
        "series":[{"books":[{"coverURL":"https://covers.example.test/1.jpg","id":101,\#
        "position":1,"releaseYear":2020,"title":"Fictional Book"}],"id":7,\#
        "name":"Fictional Saga"}],"source":"hardcover","syncedAt":800000000.5}],"version":1}
        """#

    func testAnArchiveTheIPhoneSplicedKeepsEveryBookField() async throws {
        let database = FakeCloudDatabase()
        await database.setArchiveData(Data(Self.iPhoneArchive.utf8))
        let cwa = SourceSnapshot(
            source: .cwa, accountID: "https://library.invalid/fixture",
            books: [Book(id: 1_000_000_000_000_001, title: "Owned", author: "Fictional Author")],
            syncedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let merged = try await CloudLibraryStore(database: database)
            .sync(CloudLibraryArchive(sources: [cwa]))
        let hardcover = try XCTUnwrap(merged.sources.first { $0.source == .hardcover })
        XCTAssertEqual(hardcover.syncedAt, Date(timeIntervalSinceReferenceDate: 800_000_000.5))
        XCTAssertEqual(hardcover.series?.first?.books.first?.title, "Fictional Book")
        let book = try XCTUnwrap(hardcover.books.first)
        XCTAssertEqual(book.sources, [.hardcover])
        XCTAssertNil(book.isOwned)
        XCTAssertEqual(book.finishedDates, ["2026-02-01", "2025-01-05"])
        XCTAssertEqual(book.seriesMemberships?.first?.size, 3)

        // The upload carries each field the iPhone wrote, unchanged.
        let saves = await database.saves
        XCTAssertEqual(saves, 1)
        func hardcoverBook(in data: Data) throws -> NSDictionary {
            let archive = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            let sources = try XCTUnwrap(archive["sources"] as? [[String: Any]])
            let entry = try XCTUnwrap(sources.first { $0["source"] as? String == "hardcover" })
            return try XCTUnwrap((entry["books"] as? [NSDictionary])?.first)
        }
        let written = try hardcoverBook(in: Data(Self.iPhoneArchive.utf8))
        let stored = await database.stored
        let uploaded = try hardcoverBook(in: XCTUnwrap(stored))
        for case let key as String in written.allKeys {
            XCTAssertEqual(uploaded[key] as? NSObject, written[key] as? NSObject, key)
        }
        await database.cleanUp()
    }
}

private actor FakeCloudDatabase: CloudLibraryDatabase {
    let status: CKAccountStatus
    var conflictArchive: CloudLibraryArchive?
    /// An error every read throws, such as a network failure.
    let readError: CKError?
    var stored: Data?
    var reads = 0
    var saves = 0
    private var files: [URL] = []
    init(
        status: CKAccountStatus = .available, conflictArchive: CloudLibraryArchive? = nil,
        readError: CKError? = nil
    ) {
        self.status = status
        self.conflictArchive = conflictArchive
        self.readError = readError
    }
    func accountStatus() -> CKAccountStatus { status }
    func setArchive(_ archive: CloudLibraryArchive) throws {
        stored = try JSONEncoder().encode(archive)
    }
    func setArchiveData(_ data: Data) { stored = data }
    func record(for id: CKRecord.ID) throws -> CKRecord {
        reads += 1
        if let readError { throw readError }
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
