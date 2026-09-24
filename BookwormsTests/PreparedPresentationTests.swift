import XCTest

@testable import Bookworms

@MainActor
final class PreparedPresentationTests: XCTestCase {
    func testCredentialPresenceDoesNotReadDuringRendering() {
        var reads = 0
        var saved: String? = "fixture"
        let availability = CredentialAvailability { _ in
            reads += 1
            return saved
        }
        availability.reload("fixture-account")
        for _ in 0..<100 { XCTAssertTrue(availability.contains("fixture-account")) }
        XCTAssertEqual(reads, 1)
        saved = nil
        availability.reload("fixture-account")
        XCTAssertFalse(availability.contains("fixture-account"))
        XCTAssertEqual(reads, 2)
    }

    func testPreparedComparisonSurvivesNavigationAndInvalidatesForChoices() {
        let model = SocialLibraryModel()
        model.useSample()
        var preferences = ViewPreferences()
        preferences.readerID = model.following.first?.id
        model.prepare(preferences)
        let revision = model.presentationRevision
        let expected = model.presentation.shared.map(\.id)
        XCTAssertFalse(expected.isEmpty)
        for _ in 0..<100 {
            model.prepare(preferences)
            XCTAssertEqual(model.presentation.shared.map(\.id), expected)
        }
        XCTAssertEqual(model.presentationRevision, revision)
        preferences.ambientMinutes = 15
        model.prepare(preferences)
        XCTAssertEqual(model.presentationRevision, revision)
        preferences.sharedReadsSort = .disagreement
        model.prepare(preferences)
        XCTAssertEqual(model.presentationRevision, revision + 1)
        XCTAssertEqual(
            model.presentation.shared.map(\.id),
            SocialPresentation(snapshot: model.snapshot, preferences: preferences).shared.map(\.id))
        preferences.comparisonCount = 1
        model.prepare(preferences)
        XCTAssertEqual(model.presentationRevision, revision + 2)
        XCTAssertEqual(model.presentation.shared.count, 1)
        preferences.readerID = nil
        model.prepare(preferences)
        XCTAssertTrue(model.presentation.shared.isEmpty)
        XCTAssertTrue(model.presentation.mine.isEmpty)
    }

    func testPreparedIntersectionUsesFullLibrariesAndKeepsReaderRatings() {
        func item(_ id: Int, _ rating: Double) -> ReaderBook {
            ReaderBook(
                book: Book(id: id, title: "Book \(id)", author: "Fixture"),
                rating: rating, review: nil, hasSpoilers: false, finished: nil)
        }
        let owner = ReaderProfile(id: 1, username: "owner", name: nil, avatarURL: nil)
        let reader = ReaderProfile(id: 2, username: "reader", name: nil, avatarURL: nil)
        let snapshot = SocialSnapshot(
            owner: owner, following: [reader],
            mine: [item(1, 5), item(2, 4)], readerBooks: [2: [item(3, 5), item(2, 3)]])
        var preferences = ViewPreferences()
        preferences.readerID = 2
        preferences.comparisonCount = 1
        let prepared = SocialPresentation(snapshot: snapshot, preferences: preferences)
        XCTAssertEqual(prepared.mine.first?.id, 1)
        XCTAssertEqual(prepared.theirs.first?.id, 3)
        XCTAssertEqual(prepared.shared.first?.id, 2)
        XCTAssertEqual(prepared.shared.first?.mine.rating, 4)
        XCTAssertEqual(prepared.shared.first?.theirs.rating, 3)
    }
}
