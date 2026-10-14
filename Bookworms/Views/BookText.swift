import SwiftUI
import UIKit

/// A book's own text, such as its title, description, or a review, with every "house" of House
/// of Leaves in blue.
///
/// Mark Z. Danielewski's novel prints the word "house" in blue. For that book alone
/// (`HouseOfLeaves.isNovel(_:)`), this view letters each "house" in the novel's blue, fitted to
/// the ground behind it. Any other book's text, including a title with "house" in it, is plain
/// text. VoiceOver reads the text unchanged.
struct BookText: View {
    let text: String
    let book: Book?

    init(_ text: String, of book: Book?) {
        self.text = text
        self.book = book
    }

    var body: some View {
        if let book, HouseOfLeaves.isNovel(book) {
            HouseOfLeavesText(text: text)
        } else {
            Text(verbatim: text)
        }
    }
}

/// House of Leaves' text, which alone reads the color scheme, so other books' text has no
/// environment dependencies.
private struct HouseOfLeavesText: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let lettering = colorScheme == .dark ? HouseOfLeaves.onDark : HouseOfLeaves.onLight
        let words = HouseOfLeaves.text(text, blue: lettering.blue.color)
        if lettering.glows { words.textRenderer(HouseOfLeaves.Glow()) } else { words }
    }
}

/// Recognizes House of Leaves and letters its "house" as the novel does.
enum HouseOfLeaves {
    /// How "house" is lettered on one ground: its blue, and whether a faint white glow sits
    /// behind it.
    struct Lettering: Equatable, Sendable {
        let blue: StyleColor
        let glows: Bool
    }

    /// The blue the novel prints "house" in, #6570AE.
    static let novelBlue = StyleColor(red: 0x65 / 255, green: 0x70 / 255, blue: 0xAE / 255)
    /// The glow's opacity where it is strongest, under the word's strokes.
    static let glowOpacity = 0.35
    /// The glow's radius as a share of the line's height.
    static let glowRadius = 0.15

    /// The lightest ground that dark-scheme text sits on: a material card over the walnut wall.
    /// The wall and ambient mode are darker, so a blue that reads here reads on them too.
    static let darkGround = StyleColor(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255)
    /// The darkest ground that light-scheme text sits on: the oak wall's lower edge
    /// (`ShelfPalette.wallBottom`). Light cards and the plain background are lighter.
    static let lightGround = StyleColor(red: 0.77, green: 0.67, blue: 0.54)
    /// Lettering for interface text, prepared once per color scheme.
    static let onDark = lettering(on: darkGround)
    static let onLight = lettering(on: lightGround)

    /// Whether `book` is House of Leaves by Mark Z. Danielewski, in any edition.
    ///
    /// The author must name Danielewski, and the title must be "House of Leaves" in any case,
    /// ignoring a subtitle after a colon or a dash and an edition note in parentheses or
    /// brackets. Editions carry different Hardcover IDs, so the ID plays no part.
    static func isNovel(_ book: Book) -> Bool {
        // The author check fails first for nearly every book, so it comes first.
        guard book.author.range(of: "danielewski", options: .caseInsensitive) != nil else {
            return false
        }
        let title = book.title.prefix { !":—–-([".contains($0) }
        return title.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("house of leaves") == .orderedSame
    }

