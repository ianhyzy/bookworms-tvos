import XCTest

@testable import Bookworms

@MainActor
final class PerformanceDiagnosticsTests: XCTestCase {
    func testDiagnosticsAreInactiveWithoutExplicitLaunchArgument() {
        XCTAssertFalse(PerformanceDiagnostics.enabled)
        for variant in ["eligibility", "layout", "activity", "mounting", "glass", "background"] {
            XCTAssertFalse(PerformanceDiagnostics.isolates(variant))
        }
    }

    func testDisabledMarkersDoNotChangeResults() {
        let interval = PerformanceDiagnostics.begin("TestInterval")
        PerformanceDiagnostics.event("TestEvent", 42)
        interval.end()
        let books = [Book(id: 1, title: "Example", author: "Reader", pages: 300)]
        XCTAssertEqual(
            BookPresentation.pages(
                books: books, styles: [:], coverRatios: [:], width: 1000,
                rowHeight: 500
            )
            .flatMap(\.books), books)
    }
}
