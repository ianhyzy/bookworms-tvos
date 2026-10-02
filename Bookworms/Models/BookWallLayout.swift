import CoreText
import Foundation

/// Stable slots for one calendar year's books, including the space occupied by their covers.
struct BookWallLayout: Sendable {
    struct Slot: Sendable {
        let book: Book
        let column: Int
        let row: Int
        let x: Float
        let restingY: Float
        let bookHeight: Float
        let spineThickness: Float
        let coverWidth: Float

        var spineFaceWidth: Float { bookHeight * 0.94 }
        var spineFaceHeight: Float { spineThickness * 0.88 }
        var collisionThickness: Float { spineThickness + BookWallLayout.coverWrapThickness * 2 }
    }

    static let floorY: Float = -4.5
    static let coverWrapThickness: Float = 0.006
    static let minimumLaneWidth: Float = 3.1
    static let maxStackHeight: Float = 8.5
    static let minimumSpineThickness: Float = 0.55
    static let minimumBookHeight: Float = 2.75
    /// Keeps each spine clearly longer than it is thick, so thick books do not read as blocks.
    static let minimumLengthToThickness: Float = 6
    /// Very long books stop thickening here (before per-book variety) so one book cannot
    /// widen its column enough to push the whole wall back.
    static let maximumPageThickness: Float = 1.3
    /// Thick books keep their thickness but stop lengthening here, so a doorstopper reads as
    /// chunky rather than widening its column.
    static let maximumBookLength: Float = 5.6
    /// Vertical layout of spine text as fractions of the spine's thickness: a small top
    /// margin, the title, then the author directly below it.
    static let titleTop: CGFloat = 0.05
    static let titleShare: CGFloat = 0.58
    static let authorShare: CGFloat = 0.32
    /// About this many books share a column; fewer, taller columns fit the screen's height.
    static let booksPerColumn = 10
    static let fallbackCoverAspectRatio: Float = 2.0 / 3.0
    static let minimumTitleFontSize: CGFloat = 56
    static let minimumAuthorFontSize: CGFloat = 48

    private struct Dimensions {
        let bookHeight: Float
        let spineThickness: Float
        /// The thinnest spine that still fits the book's lettering at its minimum sizes.
        let textThickness: Float
        let coverWidth: Float
    }

    let columns: Int
    /// Combined width of every column, each sized to its own longest book.
    let totalWidth: Float
    let slots: [Slot]

    init(books: [Book], coverRatios: [Int: Double] = [:]) {
        let columnCount = min(
            5, max(3, (books.count + Self.booksPerColumn - 1) / Self.booksPerColumn))
        columns = columnCount
        let lanes = (0..<columnCount)
            .map { column in
                books.enumerated()
                    .compactMap { index, book in
                        index % columnCount == column ? book : nil
                    }
            }
        let laneDimensions = lanes.map { lane in
            lane.map { book in
                Self.dimensions(for: book, coverRatio: coverRatios[book.id])
            }
        }
        // Each column fits its own longest book, so one long book does not widen every
        // column and push the camera back. The clearance includes the seeded horizontal
        // offset at both neighboring edges.
        let laneWidths = laneDimensions.map { lane in
            max(Self.minimumLaneWidth, (lane.map(\.bookHeight).max() ?? 0) + 0.24)
        }
        let totalWidth = laneWidths.reduce(0, +)
        self.totalWidth = totalWidth
        var laneCenters: [Float] = []
        var left = -totalWidth / 2
        for width in laneWidths {
            laneCenters.append(left + width / 2)
            left += width
        }
        var slots: [Slot] = []
        for (column, lane) in lanes.enumerated() {
            let dimensions = laneDimensions[column]
            // Reserve both covering layers before distributing the available stack height.
            let coreHeight = max(
                0, Self.maxStackHeight - Float(lane.count) * Self.coverWrapThickness * 2)
            // A crowded column gives up only thickness beyond what each spine's lettering
            // needs. Text-fit thickness shrinks only if even that exceeds the column.
            let textTotal = dimensions.reduce(0) { $0 + $1.textThickness }
            let floorScale = min(1, coreHeight / max(0.001, textTotal))
            let extraSpace = max(0, coreHeight - textTotal)
            let totalExtra = dimensions.reduce(0) {
                $0 + max(0, $1.spineThickness - $1.textThickness)
            }
            let extraScale = min(1, extraSpace / max(0.001, totalExtra))
            var top = Self.floorY
            for (row, book) in lane.enumerated() {
                let size = dimensions[row]
                let thickness =
                    size.textThickness * floorScale
                    + max(0, size.spineThickness - size.textThickness) * extraScale
                let collisionThickness = thickness + Self.coverWrapThickness * 2
                slots.append(
                    Slot(
                        book: book, column: column, row: row,
                        x: laneCenters[column],
                        restingY: top + collisionThickness / 2, bookHeight: size.bookHeight,
                        spineThickness: thickness, coverWidth: size.coverWidth))
                top += collisionThickness
            }
        }
        self.slots = slots.sorted {
            $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
        }
    }

