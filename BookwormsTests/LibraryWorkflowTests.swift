import Observation
import XCTest
import os

@testable import Bookworms

@MainActor
final class LibraryWorkflowTests: XCTestCase {
    func testHardcoverSetupResetRemovesLocalAccountAndDefersCloudRestore() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "hasCompletedWelcome")
        fixture.defaults.set(false, forKey: "hardcoverEnabled")
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.set(fixture.time, forKey: "syncAttempt.hardcover")
        fixture.defaults.set(fixture.time, forKey: "syncSuccess.hardcover")
        fixture.defaults.set(["hardcover": "Saved connection error"], forKey: "sourceErrors")
        fixture.secrets["hardcover-refresh-token"] = "hc_rt_fictional_original"
        fixture.defaults.set(fixture.time, forKey: HardcoverSession.renewalKey)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        let revoked = expectation(description: "The removed login is revoked at Hardcover")
        dependencies.revokeHardcoverToken = { refreshToken in
            XCTAssertEqual(refreshToken, "hc_rt_fictional_original")
            revoked.fulfill()
        }
        let legacy = LibrarySnapshot(books: [fixture.book(1)], syncedAt: fixture.time)
        try JSONEncoder().encode(legacy).write(to: dependencies.legacySnapshotURL)
        let model = LibraryModel(dependencies: dependencies)

        try await model.resetHardcoverSetup()
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertNil(fixture.secrets["hardcover-token"])
        XCTAssertNil(fixture.secrets["hardcover-refresh-token"])
        XCTAssertNil(fixture.defaults.object(forKey: HardcoverSession.renewalKey))
        XCTAssertTrue(dependencies.sourceStore.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dependencies.legacySnapshotURL.path))
        for key in [
            "activeHardcoverAccountID", "hasCompletedWelcome", "syncAttempt.hardcover",
            "syncSuccess.hardcover",
        ] {
            XCTAssertNil(fixture.defaults.object(forKey: key))
        }
        XCTAssertNil(model.sourceErrors["hardcover"])
        XCTAssertTrue(model.hardcoverEnabled)
        XCTAssertTrue(model.iCloudEnabled, "The reset preserves the owner's storage preference.")
        await model.start()
        await model.waitForCloudSync()
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertFalse(model.hardcoverConnected)
        XCTAssertFalse(model.hasCompletedWelcome)
        XCTAssertTrue(model.shouldOfferWelcome)
        XCTAssertEqual(model.cloudStatus, "iCloud storage waits until setup finishes.")
    }

    func testOwnedBooksIsOfferedOnlyWhenItCanShowBooks() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "hasCompletedWelcome")
        fixture.defaults.set(
            try JSONEncoder().encode(ShelfPreferences(collection: .owned)),
            forKey: "shelfPreferences")
        var owned = fixture.book(2)
        owned.isOwned = true
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1), owned])])
        let model = LibraryModel(dependencies: fixture.dependencies())

        await model.start()
        XCTAssertEqual(
            model.shelfCollections.contains(.owned), BookPresentation.offersCWA,
            "Only the CWA source marks books owned")
        XCTAssertEqual(model.shelfPreferences.collection, .owned, "The saved choice stays")
        if !BookPresentation.offersCWA {
            XCTAssertEqual(model.activeShelfPreferences.collection, ShelfPreferences().collection)
            XCTAssertEqual(Set(model.books.map(\.id)), [1, 2])
        }
    }

    func testAnOlderSnapshotOfAnotherAccountDoesNotMakeHardcoverDue() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "hasCompletedWelcome")
        let placeholder = SourceSnapshot(
            source: .hardcover, accountID: "hardcover", books: [fixture.book(2)],
            syncedAt: fixture.time.addingTimeInterval(-30 * 86_400))
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)]), placeholder])
        // The fixture fails any Hardcover request, so the start must not find the source due.
        let model = LibraryModel(dependencies: fixture.dependencies())

        await model.start()
        XCTAssertEqual(
            fixture.defaults.object(forKey: "syncSuccess.hardcover") as? Date, fixture.time,
            "The active account's snapshot, not the older placeholder, sets the last success")
    }

    func testHardcoverSetupResetRetainsCWAArtworkDesignsAndDisplaySettings() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "hasCompletedWelcome")
        fixture.defaults.set(true, forKey: "cwaEnabled")
        fixture.defaults.set("light", forKey: "appearance")
        fixture.defaults.set(15, forKey: "bookCount")
        fixture.defaults.set(fixture.time, forKey: "syncAttempt.cwa")
        fixture.defaults.set(fixture.time, forKey: "syncSuccess.cwa")
        fixture.defaults.set(
            ["hardcover": "Hardcover error", "cwa": "CWA error"], forKey: "sourceErrors")
        fixture.secrets["cwa-password"] = "fictional-password"
        try fixture.save([
            fixture.snapshot(.hardcover, books: [fixture.book(1)]),
            fixture.snapshot(.cwa, books: [fixture.book(2)]),
        ])
        let dependencies = fixture.dependencies()
        let record = AIStyleRecord(
            bookID: 1, style: .fallback(for: fixture.book(1)),
            font: DownloadedFont(
                family: "Fixture", postScriptName: "Fixture-Regular", filePath: "fixture.ttf",
                licensePath: "fixture-license.txt"),
            weight: 400, provider: .openAI, model: "fixture-model", coverHash: "fixture-cover",
            generatedAt: fixture.time, rationale: "Fictional saved design")
        try dependencies.styleStore.save([1: record])
        let designs = try Data(contentsOf: dependencies.styleStore.cacheURL)
        let artworkURL = fixture.directory.appending(path: "artwork/retained-cover")
        try FileManager.default.createDirectory(
            at: artworkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let artwork = Data("Fictional retained artwork".utf8)
        try artwork.write(to: artworkURL)
        let model = LibraryModel(dependencies: dependencies)

        try await model.resetHardcoverSetup()
        XCTAssertEqual(dependencies.sourceStore.load().map(\.source), [.cwa])
        XCTAssertEqual(dependencies.sourceStore.load().first?.books.map(\.id), [2])
        XCTAssertEqual(fixture.secrets["cwa-password"], "fictional-password")
        XCTAssertEqual(model.cwaConfiguration, fixture.configuration)
        XCTAssertTrue(model.cwaEnabled)
        XCTAssertEqual(fixture.defaults.object(forKey: "syncAttempt.cwa") as? Date, fixture.time)
        XCTAssertEqual(fixture.defaults.object(forKey: "syncSuccess.cwa") as? Date, fixture.time)
        XCTAssertEqual(model.sourceErrors["cwa"], "CWA error")
        XCTAssertNil(model.sourceErrors["hardcover"])
        XCTAssertEqual(fixture.defaults.string(forKey: "appearance"), "light")
        XCTAssertEqual(model.bookCount, 15)
        XCTAssertEqual(try Data(contentsOf: artworkURL), artwork)
        XCTAssertEqual(try Data(contentsOf: dependencies.styleStore.cacheURL), designs)
        XCTAssertEqual(fixture.defaults.data(forKey: AIStyleStore.key), designs)
        await model.start()
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertFalse(model.shouldOfferWelcome, "A retained CWA account still suppresses setup.")
        XCTAssertEqual(dependencies.styleStore.load()[1]?.rationale, record.rationale)
    }

    func testHardcoverSetupResetStopsWhenCredentialRemovalFails() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "hasCompletedWelcome")
        fixture.defaults.set(false, forKey: "hardcoverEnabled")
        fixture.defaults.set(fixture.time, forKey: "syncAttempt.hardcover")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.removeCredential = { _ in }
        let legacy = LibrarySnapshot(books: [fixture.book(1)], syncedAt: fixture.time)
        try JSONEncoder().encode(legacy).write(to: dependencies.legacySnapshotURL)
        let model = LibraryModel(dependencies: dependencies)

        do {
            try await model.resetHardcoverSetup()
            XCTFail("A retained Keychain credential must stop the reset.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_original")
        XCTAssertEqual(dependencies.sourceStore.load().first?.books.map(\.id), [1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dependencies.legacySnapshotURL.path))
        XCTAssertEqual(
            fixture.defaults.string(forKey: "activeHardcoverAccountID"), fixture.hardcoverAccountID)
        XCTAssertTrue(model.hasCompletedWelcome)
        XCTAssertFalse(model.hardcoverEnabled)
        XCTAssertEqual(
            fixture.defaults.object(forKey: "syncAttempt.hardcover") as? Date, fixture.time)
        await model.start()
        XCTAssertTrue(model.hardcoverConnected)
        XCTAssertFalse(model.shouldOfferWelcome)
    }

    func testHardcoverSetupResetResumesCloudWhenRetainedCWAStateSkipsWelcome() async throws {
        for retainsCredential in [true, false] {
            let fixture = try LibraryWorkflowFixture()
            defer { fixture.cleanUp() }
            fixture.defaults.set(true, forKey: "iCloudEnabled")
            if retainsCredential {
                fixture.secrets["cwa-password"] = "fictional-password"
            }
            var snapshots = [fixture.snapshot(.hardcover, books: [fixture.book(1)])]
            if !retainsCredential {
                snapshots.append(fixture.snapshot(.cwa, books: [fixture.book(2)]))
            }
            try fixture.save(snapshots)
            var dependencies = fixture.dependencies()
            dependencies.sleep = { _ in }
            var cloudCalls = 0
            dependencies.syncCloud = { archive in
                cloudCalls += 1
                return archive
            }
            let model = LibraryModel(dependencies: dependencies)

            try await model.resetHardcoverSetup()
            await model.start()
            await model.waitForCloudSync()

            XCTAssertFalse(model.shouldOfferWelcome)
            XCTAssertFalse(model.hasCompletedWelcome)
            XCTAssertNil(fixture.secrets["hardcover-token"])
            XCTAssertEqual(cloudCalls, 1, "Retained CWA state must not strand iCloud behind setup.")
            XCTAssertTrue(model.cloudStatus.hasPrefix("Saved to iCloud."))
            XCTAssertEqual(model.hasCWAPassword, retainsCredential)
            XCTAssertEqual(
                dependencies.sourceStore.load().map(\.source), retainsCredential ? [] : [.cwa])
        }
    }

    func testWelcomeWaitsForStartupAndPersistsExplicitCompletion() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        let dependencies = fixture.dependencies()
        let model = LibraryModel(dependencies: dependencies)
        XCTAssertFalse(model.shouldOfferWelcome, "Startup must inspect saved state before setup.")
        await model.start()
        XCTAssertTrue(model.shouldOfferWelcome)
        XCTAssertFalse(model.hasCompletedWelcome)
        model.completeWelcome()
        XCTAssertFalse(model.shouldOfferWelcome)
        XCTAssertTrue(fixture.defaults.bool(forKey: "hasCompletedWelcome"))

        let restored = LibraryModel(dependencies: dependencies)
        await restored.start()
        XCTAssertFalse(restored.shouldOfferWelcome)
        XCTAssertTrue(restored.hasCompletedWelcome)
    }

    func testWelcomeSkipsSavedAccountsEvenWhenTheirSourcesAreDisabled() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "hardcoverEnabled")
        let hardcover = LibraryModel(dependencies: fixture.dependencies())
        await hardcover.start()
        XCTAssertTrue(hardcover.hardcoverConnected)
        XCTAssertFalse(hardcover.isConnected)
        XCTAssertFalse(hardcover.shouldOfferWelcome)

        fixture.secrets.removeAll()
        fixture.secrets["cwa-password"] = "fictional-password"
        fixture.defaults.set(false, forKey: "cwaEnabled")
        let cwa = LibraryModel(dependencies: fixture.dependencies())
        await cwa.start()
        XCTAssertTrue(cwa.hasCWAPassword)
        XCTAssertFalse(cwa.isConnected)
        XCTAssertFalse(cwa.shouldOfferWelcome)
    }

    func testWelcomeSkipsSavedEmptySnapshotWithoutCredentials() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        try fixture.save([fixture.snapshot(.hardcover, books: [])])
        let model = LibraryModel(dependencies: fixture.dependencies())
        await model.start()
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertFalse(model.hardcoverConnected)
        XCTAssertFalse(model.shouldOfferWelcome)
        XCTAssertFalse(model.hasCompletedWelcome)
    }

    func testSampleChoiceCompletesWelcomeWithoutProviderRequests() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        let dependencies = fixture.dependencies()
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(model.shouldOfferWelcome)
        model.showSample()
        XCTAssertTrue(model.isSample)
        XCTAssertFalse(model.books.isEmpty)
        XCTAssertTrue(model.hasCompletedWelcome)
        XCTAssertFalse(model.shouldOfferWelcome)
        XCTAssertTrue(dependencies.sourceStore.load().isEmpty)

        let restored = LibraryModel(dependencies: dependencies)
        await restored.start()
        XCTAssertTrue(restored.hasCompletedWelcome)
        XCTAssertFalse(restored.shouldOfferWelcome)
    }

    func testFirstConnectionReportsValidationAndDownloadUntilSaved() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        let validation = ControlledLibraryResponse<String>("Account validation started")
        let download = ControlledLibraryResponse<HardcoverLibrary>("Library download started")
        var dependencies = fixture.dependencies()
        dependencies.validateHardcover = { _ in try await validation.value() }
        dependencies.fetchHardcover = { _, _ in try await download.value() }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let connection = Task { await model.connect("hc_pat_fictional_original") }
        await fulfillment(of: [validation.started], timeout: 5)
        XCTAssertTrue(model.isLoading)
        if case .validatingAccount? = model.hardcoverConnectionPhase {
        } else {
            XCTFail("Account validation must have its own progress phase.")
        }
        XCTAssertNil(fixture.secrets["hardcover-token"])
        XCTAssertFalse(model.hasCompletedWelcome)
        validation.resolve(fixture.hardcoverAccountID)
        await fulfillment(of: [download.started], timeout: 5)
        if case .downloadingLibrary? = model.hardcoverConnectionPhase {
        } else {
            XCTFail("Library download must have its own progress phase.")
        }
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertNil(fixture.secrets["hardcover-token"])
        download.resolve(
            HardcoverLibrary(accountID: fixture.hardcoverAccountID, books: [fixture.book(1)]))
        let connected = await connection.value
        XCTAssertTrue(connected)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.hardcoverConnectionPhase)
        XCTAssertTrue(model.hardcoverConnected)
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertEqual(dependencies.sourceStore.load().first?.books.map(\.id), [1])
        XCTAssertFalse(
            model.hasCompletedWelcome, "The welcome view completes setup after artwork is ready.")
    }

    func testFailedFirstDownloadPreservesUncompletedWelcomeAndClearsProgress() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        var dependencies = fixture.dependencies()
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        dependencies.fetchHardcover = { _, _ in throw URLError(.notConnectedToInternet) }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let connected = await model.connect("hc_pat_fictional_original")
        XCTAssertFalse(connected)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.hardcoverConnectionPhase)
        XCTAssertFalse(model.hardcoverConnected)
        XCTAssertNil(fixture.secrets["hardcover-token"])
        XCTAssertTrue(dependencies.sourceStore.load().isEmpty)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.shouldOfferWelcome)
        XCTAssertFalse(model.hasCompletedWelcome)
    }

    func testCachedOfflineStartupRetainsBooksAndErrorAcrossRelaunch() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86401)])
        var dependencies = fixture.dependencies()
        var fetches = 0
        dependencies.fetchHardcover = { _, _ in
            fetches += 1
            throw URLError(.notConnectedToInternet)
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertFalse(model.isSample)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(fetches, 1)
        XCTAssertNotNil(model.sourceErrors["hardcover"])

        let restored = LibraryModel(dependencies: dependencies)
        await restored.start()
        XCTAssertEqual(restored.books.map(\.id), [1])
        XCTAssertNotNil(restored.sourceErrors["hardcover"])
        XCTAssertEqual(fetches, 1, "A failed request must respect the five-minute backoff.")
        fixture.time += 300
        await restored.becameActive()
        XCTAssertEqual(fetches, 2)
    }

    func testPartialProviderFailureSavesSuccessfulSourceAndKeepsOtherCache() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "cwaEnabled")
        fixture.secrets["cwa-password"] = "fictional-password"
        try fixture.save([
            fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86401),
            fixture.snapshot(.cwa, books: [fixture.book(2)], age: 86401),
        ])
        var dependencies = fixture.dependencies()
        dependencies.fetchHardcover = { _, _ in
            HardcoverLibrary(accountID: fixture.hardcoverAccountID, books: [fixture.book(3)])
        }
        dependencies.fetchCWA = { _, _ in throw SourceError.forbidden }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertEqual(Set(model.books.map(\.id)), [2, 3])
        XCTAssertNil(model.sourceErrors["hardcover"])
        XCTAssertNotNil(model.sourceErrors["cwa"])
        let saved = dependencies.sourceStore.load()
        XCTAssertEqual(saved.first { $0.source == .hardcover }?.books.map(\.id), [3])
        XCTAssertEqual(saved.first { $0.source == .cwa }?.books.map(\.id), [2])
    }

    func testSyncedSeriesPersistAndMatchTheirBooks() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86401)])
        var book = fixture.book(3)
        book.seriesID = 7
        book.coverURL = URL(string: "https://covers.example/library-3.jpg")
        let series = SeriesInfo(
            id: 7, name: "Fictional Saga",
            books: [
                .init(
                    id: 3, title: "One", position: 1, releaseYear: 2024,
                    coverURL: URL(string: "https://covers.example/series-3.jpg")),
                .init(
                    id: 4, title: "Two", position: 2, releaseYear: nil,
                    coverURL: URL(string: "https://covers.example/series-4.jpg")),
            ])
        var dependencies = fixture.dependencies()
        var seriesFetchFails = false
        dependencies.fetchHardcover = { _, _ in
            HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [book],
                series: seriesFetchFails ? nil : [series])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertEqual(model.series(for: book)?.books.map(\.id), [3, 4])
        XCTAssertEqual(
            model.browsingCoverURLs.map(\.lastPathComponent), ["library-3.jpg", "series-4.jpg"],
            "Owned series books use their library cover")
        var saved = dependencies.sourceStore.load()
        XCTAssertEqual(saved.first { $0.source == .hardcover }?.series, [series])

        seriesFetchFails = true
        fixture.time += 10
        await model.refresh(manual: true)
        XCTAssertEqual(
            model.series(for: book)?.books.map(\.id), [3, 4],
            "A failed series fetch keeps the cached series")
        saved = dependencies.sourceStore.load()
        XCTAssertEqual(saved.first { $0.source == .hardcover }?.series, [series])
    }

    func testFilteredShelfStillPublishesTheUnfilteredTopShelf() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        func covered(_ id: Int, author: String = "Fictional author") -> Book {
            var book = fixture.book(id)
            book.author = author
            book.coverURL = URL(string: "https://covers.example/\(id).jpg")
            return book
        }
        try fixture.save([fixture.snapshot(.hardcover, books: [covered(1)], age: 86401)])
        fixture.defaults.set(2, forKey: "bookCount")
        var dependencies = fixture.dependencies()
        var library = [covered(1, author: "Filtered author"), covered(2)]
        dependencies.fetchHardcover = { _, _ in
            HardcoverLibrary(accountID: fixture.hardcoverAccountID, books: library)
        }
        let published = OSAllocatedUnfairLock<[Set<Int>]>(initialState: [])
        dependencies.writeTopShelf = { books in
            published.withLock { $0.append(Set(books.map(\.id))) }
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.shelfFilter = .author("Filtered author")
        XCTAssertEqual(model.books.map(\.id), [1])
        library.append(covered(3))
        fixture.time += 10
        await model.refresh(manual: true)
        await model.waitForTopShelf()
        XCTAssertEqual(model.books.map(\.id), [1], "The filter still limits My Shelf")
        XCTAssertEqual(
            published.withLock { $0.last?.count }, 2,
            "A sync during a filter publishes the unfiltered shelf within Books shown")
    }

    func testRejectedHardcoverReplacementRetainsCredentialAndSnapshot() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var validatedTokens: [String] = []
        dependencies.validateHardcover = { token in
            validatedTokens.append(token)
            throw HardcoverError.invalidToken
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let connected = await model.connect("hc_pat_fictional_replacement")
        XCTAssertFalse(connected)
        XCTAssertEqual(validatedTokens, ["hc_pat_fictional_replacement"])
        XCTAssertEqual(
            model.sourceErrors["hardcover"], HardcoverError.invalidToken.localizedDescription)
        XCTAssertEqual(model.message, HardcoverError.invalidToken.localizedDescription)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_original")
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertTrue(model.hardcoverConnected)
        XCTAssertFalse(
            model.hardcoverSessionExpired, "A rejected replacement keeps the saved login")
        XCTAssertEqual(model.connectionRevision, 0)
    }

    func testNewestHardcoverSnapshotSuppliesCoversWhenSameAccountHasStaleCopy() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        var stale = fixture.book(1)
        stale.detailCoverURL = URL(string: "https://example.com/stale.jpg")
        var fresh = fixture.book(1)
        fresh.detailCoverURL = URL(string: "https://example.com/fresh.jpg")
        var staleSnapshot = fixture.snapshot(.hardcover, books: [stale], age: 86_400)
        staleSnapshot.accountID = fixture.hardcoverAccountID
        var freshSnapshot = fixture.snapshot(.hardcover, books: [fresh])
        freshSnapshot.accountID = fixture.hardcoverAccountID
        try fixture.save([staleSnapshot, freshSnapshot])
        let model = LibraryModel(dependencies: fixture.dependencies())
        await model.start()
        XCTAssertEqual(
            model.books.first?.detailCoverURL, fresh.detailCoverURL,
            "The newest snapshot supplies covers even when an older one sorts first")
    }

    func testRejectedSyncMarksSessionExpiredUntilASuccessfulSync() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var rejects = true
        dependencies.fetchHardcover = { _, _ in
            if rejects { throw HardcoverError.invalidToken }
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.refresh(manual: true)
        XCTAssertTrue(model.hardcoverSessionExpired)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_original")
        XCTAssertEqual(model.books.map(\.id), [1])
        rejects = false
        fixture.time += 10
        await model.refresh(manual: true)
        XCTAssertFalse(model.hardcoverSessionExpired)
    }

    func testValidatedHardcoverReplacementPreservesDailySnapshotAndSavesCredential() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var validations = 0
        dependencies.validateHardcover = { token in
            XCTAssertEqual(token, "hc_pat_fictional_replacement")
            validations += 1
            return fixture.hardcoverAccountID
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let connected = await model.connect("hc_pat_fictional_replacement")
        XCTAssertTrue(connected)
        XCTAssertEqual(validations, 1)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_replacement")
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertEqual(model.connectionRevision, 1)
        XCTAssertEqual(dependencies.sourceStore.load().first?.syncedAt, fixture.time)
    }

    func testSyncRenewsAnExpiringTokenAndSpendsEachRefreshTokenOnce() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var spent: [String] = []
        dependencies.refreshHardcoverToken = { refreshToken in
            spent.append(refreshToken)
            return fixture.tokens(spent.count + 1)
        }
        var fetched: [String] = []
        dependencies.fetchHardcover = { token, _ in
            fetched.append(token)
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.refresh(manual: true)
        XCTAssertEqual(spent, ["hc_rt_fictional_1"])
        XCTAssertEqual(fetched, ["hc_at_fictional_2"])
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_at_fictional_2")
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_2")
        XCTAssertEqual(
            fixture.defaults.object(forKey: HardcoverSession.renewalKey) as? Date,
            fixture.time.addingTimeInterval(604_800 - 86_400),
            "A week-long token renews a day before it expires")

        // A token with more than a day left is used as it is.
        fixture.time += 86_400
        await model.refresh(manual: true)
        XCTAssertEqual(spent, ["hc_rt_fictional_1"])

        // The next renewal spends the rotated refresh token, never the spent one.
        fixture.time += 5.5 * 86_400
        await model.refresh(manual: true)
        XCTAssertEqual(spent, ["hc_rt_fictional_1", "hc_rt_fictional_2"])
        XCTAssertEqual(fetched, ["hc_at_fictional_2", "hc_at_fictional_2", "hc_at_fictional_3"])
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_3")
        XCTAssertFalse(model.hardcoverSessionExpired)
    }

    func testRejectedTokenRenewsOnceAndRetriesTheSync() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 5 * 86_400)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var spent: [String] = []
        dependencies.refreshHardcoverToken = { refreshToken in
            spent.append(refreshToken)
            return fixture.tokens(2)
        }
        var fetched: [String] = []
        dependencies.fetchHardcover = { token, _ in
            fetched.append(token)
            if token == "hc_at_fictional_1" { throw HardcoverError.invalidToken }
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.refresh(manual: true)
        XCTAssertEqual(spent, ["hc_rt_fictional_1"])
        XCTAssertEqual(fetched, ["hc_at_fictional_1", "hc_at_fictional_2"])
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertFalse(model.hardcoverSessionExpired)
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_2")
    }

    func testConcurrentSyncsShareOneRenewal() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        // The controlled response fails the test if a second renewal starts while it waits.
        let renewal = ControlledLibraryResponse<HardcoverTokens>("Token renewal started")
        var dependencies = fixture.dependencies()
        var spent: [String] = []
        dependencies.refreshHardcoverToken = { refreshToken in
            spent.append(refreshToken)
            return try await renewal.value()
        }
        var fetched: [String] = []
        dependencies.fetchHardcover = { token, _ in
            fetched.append(token)
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let library = Task { await model.refresh(manual: true) }
        await fulfillment(of: [renewal.started], timeout: 5)
        // The model runs on the main actor, so each task reaches the shared renewal without
        // suspending after it fulfills its expectation, and the test resumes only once both wait.
        let socialJoined = expectation(description: "Social sync waits for the renewal")
        let social = Task {
            socialJoined.fulfill()
            return await model.hardcoverTokenForSync()
        }
        let rejectedJoined = expectation(description: "A rejected request waits for the renewal")
        let rejected = Task {
            rejectedJoined.fulfill()
            return try await model.renewHardcoverToken(rejected: "hc_at_fictional_1")
        }
        await fulfillment(of: [socialJoined, rejectedJoined], timeout: 5)
        renewal.resolve(fixture.tokens(2))
        await library.value
        let socialToken = await social.value
        let renewedToken = try await rejected.value
        XCTAssertEqual(spent, ["hc_rt_fictional_1"])
        XCTAssertEqual(fetched, ["hc_at_fictional_2"])
        XCTAssertEqual(socialToken, "hc_at_fictional_2")
        XCTAssertEqual(renewedToken, "hc_at_fictional_2")
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_2")
    }

    func testRejectedRenewalKeepsAWorkingTokenUntilHardcoverRejectsIt() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var renewals = 0
        dependencies.refreshHardcoverToken = { _ in
            renewals += 1
            throw HardcoverError.invalidToken
        }
        var fetches = 0
        dependencies.fetchHardcover = { token, _ in
            XCTAssertEqual(token, "hc_at_fictional_1")
            fetches += 1
            // Hardcover rejects the access token in the second sync.
            if fetches == 2 { throw HardcoverError.invalidToken }
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        // The access token still works, so the sync succeeds without asking to reconnect.
        await model.refresh(manual: true)
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertFalse(model.hardcoverSessionExpired)

        // The rejected refresh token isn't sent again.
        fixture.time += 10
        let token = await model.hardcoverTokenForSync()
        XCTAssertEqual(token, "hc_at_fictional_1")
        XCTAssertEqual(renewals, 1)

        // Once Hardcover rejects the access token too, Settings shows Reconnect Hardcover, and
        // the login stays saved.
        fixture.time += 10
        await model.refresh(manual: true)
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(renewals, 1)
        XCTAssertTrue(model.hardcoverSessionExpired)
        XCTAssertEqual(
            model.sourceErrors["hardcover"], HardcoverError.invalidToken.localizedDescription)
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_at_fictional_1")
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_1")
    }

    func testRejectedSocialRenewalShowsReconnectAndKeepsTheLogin() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 5 * 86_400)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var renewals = 0
        dependencies.refreshHardcoverToken = { _ in
            renewals += 1
            throw HardcoverError.invalidToken
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        do {
            _ = try await model.renewHardcoverToken(rejected: "hc_at_fictional_1")
            XCTFail("A rejected refresh token must fail.")
        } catch HardcoverError.invalidToken {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(renewals, 1)
        XCTAssertTrue(model.hardcoverSessionExpired)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_at_fictional_1")
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_1")
    }

    func testRejectedTokenWithoutRefreshTokenShowsReconnect() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        // The fixture's renewal fails the test, so this also checks that none starts.
        let model = LibraryModel(dependencies: fixture.dependencies())
        await model.start()
        do {
            _ = try await model.renewHardcoverToken(rejected: "hc_pat_fictional_original")
            XCTFail("A login without a refresh token can't be renewed.")
        } catch HardcoverError.invalidToken {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(model.hardcoverSessionExpired)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_original")
    }

    func testUnavailableRenewalKeepsUsingTheSavedToken() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.refreshHardcoverToken = { _ in throw URLError(.timedOut) }
        var fetched: [String] = []
        dependencies.fetchHardcover = { token, _ in
            fetched.append(token)
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.refresh(manual: true)
        XCTAssertEqual(fetched, ["hc_at_fictional_1"])
        XCTAssertFalse(model.hardcoverSessionExpired)
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_1")
    }

    func testUnreadableRefreshTokenNeverDeletesTheLogin() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var readable = false
        dependencies.readCredential = { account in
            account == HardcoverSession.refreshAccount && !readable ? nil : fixture.secrets[account]
        }
        var spent: [String] = []
        dependencies.refreshHardcoverToken = { refreshToken in
            spent.append(refreshToken)
            return fixture.tokens(2)
        }
        var fetched: [String] = []
        dependencies.fetchHardcover = { token, _ in
            fetched.append(token)
            // Hardcover rejects the second sync's token.
            if fetched.count == 2 { throw HardcoverError.invalidToken }
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        // A failed read can't renew, so the sync uses the saved token as it is.
        await model.refresh(manual: true)
        XCTAssertEqual(fetched, ["hc_at_fictional_1"])
        XCTAssertFalse(model.hardcoverSessionExpired)

        // A rejected token without a readable refresh token shows Reconnect but deletes nothing.
        fixture.time += 10
        await model.refresh(manual: true)
        XCTAssertTrue(model.hardcoverSessionExpired)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_at_fictional_1")
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_1")
        XCTAssertTrue(spent.isEmpty)

        // Once Keychain reads again, the next sync renews and recovers.
        readable = true
        fixture.time += 10
        await model.refresh(manual: true)
        XCTAssertEqual(spent, ["hc_rt_fictional_1"])
        XCTAssertEqual(fetched.last, "hc_at_fictional_2")
        XCTAssertFalse(model.hardcoverSessionExpired)
    }

    func testShortLivedTokenRenewsHalfwayThroughItsLifetime() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var spent: [String] = []
        dependencies.refreshHardcoverToken = { refreshToken in
            spent.append(refreshToken)
            var tokens = fixture.tokens(spent.count + 1)
            tokens.expiresIn = 3_600
            return tokens
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let first = await model.hardcoverTokenForSync()
        let second = await model.hardcoverTokenForSync()
        XCTAssertEqual(first, "hc_at_fictional_2")
        XCTAssertEqual(second, "hc_at_fictional_2")
        XCTAssertEqual(spent, ["hc_rt_fictional_1"], "Back-to-back syncs share one renewal")

        fixture.time += 1_799
        let beforeHalfway = await model.hardcoverTokenForSync()
        XCTAssertEqual(beforeHalfway, "hc_at_fictional_2")
        fixture.time += 1
        let halfway = await model.hardcoverTokenForSync()
        XCTAssertEqual(halfway, "hc_at_fictional_3")
        XCTAssertEqual(spent, ["hc_rt_fictional_1", "hc_rt_fictional_2"])
    }

    func testRotatedTokensThatKeychainRefusesStayInUseForThisLaunch() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var refusesSaves = true
        dependencies.saveCredential = { value, account in
            if refusesSaves { throw CredentialStore.CredentialError.saveFailed }
            fixture.secrets[account] = value
        }
        var spent: [String] = []
        dependencies.refreshHardcoverToken = { refreshToken in
            spent.append(refreshToken)
            return fixture.tokens(spent.count + 1)
        }
        var fetched: [String] = []
        dependencies.fetchHardcover = { token, _ in
            fetched.append(token)
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.refresh(manual: true)
        XCTAssertEqual(fetched, ["hc_at_fictional_2"])
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_1")

        // While Keychain still refuses, the unsaved pair's own schedule applies, so the next
        // boundary doesn't renew again.
        fixture.time += 10
        let unsavedToken = await model.hardcoverTokenForSync()
        XCTAssertEqual(unsavedToken, "hc_at_fictional_2")
        XCTAssertEqual(spent, ["hc_rt_fictional_1"])

        // The next boundary saves the rotated pair instead of spending the old token again.
        refusesSaves = false
        fixture.time += 10
        let token = await model.hardcoverTokenForSync()
        XCTAssertEqual(token, "hc_at_fictional_2")
        XCTAssertEqual(spent, ["hc_rt_fictional_1"])
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_at_fictional_2")
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_2")
        XCTAssertEqual(
            fixture.defaults.object(forKey: HardcoverSession.renewalKey) as? Date,
            fixture.time.addingTimeInterval(518_400 - 20), "The schedule counts from the renewal")
    }

    func testDisconnectDuringRenewalKeepsTheLoginRemoved() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let renewal = ControlledLibraryResponse<HardcoverTokens>("Token renewal started")
        var dependencies = fixture.dependencies()
        dependencies.refreshHardcoverToken = { _ in try await renewal.value() }
        let revoked = expectation(description: "Disconnecting revokes the login")
        var revocations: [String] = []
        dependencies.revokeHardcoverToken = { refreshToken in
            revocations.append(refreshToken)
            if revocations.count == 1 { revoked.fulfill() }
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let social = Task { await model.hardcoverTokenForSync() }
        await fulfillment(of: [renewal.started], timeout: 5)
        model.disconnect()
        await fulfillment(of: [revoked], timeout: 5)
        renewal.resolve(fixture.tokens(2))
        let token = await social.value
        XCTAssertNil(token)
        XCTAssertEqual(
            revocations, ["hc_rt_fictional_1", "hc_rt_fictional_2"],
            "The refresh token the renewal rotated is revoked too")
        XCTAssertNil(fixture.secrets["hardcover-token"])
        XCTAssertNil(fixture.secrets["hardcover-refresh-token"])
        XCTAssertNil(fixture.defaults.object(forKey: HardcoverSession.renewalKey))
    }

    func testDisconnectRevokesTheLoginEvenIfHardcoverIsUnreachable() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 5 * 86_400)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        let revoked = expectation(description: "Disconnecting revokes the login")
        var revocations: [String] = []
        dependencies.revokeHardcoverToken = { refreshToken in
            revocations.append(refreshToken)
            revoked.fulfill()
            throw URLError(.notConnectedToInternet)
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.disconnect()
        XCTAssertNil(fixture.secrets["hardcover-token"])
        XCTAssertNil(fixture.secrets["hardcover-refresh-token"])
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertEqual(revocations, ["hc_rt_fictional_1"])
        XCTAssertFalse(model.hardcoverConnected)
        XCTAssertFalse(model.hardcoverSessionExpired)
    }

    func testTokenWithoutRefreshReplacesTheSavedRefreshToken() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 3_600)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let connected = await model.connect("hc_pat_fictional_replacement")
        XCTAssertTrue(connected)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_replacement")
        XCTAssertNil(fixture.secrets["hardcover-refresh-token"])
        XCTAssertNil(fixture.defaults.object(forKey: HardcoverSession.renewalKey))
    }

    func testDisablingSourceRejectsHeldCredentialValidation() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let response = ControlledLibraryResponse<Void>("Credential validation started")
        var dependencies = fixture.dependencies()
        dependencies.validateHardcover = { _ in
            try await response.value()
            return fixture.hardcoverAccountID
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let completed = expectation(description: "Connection attempt returned")
        let work = Task {
            let connected = await model.connect("hc_pat_fictional_replacement")
            completed.fulfill()
            return connected
        }
        await fulfillment(of: [response.started], timeout: 5)
        model.hardcoverEnabled = false
        response.resolve(())
        await fulfillment(of: [completed], timeout: 5)
        let connected = await work.value
        XCTAssertFalse(connected)
        XCTAssertFalse(model.hardcoverEnabled)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_original")
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertEqual(model.connectionRevision, 0)
    }

    func testDeviceAuthFlowConnectsSuccessfully() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeValue(forKey: "hardcover-token")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var validations = 0
        dependencies.validateHardcover = { token in
            XCTAssertEqual(token, "hc_at_fictional_replacement")
            validations += 1
            return fixture.hardcoverAccountID
        }
        let auth = HardcoverDeviceAuth(
            deviceCode: "fixture_device_code",
            userCode: "TEST-CODE",
            verificationURI: URL(string: "https://hardcover.app/link")!,
            verificationURIComplete: URL(string: "https://hardcover.app/link?c=TESTCODE")!,
            expiresIn: 900,
            interval: 1
        )
        dependencies.requestHardcoverDeviceAuth = { auth }
        var pollCount = 0
        dependencies.pollHardcoverDeviceToken = { code in
            pollCount += 1
            if pollCount == 1 { return .pending }
            return .success(
                HardcoverTokens(
                    accessToken: "hc_at_fictional_replacement",
                    refreshToken: "hc_rt_fictional_replacement", expiresIn: 604_800))
        }
        dependencies.sleep = { _ in }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertFalse(model.hardcoverConnected)
        model.startHardcoverDeviceAuth()
        // Polling uses the injected no-op sleep, so yielding lets the task finish without real time.
        for _ in 0..<1000 where !model.hardcoverConnected { await Task.yield() }
        XCTAssertTrue(model.hardcoverConnected)
        XCTAssertEqual(validations, 1)
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_at_fictional_replacement")
        XCTAssertEqual(fixture.secrets["hardcover-refresh-token"], "hc_rt_fictional_replacement")
        XCTAssertEqual(
            fixture.defaults.object(forKey: HardcoverSession.renewalKey) as? Date,
            fixture.time.addingTimeInterval(518_400))
    }

    func testDeviceApprovalDuringCWARefreshClearsConsumedCodeAndOffersRetry() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeValue(forKey: "hardcover-token")
        fixture.secrets["cwa-password"] = "fictional-password"
        fixture.defaults.set(true, forKey: "cwaEnabled")
        try fixture.save([fixture.snapshot(.cwa, books: [fixture.book(1)])])
        let authorization = ControlledLibraryResponse<HardcoverDevicePollResult>(
            "Device approval requested")
        let download = ControlledLibraryResponse<[Book]>("CWA refresh started")
        var dependencies = fixture.dependencies()
        dependencies.fetchCWA = { _, _ in try await download.value() }
        dependencies.requestHardcoverDeviceAuth = {
            HardcoverDeviceAuth(
                deviceCode: "fixture_device_code", userCode: "TEST-CODE",
                verificationURI: URL(string: "https://hardcover.app/link")!,
                verificationURIComplete: URL(string: "https://hardcover.app/link?c=TESTCODE")!,
                expiresIn: 900, interval: 1)
        }
        dependencies.pollHardcoverDeviceToken = { _ in try await authorization.value() }
        dependencies.sleep = { _ in }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.startHardcoverDeviceAuth()
        await fulfillment(of: [authorization.started], timeout: 5)
        let refresh = Task { await model.refresh(manual: true) }
        await fulfillment(of: [download.started], timeout: 5)
        XCTAssertTrue(model.isLoading)
        let retryShown = expectation(description: "Consumed device code replaced by retry")
        withObservationTracking {
            _ = model.hardcoverDeviceAuthMessage
        } onChange: {
            retryShown.fulfill()
        }

        authorization.resolve(
            .success(HardcoverTokens(accessToken: "hc_pat_fictional_replacement")))
        await fulfillment(of: [retryShown], timeout: 5)

        XCTAssertNil(model.hardcoverDeviceAuth)
        XCTAssertFalse(model.hardcoverDeviceAuthLoading)
        XCTAssertEqual(
            model.hardcoverDeviceAuthMessage,
            "A library sync is finishing. Request a new link code to connect.")
        XCTAssertFalse(model.hardcoverConnected)
        XCTAssertNil(fixture.secrets["hardcover-token"])
        XCTAssertNil(model.hardcoverConnectionPhase)
        download.resolve([fixture.book(2)])
        await refresh.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertEqual(dependencies.sourceStore.load().map(\.source), [.cwa])
        XCTAssertNotNil(
            model.hardcoverDeviceAuthMessage, "Finishing the refresh must preserve retry.")
    }

    func testRejectedCWAReplacementRetainsAccountAndCredential() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "cwaEnabled")
        fixture.secrets["cwa-password"] = "fictional-original"
        try fixture.save([fixture.snapshot(.cwa, books: [fixture.book(2)], age: 86401)])
        var dependencies = fixture.dependencies()
        var requestedConfigurations: [CWAConfiguration] = []
        var requestedPasswords: [String] = []
        dependencies.fetchCWA = { configuration, password in
            requestedConfigurations.append(configuration)
            requestedPasswords.append(password)
            throw SourceError.credentials
        }
        // Startup displays the cache without attempting a disconnected Hardcover request.
        fixture.secrets.removeValue(forKey: "hardcover-token")
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertEqual(requestedConfigurations, [fixture.configuration])
        XCTAssertEqual(requestedPasswords, ["fictional-original"])
        fixture.time += 300
        let replacement = CWAConfiguration(server: "https://replacement.invalid", username: "other")
        let connected = await model.connectCWA(replacement, password: "fictional-replacement")
        XCTAssertFalse(connected)
        XCTAssertEqual(requestedConfigurations, [fixture.configuration, replacement])
        XCTAssertEqual(requestedPasswords, ["fictional-original", "fictional-replacement"])
        XCTAssertEqual(model.sourceErrors["cwa"], SourceError.credentials.localizedDescription)
        XCTAssertEqual(model.message, SourceError.credentials.localizedDescription)
        XCTAssertEqual(model.cwaConfiguration, fixture.configuration)
        XCTAssertEqual(fixture.secrets["cwa-password"], "fictional-original")
        XCTAssertEqual(model.books.map(\.id), [2])
    }

    func testPreferencesAndEnabledSourcesPersistAndChangeVisibleBooks() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([
            fixture.snapshot(.hardcover, books: [fixture.book(1, title: "Zebra")]),
            fixture.snapshot(.cwa, books: [fixture.book(2, title: "Apple")]),
        ])
        let model = LibraryModel(dependencies: fixture.dependencies())
        await model.start()
        XCTAssertEqual(model.books.map(\.id), [1])
        model.cwaEnabled = true
        model.shelfPreferences = ShelfPreferences(collection: .all, sort: .title)
        XCTAssertEqual(model.books.map(\.id), [2, 1])
        model.hardcoverEnabled = false
        model.bookCount = 1
        XCTAssertEqual(model.books.map(\.id), [2])
        let restored = LibraryModel(dependencies: fixture.dependencies())
        await restored.start()
        XCTAssertEqual(restored.books.map(\.id), [2])
        XCTAssertFalse(restored.hardcoverEnabled)
        XCTAssertTrue(restored.cwaEnabled)
        XCTAssertEqual(restored.shelfPreferences.sort, .title)
        XCTAssertEqual(restored.bookCount, 1)
    }

    func testInjectedClockDrivesDailyRefreshAndManualCooldown() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var fetches = 0
        dependencies.fetchHardcover = { _, _ in
            fetches += 1
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(fetches + 1)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        fixture.time += 86399
        await model.becameActive()
        XCTAssertEqual(fetches, 0)
        fixture.time += 1
        await model.becameActive()
        XCTAssertEqual(fetches, 1)
        await model.refresh(manual: true)
        XCTAssertEqual(fetches, 2)
        fixture.time += 9
        await model.refresh(manual: true)
        XCTAssertEqual(fetches, 2)
        fixture.time += 1
        await model.refresh(manual: true)
        XCTAssertEqual(fetches, 3)
        XCTAssertEqual(model.syncedAt, fixture.time)
        XCTAssertEqual(model.books.map(\.id), [4])
    }

    func testChangingCWAAccountRejectsHeldResponse() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "cwaEnabled")
        fixture.defaults.set(false, forKey: "hardcoverEnabled")
        fixture.secrets["cwa-password"] = "fictional-password"
        try fixture.save([fixture.snapshot(.cwa, books: [fixture.book(1)])])
        let response = ControlledLibraryResponse<[Book]>("CWA request started")
        var dependencies = fixture.dependencies()
        dependencies.fetchCWA = { configuration, _ in
            XCTAssertEqual(configuration, fixture.configuration)
            return try await response.value()
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let completed = expectation(description: "Refresh returned")
        let work = Task {
            await model.refresh(manual: true)
            completed.fulfill()
        }
        await fulfillment(of: [response.started], timeout: 5)
        model.cwaConfiguration = CWAConfiguration(
            server: "https://other.invalid", username: "other")
        response.resolve([fixture.book(99)])
        await fulfillment(of: [completed], timeout: 5)
        await work.value
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertEqual(
            dependencies.sourceStore.load().first?.accountID, fixture.configuration.identity)
        XCTAssertEqual(dependencies.sourceStore.load().first?.books.map(\.id), [1])
        XCTAssertNil(model.sourceErrors["cwa"])
    }

    func testDisablingSourceRejectsHeldRefreshWithoutReplacingSavedBooks() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let response = ControlledLibraryResponse<HardcoverLibrary>("Hardcover request started")
        var dependencies = fixture.dependencies()
        dependencies.fetchHardcover = { _, _ in try await response.value() }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let completed = expectation(description: "Refresh returned")
        let work = Task {
            await model.refresh(manual: true)
            completed.fulfill()
        }
        await fulfillment(of: [response.started], timeout: 5)
        model.hardcoverEnabled = false
        response.resolve(
            HardcoverLibrary(accountID: fixture.hardcoverAccountID, books: [fixture.book(99)]))
        await fulfillment(of: [completed], timeout: 5)
        await work.value
        XCTAssertTrue(model.books.isEmpty)
        model.hardcoverEnabled = true
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertEqual(dependencies.sourceStore.load().first?.books.map(\.id), [1])
    }

    func testCancellationRejectsHeldRefresh() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let response = ControlledLibraryResponse<HardcoverLibrary>("Request started")
        var dependencies = fixture.dependencies()
        dependencies.fetchHardcover = { _, _ in try await response.value() }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let completed = expectation(description: "Cancelled refresh returned")
        let work = Task {
            await model.refresh(manual: true)
            completed.fulfill()
        }
        await fulfillment(of: [response.started], timeout: 5)
        work.cancel()
        response.resolve(
            HardcoverLibrary(accountID: fixture.hardcoverAccountID, books: [fixture.book(99)]))
        await fulfillment(of: [completed], timeout: 5)
        await work.value
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.sourceErrors["hardcover"])
    }

    func testCloudFailureRetainsLocalDataAndReportsFailure() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertTrue(model.cloudStatus.contains("Local data is retained"))
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertEqual(dependencies.sourceStore.load().first?.books.map(\.id), [1])
    }

    func testCloudSyncKeepsNewestSnapshot() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let stale = fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86_400)
        let current = fixture.snapshot(.hardcover, books: [fixture.book(2)])
        try fixture.save([stale, current])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in CloudLibraryArchive(sources: [stale, current]) }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(model.books.map(\.id), [2])
    }

    func testOfflineLaunchReadsCompanionCacheFromCompleteLocalSnapshot() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.set(1, forKey: "bookCount")
        try fixture.save([
            fixture.snapshot(.hardcover, books: [fixture.book(1), fixture.book(2)])
        ])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        let cacheRead = expectation(description: "Companion cache read on offline launch")
        var requestedIDs: [Int] = []
        dependencies.fetchSpineDesigns = { accountID, books in
            XCTAssertEqual(accountID, fixture.hardcoverAccountID)
            requestedIDs = books.map(\.id).sorted()
            cacheRead.fulfill()
            return ([:], true)
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await fulfillment(of: [cacheRead], timeout: 5)
        XCTAssertEqual(model.books.count, 1)
        XCTAssertEqual(requestedIDs, [1, 2])
        XCTAssertTrue(model.cloudStatus.contains("Local data is retained"))
    }

    func testCompanionCoverChoiceLeadsDisplayedCoversWithoutChangingDesignInputs() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let detail = URL(string: "https://covers.example.test/detail.jpg")!
        let catalog = URL(string: "https://covers.example.test/catalog.jpg")!
        let chosen = URL(string: "https://covers.example.test/chosen.jpg")!
        var first = fixture.book(1)
        first.detailCoverURL = detail
        first.coverURL = catalog
        try fixture.save([fixture.snapshot(.hardcover, books: [first, fixture.book(2)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        var designBooks: [Book] = []
        dependencies.fetchSpineDesigns = { _, books in
            designBooks = books
            return ([:], true)
        }
        dependencies.fetchCoverChoices = { accountID, _ in
            (
                [
                    1: CoverChoiceV1(
                        version: 1, accountID: accountID, bookID: 1, coverURL: chosen,
                        chosenAt: fixture.time)
                ], true
            )
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await model.waitForCompanionRecords()
        let shown = try XCTUnwrap(model.books.first { $0.id == 1 })
        XCTAssertEqual(shown.coverURLs, [chosen, detail, catalog])
        XCTAssertNil(model.books.first { $0.id == 2 }?.chosenCoverURL)
        XCTAssertEqual(designBooks.first { $0.id == 1 }?.coverURLs, [detail, catalog])

        // Companion choices apply only with iCloud storage on.
        model.iCloudEnabled = false
        XCTAssertEqual(model.books.first { $0.id == 1 }?.coverURLs, [detail, catalog])
        XCTAssertTrue(model.spineDesigns.isEmpty)
    }

    func testSeriesLooksDrawForMembersAndAMissingLookCopiesTheEarliestDesign() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let books = (1...3)
            .map { id in
                var book = fixture.book(id)
                book.seriesID = 7
                book.seriesPosition = Double(id)
                return book
            }
        try fixture.save([fixture.snapshot(.hardcover, books: books)])
        func design(_ id: Int, hex: String, day: Double) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: fixture.hardcoverAccountID, bookID: id,
                workItemHash: SpineCloudIdentity.workItemHash(
                    accountID: fixture.hardcoverAccountID, book: books[id - 1]),
                coverHash: String(repeating: "a", count: 64), generatorVersion: "ios-pcc-v2",
                generatedAt: Date(timeIntervalSince1970: day * 86_400), backgroundHex: hex,
                foregroundHex: "#FFFFFF", accentHex: "#FFFFFF", typeface: "serif",
                weight: 700, uppercase: false)
        }
        let designs = [1: design(1, hex: "#102030", day: 2), 2: design(2, hex: "#203040", day: 1)]
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        dependencies.fetchSpineDesigns = { _, _ in (designs, true) }
        var requestedKeys: [SeriesLookKey] = []
        dependencies.fetchSeriesLooks = { _, keys in
            requestedKeys = keys
            return [:]
        }
        var created: [SeriesLookV1] = []
        dependencies.createSeriesLook = { look in
            created.append(look)
            return look
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await model.waitForCompanionRecords()

        let key = SeriesLookKey(seriesID: 7, group: "|fictionalauthor")
        XCTAssertEqual(requestedKeys, [key])
        XCTAssertEqual(created.map(\.sourceBookID), [2], "The earliest design decides the look")
        XCTAssertEqual(created.first?.createdAt, fixture.time)
        XCTAssertEqual(
            (1...3).map { model.lookDesigns[$0]?.backgroundHex },
            Array(repeating: "#203040", count: 3))
        XCTAssertTrue(model.seriesSources.isEmpty, "Books with a look borrow no other design")
    }

    func testMissingLooksSkipBooksThatKeepTheirOwnLookAndWaitForACompleteRead() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let books = (1...3)
            .map { id in
                var book = fixture.book(id)
                book.seriesID = 7
                book.seriesPosition = Double(id)
                return book
            }
        try fixture.save([fixture.snapshot(.hardcover, books: books)])
        func design(_ id: Int, day: Double) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: fixture.hardcoverAccountID, bookID: id,
                workItemHash: SpineCloudIdentity.workItemHash(
                    accountID: fixture.hardcoverAccountID, book: books[id - 1]),
                coverHash: String(repeating: "a", count: 64), generatorVersion: "ios-pcc-v2",
                generatedAt: Date(timeIntervalSince1970: day * 86_400), backgroundHex: "#102030",
                foregroundHex: "#FFFFFF", accentHex: "#FFFFFF", typeface: "serif",
                weight: 700, uppercase: false)
        }
        // Book 1 keeps its own look, so its earlier design must not become the group's.
        let designs = [1: design(1, day: 1), 2: design(2, day: 2)]
        let link = SeriesLinkV1(
            accountID: fixture.hardcoverAccountID, bookID: 1, ownLook: true,
            chosenAt: fixture.time)
        for isComplete in [false, true] {
            var dependencies = fixture.dependencies()
            dependencies.sleep = { _ in }
            dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
            dependencies.fetchSpineDesigns = { _, _ in (designs, isComplete) }
            dependencies.fetchSeriesLinks = { _, _ in ([1: link], true) }
            var created: [SeriesLookV1] = []
            dependencies.createSeriesLook = { look in
                created.append(look)
                return look
            }
            let model = LibraryModel(dependencies: dependencies)
            await model.start()
            await model.waitForCloudSync()
            await model.waitForCompanionRecords()
            XCTAssertEqual(
                created.map(\.sourceBookID), isComplete ? [2] : [],
                "Only a complete read creates looks")
        }
    }

    func testAFailedLookSaveDoesNotStopTheOtherGroups() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        // Books 1 and 2 are in series 7, books 3 and 4 in series 8.
        let books = (1...4)
            .map { id in
                var book = fixture.book(id)
                book.seriesID = id <= 2 ? 7 : 8
                book.seriesPosition = Double(id)
                return book
            }
        try fixture.save([fixture.snapshot(.hardcover, books: books)])
        func design(_ id: Int) -> SpineDesignV1 {
            SpineDesignV1(
                version: 1, accountID: fixture.hardcoverAccountID, bookID: id,
                workItemHash: SpineCloudIdentity.workItemHash(
                    accountID: fixture.hardcoverAccountID, book: books[id - 1]),
                coverHash: String(repeating: "a", count: 64), generatorVersion: "ios-pcc-v2",
                generatedAt: Date(timeIntervalSince1970: 86_400), backgroundHex: "#102030",
                foregroundHex: "#FFFFFF", accentHex: "#FFFFFF", typeface: "serif",
                weight: 700, uppercase: false)
        }
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        dependencies.fetchSpineDesigns = { _, _ in ([1: design(1), 3: design(3)], true) }
        var attempted: [Int] = []
        dependencies.createSeriesLook = { look in
            attempted.append(look.seriesID)
            if look.seriesID == 7 { throw CloudStorageError.temporarilyUnavailable }
            return look
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await model.waitForCompanionRecords()

        XCTAssertEqual(attempted, [7, 8], "Each group's save is tried")
        XCTAssertNil(model.lookDesigns[1], "A failed save leaves its group without a look")
        XCTAssertEqual(model.lookDesigns[3]?.bookID, 3)
        XCTAssertEqual(model.lookDesigns[4]?.bookID, 4)
    }

    func testCloudWorklistUsesCompleteHardcoverSnapshotAndClearsWhenDisabled() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.set(1, forKey: "bookCount")
        try fixture.save([
            fixture.snapshot(
                .hardcover, books: [fixture.book(3), fixture.book(1), fixture.book(2)])
        ])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { $0 }
        // The fixture fails any Hardcover validation: publishing must not call the API.
        var published: [SpineWorklistV1] = []
        dependencies.publishSpineWorklist = { published.append($0) }
        let designFetch = expectation(description: "Complete Hardcover design cache requested")
        let cachePrune = expectation(description: "Companion design cache cleared when disabled")
        var requestedDesignIDs: [Int] = []
        var didFulfillDesignFetch = false
        var didFulfillCachePrune = false
        dependencies.fetchSpineDesigns = { accountID, books in
            if accountID.isEmpty {
                XCTAssertTrue(books.isEmpty)
                if !didFulfillCachePrune {
                    didFulfillCachePrune = true
                    cachePrune.fulfill()
                }
                return ([:], true)
            }
            XCTAssertEqual(accountID, fixture.hardcoverAccountID)
            requestedDesignIDs = books.map(\.id).sorted()
            XCTAssertEqual(requestedDesignIDs, [1, 2, 3])
            if !didFulfillDesignFetch {
                didFulfillDesignFetch = true
                designFetch.fulfill()
            }
            return ([:], true)
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await fulfillment(of: [designFetch], timeout: 5)
        XCTAssertEqual(model.books.count, 1)
        XCTAssertEqual(published.last?.accountID, fixture.hardcoverAccountID)
        XCTAssertEqual(published.last?.bookIDs, [1, 2, 3])
        XCTAssertEqual(requestedDesignIDs, [1, 2, 3])

        model.hardcoverEnabled = false
        await model.waitForCloudSync()
        await fulfillment(of: [cachePrune], timeout: 5)
        XCTAssertEqual(published.last?.bookIDs, [])
    }

    func testCloudRestoreChoosesWorklistAccountWithoutLocalCredential() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        fixture.secrets.removeValue(forKey: "hardcover-token")
        let old = SourceSnapshot(
            source: .hardcover, accountID: "old-account", books: [fixture.book(1)],
            syncedAt: fixture.time.addingTimeInterval(1))
        let active = SourceSnapshot(
            source: .hardcover, accountID: "active-account", books: [fixture.book(2)],
            syncedAt: fixture.time)
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in CloudLibraryArchive(sources: [old, active]) }
        dependencies.readSpineWorklist = {
            SpineWorklistV1(
                accountID: "active-account", syncedAt: active.syncedAt, bookIDs: [2])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertEqual(
            fixture.defaults.string(forKey: "activeHardcoverAccountID"), "active-account")
    }

    func testCredentialFreeRestorePreservesRemoteEmptyWorklist() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        fixture.secrets.removeValue(forKey: "hardcover-token")
        let snapshot = SourceSnapshot(
            source: .hardcover, accountID: "restored-account", books: [fixture.book(1)],
            syncedAt: fixture.time)
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in CloudLibraryArchive(sources: [snapshot]) }
        dependencies.readSpineWorklist = {
            SpineWorklistV1(
                accountID: "restored-account", syncedAt: snapshot.syncedAt, bookIDs: [])
        }
        var published: [SpineWorklistV1] = []
        dependencies.publishSpineWorklist = { published.append($0) }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertTrue(published.isEmpty)
    }

    func testSnapshotInstalledDuringWorklistReadSurvivesCloudSync() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.set(true, forKey: "cwaEnabled")
        fixture.secrets["cwa-password"] = "fictional-password"
        fixture.secrets.removeValue(forKey: "hardcover-token")
        try fixture.save([fixture.snapshot(.cwa, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { $0 }
        dependencies.fetchCWA = { _, _ in [fixture.book(5)] }
        var model: LibraryModel!
        var reads = 0
        dependencies.readSpineWorklist = {
            reads += 1
            // A newer CWA snapshot lands while the cloud task awaits the worklist read.
            if reads == 1 {
                fixture.time = fixture.time.addingTimeInterval(60)
                await model.refresh(manual: true)
            }
            return nil
        }
        model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.books.map(\.id), [5])
        XCTAssertEqual(
            dependencies.sourceStore.load().first { $0.source == .cwa }?.books.map(\.id), [5])
        XCTAssertTrue(model.cloudStatus.contains("Saved to iCloud"))
    }

    func testWorklistMatchesUploadedArchiveWhenSnapshotChangesDuringSync() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let uploadedAt = fixture.time
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.fetchHardcover = { _, _ in
            HardcoverLibrary(accountID: fixture.hardcoverAccountID, books: [fixture.book(9)])
        }
        var model: LibraryModel!
        var uploads = 0
        dependencies.syncCloud = { archive in
            uploads += 1
            // A newer Hardcover snapshot lands while the archive upload is in flight.
            if uploads == 1 {
                fixture.time = fixture.time.addingTimeInterval(60)
                await model.refresh(manual: true)
            }
            return archive
        }
        var published: [SpineWorklistV1] = []
        dependencies.publishSpineWorklist = { published.append($0) }
        model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(published.map(\.syncedAt), [uploadedAt, uploadedAt.addingTimeInterval(60)])
        XCTAssertEqual(published.map(\.bookIDs), [[1], [9]])
        XCTAssertEqual(model.books.map(\.id), [9])
    }

    func testExpiredHardcoverSessionCannotPublishWorklist() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86401)])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { $0 }
        dependencies.fetchHardcover = { _, _ in throw HardcoverError.invalidToken }
        var published: [SpineWorklistV1] = []
        dependencies.publishSpineWorklist = { published.append($0) }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(model.hardcoverSessionExpired)
        XCTAssertEqual(model.books.map(\.id), [1])

        model.iCloudEnabled = true
        await model.waitForCloudSync()
        XCTAssertTrue(model.cloudStatus.contains("Saved to iCloud"))
        XCTAssertTrue(published.isEmpty)
    }

    func testSwitchingBackToSavedHardcoverAccountRequiresCompleteFetch() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(
            fixture.time.addingTimeInterval(1), forKey: "syncAttempt.hardcover")
        try fixture.save([
            fixture.snapshot(.hardcover, books: [fixture.book(1)]),
            SourceSnapshot(
                source: .hardcover, accountID: "other-account", books: [fixture.book(2)],
                syncedAt: fixture.time),
        ])
        var dependencies = fixture.dependencies()
        dependencies.validateHardcover = { _ in "other-account" }
        var fetches = 0
        dependencies.fetchHardcover = { _, _ in
            fetches += 1
            return HardcoverLibrary(accountID: "other-account", books: [fixture.book(3)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertEqual(model.books.map(\.id), [1])
        XCTAssertFalse(
            SourceSyncSchedule(defaults: fixture.defaults)
                .isDue(
                    .hardcover, now: fixture.time, hasSnapshot: false))
        let connected = await model.connect("hc_pat_fictional_replacement")
        XCTAssertTrue(connected)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(model.books.map(\.id), [3])
        XCTAssertEqual(fixture.defaults.string(forKey: "activeHardcoverAccountID"), "other-account")
    }

    func testCloudAccountChangeRejectsOldReplyAfterNewSyncCompletes() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let old = ControlledLibraryResponse<CloudLibraryArchive>("Old cloud account requested")
        let current = ControlledLibraryResponse<CloudLibraryArchive>("New cloud account requested")
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        var calls = 0
        dependencies.syncCloud = { _ in
            calls += 1
            return try await (calls == 1 ? old : current).value()
        }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await fulfillment(of: [old.started], timeout: 5)
        let waiting = expectation(description: "Old sync observed")
        let oldFinished = expectation(description: "Old sync finished")
        let oldWaiter = Task {
            waiting.fulfill()
            await model.waitForCloudSync()
            oldFinished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 5)
        model.cloudAccountChanged()
        model.iCloudEnabled = true
        await fulfillment(of: [current.started], timeout: 5)
        current.resolve(
            CloudLibraryArchive(sources: [
                fixture.snapshot(.hardcover, books: [fixture.book(2)], age: -1)
            ]))
        await model.waitForCloudSync()
        XCTAssertEqual(model.books.map(\.id), [2])
        let currentStatus = model.cloudStatus
        old.resolve(
            CloudLibraryArchive(sources: [
                fixture.snapshot(.hardcover, books: [fixture.book(99)], age: -2)
            ]))
        await fulfillment(of: [oldFinished], timeout: 5)
        await oldWaiter.value
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertEqual(model.cloudStatus, currentStatus)
        XCTAssertEqual(dependencies.sourceStore.load().first?.books.map(\.id), [2])
    }

    func testCloudDebounceCanBeReleasedWithoutRealTimeAndCancelsWhenDisabled() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let delay = ControlledLibraryResponse<Void>("Cloud debounce scheduled")
        var dependencies = fixture.dependencies()
        dependencies.sleep = { duration in
            XCTAssertEqual(duration, .seconds(2))
            try await delay.value()
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        // Turning storage on queues a debounced sync; the launch sync starts without one.
        model.iCloudEnabled = true
        await fulfillment(of: [delay.started], timeout: 5)
        let waiting = expectation(description: "Waiting for scheduled cloud sync")
        let completed = expectation(description: "Cancelled cloud sync returned")
        let work = Task {
            waiting.fulfill()
            await model.waitForCloudSync()
            completed.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 5)
        model.iCloudEnabled = false
        delay.resolve(())
        await fulfillment(of: [completed], timeout: 5)
        await work.value
        XCTAssertTrue(model.cloudStatus.contains("storage is off"))
        XCTAssertEqual(model.books.map(\.id), [1])
    }

    func testFreshICloudSnapshotOfTheActiveAccountSkipsTheDueFetch() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86_401)])
        // Another device synced the account an hour ago. The fixture fails any Hardcover
        // request, so the due check must end with the iCloud read.
        let remote = fixture.snapshot(.hardcover, books: [fixture.book(2)], age: 3_600)
        var dependencies = fixture.dependencies()
        dependencies.sleep = { duration in
            // The 10-second limit on the read never elapses; the model cancels it.
            if duration == .seconds(10) { try await Task.sleep(for: .seconds(3_600)) }
        }
        var reads = 0
        dependencies.syncCloud = { _ in
            reads += 1
            return CloudLibraryArchive(sources: [remote])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(model.books.map(\.id), [2])
        XCTAssertEqual(
            fixture.defaults.object(forKey: "syncSuccess.hardcover") as? Date, remote.syncedAt)
        XCTAssertEqual(reads, 1, "The read before the fetch replaces the read after the check")
    }

    func testICloudReadBeforeAFetchRechecksEachSource() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.set(true, forKey: "cwaEnabled")
        fixture.secrets["cwa-password"] = "fictional-password"
        try fixture.save([
            fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86_401),
            fixture.snapshot(.cwa, books: [fixture.book(4)], age: 86_401),
        ])
        // iCloud holds a fresh Hardcover copy, so only CWA is still due. The fixture fails any
        // Hardcover request.
        let remote = fixture.snapshot(.hardcover, books: [fixture.book(2)], age: 3_600)
        var dependencies = fixture.dependencies()
        dependencies.sleep = { duration in
            if duration == .seconds(10) { try await Task.sleep(for: .seconds(3_600)) }
        }
        var reads = 0
        dependencies.syncCloud = { archive in
            reads += 1
            return reads == 1 ? CloudLibraryArchive(sources: [remote]) : archive
        }
        var cwaFetches = 0
        dependencies.fetchCWA = { _, _ in
            cwaFetches += 1
            return [fixture.book(5)]
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(cwaFetches, 1)
        XCTAssertEqual(Set(model.books.map(\.id)), [2, 5])
    }

    func testACredentialFreeRestoreDoesNotWaitForICloudOnActivation() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.secrets = [:]
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86_401)])
        let read = ControlledLibraryResponse<CloudLibraryArchive>("iCloud read started")
        var dependencies = fixture.dependencies()
        var waits: [Duration] = []
        dependencies.sleep = { waits.append($0) }
        dependencies.syncCloud = { _ in try await read.value() }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await fulfillment(of: [read.started], timeout: 5)
        // No source can fetch, so activation doesn't hold `isLoading` through the read.
        await model.becameActive()
        XCTAssertFalse(waits.contains(.seconds(10)))
        XCTAssertFalse(model.isLoading)

        read.resolve(CloudLibraryArchive())
        await model.waitForCloudSync()
        XCTAssertEqual(model.books.map(\.id), [1])
    }

    func testStaleICloudSnapshotLeadsToOneFetchAndAnUpload() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 100_000)])
        // Another device's copy is newer than this one's, but 25 hours old.
        let remote = fixture.snapshot(.hardcover, books: [fixture.book(2)], age: 90_000)
        var dependencies = fixture.dependencies()
        dependencies.sleep = { duration in
            if duration == .seconds(10) { try await Task.sleep(for: .seconds(3_600)) }
        }
        var uploads: [CloudLibraryArchive] = []
        dependencies.syncCloud = { archive in
            uploads.append(archive)
            return uploads.count == 1 ? CloudLibraryArchive(sources: [remote]) : archive
        }
        var previous: [SourceSnapshot?] = []
        dependencies.fetchHardcover = { _, snapshot in
            previous.append(snapshot)
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(3)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(
            previous.map { $0?.books.map(\.id) }, [[2]],
            "One fetch, which keeps the covers of the newest copy")
        XCTAssertEqual(uploads.count, 2, "The read, then the fetched snapshot's upload")
        XCTAssertEqual(uploads.last?.sources.map { $0.books.map(\.id) }, [[3]])
        XCTAssertEqual(model.books.map(\.id), [3])
    }

    func testAnUnansweredICloudReadDelaysTheDueFetchByTenSecondsAtMost() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86_401)])
        let read = ControlledLibraryResponse<CloudLibraryArchive>("iCloud read started")
        var dependencies = fixture.dependencies()
        // Each wait elapses at once, so the read's 10-second limit passes before it answers.
        var waits: [Duration] = []
        dependencies.sleep = { waits.append($0) }
        var archives: [CloudLibraryArchive] = []
        dependencies.syncCloud = { archive in
            archives.append(archive)
            return archives.count == 1 ? try await read.value() : archive
        }
        var fetches = 0
        dependencies.fetchHardcover = { _, _ in
            fetches += 1
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(2)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertEqual(waits, [.seconds(10)])
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(model.books.map(\.id), [2])

        // The read keeps running, and the fetched snapshot still reaches iCloud.
        await fulfillment(of: [read.started], timeout: 5)
        read.resolve(CloudLibraryArchive())
        await model.waitForCloudSync()
        XCTAssertEqual(archives.last?.sources.map { $0.books.map(\.id) }, [[2]])
        XCTAssertTrue(model.cloudStatus.contains("Saved to iCloud"))
        XCTAssertEqual(model.books.map(\.id), [2])
    }

    func testBrowsingAndAmbientStateDoNotReadSecretsOrStartBackgroundServices() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1), fixture.book(2)])])
        var dependencies = fixture.dependencies()
        var reads = 0
        dependencies.readCredential = { account in
            reads += 1
            return fixture.secrets[account]
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let startupReads = reads
        for _ in 0..<20 {
            _ = model.isConnected
            _ = model.hasCWAPassword
            _ = model.hasAIKey
            _ = model.book(withID: 1)
            model.setAmbientActive(true)
            model.setAmbientActive(false)
        }
        model.regenerateSpines()
        model.regenerateSpines(onlyMissing: true, automatically: true)
        XCTAssertEqual(reads, startupReads)
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.generationStatus, "Spine generation is disabled.")
    }
}

