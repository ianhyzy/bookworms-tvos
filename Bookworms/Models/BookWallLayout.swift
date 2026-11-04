import Foundation
import UIKit

/// Stable slots for one page of a calendar year's books, including the space occupied by their
/// covers.
struct BookWallLayout: Sendable {
    struct Slot: Sendable {
        let book: Book
        let column: Int
        let row: Int
        let x: Float
        /// The width of the slot's column, which holds the column's longest book with room
        /// beside it for the book's seeded offset and turn.
        let laneWidth: Float
        let restingY: Float
        let bookHeight: Float
        let spineThickness: Float
        let coverWidth: Float
        /// The spine's lettering, measured by the shelf's rule at the spine's length and
        /// thickness in points at `pointsPerUnit`.
        let lettering: SpineLettering
        /// The wall's viewing scale, in points per scene unit, that `lettering` was measured at.
        let pointsPerUnit: Float

        /// The spine's central area, which focus targets use.
        var spineFaceWidth: Float { bookHeight * 0.94 }
        var spineFaceHeight: Float { spineThickness * 0.88 }
        /// The spine plane, which covers the casing's flat spine wall so the cloth's shading
        /// and the cover's fold reach its edges.
        var spineWallWidth: Float { bookHeight }
        var spineWallHeight: Float { spineThickness }
        var collisionThickness: Float { spineThickness + BookWallLayout.coverWrapThickness * 2 }
    }

    /// The height a wall's stacks are centered on, wherever its floor sits, so the camera and
    /// the backdrop's baked lighting keep one center for every wall.
    static let stackCenterY: Float = -0.25
    static let coverWrapThickness: Float = 0.006
    static let minimumLaneWidth: Float = 3.1
    /// The room stacks get first. A crowded column gives up thickness beyond what its lettering
    /// needs to stay this short, so a small wall frames close.
    static let shortStackHeight: Float = 8.5
    /// The room stacks grow to before their lettering would have to shrink.
    static let maximumStackHeight: Float = 12
    static let minimumSpineThickness: Float = 0.55
    /// Keeps each spine clearly longer than it is thick, so thick books do not read as blocks.
    static let minimumLengthToThickness: Float = 6
    /// Very long books stop thickening here (before per-book variety) so one book cannot
    /// widen its column enough to push the whole wall back.
    static let maximumPageThickness: Float = 1.3
    /// Thick books keep their thickness but stop lengthening here, so a doorstopper reads as
    /// chunky rather than widening its column.
    static let maximumBookLength: Float = 5.6
    /// About this many books share a column; fewer, taller columns fit the screen's height.
    static let booksPerColumn = 10
    static let maximumColumns = 4
    /// A year this size always fits one page: `maximumColumns` stacks of the thickest spine
    /// lettering can ask for, `maximumPageThickness` and its covering. It needs no measuring.
    static let booksThatAlwaysFit = 36
    /// A little under the scale any full page shows at (`BookWallScene.spinePointsPerUnit(for:)`),
    /// which the screen's height sets, whatever its books' lengths. `pages(of:typographies:)`
    /// measures at this one scale, so it measures each book once. A page's real scale is the same
    /// or larger, which letters its spines no thicker, so the page still fits.
    static let fullPagePointsPerUnit: Float = 65.9
    static let fallbackCoverAspectRatio: Float = 2.0 / 3.0
    /// The resting wall's scale at its spine plane, in points per scene unit, when the screen's
    /// height frames it: the largest the scale gets. `BookWallPreparation` lays a wall out at
    /// its own scale (`BookWallScene.spinePointsPerUnit(for:)`).
    static let nominalPointsPerUnit: Float = 90

    struct Dimensions: Sendable {
        /// The length the lettering search starts from, before it lengthens the spine.
        let startHeight: Float
        /// The length the book's lettering needs at `textThickness`, before variety.
        let readableHeight: Float
        let spineThickness: Float
        /// The thinnest spine that still fits the book's lettering at its minimum sizes.
        let textThickness: Float
        /// The page-count thickness with variety, which the book's shape keeps it at least
        /// `minimumLengthToThickness` times as long as.
        let pageShapeThickness: Float
        let lengthVariety: Float