    private static func dimensions(for book: Book, coverRatio: Double?) -> Dimensions {
        let pages = Float(min(1_400, max(100, book.pages ?? 320)))
        let seed = Float((UInt64(bitPattern: Int64(book.id)) &* 2_654_435_761) % 101) / 100
        // The upright height grows with the square root of page count. Matching cover width
        // to the image ratio then makes the front-board area grow with page count as well.
        // The raised floor keeps short books from reading as small next to long ones; the
        // unchanged ceiling keeps the widest lane, and therefore the camera, where it was.
        let coverScale = min(1.48, max(1.15, sqrt(pages / 500)))
        let naturalHeight = 2.25 * coverScale + (seed - 0.5) * 0.09
        let initialHeight = max(
            Self.minimumBookHeight, naturalHeight,
            Self.heightNeededForText(book, thickness: Self.minimumSpineThickness))
        let naturalThickness =
            Self.minimumSpineThickness + max(0, pages - 250) * 0.0009
            + seed * 0.025
        // Size tracks page count only loosely. A second per-book seed scales each book up by
        // as much as a quarter, so books of similar length still differ and few sit exactly
        // on the minimums. Scaling only upward keeps the text-fit sizes valid.
        let variety =
            Float((UInt64(bitPattern: Int64(book.id)) &* 40_503 &+ 12_345) % 1_000) / 999
        let textThickness = max(
            Self.minimumSpineThickness, Self.thicknessNeededForText(book, height: initialHeight))
        let spineThickness =
            max(min(naturalThickness, Self.maximumPageThickness), textThickness)
            * (1 + variety * 0.25)
        let lengthVariety = Float((UInt64(bitPattern: Int64(book.id)) &* 69_069) % 997) / 996
        let bookHeight = max(
            initialHeight * (1 + lengthVariety * 0.22),
            min(spineThickness * Self.minimumLengthToThickness, Self.maximumBookLength))
        let ratio =
            coverRatio.flatMap { value -> Float? in
                value.isFinite && value > 0 ? Float(value) : nil
            } ?? Self.fallbackCoverAspectRatio
        return Dimensions(
            bookHeight: bookHeight,
            spineThickness: spineThickness,
            textThickness: textThickness,
            coverWidth: bookHeight * ratio)
    }

    private static func heightNeededForText(_ book: Book, thickness: Float) -> Float {
        let font = CTFontCreateWithName(
            BookWallLocalSpine.fontName(for: book) as CFString, Self.minimumTitleFontSize, nil)
        let longest =
            (book.title + " " + book.author).split(whereSeparator: \.isWhitespace)
            .map { textWidth(String($0), font: font) }.max() ?? 0
        let usableWidth = Float(longest / (420 * 0.94 * 0.80))
        return max(Self.minimumBookHeight, usableWidth, thickness * Self.minimumLengthToThickness)
    }

    private static func thicknessNeededForText(_ book: Book, height: Float) -> Float {
        let availableWidth = CGFloat(height * 0.94 * 420 * 0.80)
        let title = CTFontCreateWithName(
            BookWallLocalSpine.fontName(for: book) as CFString, Self.minimumTitleFontSize, nil)
        let author = CTFontCreateWithName(
            BookWallLocalSpine.fontName(for: book) as CFString, Self.minimumAuthorFontSize, nil)
        let titleLines = wrappedLineCount(book.title, font: title, width: availableWidth)
        let authorLines = wrappedLineCount(book.author, font: author, width: availableWidth)
        let titleHeight = CGFloat(titleLines) * CTFontGetAscent(title) * 1.22
        let authorHeight = CGFloat(authorLines) * CTFontGetAscent(author) * 1.25
        return max(
            Self.minimumSpineThickness,
            Float(titleHeight / (420 * 0.88 * Self.titleShare)),
            Float(authorHeight / (420 * 0.88 * Self.authorShare)))
    }

    private static func wrappedLineCount(_ text: String, font: CTFont, width: CGFloat) -> Int {
        var lines = 1
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if !current.isEmpty && textWidth(candidate, font: font) > width {
                lines += 1
                current = String(word)
            } else {
                current = candidate
            }
        }
        return lines
    }

    private static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}
