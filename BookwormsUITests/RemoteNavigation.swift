import XCTest

/// Remote-navigation helpers that enforce the rules in `docs/FOCUS_NAVIGATION.md`.
///
/// Launch with `--focus-probe` so the app exposes its native focus-update count. Checking only the
/// final focused element cannot detect a bounce, because a bounce ends on a plausible element.
/// `press(_:in:expecting:)` also requires that the press produced exactly one focus update.
@MainActor
enum RemoteNavigation {
    /// How long a press must stay settled before the test accepts it. A bounce from app code runs
    /// within a few frames of the first update, so this window observes it without polling for a
    /// passing state.
    static let settleWindow: TimeInterval = 1

    static func launch(
        view: String? = nil, arguments: [String] = [], resetSettings: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            (resetSettings ? ["--reset-test-settings"] : []) + [
                "--sample-library", "--focus-probe",
            ]
            + arguments + (view.map { ["--start-view=\($0)"] } ?? [])
        app.launch()
        return app
    }

    /// Launches on My Shelf and opens the view titled `title` from the sidebar, as a user does.
    ///
    /// Prefer this to `launch(view:)` for views that users reach only through the sidebar, so
    /// tests cover the same entry path.
    static func open(
        _ title: String, arguments: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIApplication {
        let app = launch(arguments: arguments)
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15), file: file, line: line)
        selectView(title, in: app, file: file, line: line)
        return app
    }

    /// The number of native focus updates since launch, or `nil` without `--focus-probe`.
    static func transitions(_ app: XCUIApplication) -> Int? {
        let probe = app.descendants(matching: .any)["focus-transition-probe"]
        guard probe.exists else { return nil }
        return (probe.value as? String).flatMap(Int.init)
    }

    /// The focused element whose identifier starts with `prefix`, if any.
    static func focused(_ app: XCUIApplication, prefix: String) -> XCUIElement? {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND hasFocus == true", prefix))
            .firstMatch
        return match.exists ? match : nil
    }

    static func waitForFocus(
        _ element: XCUIElement, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in isFocused(element) }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [focused], timeout: timeout), .completed,
            "Expected focus on \(element.identifier)", file: file, line: line)
    }

    /// Presses `direction` and requires one focus update that lands on `expected` and stays there.
    static func press(
        _ direction: XCUIRemote.Button, in app: XCUIApplication, expecting expected: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let before = transitions(app)
        XCUIRemote.shared.press(direction)
        waitForFocus(expected, file: file, line: line)
        assertSettled(app, after: before, expectedUpdates: 1, file: file, line: line)
        XCTAssertTrue(
            isFocused(expected), "Focus left \(expected.identifier) without input",
            file: file, line: line)
    }

    /// Presses `direction` where no focusable item exists and requires that focus does not move.
    static func pressWithoutMoving(
        _ direction: XCUIRemote.Button, in app: XCUIApplication, from current: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let before = transitions(app)
        XCUIRemote.shared.press(direction)
        assertSettled(app, after: before, expectedUpdates: 0, file: file, line: line)
        XCTAssertTrue(isFocused(current), file: file, line: line)
    }

    private static func assertSettled(
        _ app: XCUIApplication, after before: Int?, expectedUpdates: Int,
        file: StaticString, line: UInt
    ) {
        guard let before else {
            XCTFail("Launch with --focus-probe to count focus updates", file: file, line: line)
            return
        }
        // Observe the whole window so a late second update is counted.
        _ = XCTWaiter.wait(
            for: [XCTestExpectation(description: "Focus settles")], timeout: settleWindow)
        XCTAssertEqual(
            transitions(app), before + expectedUpdates,
            "One remote press must produce \(expectedUpdates) focus update(s). More means app code moved focus after the focus engine.",
            file: file, line: line)
    }

    /// The buttons whose identifiers start with `prefix` and lie fully on screen, left to right.
    static func visibleButtons(
        _ app: XCUIApplication, prefix: String, in container: XCUIElement? = nil
    ) -> [XCUIElement] {
        let root = container ?? app
        var seen = Set<String>()
        return root.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
            .filter { $0.frame.minX >= app.frame.minX && $0.frame.maxX <= app.frame.maxX }
            .filter { seen.insert($0.identifier).inserted }
            .sorted { $0.frame.minX < $1.frame.minX }
            // Rebind by identifier: index-bound elements shift when buttons such as review actions
            // appear or disappear.
            .map { root.buttons[$0.identifier] }
    }

    /// Moves focus to the sidebar with Menu, then to the item titled `name`, such as `My Shelf`,
    /// `Ambient`, or `Settings`.
    static func focusSidebarItem(
        _ name: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        // Menu from the sidebar leaves the app, so press it only when focus is in content.
        if !sidebarItems.contains(where: { hasFocus(labeled: $0, in: app) }) {
            XCUIRemote.shared.press(.menu)
        }
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<8 where !hasFocus(labeled: name, in: app) {
                XCUIRemote.shared.press(direction)
            }
        }
        XCTAssertTrue(
            hasFocus(labeled: name, in: app), "Sidebar item unreachable: \(name)",
            file: file, line: line)
    }

    private static let sidebarItems = [
        "My Shelf", "Following", "Compare Shelves", "Book Club", "Ambient", "Settings",
    ]

    /// Opens the view named `title` from the sidebar and enters its content.
    ///
    /// Selecting can leave the sidebar open, for example while the view prepares its rows. A user
    /// then presses Right, so this does too, a few times at most.
    static func selectView(
        _ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        focusSidebarItem(title, in: app, file: file, line: line)
        XCUIRemote.shared.press(.select)
        for _ in 0..<3 {
            let left = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !hasFocus(labeled: title, in: app) }, object: nil)
            if XCTWaiter.wait(for: [left], timeout: 2) == .completed { return }
            XCUIRemote.shared.press(.right)
        }
        XCTFail("Focus stayed in the sidebar after selecting \(title)", file: file, line: line)
    }

    /// Moves focus to `element` by pressing toward it from the focused element, as a user would.
    /// Use it in layouts with columns, where Down alone can land in the other column.
    static func moveFocus(
        to element: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<12 where !isFocused(element) {
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex.last
            guard let from = focused?.frame, element.exists else {
                XCUIRemote.shared.press(.down)
                continue
            }
            let to = element.frame
            // Left or Right in the Settings section bar would switch sections, so leave it first.
            let bar = app.descendants(matching: .any)["settings-sections"]
            let inBar = bar.exists && bar.frame.contains(CGPoint(x: from.midX, y: from.midY))
            // Change columns first; moving vertically in the wrong column can miss the target.
            let direction: XCUIRemote.Button =
                inBar
                ? .down
                : to.maxX <= from.minX
                    ? .left
                    : to.minX >= from.maxX
                        ? .right : to.midY > from.midY ? .down : .up
            XCUIRemote.shared.press(direction)
        }
        waitForFocus(element, file: file, line: line)
    }

    /// Opens the Settings sidebar item and, when `section` is set, selects that section segment.
    static func openSettings(
        _ app: XCUIApplication, section: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        selectView("Settings", in: app, file: file, line: line)
        let sections = app.descendants(matching: .any)["settings-sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5), file: file, line: line)
        guard let section else { return }
        let button = sections.buttons[section]
        for _ in 0..<6 where !isFocused(button) {
            let inBar =
                sections.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).count > 0
            XCUIRemote.shared.press(inBar ? .left : .up)
        }
        for _ in 0..<6 where !isFocused(button) { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(
            isFocused(button), "Settings section unreachable: \(section)", file: file, line: line)
        XCUIRemote.shared.press(.select)
    }

    /// Chooses `name` with the reader picker in the Compare Shelves or Book Club header.
    static func chooseReader(
        _ name: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let picker = app.buttons["reader-picker-menu"]
        XCTAssertTrue(picker.waitForExistence(timeout: 30), file: file, line: line)
        for _ in 0..<3 where !isFocused(picker) { XCUIRemote.shared.press(.up) }
        for _ in 0..<2 where !isFocused(picker) { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(isFocused(picker), "Reader picker unreachable", file: file, line: line)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)[name].firstMatch.waitForExistence(timeout: 30),
            file: file, line: line)
        for _ in 0..<12 where !hasFocus(labeled: name, in: app) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(
            hasFocus(labeled: name, in: app), "Reader unreachable: \(name)", file: file, line: line)
        XCUIRemote.shared.press(.select)
        let chosen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", name), object: picker)
        XCTAssertEqual(
            XCTWaiter.wait(for: [chosen], timeout: 10), .completed, file: file, line: line)
    }

    /// Leaves Settings or Ambient for My Shelf.
    static func showShelf(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        selectView("My Shelf", in: app, file: file, line: line)
    }

    /// Opens the Ambient sidebar item and starts playback with its **Start** button.
    static func startAmbient(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        selectView("Ambient", in: app, file: file, line: line)
        let start = app.buttons["start-ambient"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), file: file, line: line)
        // Start sits below the interval and session pickers.
        if hasFocus(labeled: "Ambient", in: app) { XCUIRemote.shared.press(.right) }
        for _ in 0..<4 where !isFocused(start) { XCUIRemote.shared.press(.down) }
        waitForFocus(start, file: file, line: line)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["stop-ambient"].waitForExistence(timeout: 10), file: file, line: line)
    }

    /// Whether the focused element is labeled `name` or contains an element labeled `name`.
    ///
    /// Sidebar rows and menu items report focus on a container, while a query by name can match a
    /// different element with the same label, such as the Settings tab's `gearshape` button.
    static func hasFocus(labeled name: String, in app: XCUIApplication) -> Bool {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
        let label = NSPredicate(format: "label == %@", name)
        return focused.matching(label).count > 0 || focused.containing(label).count > 0
    }

    /// Whether `element`, one of its descendants, or a focused container of it has focus. Menus
    /// report focus on a container rather than on the identified button.
    static func isFocused(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let focus = NSPredicate(format: "hasFocus == true")
        if element.hasFocus || element.descendants(matching: .any).matching(focus).count > 0 {
            return true
        }
        // Elements found by label have no identifier; match them by label instead.
        let key =
            element.identifier.isEmpty
            ? NSPredicate(format: "label == %@", element.label)
            : NSPredicate(format: "identifier == %@", element.identifier)
        return XCUIApplication().descendants(matching: .any).matching(focus).containing(key).count
            > 0
    }
}
