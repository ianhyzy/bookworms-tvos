import XCTest

/// Checks that social views follow the focus rules in `docs/FOCUS_NAVIGATION.md`: every press moves
/// focus once, directly to the expected item.
@MainActor
final class SocialNavigationTests: XCTestCase {
    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func sharedCovers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH 'shared-' AND NOT identifier BEGINSWITH 'shared-review-'"
            ))
    }

    func testSidebarSwitchesViewsAndEntersContent() {
        continueAfterFailure = false
        let app = RemoteNavigation.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        let destinations = [
            ("Following", "activity-"), ("Compare Shelves", "book-"), ("Book Club", "shared-"),
            ("My Shelf", "book-"),
        ]
        for (title, prefix) in destinations {
            RemoteNavigation.selectView(title, in: app)
            let content = app.descendants(matching: .any)
                .matching(
                    NSPredicate(format: "identifier BEGINSWITH %@ AND hasFocus == true", prefix)
                )
                .firstMatch
            XCTAssertTrue(
                content.waitForExistence(timeout: 5),
                "Selecting \(title) must move focus into its content")
        }
    }

    func testFollowingCardsAndReviewButtonsMoveDirectly() throws {
        let app = RemoteNavigation.launch(view: "following")
        let first = app.buttons["activity-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        let cards = (1...4).map { app.buttons["activity-\($0)"] }
        for card in cards {
            XCTAssertTrue(card.exists)
            XCTAssertGreaterThanOrEqual(card.frame.minX, 0)
            XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.maxX)
        }
        for (left, right) in zip(cards, cards.dropFirst()) {
            XCTAssertLessThan(left.frame.maxX, right.frame.minX)
        }
        // The first card is focused and lifted; the others share a top edge.
        for (left, right) in zip(cards.dropFirst(), cards.dropFirst(2)) {
            XCTAssertEqual(left.frame.minY, right.frame.minY, accuracy: 30)
        }
        capture(app, name: "Following")
        try app.performAccessibilityAudit(for: [
            .contrast, .textClipped, .sufficientElementDescription, .trait,
        ])
        RemoteNavigation.press(.right, in: app, expecting: cards[1])
        RemoteNavigation.press(.left, in: app, expecting: first)
        let review = app.buttons["activity-review-1"]
        RemoteNavigation.press(.down, in: app, expecting: review)
        RemoteNavigation.press(.up, in: app, expecting: first)
        RemoteNavigation.press(.right, in: app, expecting: cards[1])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail-title"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        RemoteNavigation.waitForFocus(cards[1])
    }

    func testComparisonDownAndUpKeepColumn() {
        continueAfterFailure = false
        let app = RemoteNavigation.open("Compare Shelves", arguments: ["--sample-pages"])
        let upper = app.otherElements["comparison-upper"]
        let lower = app.otherElements["comparison-lower"]
        XCTAssertTrue(upper.waitForExistence(timeout: 15))
        let upperBooks = RemoteNavigation.visibleButtons(app, prefix: "book-", in: upper)
        let lowerBooks = RemoteNavigation.visibleButtons(app, prefix: "book-", in: lower)
        XCTAssertGreaterThanOrEqual(upperBooks.count, 3)
        XCTAssertFalse(lowerBooks.isEmpty)
        RemoteNavigation.waitForFocus(upperBooks[0])
        RemoteNavigation.press(.right, in: app, expecting: upperBooks[1])
        RemoteNavigation.press(.right, in: app, expecting: upperBooks[2])
        let lowerTarget = lowerBooks[min(2, lowerBooks.count - 1)]
        RemoteNavigation.press(.down, in: app, expecting: lowerTarget)
        RemoteNavigation.press(.up, in: app, expecting: upperBooks[2])
        XCTAssertTrue(
            app.descendants(matching: .any)["comparison-ratings"].firstMatch.exists,
            "The caption shows both readers' ratings")
        capture(app, name: "Compare Shelves column")
    }

    func testComparisonRowsPageIndependently() {
        continueAfterFailure = false
        let app = RemoteNavigation.open("Compare Shelves", arguments: ["--sample-pages"])
        let upper = app.otherElements["comparison-upper"]
        let lower = app.otherElements["comparison-lower"]
        XCTAssertTrue(upper.waitForExistence(timeout: 15))
        let upperBooks = RemoteNavigation.visibleButtons(app, prefix: "book-", in: upper)
        let lowerBefore = RemoteNavigation.visibleButtons(app, prefix: "book-", in: lower)
            .map(\.identifier)
        RemoteNavigation.waitForFocus(upperBooks[0])
        for book in upperBooks.dropFirst() {
            RemoteNavigation.press(.right, in: app, expecting: book)
        }
        guard let last = upperBooks.last else { return XCTFail("Expected upper books") }
        let before = RemoteNavigation.transitions(app)
        XCUIRemote.shared.press(.right)
        let pageEntry = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == false"), object: last)
        XCTAssertEqual(XCTWaiter.wait(for: [pageEntry], timeout: 5), .completed)
        guard let entered = RemoteNavigation.focused(app, prefix: "book-") else {
            return XCTFail("Right from the last book must reach the next page")
        }
        let enteredID = entered.identifier
        RemoteNavigation.waitForFocus(upper.buttons[enteredID])
        XCTAssertEqual(RemoteNavigation.transitions(app), before.map { $0 + 1 })
        XCTAssertEqual(
            RemoteNavigation.visibleButtons(app, prefix: "book-", in: lower).map(\.identifier),
            lowerBefore, "Paging one row must not page the other")
        RemoteNavigation.press(.left, in: app, expecting: last)
    }

    func testComparisonUpReachesNearestHeaderControlDirectly() {
        continueAfterFailure = false
        let app = RemoteNavigation.open("Compare Shelves")
        let upper = app.otherElements["comparison-upper"]
        XCTAssertTrue(upper.waitForExistence(timeout: 15))
        let books = RemoteNavigation.visibleButtons(app, prefix: "book-", in: upper)
        guard let first = books.first, let last = books.last else {
            return XCTFail("Expected upper books")
        }
        RemoteNavigation.waitForFocus(first)
        let order = app.buttons["comparison-order-options"]
        let picker = app.buttons["reader-picker-menu"]
        XCTAssertLessThan(order.frame.midX, picker.frame.midX)
        RemoteNavigation.press(.up, in: app, expecting: order)
        RemoteNavigation.press(.down, in: app, expecting: first)
        for book in books.dropFirst() {
            RemoteNavigation.press(.right, in: app, expecting: book)
        }
        RemoteNavigation.press(.up, in: app, expecting: picker)
        RemoteNavigation.press(.left, in: app, expecting: order)
        RemoteNavigation.press(.down, in: app, expecting: last)
    }

    func testSharedCoversHeaderAndReviewsMoveDirectly() {
        continueAfterFailure = false
        let app = RemoteNavigation.open("Book Club")
        let covers = sharedCovers(app)
        XCTAssertTrue(covers.firstMatch.waitForExistence(timeout: 15))
        let visible = RemoteNavigation.visibleButtons(app, prefix: "shared-")
            .filter { !$0.identifier.hasPrefix("shared-review-") }
        XCTAssertGreaterThanOrEqual(visible.count, 4)
        RemoteNavigation.waitForFocus(visible[0])
        RemoteNavigation.press(.right, in: app, expecting: visible[1])
        XCTAssertEqual(visible[0].frame.maxY, visible[1].frame.maxY, accuracy: 10)
        RemoteNavigation.press(.up, in: app, expecting: app.buttons["reader-picker-menu"])
        RemoteNavigation.press(.down, in: app, expecting: visible[1])
        capture(app, name: "Book Club covers and reviews")

        let longReview = app.buttons["shared-3"]
        while !longReview.hasFocus {
            guard let current = RemoteNavigation.focused(app, prefix: "shared-"),
                let index = visible.firstIndex(where: { $0.identifier == current.identifier }),
                index + 1 < visible.count
            else { return XCTFail("shared-3 must be reachable") }
            RemoteNavigation.press(.right, in: app, expecting: visible[index + 1])
        }
        let expand = app.buttons["shared-review-You"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(expand.label, "Read review")
        RemoteNavigation.press(.down, in: app, expecting: expand)
        RemoteNavigation.pressWithoutMoving(.down, in: app, from: expand)
        RemoteNavigation.press(.up, in: app, expecting: longReview)

        // Right moves to the next cover in sort order; Down stays put when it has no review action.
        guard let index = visible.firstIndex(where: { $0.identifier == longReview.identifier }),
            index + 1 < visible.count
        else { return XCTFail("A cover must follow shared-3") }
        let next = visible[index + 1]
        RemoteNavigation.press(.right, in: app, expecting: next)
        if !app.buttons["shared-review-You"].exists
            && !app.buttons["shared-review-Sample reader"].exists
        {
            RemoteNavigation.pressWithoutMoving(.down, in: app, from: next)
        }
    }

    func testSharedSortChoiceUpdatesView() {
        continueAfterFailure = false
        let app = RemoteNavigation.open("Book Club")
        let sort = app.buttons["view-options"]
        XCTAssertTrue(sort.waitForExistence(timeout: 15))
        XCTAssertEqual(sort.value as? String, "Rating agreement")
        RemoteNavigation.waitForFocus(sharedCovers(app).firstMatch)
        RemoteNavigation.press(.up, in: app, expecting: app.buttons["reader-picker-menu"])
        RemoteNavigation.press(.right, in: app, expecting: sort)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["Rating disagreement"].firstMatch
                .waitForExistence(timeout: 5))
        for _ in 0..<3 where !RemoteNavigation.hasFocus(labeled: "Rating disagreement", in: app) {
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.select)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Rating disagreement"), object: sort)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertTrue(RemoteNavigation.isFocused(sort), "Changing the sort must not move focus")
        capture(app, name: "Book Club by disagreement")
    }

    func testReaderPickerOnViewChoosesReader() {
        let app = RemoteNavigation.open("Compare Shelves")
        XCTAssertTrue(app.otherElements["comparison-upper"].waitForExistence(timeout: 15))
        RemoteNavigation.chooseReader("Sample reader", in: app)
        capture(app, name: "Comparison reader picker")
        XCTAssertTrue(app.staticTexts["Sample reader"].exists)
    }

    func testSettingsOmitPerViewChoices() {
        let app = RemoteNavigation.launch(arguments: ["--settings-tab=Views"])
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.openSettings(app)
        XCTAssertTrue(app.staticTexts["comparison-limit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["choose-reader"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["Comparison order"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["Ambient view interval"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["ambient-view-following"].exists,
            "Ambient views are chosen on the Ambient page")
    }

    func testAmbientViewTogglesSitBetweenSessionAndStart() {
        let app = RemoteNavigation.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.selectView("Ambient", in: app)
        let following = app.descendants(matching: .any)["ambient-view-following"].firstMatch
        let middle = app.descendants(matching: .any)["ambient-view-comparison"].firstMatch
        let start = app.buttons["start-ambient"]
        XCTAssertTrue(following.waitForExistence(timeout: 5))
        RemoteNavigation.moveFocus(to: following, in: app)
        RemoteNavigation.press(.down, in: app, expecting: start)
        RemoteNavigation.press(.up, in: app, expecting: middle)
        capture(app, name: "Ambient page")
    }

    func testSpoilerReviewRequiresExplicitReveal() {
        let app = RemoteNavigation.launch(view: "following")
        let first = app.buttons["activity-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        RemoteNavigation.waitForFocus(first)
        RemoteNavigation.press(.right, in: app, expecting: app.buttons["activity-2"])
        RemoteNavigation.press(.down, in: app, expecting: app.buttons["activity-review-2"])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Reveal spoilers"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["A memorable read with a distinctive voice."].isHittable)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.staticTexts["A memorable read with a distinctive voice."]
                .waitForExistence(timeout: 5))
        capture(app, name: "Review reading sheet")
    }

    func testAmbientConsumesFirstSelectAndReturnsToLauncher() {
        let app = RemoteNavigation.launch()
        XCTAssertTrue(app.buttons["book-1"].waitForExistence(timeout: 15))
        RemoteNavigation.startAmbient(app)
        capture(app, name: "Ambient shelf")
        XCUIRemote.shared.press(.select)
        RemoteNavigation.waitForFocus(app.buttons["start-ambient"])
        XCTAssertFalse(app.staticTexts["detail-title"].exists)
        XCTAssertFalse(app.buttons["stop-ambient"].exists)
    }
}
