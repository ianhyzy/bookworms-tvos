import UIKit
import XCTest

@MainActor
final class BookWallNavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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

        // Both edge columns use the full-screen projection and restore the same selected model.
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
        XCUIRemote.shared.press(.select)
        waitForReplayToLand(app)
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
        XCUIRemote.shared.press(.select)
        waitForReplayToLand(app)
        XCTAssertTrue(first.exists)
        RemoteNavigation.waitForFocus(replay)
        RemoteNavigation.press(.down, in: app, expecting: topRight)
        assertSpinesInsideScreen(app)
        capture(app, name: "Book-Wall-renderer-replayed")
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

    private func openWall() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--test-scenario=artwork", "--start-view=shelf", "--test-enable-book-wall",
            "--focus-probe",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
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

    /// Waits for a replay started by Drop again to finish. Spines stay mounted during a replay,
    /// so their existence does not show that the books have landed. With Reduce Motion the wall
    /// arranges the books at once and its status can clear before this check runs.
    private func waitForReplayToLand(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let status = app.staticTexts[
            reduceMotion ? "Arranging books…" : "Books are falling into place…"]
        if !reduceMotion {
            XCTAssertTrue(
                status.waitForExistence(timeout: 2), "Drop again did not start a fall",
                file: file, line: line)
        }
        XCTAssertTrue(
            status.waitForNonExistence(timeout: 15), "The replayed books did not land",
            file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: [
            .contrast, .textClipped, .sufficientElementDescription, .trait,
        ]) { issue in
            // The one-pixel probes report test evidence, not user-facing content.
            ["scenario-probe", "focus-transition-probe"].contains(issue.element?.identifier ?? "")
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
