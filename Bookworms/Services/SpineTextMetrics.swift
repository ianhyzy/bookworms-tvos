import SwiftUI
import UIKit

@MainActor
enum SpineTextMetrics {
    static let minimumTitleSize: CGFloat = 23
    static let titleEndPadding: CGFloat = 4
    static let crossSpinePadding: CGFloat = 22

    static func textLength(for book: Book, height: CGFloat) -> CGFloat {
        height - (book.format == nil ? 53 : 95)
    }

    static func typography(for book: Book, style: SpineStyle, dimensions: SpineDimensions)
        -> Typography
    {
        typography(
            title: style.uppercase ? book.spineTitle.uppercased() : book.spineTitle,
            author: book.author, fontName: style.fontName,
            length: textLength(for: book, height: dimensions.height),
            height: dimensions.width - crossSpinePadding,
            maximumTitle: min(58, dimensions.width * 0.72),
            maximumAuthor: min(22, dimensions.width * 0.32), hasSubtitle: book.spineSubtitle != nil,
            visualScale: SpineFontProfile.sizeScale(fontName: style.fontName, text: book.author),
            titleVisualScale: SpineFontProfile.sizeScale(
                fontName: style.fontName,
                text: style.uppercase ? book.spineTitle.uppercased() : book.spineTitle),
            compactAuthor: true)
    }

    private struct DimensionsKey: Hashable {
        let book: Book
        let style: SpineStyle
        let width: CGFloat
        let height: CGFloat
        let rowHeight: CGFloat
        let resolvedFont: String
    }
    private static var savedDimensions: [DimensionsKey: SpineDimensions] = [:]

    /// Uses spare shelf height when a main title cannot reach the legibility target.
    static func readableDimensions(
        for book: Book, style: SpineStyle,
        natural: SpineDimensions, rowHeight: CGFloat
    ) -> SpineDimensions {
        let key = DimensionsKey(
            book: book, style: style, width: natural.width, height: natural.height,
            rowHeight: rowHeight,
            resolvedFont: UIFont(name: style.fontName, size: 23)?.fontName ?? "system")
        if let cached = savedDimensions[key] { return cached }
        // Prefer extra height so page-count-based thickness changes only as a last resort.
        // The shelf’s top gap accommodates the focus lift; retain the book-shape bounds.
        let maximumHeight = max(
            natural.height,
            min(
                rowHeight,
                natural.width * ShelfLayout.slendernessRange.upperBound))
        var dimensions = natural
        while typography(for: book, style: style, dimensions: dimensions).titleSize
            < minimumTitleSize,
            dimensions.height < maximumHeight
        {
            dimensions = SpineDimensions(
                width: natural.width,
                height: min(maximumHeight, dimensions.height + 8))
        }
        // Extremely long titles may need a little more thickness after exhausting shelf height.
        // ShelfLayout includes this adjustment when packing pages, so wider books cannot overlap.
        let maximumWidth = max(
            natural.width,
            min(
                rowHeight * ShelfLayout.widthRange.upperBound,
                dimensions.height / ShelfLayout.slendernessRange.lowerBound))
        while typography(for: book, style: style, dimensions: dimensions).titleSize
            < minimumTitleSize,
            dimensions.width < maximumWidth
        {
            dimensions = SpineDimensions(
                width: min(maximumWidth, dimensions.width + 2),
                height: dimensions.height)
        }
        // Registering one font must not refit every other book during page packing.
        if savedDimensions.count >= 4096 { savedDimensions.removeAll(keepingCapacity: true) }
        savedDimensions[key] = dimensions
        return dimensions
    }

    private struct Key: Hashable {
        let text: String
        let fontName: String?
        let maximum: CGFloat
        let width: CGFloat
        let height: CGFloat
        let preferSingleLine: Bool
    }
    private static var values: [Key: CGFloat] = [:]

