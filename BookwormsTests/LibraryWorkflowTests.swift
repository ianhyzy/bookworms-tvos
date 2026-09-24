import XCTest

@testable import Bookworms

@MainActor
final class LibraryWorkflowTests: XCTestCase {
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
        dependencies.fetchHardcover = { _ in [fixture.book(3)] }
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
        XCTAssertEqual(model.connectionRevision, 0)
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
        dependencies.validateHardcover = { _ in try await response.value() }
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
            return [fixture.book(fetches + 1)]
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
        let response = ControlledLibraryResponse<[Book]>("Hardcover request started")
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
        response.resolve([fixture.book(99)])
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
        let response = ControlledLibraryResponse<[Book]>("Request started")
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
        response.resolve([fixture.book(99)])
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
    var time = Date(timeIntervalSince1970: 1_780_000_000)
    var secrets = ["hardcover-token": "hc_pat_fictional_original"]

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "iCloudEnabled")
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
            source: source, accountID: source == .hardcover ? "hardcover" : configuration.identity,
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
