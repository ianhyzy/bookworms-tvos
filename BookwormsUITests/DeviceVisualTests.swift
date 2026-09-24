import XCTest

@MainActor
final class DeviceVisualTests: XCTestCase {
    func testRealShelfBackwardPagingAndSidebarReturn() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Uses the authorized library on the physical Apple TV.")
        #else
            // Supply current boundary IDs instead of repeatedly fetching every frame over the network.
            let environment = ProcessInfo.processInfo.environment
            guard let lastID = environment["SHELF_LAST_BOOK_ID"],
                let nextID = environment["SHELF_NEXT_BOOK_ID"]
            else {
                throw XCTSkip("Requires the current shelf boundary IDs.")
            }
            let app = XCUIApplication()
            app.launchArguments = ["--start-shelf-page=1"]
            app.launch()
            let last = app.buttons["book-\(lastID)"]
            let next = app.buttons["book-\(nextID)"]
            XCTAssertTrue(next.waitForExistence(timeout: 30))
            XCTAssertTrue(next.hasFocus)
            for _ in 0..<2 {
                XCUIRemote.shared.press(.left)
                XCTAssertTrue(last.waitForExistence(timeout: 10))
                print("Arrival focus diagnostics:", last.value ?? "unavailable")
                let arrived = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "hasFocus == true"), object: last)
                XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 10), .completed)
                Thread.sleep(forTimeInterval: 1)
                XCTAssertTrue(last.hasFocus)
                XCUIRemote.shared.press(.right)
                XCTAssertTrue(next.waitForExistence(timeout: 10))
                XCTAssertTrue(next.hasFocus)
            }
            XCUIRemote.shared.press(.left)
            XCTAssertTrue(last.waitForExistence(timeout: 10))
            XCTAssertTrue(last.hasFocus)
            let shelf = XCTAttachment(screenshot: app.screenshot())
            shelf.name = "Real shelf with optical typography and backward focus"
            shelf.lifetime = .keepAlways
            add(shelf)
            RemoteNavigation.focusSidebarItem("My Shelf", in: app)
            XCUIRemote.shared.press(.right)
            let returned = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasFocus == true"), object: last)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        #endif
    }

    func testBrowseAndInspectHouseOfLeaves() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_DEVICE_VISUALS"] == "1" else {
            throw XCTSkip("Requires the authorized library on the physical Apple TV.")
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "book-"))
                .firstMatch.waitForExistence(timeout: 60))
        // Leave time to attach Instruments before this repeatable interaction sequence.
        Thread.sleep(forTimeInterval: 40)
        for _ in 0..<2 {
            for _ in 0..<8 { XCUIRemote.shared.press(.right) }
            for _ in 0..<8 { XCUIRemote.shared.press(.left) }
        }
        let house = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "House of Leaves, by ")).firstMatch
        XCTAssertTrue(house.exists)
        for _ in 0..<18 {
            if house.hasFocus { break }
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(house.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["detail-title"].label, "House of Leaves")
        XCTAssertTrue(app.images["detail-cover"].waitForExistence(timeout: 35))
        let cover = XCTAttachment(screenshot: app.screenshot())
        cover.name = "House of Leaves detail"
        cover.lifetime = .keepAlways
        add(cover)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.menu)
        let restored = NSPredicate(format: "hasFocus == true")
        expectation(for: restored, evaluatedWith: house)
        waitForExpectations(timeout: 5)
        let shelf = XCTAttachment(screenshot: app.screenshot())
        shelf.name = "Release shelf"
        shelf.lifetime = .keepAlways
        add(shelf)
    }
}
