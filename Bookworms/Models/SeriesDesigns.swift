import CoreText
import Foundation

/// Decides which books in a series draw with another book's spine design, so a series looks
/// alike on the shelf: the same font and colors, with only the title, author, and thickness
/// changing. The rules and names match the iPhone companion's `SeriesDesigns`.
///
/// Alignment happens when the app draws, not when it saves: each book keeps its own saved style,
/// so changing these rules changes no saved data.
enum SeriesDesigns {
    /// Returns whether `book` and `other` share a series design: the same series and at least
    /// one shared author.
    ///
    /// This is the whole membership rule; everything else in the app calls it. To let every
    /// book in a series match whoever wrote it, return `true` after the series check instead of
    /// comparing authors. Each `Book` stores one series, the featured one from Hardcover, so a
    /// book in several series matches only through that one.
    static func matches(_ book: Book, _ other: Book) -> Bool {
        guard let series = book.seriesID, series == other.seriesID else { return false }
        if let groups = subseries[series] {
            // A book in no group, or a group of its own, keeps its own design.
            guard let group = groups[titleKey(book.title)], group == groups[titleKey(other.title)]
            else { return false }
        }
        return !authors(of: book).isDisjoint(with: authors(of: other))
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

    /// The book's authors, compared without case, diacritics, spaces, or punctuation. Libraries
    /// join several authors with ", ".
    static func authors(of book: Book) -> Set<String> {
        Set(
            book.author.components(separatedBy: ", ")
                .map {
                    String(
                        $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                            .filter { $0.isLetter || $0.isNumber })
                }
                .filter { !$0.isEmpty })
    }

    /// Returns whether `lhs` ranks before `rhs` as a series' design source: the lower series
    /// position, then the earlier finish, then the lower book ID. A missing position or finish
    /// ranks last, so reading the first book or a prequel later moves the series to its design.
    static func ranksBefore(_ lhs: Book, _ rhs: Book) -> Bool {
        (lhs.seriesPosition ?? .infinity, finish(lhs), lhs.id)
            < (rhs.seriesPosition ?? .infinity, finish(rhs), rhs.id)
    }

    /// The finish date, `yyyy-MM-dd`, which sorts as text; a book without one sorts last.
    private static func finish(_ book: Book) -> String {
        book.finished.map { String($0.prefix(10)) } ?? "~"
    }

    /// Returns whether another book may draw with a design in `fontName`: never a name
    /// `SpineFontPolicy.allows(_:)` blocks, such as Impact, an italic, or a slanted face.
    ///
    /// The check stands on its own and doesn't rely on saved styles having been remapped to
    /// allowed faces when they load.
    static func isUsableSource(_ fontName: String) -> Bool {
        SpineFontPolicy.allows(fontName)
    }

    /// Maps each book that shares a series design to the book whose design it draws with. A
    /// source maps to itself; books that draw their own design are absent.
    ///
    /// A book's source is the best-ranked book among it and its matching series-mates whose
    /// font, from `fonts`, is usable. `canLetter` tells whether a source's font can letter a
    /// book; a book it rejects, such as one whose title the font lacks glyphs for, keeps its own
    /// design.
    static func sources(
        books: [Book], fonts: [Int: String],
        canLetter: (Book, String) -> Bool = { _, _ in true }
    ) -> [Int: Int] {
        let candidates = Dictionary(
            grouping: books.filter {
                $0.seriesID != nil && fonts[$0.id].map(isUsableSource) == true
            },
            by: { $0.seriesID })
        var sources: [Int: Int] = [:]
        for book in books {
            guard
                let source = candidates[book.seriesID]?
                    .filter({ $0.id == book.id || matches(book, $0) }).min(by: ranksBefore),
                source.id != book.id, let font = fonts[source.id], canLetter(book, font)
            else { continue }
            sources[book.id] = source.id
            sources[source.id] = source.id
        }
        return sources
    }

    /// The text a spine letters for `book`, for glyph checks: its title and author.
    static func lettering(of book: Book) -> String {
        book.title + " " + book.author
    }

    /// Whether the font named `fontName` has a glyph for every letter `book`'s spine draws.
    /// Preparation checks this once per book; a font that is not installed letters nothing.
    static func canLetter(_ book: Book, fontName: String) -> Bool {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        // CoreText substitutes a default face for a missing name; that face does not count.
        guard (CTFontCopyPostScriptName(font) as String) == fontName else { return false }
        let characters = Array(
            lettering(of: book).unicodeScalars.filter { !$0.properties.isWhitespace }
                .map(String.init).joined().utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }
}
