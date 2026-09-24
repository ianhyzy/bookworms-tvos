import XCTest

@MainActor
final class ShelfNavigationTests: XCTestCase {
    func testSelectBookReadDetailsAndReturnToShelf() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-test-settings", "--sample-library"]
        app.launch()
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
        let initialY = app.staticTexts["book-description"].frame.minY
        XCUIRemote.shared.press(.down)
        XCTAssertLessThan(
            app.staticTexts["book-description"].frame.minY, initialY,
            "The first Down press must scroll without selecting a scrollbar.")
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

}
