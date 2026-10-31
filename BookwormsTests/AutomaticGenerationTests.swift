import XCTest

@testable import Bookworms

@MainActor
final class AutomaticGenerationTests: XCTestCase {
    func testGenerationEntryPointsAreDisabled() {
        XCTAssertFalse(BookPresentation.spineGenerationEnabled)
        let model = LibraryModel()
        model.regenerateSpines()
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.generationStatus, "Spine generation is disabled.")
        model.regenerateSpines(onlyMissing: true, automatically: true)
        XCTAssertFalse(model.isGenerating)
    }

    func testOnlyNewBooksWithCoversAreEligibleAndFailuresWaitADay() throws {
        let suite = "AutomaticGenerationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = AutomaticSpineGeneration(defaults: defaults)
        let now = Date()
        let books = [
            Book(
                id: 1, title: "Saved", author: "Fixture",
                coverURL: URL(string: "https://fixture.invalid/1")),
            Book(
                id: 2, title: "New", author: "Fixture",
                coverURL: URL(string: "https://fixture.invalid/2")),
            Book(id: 3, title: "No cover", author: "Fixture"),
        ]
        XCTAssertEqual(policy.candidates(in: books, savedIDs: [1], now: now).map(\.id), [2])
        policy.recordAttempt([books[1]], now: now)
        let reloaded = AutomaticSpineGeneration(defaults: defaults)
        XCTAssertTrue(
            reloaded.candidates(in: books, savedIDs: [1], now: now.addingTimeInterval(86399))
                .isEmpty)
        XCTAssertTrue(
            reloaded.candidates(in: books, savedIDs: [1], now: now.addingTimeInterval(-1)).isEmpty)
        XCTAssertEqual(
            reloaded.candidates(in: books, savedIDs: [1], now: now.addingTimeInterval(86400))
                .map(\.id), [2])
        XCTAssertTrue(
            reloaded.candidates(in: books, savedIDs: [1, 2], now: now.addingTimeInterval(86400))
                .isEmpty)
    }
}
