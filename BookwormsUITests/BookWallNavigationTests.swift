import UIKit
import XCTest

@MainActor
final class BookWallNavigationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // The test runner's Reduce Motion pass sets this; a pass without the setting tests nothing.
        if ProcessInfo.processInfo.environment["BOOKWORMS_EXPECT_REDUCE_MOTION"] == "1" {
            XCTAssertTrue(UIAccessibility.isReduceMotionEnabled, "Simulator Reduce Motion is off")
        }
    }

    func testSpineFocusDetailsAndSettledReturn() {
        let app = openWall()
        let first = app.buttons["book-wall-8"]
        RemoteNavigation.waitForFocus(first)
        let second = app.buttons["book-wall-7"]
        RemoteNavigation.press(.right, in: app, expecting: second)
        let above = app.buttons["book-wall-4"]
        RemoteNavigation.press(.up, in: app, expecting: above)
        RemoteNavigation.press(.down, in: app, expecting: second)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["book-wall-replay"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertEqual(app.state, .runningForeground, "Back closes details without leaving the app")
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(second)
        XCTAssertTrue(first.exists, "Returning from details keeps the settled wall mounted")

        // Details open from both edge columns, and focus returns to the same spine.
        for id in [8, 3] {
            let book = app.buttons["book-wall-\(id)"]
            RemoteNavigation.moveFocus(to: book, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(book.waitForExistence(timeout: 5))
            RemoteNavigation.waitForFocus(book)
        }
        assertSpinesInsideScreen(app)
    }

    func testDropAgainIsReachableAndRestoresTheWall() {
        let app = openWall()
        let first = app.buttons["book-wall-8"]
        let topRight = app.buttons["book-wall-3"]
        RemoteNavigation.moveFocus(to: topRight, in: app)
        let replay = app.buttons["book-wall-replay"]
        XCTAssertTrue(replay.exists)
        RemoteNavigation.press(.up, in: app, expecting: replay)
        replayAndWaitToLand(app)
        XCTAssertTrue(first.exists)
        RemoteNavigation.waitForFocus(replay)
        RemoteNavigation.press(.down, in: app, expecting: topRight)
        assertSpinesInsideScreen(app)
    }

    func testLeftFromSpineReachesNativeSidebarAndReturns() {
        let app = openWall()
        let first = app.buttons["book-wall-8"]
        RemoteNavigation.waitForFocus(first)
        let sidebar = app.staticTexts["Book Wall"].firstMatch
        RemoteNavigation.press(.left, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: first)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: first)
    }

    /// With Book Wall the only sidebar view, the waiting dialog offers no way back to My Shelf,
    /// which would show the wall again. Back shows Settings in one focus update, which the focus
    /// engine places, each time the dialog shows, and Back can then leave the app.
    func testBackFromTheWaitingDialogOpensSettingsWhenBookWallIsTheOnlyView() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--test-scenario=artwork", "--test-only-book-wall", "--test-wall-never-prepares",
            "--focus-probe", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        let waiting = app.staticTexts["Preparing Book Wall"]
        let sections = app.descendants(matching: .any)["settings-sections"]
        // The focus engine can place focus in the sidebar or in Settings, whose My Shelf toggle
        // shares a sidebar row's label, so this tells them apart by position.
        func focusIsInSidebar() -> Bool {
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex.last
            return focused.map { $0.frame.maxX < sections.frame.minX } ?? false
        }
        for attempt in 0..<2 {
            if attempt > 0 {
                if !focusIsInSidebar() { XCUIRemote.shared.press(.menu) }
                let sidebar = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in focusIsInSidebar() }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [sidebar], timeout: 5), .completed)
                RemoteNavigation.focusSidebarItem("Book Wall", in: app)
                XCUIRemote.shared.press(.select)
            }
            XCTAssertTrue(waiting.waitForExistence(timeout: 60))
            XCTAssertFalse(app.buttons["Back to My Shelf"].exists)
            let before = RemoteNavigation.transitions(app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(sections.waitForExistence(timeout: 5))
            RemoteNavigation.assertSettled(
                app, after: before, expectedUpdates: 1, file: #filePath, line: #line)
            XCTAssertFalse(waiting.exists)
        }
        // Back from Settings content opens the sidebar, and Back from the sidebar leaves the app.
        for _ in 0..<2 where app.state == .runningForeground {
            XCUIRemote.shared.press(.menu)
            _ = app.wait(for: .runningBackground, timeout: 3)
        }
        XCTAssertEqual(app.state, .runningBackground, "Back never left the app")
    }

    func testRendererKeepsCountedFocusInEveryDirectionAndReplays() {
        let app = openWall()
        let first = app.buttons["book-wall-8"]
        let second = app.buttons["book-wall-7"]
        let middle = app.buttons["book-wall-4"]
        let topRight = app.buttons["book-wall-3"]
        let replay = app.buttons["book-wall-replay"]
        let sidebar = app.staticTexts["Book Wall"].firstMatch

        RemoteNavigation.press(.right, in: app, expecting: second)
        RemoteNavigation.press(.up, in: app, expecting: middle)
        RemoteNavigation.press(.down, in: app, expecting: second)
        RemoteNavigation.press(.left, in: app, expecting: first)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: first)
        RemoteNavigation.press(.left, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: first)
        RemoteNavigation.press(.menu, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: first)
        RemoteNavigation.moveFocus(to: topRight, in: app)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: topRight)
        RemoteNavigation.press(.up, in: app, expecting: replay)
        if #available(tvOS 27, *) {
            // On tvOS 27, Up from the header reaches the sidebar natively.
            RemoteNavigation.press(.up, in: app, expecting: sidebar)
            RemoteNavigation.press(.right, in: app, expecting: topRight)
            RemoteNavigation.press(.up, in: app, expecting: replay)
        } else {
            RemoteNavigation.pressWithoutMoving(.up, in: app, from: replay)
        }
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: replay)
        RemoteNavigation.press(.left, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: topRight)
        RemoteNavigation.press(.up, in: app, expecting: replay)
        replayAndWaitToLand(app)
        XCTAssertTrue(first.exists)
        RemoteNavigation.waitForFocus(replay)
        RemoteNavigation.press(.down, in: app, expecting: topRight)
        assertSpinesInsideScreen(app)
        capture(app, name: "Book-Wall-renderer-replayed")
    }

    /// Companion designs change each spine's face and title case, and therefore book sizes.
    func testCompanionDesignsKeepCountedFocusInEveryDirection() {
        let app = openWall(companionDesigns: true)
        XCTAssertEqual(app.staticTexts["book-wall-design-probe"].label, "8")
        let first = app.buttons["book-wall-8"]
        let second = app.buttons["book-wall-7"]
        let middle = app.buttons["book-wall-4"]
        let topRight = app.buttons["book-wall-3"]
        let replay = app.buttons["book-wall-replay"]
        let sidebar = app.staticTexts["Book Wall"].firstMatch

        RemoteNavigation.press(.right, in: app, expecting: second)
        RemoteNavigation.press(.up, in: app, expecting: middle)
        RemoteNavigation.press(.down, in: app, expecting: second)
        RemoteNavigation.press(.left, in: app, expecting: first)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: first)
        RemoteNavigation.press(.left, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: first)
        RemoteNavigation.press(.menu, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: first)
        RemoteNavigation.moveFocus(to: topRight, in: app)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: topRight)
        RemoteNavigation.press(.up, in: app, expecting: replay)
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: replay)
        RemoteNavigation.press(.down, in: app, expecting: topRight)
        assertSpinesInsideScreen(app)
        capture(app, name: "Book-Wall-companion-designs")
    }

    func testRendererRestoresBothEdgeBooksAfterDetailsAndTabReentry() {
        let app = openWall()
        for (id, title) in [
            (8, "Winter in the Orchard"), (3, "Tides of the Changing Coast"),
        ] {
            let book = app.buttons["book-wall-\(id)"]
            RemoteNavigation.moveFocus(to: book, in: app)
            XCTAssertEqual(book.label, "\(title), by Alex Rowan")
            capture(app, name: "Book-Wall-renderer-edge-\(id)-focused")
            XCUIRemote.shared.press(.select)
            let detail = app.staticTexts["detail-title"]
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertEqual(detail.label, title)
            XCTAssertFalse(app.buttons["book-wall-replay"].exists)
            XCTAssertEqual(
                app.buttons.matching(identifier: "back-to-shelf").count, 1,
                "Details show only the wall's Back button")
            capture(app, name: "Book-Wall-renderer-edge-\(id)-detail")
            XCUIRemote.shared.press(.menu)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(book.waitForExistence(timeout: 5))
            RemoteNavigation.waitForFocus(book)
            assertSpinesInsideScreen(app)
            capture(app, name: "Book-Wall-renderer-edge-\(id)-returned")

            RemoteNavigation.selectView("My Shelf", in: app)
            XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 5))
            RemoteNavigation.selectView("Book Wall", in: app)
            XCTAssertTrue(book.waitForExistence(timeout: 15))
            RemoteNavigation.waitForFocus(book)
            XCTAssertFalse(detail.exists, "Tab reentry keeps the wall closed")
        }
    }

    /// Back from the shelf that wall details filtered reveals those details, which stayed open
    /// beneath it: the book never flies out again, and focus returns to the author that applied
    /// the filter.
    func testBackFromDetailFilterReturnsToDetailsWithoutAnotherFlight() {
        let app = openWall()
        let book = app.buttons["book-wall-8"]
        RemoteNavigation.waitForFocus(book)
        XCUIRemote.shared.press(.select)
        let title = app.staticTexts["detail-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let back = app.buttons["back-to-shelf"]
        RemoteNavigation.waitForFocus(back)
        let flights = app.staticTexts["book-wall-flight-probe"]
        XCTAssertEqual(flights.label, "1")
        let author = app.buttons["detail-author"]
        RemoteNavigation.press(.right, in: app, expecting: author)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["clear-shelf-filter"].waitForExistence(timeout: 5))
        let shelfBook = app.buttons["book-8"]
        RemoteNavigation.waitForFocus(shelfBook)
        XCTAssertFalse(title.exists && title.isHittable, "The shelf didn't cover the details")

        let before = RemoteNavigation.transitions(app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(title.exists, "Details weren't there at once")
        XCTAssertEqual(title.label, "Winter in the Orchard")
        RemoteNavigation.waitForFocus(author)
        // Observe a full settle window so a late update or flight is counted.
        _ = XCTWaiter.wait(
            for: [XCTestExpectation(description: "Details settle")],
            timeout: RemoteNavigation.settleWindow)
        XCTAssertEqual(flights.label, "1", "Back from the filter flew the book out again")
        XCTAssertTrue(RemoteNavigation.isFocused(author))
        XCTAssertFalse(app.buttons["clear-shelf-filter"].exists)
        // Two updates: the leaving shelf clears focus, and the details restore it to the author.
        XCTAssertEqual(RemoteNavigation.transitions(app), before.map { $0 + 2 })

        // Back from the author closes the details onto the same spine.
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(book)
    }

    /// Details opened on the shelf that wall details filtered return focus to their book, and
    /// the wall details stay open beneath both: Back reaches them without another flight.
    func testBackThroughDetailsOnAFilteredShelfKeepsTheWallDetails() throws {
        let app = openWall()
        let book = app.buttons["book-wall-8"]
        RemoteNavigation.waitForFocus(book)
        XCUIRemote.shared.press(.select)
        let title = app.staticTexts["detail-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(app.buttons["back-to-shelf"])
        let flights = app.staticTexts["book-wall-flight-probe"]
        XCTAssertEqual(flights.label, "1")
        let author = app.buttons["detail-author"]
        RemoteNavigation.press(.right, in: app, expecting: author)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["clear-shelf-filter"].waitForExistence(timeout: 5))
        let entry = app.buttons["book-8"]
        RemoteNavigation.waitForFocus(entry)
        // Every scenario book shares book 8's author, and the shelf pages before it, so book 7
        // to its left sits on the page before book 8's.
        let other = app.buttons["book-7"]
        RemoteNavigation.press(.left, in: app, expecting: other)
        XCUIRemote.shared.press(.select)
        RemoteNavigation.waitForFocus(
            app.buttons
                .matching(
                    NSPredicate(format: "identifier == %@ AND hasFocus == true", "back-to-shelf")
                )
                .firstMatch)
        XCTAssertFalse(
            RemoteNavigation.visibleButtons(app, prefix: "book-7").isEmpty,
            "The shelf beneath the details paged away from their book")

        var before = try XCTUnwrap(RemoteNavigation.transitions(app))
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(other)
        _ = XCTWaiter.wait(
            for: [XCTestExpectation(description: "Shelf settles")],
            timeout: RemoteNavigation.settleWindow)
        XCTAssertTrue(RemoteNavigation.isFocused(other))
        // Two updates: the leaving details clear focus, and the shelf restores it to book 7.
        XCTAssertEqual(RemoteNavigation.transitions(app), before + 2)
        XCTAssertFalse(RemoteNavigation.visibleButtons(app, prefix: "book-7").isEmpty)

        before = try XCTUnwrap(RemoteNavigation.transitions(app))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(title.exists, "The wall details closed under the filtered shelf")
        XCTAssertEqual(title.label, "Winter in the Orchard")
        RemoteNavigation.waitForFocus(author)
        _ = XCTWaiter.wait(
            for: [XCTestExpectation(description: "Details settle")],
            timeout: RemoteNavigation.settleWindow)
        XCTAssertEqual(flights.label, "1", "Back from the filter flew the book out again")
        XCTAssertTrue(RemoteNavigation.isFocused(author))
        // Two updates: the leaving shelf clears focus, and the details restore it to the author.
        XCTAssertEqual(RemoteNavigation.transitions(app), before + 2)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(book)
    }

    /// The clear button on a shelf that wall details filtered closes those details and shows
    /// the whole of My Shelf on the book whose details applied the filter.
    func testClearingDetailFilterShowsWholeShelf() {
        let app = openWall()
        let book = app.buttons["book-wall-8"]
        RemoteNavigation.waitForFocus(book)
        XCUIRemote.shared.press(.select)
        let back = app.buttons["back-to-shelf"]
        RemoteNavigation.waitForFocus(back)
        let author = app.buttons["detail-author"]
        RemoteNavigation.press(.right, in: app, expecting: author)
        XCUIRemote.shared.press(.select)
        let clear = app.buttons["clear-shelf-filter"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let shelfBook = app.buttons["book-8"]
        RemoteNavigation.waitForFocus(shelfBook)
        RemoteNavigation.press(.down, in: app, expecting: clear)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["book-2"].waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(shelfBook)
        XCTAssertFalse(clear.exists)
        XCTAssertFalse(app.staticTexts["detail-title"].exists)
    }

    func testRendererExposesBookDescriptionsAndAccessibleDetails() throws {
        let app = openWall()
        for id in 1...8 {
            let book = app.buttons["book-wall-\(id)"]
            XCTAssertTrue(book.label.hasSuffix(", by Alex Rowan"))
            XCTAssertGreaterThan(book.label.count, ", by Alex Rowan".count)
        }
        XCTAssertEqual(app.buttons["book-wall-replay"].label, "Drop again")
        try audit(app)
        RemoteNavigation.moveFocus(to: app.buttons["book-wall-8"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        try audit(app)
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(app.buttons["book-wall-8"])
    }

    func testRetryAfterRendererErrorRestoresTheWall() {
        let app = launchWithWall(arguments: ["--test-fail-book-wall-renderer"])
        RemoteNavigation.focusSidebarItem("Book Wall", in: app)
        // The stopped wall's only control is Retry, so Select moves focus once, straight to it.
        let retry = app.buttons["book-wall-retry"]
        RemoteNavigation.press(.select, in: app, expecting: retry)
        XCTAssertFalse(app.buttons["book-wall-8"].exists, "A stopped wall offers no spines")
        let sidebar = app.staticTexts["Book Wall"].firstMatch
        RemoteNavigation.press(.left, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: retry)
        RemoteNavigation.press(.menu, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: retry)
        // Only the first connection fails, so Retry brings the wall back.
        RemoteNavigation.press(.select, in: app, expecting: app.buttons["book-wall-8"])
        XCTAssertTrue(app.buttons["book-wall-replay"].waitForExistence(timeout: 20))
        XCTAssertFalse(retry.exists)
    }

    func testRetryKeepsFocusWhileTheRendererFailsAgain() {
        let app = launchWithWall(arguments: ["--test-fail-book-wall-renderer=2"])
        RemoteNavigation.focusSidebarItem("Book Wall", in: app)
        let retry = app.buttons["book-wall-retry"]
        RemoteNavigation.press(.select, in: app, expecting: retry)
        // The second connection fails too, so the press leaves focus on Retry.
        RemoteNavigation.pressWithoutMoving(.select, in: app, from: retry)
        XCTAssertFalse(app.buttons["book-wall-8"].exists, "A stopped wall offers no spines")
        RemoteNavigation.press(.select, in: app, expecting: app.buttons["book-wall-8"])
        XCTAssertTrue(app.buttons["book-wall-replay"].waitForExistence(timeout: 20))
        XCTAssertFalse(retry.exists)
    }

    // MARK: - Pages

    func testASyncDuringAFallLeavesTheWallAlone() {
        let app = openInventedWall(books: 36, arguments: ["--test-wall-syncs-during-replay"])
        let replay = app.buttons["book-wall-replay"]
        RemoteNavigation.moveFocus(to: replay, in: app)
        let wallID = app.staticTexts["book-wall-id-probe"]
        let before = wallID.label
        let falls = Int(app.staticTexts["book-wall-fall-probe"].label) ?? 0
        XCUIRemote.shared.press(.select)
        waitForFalls(falls + 1, in: app)
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Sync settles")], timeout: 10)
        XCTAssertEqual(wallID.label, before, "A sync replaced the wall under the reader")
        XCTAssertEqual(app.staticTexts["book-wall-fall-probe"].label, String(falls + 1))
        XCTAssertEqual(app.staticTexts["book-wall-cut-falls-probe"].label, "0")
    }

    func testASyncWaitsUntilTheReaderLeavesTheWall() {
        let app = launchWithWall(arguments: ["--test-wall-keeps-syncing"])
        RemoteNavigation.focusSidebarItem("Book Wall", in: app)
        let entry = app.buttons["book-wall-8"]
        RemoteNavigation.press(.select, in: app, expecting: entry)
        let replay = app.buttons["book-wall-replay"]
        XCTAssertTrue(replay.waitForExistence(timeout: 30))
        let drops = app.staticTexts["book-wall-drops-probe"]
        let wallID = app.staticTexts["book-wall-id-probe"]
        let dropsAtEntry = drops.label
        XCTAssertLessThanOrEqual(Int(dropsAtEntry) ?? 2, 1, "A sync restarted the first fall")
        func wait(_ seconds: TimeInterval) {
            _ = XCTWaiter.wait(
                for: [XCTestExpectation(description: "Syncs run")], timeout: seconds)
        }

        let wallOnEntry = wallID.label
        wait(10)
        XCTAssertEqual(wallID.label, wallOnEntry, "A sync replaced the resting wall")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 15))
        wait(10)
        XCTAssertEqual(wallID.label, wallOnEntry, "A sync replaced the wall behind details")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        wait(6)
        XCTAssertEqual(wallID.label, wallOnEntry, "A sync replaced the wall after details")
        XCTAssertEqual(drops.label, dropsAtEntry, "Closing details dropped the books")

        RemoteNavigation.selectView("My Shelf", in: app)
        wait(10)
        RemoteNavigation.focusSidebarItem("Book Wall", in: app)
        RemoteNavigation.press(.select, in: app, expecting: entry)
        XCTAssertNotEqual(wallID.label, wallOnEntry, "The newer wall should show on return")
        XCTAssertEqual(drops.label, dropsAtEntry, "Returning dropped the books")
    }

    func testAYearOnOnePageShowsNoPageMenu() {
        let app = openWall()
        XCTAssertFalse(app.buttons["book-wall-page-options"].exists)
    }

    func testPageMenuLinesUpWithDropAgainAndKeepsCountedFocus() {
        let app = openInventedWall(books: 100)
        let menu = app.buttons["book-wall-page-options"]
        let replay = app.buttons["book-wall-replay"]
        let sidebar = app.staticTexts["Book Wall"].firstMatch
        XCTAssertTrue(menu.exists)
        XCTAssertEqual(menu.label, "Page")
        XCTAssertEqual(menu.value as? String, "1 of 2")
        XCTAssertEqual(menu.frame.minY, replay.frame.minY, accuracy: 1)
        XCTAssertEqual(menu.frame.height, replay.frame.height, accuracy: 1)
        XCTAssertLessThan(menu.frame.maxX, replay.frame.minX)

        RemoteNavigation.moveFocus(to: replay, in: app)
        RemoteNavigation.press(.left, in: app, expecting: menu)
        RemoteNavigation.press(.right, in: app, expecting: replay)
        RemoteNavigation.press(.left, in: app, expecting: menu)
        RemoteNavigation.press(.left, in: app, expecting: sidebar)
        pressToSpine(.right, in: app)
        RemoteNavigation.press(.menu, in: app, expecting: sidebar)
        pressToSpine(.right, in: app)
        RemoteNavigation.moveFocus(to: replay, in: app)
        RemoteNavigation.press(.left, in: app, expecting: menu)
        pressToSpine(.down, in: app)
    }

    func testChoosingAPageDropsItsBooksAndLeavesFocusOnTheMenu() {
        let app = openInventedWall(books: 100)
        let menu = app.buttons["book-wall-page-options"]
        let replay = app.buttons["book-wall-replay"]
        let firstPage = shownBooks(app)
        XCTAssertEqual(firstPage, Array(1...firstPage.count), "January comes first")

        RemoteNavigation.moveFocus(to: replay, in: app)
        RemoteNavigation.press(.left, in: app, expecting: menu)
        let falls = Int(app.staticTexts["book-wall-fall-probe"].label) ?? 0
        choosePage(2, on: menu, in: app)
        capture(app, name: "Book-Wall-page-2-falling")
        waitForFalls(falls + 1, in: app)
        RemoteNavigation.waitForFocus(menu)
        XCTAssertEqual(menu.value as? String, "2 of 2")
        let secondPage = shownBooks(app)
        XCTAssertEqual(
            secondPage, Array((firstPage.count + 1)...100), "No book is lost or repeated")
        XCTAssertEqual(app.staticTexts["book-wall-seated-probe"].label, "0")
        capture(app, name: "Book-Wall-page-2")

        // Landing moves no focus, and Drop again drops the same page.
        let updates = RemoteNavigation.transitions(app)
        _ = XCTWaiter.wait(
            for: [XCTestExpectation(description: "Focus stays")],
            timeout: RemoteNavigation.settleWindow)
        XCTAssertEqual(RemoteNavigation.transitions(app), updates)
        RemoteNavigation.press(.right, in: app, expecting: replay)
        replayAndWaitToLand(app)
        XCTAssertEqual(shownBooks(app), secondPage)
        XCTAssertEqual(menu.value as? String, "2 of 2")
        XCTAssertEqual(app.staticTexts["book-wall-seated-probe"].label, "0")

        // Down enters the new page's spines, and every spine stays on screen.
        RemoteNavigation.press(.left, in: app, expecting: menu)
        pressToSpine(.down, in: app)
        for id in secondPage {
            let frame = app.buttons["book-wall-\(id)"].frame
            XCTAssertTrue(app.frame.contains(frame), "Book \(id) extends outside the screen")
        }

        // A page shown before returns.
        RemoteNavigation.moveFocus(to: replay, in: app)
        RemoteNavigation.press(.left, in: app, expecting: menu)
        let secondFalls = Int(app.staticTexts["book-wall-fall-probe"].label) ?? 0
        choosePage(1, on: menu, in: app)
        waitForFalls(secondFalls + 1, in: app)
        XCTAssertEqual(shownBooks(app), firstPage)
        RemoteNavigation.waitForFocus(menu)
    }

    func testSpinesWaitWhileAPagePreparesAndItsArrivalMovesNoFocus() {
        let app = openInventedWall(books: 100, arguments: ["--test-wall-slow-pages"])
        let menu = app.buttons["book-wall-page-options"]
        let replay = app.buttons["book-wall-replay"]
        let firstPage = shownBooks(app)
        RemoteNavigation.moveFocus(to: replay, in: app)
        RemoteNavigation.press(.left, in: app, expecting: menu)
        let falls = Int(app.staticTexts["book-wall-fall-probe"].label) ?? 0
        choosePage(2, on: menu, in: app)
        RemoteNavigation.waitForFocus(menu)
        XCTAssertEqual(shownBooks(app), firstPage, "The chosen page is still preparing")
        XCTAssertFalse(app.buttons["book-wall-\(firstPage[0])"].isEnabled)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: menu)

        let updates = RemoteNavigation.transitions(app)
        waitForFalls(falls + 1, in: app)
        XCTAssertNotEqual(shownBooks(app), firstPage)
        XCTAssertEqual(RemoteNavigation.transitions(app), updates)
        RemoteNavigation.waitForFocus(menu)
        pressToSpine(.down, in: app)
    }

    func testDetailsReturnToTheSamePageAndBook() {
        let app = openInventedWall(books: 100, arguments: ["--test-wall-page=2"])
        let menu = app.buttons["book-wall-page-options"]
        XCTAssertEqual(menu.value as? String, "2 of 2")
        let books = shownBooks(app)
        let entry = app.buttons["book-wall-\(books[0])"]
        RemoteNavigation.moveFocus(to: entry, in: app)
        let beside = app.buttons["book-wall-\(books[1])"]
        RemoteNavigation.press(.right, in: app, expecting: beside)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCTAssertFalse(menu.exists, "Details cover the header")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(beside.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(beside)
        XCTAssertEqual(shownBooks(app), books)
        XCTAssertEqual(menu.value as? String, "2 of 2")

        // Left from the leftmost spine and Back both reach the native sidebar.
        let sidebar = app.staticTexts["Book Wall"].firstMatch
        RemoteNavigation.press(.left, in: app, expecting: entry)
        RemoteNavigation.press(.left, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: entry)
        RemoteNavigation.press(.menu, in: app, expecting: sidebar)
        RemoteNavigation.press(.right, in: app, expecting: entry)
    }

    func testAPagePastTheYearShowsTheLastPage() {
        let app = openInventedWall(books: 100, arguments: ["--test-wall-page=99"])
        XCTAssertEqual(app.buttons["book-wall-page-options"].value as? String, "2 of 2")
        XCTAssertEqual(shownBooks(app).last, 100)
    }

    /// Presses `direction` and requires one stable focus update, to any of the page's spines.
    private func pressToSpine(
        _ direction: XCUIRemote.Button, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let before = RemoteNavigation.transitions(app)
        XCUIRemote.shared.press(direction)
        RemoteNavigation.assertSettled(
            app, after: before, expectedUpdates: 1, file: file, line: line)
        // Identifiers with this prefix also name Drop again and the menu, without a book's ID.
        let id = RemoteNavigation.focused(app, prefix: "book-wall-")?.identifier
            .dropFirst("book-wall-".count)
        XCTAssertNotNil(
            id.flatMap { Int($0) }, "Focus did not reach a spine", file: file, line: line)
    }

    /// Opens the page menu from focus on it, and chooses `page`, counted from 1.
    private func choosePage(
        _ page: Int, on menu: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCUIRemote.shared.press(.select)
        let item = app.descendants(matching: .any)["Page \(page)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), file: file, line: line)
        capture(app, name: "Book-Wall-menu-choosing-page-\(page)")
        // The menu opens on the current page, and its items run down in order.
        for _ in 0..<8 where !RemoteNavigation.hasFocus(labeled: "Page \(page)", in: app) {
            XCUIRemote.shared.press(page == 1 ? .up : .down)
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Moved")], timeout: 0.5)
        }
        XCUIRemote.shared.press(.select)
        let chosen = NSPredicate(format: "value BEGINSWITH %@", "\(page) of ")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: chosen, object: menu)], timeout: 10),
            .completed, "The menu did not choose page \(page)", file: file, line: line)
    }

    /// Waits until `count` falls have finished: with a new page, once its books have landed.
    private func waitForFalls(
        _ count: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let landed = NSPredicate(format: "label == %@", String(count))
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: landed, object: app.staticTexts["book-wall-fall-probe"])
                ], timeout: 60),
            .completed, "The page's books did not land", file: file, line: line)
    }

    /// The IDs of the books on the page the wall shows, in finish order.
    private func shownBooks(_ app: XCUIApplication) -> [Int] {
        app.staticTexts["book-wall-books-probe"].label
            .split(separator: ",").compactMap { Int($0) }
    }

    /// Enters the wall of a year of `count` invented books, once its books have landed.
    private func openInventedWall(books count: Int, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "--test-scenario=artwork", "--start-view=shelf", "--test-enable-book-wall",
                "--focus-probe", "--test-wall-books=\(count)",
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            ] + arguments
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        let shelfBook = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
            .firstMatch
        XCTAssertTrue(shelfBook.waitForExistence(timeout: 60))
        RemoteNavigation.focusSidebarItem("Book Wall", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["book-wall-replay"].waitForExistence(timeout: 60))
        return app
    }

    private func launchWithWall(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "--test-scenario=artwork", "--start-view=shelf", "--test-enable-book-wall",
                "--focus-probe",
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            ] + arguments
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
        return app
    }

    private func openWall(companionDesigns: Bool = false) -> XCUIApplication {
        let app = launchWithWall(arguments: companionDesigns ? ["--test-companion-designs"] : [])
        // The scenario enables Book Wall; enter it through the native sidebar, as a viewer does.
        // The spines exist in the page's first render, so Select moves focus once, straight to
        // the entry book.
        RemoteNavigation.focusSidebarItem("Book Wall", in: app)
        let entry = app.buttons["book-wall-8"]
        RemoteNavigation.press(.select, in: app, expecting: entry)
        let updates = RemoteNavigation.transitions(app)
        // Spines are focusable while books fall; landing republishes their rectangles without
        // moving focus, and Drop again appears once they rest.
        XCTAssertTrue(app.buttons["book-wall-replay"].waitForExistence(timeout: 20))
        XCTAssertEqual(RemoteNavigation.transitions(app), updates, "Landing moved focus")
        return app
    }

    /// Presses Select on the focused Drop again button and waits for the replayed books to
    /// land. Spines stay mounted during a replay, and with Reduce Motion the status text can
    /// clear before a check runs, so the wall's fall count is the only lasting evidence.
    private func replayAndWaitToLand(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let probe = app.staticTexts["book-wall-fall-probe"]
        let landed = Int(probe.label) ?? 0
        XCUIRemote.shared.press(.select)
        let replayed = NSPredicate(format: "label == %@", String(landed + 1))
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: replayed, object: probe)],
                timeout: 15),
            .completed, "Drop again did not replay the fall", file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func audit(_ app: XCUIApplication) throws {
        // The one-pixel probes report test evidence, not user-facing content.
        try app.auditAccessibility {
            [
                "scenario-probe", "focus-transition-probe", "book-wall-fall-probe",
                "book-wall-design-probe", "book-wall-seated-probe", "book-wall-books-probe",
                "book-wall-drops-probe", "book-wall-cut-falls-probe", "book-wall-id-probe",
            ]
            .contains($0.element?.identifier ?? "")
        }
    }

    private func assertSpinesInsideScreen(_ app: XCUIApplication) {
        for id in 1...8 {
            let book = app.buttons["book-wall-\(id)"]
            XCTAssertTrue(book.exists)
            XCTAssertTrue(app.frame.contains(book.frame), "Book \(id) extends outside the screen")
        }
    }
}
