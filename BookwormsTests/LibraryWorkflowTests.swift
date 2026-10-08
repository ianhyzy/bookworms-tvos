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
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let dependencies = fixture.dependencies()
        let legacy = LibrarySnapshot(books: [fixture.book(1)], syncedAt: fixture.time)
        try JSONEncoder().encode(legacy).write(to: dependencies.legacySnapshotURL)
        let model = LibraryModel(dependencies: dependencies)

        try await model.resetHardcoverSetup()
        XCTAssertNil(fixture.secrets["hardcover-token"])
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
        dependencies.fetchHardcover = { _ in try await download.value() }
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
        dependencies.fetchHardcover = { _ in throw URLError(.notConnectedToInternet) }
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
        dependencies.fetchHardcover = { _ in
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
        dependencies.fetchHardcover = { _ in
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
        dependencies.fetchHardcover = { _ in
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
        dependencies.fetchHardcover = { _ in
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
        dependencies.fetchHardcover = { _ in
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
            XCTAssertEqual(token, "hc_pat_fictional_replacement")
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
            return .success(token: "hc_pat_fictional_replacement")
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
        XCTAssertEqual(fixture.secrets["hardcover-token"], "hc_pat_fictional_replacement")
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
        dependencies.fetchHardcover = { _ in
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
        dependencies.fetchHardcover = { _ in try await response.value() }
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
        dependencies.fetchHardcover = { _ in try await response.value() }
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
        dependencies.fetchHardcover = { _ in
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
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        let delay = ControlledLibraryResponse<Void>("Cloud debounce scheduled")
        var dependencies = fixture.dependencies()
        dependencies.sleep = { duration in
            XCTAssertEqual(duration, .seconds(2))
            try await delay.value()
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
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
        dependencies.fetchHardcover = { _ in
            XCTFail("Unexpected Hardcover request")
            throw URLError(.unsupportedURL)
        }
        dependencies.validateHardcover = { _ in
            XCTFail("Unexpected Hardcover validation")
            throw URLError(.unsupportedURL)
        }
        dependencies.fetchCWA = { _, _ in
            XCTFail("Unexpected CWA request")
            throw URLError(.unsupportedURL)
        }
        dependencies.syncCloud = { _ in
            XCTFail("Unexpected cloud request")
            throw URLError(.unsupportedURL)
        }
        dependencies.sleep = { _ in
            XCTFail("Unexpected scheduled work")
            throw CancellationError()
        }
        return dependencies
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
