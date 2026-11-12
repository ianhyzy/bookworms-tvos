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
        let goal = FeedActivity(
            id: 5, reader: older.reader, createdAt: "2026-09-18T10:00:00Z",
            summary: "Shared a reading update", book: nil, likes: 0, rating: nil, review: nil,
            hasSpoilers: false)
        XCTAssertEqual(
            FeedActivity.latestPerBook([goal, newest]).map(\.id), [2],
            "Bookless events are left out")
    }

    /// An empty Feed asks the reader to connect only before any account's data loads: it says
    /// it's loading while social data loads, that there's no activity once it has, and that it
    /// couldn't load after a failure other than a denied login or permission.
    func testEmptyFeedMessageFollowsTheLoad() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmptyFeed.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        XCTAssertTrue(model.emptyFeedMessage.hasPrefix("Connect Hardcover"))

        await client.hold("reader2")
        let load = Task {
            await model.load(
                token: "hc_pat_fixture", readerID: 2, enabledViews: [.following, .comparison])
        }
        // The held library of reader 2 keeps the load running after the feed arrives.
        for _ in 0..<100 where !model.isLoading { await Task.yield() }
        XCTAssertEqual(model.emptyFeedMessage, "Loading activity from people you follow…")
        await client.release("reader2")
        await load.value
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertEqual(model.emptyFeedMessage, "People you follow have no recent activity.")

        let offlineClient = SocialFixtureClient()
        await offlineClient.fail(with: .offline)
        let offline = SocialLibraryModel(
            client: offlineClient,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "EmptyFeed.\(UUID())")),
            cacheRoot: root.appending(path: "offline"))
        await offline.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.following])
        XCTAssertFalse(offline.isLoading)
        XCTAssertEqual(
            offline.emptyFeedMessage,
            "Activity from people you follow couldn't load. Try again later.")
    }

    /// A first load whose Following request succeeds and Feed request fails says the activity
    /// couldn't load, not that there is none.
    func testEmptyFeedMessageReportsAFailedFeedAfterFollowingLoads() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FailedFeed.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        await client.failFeed()
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await model.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.following])
        XCTAssertNotNil(model.snapshot, "Following installed before the feed failed")
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(
            model.emptyFeedMessage,
            "Activity from people you follow couldn't load. Try again later.")
    }

    /// A library that fails after an empty feed loads leaves Feed saying there's no activity.
    func testEmptyFeedMessageIgnoresALibraryFailureAfterTheFeedLoads() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LateFailure.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        await client.failLibrary(of: 2)
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await model.load(
            token: "hc_pat_fixture", readerID: 2, enabledViews: [.following, .comparison])
        let counts = await client.counts
        XCTAssertEqual(counts["reader2"], 1, "The load reached reader 2's library")
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.emptyFeedMessage, "People you follow have no recent activity.")
    }

    /// Without a reader to compare with, Compare Shelves and Book Club point at the reader picker
    /// only when the reader follows someone. Otherwise they say why there is nobody to choose.
    func testNoReaderMessageFollowsTheFollowingList() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func model(_ name: String, _ client: SocialFixtureClient) throws -> SocialLibraryModel {
            let model = SocialLibraryModel(
                client: client,
                defaults: try XCTUnwrap(UserDefaults(suiteName: "NoReader.\(UUID())")),
                cacheRoot: root.appending(path: name))
            XCTAssertTrue(model.noReaderMessage.hasPrefix("Connect Hardcover"))
            return model
        }
        func load(_ model: SocialLibraryModel) async {
            await model.load(token: "hc_pat_fixture", readerID: nil, enabledViews: [.comparison])
        }
        let followingClient = SocialFixtureClient()
        await followingClient.hold("following")
        let following = try model("following", followingClient)
        let pending = Task { await load(following) }
        while await followingClient.counts["following"] == nil { await Task.yield() }
        XCTAssertEqual(following.noReaderMessage, "Loading the people you follow…")
        await followingClient.release("following")
        await pending.value
        XCTAssertEqual(following.noReaderMessage, "Choose a reader above.")

        let nobodyClient = SocialFixtureClient()
        await nobodyClient.followNobody()
        let nobody = try model("nobody", nobodyClient)
        await load(nobody)
        XCTAssertEqual(
            nobody.noReaderMessage,
            "Follow readers on Hardcover to compare your books with theirs.")

        let offlineClient = SocialFixtureClient()
        await offlineClient.fail(with: .offline)
        let offline = try model("offline", offlineClient)
        await load(offline)
        XCTAssertEqual(
            offline.noReaderMessage, "The people you follow couldn't load. Try again later.")
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

        let picksDefaults = try XCTUnwrap(UserDefaults(suiteName: "Scope.\(UUID())"))
        let picksRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: picksRoot) }
        let picksClient = SocialFixtureClient()
        await picksClient.failFeed()
        let picks = SocialLibraryModel(
            client: picksClient, defaults: picksDefaults, cacheRoot: picksRoot)
        await picks.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.friendsPicks])
        counts = await picksClient.counts
        XCTAssertEqual(counts["feed"], 1, "Friends' Picks ranks feed ratings")
        XCTAssertEqual(
            [counts["reader1"], counts["reader2"], counts["reader3"]], [1, 1, 1],
            "A feed failure doesn't stop Friends' Picks from syncing libraries")

        let deniedDefaults = try XCTUnwrap(UserDefaults(suiteName: "Scope.\(UUID())"))
        let deniedRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: deniedRoot) }
        let deniedClient = SocialFixtureClient()
        await deniedClient.failFeed(denied: true)
        let denied = SocialLibraryModel(
            client: deniedClient, defaults: deniedDefaults, cacheRoot: deniedRoot)
        await denied.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.friendsPicks])
        XCTAssertNil(denied.snapshot, "Denied feed access reaches the error handler")
        counts = await deniedClient.counts
        XCTAssertNil(counts["reader1"])
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
        XCTAssertFalse(restored.snapshot?.mine.isEmpty ?? true)
        XCTAssertFalse(restored.books(for: 2).isEmpty)
        let counts = await client.counts
        XCTAssertEqual(counts["following"], 2)
        XCTAssertEqual(counts["reader2"], 2)
    }

    func testRejectedTokenRenewsOnceAndRenewedTokensKeepTheCache() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Renewal.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        await client.reject("hc_at_fixture_old")
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        var renewals: [String] = []
        await model.load(
            token: "hc_at_fixture_old", account: "1", readerID: 2, enabledViews: [.comparison],
            renewToken: { rejected in
                renewals.append(rejected)
                return "hc_at_fixture_new"
            })
        XCTAssertEqual(renewals, ["hc_at_fixture_old"])
        XCTAssertFalse(model.snapshot?.mine.isEmpty ?? true)
        XCTAssertFalse(model.books(for: 2).isEmpty)
        let tokens = await client.tokens
        XCTAssertEqual(tokens.first, "hc_at_fixture_old")
        XCTAssertEqual(Set(tokens.dropFirst()), ["hc_at_fixture_new"])

        // A later token of the same account reads the cache without asking for its owner again.
        let owners = await client.counts["owner"]
        let restored = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await restored.load(
            token: "hc_at_fixture_newer", account: "1", readerID: 2, enabledViews: [.comparison])
        XCTAssertFalse(restored.books(for: 2).isEmpty)
        let restoredOwners = await client.counts["owner"]
        XCTAssertEqual(restoredOwners, owners)
    }

    func testFailedRenewalDuringFriendsPicksFeedKeepsTheCache() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RenewalFailure.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        await client.failFeed()
        var time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        // Caches Following; the failed feed stays due without the readers' libraries.
        await model.load(token: "hc_at_fixture_old", readerID: 2, enabledViews: [.following])
        XCTAssertFalse(model.following.isEmpty)

        time += 301
        await client.reject("hc_at_fixture_old")
        let sent = await client.tokens.count
        var renewals = 0
        await model.load(
            token: "hc_at_fixture_old", readerID: 2, enabledViews: [.friendsPicks],
            renewToken: { _ in
                renewals += 1
                throw URLError(.timedOut)
            })
        XCTAssertEqual(renewals, 1)
        XCTAssertFalse(model.following.isEmpty, "A failed renewal keeps the cached snapshot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "1.json").path))
        XCTAssertTrue(model.status.contains("Cached data is retained"))
        XCTAssertTrue(model.status.contains("Hardcover did not respond in time"), model.status)
        let tokens = await client.tokens
        XCTAssertEqual(
            tokens.count - sent, 1, "The load stops instead of sending the rejected token again")
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

    func testCoverPolicyRequiresSavedKeyAndAvailableFont() {
        for key in [false, true] {
            for font in [false, true] {
                XCTAssertEqual(
                    BookPresentation.usesSpine(hasSavedKey: key, fontAvailable: font), key && font)
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

    func testReviewsAreInertAndMissingReviewIsNotInvented() throws {
        XCTAssertNil(ReviewText.clean("  "))
        XCTAssertEqual(
            ReviewText.clean(
                "<script>secret()</script><p>Hello &amp; goodbye</p>[link](https://example.com)"),
            "Hello & goodbye\nlink")
        let book = item(1, rating: 4, review: nil)
        XCTAssertNil(book.reviewText)
        // The cache stores the raw review; decoding cleans it again.
        let data = try JSONEncoder().encode(item(2, rating: 4, review: "<p>Kept &amp; clean</p>"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("reviewText"))
        XCTAssertEqual(
            try JSONDecoder().decode(ReaderBook.self, from: data).reviewText, "Kept & clean")
    }

    func testViewPreferencesStayBoundedAndKeepOneSidebarView() throws {
        let suite = "ViewsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = BookwormsCoordinator(defaults: defaults)
        coordinator.setEnabled(.shelf, false)
        XCTAssertEqual(
            coordinator.current, .yearInReview, "Hiding the current view moves to the first")
        coordinator.switchView(-1)
        XCTAssertEqual(coordinator.current, .friendsPicks)
        coordinator.switchView(1)
        XCTAssertEqual(coordinator.current, .yearInReview)
        for view in [BookwormsView.yearInReview, .bookWall, .following, .comparison, .shared] {
            coordinator.setEnabled(view, false)
        }
        XCTAssertEqual(
            coordinator.preferences.orderedViews, [.friendsPicks], "The last view stays")
        coordinator.setInAmbient(.shelf, false)
        XCTAssertFalse(coordinator.preferences.ambientOrderedViews.contains(.shelf))
        coordinator.setInAmbient(.shelf, true)
        XCTAssertTrue(coordinator.preferences.ambientOrderedViews.contains(.shelf))
        var preferences = ViewPreferences()
        preferences.enabled = [.following, .following]
        preferences.ambientMinutes = -1
        preferences.sessionMinutes = 4
        preferences.comparisonCount = 500
        preferences.validate()
        XCTAssertEqual(preferences.orderedViews, [.following])
        XCTAssertEqual(preferences.ambientMinutes, 10)
        XCTAssertEqual(preferences.sessionMinutes, 0)
        XCTAssertEqual(preferences.comparisonCount, BookLimit.maximum)
        // Ambient views are independent of the menu; data covers both.
        XCTAssertEqual(
            preferences.ambientOrderedViews, BookwormsView.allCases.filter(\.supportsAmbient))
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
        let revision = model.revision
        await model.load(token: token, readerID: 2)
        let second = await client.counts
        XCTAssertEqual(first, second)
        XCTAssertEqual(model.revision, revision, "A load with nothing due doesn't reinstall")
        var preferences = ViewPreferences()
        preferences.readerID = 2
        model.prepare(preferences)
        XCTAssertEqual(model.presentation.shared.count, 1)
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
        XCTAssertEqual(restored.snapshot?.mine.count, 1)
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
        XCTAssertFalse(model.snapshot?.mine.isEmpty ?? true)
        await client.fail(with: .denied)
        time += 11
        await model.load(token: token, readerID: 2, manual: true)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "1.json").path))
    }

    /// A first load that reads the cache file and is then denied deletes that file, though it
    /// never installed it.
    func testDeniedFirstLoadDeletesTheCacheFileItRead() async throws {
        let suite = "SocialDeniedFirst.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        let token = "hc_pat_" + String(repeating: "x", count: 32)
        let cached = SocialSnapshot(
            owner: ReaderProfile(id: 1, username: "reader1", name: nil, avatarURL: nil))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(cached).write(to: root.appending(path: "1.json"))
        await client.fail(with: .denied)
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await model.load(token: token, readerID: 2)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "1.json").path))
    }

    /// A manual load during a matching automatic load runs its own requests instead of waiting
    /// for the automatic one, which skipped datasets that aren't due.
    func testManualLoadDuringAnAutomaticLoadBypassesTheDailyGates() async throws {
        let suite = "SocialManualInFlight.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        let time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        let token = "hc_pat_" + String(repeating: "x", count: 32)
        await client.hold("reader2")
        let automatic = Task { await model.load(token: token, readerID: 2) }
        while await client.counts["reader2"] == nil { await Task.yield() }
        let manual = Task { await model.load(token: token, readerID: 2, manual: true) }
        // A manual load that waited on the automatic one would never request Following again.
        for _ in 0..<10_000 where await client.counts["following"] != 2 { await Task.yield() }
        await client.release("reader2")
        await automatic.value
        await manual.value
        let counts = await client.counts
        XCTAssertEqual(counts["following"], 2, "The manual load skips the daily gate")
    }

    /// Settings → Sources shows the status, so it names neither Settings nor raw scopes. A missing
    /// permission names Disconnect, the button that state shows, and a rejected login doesn't
    /// blame social permissions.
    func testRejectedLoginAndMissingPermissionExplainThemselvesPlainly() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SocialStatus.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SocialFixtureClient()
        await client.reject("hc_at_fixture_old")
        let model = SocialLibraryModel(client: client, defaults: defaults, cacheRoot: root)
        await model.load(
            token: "hc_at_fixture_old", readerID: 2,
            renewToken: { _ in throw HardcoverError.invalidToken })
        XCTAssertEqual(model.status, "The Hardcover login is invalid or expired.")

        let scoped = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root.appending(path: "scope"))
        await client.fail(with: .scope)
        await scoped.load(token: "hc_at_fixture_new", readerID: 2)
        XCTAssertTrue(scoped.status.contains("permission to see the readers you follow"))
        XCTAssertTrue(scoped.status.contains("Disconnect Hardcover"))
        for status in [model.status, scoped.status] {
            XCTAssertFalse(status.contains("Settings"), status)
            XCTAssertFalse(status.contains("read:"), status)
        }
    }

    func testDeniedReaderLibraryIsEmptyAndKeepsOtherSocialData() async throws {
        let suite = "SocialDeniedReaderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        await client.deny(reader: 2)
        var time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        await model.load(
            token: "hc_pat_fixture", readerID: 2, enabledViews: [.comparison, .friendsPicks])
        // Past the five-minute retry backoff, only a saved sync date keeps reader 2 from being due.
        time += 301
        await model.load(
            token: "hc_pat_fixture", readerID: 2, enabledViews: [.comparison, .friendsPicks])
        XCTAssertNotNil(model.snapshot, "One reader's denial keeps the rest of the social data")
        XCTAssertNotNil(model.reader(2))
        XCTAssertTrue(model.books(for: 2).isEmpty)
        XCTAssertFalse(model.books(for: 3).isEmpty)
        XCTAssertFalse(model.snapshot?.mine.isEmpty ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "1.json").path))
        let counts = await client.counts
        XCTAssertEqual(counts["reader2"], 1, "The empty library counts as synced for the day")
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

    /// Choosing another reader while a library downloads drops that download, whether it ends
    /// with a late response or by throwing when it finds its load cancelled. It isn't a failed
    /// attempt, so choosing the first reader again downloads their library at once.
    func testSupersededReaderCannotInstallLateResponse() async throws {
        for throwing in [false, true] {
            let suite = "SocialStale.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let client = SocialFixtureClient()
            await client.hold("reader2", throwingWhenCancelled: throwing)
            let time = Date()
            let model = SocialLibraryModel(
                client: client, defaults: defaults, cacheRoot: root, now: { time })
            // Compare Shelves alone downloads only the selected reader's library.
            let views: Set<BookwormsView> = [.comparison]
            let first = Task {
                await model.load(token: "hc_pat_fixture", readerID: 2, enabledViews: views)
            }
            while await client.counts["reader2"] == nil { await Task.yield() }
            await model.load(token: "hc_pat_fixture", readerID: 3, enabledViews: views)
            // Release the superseded request only after the newer reader has installed.
            await client.release("reader2")
            await first.value
            XCTAssertEqual(model.books(for: 3).count, 1)
            XCTAssertTrue(model.books(for: 2).isEmpty)
            await model.load(token: "hc_pat_fixture", readerID: 2, enabledViews: views)
            XCTAssertEqual(model.books(for: 2).count, 1, "Throwing when cancelled: \(throwing)")
        }
    }

    /// A library that fails to download waits five minutes before an automatic load retries it.
    func testFailedLibraryWaitsFiveMinutesBeforeAnAutomaticRetry() async throws {
        let suite = "SocialBackoff.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let client = SocialFixtureClient()
        await client.failLibrary(of: 2)
        var time = Date()
        let model = SocialLibraryModel(
            client: client, defaults: defaults, cacheRoot: root, now: { time })
        for (elapsed, requests) in [(0.0, 1), (299, 1), (2, 2)] {
            time += elapsed
            await model.load(token: "hc_pat_fixture", readerID: 2, enabledViews: [.comparison])
            let counts = await client.counts
            XCTAssertEqual(counts["reader2"], requests)
        }
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

        XCTAssertFalse(SpoilerPolicy.alwaysHide.hides(hasSpoilers: false, isRead: false))
        XCTAssertTrue(SpoilerPolicy.alwaysHide.hides(hasSpoilers: true, isRead: true))
        XCTAssertFalse(SpoilerPolicy.showIfRead.hides(hasSpoilers: true, isRead: true))
        XCTAssertTrue(SpoilerPolicy.showIfRead.hides(hasSpoilers: true, isRead: false))
    }

    func testFriendPicksRankUnreadBooksByFansThenRating() {
        func reader(_ id: Int) -> ReaderProfile {
            ReaderProfile(id: id, username: "r\(id)", name: "Reader \(id)", avatarURL: nil)
        }
        func item(_ id: Int, _ rating: Double?, finished: String? = "2026-01-01") -> ReaderBook {
            ReaderBook(
                book: Book(id: id, title: "Book \(id)", author: "A"), rating: rating, review: nil,
                hasSpoilers: false, finished: finished)
        }
        var readBook = Book(id: 16, title: "Book 16", author: "A")
        readBook.isRead = true
        let markedRead = ReaderBook(
            book: readBook, rating: 5, review: nil, hasSpoilers: false, finished: nil)
        let snapshot = SocialSnapshot(
            owner: reader(1), following: [reader(2), reader(3), reader(4)],
            activities: [
                FeedActivity(
                    id: 1, reader: reader(4), createdAt: nil, summary: "", book: item(12, nil).book,
                    likes: 0, rating: 4.5, review: nil, hasSpoilers: false)
            ],
            mine: [item(10, 5), item(13, nil, finished: nil), markedRead],
            readerBooks: [
                2: [
                    item(10, 5), item(11, 4), item(12, 5), item(13, 4), item(14, 3.5), item(16, 5),
                ],
                3: [item(11, 5), item(12, 4)],
                9: [item(15, 5)],
            ])
        let picks = FriendPick.ranked(snapshot, limit: 40)
        XCTAssertEqual(
            picks.map(\.id), [12, 11, 13],
            "Read books, including those marked Read without a date, low ratings, and unfollowed "
                + "readers are left out; Want to Read stays")
        XCTAssertEqual(picks[0].fans.map(\.id), [2, 4, 3], "Feed ratings count as fans")
        XCTAssertEqual(picks[1].averageRating, 4.5)
        XCTAssertEqual(
            FriendPick.ranked(snapshot, alsoRead: [13], limit: 40).map(\.id), [12, 11],
            "A book the library marks Read without a rating or date isn't in mine but is left out")
        XCTAssertEqual(
            FriendPick.readersToSync(snapshot, limit: 2), [4, 2],
            "The most active readers in the feed sync first")
    }

    func testFriendReadsIndexFollowedReadersRatedFirst() {
        func reader(_ id: Int, _ name: String) -> ReaderProfile {
            ReaderProfile(id: id, username: "r\(id)", name: name, avatarURL: nil)
        }
        func item(_ id: Int, _ rating: Double?) -> ReaderBook {
            ReaderBook(
                book: Book(id: id, title: "Book \(id)", author: "A"), rating: rating, review: nil,
                hasSpoilers: false, finished: nil)
        }
        let snapshot = SocialSnapshot(
            owner: reader(1, "Owner"),
            following: [reader(2, "Blair"), reader(3, "Avery"), reader(4, "Casey")],
            readerBooks: [
                2: [item(10, 4), item(11, nil)],
                3: [item(10, 4), item(11, 5)],
                4: [item(10, nil)],
                9: [item(10, 5)],
            ])
        let index = FriendRead.byBook(snapshot)
        XCTAssertEqual(
            index.reads[10]?.map(\.reader.id), [3, 2, 4],
            "Rated first, ties by name; readers you don't follow are left out")
        XCTAssertEqual(index.reads[11]?.map(\.rating), [5, nil])
        XCTAssertNil(index.reads[12], "A book no friend has shows no row")
        XCTAssertEqual(Set(index.readers.map(\.id)), [2, 3, 4])
    }

    private func item(_ id: Int, rating: Double?, review: String? = nil) -> ReaderBook {
        ReaderBook(
            book: Book(id: id, title: "Same", author: "Fixture"), rating: rating, review: review,
            hasSpoilers: false, finished: nil)
    }
}

