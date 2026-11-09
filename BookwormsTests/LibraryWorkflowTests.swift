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

    /// A login refused for a missing permission isn't saved, so its message asks the reader to
    /// connect again rather than to use a Disconnect button that isn't shown.
    func testFailedConnectionForMissingPermissionAsksToConnectAgain() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        var dependencies = fixture.dependencies()
        dependencies.validateHardcover = { _ in throw HardcoverError.insufficientScope }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let connected = await model.connect("hc_pat_fictional_original")
        XCTAssertFalse(connected)
        XCTAssertFalse(model.hardcoverConnected)
        XCTAssertEqual(model.message, LibraryModel.unsavedScopeMessage)
        XCTAssertEqual(
            model.sourceErrors[LibrarySource.hardcover.rawValue], LibraryModel.unsavedScopeMessage)
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

    func testHardcoverSyncTimeoutNamesHardcover() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86401)])
        var dependencies = fixture.dependencies()
        dependencies.fetchHardcover = { _, _ in throw URLError(.timedOut) }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let text = "Hardcover did not respond in time. Check your network and try again."
        XCTAssertEqual(model.sourceErrors["hardcover"], text)
        XCTAssertEqual(model.message, text)
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
        book.seriesName = "Fictional Saga"
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
        XCTAssertEqual(model.series(for: book)?.info?.books.map(\.id), [3, 4])
        XCTAssertEqual(
            model.browsingCoverURLs.map(\.lastPathComponent), ["library-3.jpg", "series-4.jpg"],
            "Owned series books use their library cover")
        var saved = dependencies.sourceStore.load()
        XCTAssertEqual(saved.first { $0.source == .hardcover }?.series, [series])

        seriesFetchFails = true
        fixture.time += 10
        await model.refresh(manual: true)
        XCTAssertEqual(
            model.series(for: book)?.info?.books.map(\.id), [3, 4],
            "A failed series fetch keeps the cached series")
        saved = dependencies.sourceStore.load()
        XCTAssertEqual(saved.first { $0.source == .hardcover }?.series, [series])
    }

    func testDetailsNameTheLinkedElseTheShortestSeries() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        func info(_ id: Int, _ name: String) -> SeriesInfo {
            SeriesInfo(
                id: id, name: name,
                books: [
                    .init(id: 1, title: "One", position: 1, releaseYear: nil, coverURL: nil)
                ])
        }
        let saga = SeriesMembership(
            seriesID: 7, name: "Fictional Saga", position: 12, featured: true, size: 20)
        let arc = SeriesMembership(seriesID: 8, name: "Fictional Arc", position: 2, size: 3)
        var book = fixture.book(1)
        book.seriesID = 7
        book.seriesName = "Fictional Saga"
        book.seriesMemberships = [saga, arc]
        try fixture.save([
            SourceSnapshot(
                source: .hardcover, accountID: fixture.hardcoverAccountID, books: [book],
                syncedAt: fixture.time,
                series: [info(7, "Fictional Saga"), info(8, "Fictional Arc")])
        ])
        for link in [
            nil,
            SeriesLinkV1(
                accountID: fixture.hardcoverAccountID, bookID: 1, linkedSeriesID: 7,
                chosenAt: fixture.time),
        ] {
            var dependencies = fixture.dependencies()
            dependencies.sleep = { _ in }
            dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
            dependencies.fetchSeriesLinks = { _, _ in (link.map { [1: $0] } ?? [:], true) }
            let model = LibraryModel(dependencies: dependencies)
            await model.start()
            await model.waitForCloudSync()
            await model.waitForCompanionRecords()
            let shown = try XCTUnwrap(model.series(for: book))
            XCTAssertEqual(shown.membership, link == nil ? arc : saga)
            XCTAssertEqual(shown.info?.name, link == nil ? "Fictional Arc" : "Fictional Saga")
            XCTAssertEqual(
                SeriesDesigns.label(of: shown.membership),
                link == nil ? "Fictional Arc 2 of 3" : "Fictional Saga 12 of 20")
        }
    }

    func testPickingASeriesSavesTheBooksLinkAsTheiPhoneDoes() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let saga = SeriesMembership(
            seriesID: 7, name: "Fictional Saga", position: 12, featured: true, size: 20)
        let arc = SeriesMembership(seriesID: 8, name: "Fictional Arc", position: 2, size: 3)
        var book = fixture.book(1)
        book.seriesID = 7
        book.seriesName = "Fictional Saga"
        book.seriesMemberships = [saga, arc]
        try fixture.save([
            SourceSnapshot(
                source: .hardcover, accountID: fixture.hardcoverAccountID, books: [book],
                syncedAt: fixture.time)
        ])
        // The links iCloud holds: a save replaces the link, or deletes one that changes nothing.
        var stored: [Int: SeriesLinkV1] = [:]
        var saves: [SeriesLinkV1] = []
        var savesFail = false
        // The number of earlier saves at which one save fails.
        var failsAfterSaves: Int?
        var heldSave: ControlledLibraryResponse<Void>?
        var duringUserRead: (@MainActor () async -> Void)?
        var cloudUser = "_fictional_user_1"
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        dependencies.cloudUserRecordName = {
            let hook = duringUserRead
            duringUserRead = nil
            await hook?()
            return cloudUser
        }
        dependencies.fetchSeriesLinks = { _, _ in (stored, true) }
        dependencies.saveSeriesLink = { link, accountID, bookID in
            XCTAssertEqual(accountID, fixture.hardcoverAccountID)
            XCTAssertEqual(bookID, 1)
            if let heldSave { try await heldSave.value() }
            if savesFail || failsAfterSaves == saves.count { throw CloudStorageError.unavailable }
            saves.append(link)
            stored[bookID] = link.changesNothing ? nil : link
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await model.waitForCompanionRecords()
        XCTAssertTrue(model.canPickSeries(for: book))
        XCTAssertEqual(model.series(for: book)?.all, [saga, arc])
        XCTAssertEqual(model.series(for: book)?.membership, arc, "The shortest series by default")

        let save = ControlledLibraryResponse<Void>("Series link save started")
        heldSave = save
        model.pickSeries(7, for: book)
        XCTAssertEqual(model.series(for: book)?.membership, saga, "A pick shows at once")
        await fulfillment(of: [save.started], timeout: 5)
        await model.becameActive()
        await model.waitForCompanionRecords()
        XCTAssertEqual(
            model.series(for: book)?.membership, saga, "A read during the save keeps the pick")
        heldSave = nil
        save.resolve(())
        await model.waitForSeriesLinkSaves()
        await model.waitForCompanionRecords()
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves.last?.linkedSeriesID, 7)
        XCTAssertEqual(saves.last?.ownLook, false)
        XCTAssertEqual(saves.last?.standsAlone, false)
        XCTAssertEqual(model.series(for: book)?.membership, saga)

        // A read that starts after the save shows the link iCloud holds, such as none once the
        // iPhone resets the book to its default series.
        stored = [:]
        await model.becameActive()
        await model.waitForCompanionRecords()
        XCTAssertEqual(model.series(for: book)?.membership, arc)

        // Picking the shortest series saves a link that changes nothing, which deletes it.
        model.pickSeries(7, for: book)
        await model.waitForSeriesLinkSaves()
        await model.waitForCompanionRecords()
        model.pickSeries(8, for: book)
        await model.waitForSeriesLinkSaves()
        await model.waitForCompanionRecords()
        XCTAssertEqual(saves.count, 3)
        XCTAssertEqual(saves.last?.changesNothing, true)
        XCTAssertNil(stored[1])
        XCTAssertEqual(model.series(for: book)?.membership, arc)
        model.pickSeries(8, for: book)
        await model.waitForSeriesLinkSaves()
        XCTAssertEqual(saves.count, 3, "Picking the shown series saves nothing")

        // A failed save restores the earlier choice, which then gives way to another device's
        // link, even one stamped by a clock behind this one.
        savesFail = true
        model.pickSeries(7, for: book)
        XCTAssertEqual(model.series(for: book)?.membership, saga)
        await model.waitForSeriesLinkSaves()
        XCTAssertEqual(model.series(for: book)?.membership, arc)
        stored[1] = SeriesLinkV1(
            accountID: fixture.hardcoverAccountID, bookID: 1, linkedSeriesID: 7,
            chosenAt: fixture.time.addingTimeInterval(-60))
        await model.becameActive()
        await model.waitForCompanionRecords()
        XCTAssertEqual(model.series(for: book)?.membership, saga)

        // A pick made while an account change reads the iCloud user waits for the check, then
        // saves when the user is unchanged.
        savesFail = false
        var savesBefore = saves.count
        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        duringUserRead = {
            model.pickSeries(8, for: book)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(saves.count, savesBefore, "The save waits for the check")
        }
        await model.cloudAccountChanged()
        XCTAssertNil(duringUserRead)
        await model.waitForSeriesLinkSaves()
        XCTAssertEqual(saves.count, savesBefore + 1)
        XCTAssertEqual(saves.last?.changesNothing, true)
        XCTAssertEqual(model.series(for: book)?.membership, arc)
        await model.waitForCompanionRecords()
        XCTAssertEqual(model.series(for: book)?.membership, arc)

        // A save already under way when the notice arrives keeps its pick once the check
        // confirms the user.
        savesBefore = saves.count
        let pending = ControlledLibraryResponse<Void>("Series link save under way")
        heldSave = pending
        model.pickSeries(7, for: book)
        await fulfillment(of: [pending.started], timeout: 5)
        duringUserRead = {
            heldSave = nil
            pending.resolve(())
            for _ in 0..<20 { await Task.yield() }
        }
        await model.cloudAccountChanged()
        XCTAssertNil(duringUserRead)
        await model.waitForSeriesLinkSaves()
        await model.waitForCompanionRecords()
        XCTAssertEqual(saves.count, savesBefore + 1)
        XCTAssertEqual(model.series(for: book)?.membership, saga)

        // Two picks made during a check save in order. When the later save fails, the earlier
        // pick shows, since iCloud holds it, and picking the later series again saves it.
        savesBefore = saves.count
        failsAfterSaves = savesBefore + 1
        duringUserRead = {
            model.pickSeries(8, for: book)
            model.pickSeries(7, for: book)
        }
        await model.cloudAccountChanged()
        await model.waitForSeriesLinkSaves()
        XCTAssertEqual(saves.count, savesBefore + 1)
        XCTAssertEqual(saves.last?.changesNothing, true)
        XCTAssertNil(stored[1])
        XCTAssertEqual(model.series(for: book)?.membership, arc)
        failsAfterSaves = nil
        model.pickSeries(7, for: book)
        await model.waitForSeriesLinkSaves()
        await model.waitForCompanionRecords()
        XCTAssertEqual(saves.count, savesBefore + 2)
        XCTAssertEqual(saves.last?.linkedSeriesID, 7)
        XCTAssertEqual(model.series(for: book)?.membership, saga)

        // When both saves fail, the choice iCloud held before either pick shows, and picking
        // the earlier series again saves it.
        savesBefore = saves.count
        savesFail = true
        model.pickSeries(8, for: book)
        model.pickSeries(7, for: book)
        await model.waitForSeriesLinkSaves()
        XCTAssertEqual(saves.count, savesBefore)
        XCTAssertEqual(model.series(for: book)?.membership, saga)
        savesFail = false
        model.pickSeries(8, for: book)
        await model.waitForSeriesLinkSaves()
        XCTAssertEqual(saves.count, savesBefore + 1)
        XCTAssertNil(stored[1])
        XCTAssertEqual(model.series(for: book)?.membership, arc)
        model.pickSeries(7, for: book)
        await model.waitForSeriesLinkSaves()
        await model.waitForCompanionRecords()
        XCTAssertEqual(saves.count, savesBefore + 2)
        XCTAssertEqual(model.series(for: book)?.membership, saga)

        // A pick that turning storage off cleared during a check isn't saved once the reader
        // turns storage on again, even for another iCloud user.
        savesBefore = saves.count
        cloudUser = "_fictional_user_2"
        duringUserRead = {
            model.pickSeries(8, for: book)
            model.iCloudEnabled = false
            model.iCloudEnabled = true
        }
        await model.cloudAccountChanged()
        await model.waitForSeriesLinkSaves()
        await model.waitForCompanionRecords()
        XCTAssertTrue(model.iCloudEnabled)
        XCTAssertEqual(saves.count, savesBefore)
        XCTAssertEqual(model.series(for: book)?.membership, saga)

        // A pick made while the check finds another user is never saved: storage turns off.
        // Turning storage on above cleared the saved user; a sync saves it again.
        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        savesBefore = saves.count
        cloudUser = "_fictional_user_2"
        duringUserRead = { model.pickSeries(8, for: book) }
        await model.cloudAccountChanged()
        await model.waitForSeriesLinkSaves()
        XCTAssertFalse(model.iCloudEnabled)
        XCTAssertEqual(saves.count, savesBefore)
        XCTAssertFalse(model.canPickSeries(for: book))
    }

    /// Unsaved picks, including a pick of the default series, belong to their account: once a
    /// restore adopts another account, that account's series links show.
    func testAnAccountChangeDropsUnsavedSeriesPicks() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        fixture.secrets.removeValue(forKey: "hardcover-token")
        let saga = SeriesMembership(
            seriesID: 7, name: "Fictional Saga", position: 12, featured: true, size: 20)
        let arc = SeriesMembership(seriesID: 8, name: "Fictional Arc", position: 2, size: 3)
        var book = fixture.book(1)
        book.seriesID = 7
        book.seriesName = "Fictional Saga"
        book.seriesMemberships = [saga, arc]
        func snapshot(_ accountID: String) -> SourceSnapshot {
            SourceSnapshot(
                source: .hardcover, accountID: accountID, books: [book], syncedAt: fixture.time)
        }
        var worklistAccount = "_fictional_account_a"
        var archive = CloudLibraryArchive(sources: [snapshot("_fictional_account_a")])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in archive }
        dependencies.readSpineWorklist = {
            SpineWorklistV1(accountID: worklistAccount, syncedAt: fixture.time, bookIDs: [1])
        }
        // Account B's iPhone linked the book to the Fictional Saga.
        dependencies.fetchSeriesLinks = { accountID, _ in
            guard accountID == "_fictional_account_b" else { return ([:], true) }
            return (
                [
                    1: SeriesLinkV1(
                        accountID: accountID, bookID: 1, linkedSeriesID: 7,
                        chosenAt: fixture.time)
                ], true
            )
        }
        let save = ControlledLibraryResponse<Void>("Series link save started")
        dependencies.saveSeriesLink = { _, _, _ in try await save.value() }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await model.waitForCompanionRecords()
        XCTAssertTrue(model.canPickSeries(for: book))
        XCTAssertEqual(model.series(for: book)?.membership, arc)

        // The Fictional Saga's save is under way when the default is picked again.
        model.pickSeries(7, for: book)
        await fulfillment(of: [save.started], timeout: 5)
        model.pickSeries(8, for: book)
        XCTAssertEqual(model.series(for: book)?.membership, arc)

        worklistAccount = "_fictional_account_b"
        archive = CloudLibraryArchive(sources: [snapshot("_fictional_account_b")])
        model.queueCloudSync(delay: .zero)
        await model.waitForCloudSync()
        save.resolve(())
        await model.waitForSeriesLinkSaves()
        await model.becameActive()
        await model.waitForCompanionRecords()
        XCTAssertEqual(model.series(for: book)?.membership, saga)
    }

    /// On a credential-free shelf without a worklist, a newer snapshot of another account
    /// changes the account whose records apply, which drops an unsaved pick of the default
    /// series too, so it can't hide the new account's link.
    func testANewerSnapshotOfAnotherAccountDropsUnsavedDefaultPicks() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
        fixture.secrets.removeValue(forKey: "hardcover-token")
        let saga = SeriesMembership(
            seriesID: 7, name: "Fictional Saga", position: 12, featured: true, size: 20)
        let arc = SeriesMembership(seriesID: 8, name: "Fictional Arc", position: 2, size: 3)
        var book = fixture.book(1)
        book.seriesID = 7
        book.seriesName = "Fictional Saga"
        book.seriesMemberships = [saga, arc]
        var archive = CloudLibraryArchive(sources: [
            SourceSnapshot(
                source: .hardcover, accountID: "_fictional_account_a", books: [book],
                syncedAt: fixture.time)
        ])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in archive }
        // Account B's iPhone linked the book to the Fictional Saga.
        dependencies.fetchSeriesLinks = { accountID, _ in
            guard accountID == "_fictional_account_b" else { return ([:], true) }
            return (
                [
                    1: SeriesLinkV1(
                        accountID: accountID, bookID: 1, linkedSeriesID: 7,
                        chosenAt: fixture.time)
                ], true
            )
        }
        let save = ControlledLibraryResponse<Void>("Series link save started")
        dependencies.saveSeriesLink = { _, _, _ in try await save.value() }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        await model.waitForCompanionRecords()
        XCTAssertTrue(model.canPickSeries(for: book))
        XCTAssertEqual(model.series(for: book)?.membership, arc)

        // The Fictional Saga's save is under way when the default is picked again.
        model.pickSeries(7, for: book)
        await fulfillment(of: [save.started], timeout: 5)
        model.pickSeries(8, for: book)

        archive = CloudLibraryArchive(sources: [
            SourceSnapshot(
                source: .hardcover, accountID: "_fictional_account_b", books: [book],
                syncedAt: fixture.time.addingTimeInterval(60))
        ])
        model.queueCloudSync(delay: .zero)
        await model.waitForCloudSync()
        save.resolve(())
        await model.waitForSeriesLinkSaves()
        await model.becameActive()
        await model.waitForCompanionRecords()
        XCTAssertNil(fixture.defaults.string(forKey: "activeHardcoverAccountID"))
        XCTAssertEqual(model.series(for: book)?.membership, saga)
    }

    func testAPickKeepsTheBooksOwnLookAndReplacesNotInASeries() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let saga = SeriesMembership(
            seriesID: 7, name: "Fictional Saga", position: 12, featured: true, size: 20)
        let arc = SeriesMembership(seriesID: 8, name: "Fictional Arc", position: 2, size: 3)
        var book = fixture.book(1)
        book.seriesID = 7
        book.seriesName = "Fictional Saga"
        book.seriesMemberships = [saga, arc]
        try fixture.save([
            SourceSnapshot(
                source: .hardcover, accountID: fixture.hardcoverAccountID, books: [book],
                syncedAt: fixture.time)
        ])
        // iPhone edits: **This book** keeps the book's own look; **Not in a series** stands alone.
        for iPhoneLink in [
            SeriesLinkV1(
                accountID: fixture.hardcoverAccountID, bookID: 1, ownLook: true,
                chosenAt: fixture.time),
            SeriesLinkV1(
                accountID: fixture.hardcoverAccountID, bookID: 1, standsAlone: true,
                chosenAt: fixture.time),
        ] {
            var stored: SeriesLinkV1? = iPhoneLink
            var saves: [SeriesLinkV1] = []
            var dependencies = fixture.dependencies()
            dependencies.sleep = { _ in }
            dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
            dependencies.fetchSeriesLinks = { _, _ in (stored.map { [1: $0] } ?? [:], true) }
            dependencies.saveSeriesLink = { link, _, _ in
                saves.append(link)
                stored = link.changesNothing ? nil : link
            }
            let model = LibraryModel(dependencies: dependencies)
            await model.start()
            await model.waitForCloudSync()
            await model.waitForCompanionRecords()
            if iPhoneLink.ownLook {
                model.pickSeries(7, for: book)
                await model.waitForSeriesLinkSaves()
                await model.waitForCompanionRecords()
                XCTAssertEqual(saves.last?.linkedSeriesID, 7)
                XCTAssertEqual(saves.last?.ownLook, true, "A pick keeps the book's own look")
                model.pickSeries(8, for: book)
                await model.waitForSeriesLinkSaves()
                await model.waitForCompanionRecords()
                XCTAssertNil(saves.last?.linkedSeriesID)
                XCTAssertEqual(saves.last?.ownLook, true)
                XCTAssertNotNil(stored, "The shortest series keeps a link with its own look")
            } else {
                XCTAssertNil(model.series(for: book))
                model.pickSeries(8, for: book)
                await model.waitForSeriesLinkSaves()
                await model.waitForCompanionRecords()
                XCTAssertEqual(
                    saves.count, 1, "Picking the shortest series replaces standing alone")
                XCTAssertEqual(saves.last?.changesNothing, true)
                XCTAssertNil(stored)
            }
            XCTAssertEqual(model.series(for: book)?.membership, arc)
        }
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
        XCTAssertEqual(model.message, "Hardcover token verified. Loading library…")
        model.clearVerifiedTokenMessage()
        XCTAssertNil(model.message)
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
        XCTAssertNil(model.message)
    }

    func testDisconnectReportsAKeychainTokenItCouldNotRemove() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 5 * 86_400)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.removeCredential = { account in
            guard account == HardcoverSession.refreshAccount else {
                throw CredentialStore.CredentialError.removeFailed
            }
            fixture.secrets.removeValue(forKey: account)
        }
        let revoked = expectation(description: "Disconnecting still revokes the login")
        dependencies.revokeHardcoverToken = { refreshToken in
            XCTAssertEqual(refreshToken, "hc_rt_fictional_1")
            revoked.fulfill()
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.disconnect()
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertNil(fixture.secrets["hardcover-refresh-token"])
        XCTAssertNotNil(fixture.secrets["hardcover-token"])
        XCTAssertEqual(model.message, "The saved Hardcover login could not be removed.")
        XCTAssertFalse(model.hardcoverConnected)
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

    func testARejectedDeviceCodeStopsPolling() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeValue(forKey: "hardcover-token")
        var dependencies = fixture.dependencies()
        dependencies.requestHardcoverDeviceAuth = {
            HardcoverDeviceAuth(
                deviceCode: "fixture_device_code", userCode: "TEST-CODE",
                verificationURI: URL(string: "https://hardcover.app/link")!,
                verificationURIComplete: URL(string: "https://hardcover.app/link?c=TESTCODE")!,
                expiresIn: 900, interval: 1)
        }
        let polled = expectation(description: "Device code polled")
        var polls = 0
        dependencies.pollHardcoverDeviceToken = { _ in
            polls += 1
            if polls == 1 { polled.fulfill() }
            throw HardcoverError.invalidAuthorizationCode
        }
        // Bounds the polling a regression would repeat without waiting.
        var sleeps = 0
        dependencies.sleep = { _ in
            sleeps += 1
            if sleeps > 3 { throw CancellationError() }
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.startHardcoverDeviceAuth()
        await fulfillment(of: [polled], timeout: 5)
        // The polling task runs on the main actor without suspending after the rejection, so it
        // has stopped or polled again before this test resumes.
        XCTAssertEqual(polls, 1, "Hardcover won't accept a rejected code again")
        XCTAssertEqual(
            model.hardcoverDeviceAuthMessage,
            HardcoverError.invalidAuthorizationCode.errorDescription)
        XCTAssertNotNil(model.hardcoverDeviceAuth, "The card keeps New code beside the message")
    }

    func testADeviceSignInThatIsntKeptRevokesItsLogin() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeValue(forKey: "hardcover-token")
        var dependencies = fixture.dependencies()
        dependencies.requestHardcoverDeviceAuth = {
            HardcoverDeviceAuth(
                deviceCode: "fixture_device_code", userCode: "TEST-CODE",
                verificationURI: URL(string: "https://hardcover.app/link")!,
                verificationURIComplete: URL(string: "https://hardcover.app/link?c=TESTCODE")!,
                expiresIn: 900, interval: 1)
        }
        dependencies.pollHardcoverDeviceToken = { _ in .success(fixture.tokens(2)) }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        dependencies.fetchHardcover = { _, _ in throw HardcoverError.http(503) }
        dependencies.sleep = { _ in }
        let revoked = expectation(description: "Unsaved login revoked")
        dependencies.revokeHardcoverToken = { token in
            XCTAssertEqual(token, "hc_rt_fictional_2")
            revoked.fulfill()
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.startHardcoverDeviceAuth()
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertFalse(model.hardcoverConnected)
        XCTAssertNil(fixture.secrets[HardcoverSession.refreshAccount])
    }

    func testARefusedAccessTokenSaveKeepsTheSavedLogin() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 604_800)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.requestHardcoverDeviceAuth = {
            HardcoverDeviceAuth(
                deviceCode: "fixture_device_code", userCode: "TEST-CODE",
                verificationURI: URL(string: "https://hardcover.app/link")!,
                verificationURIComplete: URL(string: "https://hardcover.app/link?c=TESTCODE")!,
                expiresIn: 900, interval: 1)
        }
        dependencies.pollHardcoverDeviceToken = { _ in .success(fixture.tokens(2)) }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        // Keychain takes the refresh token, which is saved first, and refuses the access token.
        dependencies.saveCredential = { value, account in
            guard account == HardcoverSession.refreshAccount else {
                throw CredentialStore.CredentialError.saveFailed
            }
            fixture.secrets[account] = value
        }
        dependencies.sleep = { _ in }
        let revoked = expectation(description: "Unsaved login revoked")
        dependencies.revokeHardcoverToken = { token in
            XCTAssertEqual(token, "hc_rt_fictional_2")
            revoked.fulfill()
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.startHardcoverDeviceAuth()
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertEqual(fixture.secrets[HardcoverSession.accessAccount], "hc_at_fictional_1")
        XCTAssertEqual(
            fixture.secrets[HardcoverSession.refreshAccount], "hc_rt_fictional_1",
            "The saved access token keeps the refresh token that renews it")
    }

    func testARefusedRefreshTokenSaveNeverRemovesAnUnreadableLogin() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.signInWithOAuth(expiringIn: 604_800)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.requestHardcoverDeviceAuth = {
            HardcoverDeviceAuth(
                deviceCode: "fixture_device_code", userCode: "TEST-CODE",
                verificationURI: URL(string: "https://hardcover.app/link")!,
                verificationURIComplete: URL(string: "https://hardcover.app/link?c=TESTCODE")!,
                expiresIn: 900, interval: 1)
        }
        dependencies.pollHardcoverDeviceToken = { _ in .success(fixture.tokens(2)) }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        // A failed read returns nil like a missing item, and Keychain refuses the new refresh
        // token, so the saved one is never replaced.
        dependencies.readCredential = { account in
            account == HardcoverSession.refreshAccount ? nil : fixture.secrets[account]
        }
        dependencies.saveCredential = { _, _ in throw CredentialStore.CredentialError.saveFailed }
        var removed: [String] = []
        dependencies.removeCredential = { account in
            removed.append(account)
            fixture.secrets.removeValue(forKey: account)
        }
        dependencies.sleep = { _ in }
        let revoked = expectation(description: "Unsaved login revoked")
        dependencies.revokeHardcoverToken = { token in
            XCTAssertEqual(token, "hc_rt_fictional_2")
            revoked.fulfill()
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.startHardcoverDeviceAuth()
        await fulfillment(of: [revoked], timeout: 5)
        XCTAssertFalse(removed.contains(HardcoverSession.refreshAccount))
        XCTAssertEqual(fixture.secrets[HardcoverSession.accessAccount], "hc_at_fictional_1")
        XCTAssertEqual(fixture.secrets[HardcoverSession.refreshAccount], "hc_rt_fictional_1")
    }

    func testConnectingCWASkipsTheDailyGate() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "cwaEnabled")
        fixture.secrets["cwa-password"] = "fictional-original"
        try fixture.save([fixture.snapshot(.cwa, books: [fixture.book(2)])])
        var dependencies = fixture.dependencies()
        var requestedPasswords: [String] = []
        dependencies.fetchCWA = { _, password in
            requestedPasswords.append(password)
            return [fixture.book(3)]
        }
        fixture.secrets.removeValue(forKey: "hardcover-token")
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(requestedPasswords.isEmpty, "The snapshot synced today isn't due")
        let connected = await model.connectCWA(
            fixture.configuration, password: "fictional-replacement")
        XCTAssertTrue(connected, "A changed password connects within a day of the last sync")
        XCTAssertEqual(requestedPasswords, ["fictional-replacement"])
        XCTAssertEqual(fixture.secrets["cwa-password"], "fictional-replacement")
    }

    func testCWAStatusFollowsTheActiveAccountsSnapshot() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([
            SourceSnapshot(
                source: .cwa, accountID: "https://other.invalid/fixture",
                books: [fixture.book(2)], syncedAt: fixture.time)
        ])
        fixture.defaults.set(fixture.time.addingTimeInterval(-1000), forKey: "syncAttempt.cwa")
        fixture.secrets.removeValue(forKey: "hardcover-token")
        let model = LibraryModel(dependencies: fixture.dependencies())
        await model.start()
        XCTAssertNil(
            model.sourceStatus(.cwa),
            "Another account's sync today doesn't push the active account's check to tomorrow")
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

    func testUnchangedShelfKeepsItsPresentationRevision() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1), fixture.book(2)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        let revision = model.presentationRevision
        // Reapplying the same preferences selects the same books with the same styles.
        model.shelfPreferences = model.shelfPreferences
        XCTAssertEqual(model.presentationRevision, revision)
    }

    func testBookWallWaitsForTheLaunchCompanionRead() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        // The wall's time limit holds until the test ends.
        let (deadline, passDeadline) = AsyncStream.makeStream(of: Void.self)
        defer { passDeadline.finish() }
        dependencies.sleep = { _ in }
        dependencies.companionReadLimit = { for await _ in deadline {} }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        dependencies.fetchSpineDesigns = { _, _ in
            for await _ in held {}
            return ([:], true)
        }

        let offline = LibraryModel(dependencies: dependencies)
        await offline.start()
        XCTAssertTrue(offline.hasReadCompanionRecords, "No read runs with iCloud storage off")

        fixture.defaults.set(true, forKey: "iCloudEnabled")
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(model.hasLoadedLibrarySnapshot)
        XCTAssertFalse(model.hasReadCompanionRecords)
        release.finish()
        await model.waitForCompanionRecords()
        XCTAssertTrue(model.hasReadCompanionRecords)
    }

    /// An account change notice for the same user holds launch's companion read and reads again,
    /// and Book Wall keeps waiting for that read.
    func testBookWallKeepsWaitingThroughAnAccountCheck() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        let (deadline, passDeadline) = AsyncStream.makeStream(of: Void.self)
        defer { passDeadline.finish() }
        dependencies.sleep = { _ in }
        dependencies.companionReadLimit = { for await _ in deadline {} }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        dependencies.cloudUserRecordName = { "_fictional_user_1" }
        var heldReads: [CheckedContinuation<Void, Never>] = []
        dependencies.fetchSpineDesigns = { _, _ in
            await withCheckedContinuation { heldReads.append($0) }
            return ([:], true)
        }

        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        for _ in 0..<100 where heldReads.isEmpty { await Task.yield() }
        XCTAssertEqual(heldReads.count, 1)
        XCTAssertFalse(model.hasReadCompanionRecords)
        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        await model.cloudAccountChanged()
        XCTAssertTrue(model.iCloudEnabled)
        XCTAssertFalse(model.hasReadCompanionRecords)
        for _ in 0..<100 where heldReads.count < 2 { await Task.yield() }
        XCTAssertEqual(heldReads.count, 2, "The check starts the read again")
        for read in heldReads { read.resume() }
        await model.waitForCompanionRecords()
        XCTAssertTrue(model.hasReadCompanionRecords)
    }

    func testBookWallStopsWaitingForAStalledCompanionRead() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        dependencies.companionReadLimit = {}
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        defer { release.finish() }
        dependencies.fetchSpineDesigns = { _, _ in
            for await _ in held {}
            return ([:], true)
        }

        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        for _ in 0..<100 where !model.hasReadCompanionRecords { await Task.yield() }
        XCTAssertTrue(model.hasReadCompanionRecords, "The read is still running")
    }

    func testRemovingTheAIKeyReportsAFailedDelete() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(try JSONEncoder().encode(AIConfiguration()), forKey: "aiConfiguration")
        var dependencies = fixture.dependencies()
        dependencies.removeCredential = { _ in throw CredentialStore.CredentialError.removeFailed }
        let model = LibraryModel(dependencies: dependencies)
        model.removeAIKey()
        XCTAssertEqual(model.generationStatus, "The API key could not be removed. Try again.")
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
            return ([:], true)
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
        // Designs, links, and looks each answered in full, or not.
        for complete in [
            (false, true, true), (true, false, true), (true, true, false), (true, true, true),
        ] {
            let isComplete = complete == (true, true, true)
            var dependencies = fixture.dependencies()
            dependencies.sleep = { _ in }
            dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
            dependencies.fetchSpineDesigns = { _, _ in (designs, complete.0) }
            dependencies.fetchSeriesLinks = { _, _ in ([1: link], complete.1) }
            dependencies.fetchSeriesLooks = { _, _ in ([:], complete.2) }
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

    /// **Settings → Spines** counts the books with no design yet only while storage is on,
    /// since turning it off hides designs rather than removing them.
    func testSpinesNoteCountsUndesignedBooksOnlyWithStorageOn() async throws {
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
        await model.waitForCompanionRecords()
        XCTAssertEqual(
            model.spinesNote, "1 book has no design yet, so it gets the Apple TV's own look.")

        model.iCloudEnabled = false
        XCTAssertEqual(
            model.spinesNote,
            "iCloud storage is off, so Book Wall uses the Apple TV's own looks. Turn it on in General."
        )
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

    /// An Apple TV without a credential reads the companion records of the account whose
    /// snapshot it shows, such as an iPhone's library with no worklist, without saving that
    /// account or listing work. The legacy `"hardcover"` placeholder has no records.
    func testCredentialFreeShelfReadsTheShownAccountsCompanionRecords() async throws {
        for accountID in ["_fictional_iphone_account", "hardcover"] {
            let fixture = try LibraryWorkflowFixture()
            defer { fixture.cleanUp() }
            fixture.defaults.set(true, forKey: "iCloudEnabled")
            fixture.defaults.removeObject(forKey: "activeHardcoverAccountID")
            fixture.secrets.removeValue(forKey: "hardcover-token")
            let book = fixture.book(1)
            let snapshot = SourceSnapshot(
                source: .hardcover, accountID: accountID, books: [book], syncedAt: fixture.time)
            var dependencies = fixture.dependencies()
            dependencies.sleep = { _ in }
            dependencies.syncCloud = { _ in CloudLibraryArchive(sources: [snapshot]) }
            var readAccounts: [String] = []
            dependencies.fetchSpineDesigns = { accountID, _ in
                readAccounts.append(accountID)
                return ([:], true)
            }
            dependencies.fetchCoverChoices = { accountID, _ in
                (
                    [
                        1: CoverChoiceV1(
                            version: 1, accountID: accountID, bookID: 1,
                            coverURL: URL(string: "https://covers.example.test/chosen.jpg")!,
                            chosenAt: fixture.time)
                    ], true
                )
            }
            dependencies.publishSpineWorklist = { _ in XCTFail("Unexpected worklist") }
            let model = LibraryModel(dependencies: dependencies)
            await model.start()
            await model.waitForCloudSync()
            await model.waitForCompanionRecords()
            XCTAssertEqual(model.books.map(\.id), [1])
            XCTAssertNil(fixture.defaults.string(forKey: "activeHardcoverAccountID"))
            if accountID == "hardcover" {
                XCTAssertEqual(readAccounts, [])
                XCTAssertFalse(model.canPickSeries(for: book))
                XCTAssertNil(model.books.first?.chosenCoverURL)
            } else {
                XCTAssertEqual(readAccounts, [accountID])
                XCTAssertTrue(model.canPickSeries(for: book))
                XCTAssertNotNil(model.books.first?.chosenCoverURL)
            }
        }
    }

    /// The empty shelf names the setting that hides a connected reader's books, which the
    /// screen labels Collection, and tells a library with no books apart from one that is
    /// loading or couldn't load.
    func testEmptyShelfHintNamesWhyTheShelfIsEmpty() async throws {
        let signedOut = try LibraryWorkflowFixture()
        defer { signedOut.cleanUp() }
        signedOut.secrets.removeValue(forKey: "hardcover-token")
        let model = LibraryModel(dependencies: signedOut.dependencies())
        await model.start()
        XCTAssertEqual(
            model.emptyShelfHint, "Connect a source in Settings to explore your books.")

        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        try fixture.save([fixture.snapshot(.hardcover, books: [])])
        let empty = LibraryModel(dependencies: fixture.dependencies())
        await empty.start()
        XCTAssertTrue(empty.books.isEmpty)
        XCTAssertEqual(
            empty.emptyShelfHint,
            "Your library has no books yet. Books you add appear after the next sync.")

        let filtered = try LibraryWorkflowFixture()
        defer { filtered.cleanUp() }
        let unread = Book(id: 2, title: "Fixture 2", author: "Fictional author")
        try filtered.save([filtered.snapshot(.hardcover, books: [unread])])
        let hidden = LibraryModel(dependencies: filtered.dependencies())
        await hidden.start()
        hidden.shelfPreferences = ShelfPreferences(collection: .read)
        XCTAssertTrue(hidden.books.isEmpty, "Read Books leaves out an unread book")
        XCTAssertEqual(
            hidden.emptyShelfHint,
            "No books match your shelf choices. Change Collection in Settings → Shelf.")

        let loading = try LibraryWorkflowFixture()
        defer { loading.cleanUp() }
        var dependencies = loading.dependencies()
        var heldFetch: CheckedContinuation<Void, Never>?
        dependencies.fetchHardcover = { _, _ in
            await withCheckedContinuation { heldFetch = $0 }
            throw URLError(.notConnectedToInternet)
        }
        let first = LibraryModel(dependencies: dependencies)
        let start = Task { await first.start() }
        for _ in 0..<100 where heldFetch == nil { await Task.yield() }
        XCTAssertEqual(first.emptyShelfHint, "Loading your books…")
        try XCTUnwrap(heldFetch).resume()
        await start.value
        XCTAssertNotNil(first.sourceErrors["hardcover"])
        XCTAssertEqual(
            first.emptyShelfHint,
            "Your books couldn't load. Check Settings → Sources, then sync again.")
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

    /// CloudKit posts `CKAccountChanged` for the same account too; only another user, or one
    /// that can't be read, turns iCloud storage off.
    func testCloudAccountChangeKeepsStorageForTheSameUser() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { $0 }
        var user: String? = "_fictional_user_1"
        dependencies.cloudUserRecordName = { user }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(
            fixture.defaults.string(forKey: LibraryModel.cloudUserKey), "_fictional_user_1")

        await model.cloudAccountChanged()
        XCTAssertTrue(model.iCloudEnabled)

        user = "_fictional_user_2"
        await model.cloudAccountChanged()
        XCTAssertFalse(model.iCloudEnabled)
        XCTAssertNil(fixture.defaults.string(forKey: LibraryModel.cloudUserKey))
        XCTAssertEqual(
            model.cloudStatus,
            "Your iCloud account changed, so iCloud storage turned off. Turn it on to sync this library with the current account."
        )
    }

    /// CloudKit posts no notice for an account change made while the app wasn't running, so
    /// launch compares the user with the last sync's before any sync or companion read, without
    /// waiting for the read itself. The same user, or one it can't read, as offline, keeps
    /// storage on; a later sync that reads another user then stops before it uploads.
    func testLaunchChecksTheICloudUserBeforeCloudWork() async throws {
        for launchUser in ["_fictional_user_2", "_fictional_user_1", nil] as [String?] {
            let fixture = try LibraryWorkflowFixture()
            defer { fixture.cleanUp() }
            fixture.defaults.set(true, forKey: "iCloudEnabled")
            fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
            try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
            var dependencies = fixture.dependencies()
            dependencies.sleep = { _ in }
            var syncs = 0
            dependencies.syncCloud = {
                syncs += 1
                return $0
            }
            var reads = 0
            dependencies.fetchSpineDesigns = { _, _ in
                reads += 1
                return ([:], true)
            }
            var user = launchUser
            // Launch's read is held, so `start()` returning shows it doesn't wait for the read.
            var holdsRead = true
            var heldRead: CheckedContinuation<Void, Never>?
            dependencies.cloudUserRecordName = {
                if holdsRead {
                    holdsRead = false
                    await withCheckedContinuation { heldRead = $0 }
                }
                return user
            }
            dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
            let model = LibraryModel(dependencies: dependencies)
            await model.start()
            XCTAssertEqual(syncs, 0)
            XCTAssertEqual(reads, 0)
            XCTAssertFalse(model.hasReadCompanionRecords)
            for _ in 0..<100 where heldRead == nil { await Task.yield() }
            try XCTUnwrap(heldRead).resume()
            await model.waitForCloudUserChecks()
            await model.waitForCloudSync()
            await model.waitForCompanionRecords()
            if launchUser == "_fictional_user_2" {
                XCTAssertFalse(model.iCloudEnabled)
                XCTAssertEqual(syncs, 0)
                XCTAssertEqual(reads, 0)
                XCTAssertTrue(model.cloudStatus.hasPrefix("Your iCloud account changed"))
                continue
            }
            XCTAssertTrue(model.iCloudEnabled)
            XCTAssertEqual(syncs, 1)
            XCTAssertGreaterThan(reads, 0)

            user = "_fictional_user_2"
            model.queueCloudSync(delay: .zero)
            await model.waitForCloudSync()
            XCTAssertFalse(model.iCloudEnabled)
            XCTAssertEqual(syncs, 1, "The sync stopped before it uploaded")
        }
    }

    /// Before any sync saved a user, an account notice, such as the one that follows signing
    /// in to iCloud as a failed sync asks, keeps storage on and syncs.
    func testSigningInToICloudAfterAFailedSyncKeepsStorageOn() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        var signedIn = false
        dependencies.syncCloud = {
            guard signedIn else { throw CloudStorageError.unavailable }
            return $0
        }
        dependencies.cloudUserRecordName = { signedIn ? "_fictional_user_1" : nil }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(
            model.cloudStatus,
            "iCloud could not sync. Local data is retained. Sign in to iCloud in Apple TV Settings, then sync again."
        )

        signedIn = true
        await model.cloudAccountChanged()
        XCTAssertTrue(model.iCloudEnabled)
        await model.waitForCloudSync()
        XCTAssertEqual(
            fixture.defaults.string(forKey: LibraryModel.cloudUserKey), "_fictional_user_1")
        XCTAssertTrue(model.cloudStatus.hasPrefix("Saved to iCloud."))
    }

    /// No sync starts while `cloudAccountChanged()` reads the user, so a sync queued then can't
    /// upload this library to another account. The held-back sync runs once the user matches.
    func testCloudAccountChangeHoldsSyncsWhileReadingTheUser() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        var syncs = 0
        dependencies.syncCloud = {
            syncs += 1
            return $0
        }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        var model: LibraryModel?
        var queueDuringRead = false
        var syncsDuringRead: Int?
        var user = "_fictional_user_1"
        dependencies.cloudUserRecordName = {
            if queueDuringRead, let model {
                queueDuringRead = false
                model.queueCloudSync(delay: .zero)
                await model.waitForCloudSync()
                syncsDuringRead = syncs
            }
            return user
        }
        model = LibraryModel(dependencies: dependencies)
        let library = try XCTUnwrap(model)
        await library.start()
        await library.waitForCloudSync()
        let before = syncs

        queueDuringRead = true
        await library.cloudAccountChanged()
        XCTAssertEqual(syncsDuringRead, before)
        await library.waitForCloudSync()
        XCTAssertEqual(syncs, before + 1)

        user = "_fictional_user_2"
        queueDuringRead = true
        await library.cloudAccountChanged()
        XCTAssertEqual(syncsDuringRead, before + 1)
        await library.waitForCloudSync()
        XCTAssertEqual(syncs, before + 1)
        XCTAssertFalse(library.iCloudEnabled)
    }

    /// A user that changes during a sync isn't recorded.
    func testCloudAccountChangeChecksTheUserAroundEachSync() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { $0 }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        // Every read before a sync sees one user and every read after it another.
        var reads = 0
        dependencies.cloudUserRecordName = {
            reads += 1
            return reads.isMultiple(of: 2) ? "_fictional_user_2" : "_fictional_user_1"
        }
        let library = LibraryModel(dependencies: dependencies)
        await library.start()
        await library.waitForCloudSync()
        XCTAssertGreaterThan(reads, 1)
        XCTAssertNil(fixture.defaults.string(forKey: LibraryModel.cloudUserKey))
    }

    /// Storage that is off has nothing to stop, so an account notice leaves it off with its
    /// status, and keeps the shown account.
    func testCloudAccountChangeLeavesStorageThatIsOffAlone() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        fixture.secrets.removeValue(forKey: "hardcover-token")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        var reads = 0
        dependencies.cloudUserRecordName = {
            reads += 1
            return "_fictional_user_2"
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.cloudAccountChanged()
        XCTAssertFalse(model.iCloudEnabled)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(model.cloudStatus, "")
        XCTAssertEqual(
            fixture.defaults.string(forKey: "activeHardcoverAccountID"),
            fixture.hardcoverAccountID)
        XCTAssertEqual(model.books.map(\.id), [1])
    }

    /// Turning storage on clears the user the last sync saved, so the next sync keeps storage
    /// on and saves the current user.
    func testTurningStorageOnSyncsWithTheCurrentUser() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        var syncs = 0
        dependencies.syncCloud = {
            syncs += 1
            return $0
        }
        dependencies.cloudUserRecordName = { "_fictional_user_2" }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        model.iCloudEnabled = true
        await model.waitForCloudSync()
        XCTAssertTrue(model.iCloudEnabled)
        XCTAssertEqual(syncs, 1)
        XCTAssertEqual(
            fixture.defaults.string(forKey: LibraryModel.cloudUserKey), "_fictional_user_2")
    }

    /// Turning storage off and on again while CloudKit reads the user is a newer choice too,
    /// though the setting ends where it began.
    func testCloudAccountChangeKeepsStorageToggledOffAndOnDuringTheRead() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { _ in throw CloudStorageError.unavailable }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        var model: LibraryModel?
        var toggleDuringRead = false
        dependencies.cloudUserRecordName = {
            if toggleDuringRead, let model {
                toggleDuringRead = false
                model.iCloudEnabled = false
                model.iCloudEnabled = true
            }
            return "_fictional_user_2"
        }
        model = LibraryModel(dependencies: dependencies)
        let library = try XCTUnwrap(model)
        await library.start()
        await library.waitForCloudSync()

        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        toggleDuringRead = true
        await library.cloudAccountChanged()
        XCTAssertFalse(toggleDuringRead)
        XCTAssertTrue(library.iCloudEnabled)
    }

    /// Turning storage off while a sync reads the user stops that sync before it uploads.
    func testTurningStorageOffWhileASyncReadsTheUserUploadsNothing() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        dependencies.sleep = { _ in }
        var syncs = 0
        dependencies.syncCloud = {
            syncs += 1
            return $0
        }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        var model: LibraryModel?
        var turnOffDuringRead = false
        dependencies.cloudUserRecordName = {
            if turnOffDuringRead {
                turnOffDuringRead = false
                model?.iCloudEnabled = false
            }
            return "_fictional_user_1"
        }
        model = LibraryModel(dependencies: dependencies)
        let library = try XCTUnwrap(model)
        await library.start()
        await library.waitForCloudSync()
        let before = syncs

        turnOffDuringRead = true
        library.queueCloudSync(delay: .zero)
        await library.waitForCloudSync()
        XCTAssertFalse(turnOffDuringRead)
        XCTAssertFalse(library.iCloudEnabled)
        XCTAssertEqual(syncs, before)
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
        dependencies.cloudUserRecordName = { nil }
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
        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        await model.cloudAccountChanged()
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
        XCTAssertEqual(model.cloudStatus, "")
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

    /// Launch's iCloud user check holds the sync back, and a due refresh waits for the check
    /// and the sync that follows it, so a fresh iCloud snapshot still skips the fetch.
    func testADueLaunchFetchWaitsForTheICloudUserCheckAndItsSync() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "iCloudEnabled")
        fixture.defaults.set("_fictional_user_1", forKey: LibraryModel.cloudUserKey)
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)], age: 86_401)])
        let remote = fixture.snapshot(.hardcover, books: [fixture.book(2)], age: 3_600)
        var dependencies = fixture.dependencies()
        dependencies.sleep = { duration in
            if duration == .seconds(10) { try await Task.sleep(for: .seconds(3_600)) }
        }
        dependencies.cloudUserRecordName = { "_fictional_user_1" }
        var reads = 0
        dependencies.syncCloud = { _ in
            reads += 1
            return CloudLibraryArchive(sources: [remote])
        }
        var fetches = 0
        dependencies.fetchHardcover = { _, _ in
            fetches += 1
            return HardcoverLibrary(
                accountID: fixture.hardcoverAccountID, books: [fixture.book(3)])
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.waitForCloudSync()
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.books.map(\.id), [2])
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
        dependencies.fetchSeriesLooks = { _, _ in ([:], true) }
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

