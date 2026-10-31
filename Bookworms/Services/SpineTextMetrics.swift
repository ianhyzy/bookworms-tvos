import SwiftUI
import UIKit

/// The lettering a spine draws: the title's lines, the author's form, their sizes, and their
/// widths, in points, in a spine lying flat with its head on the left.
///
/// The shelf measures it when its pages are prepared
/// (`SpineTextMetrics.lettering(for:style:dimensions:)`) and `SpineView` draws it; Book Wall
/// measures it when it lays out the wall (`BookWallLayout`) and `BookWallSpineTexture` draws
/// it. Neither focus changes nor view updates measure text.
struct SpineLettering: Equatable, Sendable {
    /// The PostScript name of the face it was measured in, or `nil` for a system face, which
    /// stands in for a face that wasn't registered at the time.
    let fontName: String?
    /// The title's lines, joined by line breaks. Lines break only between words.
    let title: String
    let titleSize: CGFloat
    let titleWidth: CGFloat
    /// The author's form: the name on one line, on two lines joined by a line break, or the
    /// surname.
    let author: String
    let authorSize: CGFloat
    let authorWidth: CGFloat
    /// Whether `author` fits `authorWidth` whole. A surname too long for its room truncates.
    let authorFits: Bool
    /// The length along the spine that the lettering takes: the spine's length less the format
    /// icon's room at the tail.
    let length: CGFloat
    /// The margin at each end of `length`.
    let inset: CGFloat
}

/// Measures spine lettering by the iPhone and Mac app's rule, with the Apple TV's minimum
/// sizes, for every view that draws a spine: the shelf, Ambient, and Book Wall.
@MainActor
enum SpineTextMetrics {
    /// The smallest title the shelf aims for. `readableDimensions` lengthens, then thickens, a
    /// spine whose title would letter smaller.
    nonisolated static let minimumTitleSize: CGFloat = 23
    /// The smallest author size. Only a surname too long for the author's widest room truncates.
    nonisolated static let minimumAuthorSize: CGFloat = 16
    /// How much larger than the author the title stays, where the author's minimum allows.
    nonisolated static let titleLead: CGFloat = 4
    nonisolated static let formatIconSize: CGFloat = 18
    /// The tail length the format icon takes: the icon and its margin from the spine's end.
    nonisolated static let formatIconRoom: CGFloat = 38

    /// The length along a spine `height` long that `book`'s lettering takes.
    nonisolated static func letteredLength(for book: Book, height: CGFloat) -> CGFloat {
        max(0, height - (book.format == nil ? 0 : formatIconRoom))
    }

    /// The format icon's center along a spine `height` long, lying flat with its head on the
    /// left, so it reads in the lettering's direction. It sits in the room `letteredLength`
    /// leaves at the tail.
    nonisolated static func formatIconCenter(height: CGFloat) -> CGFloat {
        height - (formatIconRoom - formatIconSize) - formatIconSize / 2
    }

    /// The spine's title and author as every view letters them: the title up to its first
    /// colon, as on the iPhone, in capitals when `uppercase`, and the author shortened by
    /// `SpineView.shortAuthor(_:)`.
    nonisolated static func text(of book: Book, uppercase: Bool) -> (title: String, author: String)
    {
        (
            uppercase ? book.spineTitle.uppercased() : book.spineTitle,
            SpineView.shortAuthor(book.author)
        )
    }

    /// `book`'s lettering on a spine of `dimensions`, from a bounded cache.
    static func lettering(
        for book: Book, style: SpineStyle, dimensions: SpineDimensions, maximumLines: Int = 3
    ) -> SpineLettering {
        let spine = text(of: book, uppercase: style.uppercase)
        return lettering(
            title: spine.title, author: spine.author, fontName: style.fontName,
            length: letteredLength(for: book, height: dimensions.height),
            thickness: dimensions.width, maximumLines: maximumLines)
    }

    private struct Key: Hashable {
        let title: String
        let author: String
        let font: String?
        let length: CGFloat
        let thickness: CGFloat
        let maximumLines: Int
    }
    private static var letterings: [Key: SpineLettering] = [:]

    /// `title` and `author` lettered in `length` along a spine `thickness` across, in at most
    /// `maximumLines` title lines. A third line applies only when two lines can't reach
    /// `minimumTitleSize`.
    static func lettering(
        title: String, author: String, fontName: String, length: CGFloat, thickness: CGFloat,
        maximumLines: Int = 3
    ) -> SpineLettering {
        let resolved = UIFont(name: fontName, size: minimumTitleSize)?.fontName
        let key = Key(
            title: title, author: author, font: resolved, length: length, thickness: thickness,
            maximumLines: maximumLines)
        if let saved = letterings[key] { return saved }
        let measurement = PerformanceDiagnostics.begin("TypographyMiss")
        defer { measurement.end() }
        let result = measure(
            title: title, author: author, fontName: resolved,
            font: { uiFont(name: resolved, size: $0) }, length: length, thickness: thickness,
            maximumLines: maximumLines)
        if letterings.count >= 4096 { letterings.removeAll(keepingCapacity: true) }
        letterings[key] = result
        return result
    }

