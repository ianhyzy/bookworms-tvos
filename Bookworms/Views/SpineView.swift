import SwiftUI
import UIKit

struct SpineView: View {
    let book: Book
    let style: SpineStyle
    let dimensions: SpineDimensions
    /// The lettering `SpineTextMetrics.lettering(for:style:dimensions:)` measured when the
    /// shelf's pages were prepared. The view draws it as measured.
    let lettering: SpineLettering
    let isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = dimensions.width
        let height = dimensions.height
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
            // Lettered lying flat, head on the left, then turned to read top to bottom. The
            // format icon turns with the lettering, so it reads in the same direction.
            HStack(spacing: 0) {
                letteringRow
                    .frame(width: lettering.length, height: width)
                if book.format != nil {
                    Image(systemName: book.formatSymbol)
                        .appFont(size: SpineTextMetrics.formatIconSize)
                        .frame(width: SpineTextMetrics.formatIconSize)
                        .padding(
                            .trailing,
                            SpineTextMetrics.formatIconRoom - SpineTextMetrics.formatIconSize)
                }
            }
            .frame(width: height, height: width, alignment: .leading)
            .rotationEffect(.degrees(90))
            .frame(width: width, height: height)
            .foregroundStyle(style.foreground.color)
        }
        .frame(width: width, height: height)
        .overlay {
            RoundedRectangle(cornerRadius: corner).fill(.white.opacity(isFocused ? 0.09 : 0))
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1, anchor: .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
    }

    /// The title at the head end and the author at the tail end, at their measured sizes.
    /// Measured text sizes itself (`fixedSize`), so SwiftUI never rewraps or scales it.
    private var letteringRow: some View {
        HStack(spacing: 0) {
            spineTitle(lettering.title)
                .font(SpineTextMetrics.font(name: lettering.fontName, size: lettering.titleSize))
                .textRenderer(SpineTextRenderer(fontSize: lettering.titleSize))
                .multilineTextAlignment(.leading)
                .fixedSize()
                .frame(width: lettering.titleWidth, alignment: .leading)
            Spacer(minLength: 0)
            authorText
                .font(SpineTextMetrics.font(name: lettering.fontName, size: lettering.authorSize))
                .textRenderer(SpineTextRenderer(fontSize: lettering.authorSize))
                .multilineTextAlignment(.trailing)
                .frame(width: lettering.authorWidth, alignment: .trailing)
        }
        .padding(.horizontal, lettering.inset)
    }

    @ViewBuilder private var authorText: some View {
        if lettering.authorFits {
            Text(verbatim: lettering.author).fixedSize()
        } else {
            Text(verbatim: lettering.author).lineLimit(1).truncationMode(.tail)
        }
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
    /// 7 mm at 100 pages plus 0.035 mm a page, up to 40 mm, thickened by none, half, or all of
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

    // The author forms below are the iPhone and Mac app's (`SpineView` in
    // `ios/Bookworms/Views/SpineView.swift`). Keep the two copies the same.

    /// Shortens a long contributor list to its first name, since a spine has little room.
    nonisolated static func shortAuthor(_ author: String) -> String {
        let names = author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count > 2 || (names.count == 2 && author.count > 32), let first = names.first
        else { return author }
        return first + " et al."
    }

    /// Words that belong to the surname that follows them, such as "Le" in "Ursula K. Le Guin".
    private nonisolated static let surnameParticles: Set<String> = [
        "al", "bin", "da", "de", "del", "della", "der", "di", "du", "el", "la", "le", "st.",
        "ten", "ter", "van", "von",
    ]
    /// Words that follow a surname, such as "Jr." in "Walter M. Miller Jr.".
    private nonisolated static let nameSuffixes: Set<String> = [
        "jr.", "jr", "sr.", "sr", "ii", "iii", "iv",
    ]

    /// `author` with each name shortened to its surname, such as "Le Guin" for "Ursula K. Le
    /// Guin" or "Gaiman, Pratchett" for "Neil Gaiman, Terry Pratchett", keeping the "et al."
    /// that `shortAuthor(_:)` adds. Returns `nil` when no name has a shorter form.
    nonisolated static func surname(_ author: String) -> String? {
        let (names, others) = names(of: author)
        let surnames = names.map(lastName)
        guard surnames != names else { return nil }
        return surnames.joined(separator: ", ") + others
    }

    /// `author` on two lines: a pair of names one over the other, or one name broken before
    /// its surname, such as "David Foster" over "Wallace". Returns `nil` for anything else.
    nonisolated static func twoLines(_ author: String) -> String? {
        let (names, others) = names(of: author)
        if names.count == 2 { return names[0] + ",\n" + names[1] + others }
        guard let name = names.first, names.count == 1 else { return nil }
        let surname = lastName(name)
        guard name.hasSuffix(surname) else { return nil }
        let given = name.dropLast(surname.count).trimmingCharacters(in: .whitespaces)
        return given.isEmpty ? nil : given + "\n" + surname + others
    }

    /// The names in `author`, and " et al." when `shortAuthor(_:)` ended it with that.
    private nonisolated static func names(of author: String) -> (names: [String], others: String) {
        let others = " et al."
        let hasOthers = author.hasSuffix(others)
        let names = author.dropLast(hasOthers ? others.count : 0).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (names, hasOthers ? others : "")
    }

    /// One name's surname, with the particles before it and any suffix after it, or the whole
    /// name when it is a single word.
    private nonisolated static func lastName(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        guard words.count > 1 else { return name }
        var surname = [words.removeLast()]
        if nameSuffixes.contains(surname[0].lowercased()), words.count > 1 {
            surname.insert(words.removeLast(), at: 0)
        }
        while words.count > 1, let word = words.last, surnameParticles.contains(word.lowercased()) {
            surname.insert(words.removeLast(), at: 0)
        }
        return surname.joined(separator: " ")
    }
}
