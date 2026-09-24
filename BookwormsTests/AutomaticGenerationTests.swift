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

    func testMissingSnapshotRecoversAndFailuresUseShortBackoff() {
        let now = Date()
        XCTAssertFalse(
            RefreshPolicy.isDue(
                lastAttempt: now, lastSuccess: now,
                hasSnapshot: true, manual: false, now: now + 60))
        XCTAssertTrue(
            RefreshPolicy.isDue(
                lastAttempt: now, lastSuccess: now,
                hasSnapshot: false, manual: false, now: now + 60))
        XCTAssertFalse(
            RefreshPolicy.isDue(
                lastAttempt: now, lastSuccess: nil,
                hasSnapshot: false, manual: false, now: now + 299))
        XCTAssertTrue(
            RefreshPolicy.isDue(
                lastAttempt: now, lastSuccess: nil,
                hasSnapshot: false, manual: false, now: now + 300))
        XCTAssertTrue(
            RefreshPolicy.isDue(
                lastAttempt: now, lastSuccess: now,
                hasSnapshot: true, manual: true, now: now + 10))
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

    func testManualSyncBypassesDailyGateAndResetsAutomaticSchedule() throws {
        let suite = "ManualSyncTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schedule = SourceSyncSchedule(defaults: defaults)
        let now = Date()
        for source in LibrarySource.allCases {
            try schedule.begin(source, now: now)
            schedule.seed(source, date: now)
            XCTAssertThrowsError(try schedule.begin(source, now: now.addingTimeInterval(60)))
            try schedule.begin(source, now: now.addingTimeInterval(60), manual: true)
            schedule.seed(source, date: now.addingTimeInterval(60))
            XCTAssertEqual(schedule.lastAttempt(source), now.addingTimeInterval(60))
            XCTAssertFalse(schedule.isDue(source, now: now.addingTimeInterval(86400)))
            XCTAssertTrue(schedule.isDue(source, now: now.addingTimeInterval(86460)))
        }
    }
}
