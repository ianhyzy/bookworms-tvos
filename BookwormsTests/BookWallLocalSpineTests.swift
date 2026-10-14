import UIKit
import XCTest

@testable import Bookworms

final class BookWallLocalSpineTests: XCTestCase {
    @MainActor
    func testGenresSelectTwelveInstalledFaces() {
        let genres = [
            "Fantasy", "Science Fiction", "Mystery", "Horror", "Romance", "History",
            "Literary Fiction", "Memoir", "Young Adult", "Graphic Novel", "Poetry", "Humor",
        ]
        let names = genres.enumerated()
            .map { index, genre in
                BookWallLocalSpine.fontName(
                    for: Book(id: index + 1, title: "Book", author: "Author", genres: [genre]))
            }
        XCTAssertEqual(Set(names).count, 12)
        for name in names { XCTAssertNotNil(UIFont(name: name, size: 24), name) }
    }

    func testCoverColorsAlwaysProduceReadableText() {
        let book = Book(id: 1, title: "Book", author: "Author", genres: ["Fantasy"])
        for level in stride(from: 0.0, through: 1.0, by: 0.1) {
            let color = StyleColor(red: level, green: level, blue: level)
            let style = BookWallLocalSpine.style(
                for: book, samples: Array(repeating: color, count: 20))
            XCTAssertGreaterThanOrEqual(style.foreground.contrast(with: style.background), 4.5)
        }
    }

    @MainActor
    func testCoverSamplingUsesItsDominantColor() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
            .image { context in
                UIColor(red: 0.75, green: 0.12, blue: 0.18, alpha: 1).setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            }
        let cover = try XCTUnwrap(image.cgImage)
        let book = Book(id: 1, title: "Book", author: "Author")
        let style = BookWallLocalSpine.style(for: book, cover: cover)
        XCTAssertGreaterThan(style.background.red, style.background.green * 3)
        XCTAssertGreaterThanOrEqual(style.foreground.contrast(with: style.background), 4.5)
    }

    @MainActor
    func testEdgeColorsFollowTheCoversSpineSideFromHeadToTail() throws {
        // The spine side is red at the head and green at the tail; the rest of the art is blue.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 96))
            .image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 100, height: 96))
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 6, height: 48))
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 48, width: 6, height: 48))
            }
        let colors = BookWallLocalSpine.edgeColors(of: try XCTUnwrap(image.cgImage))
        XCTAssertEqual(colors.count, 48)
        let head = try XCTUnwrap(colors.first)
        let tail = try XCTUnwrap(colors.last)
        XCTAssertGreaterThan(head.red, 0.9)
        XCTAssertLessThan(head.blue, 0.1)
        XCTAssertGreaterThan(tail.green, 0.9)
        XCTAssertLessThan(tail.blue, 0.1)
    }

    @MainActor
    func testSpineCornersAreNearlySquare() {
        XCTAssertEqual(SpineView.cornerRadius(thickness: 20), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SpineView.cornerRadius(thickness: 40), 1)
        XCTAssertEqual(SpineView.cornerRadius(thickness: 160), 1)
    }

    @MainActor
    func testOnlyBooksAtLeast32MillimetersThickHaveStampedBands() {
        for id in 1...40 {
            let doorstopper = Book(id: id, title: "Book", author: "Author", pages: 1_100)
            let novel = Book(id: id, title: "Book", author: "Author", pages: 320)
            let unknown = Book(id: id, title: "Book", author: "Author")
            XCTAssertTrue(SpineView.stamps(doorstopper), "\(id)")
            XCTAssertFalse(SpineView.stamps(novel), "\(id)")
            XCTAssertFalse(SpineView.stamps(unknown), "\(id)")
            for pages in [100, 500, 700, 900, 1_400] {
                let book = Book(id: id, title: "Book", author: "Author", pages: pages)
                let thickness = SpineView.thickness(of: book)
                XCTAssertEqual(thickness % 4, 0)
                XCTAssertEqual(SpineView.stamps(book), thickness >= 32)
            }
        }
        // Without variety, a 721-page book is 28.2 mm thick, which rounds to 28 mm.
        let thicknesses = (1...200)
            .map { SpineView.thickness(of: Book(id: $0, title: "B", author: "A", pages: 721)) }
        XCTAssertEqual(thicknesses.min(), 28)
    }
}