        /// The book's length at `thickness`, from `readable`: variety scales it up by as much as
        /// 22%, so similar books still differ and few sit exactly on the minimums, and the book
        /// stays at least `minimumLengthToThickness` times as long as it is thick. Variety never
        /// takes a book past `maximumBookLength`: a spine lengthened for its lettering may
        /// already come close, and a longer book, with a board that grows with it, can be too
        /// large for the detail flight to frame. Within 22% of that maximum, variety spreads
        /// books over the room left, so they still differ rather than all stopping at it.
        func bookHeight(readable: Float, thickness: Float) -> Float {
            let maximum = BookWallLayout.maximumBookLength
            let room = min(0.22, max(0, maximum / max(0.001, readable) - 1))
            return min(
                maximum,
                max(
                    readable * (1 + lengthVariety * room),
                    max(thickness, pageShapeThickness) * BookWallLayout.minimumLengthToThickness))
        }
    }

    let columns: Int
    /// The room the stacks have: `shortStackHeight`, or up to `maximumStackHeight` for a wall
    /// whose lettering doesn't fit that.
    let stackHeight: Float
    /// Where the bottom books rest, which is the shelf's top.
    var floorY: Float { Self.stackCenterY - stackHeight / 2 }
    /// Combined width of every column, each sized to its own longest book.
    let totalWidth: Float
    let slots: [Slot]
    /// The viewing scale the wall's lettering was measured at, in points per scene unit.
    let pointsPerUnit: Float

