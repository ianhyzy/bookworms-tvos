import SwiftUI
import UIKit

struct SpineView: View {
    let book: Book
    let style: SpineStyle
    let dimensions: SpineDimensions
    let isFocused: Bool
    // Font registration changes outside SwiftUI; this value invalidates the resolved lettering.
    var fontRevision: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = dimensions.width
        let height = dimensions.height
        let title = style.uppercase ? book.spineTitle.uppercased() : book.spineTitle
        // Account for outer padding and explicit gaps before rotating the text.
        let textLength = SpineTextMetrics.textLength(for: book, height: height)
        let textHeight = width - SpineTextMetrics.crossSpinePadding
        let typography = SpineTextMetrics.typography(
            for: book, style: style, dimensions: dimensions)
        let corner = Self.cornerRadius(thickness: width)
        ZStack {
            // Shadow the book shape only; shadowing the text layers creates costly offscreen passes.
            // The fill is flat, because the lettering's contrast is checked against this color.
            RoundedRectangle(cornerRadius: corner).fill(style.background.color)
                .shadow(
                    color: .black.opacity(isFocused ? 0.42 : 0.24), radius: isFocused ? 16 : 5,
                    x: 3, y: isFocused ? 6 : 2)
            relief.clipShape(.rect(cornerRadius: corner))
            if Self.stamps(book) {
                Self.stampedBands(on: style.background, length: height, thickness: width)
                    .padding(.horizontal, width * 0.1)
            }
            VStack(spacing: 0) {
                Spacer().frame(height: 13)
                HStack(spacing: textLength * 0.03) {
                    VStack(spacing: 4) {
                        spineTitle(title)
                            .font(
                                SpineTextMetrics.font(
                                    name: style.fontName, size: typography.titleSize)
                            )
                            .textRenderer(SpineTextRenderer(fontSize: typography.titleSize))
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle = book.spineSubtitle {
                            Text(subtitle)
                                .font(
                                    .system(
                                        size: SpineTextMetrics.fittedSize(
                                            subtitle, fontName: nil, maximum: 20,
                                            width: typography.titleLength - 2
                                                * SpineTextMetrics.titleEndPadding,
                                            height: textHeight * 0.26))
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, SpineTextMetrics.titleEndPadding)
                    .frame(width: typography.titleLength, height: textHeight)
                    SpineAuthorText(
                        text: book.author, fontName: style.fontName,
                        fontSize: typography.authorSize, width: typography.authorLength,
                        height: textHeight, color: style.foreground.color)
                }
                .multilineTextAlignment(.center)
                .frame(width: textLength, height: textHeight)
                .rotationEffect(.degrees(90))
                .frame(width: width, height: textLength)
                if book.format != nil {
                    Image(systemName: book.formatSymbol)
                        .appFont(size: 18)
                        .frame(height: 18)
                        .padding(.top, 24)
                }
            }
            .foregroundStyle(style.foreground.color)
            .padding(.vertical, 20)
        }
        .frame(width: width, height: height)
        .overlay {
            RoundedRectangle(cornerRadius: corner).fill(.white.opacity(isFocused ? 0.09 : 0))
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1, anchor: .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
    }

    /// The corner radius of a spine `thickness` points across: nearly square, as a flat cloth
    /// spine's corners are.
    nonisolated static func cornerRadius(thickness: CGFloat) -> CGFloat {
        min(1, thickness * 0.025)
    }

    /// Shading across the thickness: the long edges darken where the cloth turns onto the
    /// boards, with no highlight between them, so the face reads as a flat spine. The front
    /// board's edge, on the lettering's top side, takes the full shade.
    private var relief: some View {
        let shade = Self.relief(on: style.background)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(shade), location: 0),
                .init(color: .clear, location: 0.05),
                .init(color: .clear, location: 0.95),
                .init(color: .black.opacity(shade * 0.65), location: 1),
            ], startPoint: .trailing, endPoint: .leading)
    }

    /// The relief's black opacity at the front board's edge on `cloth`. Darker cloth takes
    /// more.
    nonisolated static func relief(on cloth: StyleColor) -> Double {
        0.025 + 0.12 * (1 - cloth.luminance)
    }

    /// The thinnest book, in millimeters from back to front cover, whose spine has
    /// blind-stamped bands: about 700 pages. A thinner spine draws them too small to read.
    nonisolated static let stampedThickness = 32

    /// Whether `book`'s spine has blind-stamped bands. It depends on the book alone, so the
    /// shelf, Book Wall, and the iPhone companion agree whatever size each draws the spine.
    nonisolated static func stamps(_ book: Book) -> Bool {
        thickness(of: book) >= stampedThickness
    }

    /// The book's thickness in millimeters, as the iPhone companion's `BookShape` sizes it:
    /// 7 mm at 100 pages plus 0.35 mm a page, up to 40 mm, thickened by none, half, or all of
    /// 25 percent as the book's ID decides, and rounded to 4 mm. Page counts count from 100 to
    /// 1,400, and a book without one counts as 320 pages. The arithmetic follows the
    /// companion's single-precision decimeters, so both apps round a borderline book alike.
    nonisolated static func thickness(of book: Book) -> Int {
        let pages = Float(min(1_400, max(100, book.pages ?? 320)))
        let variety = (Float(unit(book.id, salt: 41)) * 2).rounded(.toNearestOrAwayFromZero) / 2
        let decimeters = min(0.4, 0.07 + (pages - 100) * 0.00035) * (1 + variety * 0.25)
        return Int((decimeters / 0.04).rounded()) * 4
    }

    /// A number from 0 to 1 that `id` and `salt` decide, as the iPhone companion's
    /// `ShareStyle.unit(0, id, salt)` computes it.
    nonisolated private static func unit(_ id: Int, salt: UInt64) -> Double {
        var z =
            UInt64(bitPattern: Int64(id)) &* 0x9E37_79B9_7F4A_7C15 &+ salt
            &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    /// The blind-stamped bands on a spine `length` long and `thickness` across: each line's
    /// width, the slot each pair of lines is centered in, and the slot's inset from each end.
    nonisolated static func bands(length: CGFloat, thickness: CGFloat)
        -> (line: CGFloat, slot: CGFloat, inset: CGFloat)
    {
        (max(1.2, thickness * 0.03), max(2, thickness * 0.07), max(3, length * 0.0175))
    }

    /// The opacities of a band's black shadow and white highlight on `cloth`. A highlight
    /// barely shows on light cloth, so the shadow deepens with the cloth's lightness to keep
    /// the band readable there.
    nonisolated static func bandShades(on cloth: StyleColor) -> (shadow: Double, light: Double) {
        (0.22 + 0.22 * cloth.luminance, 0.15 * (1 - cloth.luminance))
    }

    /// Bands pressed into `cloth` near the head and tail of an upright spine, with no ink:
    /// each band is shadowed on its head side, away from the light, and caught by the light on
    /// its tail side.
    static func stampedBands(on cloth: StyleColor, length: CGFloat, thickness: CGFloat)
        -> some View
    {
        let size = bands(length: length, thickness: thickness)
        let shades = bandShades(on: cloth)
        let band = VStack(spacing: 0) {
            Color.black.opacity(shades.shadow).frame(height: size.line)
            Color.white.opacity(shades.light).frame(height: size.line)
        }
        .frame(height: size.slot)
        return VStack(spacing: 0) {
            band
            Spacer(minLength: 0)
            band
        }
        .padding(.vertical, size.inset)
    }

    /// The title, with House of Leaves' "house" in blue on this cloth. The spine's own text
    /// renderer draws it, so the blue has no glow; the blue passes without one.
    private func spineTitle(_ title: String) -> Text {
        guard HouseOfLeaves.isNovel(book) else { return Text(verbatim: title) }
        let lettering = HouseOfLeaves.lettering(on: style.background, ink: style.foreground)
        return HouseOfLeaves.text(title, blue: lettering.blue.color)
    }
}
