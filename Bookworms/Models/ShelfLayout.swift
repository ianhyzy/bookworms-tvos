import Foundation

struct SpineDimensions: Equatable {
    let width: CGFloat
    let height: CGFloat
}

struct ShelfPage: Identifiable {
    let id: Int
    let books: [Book]
    let dimensions: [Int: SpineDimensions]
}

enum ShelfLayout {
    static let gap: CGFloat = 18
    /// Packing uses the minimum gap; presentation shares remaining room between books.
    static func distributedGap(widths: [CGFloat], availableWidth: CGFloat) -> CGFloat {
        guard widths.count > 1 else { return 0 }
        return max(gap, (availableWidth - widths.reduce(0, +)) / CGFloat(widths.count - 1))
    }

    static func center(at index: Int, widths: [CGFloat], availableWidth: CGFloat) -> CGFloat {
        guard widths.indices.contains(index) else { return availableWidth / 2 }
        if widths.count == 1 { return availableWidth / 2 }
        return widths.prefix(index).reduce(0, +)
            + CGFloat(index) * distributedGap(widths: widths, availableWidth: availableWidth)
            + widths[index] / 2
    }

    static let heightRange = 0.76...0.96
    static let widthRange = 0.075...0.245
    static let slendernessRange = 3.1...11.5

    static func dimensions(for book: Book, among books: [Book], rowHeight: CGFloat)
        -> SpineDimensions
    {
        dimensions(for: book, medianPages: medianPageCount(in: books), rowHeight: rowHeight)
    }

    private static func medianPageCount(in books: [Book]) -> Double {
        let counts = books.compactMap(\.pages).filter { $0 > 0 }.map { Double(min(20000, $0)) }
            .sorted()
        guard !counts.isEmpty else { return 320 }
        let middle = counts.count / 2
        if counts.count.isMultiple(of: 2) {
            return (counts[middle - 1] + counts[middle]) / 2
        }
        return counts[middle]
    }

    private static func dimensions(for book: Book, medianPages median: Double, rowHeight: CGFloat)
        -> SpineDimensions
    {
        let row = max(100, min(1800, rowHeight.isFinite ? rowHeight : 500))
        let pages = book.pages.flatMap { $0 > 0 ? Double(min(20000, $0)) : nil } ?? median
        // Use book identity, not series identity, so related volumes do not share identical geometry.
        let seed = StyleColor.seed(book.id) ^ (StyleColor.seed(book.id) >> 13)
        let heightFraction =
            heightRange.lowerBound + Double(seed % 1009) / 1008
            * (heightRange.upperBound - heightRange.lowerBound)
        let height = row * heightFraction
        // A logarithmic curve retains differences in long books without clamping them all to one width.
        let ratio = min(16, max(0.0625, pages / max(1, median)))
        let widthFraction = 0.145 + 0.057 * log2(ratio)
        let lower = max(row * widthRange.lowerBound, height / slendernessRange.upperBound)
        let upper = min(row * widthRange.upperBound, height / slendernessRange.lowerBound)
        let width = min(upper, max(lower, row * widthFraction))
        return SpineDimensions(width: width, height: height)
    }

    static func plan(
        for books: [Book], width: CGFloat, rowHeight: CGFloat,
        adjust: ((Book, SpineDimensions) -> SpineDimensions)? = nil
    ) -> [ShelfPage] {
        func sized(_ book: Book, median: Double) -> SpineDimensions {
            let natural = dimensions(for: book, medianPages: median, rowHeight: rowHeight)
            return adjust?(book, natural) ?? natural
        }
        let available = max(1, width.isFinite ? width : 1)
        var groups: [[Book]] = []
        var current: [Book] = []
        // Pack conservatively, then compare thickness within each actual shelf.
        for book in books {
            let trial = current + [book]
            let median = medianPageCount(in: trial)
            let used =
                trial.reduce(CGFloat(0)) {
                    $0 + sized($1, median: median).width
                }
                + CGFloat(trial.count - 1) * gap
            if used > available && !current.isEmpty {
                groups.append(current)
                current = [book]
            } else {
                current = trial
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated()
            .map { index, group in
                let median = medianPageCount(in: group)
                let natural = group.map {
                    sized($0, median: median)
                }
                let sum = natural.reduce(CGFloat(0)) { $0 + $1.width }
                let scale = min(
                    1, max(0.01, (available - CGFloat(group.count - 1) * gap) / max(1, sum)))
                let sizes = zip(group, natural)
                    .map { book, size in
                        (
                            book.id,
                            SpineDimensions(width: size.width * scale, height: size.height * scale)
                        )
                    }
                return ShelfPage(
                    id: index, books: group, dimensions: Dictionary(uniqueKeysWithValues: sizes))
            }
    }

    static func pages(for books: [Book], width: CGFloat, rowHeight: CGFloat) -> [[Book]] {
        plan(for: books, width: width, rowHeight: rowHeight).map(\.books)
    }
}
