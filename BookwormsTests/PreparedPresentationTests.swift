import XCTest

@testable import Bookworms

@MainActor
final class PreparedPresentationTests: XCTestCase {
    func testShelfPagesWaitForTheCurrentCoverDimensions() throws {
        let suite = "PreparedPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var dependencies = LibraryDependencies(
            defaults: defaults,
            storageDirectory: FileManager.default.temporaryDirectory.appending(path: suite))
        dependencies.allowLaunchOverrides = false
        dependencies.readCredential = { _ in nil }
        let library = LibraryModel(dependencies: dependencies)
        let books = [Book(id: 1, title: "A fixture book", author: "A fixture author")]
        let initialKey = ShelfPreparationKey(
            revision: library.presentationRevision, fontRevision: library.fontRevision,
            width: 1400, height: 600)
        let initialPages = BookPresentation.pages(
            books: books, styles: [:], coverRatios: library.coverRatios,
            width: initialKey.width, rowHeight: initialKey.height)
        let initial = PreparedShelfPages(key: initialKey, pages: initialPages)
        XCTAssertTrue(initial.isReady(for: initialKey))

        library.recordCoverRatio(0.45, for: 1)
        let currentKey = ShelfPreparationKey(
            revision: library.presentationRevision, fontRevision: library.fontRevision,
            width: initialKey.width, height: initialKey.height)
        XCTAssertFalse(initial.pages.isEmpty)
        XCTAssertFalse(initial.isReady(for: currentKey))

        let currentPages = BookPresentation.pages(
            books: books, styles: [:], coverRatios: library.coverRatios,
            width: currentKey.width, rowHeight: currentKey.height)
        let current = PreparedShelfPages(key: currentKey, pages: currentPages)
        XCTAssertNotEqual(
            initial.pages.first?.dimensions[1]?.width, current.pages.first?.dimensions[1]?.width)
        XCTAssertTrue(current.isReady(for: currentKey))
    }

    func testShelfPagesInvalidateForNewFontsAndGeometry() {
        let books = [Book(id: 1, title: "A fixture book", author: "A fixture author")]
        let key = ShelfPreparationKey(revision: 1, fontRevision: 2, width: 1400, height: 600)
        let prepared = PreparedShelfPages(
            key: key,
            pages: BookPresentation.pages(
                books: books, styles: [:], coverRatios: [:], width: key.width, rowHeight: key.height
            ))
        for requested in [
            ShelfPreparationKey(revision: 1, fontRevision: 3, width: 1400, height: 600),
            ShelfPreparationKey(revision: 1, fontRevision: 2, width: 1200, height: 600),
            ShelfPreparationKey(revision: 1, fontRevision: 2, width: 1400, height: 500),
        ] {
            XCTAssertFalse(prepared.isReady(for: requested))
        }
        XCTAssertTrue(prepared.isReady(for: key))
    }

    func testEmptyShelfPagesDoNotSatisfyNonemptyLibraryPreparation() {
        let key = ShelfPreparationKey(revision: 1, fontRevision: 2, width: 1400, height: 600)
        XCTAssertFalse(PreparedShelfPages(key: key, pages: []).isReady(for: key))
    }

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