    // Resolve the same UIKit face used for measurement, including newly registered fonts.
    static func font(name: String, size: CGFloat) -> Font {
        Font(UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: .medium))
    }

    static func fittedSize(
        _ text: String, fontName: String?, maximum: CGFloat, width: CGFloat, height: CGFloat,
        preferSingleLine: Bool = false
    ) -> CGFloat {
        let resolvedFont = fontName.flatMap { UIFont(name: $0, size: maximum)?.fontName }
        let key = Key(
            text: text, fontName: resolvedFont, maximum: maximum, width: width,
            height: height, preferSingleLine: preferSingleLine)
        if let saved = values[key] { return saved }
        let measurement = PerformanceDiagnostics.begin("TypographyMiss")
        defer { measurement.end() }
        let result = measure(
            text, fontName: resolvedFont, maximum: maximum, width: width, height: height,
            preferSingleLine: preferSingleLine)
        if values.count >= 1024 { values.removeAll(keepingCapacity: true) }
        values[key] = result
        return result
    }

    struct Typography {
        let titleSize: CGFloat
        let authorSize: CGFloat
        let titleLength: CGFloat
        let authorLength: CGFloat
    }

    /// Fits both labels, favoring a four-point title lead without sacrificing author readability.
    static func typography(
        title: String, author: String, fontName: String, length: CGFloat,
        height: CGFloat, maximumTitle: CGFloat, maximumAuthor: CGFloat, hasSubtitle: Bool,
        visualScale: CGFloat = 1, titleVisualScale: CGFloat? = nil, compactAuthor: Bool = false
    ) -> Typography {
        let titleHeight = height * (hasSubtitle ? 0.68 : 1)
        func fit(titleFraction: CGFloat, singleLine: Bool) -> Typography {
            let titleLength = length * titleFraction
            let authorLength = length * (0.97 - titleFraction)
            let scale = min(1.06, max(0.94, visualScale))
            let titleScale = min(1.03, max(0.97, titleVisualScale ?? (1 + (scale - 1) / 2)))
            func adjusted(
                _ text: String, maximum: CGFloat, width: CGFloat, height: CGFloat,
                singleLine: Bool, scale: CGFloat, floor: CGFloat, isAuthor: Bool = false
            ) -> CGFloat {
                func fit(_ maximum: CGFloat) -> CGFloat {
                    if isAuthor && compactAuthor {
                        return SpineAuthorLayout.fittedSize(
                            text, fontName: fontName,
                            maximum: min(
                                maximum,
                                fittedSize(
                                    text, fontName: fontName, maximum: maximum,
                                    width: width, height: height)), width: width, height: height)
                    }
                    return fittedSize(
                        text, fontName: fontName, maximum: maximum,
                        width: width, height: height, preferSingleLine: singleLine)
                }
                let fitted = fit(maximum)
                // Shrinking never crosses an existing legibility floor; growth must fit the box.
                if scale < 1 { return max(min(floor, fitted), fitted * scale) }
                guard scale > 1 else { return fitted }
                let enlarged = fit(min(maximum * scale, fitted * scale))
                // A different half-point search grid must not make an enlargement shrink text.
                return max(fitted, enlarged)
            }
            return Typography(
                titleSize: adjusted(
                    title, maximum: maximumTitle,
                    width: titleLength - 2 * titleEndPadding, height: titleHeight,
                    singleLine: singleLine, scale: titleScale, floor: minimumTitleSize),
                authorSize: adjusted(
                    author, maximum: maximumAuthor,
                    width: authorLength, height: height, singleLine: false, scale: scale, floor: 16,
                    isAuthor: true),
                titleLength: titleLength, authorLength: authorLength)
        }

        var best = fit(titleFraction: 0.75, singleLine: true)
        let originalAuthorSize = best.authorSize
        let target = max(minimumTitleSize, originalAuthorSize + 4)
        if best.titleSize >= target { return best }

        // Try wrapping and borrowing unused author space before reducing either label.
        // A short candidate list keeps focus updates cheap and reuses the measurement cache.
        for fraction: CGFloat in [0.75, 0.78, 0.81, 0.84] {
            let candidate = fit(titleFraction: fraction, singleLine: false)
            guard candidate.authorSize >= min(16, originalAuthorSize) else { continue }
            if candidate.titleSize > best.titleSize { best = candidate }
            if best.titleSize >= target { return best }
        }

        // Sixteen points is a soft author floor: never shrink an already smaller label further.
        // If the spine is too narrow, readability takes priority over the four-point difference.
        let authorSize = min(best.authorSize, max(16, best.titleSize - 4))
        return Typography(
            titleSize: best.titleSize, authorSize: authorSize,
            titleLength: best.titleLength, authorLength: best.authorLength)
    }

    private static func nextSmallerSize(_ size: CGFloat) -> CGFloat {
        // Fractional starting sizes must still test the exact legibility target before going below it.
        if size > minimumTitleSize && size - 0.5 < minimumTitleSize { return minimumTitleSize }
        return size - 0.5
    }

    static func measure(
        _ text: String, fontName: String?, maximum: CGFloat, width: CGFloat,
        height: CGFloat, preferSingleLine: Bool
    ) -> CGFloat {
        // Prefer one line only when it needs modest shrinking; otherwise use the available width.
        if preferSingleLine {
            var size = maximum
            while size >= maximum * 0.75 {
                let font =
                    fontName.flatMap { UIFont(name: $0, size: size) }
                    ?? UIFont.systemFont(ofSize: size, weight: .medium)
                let bounds = (text as NSString).size(withAttributes: [.font: font])
                if bounds.width <= width * 0.96 && bounds.height <= height * 0.9 { return size }
                size = nextSmallerSize(size)
            }
        }
        var size = maximum
        while size > 8 {
            let font =
                fontName.flatMap { UIFont(name: $0, size: size) }
                ?? UIFont.systemFont(ofSize: size, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let bounds = (text as NSString)
                .boundingRect(
                    with: CGSize(width: width, height: 10000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes,
                    context: nil)
            let longestWord =
                text.split(whereSeparator: \.isWhitespace)
                .map { (String($0) as NSString).size(withAttributes: attributes).width }.max() ?? 0
            if bounds.height <= height * 0.9 && longestWord <= width * 0.96 { return size }
            size = nextSmallerSize(size)
        }
        return size
    }

}
