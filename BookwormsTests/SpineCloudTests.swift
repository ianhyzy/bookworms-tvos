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
        let read = try await online.designs(accountID: "42", books: [book, self.book(id: 8)])
        XCTAssertEqual(read.values[7]?.typeface, "serif")
        XCTAssertTrue(read.isComplete, "A book without a design still counts as read")

        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let offlineRead = try await offline.designs(accountID: "42", books: [book])
        XCTAssertEqual(offlineRead.values[7]?.coverHash, String(repeating: "a", count: 64))
        XCTAssertFalse(offlineRead.isComplete, "A cached read is not complete")
        let other = try await offline.designs(accountID: "other", books: [book]).values
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
        let retained = try await offline.designs(accountID: "42", books: [book]).values
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

    func testCoverChoiceRecordNamesMatchIPhoneContract() {
        XCTAssertEqual(
            SpineCloudIdentity.coverChoiceRecordID(accountID: "42", bookID: 7).recordName,
            "cover-choice-v1-755dac3729029e2e2976249c4e03b160c699ef71f296c346e22183dc23503c33")
        XCTAssertEqual(
            SpineCloudIdentity.coverChoiceRecordID(accountID: "reader-1", bookID: 1234).recordName,
            "cover-choice-v1-83b1cd81db89961507083cb1fbc2f11d5a9e8a15e91f50b048ca7f7c9b2f3b1a")
    }

    func testCoverChoiceRejectsUnsafeURLsAndOtherBooks() throws {
        let book = book()
        func choice(_ url: String, accountID: String = "42", bookID: Int = 7, edition: Int? = 3)
            -> CoverChoiceV1
        {
            CoverChoiceV1(
                version: 1, accountID: accountID, bookID: bookID, coverURL: URL(string: url)!,
                editionID: edition, chosenAt: Date(timeIntervalSince1970: 1_780_000_000))
        }
        XCTAssertTrue(
            choice("https://assets.hardcover.app/edition.jpg").isValid(accountID: "42", book: book))
        XCTAssertTrue(
            choice("https://assets.hardcover.app/a.jpg", edition: nil)
                .isValid(accountID: "42", book: book))
        for url in [
            "http://assets.hardcover.app/a.jpg", "https://user@assets.hardcover.app/a.jpg",
            "https://assets.hardcover.app:8443/a.jpg", "https://assets.hardcover.app/a.jpg#x",
            "https://localhost/a.jpg", "https://nas.local/a.jpg", "https://tv.internal/a.jpg",
            "https://192.168.1.2/a.jpg", "https://[::1]/a.jpg", "https://intranet/a.jpg",
        ] {
            XCTAssertFalse(choice(url).isValid(accountID: "42", book: book), url)
        }
        XCTAssertFalse(
            choice("https://assets.hardcover.app/a.jpg", edition: 0)
                .isValid(accountID: "42", book: book))
        XCTAssertFalse(
            choice("https://assets.hardcover.app/a.jpg", bookID: 8)
                .isValid(accountID: "42", book: book))
        XCTAssertFalse(
            choice("https://assets.hardcover.app/a.jpg").isValid(accountID: "other", book: book))

        // The iPhone omits `editionID` when the cover belongs to no edition.
        let payload = Data(
            #"{"version":1,"accountID":"42","bookID":7,"coverURL":"https://assets.hardcover.app/a.jpg","chosenAt":801000000.5}"#
                .utf8)
        let decoded = try JSONDecoder().decode(CoverChoiceV1.self, from: payload)
        XCTAssertNil(decoded.editionID)
        XCTAssertTrue(decoded.isValid(accountID: "42", book: book))
    }

    func testCoverChoiceCachesOfflineAndDeletionRestoresDefaultCover() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let choice = CoverChoiceV1(
            version: 1, accountID: "42", bookID: 7,
            coverURL: URL(string: "https://assets.hardcover.app/edition.jpg")!, editionID: 3,
            chosenAt: Date(timeIntervalSince1970: 1_780_000_000))
        let database = FakeSpineDatabase()
        try await database.put(choice)
        try await database.put(design(for: book))
        let store = SpineCloudStore(database: database, cacheURL: cacheURL)
        let fetched = try await store.coverChoices(accountID: "42", books: [book])
        XCTAssertEqual(fetched[7], choice)
        let designs = try await store.designs(accountID: "42", books: [book]).values
        XCTAssertEqual(designs.count, 1, "Designs and choices keep separate caches")

        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let retained = try await offline.coverChoices(accountID: "42", books: [book])
        XCTAssertEqual(retained[7], choice)

        await database.deleteCoverChoice(accountID: "42", bookID: 7)
        let cleared = try await store.coverChoices(accountID: "42", books: [book])
        XCTAssertTrue(cleared.isEmpty)
        let cache = try JSONDecoder()
            .decode(
                [String: CoverChoiceV1].self,
                from: Data(contentsOf: directory.appending(path: "cover-choices-v1.json")))
        XCTAssertTrue(cache.isEmpty)
        let keptDesigns = try await offline.designs(accountID: "42", books: [book]).values
        XCTAssertEqual(keptDesigns.count, 1)
    }

    func testEmptyAccountSelectionPrunesPriorAccountCacheWhileOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = book()
        let database = FakeSpineDatabase()
        try await database.put(design(for: book))
        let online = SpineCloudStore(database: database, cacheURL: cacheURL)
        let populated = try await online.designs(accountID: "42", books: [book]).values
        XCTAssertEqual(populated.count, 1)

        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let pruned = try await offline.designs(accountID: "other", books: []).values
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
        let populated = try await online.designs(accountID: "42", books: [book]).values
        XCTAssertEqual(populated.count, 1)

        var changed = book
        changed.detailCoverURL = URL(string: "https://example.test/replaced.jpg")
        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let pruned = try await offline.designs(accountID: "42", books: [changed]).values
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
        let olderRead = Task { try await store.designs(accountID: "42", books: [book]).values }
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
        let initial = try await store.designs(accountID: "42", books: [book]).values
        XCTAssertEqual(initial.count, 1)

        try await database.put(design(for: book, typeface: "external-font"))
        let refreshed = try await store.designs(accountID: "42", books: [book]).values
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
        let refreshed = try await store.designs(accountID: "42", books: [book]).values
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
        XCTAssertEqual(fetched.values.keys.sorted(), [2])
        XCTAssertFalse(fetched.isComplete, "A failed record leaves the read incomplete")
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
            let retained = try await offline.designs(accountID: "42", books: books).values
            XCTAssertEqual(retained.keys.sorted(), [1])
        }
    }

    func testFailedBatchReturnsEarlierBatchesAsAnIncompleteRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = (1...101).map { book(id: $0) }
        let database = FakeSpineDatabase()
        try await database.put(design(for: books[0]))
        await database.failBatch(number: 2, with: CKError(.serviceUnavailable))
        let read = try await SpineCloudStore(database: database, cacheURL: cacheURL)
            .designs(accountID: "42", books: books)
        XCTAssertEqual(read.values.keys.sorted(), [1])
        XCTAssertFalse(read.isComplete)
    }

    private let cityWatch = SeriesLookKey(seriesID: 1018, group: "City Watch|terrypratchett")

    private func look(
        _ key: SeriesLookKey? = nil, backgroundHex: String = "#1A2B3C", weight: Int = 700
    ) -> SeriesLookV1 {
        let key = key ?? cityWatch
        return SeriesLookV1(
            accountID: "42", seriesID: key.seriesID, group: key.group, sourceBookID: 123,
            origin: "ios-pcc-v2", createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            backgroundHex: backgroundHex, foregroundHex: "#F0E0D0", accentHex: "#C0A060",
            typeface: "serif", weight: weight, uppercase: false, fontFamily: "EB Garamond",
            fontPostScriptName: "EBGaramond-Bold", instanceWeight: 700)
    }

    func testSeriesRecordNamesMatchIPhoneContract() {
        XCTAssertEqual(
            SpineCloudIdentity.seriesLookRecordID(accountID: "42", key: cityWatch).recordName,
            "series-look-v1-f6b8bd60e3d149603964e4149bb554dfad824022ea2eb99f8ca02e5708be48b1")
        XCTAssertEqual(
            SpineCloudIdentity.seriesLookRecordID(
                accountID: "reader-1", key: SeriesLookKey(seriesID: 2001, group: "|mattdinniman")
            )
            .recordName,
            "series-look-v1-6e2279d0948162ceac3aa23fc9b1358452aa321064eb41d5e87182e41e94a104")
        XCTAssertEqual(
            SpineCloudIdentity.seriesLinkRecordID(accountID: "42", bookID: 7).recordName,
            "series-link-v1-755dac3729029e2e2976249c4e03b160c699ef71f296c346e22183dc23503c33")
    }

    func testSeriesLookPayloadDecodesAndFollowsTheDesignLookRules() throws {
        let json = #"""
            {"version": 1, "accountID": "42", "seriesID": 1018,
             "group": "City Watch|terrypratchett", "sourceBookID": 123, "origin": "ios-pcc-v2",
             "createdAt": 801000000, "backgroundHex": "#1A2B3C", "foregroundHex": "#F0E0D0",
             "accentHex": "#C0A060", "typeface": "serif", "weight": 700, "uppercase": false,
             "fontFamily": "EB Garamond", "fontPostScriptName": "EBGaramond-Bold",
             "instanceWeight": 700}
            """#
        let decoded = try JSONDecoder().decode(SeriesLookV1.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isValid(accountID: "42", key: cityWatch))
        XCTAssertNil(decoded.editedAt)
        XCTAssertEqual(
            try JSONDecoder().decode(SeriesLookV1.self, from: JSONEncoder().encode(decoded)),
            decoded)

        XCTAssertFalse(look().isValid(accountID: "other", key: cityWatch))
        XCTAssertFalse(
            look().isValid(accountID: "42", key: SeriesLookKey(seriesID: 1018, group: "|")))
        XCTAssertFalse(look(weight: 650).isValid(accountID: "42", key: cityWatch))
        XCTAssertFalse(
            look(backgroundHex: "#E0D0C0").isValid(accountID: "42", key: cityWatch),
            "Text needs 4.5:1 contrast")
        XCTAssertFalse(
            look(backgroundHex: "#1a2b3c").isValid(accountID: "42", key: cityWatch))
        let long = SeriesLookKey(seriesID: 1018, group: String(repeating: "a", count: 201))
        XCTAssertFalse(look(long).isValid(accountID: "42", key: long))
        var blank = look()
        blank = SeriesLookV1(
            accountID: "42", seriesID: 1018, group: cityWatch.group, sourceBookID: 123,
            origin: " ", createdAt: blank.createdAt, backgroundHex: blank.backgroundHex,
            foregroundHex: blank.foregroundHex, accentHex: blank.accentHex, typeface: "serif",
            weight: 700, uppercase: false)
        XCTAssertFalse(blank.isValid(accountID: "42", key: cityWatch), "An origin is required")
    }

    func testSeriesLinkPayloadDecodesAndValidatesItsBook() throws {
        let json = #"""
            {"version": 1, "accountID": "42", "bookID": 7, "linkedSeriesID": 2001,
             "standsAlone": false, "ownLook": true, "chosenAt": 801000000}
            """#
        let link = try JSONDecoder().decode(SeriesLinkV1.self, from: Data(json.utf8))
        XCTAssertEqual(link.linkedSeriesID, 2001)
        XCTAssertTrue(link.ownLook)
        XCTAssertTrue(link.isValid(accountID: "42", book: book()))
        XCTAssertFalse(link.isValid(accountID: "42", book: book(id: 8)))
        XCTAssertFalse(link.isValid(accountID: "other", book: book()))
        let unlinked = try JSONDecoder()
            .decode(
                SeriesLinkV1.self,
                from: Data(
                    #"{"version": 1, "accountID": "42", "bookID": 7, "standsAlone": true, "ownLook": false, "chosenAt": 0}"#
                        .utf8))
        XCTAssertNil(unlinked.linkedSeriesID)
        XCTAssertTrue(unlinked.isValid(accountID: "42", book: book()))
    }

    func testSeriesLinksAndLooksCacheForOfflineReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = SeriesLinkV1(
            accountID: "42", bookID: 7, standsAlone: true,
            chosenAt: Date(timeIntervalSince1970: 1_780_000_000))
        let database = FakeSpineDatabase()
        try await database.put(link)
        try await database.put(look())
        let online = SpineCloudStore(database: database, cacheURL: cacheURL)
        let links = try await online.seriesLinks(accountID: "42", books: [book()]).values
        let looks = try await online.seriesLooks(accountID: "42", keys: [cityWatch])
        XCTAssertEqual(links, [7: link])
        XCTAssertEqual(looks, [cityWatch: look()])

        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let cachedLinks = try await offline.seriesLinks(accountID: "42", books: [book()]).values
        let cachedLooks = try await offline.seriesLooks(accountID: "42", keys: [cityWatch])
        XCTAssertEqual(cachedLinks, [7: link])
        XCTAssertEqual(cachedLooks, [cityWatch: look()])
        let cleared = try await offline.seriesLooks(accountID: "", keys: [])
        XCTAssertTrue(cleared.isEmpty)
        let afterClear = try await offline.seriesLooks(accountID: "42", keys: [cityWatch])
        XCTAssertTrue(afterClear.isEmpty, "An empty account clears the look cache")
    }

    func testCreatingASeriesLookKeepsTheLookSavedFirst() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cacheURL = directory.appending(path: "spine-designs.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = FakeSpineDatabase()
        let store = SpineCloudStore(database: database, cacheURL: cacheURL)
        let first = try await store.createSeriesLook(look())
        XCTAssertEqual(first, look())
        let offline = SpineCloudStore(
            database: FakeSpineDatabase(status: .noAccount), cacheURL: cacheURL)
        let cached = try await offline.seriesLooks(accountID: "42", keys: [cityWatch])
        XCTAssertEqual(cached[cityWatch], look(), "A created look is cached for offline reads")

        // Another device's later look loses to the saved one, which is never replaced.
        let later = SpineCloudStore(database: database, cacheURL: cacheURL)
        let kept = try await later.createSeriesLook(look(backgroundHex: "#000000"))
        XCTAssertEqual(kept, look())
        let saveCount = await database.saveCount()
        XCTAssertEqual(saveCount, 1)
        let read = try await later.seriesLooks(accountID: "42", keys: [cityWatch])
        XCTAssertEqual(read[cityWatch]?.backgroundHex, "#1A2B3C")
        do {
            _ = try await offline.createSeriesLook(look())
            XCTFail("Creating a look needs iCloud")
        } catch CloudStorageError.unavailable {}
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
    /// Records this database returned, which `save(_:)` may change.
    private var served: [CKRecord] = []

    init(status: CKAccountStatus = .available) { self.status = status }

    func accountStatus() -> CKAccountStatus { status }

    func put(_ choice: CoverChoiceV1) throws {
        let name =
            SpineCloudIdentity.coverChoiceRecordID(
                accountID: choice.accountID, bookID: choice.bookID
            )
            .recordName
        payloads[name] = try JSONEncoder().encode(choice)
        recordTypes[name] = "CoverChoiceV1"
    }

    func deleteCoverChoice(accountID: String, bookID: Int) {
        let name =
            SpineCloudIdentity.coverChoiceRecordID(accountID: accountID, bookID: bookID).recordName
        payloads[name] = nil
        recordTypes[name] = nil
    }

    func put(_ link: SeriesLinkV1) throws {
        let name =
            SpineCloudIdentity.seriesLinkRecordID(accountID: link.accountID, bookID: link.bookID)
            .recordName
        payloads[name] = try JSONEncoder().encode(link)
        recordTypes[name] = "SeriesLinkV1"
    }

    func put(_ look: SeriesLookV1) throws {
        let name =
            SpineCloudIdentity.seriesLookRecordID(accountID: look.accountID, key: look.key)
            .recordName
        payloads[name] = try JSONEncoder().encode(look)
        recordTypes[name] = "SeriesLookV1"
    }

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
        served.append(record)
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

    /// Saves like `.ifServerRecordUnchanged`: a new record cannot replace a saved one.
    func save(_ record: CKRecord) throws {
        guard let payload = record["payload"] as? Data else {
            throw CloudStorageError.incomplete
        }
        if payloads[record.recordID.recordName] != nil, !served.contains(where: { $0 === record }) {
            throw CKError(.serverRecordChanged)
        }
        payloads[record.recordID.recordName] = payload
        recordTypes[record.recordID.recordName] = record.recordType
        saves += 1
    }

    func saveCount() -> Int { saves }
    func savedType() -> String? { recordTypes[SpineCloudIdentity.worklistRecordID.recordName] }
}