/// The example profile: loading its folder, keeping it read-only, and leaving it. Fixtures are
/// fictional; tests never load the bundled profile. It shares this file's fixture.
@MainActor
final class ExampleProfileWorkflowTests: XCTestCase {
    private func exampleDesign(for book: Book, accountID: String = ExampleProfile.accountID)
        -> SpineDesignV1
    {
        SpineDesignV1(
            version: 1, accountID: accountID, bookID: book.id,
            workItemHash: SpineCloudIdentity.workItemHash(accountID: accountID, book: book),
            coverHash: String(repeating: "a", count: 64), generatorVersion: "ios-pcc-v2",
            generatedAt: Date(timeIntervalSince1970: 1_000), backgroundHex: "#102030",
            foregroundHex: "#FFFFFF", accentHex: "#FFFFFF", typeface: "serif", weight: 700,
            uppercase: false)
    }

    /// A fictional profile of books 7 and 8, with a design for book 7.
    private func exampleProfile(_ fixture: LibraryWorkflowFixture) -> ExampleProfile {
        let books = [fixture.book(7), fixture.book(8)]
        return ExampleProfile(
            books: books, series: [], designs: [7: exampleDesign(for: books[0])], looks: [:],
            syncedAt: fixture.time.addingTimeInterval(-86_400))
    }