    /// Lays out `books`, sizing each so its lettering reads in the face it draws in at
    /// `pointsPerUnit`, and measures that lettering. `typographies` gives the face for books
    /// with a companion design or a series source (`SeriesDesigns`), and other books use their
    /// genre face.
    ///
    /// `measured` gives sizes already measured at this `pointsPerUnit`, which it doesn't measure
    /// again.
    ///
    /// Measures text, so call it while the wall is prepared, never during focus changes.
    init(
        books: [Book], coverRatios: [Int: Double] = [:],
        typographies: [Int: BookWallLocalSpine.Typography] = [:],
        pointsPerUnit: Float = nominalPointsPerUnit, measured: [Int: Dimensions] = [:]
    ) {
        self.pointsPerUnit = pointsPerUnit
        func typography(of book: Book) -> BookWallLocalSpine.Typography {
            typographies[book.id] ?? BookWallLocalSpine.typography(for: book, design: nil)
        }
        let sizes = books.map { book in
            measured[book.id]
                ?? Self.dimensions(
                    for: book, typography: typography(of: book), pointsPerUnit: pointsPerUnit)
        }
        // A small wall keeps three columns unless their stacks would be too tall to letter.
        let wanted = max(3, (books.count + Self.booksPerColumn - 1) / Self.booksPerColumn)
        let columnCount =
            (min(wanted, Self.maximumColumns)..<Self.maximumColumns)
            .first {
                Self.tallestStack(sizes, columns: $0, \.textThickness) <= Self.maximumStackHeight
            }
            ?? Self.maximumColumns
        columns = columnCount
        let lanes = (0..<columnCount)
            .map { column in
                books.enumerated()
                    .compactMap { index, book in
                        index % columnCount == column ? book : nil
                    }
            }
        let laneDimensions = (0..<columnCount)
            .map { column in
                sizes.enumerated()
                    .compactMap { index, size in
                        index % columnCount == column ? size : nil
                    }
            }
        // A crowded column first gives up thickness beyond what each spine's lettering needs, to
        // fit `shortStackHeight`. A wall whose lettering needs more room takes what its spines
        // want, up to `maximumStackHeight`. Only past that, which pages prevent, does every spine
        // in a column shrink by one factor, below its lettering's needs.
        let lettered = Self.tallestStack(sizes, columns: columnCount, \.textThickness)
        let stackHeight =
            lettered <= Self.shortStackHeight
            ? Self.shortStackHeight
            : min(
                Self.maximumStackHeight,
                Self.tallestStack(sizes, columns: columnCount, \.spineThickness))
        self.stackHeight = stackHeight
        let laneThicknesses = lanes.indices.map { column in
            let dimensions = laneDimensions[column]
            // Reserve both covering layers before distributing the available stack height.
            let coreHeight = max(
                0, stackHeight - Float(lanes[column].count) * Self.coverWrapThickness * 2)
            let textTotal = dimensions.reduce(0) { $0 + $1.textThickness }
            let floorScale = min(1, coreHeight / max(0.001, textTotal))
            let extraSpace = max(0, coreHeight - textTotal)
            let totalExtra = dimensions.reduce(0) {
                $0 + max(0, $1.spineThickness - $1.textThickness)
            }
            let extraScale = min(1, extraSpace / max(0.001, totalExtra))
            return dimensions.map {
                $0.textThickness * floorScale
                    + max(0, $0.spineThickness - $0.textThickness) * extraScale
            }
        }
        // A spine squeezed thinner than its lettering needs letters a title that its thickness
        // holds back, so it keeps only the length at which that title stops growing.
        let laneLengths = lanes.indices.map { column in
            lanes[column].indices
                .map { row in
                    let size = laneDimensions[column][row]
                    let thickness = laneThicknesses[column][row]
                    let readable =
                        thickness < size.textThickness
                        ? Self.shortestLength(
                            for: lanes[column][row], typography: typography(of: lanes[column][row]),
                            from: size.startHeight, to: size.readableHeight, thickness: thickness,
                            pointsPerUnit: pointsPerUnit)
                        : size.readableHeight
                    return size.bookHeight(readable: readable, thickness: thickness)
                }
        }
        // Each column fits its own longest book, so one long book does not widen every
        // column and push the camera back. The clearance includes the seeded horizontal
        // offset at both neighboring edges.
        let laneWidths = laneLengths.map { lane in
            max(Self.minimumLaneWidth, (lane.max() ?? 0) + 0.24)
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
            var top = Self.stackCenterY - stackHeight / 2
            for (row, book) in lane.enumerated() {
                let thickness = laneThicknesses[column][row]
                let length = laneLengths[column][row]
                let collisionThickness = thickness + Self.coverWrapThickness * 2
                slots.append(
                    Slot(
                        book: book, column: column, row: row,
                        x: laneCenters[column], laneWidth: laneWidths[column],
                        restingY: top + collisionThickness / 2, bookHeight: length,
                        spineThickness: thickness,
                        coverWidth: length * Self.coverRatio(coverRatios[book.id]),
                        lettering: Self.lettering(
                            for: book, typography: typography(of: book),
                            length: length, thickness: thickness,
                            pointsPerUnit: pointsPerUnit),
                        pointsPerUnit: pointsPerUnit))
                top += collisionThickness
            }
        }
        self.slots = slots.sorted {
            $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
        }
    }

    private static func coverRatio(_ ratio: Double?) -> Float {
        ratio.flatMap { $0.isFinite && $0 > 0 ? Float($0) : nil } ?? fallbackCoverAspectRatio
    }

    /// The height of the tallest of `columns` stacks of `sizes` at the given `thickness`, with
    /// the books dealt across the columns in order.
    private static func tallestStack(
        _ sizes: [Dimensions], columns: Int, _ thickness: KeyPath<Dimensions, Float>
    ) -> Float {
        var stacks = [Float](repeating: 0, count: columns)
        for (index, size) in sizes.enumerated() {
            stacks[index % columns] += size[keyPath: thickness] + coverWrapThickness * 2
        }
        return stacks.max() ?? 0
    }

