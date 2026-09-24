import XCTest

@MainActor
final class SettingsInteractionTests: XCTestCase {
    private func openSettings(_ tab: String = "Shelf") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-test-settings", "--sample-library", "--settings-tab=\(tab)",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.openSettings(app)
        return app
    }

    /// Moves toward `element` in either column, as a user would.
    private func moveDown(to element: XCUIElement) {
        RemoteNavigation.moveFocus(to: element, in: XCUIApplication())
    }

    /// Text containing `text`, such as a date inside the reading line.
    private func text(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testDateFormatChangesAcrossViewsAndPersists() {
        let app = openSettings("General")
        let picker = app.descendants(matching: .any)["date-format-picker"].firstMatch
        moveDown(to: picker)
        XCTAssertEqual(picker.value as? String, "Jan 01, 2026")
        // The formats are a menu; choose the ISO format from it.
        XCUIRemote.shared.press(.select)
        let iso = "2026-01-31"
        XCTAssertTrue(
            app.descendants(matching: .any)[iso].firstMatch.waitForExistence(timeout: 5))
        // tvOS does not report focus on individual menu items. The menu opens on the current
        // format, the first option, and the ISO format is the fourth; the value check below
        // confirms the choice.
        for _ in 0..<3 { XCUIRemote.shared.press(.down) }
        XCUIRemote.shared.press(.select)
        let chosen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", iso), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 5), .completed)
        RemoteNavigation.showShelf(app)
        XCTAssertTrue(text(containing: "2026-09-09", in: app).waitForExistence(timeout: 5))
        if !app.buttons["book-1"].hasFocus { XCUIRemote.shared.press(.up) }
        let bookFocused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"), object: app.buttons["book-1"])
        XCTAssertEqual(XCTWaiter.wait(for: [bookFocused], timeout: 5), .completed)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "2026-09-09", in: app).exists)
        app.terminate()
        app.launchArguments = ["--sample-library"]
        app.launch()
        XCTAssertTrue(text(containing: "2026-09-09", in: app).waitForExistence(timeout: 15))
    }

    func testChooseSourcesOpensSourcesAndExplainsTokenEntry() {
        let app = XCUIApplication()
        app.launch()
        let choose = app.buttons["choose-sources"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        for _ in 0..<4 {
            if choose.hasFocus { break }
            XCUIRemote.shared.press(.up)
            if !choose.hasFocus { XCUIRemote.shared.press(.left) }
        }
        XCTAssertTrue(choose.hasFocus)
        XCUIRemote.shared.press(.select)
        let connect = app.buttons["Connect Hardcover"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["book-limit"].exists)
        moveDown(to: connect)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["hardcover-token"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["hardcover-token-qr"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.staticTexts["hardcover-step-1"].exists)
        XCTAssertTrue(app.staticTexts["hardcover-step-2"].exists)
        XCTAssertTrue(app.staticTexts["hardcover-step-3"].exists)
        XCTAssertTrue(app.staticTexts["hardcover-paste-help"].label.contains("paste"))
    }

    func testCountButtonsStepByFiveAndPersistAcrossLaunches() {
        let app = openSettings()
        let fewer = app.buttons["fewer-books"]
        // The count sits at the top of the right column.
        moveDown(to: fewer)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.staticTexts["book-limit"].label, "35")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.buttons["more-books-count"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.staticTexts["book-limit"].label, "40")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.staticTexts["book-limit"].label, "40")
        app.terminate()
        app.launchArguments = ["--sample-library"]
        app.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.openSettings(app)
        XCTAssertTrue(app.staticTexts["book-limit"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["book-limit"].label, "40")
    }

    func testProviderSettingsAreHiddenEvenWithLaunchShortcut() {
        let app = openSettings("AI spines")
        XCTAssertTrue(app.staticTexts["book-limit"].exists)
        XCTAssertFalse(app.buttons["AI spines"].exists)
        XCTAssertFalse(app.textFields["Vision model ID"].exists)
        XCTAssertFalse(app.buttons["Save provider"].exists)
        XCTAssertFalse(app.buttons["Regenerate spines"].exists)
        XCTAssertFalse(app.buttons["Stop generation"].exists)
    }

    func testCloudStorageToggleStopsManualSync() {
        let app = openSettings("General")
        let toggle = app.descendants(matching: .any)["icloud-storage"].firstMatch
        moveDown(to: toggle)
        // iCloud storage starts off.
        XCTAssertFalse(app.buttons["Sync iCloud now"].isEnabled)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Sync iCloud now"].isEnabled)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(app.buttons["Sync iCloud now"].isEnabled)
        XCTAssertTrue(app.staticTexts["icloud-status"].label.contains("off"))
    }

    func testWoodBackgroundToggleCanBeFocusedAndToggled() {
        let app = openSettings("General")
        let toggle = app.descendants(matching: .any)["wood-background-toggle"].firstMatch
        moveDown(to: toggle)
        XCTAssertTrue(RemoteNavigation.isFocused(toggle))
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(RemoteNavigation.isFocused(toggle))
    }

    func testFontStylePickerCanBeFocusedAndToggled() {
        let app = openSettings("General")
        let picker = app.descendants(matching: .any)["font-style-picker"].firstMatch
        moveDown(to: picker)
        for _ in 0..<2 {
            if app.buttons["Serif"].hasFocus { break }
            XCUIRemote.shared.press(.left)
        }
        XCTAssertTrue(app.buttons["Serif"].hasFocus)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Sans-serif"].hasFocus)
    }
}