    func testExampleProfileFolderKeepsOnlyValidRecords() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        let folder = fixture.directory.appending(path: "ExampleProfile")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var books = [fixture.book(7), fixture.book(8)]
        books[0].seriesID = 3
        let snapshot = SourceSnapshot(
            source: .hardcover, accountID: ExampleProfile.accountID, books: books,
            syncedAt: fixture.time,
            series: [SeriesInfo(id: 3, name: "Fictional Cycle", books: [])])
        try JSONEncoder().encode(CloudLibraryArchive(sources: [snapshot]))
            .write(to: folder.appending(path: "library-v1.json"))
        let kept = exampleDesign(for: books[0])
        // A design made before the book's title changed carries a stale `workItemHash`.
        var retitled = books[1]
        retitled.title += " (earlier title)"
        let stale = exampleDesign(for: retitled)
        try JSONEncoder()
            .encode([
                "kept": kept,
                // Another account's design, a design for a book the profile lacks, and a stale
                // design drop out.
                "other": exampleDesign(for: books[1], accountID: fixture.hardcoverAccountID),
                "missing": exampleDesign(for: fixture.book(9)),
                "stale": stale,
            ])
            .write(to: folder.appending(path: "spine-designs-v1.json"))
        let key = SeriesLookKey(seriesID: 3, group: "|fictionalauthor")
        try JSONEncoder()
            .encode(["look": SeriesLookV1(key: key, design: kept, createdAt: fixture.time)])
            .write(to: folder.appending(path: "series-looks-v1.json"))

