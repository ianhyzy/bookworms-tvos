import CoreText
import Foundation

/// The books that share one series look: the same style series and Discworld group
/// (`SeriesDesigns.subseries`), and the same first author.
struct SeriesLookKey: Hashable, Comparable, Sendable {
    let seriesID: Int
    /// The Discworld group, or "", then "|" and the first author's `SeriesDesigns.authorKeys(of:)`
    /// key, such as "City Watch|terrypratchett".
    let group: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seriesID, lhs.group) < (rhs.seriesID, rhs.group)
    }
}

/// Decides which books in a series draw with one spine look, so a series looks alike on the
/// shelf: the same font and colors, with only the title, author, and thickness changing. The
/// rules match the iPhone companion's `SeriesDesigns`, and so do the names of `styleSeries`,
/// `lookKey`, `authorKeys`, and `lookGroups`, though this app's helpers take its own types.
///
/// A look group (`SeriesLookKey`) draws its synced series look (`SeriesLookV1`) when one exists.
/// Without one, each book draws the design of the group's best-ranked book that can lend it
/// (`sources(books:fonts:links:canLetter:)`). Each book keeps its own saved style either way.
/// The look key names the look's record (`SeriesLookV1`), so keep `styleSeries`, `lookKey`, and
/// `subseries` in step with the iPhone companion: keys that differ between the apps give one
/// group two looks, and a changed rule leaves earlier looks unused. Keep the series label
/// (`shownSeries(of:link:)` and `label(of:)`) in step too, so both apps name the same series.
enum SeriesDesigns {
    /// The series whose look `book` draws: its link, else its shortest series.
    ///
    /// A link that stands alone gives `nil`, and a link to a series gives that series with the
    /// book's position from the matching membership. Otherwise the book's shortest membership
    /// wins: a compilation, such as an omnibus, last; then the fewest books, with an unknown or
    /// one-book size last; then a featured series; then the lower series ID. A book saved before
    /// memberships were fetched uses its featured `seriesID`.
    static func styleSeries(of book: Book, link: SeriesLinkV1?) -> (id: Int, position: Double?)? {
        if let link {
            if link.standsAlone { return nil }
            if let id = link.linkedSeriesID {
                return (id, book.seriesMemberships?.first { $0.seriesID == id }?.position)
            }
        }
        guard let memberships = book.seriesMemberships else {
            return book.seriesID.map { ($0, book.seriesPosition) }
        }
        func order(_ series: SeriesMembership) -> (Int, Int, Int, Int) {
            let size = series.size.flatMap { $0 >= 2 ? $0 : nil } ?? .max
            return (series.compilation ? 1 : 0, size, series.featured ? 0 : 1, series.seriesID)
        }
        return memberships.min { order($0) < order($1) }.map { ($0.seriesID, $0.position) }
    }

    /// The look group `book` belongs to, or `nil` when it draws its own design: a book with no
    /// style series, or a book of a series with groups (`subseries`) that no group names.
    static func lookKey(of book: Book, link: SeriesLinkV1?) -> SeriesLookKey? {
        guard let series = styleSeries(of: book, link: link)?.id else { return nil }
        var subseries = ""
        if let groups = Self.subseries[series] {
            guard let group = groups[titleKey(book.title)] else { return nil }
            subseries = group
        }
        return SeriesLookKey(
            seriesID: series, group: subseries + "|" + (authorKeys(of: book).first ?? ""))
    }

    /// Groups `books` by look key (`lookKey(of:link:)`, with `links`), leaving out books without
    /// one and books whose link keeps their own look, as the iPhone companion's
    /// `lookGroups(_:)` does.
    static func lookGroups(_ books: [Book], links: [Int: SeriesLinkV1] = [:])
        -> [SeriesLookKey: [Book]]
    {
        var groups: [SeriesLookKey: [Book]] = [:]
        for book in books where links[book.id]?.ownLook != true {
            if let key = lookKey(of: book, link: links[book.id]) {
                groups[key, default: []].append(book)
            }
        }
        return groups
    }

