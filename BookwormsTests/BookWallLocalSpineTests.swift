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
}
