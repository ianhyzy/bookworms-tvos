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
            XCTAssertEqual(book.label, "\(title), Alex Rowan")
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
            XCTAssertTrue(book.label.hasSuffix(", Alex Rowan"))
            XCTAssertGreaterThan(book.label.count, ", Alex Rowan".count)
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

    private func openWall(companionDesigns: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--test-scenario=artwork", "--start-view=shelf", "--test-enable-book-wall",
            "--focus-probe",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        if companionDesigns { app.launchArguments.append("--test-companion-designs") }
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
        // The scenario enables Book Wall; enter it through the native sidebar, as a viewer does.
        // The spines exist in the tab's first render, so Select moves focus once, straight to
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
                "book-wall-design-probe",
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
