import XCTest

@MainActor
final class ShelfNavigationTests: XCTestCase {
    /// The app opens on My Shelf with the first book focused and the sidebar closed, without a
    /// press, and focus stays there. A page can't hold focus while the sidebar is open, so focus
    /// on the book also shows that the sidebar is closed.
    func testLaunchFocusesTheFirstBookWithTheSidebarClosed() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        RemoteNavigation.assertSettled(
            app, after: RemoteNavigation.transitions(app), expectedUpdates: 0,
            file: #filePath, line: #line)
        XCTAssertTrue(first.hasFocus)
    }

    /// An app left with Back from the open sidebar returns on its page, with the sidebar closed
    /// and focus on the book it left.
    func testReturningAfterLeavingThroughTheSidebarShowsTheShelf() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        let second = app.buttons["book-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        RemoteNavigation.press(.right, in: app, expecting: second)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForSidebarFocus("My Shelf", in: app)
        XCUIRemote.shared.press(.menu)
        let left = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed)
        app.activate()
        RemoteNavigation.waitForFocus(second)
    }

    func testSelectBookReadDetailsAndReturnToShelf() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail-title"].label, "The Orchard at Night")
        XCTAssertTrue(app.staticTexts["book-description"].exists)
        XCTAssertTrue(app.otherElements["rating-distribution"].exists)
        // The sample book was finished twice, and the sample reader has it. Neither the read
        // count nor the readers row takes focus; the presses below cross the row.
        XCTAssertEqual(
            app.descendants(matching: .any)["detail-read-count"].label, "Read 2 times")
        XCTAssertTrue(app.descendants(matching: .any)["detail-friend-reads"].exists)
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
        // Launch and the first presentation wait as long as launch may take on a busy machine.
        RemoteNavigation.waitForFocus(first, timeout: 15)
        XCUIRemote.shared.press(.select)
        let back = app.buttons["back-to-shelf"]
        let author = app.buttons["detail-author"]
        let fantasy = app.buttons["detail-genre-Fantasy"]
        let mystery = app.buttons["detail-genre-Mystery"]
        let reviews = app.buttons["community-reviews"]
        RemoteNavigation.waitForFocus(back, timeout: 15)
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

        // Back reveals the details beneath the filtered shelf, already present, with focus back
        // on the genre; Back again returns to the whole shelf.
        let title = app.staticTexts["detail-title"]
        XCTAssertFalse(title.exists && title.isHittable, "The shelf didn't cover the details")
        let before = RemoteNavigation.transitions(app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(title.exists, "Details weren't there at once")
        RemoteNavigation.waitForFocus(fantasy)
        _ = XCTWaiter.wait(
            for: [XCTestExpectation(description: "Details settle")],
            timeout: RemoteNavigation.settleWindow)
        XCTAssertTrue(RemoteNavigation.isFocused(fantasy))
        // Two updates: the leaving shelf clears focus, and the details restore it to the genre.
        XCTAssertEqual(RemoteNavigation.transitions(app), before.map { $0 + 2 })
        XCTAssertFalse(clear.exists)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(first)
        XCTAssertTrue(app.buttons["book-8"].waitForExistence(timeout: 5))
        XCTAssertFalse(clear.exists)
    }

    /// A book chosen on a filtered shelf filters it again from its own details; Back twice
    /// returns to the details that applied the first filter, then to the book that opened them.
    func testFilterFromFilteredShelfReturnsToFirstBook() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first, timeout: 15)
        XCUIRemote.shared.press(.select)
        let back = app.buttons["back-to-shelf"]
        let author = app.buttons["detail-author"]
        let title = app.staticTexts["detail-title"]
        RemoteNavigation.waitForFocus(back, timeout: 15)
        RemoteNavigation.press(.right, in: app, expecting: author)
        XCUIRemote.shared.press(.select)

        // Sample books 1 and 8 share an author. Book 8's author filter enters on book 8.
        let clear = app.buttons["clear-shelf-filter"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(first)
        let second = app.buttons["book-8"]
        RemoteNavigation.press(.right, in: app, expecting: second)
        XCUIRemote.shared.press(.select)
        // Book 8's details open above book 1's, which stay in the tree, so match the focused copy.
        func focused(_ identifier: String) -> XCUIElement {
            app.buttons
                .matching(
                    NSPredicate(format: "identifier == %@ AND hasFocus == true", identifier)
                )
                .firstMatch
        }
        RemoteNavigation.waitForFocus(focused("back-to-shelf"))
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "detail-title")
                .matching(NSPredicate(format: "label == %@", "Winter in the Orchard")).firstMatch
                .exists)
        RemoteNavigation.press(.right, in: app, expecting: focused("detail-author"))
        XCUIRemote.shared.press(.select)
        RemoteNavigation.waitForFocus(second)
        XCTAssertEqual(app.staticTexts.matching(identifier: "detail-title").count, 1)

        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(author)
        XCTAssertEqual(title.label, "The Orchard at Night")
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(first)
        XCTAssertTrue(app.buttons["book-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(clear.exists)
    }

    /// Details opened on a filtered shelf keep the shelf on their book's page, and Back returns
    /// focus to that book, not to the book whose details applied the filter.
    func testBackFromFilteredShelfDetailsReturnsToTheirBook() throws {
        let app = RemoteNavigation.launch(arguments: ["--sample-pages"])
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first, timeout: 15)
        XCUIRemote.shared.press(.select)
        RemoteNavigation.waitForFocus(app.buttons["back-to-shelf"], timeout: 15)
        RemoteNavigation.press(.right, in: app, expecting: app.buttons["detail-author"])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["clear-shelf-filter"].waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(first)
        // With 24 sample books, Alex Rowan's shelf pages after book 16, so book 17 sits on the
        // page after book 1's.
        for id in [8, 9, 16, 17] {
            RemoteNavigation.press(.right, in: app, expecting: app.buttons["book-\(id)"])
        }
        let other = app.buttons["book-17"]
        XCUIRemote.shared.press(.select)
        // Book 17's details open above book 1's, which stay in the tree, so match the focused
        // copy. My Shelf beneath book 1's details shows book 17 off screen.
        RemoteNavigation.waitForFocus(
            app.buttons
                .matching(
                    NSPredicate(format: "identifier == %@ AND hasFocus == true", "back-to-shelf")
                )
                .firstMatch)
        XCTAssertFalse(
            RemoteNavigation.visibleButtons(app, prefix: "book-17").isEmpty,
            "The shelf beneath the details paged away from their book")

        let before = try XCTUnwrap(RemoteNavigation.transitions(app))
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(other)
        _ = XCTWaiter.wait(
            for: [XCTestExpectation(description: "Shelf settles")],
            timeout: RemoteNavigation.settleWindow)
        XCTAssertTrue(RemoteNavigation.isFocused(other))
        // Two updates: the leaving details clear focus, and the shelf restores it to book 17.
        XCTAssertEqual(RemoteNavigation.transitions(app), before + 2)
        XCTAssertFalse(RemoteNavigation.visibleButtons(app, prefix: "book-17").isEmpty)
        XCTAssertTrue(app.buttons["clear-shelf-filter"].exists)
    }

    /// Opens sample book 1's details and focuses its series label, which names The Island Cycle,
    /// the shorter of its two series.
    private func openSeriesLabel(file: StaticString = #filePath, line: UInt = #line)
        -> (XCUIApplication, XCUIElement)
    {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), file: file, line: line)
        // Launch and the first presentation wait as long as launch may take on a busy machine.
        RemoteNavigation.waitForFocus(first, timeout: 15, file: file, line: line)
        XCUIRemote.shared.press(.select)
        RemoteNavigation.waitForFocus(
            app.buttons["back-to-shelf"], timeout: 15, file: file, line: line)
        let series = app.buttons["detail-series"]
        XCTAssertTrue(
            series.label.contains("The Island Cycle 1 of 3"), series.label, file: file, line: line)
        RemoteNavigation.press(
            .right, in: app, expecting: app.buttons["detail-author"], file: file, line: line)
        RemoteNavigation.press(.right, in: app, expecting: series, file: file, line: line)
        return (app, series)
    }

    func testSeriesPopupListsTheSeriesAndOpensLibraryBooks() {
        let (app, series) = openSeriesLabel()
        XCTAssertTrue(
            app.descendants(matching: .any)["detail-fact-Published"].label.contains("2023"),
            "Details list the publication year")
        // The list of the book's series opens on the series the label names.
        let island = app.buttons["series-row-1"]
        RemoteNavigation.press(.select, in: app, expecting: island)
        XCTAssertTrue(series.exists)
        // The series' books replace the list, with one focus update to this book.
        let current = app.buttons["series-book-1"]
        let second = app.buttons["series-book-8"]
        let unowned = app.buttons["series-book-9"]
        RemoteNavigation.press(.select, in: app, expecting: current)
        RemoteNavigation.press(.right, in: app, expecting: second)
        RemoteNavigation.press(.right, in: app, expecting: unowned)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: unowned)
        let popup = XCTAttachment(screenshot: app.screenshot())
        popup.name = "Series pop-up"
        popup.lifetime = .keepAlways
        add(popup)
        // A book outside the library stays put; one in it opens its details.
        RemoteNavigation.pressWithoutMoving(.select, in: app, from: unowned)
        // Back returns to the list, on the series that was open. Focus passes through no item
        // while the books leave, as when a pop-up closes, so this waits instead of counting.
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(island)
        RemoteNavigation.press(.select, in: app, expecting: current)
        RemoteNavigation.press(.right, in: app, expecting: second)
        XCUIRemote.shared.press(.select)
        let title = app.staticTexts["detail-title"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 5)
                && NSPredicate(format: "label == %@", "Winter in the Orchard").evaluate(with: title)
        )
    }

    /// Sample book 1's series list: The Island Cycle, the series its label names, then Tales of the
    /// Night Orchard, each row followed by its check button.
    func testSeriesListMovesFocusOnceAndPicksTheNamedSeries() {
        let (app, series) = openSeriesLabel()
        let island = app.buttons["series-row-1"]
        let tales = app.buttons["series-row-2"]
        let islandCheck = app.buttons["series-pick-1"]
        let talesCheck = app.buttons["series-pick-2"]
        RemoteNavigation.press(.select, in: app, expecting: island)
        XCTAssertTrue(islandCheck.isSelected)
        XCTAssertFalse(talesCheck.isSelected)

        // Every direction out of each row and check.
        RemoteNavigation.pressWithoutMoving(.up, in: app, from: island)
        RemoteNavigation.pressWithoutMoving(.left, in: app, from: island)
        RemoteNavigation.press(.down, in: app, expecting: tales)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: tales)
        RemoteNavigation.pressWithoutMoving(.left, in: app, from: tales)
        RemoteNavigation.press(.right, in: app, expecting: talesCheck)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: talesCheck)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: talesCheck)
        RemoteNavigation.press(.up, in: app, expecting: islandCheck)
        RemoteNavigation.pressWithoutMoving(.up, in: app, from: islandCheck)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: islandCheck)
        RemoteNavigation.press(.left, in: app, expecting: island)
        RemoteNavigation.press(.right, in: app, expecting: islandCheck)
        RemoteNavigation.press(.down, in: app, expecting: talesCheck)
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "Series list"
        list.lifetime = .keepAlways
        add(list)

        // A check picks its series without moving focus, and the label names it.
        RemoteNavigation.pressWithoutMoving(.select, in: app, from: talesCheck)
        XCTAssertTrue(talesCheck.isSelected)
        XCTAssertFalse(islandCheck.isSelected)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(series)
        XCTAssertTrue(
            series.label.contains("Tales of the Night Orchard 1 of 4"), series.label)

        // The list reopens on the picked series; picking the shortest restores the default.
        RemoteNavigation.press(.select, in: app, expecting: tales)
        RemoteNavigation.press(.up, in: app, expecting: island)
        RemoteNavigation.press(.right, in: app, expecting: islandCheck)
        RemoteNavigation.pressWithoutMoving(.select, in: app, from: islandCheck)
        XCTAssertTrue(islandCheck.isSelected)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(series)
        XCTAssertTrue(series.label.contains("The Island Cycle 1 of 3"), series.label)
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
        RemoteNavigation.waitForSidebarFocus("My Shelf", in: app)
        XCTAssertNil(RemoteNavigation.focused(app, prefix: "book-"))
        RemoteNavigation.press(.right, in: app, expecting: first)
    }

    func testDownBelowShelfDoesNotMoveFocus() {
        let app = RemoteNavigation.launch()
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: first)
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

    /// The sample library finishes every dated book in 2026, and rereads book 1 from 2024. The
    /// year menu opens on 2026, whose shelf runs earliest first.
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
        RemoteNavigation.waitForSidebarFocus("Year in Review", in: app)
        XCTAssertNil(RemoteNavigation.focused(app, prefix: "year-book-"))
        // Right closes the sidebar, and focus returns to the remembered cover.
        RemoteNavigation.press(.right, in: app, expecting: first)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Year in Review"
        capture.lifetime = .keepAlways
        add(capture)
    }

}
