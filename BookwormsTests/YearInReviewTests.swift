import XCTest

@testable import Bookworms

final class YearInReviewTests: XCTestCase {
    private func book(
        _ id: Int, finished: String?, rating: Double? = nil, pages: Int? = nil,
        format: String? = nil, author: String = "Author", genres: [String]? = nil
    ) -> Book {
        Book(
            id: id, title: "Book \(id)", author: author, pages: pages, finished: finished,
            rating: rating, format: format, genres: genres)
    }

    func testYearsGroupFinishedBooksMostRecentFirst() {
        let years = YearInReview.all(from: [
            book(1, finished: "2025-03-02"),
            book(2, finished: "2026-01-15"),
            book(3, finished: nil),
            book(4, finished: "2025-13-01"),
            book(5, finished: "not a date"),
            book(6, finished: "2025-01-20T10:00:00Z"),
        ])
        XCTAssertEqual(years.map(\.year), [2026, 2025])
        XCTAssertEqual(years[1].books.map(\.id), [6, 1], "Books run earliest first")
        XCTAssertEqual(years[1].monthlyCounts, [1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(years[1].busiestMonth, 1, "The earliest month wins a tie")
        XCTAssertTrue(YearInReview.all(from: [book(1, finished: nil)]).isEmpty)
    }

    func testTotalsIgnoreMissingValues() throws {
        let review = try XCTUnwrap(
            YearInReview.all(from: [
                book(1, finished: "2025-05-01", rating: 5, pages: 300, format: "Listened"),
                book(2, finished: "2025-05-02", rating: 4, pages: 200, format: "Ebook"),
                book(3, finished: "2025-06-01", pages: 0, format: "Listened"),
                book(4, finished: "2025-07-01", rating: 7),
            ]).first)
        XCTAssertEqual(review.pages, 500)
        XCTAssertEqual(review.booksWithPages, 2)
        XCTAssertEqual(review.ratedBooks, 2, "Out-of-range ratings are ignored")
        XCTAssertEqual(try XCTUnwrap(review.averageRating), 4.5, accuracy: 0.001)
        XCTAssertEqual(review.busiestMonth, 5)
        XCTAssertEqual(
            review.formats,
            [.init(name: "Audiobook", count: 2), .init(name: "Ebook", count: 1)])
        XCTAssertEqual(review.topAuthor, .init(name: "Author", count: 4))
    }

    func testGenresAndAuthorsRankByCountThenName() throws {
        let review = try XCTUnwrap(
            YearInReview.all(from: [
                book(
                    1, finished: "2025-01-01", author: "Rowan",
                    genres: ["Fantasy", "Mystery", "Horror", "Ignored"]),
                book(2, finished: "2025-02-01", author: "Rowan", genres: ["Mystery", "Fantasy"]),
                book(3, finished: "2025-03-01", author: "Vale", genres: ["Poetry"]),
            ]).first)
        XCTAssertEqual(
            review.genres.map(\.name), ["Fantasy", "Mystery", "Horror", "Poetry"],
            "Only each book's first \(YearInReview.genresPerBook) genres count")
        XCTAssertEqual(review.topAuthor, .init(name: "Rowan", count: 2))
    }

    func testLargeYearsShelveTheHighestRatedBooksInReadingOrder() throws {
        let count = BookLimit.maximum + 5
        let books = (1...count).map { id in
            book(
                id, finished: String(format: "2025-%02d-%02d", id % 12 + 1, id % 28 + 1),
                rating: id <= 5 ? nil : Double(id % 5 + 1))
        }
        let review = try XCTUnwrap(YearInReview.all(from: books).first)
        XCTAssertEqual(review.books.count, count, "Statistics keep every book")
        XCTAssertEqual(review.shelf.count, BookLimit.maximum)
        XCTAssertTrue(
            review.shelf.allSatisfy { $0.rating != nil }, "Unrated books are dropped first")
        XCTAssertEqual(
            review.shelf.map(\.id), review.books.filter { review.shelf.contains($0) }.map(\.id),
            "The shelf keeps reading order")
    }

    func testPreferencesSavedBeforeYearInReviewAddItOnce() throws {
        let old = Data(
            #"{"enabled":["My Shelf","Following"],"comparisonOrder":"Top rated · All time","sharedReadsSort":"Rating agreement","comparisonCount":20,"ambientMinutes":10,"sessionMinutes":0}"#
                .utf8)
        var saved = try JSONDecoder().decode(ViewPreferences.self, from: old)
        XCTAssertNil(saved.offeredViews)
        saved.validate()
        XCTAssertEqual(saved.orderedViews, [.shelf, .yearInReview, .following])
        // Turning it off afterward persists.
        saved.enabled.removeAll { $0 == .yearInReview }
        var reloaded = try JSONDecoder().decode(
            ViewPreferences.self, from: JSONEncoder().encode(saved))
        reloaded.validate()
        XCTAssertEqual(reloaded.orderedViews, [.shelf, .following])
        XCTAssertFalse(reloaded.ambientOrderedViews.contains(.yearInReview))
    }
}
