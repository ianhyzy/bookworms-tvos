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
        XCTAssertEqual(ShelfPreferences().collection, .all, "My Shelf shows All Books by default")
        XCTAssertEqual(
            ShelfPreferences(collection: .standard).select(books, limit: 20).map(\.id), [1])
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

    func testDefaultAndAllBooksLeadWithThreeMostRecentlyStartedCurrentReads() throws {
        let reading = (1...4)
            .map {
                Book(
                    id: $0, title: "Reading \($0)", author: "Author", finished: "2025-01-01",
                    isRead: true, isReading: true, started: "2026-09-0\($0)")
            }
        let read = [
            Book(id: 10, title: "Older", author: "Author", finished: "2026-01-01"),
            Book(id: 11, title: "Newer", author: "Author", finished: "2026-08-01"),
            Book(id: 12, title: "Unread", author: "Author", isOwned: true),
        ]
        let prefs = ShelfPreferences(collection: .standard, sort: .title)
        XCTAssertEqual(prefs.select(read + reading, limit: 40).map(\.id), [4, 3, 2, 11, 10])
        XCTAssertEqual(prefs.select(read + reading, limit: 2).map(\.id), [4, 3])
        let all = ShelfPreferences(collection: .all, sort: .title)
        XCTAssertEqual(
            all.select(read + reading, limit: 40).map(\.id), [4, 3, 2, 11, 10, 1, 12],
            "All Books pins current reads once, then sorts the rest, including other current reads")
        XCTAssertEqual(all.select(reading, limit: 40).count, 4)
        var owned = reading[0]
        owned.isOwned = true
        XCTAssertEqual(
            ShelfPreferences(collection: .owned, sort: .title).select([owned] + read, limit: 40)
                .map(\.id), [1, 12], "Owned Books doesn't pin current reads")
        let legacy = try JSONDecoder()
            .decode(
                ShelfPreferences.self,
                from: Data(#"{"collection":"Read Books","sort":"Title","reversed":false}"#.utf8))
        XCTAssertEqual(legacy.collection, .standard)
        XCTAssertEqual(legacy.progressStyle, .vertical, "Older choices gain the vertical sweep")
        let unknown = try JSONDecoder()
            .decode(ShelfPreferences.self, from: Data(#"{"progressStyle":"Diagonal"}"#.utf8))
        XCTAssertEqual(unknown, ShelfPreferences())
        var hidden = ShelfPreferences()
        hidden.progressStyle = .hidden
        XCTAssertEqual(
            try JSONDecoder().decode(ShelfPreferences.self, from: JSONEncoder().encode(hidden)),
            hidden)
    }

    @MainActor func testShelfFilterLimitsTheShelfUntilCleared() {
        let library = LibraryModel()
        library.showSample()
        library.shelfFilter = .author("Alex Rowan")
        XCTAssertEqual(library.books.map(\.id), [1, 8])
        library.shelfFilter = .genre("Fantasy")
        XCTAssertEqual(library.books.map(\.id), [1])
        library.shelfFilter = nil
        XCTAssertEqual(library.books.count, SampleLibrary.books.count)
        XCTAssertTrue(
            ShelfFilter.genre("Litrpg")
                .matches(Book(id: 9, title: "", author: "", genres: ["litrpg"])))
    }

    func testSeriesKeepsOneMainBookPerPositionInOrder() throws {
        let json = #"""
            {"series": [{"id": 7, "name": "Ana and Din Mysteries", "book_series": [
              {"position": 1, "book": {"id": 11, "title": "The Tainted Cup", "release_year": 2024,
                "image": {"url": "https://assets.example/1.jpg"}}},
              {"position": 1, "book": {"id": 99, "title": "The Tainted Cup (Large Print)"}},
              {"position": 1.5, "book": {"id": 15, "title": "A Novella"}},
              {"position": 2, "book": {"id": 12, "title": "A Drop of Corruption",
                "image": {"url": "http://insecure.example/2.jpg"}}},
              {"position": 3, "book": null}
            ]}]}
            """#
        let response = try JSONDecoder().decode(SeriesResponse.self, from: Data(json.utf8))
        let series = HardcoverClient.normalize(try XCTUnwrap(response.series.first))
        XCTAssertEqual(series.name, "Ana and Din Mysteries")
        XCTAssertEqual(
            series.books.map(\.id), [11, 12],
            "The most-read book wins each position; companions and empty rows are left out")
        XCTAssertEqual(series.books[0].releaseYear, 2024)
        XCTAssertNotNil(series.books[0].coverURL)
        XCTAssertNil(series.books[1].coverURL, "Only HTTPS covers are kept")
        XCTAssertEqual(SeriesInfo.positionLabel(3), "#3")
        XCTAssertEqual(SeriesInfo.positionLabel(2.5), "#2.5")
    }

    func testLibraryRowsCarrySeriesNamesIntoTheCloudArchive() throws {
        let json = #"""
            [{"id": 100, "status_id": 3, "last_read_date": "2026-03-01",
              "book": {"id": 11, "title": "The Tainted Cup",
                "cached_contributors": [{"author": {"name": "Robert Jackson Bennett"}}],
                "book_series": [
                  {"featured": false, "position": 9, "series": {"id": 8, "name": "Omnibus"}},
                  {"featured": true, "position": 1,
                    "series": {"id": 7, "name": "Ana and Din Mysteries"}}]}}]
            """#
        let rows = try JSONDecoder().decode([UserBook].self, from: Data(json.utf8))
        let book = try XCTUnwrap(HardcoverClient.normalize(rows).first)
        XCTAssertEqual(book.seriesID, 7, "The featured series wins")
        XCTAssertEqual(book.seriesName, "Ana and Din Mysteries")
        XCTAssertEqual(book.seriesPosition, 1)

        // The iPhone decodes the archive's books with this key (`CloudBook.seriesName`).
        let archive = CloudLibraryArchive(sources: [
            SourceSnapshot(
                source: .hardcover, accountID: "1", books: [book], syncedAt: .distantPast)
        ])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive))
        let sources = try XCTUnwrap((encoded as? [String: Any])?["sources"] as? [[String: Any]])
        let books = try XCTUnwrap(sources.first?["books"] as? [[String: Any]])
        XCTAssertEqual(books.first?["seriesName"] as? String, "Ana and Din Mysteries")

        let older = try JSONDecoder()
            .decode(Book.self, from: Data(#"{"id": 1, "title": "T", "author": "A"}"#.utf8))
        XCTAssertNil(older.seriesName, "Books saved before series names decode without one")
    }

    func testReaderReviewIsPlainTextAndSurvivesTheCloudArchive() throws {
        let json = #"""
            [{"id": 100, "status_id": 3, "review": "<p>A <em>quiet</em> triumph.</p><p>Again.</p>",
              "book": {"id": 11, "title": "The Tainted Cup"}}]
            """#
        let rows = try JSONDecoder().decode([UserBook].self, from: Data(json.utf8))
        let book = try XCTUnwrap(HardcoverClient.normalize(rows).first)
        XCTAssertEqual(book.review, "A quiet triumph.\n\nAgain.")

        // The iPhone decodes the archive's books with this key (`CloudBook.review`).
        let archive = CloudLibraryArchive(sources: [
            SourceSnapshot(
                source: .hardcover, accountID: "1", books: [book], syncedAt: .distantPast)
        ])
        let decoded = try JSONDecoder()
            .decode(CloudLibraryArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(decoded.sources.first?.books.first?.review, "A quiet triumph.\n\nAgain.")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive))
        let sources = try XCTUnwrap((encoded as? [String: Any])?["sources"] as? [[String: Any]])
        let books = try XCTUnwrap(sources.first?["books"] as? [[String: Any]])
        XCTAssertEqual(books.first?["review"] as? String, "A quiet triumph.\n\nAgain.")
    }

    /// The iPhone app's cases for `plainText(from:)`, so both apps store the same review text.
    func testReviewTextBecomesPlainTextAsOnTheIPhone() {
        let plain = HardcoverClient.plainText(from:)
        XCTAssertNil(plain(nil))
        XCTAssertNil(plain(" \n<p></p> "))
        XCTAssertEqual(
            plain("<p>A <em>quiet</em> triumph &amp; a joy.</p><p>Would reread.</p>"),
            "A quiet triumph & a joy.\n\nWould reread.")
        XCTAssertEqual(
            plain("Line one<br/>Line two<BR>Line three"), "Line one\nLine two\nLine three")
        XCTAssertEqual(
            plain(
                "# Verdict\n\n**Loved it.** Read [the sequel](https://example.com) next.\n> Five stars, _easily_."
            ),
            "Verdict\n\nLoved it. Read the sequel next.\nFive stars, easily.")
        XCTAssertEqual(
            plain("Tea &amp; toast &#8212; I <3 it, 5 * 3 > 2 and snake_case stays. #bookclub"),
            "Tea & toast — I <3 it, 5 * 3 > 2 and snake_case stays. #bookclub")
        XCTAssertEqual(plain("First.\n \n\n\nSecond."), "First.\n\nSecond.")
    }

    func testLibraryRowsKeepEveryNamedSeriesMembership() throws {
        let json = #"""
            [{"id": 100, "status_id": 3,
              "book": {"id": 11, "title": "Guards! Guards!",
                "book_series": [
                  {"featured": true, "position": 8, "compilation": false,
                    "series": {"id": 1018, "name": " Discworld\n", "books_count": 60,
                      "primary_books_count": 41}},
                  {"featured": false, "position": 1, "compilation": true,
                    "series": {"id": 2001, "name": "City Watch", "books_count": 8}},
                  {"featured": false, "position": 2, "series": null},
                  {"position": 3, "series": {"id": 3000, "name": "  "}},
                  {"position": null, "series": {"id": 4000, "name": "Unsized"}}]}}]
            """#
        let rows = try JSONDecoder().decode([UserBook].self, from: Data(json.utf8))
        let book = try XCTUnwrap(HardcoverClient.normalize(rows).first)
        XCTAssertEqual(
            book.seriesMemberships,
            [
                SeriesMembership(
                    seriesID: 1018, name: "Discworld", position: 8, featured: true, size: 41),
                SeriesMembership(
                    seriesID: 2001, name: "City Watch", position: 1, compilation: true, size: 8),
                SeriesMembership(seriesID: 4000, name: "Unsized"),
            ], "Rows without a series or a series name are left out")
        XCTAssertEqual(book.seriesID, 1018, "The featured series still names the book's series")

        // The iPhone companion decodes the same keys from the iCloud archive.
        let shared = #"""
            {"seriesID": 1018, "name": "Discworld", "position": 8, "featured": true,
             "compilation": false, "size": 41}
            """#
        XCTAssertEqual(
            try JSONDecoder().decode(SeriesMembership.self, from: Data(shared.utf8)),
            book.seriesMemberships?.first)
        let older = try JSONDecoder()
            .decode(Book.self, from: Data(#"{"id": 1, "title": "T", "author": "A"}"#.utf8))
        XCTAssertNil(older.seriesMemberships)
    }

    func testHotTakesSortByGapFromCommunityRating() {
        let books = [
            Book(id: 1, title: "Agree", author: "A", rating: 4, communityRating: 4.1),
            Book(id: 2, title: "Loved", author: "A", rating: 5, communityRating: 2.9),
            Book(id: 3, title: "Unrated", author: "A", communityRating: 3),
            Book(id: 4, title: "Panned", author: "A", rating: 1, communityRating: 4.2),
        ]
        let prefs = ShelfPreferences(collection: .all, sort: .hotTakes)
        XCTAssertEqual(prefs.select(books, limit: 40).map(\.id), [4, 2, 1, 3])
    }

    func testCurrentReadProgressPrefersPercentThenPagesThenSecondsAndClamps() throws {
        func read(_ pages: Int?, edition: Int? = nil) -> CurrentRead {
            CurrentRead(
                startedAt: nil, progressPages: pages, edition: CurrentRead.Length(pages: edition))
        }
        func progress(_ read: CurrentRead, pages: Int? = 100, audio: Int? = nil) -> Double? {
            HardcoverClient.progress(of: read, pages: pages, audioSeconds: audio)
        }
        XCTAssertEqual(progress(read(50, edition: 200)), 0.25)
        XCTAssertEqual(progress(read(50)), 0.5)
        XCTAssertEqual(progress(read(500)), 1)
        XCTAssertNil(progress(read(nil)))
        XCTAssertNil(progress(read(10), pages: nil))
        XCTAssertNil(HardcoverClient.progress(of: nil, pages: 100, audioSeconds: 100))

        let percent = CurrentRead(startedAt: nil, progress: 84.5, progressPages: 10)
        XCTAssertEqual(
            progress(percent)!, 0.845, accuracy: 0.0001,
            "Hardcover's percentage wins, as for an audiobook tracked by percent")
        let listened = CurrentRead(
            startedAt: nil, progressSeconds: 1800, edition: CurrentRead.Length(audioSeconds: 3600))
        XCTAssertEqual(progress(listened, pages: nil), 0.5)
        XCTAssertEqual(
            progress(CurrentRead(startedAt: nil, progressSeconds: 900), pages: nil, audio: 3600),
            0.25, "Listening time falls back to the library edition's length")
        XCTAssertEqual(progress(CurrentRead(startedAt: nil, progress: 120)), 1)
        XCTAssertNil(progress(CurrentRead(startedAt: nil, progress: .nan)))

        let decoded = try JSONDecoder()
            .decode(
                CurrentRead.self,
                from: Data(
                    #"{"started_at":"2026-09-22","progress":84.5,"progress_pages":null,"progress_seconds":72505,"edition":{"pages":null,"audio_seconds":85800}}"#
                        .utf8))
        XCTAssertEqual(decoded.progressSeconds, 72505)
        XCTAssertEqual(decoded.edition?.audioSeconds, 85800)
        XCTAssertEqual(progress(decoded, pages: nil)!, 0.845, accuracy: 0.0001)
    }

    func testEveryShelfSortSupportsReverseAndDeterministicTies() {
        let first = Book(
            id: 1, title: "Alpha", author: "Alpha", pages: 100,
            finished: "2026-01-01", rating: 2, communityRating: 4, isOwned: true,
            publicationYear: 2000)
        let second = Book(
            id: 2, title: "Zulu", author: "Zulu", pages: 500,
            finished: "2026-02-01", rating: 5, communityRating: 4.5, isOwned: true,
            publicationYear: 2020)
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
        XCTAssertTrue(LibraryModel().sourceStatus(.hardcover)?.contains("denied access") == true)
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