    /// Returns whether `book` and `other` share a series look: the same look group
    /// (`lookKey(of:link:)`) without links.
    static func matches(_ book: Book, _ other: Book) -> Bool {
        guard let key = lookKey(of: book, link: nil) else { return false }
        return key == lookKey(of: other, link: nil)
    }

    /// Groups within long series that Hardcover does not record, keyed by Hardcover series ID
    /// and then by `titleKey(_:)`: each group shares a design instead of the whole series.
    /// Books of a listed series that no group names keep their own designs.
    ///
    /// Discworld (series 1018) follows the owner's choice of the common reading-order groups.
    /// The grouping is loose; adjust it here, and in the iPhone companion's copy of this table.
    static let subseries: [Int: [String: String]] = [
        1018: groups([
            "Rincewind": [
                "The Colour of Magic", "The Color of Magic", "The Light Fantastic", "Sourcery",
                "Eric", "Faust Eric", "Interesting Times", "The Last Continent", "The Last Hero",
                "Unseen Academicals",
            ],
            "Industrial Revolution": [
                "Moving Pictures", "The Truth", "Monstrous Regiment", "Going Postal",
                "Making Money", "Raising Steam",
            ],
            "City Watch": [
                "Guards! Guards!", "Men at Arms", "Feet of Clay", "Jingo", "The Fifth Elephant",
                "Night Watch", "Thud!", "Snuff", "Where's My Cow?", "The World of Poo",
            ],
            "Death": ["Mort", "Reaper Man", "Soul Music", "Hogfather", "Thief of Time"],
            "Ancient Civilizations": ["Pyramids", "Small Gods"],
            "Witches": [
                "Equal Rites", "Wyrd Sisters", "Witches Abroad", "Lords and Ladies", "Maskerade",
                "Carpe Jugulum", "Nanny Ogg's Cookbook",
            ],
            "Tiffany Aching": [
                "The Wee Free Men", "A Hat Full of Sky", "Wintersmith", "I Shall Wear Midnight",
                "The Shepherd's Crown",
            ],
            "Science of Discworld": [
                "The Science of Discworld", "The Science of Discworld II",
                "The Science of Discworld III", "The Science of Discworld IV",
            ],
        ])
    ]

    private static func groups(_ titles: [String: [String]]) -> [String: String] {
        var keyed: [String: String] = [:]
        for (group, members) in titles {
            for title in members { keyed[titleKey(title)] = group }
        }
        return keyed
    }