private actor SocialFixtureClient: SocialLibraryFetching {
    enum Failure { case offline, denied, scope }
    var counts: [String: Int] = [:]
    /// Every token a request sent, in order.
    var tokens: [String] = []
    private var rejectedToken: String?
    /// Answers requests that send `token` with HTTP 401.
    func reject(_ token: String) { rejectedToken = token }
    private func authorize(_ token: String) throws {
        tokens.append(token)
        if token == rejectedToken { throw HardcoverError.invalidToken }
    }
    private var failure: Failure?
    private var followed = [2, 3]
    private var held: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelledRequestsThrow = false
    /// Holds every response to `request`, named as in `counts`, until `release(_:)`. A held
    /// request whose load was cancelled meanwhile still answers, or with `throwingWhenCancelled`
    /// throws, as the Hardcover client does when it finds the cancellation between pages.
    func hold(_ request: String, throwingWhenCancelled: Bool = false) {
        held.insert(request)
        cancelledRequestsThrow = throwingWhenCancelled
    }
    func release(_ request: String) {
        held.remove(request)
        for gate in gates.removeValue(forKey: request) ?? [] { gate.resume() }
    }
    private func waitWhileHeld(_ request: String) async throws {
        guard held.contains(request) else { return }
        await withCheckedContinuation { gates[request, default: []].append($0) }
        if cancelledRequestsThrow { try Task.checkCancellation() }
    }
    private var feedFailure: Error?
    func fail(with failure: Failure) { self.failure = failure }
    func failFeed(denied: Bool = false) {
        feedFailure = denied ? HardcoverError.forbidden : URLError(.timedOut)
    }
    func unfollow() { followed = [3] }
    func followNobody() { followed = [] }
    private var failingReaders: Set<Int> = []
    /// Answers requests for `reader`'s library with a network timeout.
    func failLibrary(of reader: Int) { failingReaders.insert(reader) }
    private var deniedReaders: Set<Int> = []
    /// Answers requests for `reader`'s library with HTTP 403, as for a private account.
    func deny(reader: Int) { deniedReaders.insert(reader) }
    func owner(token: String) async throws -> ReaderProfile {
        try authorize(token)
        counts["owner", default: 0] += 1
        return profile(1)
    }
    func following(owner: Int, token: String) async throws -> [ReaderProfile] {
        try authorize(token)
        counts["following", default: 0] += 1
        try await waitWhileHeld("following")
        if let failure {
            switch failure {
            case .offline: throw URLError(.notConnectedToInternet)
            case .denied: throw HardcoverError.forbidden
            case .scope: throw HardcoverError.insufficientScope
            }
        }
        return followed.map { profile($0) }
    }
    func feed(users: [Int], token: String) async throws -> [FeedActivity] {
        try authorize(token)
        counts["feed", default: 0] += 1
        if let feedFailure { throw feedFailure }
        return []
    }
    func library(user: Int, token: String) async throws -> [ReaderBook] {
        try authorize(token)
        counts["reader\(user)", default: 0] += 1
        if deniedReaders.contains(user) { throw HardcoverError.forbidden }
        if failingReaders.contains(user) { throw URLError(.timedOut) }
        try await waitWhileHeld("reader\(user)")
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
