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

    /// Text containing `text`, such as a date inside the reading line.
    private func text(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testDateFormatChangesAcrossViewsAndPersists() {
        let app = openSettings("General")
        let picker = app.descendants(matching: .any)["date-format-picker"].firstMatch
        RemoteNavigation.moveFocus(to: picker, in: app)
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

    func testChooseSourcesOpensSourcesAndExplainsLinkSignIn() {
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
        RemoteNavigation.moveFocus(to: disconnect, in: app)
        XCUIRemote.shared.press(.select)
        let connect = app.buttons["Connect Hardcover"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        RemoteNavigation.waitForFocus(connect)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["hardcover-instructions"].waitForExistence(timeout: 5))
        // **New code** shows while the code is requested and after, so focus enters the card
        // inside the sheet's scroll view without a press.
        RemoteNavigation.waitForFocus(app.buttons["hardcover-new-code"])
        XCTAssertTrue(app.descendants(matching: .any)["hardcover-token-qr"].firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["hardcover-instructions"].label.contains("hardcover.app/link"))
        XCTAssertFalse(app.buttons["Back to Sources"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Hardcover sign-in"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// **Settings → Spines** names the model behind each cached companion design, with a count.
    /// It has no controls, so Down leaves focus on its tab, and Left and Right move along the
    /// tabs with one focus update each.
    func testSpinesNamesEachDesignsModelWithCountedFocus() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--test-scenario=artwork", "--test-companion-designs", "--start-view=shelf",
            "--settings-tab=Spines", "--focus-probe", "--test-appearance=dark",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
        RemoteNavigation.openSettings(app)
        let tabs = app.descendants(matching: .any)["settings-sections"]
        let spines = tabs.buttons["Spines"]
        RemoteNavigation.waitForFocus(spines)
        XCTAssertTrue(
            app.descendants(matching: .any)["spine-makers"].waitForExistence(timeout: 10))
        for (model, count) in [
            ("Private Cloud Compute", "1 book"), ("Google Gemini (gemini-3.8-flash)", "4 books"),
            ("Apple on-device model", "2 books"), ("Default styling", "1 book"),
        ] {
            let label = NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", model, count)
            let row = app.descendants(matching: .any).matching(label)
            XCTAssertTrue(row.firstMatch.exists, "\(model): \(count)")
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings spines"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        RemoteNavigation.pressWithoutMoving(.down, in: app, from: spines)
        RemoteNavigation.press(.right, in: app, expecting: tabs.buttons["Sources"])
        RemoteNavigation.press(.left, in: app, expecting: spines)
        RemoteNavigation.press(.left, in: app, expecting: tabs.buttons["Shelf"])
        RemoteNavigation.press(.right, in: app, expecting: spines)
    }

    /// Without designs, **Settings → Spines** lists no models and says Book Wall shows a default
    /// look, and that iCloud storage is off.
    func testSpinesWithoutDesignsExplainsBookWallsOwnLook() {
        let app = openSettings("Spines")
        XCTAssertTrue(
            text(containing: "Book Wall shows a default look", in: app).waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.descendants(matching: .any)["spine-makers"].exists)
        XCTAssertTrue(text(containing: "iCloud storage is off", in: app).exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings spines without designs"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCountButtonsStepByFiveAndPersistAcrossLaunches() {
        let app = openSettings()
        let fewer = app.buttons["fewer-books"]
        // The count sits at the top of the right column.
        RemoteNavigation.moveFocus(to: fewer, in: app)
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
        RemoteNavigation.moveFocus(to: toggle, in: app)
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
        RemoteNavigation.moveFocus(to: toggle, in: app)
        // VoiceOver reads the toggle's state from its value or selected trait.
        let state = { "\(String(describing: toggle.value)) \(toggle.isSelected)" }
        let initial = state()
        // Each Select flips the state and leaves focus on the toggle.
        for expectsInitial in [false, true] {
            XCUIRemote.shared.press(.select)
            let flipped = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in (state() == initial) == expectsInitial },
                object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [flipped], timeout: 5), .completed)
            RemoteNavigation.waitForFocus(toggle)
        }
    }

    func testFontStylePickerCanBeFocusedAndToggled() {
        let app = openSettings("General")
        let picker = app.descendants(matching: .any)["font-style-picker"].firstMatch
        RemoteNavigation.moveFocus(to: picker, in: app)
        let serif = app.buttons["Serif"]
        let sans = app.buttons["Sans-serif"]
        for _ in 0..<2 where !RemoteNavigation.isFocused(serif) {
            XCUIRemote.shared.press(.left)
        }
        RemoteNavigation.waitForFocus(serif)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let chosen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: sans)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 5), .completed)
        RemoteNavigation.waitForFocus(sans)
    }

    func testProgressBarsMenuReachesNeighborsAndBackOpensSidebarAfterAChoice() {
        let app = RemoteNavigation.launch(arguments: ["--settings-tab=Shelf"])
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.openSettings(app)
        let picker = app.descendants(matching: .any)["shelf-progress"].firstMatch
        let sort = app.descendants(matching: .any)["shelf-sort"].firstMatch
        RemoteNavigation.moveFocus(to: picker, in: app)
        XCTAssertEqual(picker.value as? String, "Vertical")
        RemoteNavigation.press(.up, in: app, expecting: sort)
        RemoteNavigation.press(.down, in: app, expecting: picker)
        // The right column's controls sit higher, so Right has no target; Up then Right does.
        RemoteNavigation.pressWithoutMoving(.right, in: app, from: picker)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: picker)

        // Whether the menu opens on the first choice or the current one, two presses up reach
        // Don't show, the first.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["Horizontal"].firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.select)
        let chosen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Don't show"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 5), .completed)
        RemoteNavigation.waitForFocus(picker)
        XCUIRemote.shared.press(.menu)
        let sidebar = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in RemoteNavigation.hasFocus(labeled: "Settings", in: app)
            },
            object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [sidebar], timeout: 5), .completed,
            "Back after a menu choice opens the sidebar")
        XCTAssertEqual(app.state, .runningForeground)
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
        RemoteNavigation.waitForSidebarFocus("Settings", in: app)
        XCTAssertFalse(
            tabs.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
        RemoteNavigation.press(.right, in: app, expecting: views)
        RemoteNavigation.press(.right, in: app, expecting: tabs.buttons["Shelf"])
        XCTAssertTrue(
            app.descendants(matching: .any)["shelf-collection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["shelf-progress"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings tabs"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