    /// A title compared without case, diacritics, punctuation, or a subtitle after a colon, so
    /// "Thud!" matches "THUD" and "The Science of Discworld II: The Globe" matches its group.
    static func titleKey(_ title: String) -> String {
        let main = title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? title
        return main.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    /// The book's authors in order, compared without case, diacritics, spaces, or punctuation.
    /// Libraries join several authors with ", ".
    static func authorKeys(of book: Book) -> [String] {
        book.author.components(separatedBy: ", ")
            .map {
                String(
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        .filter { $0.isLetter || $0.isNumber })
            }
            .filter { !$0.isEmpty }
    }

    /// Returns whether `lhs` ranks before `rhs` in a look group: the lower position in its style
    /// series (`styleSeries(of:link:)`), then the earlier finish date, then the lower book ID. A
    /// missing position ranks last, as does a finish that is missing or doesn't parse, so reading
    /// the first book or a prequel later moves the group to its design.
    static func ranksBefore(_ lhs: Book, _ rhs: Book, links: [Int: SeriesLinkV1] = [:]) -> Bool {
        rank(lhs, link: links[lhs.id]) < rank(rhs, link: links[rhs.id])
    }

    private static func rank(_ book: Book, link: SeriesLinkV1?) -> (Double, Date, Int) {
        (
            styleSeries(of: book, link: link)?.position ?? .infinity,
            finishedDate(of: book) ?? .distantFuture, book.id
        )
    }

    /// The finish date, parsed from the first 10 characters of `finished` (`yyyy-MM-dd`) at noon
    /// UTC, as the iPhone companion's `CloudBook.finishedDate` does. `nil` when the finish is
    /// missing or doesn't parse, so such a book ranks as unfinished.
    private static func finishedDate(of book: Book) -> Date? {
        guard let finished = book.finished, finished.count >= 10 else { return nil }
        return try? Date(String(finished.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
    }

    /// Returns whether another book may draw with a design in `fontName`: never a name
    /// `SpineFontPolicy.allows(_:)` blocks, such as Impact, an italic, or a slanted face.
    ///
    /// The check stands on its own and doesn't rely on saved styles having been remapped to
    /// allowed faces when they load.
    static func isUsableSource(_ fontName: String) -> Bool {
        SpineFontPolicy.allows(fontName)
    }

    /// Returns whether a new series look may copy `design`: never one whose family or PostScript
    /// name is blocked, such as Impact or a slanted script, as the iPhone companion's
    /// `isUsableSource(_:)` rules.
    static func isUsableSource(_ design: SpineDesignV1) -> Bool {
        (design.fontFamily.map(SpineFontPolicy.allows) ?? true)
            && (design.fontPostScriptName.map(SpineFontPolicy.allows) ?? true)
    }

    /// The saved design a new look for a group copies, as stored: the earliest `generatedAt`
    /// among the `members`' usable original designs, else among their usable `series-reuse`
    /// copies, with the lower book ID breaking a tie. `nil` when no member has a usable design.
    ///
    /// A usable design passes `isUsableSource(_:)` and was made for the member as it is now: its
    /// `workItemHash` matches the member's current one.
    static func lookDesign(of members: [Book], designs: [Int: SpineDesignV1]) -> SpineDesignV1? {
        let usable = members.compactMap { book -> SpineDesignV1? in
            guard let design = designs[book.id], isUsableSource(design),
                design.workItemHash
                    == SpineCloudIdentity.workItemHash(accountID: design.accountID, book: book)
            else { return nil }
            return design
        }
        let originals = usable.filter { !$0.isSeriesReuse }
        return (originals.isEmpty ? usable : originals)
            .min { ($0.generatedAt, $0.bookID) < ($1.generatedAt, $1.bookID) }
    }

    /// Maps each book that draws another book's spine design to that book, its source; a
    /// source maps to itself, and a book that draws its own design and lends it to no one is
    /// absent.
    ///
    /// Each look group (`lookGroups(_:links:)`) is decided in `ranksBefore` order, so a book
    /// whose link keeps its own look neither lends nor borrows. A book takes the best-ranked
    /// earlier root whose font, from `fonts`, is usable and can letter it (`canLetter`);
    /// otherwise it is a root itself. Only a root lends its design, so no book draws a design
    /// another book borrowed. The result doesn't depend on the order of `books`.
    static func sources(
        books: [Book], fonts: [Int: String], links: [Int: SeriesLinkV1] = [:],
        canLetter: (Book, String) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        var sources: [Int: Int] = [:]
        for books in lookGroups(books, links: links).values {
            var roots: [Book] = []
            for book in books.sorted(by: { ranksBefore($0, $1, links: links) }) {
                if let root = roots.first(where: { root in
                    guard let font = fonts[root.id], isUsableSource(font) else { return false }
                    return canLetter(book, font)
                }) {
                    sources[book.id] = root.id
                    sources[root.id] = root.id
                } else {
                    roots.append(book)
                }
            }
        }
        return sources
    }

    /// The text a spine letters for `book`, for glyph checks: its title and author, uppercased
    /// when the design draws in capitals.
    static func lettering(of book: Book, uppercase: Bool = false) -> String {
        let text = book.title + " " + book.author
        return uppercase ? text.uppercased() : text
    }

    /// Whether `font` has a glyph for every letter `book`'s spine draws, in capitals when
    /// `uppercase` is set. The check uses the precomposed form, as the iPhone companion's
    /// `DownloadedFont.covers(_:)` does, and lettering that is all whitespace passes.
    static func canLetter(_ book: Book, font: CTFont, uppercase: Bool = false) -> Bool {
        let text = lettering(of: book, uppercase: uppercase).precomposedStringWithCanonicalMapping
        let characters = Array(String(text.filter { !$0.isWhitespace }).utf16)
        guard !characters.isEmpty else { return true }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }
}

extension SpineDesignV1 {
    /// Whether the design copies another book's (`provenance` "series-reuse:<bookID>").
    var isSeriesReuse: Bool {
        provenance?.split(separator: " ").contains { $0.hasPrefix("series-reuse:") } == true
    }

    /// Whether the reader chose the design's colors (a `provenance` token that starts with
    /// "generated-colors:", which records the generator's colors).
    var hasReaderColors: Bool {
        provenance?.split(separator: " ").contains { $0.hasPrefix("generated-colors:") } == true
    }

    /// Whether the reader chose the design's font on the iPhone or Mac (a "reader-font"
    /// `provenance` token).
    var hasReaderFont: Bool {
        provenance?.split(separator: " ").contains("reader-font") == true
    }

    /// Whether the reader chose the design's colors or font, which the iPhone's generation runs
    /// keep.
    var hasReaderEdits: Bool { hasReaderColors || hasReaderFont }

    /// The `provenance` token that names the model that made the design, such as
    /// "model:apple/on-device", as the iPhone and Mac read it (`SpineDesignV1.modelToken` in the
    /// iOS app), so a look copied from the design records the same tier on every device.
    ///
    /// Without a `model:` token, the generator decides: `nil`, for Private Cloud Compute, from
    /// any `ios-pcc-` version, whose Private Cloud Compute designs record none;
    /// "model:apple/on-device" from any version of the retired Mac companion's generator
    /// (`mac-foundation-models-`); and "model:local" from any other generator, such as Book
    /// Wall's `tvos-local-v1` looks. The Mac companion used no other model, so its "model:local"
    /// token also reads as "model:apple/on-device".
    var modelToken: String? {
        let isCompanion = generatorVersion.hasPrefix("mac-foundation-models-")
        if let token = provenance?.split(separator: " ").first(where: { $0.hasPrefix("model:") }) {
            return isCompanion && token == "model:local" ? "model:apple/on-device" : String(token)
        }
        if generatorVersion.hasPrefix("ios-pcc-") { return nil }
        return isCompanion ? "model:apple/on-device" : "model:local"
    }
}

extension SeriesDesigns {
    /// The series that `book`'s series label names: its style series (`styleSeries(of:link:)`),
    /// the series its link names, else its shortest series, as the book's membership in it. A
    /// book without memberships, from an older archive or cache, names its featured series.
    /// `nil` when the book has no named series or its link takes it out of every series
    /// (`SeriesLinkV1.standsAlone`).
    static func shownSeries(of book: Book, link: SeriesLinkV1?) -> SeriesMembership? {
        guard let id = styleSeries(of: book, link: link)?.id else { return nil }
        if let membership = book.seriesMemberships?.first(where: { $0.seriesID == id }) {
            return membership
        }
        guard id == book.seriesID, let name = book.seriesName, !name.isEmpty else { return nil }
        return SeriesMembership(
            seriesID: id, name: name, position: book.seriesPosition, featured: true,
            compilation: false)
    }

    /// A book's place in `series`, such as "5 of 6", or "Book 5" when the series' size is
    /// unknown or doesn't include the position. `nil` without a position.
    static func place(in series: SeriesMembership) -> String? {
        guard let position = series.position else { return nil }
        let number = position.formatted(.number.precision(.fractionLength(0...1)))
        guard let size = series.size, position >= 1, position <= Double(size) else {
            return "Book \(number)"
        }
        return "\(number) of \(size)"
    }

    /// A series label, such as "Discworld - Industrial Revolution 5 of 6": the series' name, then
    /// the book's place in it (`place(in:)`) when known.
    static func label(of series: SeriesMembership) -> String {
        [series.name, place(in: series)].compactMap(\.self).joined(separator: " ")
    }
}
