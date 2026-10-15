import UIKit
import XCTest

@testable import Bookworms

final class SeriesDesignsTests: XCTestCase {
    private func book(
        _ id: Int, series: Int? = 7, position: Double? = nil, finished: String? = nil,
        author: String = "Matt Dinniman", title: String = "Book"
    ) -> Book {
        var book = Book(
            id: id, title: title, author: author, finished: finished, seriesID: series,
            seriesName: series.map { _ in "Dungeon Crawler Carl" })
        book.seriesPosition = position
        return book
    }

    func testBooksMatchOnTheSameSeriesAndAnySharedAuthor() {
        let carl = book(1)
        XCTAssertTrue(SeriesDesigns.matches(carl, book(2, author: "matt dinnimán")))
        XCTAssertTrue(
            SeriesDesigns.matches(carl, book(3, author: "Jeff Hays, Matt Dinniman")),
            "Any one shared author is enough")
        XCTAssertTrue(SeriesDesigns.matches(carl, book(4, author: "Matt  Dinniman.")))
        XCTAssertFalse(SeriesDesigns.matches(carl, book(5, author: "Someone Else")))
        XCTAssertFalse(SeriesDesigns.matches(carl, book(6, series: 8)))
        XCTAssertFalse(SeriesDesigns.matches(book(7, series: nil), book(8, series: nil)))
    }

    func testSourcesRankByPositionThenFinishThenID() {
        XCTAssertTrue(SeriesDesigns.ranksBefore(book(9, position: 1), book(1, position: 2)))
        XCTAssertTrue(
            SeriesDesigns.ranksBefore(book(9, position: 3), book(1)),
            "A missing position ranks last")
        XCTAssertTrue(
            SeriesDesigns.ranksBefore(
                book(9, position: 2, finished: "2025-01-01"),
                book(1, position: 2, finished: "2026-01-01")))
        XCTAssertTrue(
            SeriesDesigns.ranksBefore(
                book(9, position: 2, finished: "2026-01-01"), book(1, position: 2)),
            "A missing finish ranks last")
        XCTAssertTrue(SeriesDesigns.ranksBefore(book(1, position: 2), book(9, position: 2)))
    }

    func testEachSeriesDrawsWithItsBestRankedUsableBook() {
        let books = [
            book(1, position: 1), book(2, position: 2), book(3, position: 3),
            book(4, position: 4, author: "Someone Else"), book(5, series: nil),
            book(6, series: 9, position: 1), book(7, series: 9, position: 2),
        ]
        var fonts = Dictionary(uniqueKeysWithValues: books.map { ($0.id, "Georgia-Bold") })
        fonts[1] = "Impact"
        fonts[6] = "Georgia-BoldItalic"
        let sources = SeriesDesigns.sources(books: books, fonts: fonts)
        XCTAssertNil(
            sources[1], "An Impact book ranks first, so it lends to no one and draws its own")
        XCTAssertEqual(sources[2], 2, "A source maps to itself")
        XCTAssertEqual(sources[3], 2)
        XCTAssertNil(sources[4], "A book by another author keeps its own design")
        XCTAssertNil(sources[5])
        XCTAssertNil(sources[6], "An italic book ranks first and draws its own, remapped upright")
        XCTAssertNil(sources[7], "Only an earlier book lends its design")
        XCTAssertEqual(
            SeriesDesigns.sources(books: books, fonts: fonts) { book, _ in book.id != 3 }[3], nil,
            "A book the source's font can't letter keeps its own design")

        let library = LibraryModel.seriesSources(of: books)
        XCTAssertEqual(library[3]?.id, 1, "Book Wall fonts are never blocked")
        XCTAssertEqual(library[1]?.id, 1)
        XCTAssertNil(library[4])
    }

    func testSourcesLendOnlyOwnDesignsInAnyBookOrder() {
        // Book 2 shares an author with books 1 and 3, which share none. Book 2 draws book 1's
        // design; book 3 may not draw the design book 2 borrowed, so it draws its own.
        let books = [
            book(1, position: 1, author: "Ann Author"),
            book(2, position: 2, author: "Ann Author, Co Writer"),
            book(3, position: 3, author: "Co Writer"),
        ]
        let fonts = Dictionary(uniqueKeysWithValues: books.map { ($0.id, "Georgia-Bold") })
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            XCTAssertEqual(
                SeriesDesigns.sources(books: order.map { books[$0] }, fonts: fonts),
                [1: 1, 2: 1], "\(order)")
        }
    }

    func testAFontWithoutTheLettersGlyphsCannotLetterABook() {
        XCTAssertTrue(
            SeriesDesigns.canLetter(book(1, title: "Carl's Doomsday"), fontName: "Georgia-Bold"))
        XCTAssertFalse(
            SeriesDesigns.canLetter(book(2, title: "ダンジョン"), fontName: "Georgia-Bold"))
        XCTAssertFalse(
            SeriesDesigns.canLetter(book(3), fontName: "NoSuchFont-Bold"),
            "A missing font letters nothing")
    }

    /// A book drawing with its source's design takes the source's cloth and font, and keeps its
    /// own cover's fold at the front joint.
    @MainActor
    func testTheWallDrawsTheSourcesStyleWithTheBooksOwnFold() async throws {
        func cover(_ color: UIColor, edge: UIColor) throws -> CGImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(
                size: CGSize(width: 400, height: 600), format: format
            )
            .image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
                edge.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 24, height: 600))
            }
            return try XCTUnwrap(image.cgImage)
        }
        let source = book(1, position: 1)
        let member = book(2, position: 2, title: "The Gate of the Feral Gods")
        let rasterizer = BookWallRasterizer()
        let design = await rasterizer.style(
            for: source, cover: try cover(.red, edge: .red))
        let slot = try XCTUnwrap(BookWallLayout(books: [member]).slots.first)
        let images = await rasterizer.render(
            slot: slot, cover: try cover(.blue, edge: .green), design: design, fontStyle: .serif)
        XCTAssertEqual(images.style, design, "The book wears its source's colors and font")
        let spine = try XCTUnwrap(images.spine)
        let cloth = try pixel(spine, x: spine.width / 30, y: spine.height / 2)
        let joint = try pixel(spine, x: spine.width / 30, y: 1)
        XCTAssertGreaterThan(cloth.red, cloth.green + 0.3, "The cloth is the source's red")
        XCTAssertGreaterThan(joint.green, cloth.green + 0.2, "The fold is the book's own green")
        let board = try XCTUnwrap(images.cover)
        let art = try pixel(board, x: board.width / 2, y: board.height / 2)
        XCTAssertGreaterThan(art.blue, art.red + 0.3, "The board keeps the book's own cover")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (
        red: Double, green: Double, blue: Double
    ) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(x), y: CGFloat(y) - CGFloat(image.height) + 1,
                width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }
}
