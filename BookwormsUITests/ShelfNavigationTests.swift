import XCTest

@MainActor
final class ShelfNavigationTests: XCTestCase {
    func testSelectBookReadDetailsAndReturnToShelf() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        if !first.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(first.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail-title"].label, "The Orchard at Night")
        XCTAssertTrue(app.staticTexts["book-description"].exists)
        XCTAssertFalse(app.staticTexts["HARDCOVER"].exists)
        XCTAssertFalse(app.staticTexts["About this book"].exists)
        XCTAssertTrue(app.otherElements["rating-distribution"].exists)
        let back = app.buttons["back-to-shelf"]
        let reviews = app.buttons["community-reviews"]
        let author = app.buttons["detail-author"]
        let fantasy = app.buttons["detail-genre-Fantasy"]
        RemoteNavigation.waitForFocus(back)
        RemoteNavigation.press(.right, in: app, expecting: author)
        RemoteNavigation.press(.left, in: app, expecting: back)
        RemoteNavigation.press(.right, in: app, expecting: author)
        RemoteNavigation.press(.down, in: app, expecting: fantasy)
        RemoteNavigation.press(.right, in: app, expecting: app.buttons["detail-genre-Mystery"])
        RemoteNavigation.press(.right, in: app, expecting: reviews)
        XCUIRemote.shared.press(.select)
        let longReview = app.buttons["book-review-1"]
        XCTAssertTrue(longReview.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(longReview)
        XCUIRemote.shared.press(.select)
        // Wait for the reader to take focus, as a person would, before pressing Back.
        RemoteNavigation.waitForFocus(app.descendants(matching: .any)["review-reader"])
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(longReview)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(reviews)
        let showMore = app.buttons["show-full-description"]
        XCTAssertTrue(showMore.exists)
        RemoteNavigation.press(.down, in: app, expecting: showMore)
        RemoteNavigation.press(.up, in: app, expecting: fantasy)
        RemoteNavigation.press(.down, in: app, expecting: showMore)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-text"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(showMore.waitForExistence(timeout: 5))
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "Book details"
        detail.lifetime = .keepAlways
        add(detail)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.hasFocus)
        let shelf = XCTAttachment(screenshot: app.screenshot())
        shelf.name = "Interactive shelf"
        shelf.lifetime = .keepAlways
        add(shelf)
    }
    func testDetailAuthorAndGenresFilterTheShelf() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        XCUIRemote.shared.press(.select)
        let back = app.buttons["back-to-shelf"]
        let author = app.buttons["detail-author"]
        let fantasy = app.buttons["detail-genre-Fantasy"]
        let mystery = app.buttons["detail-genre-Mystery"]
        let reviews = app.buttons["community-reviews"]
        RemoteNavigation.waitForFocus(back)
        // Every direction out of the author and genre buttons.
        let series = app.buttons["detail-series"]
        RemoteNavigation.press(.right, in: app, expecting: author)
        RemoteNavigation.pressWithoutMoving(.up, in: app, from: author)
        RemoteNavigation.press(.right, in: app, expecting: series)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: series)
        RemoteNavigation.press(.left, in: app, expecting: author)
        // Up from the metadata row reaches the series button, which sits above the second genre
        // and the histogram.
        RemoteNavigation.press(.down, in: app, expecting: fantasy)
        RemoteNavigation.press(.right, in: app, expecting: mystery)
        RemoteNavigation.press(.up, in: app, expecting: series)
        RemoteNavigation.press(.down, in: app, expecting: fantasy)
        RemoteNavigation.press(.right, in: app, expecting: mystery)
        RemoteNavigation.press(.right, in: app, expecting: reviews)
        RemoteNavigation.press(.up, in: app, expecting: series)
        RemoteNavigation.press(.left, in: app, expecting: author)
        RemoteNavigation.press(.down, in: app, expecting: fantasy)
        RemoteNavigation.press(.down, in: app, expecting: app.buttons["show-full-description"])
        RemoteNavigation.press(.up, in: app, expecting: fantasy)
        RemoteNavigation.press(.left, in: app, expecting: back)
        RemoteNavigation.press(.right, in: app, expecting: author)
        XCUIRemote.shared.press(.select)

        // The author's books, with the opened book focused.
        let clear = app.buttons["clear-shelf-filter"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(first)
        XCTAssertTrue(app.buttons["book-8"].exists)
        XCTAssertFalse(app.buttons["book-2"].exists)
        RemoteNavigation.press(.down, in: app, expecting: clear)
        RemoteNavigation.press(.up, in: app, expecting: first)
        RemoteNavigation.press(.down, in: app, expecting: clear)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["book-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(clear.exists)

        // A genre filter from the same book.
        RemoteNavigation.waitForFocus(first)
        XCUIRemote.shared.press(.select)
        RemoteNavigation.waitForFocus(back)
        RemoteNavigation.press(.right, in: app, expecting: author)
        RemoteNavigation.press(.down, in: app, expecting: fantasy)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(first)
        XCTAssertFalse(app.buttons["book-8"].exists)

        // Back reopens the details and clears the filter; Back again returns to the whole shelf.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(back)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(first)
        XCTAssertTrue(app.buttons["book-8"].waitForExistence(timeout: 5))
        XCTAssertFalse(clear.exists)
    }

    func testSeriesPopupListsTheSeriesAndOpensLibraryBooks() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        XCUIRemote.shared.press(.select)
        RemoteNavigation.waitForFocus(app.buttons["back-to-shelf"])
        XCTAssertTrue(
            app.descendants(matching: .any)["detail-fact-Published"].label.contains("2023"),
            "Details list the publication year")
        let series = app.buttons["detail-series"]
        XCTAssertTrue(series.label.contains("The Island Cycle"))
        RemoteNavigation.press(.right, in: app, expecting: app.buttons["detail-author"])
        RemoteNavigation.press(.right, in: app, expecting: series)
        XCUIRemote.shared.press(.select)
        let current = app.buttons["series-book-1"]
        let second = app.buttons["series-book-8"]
        let unowned = app.buttons["series-book-9"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(current)
        RemoteNavigation.press(.right, in: app, expecting: second)
        RemoteNavigation.press(.right, in: app, expecting: unowned)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: unowned)
        let popup = XCTAttachment(screenshot: app.screenshot())
        popup.name = "Series pop-up"
        popup.lifetime = .keepAlways
        add(popup)
        // A book outside the library stays put; one in it opens its details.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(RemoteNavigation.isFocused(unowned))
        RemoteNavigation.press(.left, in: app, expecting: second)
        XCUIRemote.shared.press(.select)
        let title = app.staticTexts["detail-title"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 5)
                && NSPredicate(format: "label == %@", "Winter in the Orchard").evaluate(with: title)
        )
    }

    func testShelfPagesMoveWithOneFocusUpdate() {
        let app = RemoteNavigation.launch(arguments: ["--sample-pages"])
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(app.buttons["book-1"])
        let visible = RemoteNavigation.visibleButtons(app, prefix: "book-")
        guard let last = visible.last, visible.count > 1,
            let lastID = Int(last.identifier.dropFirst("book-".count))
        else {
            return XCTFail("Expected several books on the first page")
        }
        for book in visible.dropFirst() {
            RemoteNavigation.press(.right, in: app, expecting: book)
        }
        let next = app.buttons["book-\(lastID + 1)"]
        for _ in 0..<2 {
            // The next page's first book is already mounted, so the focus engine reaches it natively.
            RemoteNavigation.press(.right, in: app, expecting: next)
            XCTAssertLessThanOrEqual(next.frame.maxX, app.frame.maxX, "The row must page forward")
            XCTAssertLessThan(last.frame.maxX, app.frame.midX, "The previous page must scroll away")
            RemoteNavigation.press(.left, in: app, expecting: last)
            XCTAssertGreaterThanOrEqual(last.frame.minX, app.frame.minX, "The row must page back")
        }
    }

    func testLeftFromFirstBookReachesSidebarAndRightRestoresBook() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        let second = app.buttons["book-2"]
        RemoteNavigation.press(.right, in: app, expecting: second)
        RemoteNavigation.press(.left, in: app, expecting: first)
        XCUIRemote.shared.press(.left)
        let leftContent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == false"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [leftContent], timeout: 3), .completed)
        XCTAssertNil(RemoteNavigation.focused(app, prefix: "book-"))
        RemoteNavigation.press(.right, in: app, expecting: first)
    }

    func testDownBelowShelfDoesNotMoveFocus() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: first)
        XCTAssertFalse(app.staticTexts["The bookshelf"].exists)
        XCTAssertFalse(app.staticTexts["Recently read"].exists)
    }

    func testUnselectedCoversRestOnShelf() {
        let app = RemoteNavigation.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(app.buttons["book-1"])
        RemoteNavigation.press(.right, in: app, expecting: app.buttons["book-2"])
        let resting = RemoteNavigation.visibleButtons(app, prefix: "book-")
            .filter { !$0.hasFocus }
        XCTAssertFalse(resting.isEmpty)
        let bottom = resting[0].frame.maxY
        for book in resting {
            XCTAssertEqual(
                book.frame.maxY, bottom, accuracy: 2, "\(book.identifier) must sit on the shelf")
        }
    }

    /// The sample library finishes every dated book in 2026; its shelf runs earliest first.
    func testYearInReviewCoversHeaderAndDetailsMoveDirectly() {
        continueAfterFailure = false
        let app = RemoteNavigation.open("Year in Review")
        let first = app.buttons["year-book-8"]
        let second = app.buttons["year-book-7"]
        let year = app.buttons["review-year-options"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertEqual(year.value as? String, "2026")
        XCTAssertFalse(app.buttons["year-book-4"].exists, "Books without a finish date are omitted")
        RemoteNavigation.waitForFocus(first)
        RemoteNavigation.press(.right, in: app, expecting: second)
        XCTAssertEqual(first.frame.maxY, second.frame.maxY, accuracy: 10)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: second)
        RemoteNavigation.press(.up, in: app, expecting: year)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: year)
        RemoteNavigation.press(.down, in: app, expecting: second)
        RemoteNavigation.press(.left, in: app, expecting: first)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(first)
        XCUIRemote.shared.press(.left)
        let leftContent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == false"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [leftContent], timeout: 3), .completed)
        XCTAssertNil(RemoteNavigation.focused(app, prefix: "year-book-"))
        // The header sits level with the sidebar, so Right from the sidebar reaches the year menu.
        RemoteNavigation.press(.right, in: app, expecting: year)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Year in Review"
        capture.lifetime = .keepAlways
        add(capture)
    }

}
