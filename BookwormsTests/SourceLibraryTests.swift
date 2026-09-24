import XCTest

@testable import Bookworms

final class SourceLibraryTests: XCTestCase {
    func testOPDSReadsBooksWithoutInventingReadDatesOrRatings() throws {
        let data = Data(
            #"""
            <feed xmlns="http://www.w3.org/2005/Atom">
              <link rel="next" href="/books/opds/new?offset=20"/>
              <entry><id>urn:uuid:abc</id><title>A &amp; B</title><author><name>One Author</name></author>
                <published>2021-04-01T00:00:00Z</published><updated>2026-09-10T00:00:00Z</updated>
                <summary>A description.</summary><category term="Fantasy"/>
                <link rel="http://opds-spec.org/image" href="/books/opds/cover/4"/>
                <link rel="http://opds-spec.org/acquisition" href="/books/opds/download/4/epub"/>
              </entry>
            </feed>
            """#
            .utf8)
        let page = URL(string: "https://example.com/books/opds/new")!
        let feed = try OPDSFeed.parse(data, url: page, server: "https://example.com/books")
        let book = try XCTUnwrap(feed.books.first)
        XCTAssertEqual(book.title, "A & B")
        XCTAssertEqual(book.author, "One Author")
        XCTAssertEqual(book.publicationYear, 2021)
        XCTAssertEqual(book.isOwned, true)
        XCTAssertNil(book.finished)
        XCTAssertNil(book.rating)
        XCTAssertFalse(book.isHardcoverBook)
        XCTAssertEqual(book.coverURL?.absoluteString, "https://example.com/books/opds/cover/4")
        XCTAssertEqual(feed.next?.absoluteString, "https://example.com/books/opds/new?offset=20")
    }

    func testLoginHTMLAndPartialCatalogAreRejected() {
        for xml in [
            "<html><body>Login</body></html>",
            "<feed xmlns='http://www.w3.org/2005/Atom'><entry><title>Broken</title></entry></feed>",
            "<feed>",
        ] {
            XCTAssertThrowsError(
                try OPDSFeed.parse(
                    Data(xml.utf8), url: URL(string: "https://example.com")!, server: "example"))
        }
    }

    func testCredentialsStayOnHTTPSOrigin() {
        let base = URL(string: "https://example.com")!
        XCTAssertTrue(
            SourceRedirectPolicy.sameOrigin(base, URL(string: "https://example.com/opds")!))
        for url in [
            "https://other.com/opds", "http://example.com/opds", "https://example.com:444/opds",
            "https://user:pass@example.com",
        ] {
            XCTAssertFalse(SourceRedirectPolicy.sameOrigin(base, URL(string: url)!))
        }
    }

    func testSourceIDsAreStableAndNamespaced() {
        let id = CWAConfiguration.bookID(server: "https://example.com", identifier: "abc")
        XCTAssertEqual(
            id, CWAConfiguration.bookID(server: "https://example.com", identifier: "abc"))
        XCTAssertGreaterThanOrEqual(id, 1_000_000_000_000_000)
        XCTAssertNotEqual(
            id, CWAConfiguration.bookID(server: "https://other.com", identifier: "abc"))
    }

    func testMergePreservesHardcoverDesignIDAndAddsOwnership() throws {
        let hardcover = Book(
            id: 4, title: "A Book", author: "An Author", finished: "2026-09-01", rating: 4.5)
        let cwa = Book(
            id: 1_000_000_000_000_001, title: "a book", author: "An Author", sources: [.cwa],
            isOwned: true, publicationYear: 2020)
        let sources = [
            SourceSnapshot(source: .cwa, accountID: "cwa", books: [cwa], syncedAt: Date()),
            SourceSnapshot(
                source: .hardcover, accountID: "hc", books: [hardcover], syncedAt: Date()),
        ]
        let merged = LibraryMerge.books(from: sources)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, 4)
        XCTAssertEqual(merged.first?.isOwned, true)
        XCTAssertEqual(merged.first?.rating, 4.5)
        XCTAssertEqual(merged.first?.publicationYear, 2020)
        XCTAssertEqual(Set(merged.first?.sources ?? []), Set([.hardcover, .cwa]))
    }

    func testShelfFiltersSortsAndKeepsMissingValuesLast() {
        let books = [
            Book(id: 1, title: "Z", author: "Author", finished: "2026-01-01", rating: 3),
            Book(id: 2, title: "A", author: "Author", rating: 5, isOwned: true),
            Book(id: 3, title: "B", author: "Author", isOwned: true),
        ]
        XCTAssertEqual(ShelfPreferences().select(books, limit: 20).map(\.id), [1])
        var prefs = ShelfPreferences(collection: .owned, sort: .rating)
        XCTAssertEqual(prefs.select(books, limit: 20).map(\.id), [2, 3])
        prefs.reversed = true
        XCTAssertEqual(prefs.select(books, limit: 20).map(\.id), [2, 3])
        prefs.collection = .all
        XCTAssertEqual(prefs.select(books, limit: 20).map(\.id), [1, 2, 3])
        prefs.sort = .title
        prefs.reversed = false
        XCTAssertEqual(prefs.select(books, limit: 2).map(\.id), [2, 3])
    }

    func testEveryShelfSortSupportsReverseAndDeterministicTies() {
        let first = Book(
            id: 1, title: "Alpha", author: "Alpha", pages: 100,
            finished: "2026-01-01", rating: 2, isOwned: true, publicationYear: 2000)
        let second = Book(
            id: 2, title: "Zulu", author: "Zulu", pages: 500,
            finished: "2026-02-01", rating: 5, isOwned: true, publicationYear: 2020)
        for sort in ShelfSort.allCases {
            let expected = [.dateRead, .rating, .year].contains(sort) ? [2, 1] : [1, 2]
            let forward = ShelfPreferences(collection: .all, sort: sort)
            let reverse = ShelfPreferences(collection: .all, sort: sort, reversed: true)
            XCTAssertEqual(forward.select([second, first], limit: 100).map(\.id), expected)
            XCTAssertEqual(
                reverse.select([first, second], limit: 100).map(\.id),
                expected.reversed().map { $0 })
        }
        XCTAssertEqual(
            ShelfPreferences(collection: .all).select([first, second], limit: 0).count, 1)
    }

    @MainActor
    func testFailedSourceStatusSurvivesModelRecreation() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "sourceErrors")
        defer { defaults.set(previous, forKey: "sourceErrors") }
        defaults.set(
            ["hardcover": "Hardcover denied access to this request."], forKey: "sourceErrors")
        XCTAssertTrue(LibraryModel().sourceStatus(.hardcover).contains("denied access"))
    }

    @MainActor
    func testDailyBudgetPersistsAcrossInstancesAndIsIndependentPerSource() throws {
        let name = "SourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        try SourceSyncSchedule(defaults: defaults).begin(.hardcover, now: now)
        SourceSyncSchedule(defaults: defaults).seed(.hardcover, date: now)
        let reloaded = SourceSyncSchedule(defaults: defaults)
        XCTAssertFalse(reloaded.isDue(.hardcover, now: now.addingTimeInterval(86399)))
        XCTAssertTrue(reloaded.isDue(.hardcover, now: now.addingTimeInterval(86400)))
        XCTAssertTrue(reloaded.isDue(.cwa, now: now))
        XCTAssertThrowsError(try reloaded.begin(.hardcover, now: now.addingTimeInterval(-1)))
    }

    func testCloudMergeKeepsNewestSourceAndOtherAccounts() {
        let now = Date()
        let old = SourceSnapshot(source: .hardcover, accountID: "one", books: [], syncedAt: now)
        let latest = SourceSnapshot(
            source: .hardcover, accountID: "one", books: SampleLibrary.books,
            syncedAt: now.addingTimeInterval(1))
        let other = SourceSnapshot(source: .cwa, accountID: "two", books: [], syncedAt: now)
        let merged = CloudLibraryArchive(sources: [latest])
            .merging(CloudLibraryArchive(sources: [old, other]))
        XCTAssertEqual(merged.sources.count, 2)
        XCTAssertEqual(
            merged.sources.first(where: { $0.source == .hardcover })?.books.count,
            SampleLibrary.books.count)
    }
}