    /// `title` and `author` lettered in `length` along a spine `thickness` across, in at most
    /// `maximumLines` title lines, in `font` at each size. `fontName` names the face in the
    /// result. Uncached, and safe off the main actor, so Book Wall measures while it prepares.
    nonisolated static func measure(
        title: String, author: String, fontName: String?, font: @escaping (CGFloat) -> UIFont,
        length: CGFloat, thickness: CGFloat, maximumLines: Int = 3
    ) -> SpineLettering {
        // The rule asks for the same few sizes many times.
        var fonts: [CGFloat: UIFont] = [:]
        let cachedFont = { (size: CGFloat) -> UIFont in
            if let saved = fonts[size] { return saved }
            let made = font(size)
            fonts[size] = made
            return made
        }
        func rule(_ lines: Int) -> SpineLettering {
            LetteringRule(
                fontName: fontName, font: cachedFont, title: title, author: author, length: length,
                thickness: thickness, maximumLines: lines
            )
            .lettering()
        }
        var result = rule(min(maximumLines, 2))
        if maximumLines > 2, result.titleSize < minimumTitleSize {
            let threeLines = rule(maximumLines)
            if threeLines.titleSize > result.titleSize { result = threeLines }
        }
        return result
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

    /// Uses spare shelf height when a title cannot reach `minimumTitleSize`.
    ///
    /// Growth measures the title on one or two lines, so a spine lengthens, then thickens,
    /// before its title takes a third line.
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
        while lettering(for: book, style: style, dimensions: dimensions, maximumLines: 2)
            .titleSize < minimumTitleSize,
            dimensions.height < maximumHeight
        {
            dimensions = SpineDimensions(
                width: natural.width,
                height: min(maximumHeight, dimensions.height + 8))
        }
        // Extremely long titles may need a little more thickness after exhausting shelf height.
        // `BookPresentation.pages` packs with this adjustment, so wider books cannot overlap.
        let maximumWidth = max(
            natural.width,
            min(
                rowHeight * ShelfLayout.widthRange.upperBound,
                dimensions.height / ShelfLayout.slendernessRange.lowerBound))
        while lettering(for: book, style: style, dimensions: dimensions, maximumLines: 2)
            .titleSize < minimumTitleSize,
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

    /// The face `SpineLettering.fontName` names, at `size`, or the system font.
    static func font(name: String?, size: CGFloat) -> Font {
        Font(uiFont(name: name, size: size))
    }

    nonisolated static func uiFont(name: String?, size: CGFloat) -> UIFont {
        name.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.systemFont(ofSize: size, weight: .medium)
    }
}

/// The iPhone and Mac app's spine lettering rule (`SpineView.lettering(length:thickness:)` and
/// its `SpineLettering` layout, in `ios/Bookworms/Views/SpineView.swift`), measured with UIKit
/// so the shelf can size books before it draws them. Keep the shares the same in both apps.
///
/// The Apple TV adds its safeguards: authors letter at 16 points or more, the title stays 4
/// points larger than the author where that minimum allows, and a title takes a third line
/// only when one or two lines can't reach 23 points.
private struct LetteringRule {
    let fontName: String?
    let makeFont: (CGFloat) -> UIFont
    let title: String
    let author: String
    let length: CGFloat
    let maximumLines: Int
    let inset: CGFloat
    /// The row's height and the title's starting size.
    let box: CGFloat
    let spacing: CGFloat
    let authorShare: CGFloat
    let authorCap: CGFloat
    let least: CGFloat
    let large: CGFloat
    /// The row's width between the insets.
    let width: CGFloat

    init(
        fontName: String?, font: @escaping (CGFloat) -> UIFont, title: String, author: String,
        length: CGFloat, thickness: CGFloat, maximumLines: Int
    ) {
        self.fontName = fontName
        makeFont = font
        self.title = title
        self.author = author
        self.length = length
        self.maximumLines = maximumLines
        inset = length * 0.035 + thickness * 0.25
        box = thickness * 0.88
        spacing = thickness * 0.3
        authorShare = length * 0.24
        authorCap = length * 0.4
        least = max(
            SpineTextMetrics.minimumAuthorSize, min(length * 0.04, max(7, thickness * 0.275)))
        large = max(least, min(length * 0.04, thickness * 0.5))
        width = max(0, length - 2 * inset)
    }

    struct Author {
        let text: String
        let size: CGFloat
        let width: CGFloat
        let fits: Bool
    }

    struct Row {
        let title: (lines: [String], size: CGFloat)
        let titleWidth: CGFloat
        let author: Author
    }