    /// `books`, in order, split into pages that each hold as many of the next books as
    /// `maximumColumns` stacks of `maximumStackHeight` letter without a squeeze, and the sizes it
    /// measured at `fullPagePointsPerUnit`, which `init` can reuse. A year of up to
    /// `booksThatAlwaysFit` books measures nothing. Returns `nil` when the task is cancelled.
    ///
    /// Measures each book once, so its cost is one pass over the year.
    static func pages(
        of books: [Book], typographies: [Int: BookWallLocalSpine.Typography] = [:]
    ) -> (ranges: [Range<Int>], measured: [Int: Dimensions])? {
        guard books.count > booksThatAlwaysFit else {
            return (books.isEmpty ? [] : [books.indices], [:])
        }
        var ranges: [Range<Int>] = []
        var measured: [Int: Dimensions] = [:]
        var start = 0
        var stacks = [Float](repeating: 0, count: maximumColumns)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else { return nil }
            let size = dimensions(
                for: book,
                typography: typographies[book.id]
                    ?? BookWallLocalSpine.typography(for: book, design: nil),
                pointsPerUnit: fullPagePointsPerUnit)
            measured[book.id] = size
            let height = size.textThickness + coverWrapThickness * 2
            if stacks[(index - start) % maximumColumns] + height > maximumStackHeight {
                ranges.append(start..<index)
                start = index
                stacks = stacks.map { _ in 0 }
            }
            stacks[(index - start) % maximumColumns] += height
        }
        ranges.append(start..<books.count)
        return (ranges, measured)
    }

    static func dimensions(
        for book: Book, typography: BookWallLocalSpine.Typography, pointsPerUnit: Float
    ) -> Dimensions {
        let pages = Float(min(1_400, max(100, book.pages ?? 320)))
        let seed = Float(StyleColor.seed(book.id) % 101) / 100
        // The upright height grows with the square root of page count. Matching cover width
        // to the image ratio then makes the front-board area grow with page count as well.
        // The raised floor keeps short books from reading as small next to long ones; the
        // unchanged ceiling keeps the widest lane, and therefore the camera, where it was.
        let coverScale = min(1.48, max(1.15, sqrt(pages / 500)))
        let naturalHeight = 2.25 * coverScale + (seed - 0.5) * 0.09
        let naturalThickness =
            Self.minimumSpineThickness + max(0, pages - 250) * 0.0009
            + seed * 0.025
        let pageThickness = max(
            Self.minimumSpineThickness, min(naturalThickness, Self.maximumPageThickness))
        let startHeight = max(
            naturalHeight, Self.minimumSpineThickness * Self.minimumLengthToThickness)
        let readable = Self.readableSize(
            for: book, typography: typography, height: startHeight,
            thickness: pageThickness, pointsPerUnit: pointsPerUnit)
        // Size tracks page count only loosely. A second per-book seed scales each book up by
        // as much as a quarter, so books of similar length still differ and few sit exactly
        // on the minimums. Scaling only upward keeps the text-fit sizes valid.
        let variety =
            Float((UInt64(bitPattern: Int64(book.id)) &* 40_503 &+ 12_345) % 1_000) / 999
        return Dimensions(
            startHeight: startHeight, readableHeight: readable.height,
            spineThickness: max(pageThickness, readable.thickness) * (1 + variety * 0.25),
            textThickness: readable.thickness,
            pageShapeThickness: pageThickness * (1 + variety * 0.25),
            lengthVariety: Float((UInt64(bitPattern: Int64(book.id)) &* 69_069) % 997) / 996)
    }

    /// The length, and the thinnest thickness, at which `book`'s title letters at
    /// `SpineTextMetrics.minimumTitleSize` or larger on one or two lines at `pointsPerUnit`,
    /// grown as the shelf's `SpineTextMetrics.readableDimensions` grows a spine: from `height`,
    /// it lengthens in 8-point steps up to `maximumBookLength` at the page-count `thickness`,
    /// then thickens in 2-point steps up to a sixth of its length. A title that letters at the
    /// minimum without growing needs only `minimumSpineThickness` if it letters there too. A
    /// title that can't reach the minimum takes the thickest spine, which the book's shape then
    /// holds at `maximumBookLength`; its lettering may take a third line. The length is the
    /// shortest step that letters the title as large at the page-count `thickness`, the
    /// thinnest the spine is drawn unless its column squeezes it, so it keeps room under
    /// `maximumBookLength` for its length variety. Measuring it at `minimumSpineThickness`
    /// would let a title too long for two lines, which a thicker spine narrows, letter below
    /// the minimum.
    ///
    /// Each search halves the steps it has left rather than measuring every step, since along
    /// each search a longer or thicker spine letters a title no smaller.
    private static func readableSize(
        for book: Book, typography: BookWallLocalSpine.Typography, height: Float,
        thickness: Float, pointsPerUnit: Float
    ) -> (height: Float, thickness: Float) {
        func reads(_ length: Float, _ across: Float) -> Bool {
            titleSize(
                for: book, typography: typography, length: length, thickness: across,
                pointsPerUnit: pointsPerUnit) >= SpineTextMetrics.minimumTitleSize
        }
        let length = first(
            from: height, to: max(height, maximumBookLength), by: 8 / pointsPerUnit
        ) { reads($0, thickness) }
        var across = first(
            from: thickness, to: max(thickness, length / minimumLengthToThickness),
            by: 2 / pointsPerUnit
        ) { reads(length, $0) }
        if across == thickness, thickness > minimumSpineThickness,
            reads(length, minimumSpineThickness)
        {
            across = minimumSpineThickness
        }
        return (
            shortestLength(
                for: book, typography: typography, from: height, to: length,
                thickness: max(thickness, across), pointsPerUnit: pointsPerUnit),
            across
        )
    }

    /// The shortest of the 8-point steps from `start` to `end` at which `book`'s title, on one
    /// or two lines on a spine `thickness` across, letters as large as at `end`, or at
    /// `SpineTextMetrics.minimumTitleSize` if it reaches that sooner.
    private static func shortestLength(
        for book: Book, typography: BookWallLocalSpine.Typography, from start: Float,
        to end: Float, thickness: Float, pointsPerUnit: Float
    ) -> Float {
        func size(_ length: Float) -> CGFloat {
            titleSize(
                for: book, typography: typography, length: length, thickness: thickness,
                pointsPerUnit: pointsPerUnit)
        }
        let target = min(SpineTextMetrics.minimumTitleSize, size(end))
        return first(from: start, to: max(start, end), by: 8 / pointsPerUnit) {
            size($0) >= target
        }
    }

    /// The first of `start`, `start + step`, ... up to `end` at which `holds` is true, or `end`
    /// when none is. Halves the steps it has left rather than testing every step, so `holds`
    /// must stay true once it is.
    private static func first(
        from start: Float, to end: Float, by step: Float, _ holds: (Float) -> Bool
    ) -> Float {
        func value(_ index: Int) -> Float { min(end, start + Float(index) * step) }
        guard !holds(start), end > start else { return start }
        var lower = 0
        var upper = Int(((end - start) / step).rounded(.up))
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if holds(value(middle)) { upper = middle } else { lower = middle }
        }
        return value(upper)
    }

    private static func titleSize(
        for book: Book, typography: BookWallLocalSpine.Typography, length: Float,
        thickness: Float, pointsPerUnit: Float
    ) -> CGFloat {
        lettering(
            for: book, typography: typography, length: length, thickness: thickness,
            pointsPerUnit: pointsPerUnit, maximumLines: 2
        )
        .titleSize
    }

    /// `book`'s lettering on a spine `length` by `thickness` scene units in `typography`,
    /// measured in points at `pointsPerUnit` by the rule the shelf letters with
    /// (`SpineTextMetrics.measure`), so a spine letters the same in both views at the same frame.
    static func lettering(
        for book: Book, typography: BookWallLocalSpine.Typography, length: Float,
        thickness: Float, pointsPerUnit: Float, maximumLines: Int = 3
    ) -> SpineLettering {
        let text = SpineTextMetrics.text(of: book, uppercase: typography.uppercase)
        return SpineTextMetrics.measure(
            title: text.title, author: text.author,
            fontName: typography.loadedFont(size: SpineTextMetrics.minimumTitleSize)?.fontName,
            font: { typography.font(size: $0) },
            length: SpineTextMetrics.letteredLength(
                for: book, length: CGFloat(length * pointsPerUnit),
                thickness: CGFloat(thickness * pointsPerUnit)),
            thickness: CGFloat(thickness * pointsPerUnit), maximumLines: maximumLines)
    }
}
