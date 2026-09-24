import XCTest

@testable import Bookworms

@MainActor
final class SocialFeatureTests: XCTestCase {
    func testFeedKeepsLatestBookUpdateAcrossReadersBeforeLimiting() {
        func event(_ id: Int, book: Int, reader: Int, date: String?) -> FeedActivity {
            FeedActivity(
                id: id,
                reader: ReaderProfile(id: reader, username: "reader", name: nil, avatarURL: nil),
                createdAt: date, summary: "Update",
                book: Book(id: book, title: "Book", author: "Author"), likes: 0, rating: nil,
                review: nil, hasSpoilers: false)
        }
        let older = event(1, book: 1, reader: 1, date: "2026-09-17T10:00:00Z")
        let newest = event(2, book: 1, reader: 2, date: "2026-09-17T11:00:00.000Z")
        let tied = event(3, book: 2, reader: 1, date: "2026-09-17T11:00:00Z")
        let missing = event(4, book: 3, reader: 1, date: nil)
        XCTAssertEqual(
            FeedActivity.latestPerBook([older, missing, newest, tied, newest], limit: 2).map(\.id),
            [3, 2])
        XCTAssertEqual(FeedActivity.latestPerBook([older, newest, missing]).map(\.id), [2, 4])
    }

    func testDisabledViewsDoNotFetchUnusedDatasets() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Scope.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await model.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.shelf])
        var counts = await client.counts
        XCTAssertTrue(counts.isEmpty)
        await model.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.comparison])
        counts = await client.counts
        XCTAssertNil(counts["feed"])
        XCTAssertEqual(counts["following"], 1)
        XCTAssertEqual(counts["reader1"], 1)
        XCTAssertEqual(counts["reader2"], 1)
        await model.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.following])
        counts = await client.counts
        XCTAssertEqual(counts["feed"], 1)
        XCTAssertEqual(counts["reader1"], 1)
    }

    func testPurgedSocialSnapshotRecoversInsideDailyWindow() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Purge.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        let token = "hc_pat_fixture"
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await model.load(token: token, readerID: 2)
        try FileManager.default.removeItem(at: root)
        let restored = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await restored.load(token: token, readerID: 2)
        XCTAssertFalse(restored.mine.isEmpty)
        XCTAssertFalse(restored.books(for: 2).isEmpty)
        let counts = await client.counts
        XCTAssertEqual(counts["following"], 2)
        XCTAssertEqual(counts["reader2"], 2)
    }

    func testRepeatedManualRefreshIsCoalescedByCooldown() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Cooldown.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        var time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        await model.load(token: "hc_pat_fixture", readerID: 2, manual: true)
        await model.load(token: "hc_pat_fixture", readerID: 2, manual: true)
        var counts = await client.counts
        XCTAssertEqual(counts["feed"], 1)
        time += 11
        await model.load(token: "hc_pat_fixture", readerID: 2, manual: true)
        counts = await client.counts
        XCTAssertEqual(counts["feed"], 2)
    }

    func testCoverPolicyRequiresSavedKeyDesignAndAvailableFont() {
        for key in [false, true] {
            for design in [false, true] {
                for font in [false, true] {
                    XCTAssertEqual(
                        BookPresentation.usesSpine(
                            hasSavedKey: key, hasDesign: design, fontAvailable: font),
                        key && design && font)
                }
            }
        }
    }

    func testShelfNeverMixesCoversAndSpines() {
        let books = [
            Book(id: 1, title: "One", author: "Author"),
            Book(id: 2, title: "Two", author: "Author"),
        ]
        let style = SpineStyle.fallback(for: books[0])
        XCTAssertTrue(BookPresentation.uniformStyles(books: books, styles: [1: style]).isEmpty)
        XCTAssertEqual(
            BookPresentation.uniformStyles(books: books, styles: [1: style, 2: style]).count, 2)
    }

    func testCoversKeepAspectRatioAndPagesDoNotOverlap() {
        let books = (1...12).map { Book(id: $0, title: "Book \($0)", author: "Fixture") }
        let pages = BookPresentation.pages(
            books: books, styles: [:], coverRatios: [1: 1, 2: 0.5, 3: 2], width: 900, rowHeight: 300
        )
        XCTAssertEqual(pages.flatMap(\.books).map(\.id), books.map(\.id))
        for page in pages {
            let sizes = page.books.compactMap { page.dimensions[$0.id] }
            XCTAssertLessThanOrEqual(
                sizes.reduce(0) { $0 + $1.width } + Double(sizes.count - 1) * ShelfLayout.gap,
                900.01)
            for book in page.books {
                let size = page.dimensions[book.id]!
                XCTAssertEqual(
                    size.width / size.height, [1: 1.0, 2: 0.5, 3: 2.0][book.id] ?? 2.0 / 3.0,
                    accuracy: 0.001)
            }
        }
    }

    func testSharedRatingsIntersectBeforeLimitingAndKeepEachPersonsReview() {
        let mine = (1...150).map { item($0, rating: Double($0 % 6), review: "mine") }
        let theirs = [
            item(149, rating: 4.5, review: "theirs"), item(148, rating: 5), item(147, rating: nil),
        ]
        let shared = SharedRead.ranked(mine: mine, theirs: theirs, limit: 1)
        XCTAssertEqual(shared.first?.id, 149)
        XCTAssertEqual(shared.first?.mine.review, "mine")
        XCTAssertEqual(shared.first?.theirs.review, "theirs")
        XCTAssertEqual(shared.first?.combinedRating, 9.5)
    }

    func testStableTiesAndUnknownRatings() {
        let own = [item(2, rating: 4), item(1, rating: 4), item(3, rating: nil)]
        XCTAssertEqual(SharedRead.ranked(mine: own, theirs: own, limit: 100).map(\.id), [1, 2])
        XCTAssertEqual(ComparisonOrder.rating.select(own, limit: 20).map(\.id), [1, 2])
    }

    func testSharedReadsSortingAgreementAndDisagreement() {
        let mine = [
            item(1, rating: 5, review: "Great book!"),
            item(2, rating: 4, review: "Good read."),
            item(3, rating: 5, review: "Loved it!"),
            item(4, rating: 5, review: "Solid story."),
            item(5, rating: 5, review: nil),
            item(6, rating: 5, review: "   "),
        ]
        let theirs = [
            item(1, rating: 5, review: "Incredible!"),
            item(2, rating: 4, review: "Enjoyed it."),
            item(3, rating: 1, review: "Hated it."),
            item(4, rating: 5, review: nil),
            item(5, rating: 1, review: nil),
            item(6, rating: 5, review: nil),
        ]
        let agreement = SharedRead.ranked(mine: mine, theirs: theirs, sort: .agreement, limit: 10)
        XCTAssertEqual(agreement.map(\.id), [1, 2, 3, 4, 6, 5])

        let disagreement = SharedRead.ranked(
            mine: mine, theirs: theirs, sort: .disagreement, limit: 10)
        XCTAssertEqual(disagreement.map(\.id), [3, 1, 2, 4, 5, 6])
    }

    func testReviewsAreInertAndMissingReviewIsNotInvented() {
        XCTAssertNil(ReviewText.clean("  "))
        XCTAssertEqual(
            ReviewText.clean(
                "<script>secret()</script><p>Hello &amp; goodbye</p>[link](https://example.com)"),
            "Hello & goodbye\nlink")
        let book = item(1, rating: 4, review: nil)
        XCTAssertNil(book.reviewText)
    }

    func testViewPreferencesStayBoundedAndMyShelfCannotBeDisabled() throws {
        let suite = "ViewsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = BookwormsCoordinator(defaults: defaults)
        coordinator.setEnabled(.shelf, false)
        coordinator.switchView(-1)
        XCTAssertEqual(coordinator.current, .shared)
        coordinator.switchView(1)
        XCTAssertEqual(coordinator.current, .shelf)
        var preferences = ViewPreferences()
        preferences.enabled = [.following, .following]
        preferences.ambientMinutes = -1
        preferences.sessionMinutes = 4
        preferences.comparisonCount = 500
        preferences.validate()
        XCTAssertEqual(preferences.orderedViews, [.shelf, .following])
        XCTAssertEqual(preferences.ambientMinutes, 10)
        XCTAssertEqual(preferences.sessionMinutes, 0)
        XCTAssertEqual(preferences.comparisonCount, BookLimit.maximum)
        // Ambient views are independent of the menu; data covers both.
        XCTAssertEqual(preferences.ambientOrderedViews, BookwormsView.allCases)
        preferences.ambientViews = [.shared]
        XCTAssertEqual(preferences.ambientOrderedViews, [.shelf, .shared])
        XCTAssertEqual(preferences.activeViews, [.shelf, .following, .shared])
        let saved = try? JSONDecoder()
            .decode(
                ViewPreferences.self,
                from: Data(
                    #"{"enabled":["My Shelf"],"comparisonOrder":"Top rated · All time","sharedReadsSort":"Rating agreement","comparisonCount":20,"ambientMinutes":10,"sessionMinutes":0}"#
                        .utf8))
        XCTAssertNotNil(saved, "Preferences saved before ambient views still decode")
        XCTAssertNil(saved?.ambientViews)
    }

    func testAmbientCadenceExitAndIdleTimerRestoration() {
        var time = Date(timeIntervalSince1970: 1000)
        var idle = false
        let ambient = AmbientController(now: { time }, idleTimer: { idle = $0 })
        XCTAssertFalse(ambient.start(views: [], preferences: ViewPreferences(), voiceOver: false))
        XCTAssertFalse(idle)
        XCTAssertTrue(
            ambient.start(
                views: [.shelf, .following], preferences: ViewPreferences(), voiceOver: false))
        XCTAssertTrue(idle)
        time += 59
        ambient.tick(views: [.shelf, .following])
        XCTAssertEqual(ambient.contentIndex, 0)
        time += 1
        ambient.tick(views: [.shelf, .following])
        XCTAssertEqual(ambient.contentIndex, 1)
        time += 540
        ambient.tick(views: [.shelf, .following])
        XCTAssertEqual(ambient.view, .following)
        ambient.tick(views: [.shelf], voiceOver: true)
        XCTAssertFalse(ambient.isActive)
        XCTAssertFalse(idle)
    }

    func testAmbientSessionExpiryAndBackgroundStop() {
        var time = Date()
        var states: [Bool] = []
        let ambient = AmbientController(now: { time }, idleTimer: { states.append($0) })
        var preferences = ViewPreferences()
        preferences.sessionMinutes = 30
        ambient.start(views: [.shelf], preferences: preferences, voiceOver: false)
        time += 1800
        ambient.tick(views: [.shelf])
        XCTAssertEqual(states, [true, false])
        ambient.start(views: [.shelf], preferences: ViewPreferences(), voiceOver: false)
        ambient.tick(views: [.shelf], sceneActive: false)
        XCTAssertFalse(ambient.isActive)
        XCTAssertFalse(ambient.start(views: [.shelf], preferences: preferences, voiceOver: true))
    }

    func testSocialDailyScheduleManualOverrideAndNewReader() async throws {
        let suite = "SocialTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        var time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        let token = "hc_pat_" + String(repeating: "x", count: 32)
        await model.load(token: token, readerID: 2)
        let first = await client.counts
        await model.load(token: token, readerID: 2)
        let second = await client.counts
        XCTAssertEqual(first, second)
        XCTAssertEqual(model.shared(with: 2, limit: 20).count, 1)
        await model.load(token: token, readerID: 3)
        let third = await client.counts
        XCTAssertEqual(third["reader3"], 1)
        XCTAssertEqual(third["feed"], 1)
        time += 11
        await model.load(token: token, readerID: 3, manual: true)
        let fourth = await client.counts
        XCTAssertEqual(fourth["feed"], 2)
        let restored = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await restored.load(token: token, readerID: 3)
        XCTAssertEqual(restored.mine.count, 1)
        XCTAssertEqual(restored.books(for: 3).count, 1)
    }

    func testDeniedAccessClearsCacheButOfflineFailurePreservesIt() async throws {
        let suite = "SocialDeniedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        var time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        let token = "hc_pat_" + String(repeating: "x", count: 32)
        await model.load(token: token, readerID: 2)
        await client.fail(with: .offline)
        time += 11
        await model.load(token: token, readerID: 2, manual: true)
        XCTAssertFalse(model.mine.isEmpty)
        await client.fail(with: .denied)
        time += 11
        await model.load(token: token, readerID: 2, manual: true)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "1.json").path))
    }

    func testUnfollowRemovesComparisonAndFeed() async throws {
        let suite = "SocialUnfollowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        var time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        let token = "hc_pat_" + String(repeating: "x", count: 32)
        await model.load(token: token, readerID: 2)
        await client.unfollow()
        time += 11
        await model.load(token: token, readerID: 2, manual: true)
        XCTAssertTrue(model.books(for: 2).isEmpty)
        XCTAssertNil(model.reader(2))
    }

    func testSupersededReaderCannotInstallLateResponse() async throws {
        let suite = "SocialStale.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        await client.holdReaderTwo()
        let time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        let first = Task { await model.load(token: "hc_pat_fixture", readerID: 2) }
        while await client.counts["reader2"] == nil { await Task.yield() }
        await model.load(token: "hc_pat_fixture", readerID: 3)
        // Release the superseded request only after the newer reader has installed.
        await client.releaseReaderTwo()
        await first.value
        XCTAssertEqual(model.books(for: 3).count, 1)
        XCTAssertTrue(model.books(for: 2).isEmpty)
    }

    func testComparisonAndSharedSyncReaderSelection() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReaderSync.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await model.load(
            token: "hc_pat_fixture", readerID: 2, enabledViews: [.comparison, .shared])

        var preferences = ViewPreferences()
        preferences.readerID = 2
        model.prepare(preferences)

        XCTAssertEqual(model.presentation.reader?.id, 2)

        // Switch to reader 3
        preferences.readerID = 3
        model.prepare(preferences)

        XCTAssertEqual(model.presentation.reader?.id, 3)
    }

    func testSpoilerPolicyAndReadStatusCheck() {
        XCTAssertEqual(SpoilerPolicy.alwaysHide.rawValue, "Always hide")
        XCTAssertEqual(SpoilerPolicy.showIfRead.rawValue, "Show for read books")

        let library = LibraryModel()
        library.showSample()

        // SampleLibrary book 1 has finished: "2026-09-09"
        XCTAssertTrue(library.isBookReadByUser(1))
        // SampleLibrary book 4 has finished: nil, isRead: nil
        XCTAssertFalse(library.isBookReadByUser(4))
        // Non-existent book
        XCTAssertFalse(library.isBookReadByUser(9999))
    }

    private func item(_ id: Int, rating: Double?, review: String? = nil) -> ReaderBook {
        ReaderBook(
            book: Book(id: id, title: "Same", author: "Fixture"), rating: rating, review: review,
            hasSpoilers: false, finished: nil)
    }
}