/// Suspends until the test explicitly releases a reply, including after task cancellation.
@MainActor
private final class ControlledLibraryResponse<Value: Sendable> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, any Error>?
    private var resolvedValue: Value?
    private enum ResponseError: Error { case concurrentRequest }

    init(_ description: String) { started = XCTestExpectation(description: description) }

    func value() async throws -> Value {
        guard continuation == nil else {
            XCTFail("A controlled response supports only one pending request.")
            throw ResponseError.concurrentRequest
        }
        if let resolvedValue {
            started.fulfill()
            return resolvedValue
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resolve(_ value: Value) {
        XCTAssertNotNil(continuation, "Wait for the request before releasing its response.")
        // A timed-out expectation must fail the test without stranding a late request.
        resolvedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
private final class LibraryWorkflowFixture {
    let suite = "LibraryWorkflowTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let defaults: UserDefaults
    let configuration = CWAConfiguration(server: "https://library.invalid", username: "fixture")
    let hardcoverAccountID = "fixture-account"
    var time = Date(timeIntervalSince1970: 1_780_000_000)
    var secrets = ["hardcover-token": "hc_pat_fictional_original"]

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "iCloudEnabled")
        defaults.set(hardcoverAccountID, forKey: "activeHardcoverAccountID")
        defaults.set(try JSONEncoder().encode(configuration), forKey: "cwaConfiguration")
    }

    func dependencies() -> LibraryDependencies {
        var dependencies = LibraryDependencies(defaults: defaults, storageDirectory: directory)
        dependencies.allowLaunchOverrides = false
        dependencies.now = { self.time }
        dependencies.readCredential = { self.secrets[$0] }
        dependencies.saveCredential = { self.secrets[$1] = $0 }
        dependencies.removeCredential = { self.secrets.removeValue(forKey: $0) }
        dependencies.readTopShelf = { [] }
        dependencies.writeTopShelf = { _ in }
        dependencies.fetchHardcover = { _, _ in
            XCTFail("Unexpected Hardcover request")
            throw URLError(.unsupportedURL)
        }
        dependencies.validateHardcover = { _ in
            XCTFail("Unexpected Hardcover validation")
            throw URLError(.unsupportedURL)
        }
        dependencies.refreshHardcoverToken = { _ in
            XCTFail("Unexpected token renewal")
            throw URLError(.unsupportedURL)
        }
        dependencies.revokeHardcoverToken = { _ in XCTFail("Unexpected token revocation") }
        dependencies.fetchCWA = { _, _ in
            XCTFail("Unexpected CWA request")
            throw URLError(.unsupportedURL)
        }
        dependencies.syncCloud = { _ in
            XCTFail("Unexpected cloud request")
            throw URLError(.unsupportedURL)
        }
        dependencies.readSpineWorklist = { nil }
        dependencies.publishSpineWorklist = { _ in }
        dependencies.fetchSpineDesigns = { _, _ in ([:], true) }
        dependencies.fetchCoverChoices = { _, _ in ([:], true) }
        dependencies.fetchSeriesLinks = { _, _ in ([:], true) }
        dependencies.fetchSeriesLooks = { _, _ in [:] }
        dependencies.createSeriesLook = { _ in
            XCTFail("Unexpected series look")
            throw URLError(.unsupportedURL)
        }
        dependencies.sleep = { _ in
            XCTFail("Unexpected scheduled work")
            throw CancellationError()
        }
        return dependencies
    }

    /// Saves a fictional OAuth login, `hc_at_fictional_1` and `hc_rt_fictional_1`, whose
    /// week-long access token expires `seconds` from now.
    func signInWithOAuth(expiringIn seconds: TimeInterval) {
        secrets[HardcoverSession.accessAccount] = "hc_at_fictional_1"
        secrets[HardcoverSession.refreshAccount] = "hc_rt_fictional_1"
        defaults.set(
            time.addingTimeInterval(seconds - HardcoverSession.renewalMargin),
            forKey: HardcoverSession.renewalKey)
    }

    /// The fictional pair a renewal returns as the login's `generation`th tokens.
    func tokens(_ generation: Int) -> HardcoverTokens {
        HardcoverTokens(
            accessToken: "hc_at_fictional_\(generation)",
            refreshToken: "hc_rt_fictional_\(generation)", expiresIn: 604_800)
    }

    func book(_ id: Int, title: String? = nil) -> Book {
        Book(
            id: id, title: title ?? "Fixture \(id)", author: "Fictional author",
            finished: "2026-01-01")
    }

    func snapshot(_ source: LibrarySource, books: [Book], age: TimeInterval = 0) -> SourceSnapshot {
        SourceSnapshot(
            source: source,
            accountID: source == .hardcover ? hardcoverAccountID : configuration.identity,
            books: books, syncedAt: time.addingTimeInterval(-age))
    }

    func save(_ snapshots: [SourceSnapshot]) throws {
        try SourceLibraryStore(url: directory.appending(path: "sources.json")).save(snapshots)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