    func lettering() -> SpineLettering {
        // The author's large forms apply only where the title loses no size to them and stays
        // at least 1.4 times their size. The 1% absorbs the half-point size grid.
        let largeRow = row(large: true, least: least)
        var chosen = row(large: false, least: least)
        if largeRow.title.size >= 0.99 * chosen.title.size,
            largeRow.title.size >= 1.4 * large
        {
            chosen = largeRow
        }
        let lead = max(
            SpineTextMetrics.minimumAuthorSize, chosen.title.size - SpineTextMetrics.titleLead)
        if chosen.author.size > lead { chosen = row(large: false, least: lead) }
        return SpineLettering(
            fontName: fontName, title: chosen.title.lines.joined(separator: "\n"),
            titleSize: chosen.title.size, titleWidth: chosen.titleWidth,
            author: chosen.author.text, authorSize: chosen.author.size,
            authorWidth: chosen.author.width, authorFits: chosen.author.fits, length: length,
            inset: inset)
    }

    /// The row with the author's large forms allowed or not, and its smaller forms at `least`.
    ///
    /// The title gets the width its one line needs at the box's size first. The author gets
    /// the rest, at least `authorShare`, or its surname's width if that is wider, and at most
    /// `authorCap`, but no more than its form needs, and the title takes back what it leaves.
    private func row(large: Bool, least: CGFloat) -> Row {
        let free = max(0, width - spacing)
        let surname = widest([SpineView.surname(author) ?? author], size: least)
        let share = max(authorShare, min(authorCap, surname))
        let offered = min(
            authorCap, max(min(share, free), free - widest([title], size: box)))
        let author = self.author(in: offered, large: large, least: least)
        let used = min(offered, author.width)
        return Row(title: titleFit(free - used), titleWidth: free - used, author: author)
    }

    /// The author's first form that fits `width` and the box: on one line, on two, and as the
    /// surname, at the large size where `large` allows, then at `least`. Failing those, the
    /// surname at `least`, truncated.
    private func author(in width: CGFloat, large: Bool, least: CGFloat) -> Author {
        let forms = [author, SpineView.twoLines(author), SpineView.surname(author)]
            .compactMap { $0 }
        for size in large ? [self.large, least] : [least] {
            for form in forms {
                let lines = form.components(separatedBy: "\n")
                if fits(lines, size: size, width: width) {
                    return Author(
                        text: form, size: size, width: widest(lines, size: size), fits: true)
                }
            }
        }
        return Author(
            text: SpineView.surname(author) ?? author, size: least, width: width, fits: false)
    }

    /// The title's largest size and its lines in `width`: one line or two, whichever is
    /// larger, and three, where `maximumLines` allows, only when neither reaches the minimum.
    /// Lines break between words alone, so a title without spaces, such as a Chinese one,
    /// keeps to one line.
    private func titleFit(_ width: CGFloat) -> (lines: [String], size: CGFloat) {
        let words = title.split(separator: " ").map(String.init)
        var best = fit(words, into: 1, width: width)
        for count in 2...3 where words.count >= count && count <= maximumLines {
            if count == 3 && best.size >= SpineTextMetrics.minimumTitleSize { break }
            let candidate = fit(words, into: count, width: width)
            if candidate.size > best.size { best = candidate }
        }
        return best
    }

    /// The largest size on the half-point grid, at most the box's, at which `words` fit
    /// `count` lines in `width` and the box, broken where the widest line is narrowest.
    private func fit(_ words: [String], into count: Int, width: CGFloat) -> (
        lines: [String], size: CGFloat
    ) {
        let candidates = Self.breaks(words[...], into: count)
        let lines =
            candidates.min { widest($0, size: box) < widest($1, size: box) } ?? [title]
        let lineHeight = font(box).lineHeight / box
        let widestLine = widest(lines, size: box)
        var size = min(
            box, box / (CGFloat(count) * lineHeight),
            widestLine > 0 ? box * width / widestLine : box)
        size = (size * 2).rounded(.down) / 2
        // Fonts with optical sizes don't scale exactly; confirm at the size drawn.
        while size > 0.5, !fits(lines, size: size, width: width) { size -= 0.5 }
        return (lines, size)
    }

    /// Every way to break `words` into `count` lines of whole words.
    private static func breaks(_ words: ArraySlice<String>, into count: Int) -> [[String]] {
        guard count > 1 else { return [[words.joined(separator: " ")]] }
        guard words.count >= count else { return [] }
        return (words.startIndex + 1...words.endIndex - count + 1)
            .flatMap { end in
                breaks(words[end...], into: count - 1)
                    .map {
                        [words[..<end].joined(separator: " ")] + $0
                    }
            }
    }

    private func fits(_ lines: [String], size: CGFloat, width: CGFloat) -> Bool {
        widest(lines, size: size) <= width
            && CGFloat(lines.count) * font(size).lineHeight <= box
    }

    private func widest(_ lines: [String], size: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(size)]
        return lines.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
    }

    private func font(_ size: CGFloat) -> UIFont { makeFont(size) }
}
