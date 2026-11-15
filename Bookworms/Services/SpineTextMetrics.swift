import CoreText
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
    /// The height each title line takes: its font's line height, or less where the letters of a
    /// title on two or three lines fill the box.
    let titlePitch: CGFloat
    /// How far down each title line draws from the middle of its pitch, so that a filled
    /// title's letters, not their line boxes, sit centered across the spine.
    let titleShift: CGFloat
    /// The author's form: the name on one line, on two lines joined by a line break, or the
    /// surname. A two-line name's lines center on each other.
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
    /// How many times larger two lines must letter a title to take it off one line.
    nonisolated static let twoLineGain: CGFloat = 1.25
    /// The share of the lettered length below which a one-line title is too small to prefer, so
    /// the title takes whichever of one line and two is larger.
    nonisolated static let oneLineFloor: CGFloat = 0.045
    /// The share of the lettering's box that the letters of a title on two or three lines fill,
    /// where its width allows.
    nonisolated static let twoLineFill: CGFloat = 0.85
    /// The gap between a filled title's lines, as a share of its letters' height.
    nonisolated static let lineGap: CGFloat = 0.2
    nonisolated static let formatIconSize: CGFloat = 18
    /// The format icon's margin from the tail end of a spine without stamped bands.
    nonisolated static let formatIconMargin: CGFloat = 20
    /// The gap between the format icon and the nearer line of a stamped tail band, so the icon
    /// reads apart from the band instead of against it.
    nonisolated static let formatIconBandGap: CGFloat = 12

    /// The format icon's margin from the tail end of `book`'s spine, `length` long and
    /// `thickness` across. On a spine with stamped bands (`SpineView.stamps(_:)`), the icon
    /// clears the tail band by `formatIconBandGap`.
    nonisolated static func formatIconMargin(
        for book: Book, length: CGFloat, thickness: CGFloat
    ) -> CGFloat {
        guard SpineView.stamps(book) else { return formatIconMargin }
        let band = SpineView.bands(length: length, thickness: thickness)
        // The band's lines are centered in its slot, which is `inset` from the tail end.
        let bandEdge = band.inset + band.slot / 2 + band.line
        return max(formatIconMargin, bandEdge + formatIconBandGap)
    }

    /// The tail length the format icon takes on `book`'s spine, `length` long and `thickness`
    /// across: the icon and its margin from the tail end, or none without a format.
    nonisolated static func formatIconRoom(
        for book: Book, length: CGFloat, thickness: CGFloat
    ) -> CGFloat {
        guard book.format != nil else { return 0 }
        return formatIconMargin(for: book, length: length, thickness: thickness) + formatIconSize
    }

    /// The length along `book`'s spine, `length` long and `thickness` across, that its lettering
    /// takes: the length less the format icon's room.
    nonisolated static func letteredLength(
        for book: Book, length: CGFloat, thickness: CGFloat
    ) -> CGFloat {
        max(0, length - formatIconRoom(for: book, length: length, thickness: thickness))
    }

    /// The format icon's center along `book`'s spine, `length` long and `thickness` across,
    /// measured from the head. It sits in the room `letteredLength` leaves at the tail.
    nonisolated static func formatIconCenter(
        for book: Book, length: CGFloat, thickness: CGFloat
    ) -> CGFloat {
        length - formatIconMargin(for: book, length: length, thickness: thickness)
            - formatIconSize / 2
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
        for book: Book, style: SpineStyle, dimensions: SpineDimensions
    ) -> SpineLettering {
        let spine = text(of: book, uppercase: style.uppercase)
        return lettering(
            title: spine.title, author: spine.author, fontName: style.fontName,
            length: letteredLength(
                for: book, length: dimensions.height, thickness: dimensions.width),
            thickness: dimensions.width)
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
    /// `maximumLines` title lines. A third line applies only when neither one line nor two
    /// filled lines reach `minimumTitleSize`.
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
        LetteringRule(
            fontName: fontName, font: cached(font), title: title, author: author, length: length,
            thickness: thickness, maximumLines: maximumLines
        )
        .lettering()
    }

    /// The size `title` letters at beside `author`, in `length` along a spine `thickness`
    /// across, on one line or two sized by their line boxes, whichever is larger: the measure a
    /// spine grows by, on the shelf (`readableDimensions`) and on Book Wall.
    ///
    /// Growth doesn't count on a two-line title's letters filling the box. A spine that did
    /// would stop growing sooner, and the fill would shrink the book in place of enlarging its
    /// letters, and take the room its author's whole name needs. Where this size reaches
    /// `minimumTitleSize`, the drawn title does too, though the preference for one line can
    /// draw it smaller than this size.
    nonisolated static func growthTitleSize(
        title: String, author: String, font: @escaping (CGFloat) -> UIFont, length: CGFloat,
        thickness: CGFloat
    ) -> CGFloat {
        LetteringRule(
            fontName: nil, font: cached(font), title: title, author: author, length: length,
            thickness: thickness, maximumLines: 2, sizesByLineBoxes: true
        )
        .lettering().titleSize
    }

    /// `font`, remembering the font of each size, because the rule asks for the same few sizes
    /// many times.
    private nonisolated static func cached(_ font: @escaping (CGFloat) -> UIFont)
        -> (CGFloat) -> UIFont
    {
        var fonts: [CGFloat: UIFont] = [:]
        return { size in
            if let saved = fonts[size] { return saved }
            let made = font(size)
            fonts[size] = made
            return made
        }
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
    /// Growth measures the title by `growthTitleSize`, on one or two lines, so a spine
    /// lengthens, then thickens, before its title takes a third line.
    static func readableDimensions(
        for book: Book, style: SpineStyle,
        natural: SpineDimensions, rowHeight: CGFloat
    ) -> SpineDimensions {
        let resolved = UIFont(name: style.fontName, size: minimumTitleSize)?.fontName
        let key = DimensionsKey(
            book: book, style: style, width: natural.width, height: natural.height,
            rowHeight: rowHeight, resolvedFont: resolved ?? "system")
        if let saved = savedDimensions[key] { return saved }
        // Prefer extra height so page-count-based thickness changes only as a last resort.
        // The shelf’s top gap accommodates the focus lift; retain the book-shape bounds.
        let maximumHeight = max(
            natural.height,
            min(
                rowHeight,
                natural.width * ShelfLayout.slendernessRange.upperBound))
        let spine = text(of: book, uppercase: style.uppercase)
        func reads(_ dimensions: SpineDimensions) -> Bool {
            growthTitleSize(
                title: spine.title, author: spine.author,
                font: { uiFont(name: resolved, size: $0) },
                length: letteredLength(
                    for: book, length: dimensions.height, thickness: dimensions.width),
                thickness: dimensions.width) >= minimumTitleSize
        }
        var dimensions = natural
        while !reads(dimensions), dimensions.height < maximumHeight {
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
        while !reads(dimensions), dimensions.width < maximumWidth {
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

/// The iPhone and Mac app's spine lettering rule (`SpineLettering` in
/// `ios/Bookworms/Views/SpineLettering.swift`), measured with UIKit so the shelf can size books
/// before it draws them. Keep the shares, the title's line rule (`twoLineGain`, `oneLineFloor`,
/// `twoLineFill`, `lineGap`), and the author's forms the same in both apps.
///
/// The Apple TV adds its safeguards: sizes sit on a half-point grid, authors letter at 16
/// points or more, the title stays 4 points larger than the author where that minimum allows,
/// and a title that its preferred lines letter below 23 points takes whichever of one line and
/// two letters it larger, or a third line when neither reaches 23 points and three are larger.
private struct LetteringRule {
    let fontName: String?
    let makeFont: (CGFloat) -> UIFont
    let title: String
    let author: String
    let length: CGFloat
    let maximumLines: Int
    /// Whether the title takes the larger of one line and two sized by their line boxes, with
    /// no preference for one line and no fill: `SpineTextMetrics.growthTitleSize`.
    let sizesByLineBoxes: Bool
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
        length: CGFloat, thickness: CGFloat, maximumLines: Int, sizesByLineBoxes: Bool = false
    ) {
        self.fontName = fontName
        makeFont = font
        self.title = title
        self.author = author
        self.length = length
        self.maximumLines = maximumLines
        self.sizesByLineBoxes = sizesByLineBoxes
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

    struct Title {
        var lines: [String]
        var size: CGFloat
        var pitch: CGFloat
        var shift: CGFloat = 0
    }

    struct Row {
        let title: Title
        let titleWidth: CGFloat
        let author: Author
    }

    func lettering() -> SpineLettering {
        // The author's large forms apply only where the title keeps its lines, loses no size
        // to them, and stays at least 1.4 times their size. The 1% absorbs the half-point size
        // grid.
        let largeRow = row(large: true, least: least)
        var chosen = row(large: false, least: least)
        if largeRow.title.lines.count == chosen.title.lines.count,
            largeRow.title.size >= 0.99 * chosen.title.size, largeRow.title.size >= 1.4 * large
        {
            chosen = largeRow
        }
        let lead = max(
            SpineTextMetrics.minimumAuthorSize, chosen.title.size - SpineTextMetrics.titleLead)
        if chosen.author.size > lead { chosen = row(large: false, least: lead) }
        return SpineLettering(
            fontName: fontName, title: chosen.title.lines.joined(separator: "\n"),
            titleSize: chosen.title.size, titleWidth: chosen.titleWidth,
            titlePitch: chosen.title.pitch, titleShift: chosen.title.shift,
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

    /// The author's first form that fits `width` and the box: the whole name on one line, then
    /// on two, at the large size where `large` allows, then at `least`. A spine names its
    /// author in full wherever it can, so the surname comes only after those, at the same
    /// sizes. Failing every form, the surname at `least`, truncated.
    private func author(in width: CGFloat, large: Bool, least: CGFloat) -> Author {
        let name = [author, SpineView.twoLines(author)].compactMap { $0 }
        let surname = [SpineView.surname(author)].compactMap { $0 }
        for forms in [name, surname] {
            for size in large ? [self.large, least] : [least] {
                for form in forms {
                    let lines = form.components(separatedBy: "\n")
                    if fits(lines, size: size, width: width) {
                        return Author(
                            text: form, size: size, width: widest(lines, size: size), fits: true)
                    }
                }
            }
        }
        return Author(
            text: SpineView.surname(author) ?? author, size: least, width: width, fits: false)
    }

    /// The title in `width`: on one line, unless two lines letter it at least
    /// `SpineTextMetrics.twoLineGain` times larger, or larger at all where one line would fall
    /// below `SpineTextMetrics.oneLineFloor` of the length. A title on two lines is filled.
    ///
    /// Where that letters the title below `SpineTextMetrics.minimumTitleSize`, it takes
    /// whichever of one line and two filled lines is larger. Where that is below the minimum
    /// too, it takes three filled lines, if `maximumLines` allows them and they are larger.
    /// Lines break between words alone, so a title without spaces, such as a Chinese one,
    /// keeps to one line.
    private func titleFit(_ width: CGFloat) -> Title {
        let words = title.split(separator: " ").map(String.init)
        let one = fit(words, into: 1, width: width)
        guard maximumLines >= 2, words.count >= 2 else { return one }
        let two = fit(words, into: 2, width: width)
        guard !sizesByLineBoxes else { return two.size > one.size ? two : one }
        let twoFilled = filled(two, in: width)
        let gain =
            one.size >= SpineTextMetrics.oneLineFloor * length ? SpineTextMetrics.twoLineGain : 1
        let preferred = two.size > one.size * gain ? twoFilled : one
        guard preferred.size < SpineTextMetrics.minimumTitleSize else { return preferred }
        var largest = twoFilled.size > one.size ? twoFilled : one
        if largest.size < SpineTextMetrics.minimumTitleSize, maximumLines >= 3, words.count >= 3 {
            let three = filled(fit(words, into: 3, width: width), in: width)
            if three.size > largest.size { largest = three }
        }
        return largest
    }

    /// The largest size on the half-point grid, at most the box's, at which `words` fit
    /// `count` lines in `width` and the box, broken where the widest line is narrowest.
    private func fit(_ words: [String], into count: Int, width: CGFloat) -> Title {
        let candidates = Self.breaks(words[...], into: count)
        let lines =
            candidates.min { widest($0, size: box) < widest($1, size: box) } ?? [title]
        let lineHeight = font(box).lineHeight / box
        let size = gridSize(
            min(box, box / (CGFloat(count) * lineHeight), widthLimit(lines, in: width)),
            above: 0.5
        ) { fits(lines, size: $0, width: width) }
        return Title(lines: lines, size: size, pitch: font(size).lineHeight)
    }

    /// `title`, on two or three lines, grown until its letters fill
    /// `SpineTextMetrics.twoLineFill` of the box, or its longest line fills `width`.
    ///
    /// A font's line height leaves room for the tallest and the lowest letters of any text, and
    /// most spine titles are capitals, so lines sized by line height leave much of the box
    /// empty. The letters' own reach, measured from the title's glyphs, sizes the lines instead.
    private func filled(_ title: Title, in width: CGFloat) -> Title {
        let face = font(100) as CTFont
        let ink = ink(title.lines, in: face)
        let height = ink.top + ink.bottom
        guard height > 0 else { return title }
        let count = CGFloat(title.lines.count)
        let size = gridSize(
            min(
                SpineTextMetrics.twoLineFill * box
                    / ((count + (count - 1) * SpineTextMetrics.lineGap) * height),
                widthLimit(title.lines, in: width)),
            above: title.size
        ) { widest(title.lines, size: $0) <= width }
        guard size > title.size else { return title }
        // A line draws with its line box centered on its pitch; the shift centers its letters.
        let boxCenter =
            (CTFontGetDescent(face) + CTFontGetLeading(face) - CTFontGetAscent(face)) / 200
        return Title(
            lines: title.lines, size: size,
            pitch: (1 + SpineTextMetrics.lineGap) * height * size,
            shift: (boxCenter - (ink.bottom - ink.top) / 2) * size)
    }

    /// The largest size on the half-point grid, at most `size`, at which `fits` holds, or the
    /// first at or below `least` when none above it does. Fonts with optical sizes don't scale
    /// exactly, so `fits` confirms each size by measuring at that size.
    private func gridSize(_ size: CGFloat, above least: CGFloat, fits: (CGFloat) -> Bool)
        -> CGFloat
    {
        var size = (size * 2).rounded(.down) / 2
        while size > least, !fits(size) { size -= 0.5 }
        return size
    }

    /// The size at which `lines` would fill `width` if the face scaled exactly from the box's
    /// size.
    private func widthLimit(_ lines: [String], in width: CGFloat) -> CGFloat {
        let widestLine = widest(lines, size: box)
        return widestLine > 0 ? box * width / widestLine : box
    }

    /// How far the letters of `lines` reach above and below the baseline in `face`, a 100-point
    /// font, per point of size.
    private func ink(_ lines: [String], in face: CTFont) -> (top: CGFloat, bottom: CGFloat) {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        for text in lines {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: face]))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            top = max(top, bounds.maxY)
            bottom = max(bottom, -bounds.minY)
        }
        return (top / 100, bottom / 100)
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