private actor SocialFixtureClient: SocialLibraryFetching {
    enum Failure { case offline, denied }
    var counts: [String: Int] = [:]
    private var failure: Failure?
    private var unfollowed = false
    private var holdsReaderTwo = false
    private var readerTwoGate: CheckedContinuation<Void, Never>?
    /// Holds reader 2's library response until `releaseReaderTwo()`.
    func holdReaderTwo() { holdsReaderTwo = true }
    func releaseReaderTwo() {
        holdsReaderTwo = false
        readerTwoGate?.resume()
        readerTwoGate = nil
    }
    func fail(with failure: Failure) { self.failure = failure }
    func unfollow() { unfollowed = true }
    func owner(token: String) async throws -> ReaderProfile {
        counts["owner", default: 0] += 1
        return profile(1)
    }
    func following(owner: Int, token: String) async throws -> [ReaderProfile] {
        counts["following", default: 0] += 1
        if let failure {
            switch failure {
            case .offline: throw URLError(.notConnectedToInternet)
            case .denied: throw HardcoverError.forbidden
            }
        }
        return unfollowed ? [profile(3)] : [profile(2), profile(3)]
    }
    func feed(users: [Int], token: String) async throws -> [FeedActivity] {
        counts["feed", default: 0] += 1
        return []
    }
    func library(user: Int, token: String) async throws -> [ReaderBook] {
        counts["reader\(user)", default: 0] += 1
        if user == 2 && holdsReaderTwo {
            await withCheckedContinuation { readerTwoGate = $0 }
        }
        return [
            ReaderBook(
                book: Book(id: 10, title: "Fixture", author: "Fixture"), rating: 4,
                review: "Review", hasSpoilers: false, finished: nil)
        ]
    }
    private func profile(_ id: Int) -> ReaderProfile {
        ReaderProfile(id: id, username: "reader\(id)", name: nil, avatarURL: nil)
    }
}
