import Foundation

struct SpineDimensions: Equatable {
    let width: CGFloat
    let height: CGFloat
}

struct ShelfPage: Identifiable {
    let id: Int
    let books: [Book]
    let dimensions: [Int: SpineDimensions]
    /// The lettering of each book drawn as a spine, measured with its dimensions.
    var letterings: [Int: SpineLettering] = [:]
}

enum ShelfLayout {
    static let gap: CGFloat = 18
    /// Packing uses the minimum gap; presentation shares remaining room between books.
    static func distributedGap(widths: [CGFloat], availableWidth: CGFloat) -> CGFloat {
        guard widths.count > 1 else { return 0 }
        return max(gap, (availableWidth - widths.reduce(0, +)) / CGFloat(widths.count - 1))
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
}