        let loaded = await ExampleProfile.load(from: folder)
        let profile = try XCTUnwrap(loaded)
        XCTAssertEqual(profile.books.map(\.id), [7, 8])
        XCTAssertEqual(profile.series.map(\.id), [3])
        XCTAssertEqual(profile.designs, [7: kept])
        XCTAssertEqual(Array(profile.looks.keys), [key])
        XCTAssertEqual(profile.syncedAt, fixture.time)

        // The records file decodes as a whole, so one bad entry drops every design in it.
        let keptJSON = try XCTUnwrap(String(data: JSONEncoder().encode(kept), encoding: .utf8))
        try Data(#"{"kept": \#(keptJSON), "bad": {"version": 1}}"#.utf8)
            .write(to: folder.appending(path: "spine-designs-v1.json"))
        let partial = await ExampleProfile.load(from: folder)
        let partialProfile = try XCTUnwrap(partial, "A bad records file keeps the library")
        XCTAssertTrue(partialProfile.designs.isEmpty)
        XCTAssertEqual(Array(partialProfile.looks.keys), [key])

        // Only a version 1 archive with the example account's Hardcover source holds a profile.
        try JSONEncoder().encode(CloudLibraryArchive(version: 2, sources: [snapshot]))
            .write(to: folder.appending(path: "library-v1.json"))
        let newer = await ExampleProfile.load(from: folder)
        XCTAssertNil(newer, "A newer archive version holds no profile")
        var otherAccount = snapshot
        otherAccount.accountID = fixture.hardcoverAccountID
        try JSONEncoder().encode(CloudLibraryArchive(sources: [otherAccount]))
            .write(to: folder.appending(path: "library-v1.json"))
        let foreign = await ExampleProfile.load(from: folder)
        XCTAssertNil(foreign, "Another account's library holds no profile")

        try FileManager.default.removeItem(at: folder.appending(path: "library-v1.json"))
        let missing = await ExampleProfile.load(from: folder)
        XCTAssertNil(missing, "A folder without its library holds no profile")
    }

