import XCTest

/// Repeatable remote input. XCTest command timings are not app response measurements.
@MainActor
final class DevicePerformanceTests: XCTestCase {
    private let viewTitles = ["My Shelf", "Following", "Compare Shelves", "Book Club"]

    private func focused(_ element: XCUIElement) -> Bool {
        element.hasFocus
            || element.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).count > 0
    }

    func testMenuProfile() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VERIFY_DEVICE_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt-in physical Apple TV performance diagnosis.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        if environment["PERF_DIAGNOSTICS"] == "1" {
            app.launchArguments = ["--performance-diagnostics"]
            if let variant = environment["PERF_VARIANT"], !variant.isEmpty {
                app.launchArguments.append("--isolate=\(variant)")
            }
        }
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
                .firstMatch.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: 5)
        if let index = environment["PERF_VIEW"].flatMap(Int.init),
            viewTitles.indices.contains(index),
            index > 0
        {
            RemoteNavigation.selectView(viewTitles[index], in: app)
            Thread.sleep(forTimeInterval: 0.5)
        }
        let scenario = environment["PERF_SCENARIO"] ?? "sidebar"
        let settings = scenario == "settings"
        let sidebar = scenario == "sidebar"
        if sidebar { RemoteNavigation.focusSidebarItem(viewTitles[0], in: app) }
        if settings {
            RemoteNavigation.openSettings(app)
            for _ in 0..<6 { XCUIRemote.shared.press(.up) }
            for _ in 0..<6 { XCUIRemote.shared.press(.left) }
        }
        print("PERFORMANCE_READY")
        // Attach Instruments outside this test before measured input begins.
        Thread.sleep(forTimeInterval: 20)
        let repetitions = environment["PERF_REPETITIONS"] == "1" ? 1 : 3
        for repetition in 0..<repetitions {
            print("PERFORMANCE_RUN_\(repetition)")
            for index in 0..<40 {
                let forward = (index / (settings ? 5 : 4)).isMultiple(of: 2)
                let direction: XCUIRemote.Button =
                    sidebar ? (forward ? .down : .up) : (forward ? .right : .left)
                XCUIRemote.shared.press(direction)
                Thread.sleep(forTimeInterval: index < 20 ? 0.5 : 0.08)
            }
            Thread.sleep(forTimeInterval: 2)
        }
        // Query accessibility only after the measured intervals.
        if settings {
            RemoteNavigation.showShelf(app)
            XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 10))
        } else if scenario == "books" {
            XCTAssertTrue(
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
                    .allElementsBoundByIndex.contains { focused($0) })
        }
        print("PERFORMANCE_FINISHED")
        Thread.sleep(forTimeInterval: 45)
    }
    func testLongSessionProfile() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt-in 20-minute navigation and 45-minute ambient investigation.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--performance-diagnostics"]
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
                .firstMatch.waitForExistence(timeout: 60))
        print("PERFORMANCE_READY")
        Thread.sleep(forTimeInterval: 20)
        let end = Date().addingTimeInterval(20 * 60)
        var cycle = 0
        while Date() < end {
            RemoteNavigation.openSettings(app)
            RemoteNavigation.showShelf(app)
            for _ in 0..<4 { XCUIRemote.shared.press(.right) }
            for _ in 0..<4 { XCUIRemote.shared.press(.left) }
            cycle += 1
            print("LONG_SESSION_CYCLE_\(cycle)")
            Thread.sleep(forTimeInterval: 15)
        }
        print("PERFORMANCE_WARM_MENU")
        for index in 0..<40 {
            XCUIRemote.shared.press((index / 4).isMultiple(of: 2) ? .right : .left)
            Thread.sleep(forTimeInterval: 0.2)
        }
        RemoteNavigation.startAmbient(app)
        print("PERFORMANCE_AMBIENT_STARTED")
        for minute in 1...45 {
            Thread.sleep(forTimeInterval: 60)
            print("AMBIENT_MINUTE_\(minute)")
        }
        XCUIRemote.shared.press(.down)
        XCTAssertFalse(app.buttons["stop-ambient"].exists)
        RemoteNavigation.showShelf(app)
        for index in 0..<40 {
            XCUIRemote.shared.press((index / 4).isMultiple(of: 2) ? .right : .left)
            Thread.sleep(forTimeInterval: 0.2)
        }
        print("PERFORMANCE_FINISHED")
        Thread.sleep(forTimeInterval: 45)
    }

}