    /// The ranges of the word "house" in `text`, in any case, with a plural or possessive
    /// ending: "House", "HOUSE", "houses", or "house's". A word that only contains it, such as
    /// "household" or "lighthouse", has none.
    static func houseRanges(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /\bhouse(?:s|['’]s)?\b/.ignoresCase().wordBoundaryKind(.simple))
    }

    /// `text` with each "house" in `blue`, marked for `Glow`.
    static func text(_ text: String, blue: Color) -> Text {
        var result = Text(verbatim: "")
        var start = text.startIndex
        for range in houseRanges(in: text) {
            let before = Text(verbatim: String(text[start..<range.lowerBound]))
            let word = Text(verbatim: String(text[range])).foregroundStyle(blue)
                .customAttribute(Word())
            result = Text("\(result)\(before)\(word)")
            start = range.upperBound
        }
        return Text("\(result)\(Text(verbatim: String(text[start...])))")
    }

    /// `text` drawn with `attributes`, with each "house" in the lettering's blue for `book` alone,
    /// over a faint white shadow when the lettering glows. Book Wall draws its spine and shelf
    /// lettering into textures with this.
    static func attributed(
        _ text: String, of book: Book?, attributes: [NSAttributedString.Key: Any],
        lettering: @autoclosure () -> Lettering
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        guard let book, isNovel(book) else { return result }
        let ranges = houseRanges(in: text)
        guard !ranges.isEmpty else { return result }
        let lettering = lettering()
        let font = attributes[.font] as? UIFont
        for range in ranges {
            let range = NSRange(range, in: text)
            result.addAttribute(.foregroundColor, value: lettering.blue.uiColor, range: range)
            if lettering.glows, let font {
                let glow = NSShadow()
                glow.shadowColor = UIColor(white: 1, alpha: glowOpacity)
                glow.shadowBlurRadius = font.lineHeight * glowRadius
                glow.shadowOffset = .zero
                result.addAttribute(.shadow, value: glow, range: range)
            }
        }
        return result
    }

    /// How "house" is lettered on `ground` among text in `ink`: the novel's blue, moved as
    /// little as legibility needs, and whether a faint white glow sits behind it.
    ///
    /// The blue keeps #6570AE's hue and moves in OKLab lightness toward `ink`, in steps of 0.01,
    /// until it reaches WCAG 4.5:1 and APCA Lc 60 on `ground`. Without `ink`, it moves toward
    /// black or white, whichever contrasts more with `ground`. So it stays the novel's blue on
    /// white, darkens a little on cream, and lightens on dark grounds.
    ///
    /// The glow lightens the ground beside the strokes. Behind a blue darker than its ground,
    /// that adds contrast, so the word glows, and the blue already passes without the glow.
    /// Behind a blue lighter than its ground, a glow would cost contrast, so the word has none.
    /// On a ground that no lightness of the blue reaches, such as a mid-blue cloth, the word
    /// takes `ink`.
    static func lettering(on ground: StyleColor, ink: StyleColor? = nil) -> Lettering {
        let white = StyleColor(red: 1, green: 1, blue: 1)
        let black = StyleColor(red: 0, green: 0, blue: 0)
        let ink =
            ink ?? (ground.contrast(with: white) >= ground.contrast(with: black) ? white : black)
        let lightens = ink.oklab.l > ground.oklab.l
        var lab = novelBlue.oklab
        while (0...1).contains(lab.l) {
            let color = StyleColor(oklab: lab)
            if passes(color, on: ground) { return Lettering(blue: color, glows: !lightens) }
            lab.l += lightens ? 0.01 : -0.01
        }
        return Lettering(blue: ink, glows: !lightens)
    }

    /// Whether `color` reaches WCAG 4.5:1 and APCA Lc 60 as text on `ground`.
    static func passes(_ color: StyleColor, on ground: StyleColor) -> Bool {
        color.contrast(with: ground) >= 4.5 && abs(color.apca(on: ground)) >= 60
    }

    /// Marks a "house" for `Glow`.
    struct Word: TextAttribute {}

    /// Draws text as usual, over a faint, soft white glow behind each `Word`.
    ///
    /// The glows all draw first, so none lies over a neighboring letter. The renderer keeps the
    /// default `displayPadding` of zero: a padding widens the width that text wraps to.
    struct Glow: TextRenderer {
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            for line in layout {
                for run in line where run[Word.self] != nil {
                    let bounds = run.typographicBounds
                    var glow = context
                    glow.addFilter(
                        .shadow(
                            color: .white.opacity(glowOpacity),
                            radius: (bounds.ascent + bounds.descent) * glowRadius,
                            options: .shadowOnly))
                    glow.draw(run)
                }
            }
            for line in layout { context.draw(line) }
        }
    }
}

extension StyleColor {
    /// A color in OKLab (Björn Ottosson): perceptual lightness `l` from 0 to 1, and the green–red
    /// and blue–yellow axes `a` and `b`.
    struct OKLab: Equatable {
        var l: Double
        var a: Double
        var b: Double
    }

    var oklab: OKLab {
        func linear(_ x: Double) -> Double {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = linear(red)
        let g = linear(green)
        let b = linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// The sRGB color nearest `lab`, with each channel clamped to the gamut and rounded to
    /// 8 bits, as a display shows it.
    init(oklab lab: OKLab) {
        let l = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l3 = l * l * l
        let m3 = m * m * m
        let s3 = s * s * s
        func srgb(_ x: Double) -> Double {
            let c = max(0, min(1, x))
            let v = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            return (v * 255).rounded() / 255
        }
        self.init(
            red: srgb(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            green: srgb(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            blue: srgb(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }

    /// The APCA lightness contrast (Lc) of this color as text on `background`: positive for dark
    /// text on a light background, negative for light text on a dark one.
    func apca(on background: StyleColor) -> Double {
        func y(_ c: StyleColor) -> Double {
            let value =
                0.2126729 * pow(c.red, 2.4) + 0.7151522 * pow(c.green, 2.4)
                + 0.0721750 * pow(c.blue, 2.4)
            return value < 0.022 ? value + pow(0.022 - value, 1.414) : value
        }
        let yt = y(self)
        let yb = y(background)
        if yb > yt {
            let s = (pow(yb, 0.56) - pow(yt, 0.57)) * 1.14
            return s < 0.1 ? 0 : (s - 0.027) * 100
        } else {
            let s = (pow(yb, 0.65) - pow(yt, 0.62)) * 1.14
            return s > -0.1 ? 0 : (s + 0.027) * 100
        }
    }
}
