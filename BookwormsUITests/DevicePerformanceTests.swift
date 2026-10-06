import UIKit
import XCTest

/// Repeatable remote input. XCTest command timings are not app response measurements.
@MainActor
final class DevicePerformanceTests: XCTestCase {
    private let viewTitles = ["My Shelf", "Feed", "Compare Shelves", "Book Club"]

    private func focused(_ element: XCUIElement) -> Bool {
        element.hasFocus
            || element.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).count > 0
    }

    /// Moves focus to Book Wall's entry book: the first column's bottom book, which is the
    /// first hit target. Down can enter through **Drop again** and land on another column's top
    /// book, so this moves to the bottom of the column, then Left into the sidebar and Right back.
    private func returnToWallEntry(_ app: XCUIApplication, focusedBook: NSPredicate) {
        for _ in 0..<12 { XCUIRemote.shared.press(.down) }
        for _ in 0..<6 where app.buttons.matching(focusedBook).count > 0 {
            XCUIRemote.shared.press(.left)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCUIRemote.shared.press(.right)
        Thread.sleep(forTimeInterval: 1)
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
        let description = scenario == "description"
        if description {
            // My Shelf opens with focus on its first book; open its details.
            XCTAssertTrue(
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-'"))
                    .allElementsBoundByIndex.contains { focused($0) },
                "The description scenario starts from a focused My Shelf book.")
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 10))
            XCTAssertTrue(
                app.buttons["show-full-description"].waitForExistence(timeout: 5),
                "The first book's description must overflow to show Show more.")
            RemoteNavigation.moveFocus(to: app.buttons["show-full-description"], in: app)
        }
        print("PERFORMANCE_READY")
        // Attach Instruments outside this test before measured input begins.
        Thread.sleep(forTimeInterval: 20)
        let repetitions = environment["PERF_REPETITIONS"] == "1" ? 1 : 3
        if description {
            // Opens and closes the full description; phases carry wall-clock times.
            for cycle in 0..<repetitions {
                print("PERFORMANCE_PHASE open-\(cycle) \(Date().timeIntervalSince1970)")
                XCUIRemote.shared.press(.select)
                Thread.sleep(forTimeInterval: 3)
                print("PERFORMANCE_PHASE close-\(cycle) \(Date().timeIntervalSince1970)")
                XCUIRemote.shared.press(.menu)
                Thread.sleep(forTimeInterval: 3)
            }
            print("PERFORMANCE_PHASE end \(Date().timeIntervalSince1970)")
        }
        for repetition in 0..<(description ? 0 : repetitions) {
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
    /// Launches directly into Book Wall, opens and closes book details three times, then moves
    /// quickly through the stacks. Phase markers carry wall-clock times for aligning the trace.
    func testBookWallProfile() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt-in physical Apple TV Book Wall diagnosis.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        if environment["PERF_DIAGNOSTICS"] == "1" {
            app.launchArguments = ["--performance-diagnostics"]
            // A variant may combine isolations with "+".
            for variant in (environment["PERF_VARIANT"] ?? "").split(separator: "+") {
                app.launchArguments.append("--isolate=\(variant)")
            }
        }
        if let antialiasing = environment["PERF_WALL_ANTIALIASING"], !antialiasing.isEmpty {
            app.launchArguments.append("--wall-antialiasing=\(antialiasing)")
        }
        // Opens Book Wall without the sidebar and adds it there if it was hidden.
        app.launchArguments.append("--start-view=bookWall")
        app.launch()
        let wallBooks = NSPredicate(
            format: "identifier BEGINSWITH 'book-wall-' AND identifier != 'book-wall-replay'")
        XCTAssertTrue(app.buttons.matching(wallBooks).firstMatch.waitForExistence(timeout: 90))
        // Let preparation and the fall finish before measuring.
        Thread.sleep(forTimeInterval: 10)
        // A direct launch leaves focus on the collapsed tab control, where Menu would leave the
        // app. Down enters the wall at its entry book, as it does for a viewer.
        let focusedBook = NSCompoundPredicate(andPredicateWithSubpredicates: [
            wallBooks, NSPredicate(format: "hasFocus == true"),
        ])
        for _ in 0..<3 where app.buttons.matching(focusedBook).count == 0 {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(app.buttons.matching(focusedBook).firstMatch.waitForExistence(timeout: 10))
        func returnToEntry() { returnToWallEntry(app, focusedBook: focusedBook) }
        returnToEntry()
        // The entry book is the first column's bottom spine; each spine reports its own frame.
        let spines = app.buttons.matching(wallBooks).allElementsBoundByIndex
            .map { (id: $0.identifier, frame: $0.frame) }
        let leftColumn = spines.map(\.frame.midX).min() ?? 0
        let entry = spines.filter { abs($0.frame.midX - leftColumn) < 60 }
            .max { $0.frame.midY < $1.frame.midY }?
            .id
        XCTAssertEqual(app.buttons.matching(focusedBook).firstMatch.identifier, entry)
        // Records the starting screen, such as a tab control left over the wall.
        let start = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        start.name = "ready"
        start.lifetime = .keepAlways
        add(start)
        print("PERFORMANCE_READY")
        // Attach Instruments outside this test before measured input begins.
        Thread.sleep(forTimeInterval: 20)
        func phase(_ name: String) {
            print("PERFORMANCE_PHASE \(name) \(Date().timeIntervalSince1970)")
        }
        let remote = XCUIRemote.shared
        // Details come first: Instruments has dropped Display and GPU data later in long
        // recordings, and the open state is the most important measurement.
        for cycle in 0..<3 {
            phase("select-\(cycle)")
            remote.press(.select)
            // Flight, wall fade, text fade, and a little idle motion.
            Thread.sleep(forTimeInterval: 5)
            phase("return-\(cycle)")
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 4)
            // Stay inside the first two columns so the next selection opens a different book.
            remote.press(cycle.isMultiple(of: 2) ? .up : .right)
            Thread.sleep(forTimeInterval: 1.5)
        }
        // The details sequence stops here: a shorter recording loses less data and saves faster.
        if environment["PERF_SEQUENCE"] != "details" {
            // Unmeasured: passes through the sidebar to restore the starting book.
            phase("reposition")
            returnToEntry()
            Thread.sleep(forTimeInterval: 2)
            phase("navigate")
            // Every burst returns to the first column's bottom book, so Left never reaches the
            // sidebar, where Select and Menu would leave the wall or the app.
            let bursts: [(XCUIRemote.Button, Int)] = [
                (.up, 4), (.down, 4), (.right, 2), (.up, 4), (.down, 4), (.left, 2),
                (.up, 4), (.down, 4), (.right, 2), (.up, 4), (.down, 4), (.left, 2),
            ]
            for (direction, count) in bursts {
                for _ in 0..<count {
                    remote.press(direction)
                    Thread.sleep(forTimeInterval: 0.08)
                }
                Thread.sleep(forTimeInterval: 0.6)
            }
            Thread.sleep(forTimeInterval: 2)
            // Play/Pause only records activity on the wall, so this control phase measures XCTest's
            // press overhead at the navigation pace without any focus change.
            phase("control")
            for _ in 0..<24 {
                remote.press(.playPause)
                Thread.sleep(forTimeInterval: 0.08)
            }
            Thread.sleep(forTimeInterval: 2)
            // One focus move every two seconds separates each move's effect on frame pacing.
            phase("slow-navigate")
            for direction in [XCUIRemote.Button.up, .down, .up, .down, .up, .down] {
                remote.press(direction)
                Thread.sleep(forTimeInterval: 2)
            }
        }
        phase("end")
        // Query accessibility only after the measured intervals. Book targets show only on the
        // settled wall with details closed, so they confirm the last return completed.
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book-wall-'"))
                .firstMatch.waitForExistence(timeout: 5))
        print("PERFORMANCE_FINISHED")
        Thread.sleep(forTimeInterval: 10)
    }

    /// Captures screenshots as fast as XCTest allows while a book flies out and while it starts
    /// back, for inspecting transition rendering on the TV. Not a timing measurement.
    func testBookWallTransitionFrames() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt-in physical Apple TV Book Wall capture.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--start-view=bookWall"]
        // Space-separated extra arguments, such as diagnostics isolations.
        app.launchArguments += (ProcessInfo.processInfo.environment["PERF_EXTRA_ARGUMENTS"] ?? "")
            .split(separator: " ").map(String.init)
        app.launch()
        let wallBooks = NSPredicate(
            format: "identifier BEGINSWITH 'book-wall-' AND identifier != 'book-wall-replay'")
        let focusedBook = NSCompoundPredicate(andPredicateWithSubpredicates: [
            wallBooks, NSPredicate(format: "hasFocus == true"),
        ])
        XCTAssertTrue(app.buttons.matching(wallBooks).firstMatch.waitForExistence(timeout: 90))
        Thread.sleep(forTimeInterval: 10)
        for _ in 0..<3 where app.buttons.matching(focusedBook).count == 0 {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(app.buttons.matching(focusedBook).firstMatch.waitForExistence(timeout: 10))
        // An optional title prefix selects the book whose transitions to capture; every cycle
        // then reopens it instead of moving to another book.
        let title = ProcessInfo.processInfo.environment["PERF_BOOK_TITLE"] ?? ""
        if !title.isEmpty {
            let target = app.buttons
                .matching(
                    NSCompoundPredicate(andPredicateWithSubpredicates: [
                        wallBooks, NSPredicate(format: "label BEGINSWITH[c] %@", title),
                    ])
                )
                .firstMatch
            XCTAssertTrue(target.exists, "No wall book titled \(title)")
            returnToWallEntry(app, focusedBook: focusedBook)
            let current = app.buttons.matching(focusedBook).firstMatch
            for _ in 0..<40 where !target.hasFocus {
                guard current.exists else {
                    // Focus left the wall for the header; the stacks lie below it.
                    XCUIRemote.shared.press(.down)
                    Thread.sleep(forTimeInterval: 0.6)
                    continue
                }
                let from = current.frame
                let dx = target.frame.midX - from.midX
                let dy = target.frame.midY - from.midY
                // Spines in one stack differ in width, so stay vertical within a column.
                let sameColumn = abs(dx) < max(from.width, target.frame.width) / 2
                XCUIRemote.shared.press(
                    sameColumn ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left))
                Thread.sleep(forTimeInterval: 0.6)
            }
            XCTAssertTrue(target.hasFocus)
        }
        Thread.sleep(forTimeInterval: 2)
        // With a screen recording, screenshots would only perturb the frames being recorded.
        let recordsVideo = ProcessInfo.processInfo.environment["PERF_CAPTURE"] == "video"
        func burst(_ name: String, seconds: TimeInterval) {
            if recordsVideo {
                Thread.sleep(forTimeInterval: seconds)
                return
            }
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = String(format: "%@-%04d", name, elapsed)
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
        // Video covers three books in different positions; screenshots cover the first.
        for cycle in 0..<(recordsVideo ? 3 : 1) {
            XCUIRemote.shared.press(.select)
            burst("open", seconds: 2.5)
            Thread.sleep(forTimeInterval: 4)
            XCUIRemote.shared.press(.menu)
            burst("return", seconds: 3.5)
            Thread.sleep(forTimeInterval: 2)
            if title.isEmpty {
                XCUIRemote.shared.press(cycle.isMultiple(of: 2) ? .up : .right)
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        // A replay shows the fall and the controls returning.
        let replay = app.buttons["book-wall-replay"]
        if recordsVideo, replay.waitForExistence(timeout: 5) {
            XCUIRemote.shared.press(.up)
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.select)
            Thread.sleep(forTimeInterval: 8)
        }
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
