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
        // The empty scenario has no books and answers the link-code request locally.
        app.launchEnvironment["BOOKWORMS_SCENARIO_CONTROL"] = UUID().uuidString
        app.launchArguments = ["--test-scenario=empty", "--test-appearance=dark"]
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
        // The scenario's login works, so Sources offers Disconnect instead of a sheet.
        let disconnect = app.buttons["Disconnect Hardcover"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["book-limit"].exists)
        moveDown(to: disconnect)
        XCUIRemote.shared.press(.select)
        let connect = app.buttons["Connect Hardcover"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(connect)
        XCUIRemote.shared.press(.select)
        // The fixture issues a link code; the card shows it beside the QR code.
        XCTAssertTrue(app.staticTexts["hardcover-device-code"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hardcover-device-code"].label, "TEST-1234")
        XCTAssertTrue(app.images["hardcover-token-qr"].exists)
        XCTAssertTrue(
            app.staticTexts["hardcover-instructions"].label.contains("hardcover.app/link"))
        XCTAssertFalse(app.buttons["Back to Sources"].exists)
        XCTAssertFalse(app.textFields["hardcover-token"].exists)
        let manual = app.buttons["hardcover-manual-entry"]
        RemoteNavigation.waitForFocus(manual)
        XCTAssertTrue(app.buttons["New code"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Hardcover sign-in"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["hardcover-token"].waitForExistence(timeout: 5))
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
        RemoteNavigation.openSettings(app, section: "Shelf")
        XCTAssertTrue(app.staticTexts["book-limit"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["book-limit"].label, "40")
    }

    func testProviderSettingsAreHiddenEvenWithLaunchShortcut() {
        let app = openSettings("AI spines")
        // The hidden tab falls back to the default, Views.
        XCTAssertTrue(app.staticTexts["comparison-limit"].waitForExistence(timeout: 5))
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

    func testLeftFromFirstSettingsTabOpensSidebar() {
        let app = RemoteNavigation.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.selectView("Settings", in: app)
        let tabs = app.descendants(matching: .any)["settings-sections"]
        let views = tabs.buttons["Views"]
        XCTAssertTrue(views.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(views)
        XCUIRemote.shared.press(.left)
        let leftTabs = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == false"), object: views)
        XCTAssertEqual(XCTWaiter.wait(for: [leftTabs], timeout: 3), .completed)
        XCTAssertFalse(
            tabs.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
        RemoteNavigation.press(.right, in: app, expecting: views)
        RemoteNavigation.press(.right, in: app, expecting: tabs.buttons["Shelf"])
        XCTAssertTrue(
            app.descendants(matching: .any)["shelf-collection"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings tabs"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
