import CoreFoundation
import XCTest

/// Exercises real startup, persistence, image decoding, and remote navigation with fixture transport.
@MainActor
final class ScenarioNavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(
        _ scenario: String = "artwork", appearance: String = "dark", preserve: Bool = false,
        settingsTab: String = "Shelf"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOOKWORMS_SCENARIO_CONTROL"] = UUID().uuidString
        app.launchArguments = [
            "--test-scenario=\(scenario)", "--settings-tab=\(settingsTab)",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["TZ"] = "UTC"
        if preserve {
            app.launchArguments.append("--preserve-test-scenario")
        } else {
            app.launchArguments.append("--test-appearance=\(appearance)")
        }
        app.launch()
        return app
    }

    private func waitForFocus(
        _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        RemoteNavigation.waitForFocus(element, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func probe(_ app: XCUIApplication) throws -> [String: Any] {
        let element = app.staticTexts["scenario-probe"].firstMatch
        let previous = element.exists ? element.label : ""
        command("probe", app: app)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.label != previous },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(element.label.utf8)) as? [String: Any])
        let network = try XCTUnwrap(evidence["network"] as? [String: Any])
        XCTAssertEqual(
            network["unexpected"] as? Int, 0,
            "A scenario attempted an unconfigured network request.")
        XCTAssertEqual(
            evidence["sample"] as? Bool, false, "Scenarios must exercise normal startup.")
        XCTAssertEqual(evidence["generating"] as? Bool, false)
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(
                withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name =
            "scenario-\(evidence["scenario"] ?? "unknown")-evidence-\(evidence["revision"] ?? 0)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return evidence
    }

    private func command(_ command: String, app: XCUIApplication) {
        let channel = app.launchEnvironment["BOOKWORMS_SCENARIO_CONTROL"]!
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(
                rawValue: "gay.ian.Bookworms.scenario.\(channel).\(command)" as CFString),
            nil, nil, true)
    }

    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: [
            .contrast, .textClipped, .sufficientElementDescription, .trait,
        ]) { issue in
            // The one-pixel diagnostic probe is test instrumentation, not product content.
            issue.element?.identifier == "scenario-probe"
        }
    }

    private func waitForProbe(
        _ app: XCUIApplication, matching condition: ([String: Any]) -> Bool
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let evidence = try probe(app)
            if condition(evidence) { return evidence }
        } while Date() < deadline
        XCTFail("The scenario did not reach the required state before the timeout.")
        return try probe(app)
    }

    private func openSettings(_ app: XCUIApplication) {
        RemoteNavigation.openSettings(app)
    }

    private func moveFocus(to element: XCUIElement) {
        RemoteNavigation.moveFocus(to: element, in: XCUIApplication())
    }

    /// Audits the shelf in both appearances; the detail pass runs once, in dark, because
    /// `testAppearanceChangesAndPersistsAcrossRelaunch` already covers switching appearance.
    func testArtworkShapesDetailsAndShelfAccessibilityInBothAppearances() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let first = app.buttons["book-1"]
            XCTAssertTrue(first.waitForExistence(timeout: 20))
            waitForFocus(first)
            let initial = try probe(app)
            XCTAssertEqual(initial["sourceCalls"] as? Int, 1)
            let network = try XCTUnwrap(initial["network"] as? [String: Any])
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(network["deliveredArtwork"] as? Int), 5)
            capture(app, "scenario-artwork-shelf-\(appearance)")
            try audit(app)
            guard appearance == "dark" else {
                app.terminate()
                continue
            }
            for id in 1...6 {
                let book = app.buttons["book-\(id)"]
                XCTAssertTrue(book.waitForExistence(timeout: 5))
                waitForFocus(book)
                XCTAssertGreaterThan(book.frame.width, 0)
                XCTAssertLessThanOrEqual(book.frame.maxX, app.frame.maxX)
                XCUIRemote.shared.press(.select)
                XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
                if id == 4 || id == 5 {
                    XCTAssertTrue(app.staticTexts["Cover unavailable"].waitForExistence(timeout: 5))
                } else {
                    XCTAssertTrue(app.images["detail-cover"].waitForExistence(timeout: 5))
                }
                capture(app, "scenario-artwork-detail-\(id)")
                if id == 1 || id == 4 { try audit(app) }
                XCUIRemote.shared.press(.menu)
                XCTAssertTrue(book.waitForExistence(timeout: 5))
                waitForFocus(book)
                if id < 6 { XCUIRemote.shared.press(.right) }
            }
            let final = try probe(app)
            XCTAssertEqual(final["sourceCalls"] as? Int, initial["sourceCalls"] as? Int)
            XCTAssertEqual(
                (final["network"] as? [String: Any])?["requests"] as? Int,
                network["requests"] as? Int, "Details and remote browsing use prepared artwork.")
            app.terminate()
        }
    }

    func testHeldArtworkCompletesAfterSettingsAndPreservesNavigation() throws {
        let app = launch("delayed-artwork")
        XCTAssertTrue(app.staticTexts["Loading view…"].waitForExistence(timeout: 15))
        let pending = try waitForProbe(app) {
            ($0["network"] as? [String: Any])?["heldArtwork"] as? Int == 1
        }
        XCTAssertEqual((pending["network"] as? [String: Any])?["heldArtwork"] as? Int, 1)
        XCTAssertFalse(app.buttons["book-1"].exists)
        openSettings(app)
        XCTAssertTrue(app.staticTexts["book-limit"].exists)
        capture(app, "scenario-held-artwork-settings")
        command("release-artwork", app: app)
        let ready = try waitForProbe(app) {
            let shelf = $0["shelf"] as? [String: Any]
            return shelf?["artworkReady"] as? Bool == true && shelf?["pagesReady"] as? Bool == true
        }
        XCTAssertEqual((ready["shelf"] as? [String: Any])?["artworkReady"] as? Bool, true)
        XCTAssertTrue(
            app.staticTexts["book-limit"].exists, "Artwork completion must not leave Settings")
        RemoteNavigation.showShelf(app)
        let first = app.buttons["book-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        try probe(app)
        waitForFocus(first)
        RemoteNavigation.focusSidebarItem("My Shelf", in: app)
        XCUIRemote.shared.press(.right)
        waitForFocus(first)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.images["detail-cover"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        waitForFocus(first)
        let completed = try probe(app)
        XCTAssertEqual((completed["network"] as? [String: Any])?["heldArtwork"] as? Int, 0)
        XCTAssertEqual(completed["sourceCalls"] as? Int, 1)
        for _ in 1...5 { XCUIRemote.shared.press(.right) }
        waitForFocus(app.buttons["book-6"])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.images["detail-cover"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail-title"].label, "The Last Observatory")
        capture(app, "scenario-delayed-artwork-detail")
        XCUIRemote.shared.press(.menu)
        try probe(app)
        capture(app, "scenario-released-artwork-shelf")
    }

    func testSettingsReverseVisibleBooksAndPersistAcrossRelaunch() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
        openSettings(app)
        moveFocus(to: app.buttons["shelf-sort"])
        XCUIRemote.shared.press(.right)
        let reverse = app.descendants(matching: .any)["Reverse order"].firstMatch
        XCTAssertTrue(
            reverse.hasFocus
                || reverse.descendants(matching: .any)
                    .matching(NSPredicate(format: "hasFocus == true")).count > 0
        )
        XCUIRemote.shared.press(.select)
        capture(app, "scenario-settings-reversed")
        try audit(app)
        RemoteNavigation.showShelf(app)
        let changed = try probe(app)
        XCTAssertEqual(changed["bookIDs"] as? [Int], Array((1...8).reversed()))
        app.terminate()
        let restored = launch(preserve: true)
        let last = restored.buttons["book-8"]
        XCTAssertTrue(last.waitForExistence(timeout: 20))
        waitForFocus(last)
        XCTAssertEqual(try probe(restored)["bookIDs"] as? [Int], Array((1...8).reversed()))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(restored.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(restored.staticTexts["detail-title"].label, "Winter in the Orchard")
        capture(restored, "scenario-reversed-visible-detail")
        XCUIRemote.shared.press(.menu)
        try probe(restored)
    }

    func testOfflinePartialFailureAndEmptyErrorStates() throws {
        for scenario in ["offline", "partial", "empty", "error"] {
            let app = launch(scenario, settingsTab: "Sources")
            if scenario == "offline" || scenario == "partial" {
                XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
            } else {
                XCTAssertTrue(app.buttons["choose-sources"].waitForExistence(timeout: 20))
                XCTAssertFalse(app.buttons["book-1"].exists)
            }
            let evidence = try waitForProbe(app) {
                $0["loading"] as? Bool == false
                    && $0["sourceCalls"] as? Int == (scenario == "partial" ? 2 : 1)
            }
            XCTAssertEqual(evidence["sourceCalls"] as? Int, scenario == "partial" ? 2 : 1)
            if scenario == "offline" {
                XCTAssertEqual(
                    (evidence["network"] as? [String: Any])?["deliveredArtwork"] as? Int, 0)
            }
            capture(app, "scenario-\(scenario)-shelf")
            try audit(app)
            // The partial scenario's error belongs to CWA, whose Settings status is hidden while
            // `BookPresentation.offersCWA` is false. Check it again when CWA returns.
            if scenario != "empty" && scenario != "partial" {
                openSettings(app)
                let error: String
                switch scenario {
                case "offline":
                    error =
                        "The network connection is unavailable. Check Apple TV's connection and try again."
                case "partial":
                    error = "CWA rejected the login. Use a local CWA account with OPDS access."
                default:
                    error =
                        "The Hardcover login is invalid or expired. Reconnect in Settings."
                }
                XCTAssertTrue(app.staticTexts[error].waitForExistence(timeout: 5))
                capture(app, "scenario-\(scenario)-sources-error")
                try audit(app)
                RemoteNavigation.showShelf(app)
                try probe(app)
            }
            app.terminate()
        }
    }

    func testAppearanceChangesAndPersistsAcrossRelaunch() throws {
        let app = launch(appearance: "dark", settingsTab: "General")
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
        openSettings(app)
        let picker = app.descendants(matching: .any)["appearance-picker"].firstMatch
        moveFocus(to: picker)
        for _ in 0..<3 {
            if app.buttons["System"].hasFocus { break }
            XCUIRemote.shared.press(.left)
        }
        XCUIRemote.shared.press(.right)
        waitForFocus(app.buttons["Light"])
        XCUIRemote.shared.press(.select)
        RemoteNavigation.showShelf(app)
        XCTAssertEqual(try probe(app)["appearance"] as? String, "light")
        capture(app, "scenario-appearance-changed-light")
        app.terminate()
        let restored = launch(preserve: true)
        XCTAssertTrue(restored.buttons["book-1"].waitForExistence(timeout: 20))
        XCTAssertEqual(try probe(restored)["appearance"] as? String, "light")
        capture(restored, "scenario-appearance-restored-light")
    }

    func testSourceEnablementChangesVisibleShelfWithoutSyncAndPersists() throws {
        let app = launch(settingsTab: "Sources")
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
        openSettings(app)
        moveFocus(to: app.descendants(matching: .any)["Hardcover"].firstMatch)
        XCUIRemote.shared.press(.select)
        RemoteNavigation.showShelf(app)
        XCTAssertTrue(app.buttons["choose-sources"].waitForExistence(timeout: 5))
        let disabled = try probe(app)
        XCTAssertEqual(disabled["bookIDs"] as? [Int], [])
        XCTAssertEqual(disabled["sourceCalls"] as? Int, 1)
        app.terminate()
        let restored = launch(preserve: true, settingsTab: "Sources")
        XCTAssertTrue(restored.buttons["choose-sources"].waitForExistence(timeout: 20))
        XCTAssertEqual(try probe(restored)["sourceCalls"] as? Int, 0)
        openSettings(restored)
        moveFocus(to: restored.descendants(matching: .any)["Hardcover"].firstMatch)
        XCUIRemote.shared.press(.select)
        RemoteNavigation.showShelf(restored)
        XCTAssertTrue(restored.buttons["book-1"].waitForExistence(timeout: 10))
        let enabled = try probe(restored)
        XCTAssertEqual(enabled["bookIDs"] as? [Int], Array(1...8))
        XCTAssertEqual(enabled["sourceCalls"] as? Int, 0)
        capture(restored, "scenario-reenabled-cached-shelf")
    }

    func testAmbientClockAndForegroundStayQuietAndRestoreIdleTimer() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 20))
        let before = try probe(app)
        RemoteNavigation.startAmbient(app)
        capture(app, "scenario-artwork-ambient")
        command("advance-clock", app: app)
        let advanced = try waitForProbe(app) { $0["ambientIndex"] as? Int == 1 }
        XCTAssertEqual(advanced["ambient"] as? Bool, true)
        XCTAssertEqual(advanced["idleTimerDisabled"] as? Bool, true)
        XCUIRemote.shared.press(.select)
        waitForFocus(app.buttons["start-ambient"])
        XCTAssertFalse(app.staticTexts["detail-title"].exists)
        let stopped = try probe(app)
        XCTAssertEqual(stopped["ambient"] as? Bool, false)
        XCTAssertEqual(stopped["idleTimerDisabled"] as? Bool, false)
        XCTAssertEqual(stopped["ambientIndex"] as? Int, 1)
        RemoteNavigation.startAmbient(app)
        XCTAssertEqual(try probe(app)["idleTimerDisabled"] as? Bool, true)
        XCUIRemote.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["start-ambient"].waitForExistence(timeout: 10))
        let resumed = try probe(app)
        XCTAssertEqual(resumed["ambient"] as? Bool, false)
        XCTAssertEqual(resumed["idleTimerDisabled"] as? Bool, false)
        XCTAssertEqual(resumed["sourceCalls"] as? Int, before["sourceCalls"] as? Int)
        XCTAssertEqual(resumed["cloudCalls"] as? Int, 0)
        XCTAssertEqual(
            (resumed["network"] as? [String: Any])?["requests"] as? Int,
            (before["network"] as? [String: Any])?["requests"] as? Int)
    }
}