    func testExampleProfileIsReadOnlyUntilAConnectionReplacesIt() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        var dependencies = fixture.dependencies()
        let profile = exampleProfile(fixture)
        dependencies.exampleProfile = { profile }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(model.offersExample)

        let shown = await model.showExample()
        XCTAssertTrue(shown)
        XCTAssertTrue(model.isExample)
        XCTAssertTrue(model.isSample)
        XCTAssertFalse(model.offersExample)
        XCTAssertEqual(Set(model.books.map(\.id)), [7, 8])
        XCTAssertEqual(model.spineDesigns, profile.designs)
        XCTAssertEqual(model.now, profile.syncedAt)
        XCTAssertTrue(model.hasCompletedWelcome)
        XCTAssertFalse(model.canPickSeries(for: model.books[0]))
        // A refresh or a sync request reaches no source: the fixture fails any request.
        await model.refresh(manual: true)
        model.queueCloudSync()
        await model.waitForCloudSync()
        XCTAssertTrue(dependencies.sourceStore.load().isEmpty, "Nothing saves the example")
        model.hardcoverEnabled = false
        XCTAssertEqual(model.spineDesigns, profile.designs, "The cache prune keeps the example")

        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        dependencies.fetchHardcover = { _, _ in
            HardcoverLibrary(accountID: fixture.hardcoverAccountID, books: [fixture.book(1)])
        }
        dependencies.syncCloud = { $0 }
        let connecting = LibraryModel(dependencies: dependencies)
        await connecting.start()
        await connecting.showExample()
        let connected = await connecting.connect("hc_pat_fictional_original")
        XCTAssertTrue(connected)
        XCTAssertFalse(connecting.isExample)
        XCTAssertFalse(connecting.isSample)
        XCTAssertEqual(connecting.books.map(\.id), [1])
        XCTAssertTrue(connecting.spineDesigns.isEmpty, "Example designs never reach a library")
        XCTAssertEqual(dependencies.sourceStore.load().flatMap(\.books).map(\.id), [1])
    }

    func testAVerifiedTokenEndsTheExampleAndShowsTheSavedLibrary() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        // A disconnected account keeps its snapshot, which the disabled source hides.
        fixture.secrets.removeAll()
        fixture.defaults.set(false, forKey: "hardcoverEnabled")
        try fixture.save([fixture.snapshot(.hardcover, books: [fixture.book(1)])])
        var dependencies = fixture.dependencies()
        let profile = exampleProfile(fixture)
        dependencies.exampleProfile = { profile }
        dependencies.validateHardcover = { _ in fixture.hardcoverAccountID }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(model.books.isEmpty)
        let shown = await model.showExample()
        XCTAssertTrue(shown)

        let connected = await model.connect("hc_pat_fictional_original")
        XCTAssertTrue(connected)
        XCTAssertEqual(model.message, LibraryModel.verifiedTokenMessage)
        XCTAssertFalse(model.isExample)
        XCTAssertEqual(model.books.map(\.id), [1], "The saved library replaces the example's books")
        XCTAssertTrue(model.spineDesigns.isEmpty)
    }

    func testTurningOnICloudStorageEndsTheExample() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        var dependencies = fixture.dependencies()
        let profile = exampleProfile(fixture)
        dependencies.exampleProfile = { profile }
        dependencies.sleep = { _ in }
        var uploads: [CloudLibraryArchive] = []
        dependencies.syncCloud = { archive in
            uploads.append(archive)
            return archive
        }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.showExample()
        model.iCloudEnabled = false
        XCTAssertTrue(model.isExample, "Turning storage off keeps the example's records")
        XCTAssertEqual(model.spineDesigns, profile.designs)
        XCTAssertNil(model.spinesNote, "The example keeps its designs, so Spines has no note")

        model.iCloudEnabled = true
        XCTAssertFalse(model.isExample)
        XCTAssertTrue(model.books.isEmpty)
        XCTAssertTrue(model.spineDesigns.isEmpty, "Example designs never reach a library")
        await model.waitForCloudSync()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertTrue(
            uploads.allSatisfy { $0.sources.isEmpty }, "The example never uploads to iCloud")
    }

    func testLeavingTheExampleClearsItsShelfFilter() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        var dependencies = fixture.dependencies()
        let profile = exampleProfile(fixture)
        dependencies.exampleProfile = { profile }
        dependencies.sleep = { _ in }
        dependencies.syncCloud = { $0 }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        await model.showExample()
        model.shelfFilter = .author("Fictional author")

        model.iCloudEnabled = true
        XCTAssertFalse(model.isExample)
        XCTAssertNil(model.shelfFilter, "The real library opens unfiltered")
        await model.waitForCloudSync()
    }

    func testAMissingOrUnreadableExampleProfileShowsNothing() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.removeAll()
        var dependencies = fixture.dependencies()
        dependencies.exampleProfile = nil
        let bundleless = LibraryModel(dependencies: dependencies)
        await bundleless.start()
        XCTAssertFalse(bundleless.offersExample)
        let opened = await bundleless.showExample()
        XCTAssertFalse(opened)

        dependencies.exampleProfile = { nil }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(model.offersExample)
        let shown = await model.showExample()
        XCTAssertFalse(shown)
        XCTAssertFalse(model.isExample)
        XCTAssertFalse(model.isSample)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.message, "The welcome or empty shelf reports the failure")
        XCTAssertTrue(model.shouldOfferWelcome, "A failed read leaves the welcome available")
    }

    func testASavedLoginWithHardcoverOffDoesNotOfferTheExample() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "hardcoverEnabled")
        var dependencies = fixture.dependencies()
        let profile = exampleProfile(fixture)
        dependencies.exampleProfile = { profile }
        let model = LibraryModel(dependencies: dependencies)
        await model.start()
        XCTAssertTrue(model.hardcoverConnected)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.offersExample, "Turning the source back on must show its library")
        let shown = await model.showExample()
        XCTAssertFalse(shown)
    }

    func testExampleProfileFolderAppliesItsChosenCoversAndSeriesLinks() async throws {
        let fixture = try LibraryWorkflowFixture()
        defer { fixture.cleanUp() }
        let folder = fixture.directory.appending(path: "ExampleProfile")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let books = [fixture.book(7), fixture.book(8)]
        try JSONEncoder()
            .encode(
                CloudLibraryArchive(sources: [
                    SourceSnapshot(
                        source: .hardcover, accountID: ExampleProfile.accountID, books: books,
                        syncedAt: fixture.time)
                ])
            )
            .write(to: folder.appending(path: "library-v1.json"))
        let cover = try XCTUnwrap(URL(string: "https://covers.example.com/7.jpg"))
        func choice(_ bookID: Int, accountID: String = ExampleProfile.accountID) -> CoverChoiceV1 {
            CoverChoiceV1(
                version: 1, accountID: accountID, bookID: bookID, coverURL: cover,
                chosenAt: fixture.time)
        }
        // Another account's choice and a choice for a book the profile lacks drop out.
        try JSONEncoder()
            .encode([
                "kept": choice(7), "other": choice(8, accountID: fixture.hardcoverAccountID),
                "missing": choice(9),
            ])
            .write(to: folder.appending(path: "cover-choices-v1.json"))
        let link = SeriesLinkV1(
            accountID: ExampleProfile.accountID, bookID: 8, linkedSeriesID: 3,
            chosenAt: fixture.time)
        let missing = SeriesLinkV1(
            accountID: ExampleProfile.accountID, bookID: 9, standsAlone: true,
            chosenAt: fixture.time)
        try JSONEncoder().encode(["kept": link, "missing": missing])
            .write(to: folder.appending(path: "series-links-v1.json"))

        let loaded = await ExampleProfile.load(from: folder)
        let profile = try XCTUnwrap(loaded)
        XCTAssertEqual(profile.books.map(\.chosenCoverURL), [cover, nil])
        XCTAssertEqual(profile.links, [8: link])
    }
}
