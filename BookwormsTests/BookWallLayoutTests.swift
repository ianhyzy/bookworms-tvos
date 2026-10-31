import RealityKit
import SwiftUI
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
        // A shared id gives both books the same seeded thickness and variety, so only the
        // space reserved for their lettering differs.
        let short = Book(id: 1, title: "Dune", author: "Frank Herbert", pages: 300)
        let long = Book(
            id: 1, title: "A Very Long Book Title About the World and Everything in It",
            author: "A Writer With a Long Name", pages: 300)
        let shortSlot = try XCTUnwrap(BookWallLayout(books: [short]).slots.first)
        let longSlot = try XCTUnwrap(BookWallLayout(books: [long]).slots.first)
        XCTAssertGreaterThan(longSlot.spineThickness, shortSlot.spineThickness)
    }

    @MainActor
    func testSpineTextureUsesTheBooksActualAspectRatio() throws {
        let book = Book(id: 5, title: "Infinite Jest", author: "David Foster Wallace", pages: 1_100)
        let slot = try XCTUnwrap(BookWallLayout(books: [book]).slots.first)
        let style = BookWallLocalSpine.style(for: book, samples: [])
        let image = try XCTUnwrap(BookWallSpineTexture.make(for: slot, style: style))
        XCTAssertEqual(
            CGFloat(image.width) / CGFloat(image.height),
            CGFloat(slot.spineWallWidth) / CGFloat(slot.spineWallHeight), accuracy: 0.03)
    }

    /// The shelf and Book Wall make the same lettering decision for a spine of the same frame
    /// in the same face. A power-of-two scale keeps the frame exact in scene units.
    @MainActor
    func testBookWallLettersASpineAsTheShelfDoesAtTheSameFrame() {
        let books = [
            Book(id: 7, title: "Dune: Deluxe Edition", author: "Frank Herbert", pages: 600),
            Book(
                id: 446730, title: "The Dungeon Anarchist's Cookbook", author: "Matt Dinniman",
                format: "Ebook"),
            Book(
                id: 3, title: "Good Omens", author: "Neil Gaiman, Terry Pratchett",
                format: "Audiobook"),
        ]
        let points: Float = 64
        for book in books {
            for (thickness, length): (CGFloat, CGFloat) in [(48, 320), (82, 262), (64, 448)] {
                for uppercase in [false, true] {
                    var style = SpineStyle.fallback(for: book)
                    style.fontName = "Georgia-Bold"
                    style.uppercase = uppercase
                    let shelf = SpineTextMetrics.lettering(
                        for: book, style: style,
                        dimensions: SpineDimensions(width: thickness, height: length))
                    let wall = BookWallLayout.lettering(
                        for: book,
                        typography: BookWallLocalSpine.Typography(
                            fontName: "Georgia-Bold", uppercase: uppercase),
                        length: Float(length) / points, thickness: Float(thickness) / points,
                        pointsPerUnit: points)
                    XCTAssertEqual(wall, shelf, book.title)
                }
            }
        }
    }

    /// Each slot carries the lettering the shelf would measure at the slot's frame in points,
    /// in the book's genre face.
    @MainActor
    func testWallSlotsCarryTheShelfsLetteringAtTheirFrame() {
        let books = Array(SampleLibrary.books.prefix(12))
        let layout = BookWallLayout(books: books, pointsPerUnit: 64)
        for slot in layout.slots {
            var style = SpineStyle.fallback(for: slot.book)
            style.fontName = BookWallLocalSpine.fontName(for: slot.book)
            let shelf = SpineTextMetrics.lettering(
                for: slot.book, style: style,
                dimensions: SpineDimensions(
                    width: CGFloat(slot.spineThickness * 64),
                    height: CGFloat(slot.bookHeight * 64)))
            XCTAssertEqual(slot.lettering, shelf, slot.book.title)
        }
    }

    /// Book Wall grows a spine until its title reaches the shelf's 23-point floor at the wall's
    /// viewing scale, so a wall seen from farther away gives the same title a larger spine.
    func testWallSpinesGrowTowardTheTitleFloorAtTheirViewingScale() throws {
        let book = Book(
            id: 2, title: "The Left Hand of Darkness", author: "Ursula K. Le Guin", pages: 300)
        let near = try XCTUnwrap(BookWallLayout(books: [book], pointsPerUnit: 90).slots.first)
        XCTAssertGreaterThanOrEqual(near.lettering.titleSize, SpineTextMetrics.minimumTitleSize)
        let natural = try XCTUnwrap(
            BookWallLayout(
                books: [Book(id: 2, title: "Dune", author: "Ursula K. Le Guin", pages: 300)],
                pointsPerUnit: 90
            )
            .slots.first)
        XCTAssertGreaterThan(
            near.bookHeight * near.spineThickness, natural.bookHeight * natural.spineThickness)
        let far = try XCTUnwrap(BookWallLayout(books: [book], pointsPerUnit: 70).slots.first)
        XCTAssertGreaterThan(
            far.bookHeight * far.spineThickness, near.bookHeight * near.spineThickness)
        XCTAssertLessThanOrEqual(far.bookHeight, BookWallLayout.maximumBookLength)
    }

    /// The wall's viewing scale is largest when the screen's height frames it, and falls as
    /// wider walls frame from farther away.
    @MainActor
    func testViewingScaleFallsAsTheWallWidens() {
        func wall(_ count: Int) -> BookWallLayout {
            BookWallLayout(
                books: (1...count)
                    .map { Book(id: $0, title: "Book \($0)", author: "Author", pages: 1_400) })
        }
        let narrow = BookWallScene.spinePointsPerUnit(for: wall(8))
        let wide = BookWallScene.spinePointsPerUnit(for: wall(50))
        XCTAssertLessThanOrEqual(narrow, BookWallLayout.nominalPointsPerUnit + 1)
        XCTAssertGreaterThan(narrow, BookWallLayout.nominalPointsPerUnit - 3)
        XCTAssertLessThan(wide, narrow * 0.8)
    }

    /// `image`'s pixels, top row first, as premultiplied RGBA bytes.
    private func pixels(of image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// The bounds of `image`'s pixels lighter than 0.6 in every channel within `region`.
    private func inkBounds(_ image: CGImage, in region: CGRect) throws -> CGRect {
        let data = try pixels(of: image)
        var bounds = CGRect.null
        for y in Int(region.minY)..<min(image.height, Int(region.maxY)) {
            for x in Int(region.minX)..<min(image.width, Int(region.maxX)) {
                let offset = (y * image.width + x) * 4
                if (0..<3).allSatisfy({ data[offset + $0] > 153 }) {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds
    }

    /// The sum of `ink` over `image`'s pixels within `region`, each from its RGBA bytes.
    private func coverage(
        _ image: CGImage, in region: CGRect, ink: (ArraySlice<UInt8>) -> Double
    ) throws -> Double {
        let data = try pixels(of: image)
        var sum = 0.0
        for y in max(0, Int(region.minY))..<min(image.height, Int(region.maxY.rounded(.up))) {
            for x in max(0, Int(region.minX))..<min(image.width, Int(region.maxX.rounded(.up))) {
                let offset = (y * image.width + x) * 4
                sum += ink(data[offset..<offset + 4])
            }
        }
        return sum
    }

    /// `book`'s spine on the shelf, 60 by 420 points at one pixel per point, and on Book Wall,
    /// as the transparent lettering texture of a 64-point-per-unit wall, with the format icon's
    /// bounds in each and the texture's pixels per point.
    @MainActor
    private func formatIcons(of book: Book) throws -> (
        shelf: CGImage, shelfIcon: CGRect, wall: CGImage, wallIcon: CGRect, scale: CGFloat
    ) {
        let cloth = StyleColor(red: 0.1, green: 0.15, blue: 0.3)
        var style = SpineStyle.fallback(for: book)
        style.background = cloth
        style.foreground = .paper
        let dimensions = SpineDimensions(width: 60, height: 420)
        let renderer = ImageRenderer(
            content: SpineView(
                book: book, style: style, dimensions: dimensions,
                lettering: SpineTextMetrics.lettering(
                    for: book, style: style, dimensions: dimensions),
                isFocused: false))
        renderer.scale = 1
        let shelf = try XCTUnwrap(renderer.cgImage)
        let room = SpineTextMetrics.formatIconRoom
        let shelfIcon = try inkBounds(
            shelf, in: CGRect(x: 0, y: 420 - room, width: 60, height: room))
        let slot = try XCTUnwrap(BookWallLayout(books: [book], pointsPerUnit: 64).slots.first)
        let wall = try XCTUnwrap(
            BookWallSpineTexture.make(
                for: slot,
                style: BookWallLocalSpine.Style(
                    background: cloth, foreground: .paper,
                    typography: BookWallLocalSpine.Typography(fontName: "Georgia-Bold"))))
        let scale = BookWallSpineTexture.pixelsPerUnit / 64
        let wallIcon = try inkBounds(
            wall,
            in: CGRect(
                x: CGFloat(wall.width) - room * scale, y: 0, width: room * scale,
                height: CGFloat(wall.height)))
        XCTAssertFalse(shelfIcon.isNull, book.title)
        XCTAssertFalse(wallIcon.isNull, book.title)
        return (shelf, shelfIcon, wall, wallIcon, scale)
    }

    /// The format icon turns with the lettering, so it reads in the lettering's direction: the
    /// headphones' band faces the tops of the letters, which point right on the upright shelf
    /// spine, read top to bottom, and up on the flat Book Wall texture, read left to right.
    /// Down the symbol's axis, the band has ink, and the gap between the ear cups has none.
    @MainActor
    func testFormatIconReadsInTheLetteringsDirection() throws {
        let book = Book(
            id: 11, title: "Dune", author: "Frank Herbert", pages: 200, format: "Audiobook")
        XCTAssertEqual(book.formatSymbol, "headphones")
        let icons = try formatIcons(of: book)
        func ink(_ bytes: ArraySlice<UInt8>) -> Double {
            bytes.prefix(3).allSatisfy { $0 > 153 } ? 1 : 0
        }

        let shelf = icons.shelfIcon
        let third = shelf.width / 3
        let shelfAxis = CGRect(x: shelf.minX, y: shelf.midY - 1, width: shelf.width, height: 2)
        let right = try coverage(
            icons.shelf, in: shelfAxis.divided(atDistance: third, from: .maxXEdge).slice, ink: ink)
        let left = try coverage(
            icons.shelf, in: shelfAxis.divided(atDistance: third, from: .minXEdge).slice, ink: ink)
        XCTAssertGreaterThan(right, 0, "The shelf icon's band faces right")
        XCTAssertEqual(left, 0, "The shelf icon's ear cups face left")

        let wall = icons.wallIcon
        let wallAxis = CGRect(x: wall.midX - 3, y: wall.minY, width: 6, height: wall.height)
        let top = try coverage(
            icons.wall, in: wallAxis.divided(atDistance: wall.height / 3, from: .minYEdge).slice,
            ink: ink)
        let bottom = try coverage(
            icons.wall, in: wallAxis.divided(atDistance: wall.height / 3, from: .maxYEdge).slice,
            ink: ink)
        XCTAssertGreaterThan(top, 0, "The texture's icon band faces up")
        XCTAssertEqual(bottom, 0, "The texture's icon ear cups face down")
        // The icon is the shelf's, scaled to the texture.
        XCTAssertEqual(wall.height / icons.scale, shelf.width, accuracy: 2)
    }

    /// Both views draw the format icon in the same rendering mode, so the Ebook symbol's screen
    /// has the same faint fill on the shelf and on Book Wall: the icon's ink, in points, agrees
    /// within 10%. Monochrome rendering leaves about a third less.
    @MainActor
    func testFormatIconInksTheSameOnTheShelfAndTheWall() throws {
        let book = Book(id: 12, title: "Dune", author: "Frank Herbert", pages: 200, format: "Ebook")
        let icons = try formatIcons(of: book)
        let shelfData = try pixels(of: icons.shelf)
        // Plain cloth between the lettering and the icon.
        let clothOffset = (Int(420 - SpineTextMetrics.formatIconRoom - 3) * 60 + 30) * 4
        let cloth = Double(shelfData[clothOffset + 2])
        let paper = StyleColor.paper.blue * 255
        let shelfInk = try coverage(icons.shelf, in: icons.shelfIcon.insetBy(dx: -2, dy: -2)) {
            min(1, max(0, (Double($0[$0.startIndex + 2]) - cloth) / (paper - cloth)))
        }
        let wallInk =
            try coverage(
                icons.wall, in: icons.wallIcon.insetBy(dx: -2 * icons.scale, dy: -2 * icons.scale)
            ) { Double($0[$0.startIndex + 3]) / 255 } / Double(icons.scale * icons.scale)
        XCTAssertEqual(wallInk / shelfInk, 1, accuracy: 0.1)
    }

    @MainActor
    func testShelfFrontGrowsDownwardUntilTheLabelMeetsTheMinimum() {
        // Very long books with short titles reach `maximumBookLength`, so every column takes the
        // widest lane that page count alone produces.
        func wall(_ count: Int, pages: Int = 1_400) -> BookWallLayout {
            BookWallLayout(
                books: (1...count)
                    .map { Book(id: $0, title: "Book \($0)", author: "Author", pages: pages) })
        }
        let minimum = BookWallScene.minimumShelfThickness
        for (count, columns) in [(8, 3), (30, 3), (40, 4), (50, 5)] {
            let layout = wall(count)
            XCTAssertEqual(layout.columns, columns)
            XCTAssertEqual(
                layout.totalWidth, Float(columns) * (BookWallLayout.maximumBookLength + 0.24),
                accuracy: 0.001)
            let thickness = BookWallScene.shelfThickness(for: layout)
            XCTAssertGreaterThanOrEqual(
                BookWallScene.labelPoints(for: layout, shelfThickness: thickness),
                BookWallScene.minimumLabelPoints)
            if columns == 3 {
                XCTAssertEqual(thickness, minimum)
            } else {
                // The front is no taller than the minimum needs.
                XCTAssertLessThan(
                    BookWallScene.labelPoints(for: layout, shelfThickness: thickness - 0.01),
                    BookWallScene.minimumLabelPoints)
            }
        }
        XCTAssertGreaterThan(
            BookWallScene.shelfThickness(for: wall(50)),
            BookWallScene.shelfThickness(for: wall(40)))
        // Short books keep a 4-column wall narrow enough that its label already meets the
        // minimum, so the front keeps its minimum height.
        let narrow = wall(40, pages: 100)
        XCTAssertEqual(narrow.columns, 4)
        XCTAssertEqual(BookWallScene.shelfThickness(for: narrow), minimum)
    }

    func testDeviceGateStartsAtAppleTV4KSecondGeneration() {
        XCTAssertFalse(BookWallAvailability.supports(machineIdentifier: "AppleTV6,2"))
        XCTAssertTrue(BookWallAvailability.supports(machineIdentifier: "AppleTV11,1"))
        XCTAssertTrue(BookWallAvailability.supports(machineIdentifier: "AppleTV14,1"))
        XCTAssertFalse(BookWallAvailability.supports(machineIdentifier: "unknown"))
    }

    @MainActor
    func testAWallWithNothingToDropStopsDrawingOnceItsChangeIsShown() {
        let scene = BookWallScene()
        scene.didDrawFrame()
        XCTAssertFalse(scene.needsFrame)
        var settled = false
        scene.configure(
            prepared: BookWallPreparedWall(
                books: [], sources: [:], designs: [:], looks: [:], drawn: [:], drawsWith: [:],
                layout: BookWallLayout(books: []), bodies: [:], labels: [:], hint: nil),
            reduceMotion: false, onFocusFrames: { _, isSettled in settled = isSettled })
        scene.didDrawFrame()
        XCTAssertTrue(settled)
        XCTAssertFalse(scene.needsFrame)
    }

    @MainActor
    func testCancelingATransitionLeavesNoUnlitPointLightEnabled() {
        let scene = BookWallScene()
        scene.cancelTransition()
        let lights = scene.root.children.compactMap { $0 as? PointLight }
        XCTAssertFalse(lights.isEmpty)
        XCTAssertFalse(lights.contains { $0.isEnabled && $0.light.intensity == 0 })
    }

    /// A synthetic year of titles of one to six words and 150 to 1,050 pages, laid out at the
    /// scale it shows at, as `BookWallPreparation` does.
    @MainActor
    private func syntheticWall(_ count: Int) -> BookWallLayout {
        let words = [
            "Night", "Orchard", "River", "Glass", "House", "Winter", "Stone", "Garden", "Silent",
            "Empire", "Crown", "Shadow",
        ]
        let books = (1...count)
            .map { index in
                Book(
                    id: 1_000 + index * 37,
                    title: (0..<(1 + index * 7 % 6))
                        .map { words[(index * 5 + $0 * 3) % words.count] }
                        .joined(separator: " "),
                    author: "Author \(index)", pages: 150 + index * 97 % 901)
            }
        var layout = BookWallLayout(books: books)
        for _ in 0..<3 {
            layout = BookWallLayout(
                books: books, pointsPerUnit: BookWallScene.spinePointsPerUnit(for: layout))
        }
        return layout
    }

    /// A crowded wall keeps its books' lengths varied: a spine that its column squeezes stops
    /// lengthening where its title stops growing, so few books stop at `maximumBookLength`.
    @MainActor
    func testACrowdedWallKeepsItsBooksLengthsVaried() {
        let layout = syntheticWall(50)
        XCTAssertLessThan(layout.pointsPerUnit, 60)
        let capped = layout.slots.filter {
            $0.bookHeight >= BookWallLayout.maximumBookLength - 0.001
        }
        XCTAssertLessThan(capped.count, 35)
        XCTAssertGreaterThanOrEqual(
            Set(layout.slots.map { ($0.bookHeight * 100).rounded() }).count, 15)
    }
}
