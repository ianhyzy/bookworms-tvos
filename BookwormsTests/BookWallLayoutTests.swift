import XCTest

@testable import Bookworms

final class BookWallLayoutTests: XCTestCase {
    func testEveryBookGetsOneStableSlotWithinItsColumn() {
        let books = (1...57)
            .map { id in
                Book(id: id, title: "Book \(id)", author: "Author", pages: 120 + id * 8)
            }
        let layout = BookWallLayout(books: books)
        XCTAssertEqual(layout.columns, 5)
        XCTAssertEqual(Set(layout.slots.map { $0.book.id }), Set(books.map(\.id)))
        XCTAssertEqual(layout.slots.count, books.count)
        for column in 0..<layout.columns {
            let slots = layout.slots.filter { $0.column == column }.sorted { $0.row < $1.row }
            for (lower, upper) in zip(slots, slots.dropFirst()) {
                XCTAssertEqual(
                    lower.restingY + lower.collisionThickness / 2,
                    upper.restingY - upper.collisionThickness / 2,
                    accuracy: 0.0001)
            }
            XCTAssertLessThanOrEqual(
                slots.last.map { $0.restingY + $0.collisionThickness / 2 } ?? 0,
                BookWallLayout.floorY + BookWallLayout.maxStackHeight + 0.0001)
            XCTAssertEqual(
                slots.first.map { $0.restingY - $0.collisionThickness / 2 } ?? 0,
                BookWallLayout.floorY, accuracy: 0.0001)
        }
        XCTAssertEqual(
            layout.slots.map { $0.book.id }, BookWallLayout(books: books).slots.map { $0.book.id })
    }

    func testColumnCountFollowsBookCount() {
        func columns(_ count: Int) -> Int {
            BookWallLayout(
                books: (1...count).map { Book(id: $0, title: "Book \($0)", author: "Author") }
            )
            .columns
        }
        XCTAssertEqual(columns(8), 3)
        XCTAssertEqual(columns(30), 3)
        XCTAssertEqual(columns(31), 4)
        XCTAssertEqual(columns(40), 4)
    }

    func testWideBooksLeaveClearanceBetweenColumns() throws {
        let books = (1...8)
            .map { id in
                Book(
                    id: id, title: String(repeating: "Extraordinary", count: id == 1 ? 12 : 1),
                    author: "Author", pages: 400)
            }
        let layout = BookWallLayout(books: books)
        let widest = try XCTUnwrap(layout.slots.map(\.bookHeight).max())
        XCTAssertGreaterThan(widest, BookWallLayout.minimumLaneWidth)
        let firstRow = layout.slots.filter { $0.row == 0 }.sorted { $0.column < $1.column }
        for (left, right) in zip(firstRow, firstRow.dropFirst()) {
            let edgeGap = right.x - right.bookHeight / 2 - (left.x + left.bookHeight / 2)
            XCTAssertGreaterThanOrEqual(edgeGap, 0.24 - 0.0001)
        }
    }

    func testLongBookHasAThickerSpineWithoutCrowdingShortBooks() throws {
        let books = (1...8)
            .map { id in
                Book(
                    id: id, title: "Book \(id)", author: "Author",
                    pages: id == 5 ? 1_100 : 450)
            }
        let slots = BookWallLayout(books: books).slots
        let ordinary = try XCTUnwrap(slots.first { $0.book.id == 1 })
        let long = try XCTUnwrap(slots.first { $0.book.id == 5 })
        // Per-book variety keeps size loosely tied to page count.
        XCTAssertGreaterThan(long.spineThickness, ordinary.spineThickness * 1.5)
        XCTAssertGreaterThanOrEqual(ordinary.spineThickness, BookWallLayout.minimumSpineThickness)
        XCTAssertGreaterThan(ordinary.bookHeight, ordinary.spineThickness * 2)
        XCTAssertGreaterThan(long.bookHeight, long.spineThickness * 2.1)
        XCTAssertGreaterThanOrEqual(long.bookHeight, ordinary.bookHeight)
        XCTAssertLessThanOrEqual(long.bookHeight, BookWallLayout.maximumBookLength + 0.0001)
    }

    func testBookWidthsShowVisibleVariation() {
        let books = (1...20)
            .map {
                Book(id: $0, title: "Book \($0)", author: "Author", pages: 100 + $0 * 60)
            }
        let widths = BookWallLayout(books: books).slots.map(\.bookHeight)
        XCTAssertGreaterThan((widths.max() ?? 0) - (widths.min() ?? 0), 0.8)
    }

    func testBooksWithoutCoversUseTheFallbackAspectRatio() {
        let books = [
            Book(id: 1, title: "Termush", author: "Sven Holm", pages: 120),
            Book(
                id: 2, title: "The Left Hand of Darkness", author: "Ursula K. Le Guin", pages: 300),
            Book(id: 3, title: "The Tainted Cup", author: "Robert Jackson Bennett", pages: 390),
        ]
        for slot in BookWallLayout(books: books).slots {
            XCTAssertGreaterThanOrEqual(slot.bookHeight, BookWallLayout.minimumBookHeight)
            XCTAssertEqual(
                slot.coverWidth / slot.bookHeight,
                BookWallLayout.fallbackCoverAspectRatio, accuracy: 0.0001)
        }
    }

    func testCoverWidthFollowsEachImagesAspectRatio() throws {
        let books = [
            Book(id: 1, title: "Tall cover", author: "Author", pages: 320),
            Book(id: 2, title: "Wide cover", author: "Author", pages: 800),
        ]
        let slots = BookWallLayout(books: books, coverRatios: [1: 0.54, 2: 0.78]).slots
        for (id, ratio) in [(1, 0.54), (2, 0.78)] {
            let slot = try XCTUnwrap(slots.first { $0.book.id == id })
            XCTAssertEqual(Double(slot.coverWidth / slot.bookHeight), ratio, accuracy: 0.0001)
        }
    }

    func testLongTitleGetsMoreSpineSpace() throws {
        let short = Book(id: 1, title: "Dune", author: "Frank Herbert", pages: 300)
        let long = Book(
            id: 2, title: "A Very Long Book Title About the World and Everything in It",
            author: "A Writer With a Long Name", pages: 300)
        let slots = BookWallLayout(books: [short, long]).slots
        XCTAssertGreaterThan(
            try XCTUnwrap(slots.first { $0.book.id == 2 }).spineThickness,
            try XCTUnwrap(slots.first { $0.book.id == 1 }).spineThickness)
    }

    @MainActor
    func testSpineTextureUsesTheBooksActualAspectRatio() throws {
        let book = Book(id: 5, title: "Infinite Jest", author: "David Foster Wallace", pages: 1_100)
        let slot = try XCTUnwrap(BookWallLayout(books: [book]).slots.first)
        let style = BookWallLocalSpine.style(for: book, samples: [])
        let image = try XCTUnwrap(BookWallSpineTexture.make(for: slot, style: style))
        XCTAssertEqual(
            CGFloat(image.width) / CGFloat(image.height),
            CGFloat(slot.spineFaceWidth) / CGFloat(slot.spineFaceHeight), accuracy: 0.03)
    }

    func testDeviceGateStartsAtAppleTV4KSecondGeneration() {
        XCTAssertFalse(BookWallAvailability.supports(machineIdentifier: "AppleTV6,2"))
        XCTAssertTrue(BookWallAvailability.supports(machineIdentifier: "AppleTV11,1"))
        XCTAssertTrue(BookWallAvailability.supports(machineIdentifier: "AppleTV14,1"))
        XCTAssertFalse(BookWallAvailability.supports(machineIdentifier: "unknown"))
    }
}
