import UIKit
import XCTest

@testable import Bookworms

final class SeriesDesignsTests: XCTestCase {
    private func book(
        _ id: Int, series: Int? = 7, position: Double? = nil, finished: String? = nil,
        author: String = "Matt Dinniman", title: String = "Book"
    ) -> Book {
        var book = Book(
            id: id, title: title, author: author, finished: finished, seriesID: series,
            seriesName: series.map { _ in "Dungeon Crawler Carl" })
        book.seriesPosition = position
        return book
    }

    func testBooksMatchOnTheSameSeriesAndFirstAuthor() {
        let carl = book(1)
        XCTAssertTrue(SeriesDesigns.matches(carl, book(2, author: "matt dinnimán")))
        XCTAssertTrue(SeriesDesigns.matches(carl, book(3, author: "Matt Dinniman, Jeff Hays")))
        XCTAssertFalse(
            SeriesDesigns.matches(carl, book(3, author: "Jeff Hays, Matt Dinniman")),
            "Only the first author counts, so a look group has one key")
        XCTAssertTrue(SeriesDesigns.matches(carl, book(4, author: "Matt  Dinniman.")))
        XCTAssertFalse(SeriesDesigns.matches(carl, book(5, author: "Someone Else")))
        XCTAssertFalse(SeriesDesigns.matches(carl, book(6, series: 8)))
        XCTAssertFalse(SeriesDesigns.matches(book(7, series: nil), book(8, series: nil)))
    }

    func testDiscworldBooksShareADesignOnlyWithinTheirGroup() {
        func discworld(_ id: Int, _ title: String) -> Book {
            book(id, series: 1018, author: "Terry Pratchett", title: title)
        }
        let guards = discworld(1, "Guards! Guards!")
        XCTAssertTrue(SeriesDesigns.matches(guards, discworld(2, "THUD")))
        XCTAssertTrue(SeriesDesigns.matches(guards, discworld(3, "Night Watch: A Discworld Novel")))
        XCTAssertFalse(SeriesDesigns.matches(guards, discworld(4, "Mort")))
        XCTAssertTrue(
            SeriesDesigns.matches(
                discworld(5, "The Science of Discworld II: The Globe"),
                discworld(6, "The Science of Discworld")))
        // A book no group names keeps its own design.
        let maurice = discworld(7, "The Amazing Maurice and His Educated Rodents")
        XCTAssertFalse(SeriesDesigns.matches(maurice, discworld(8, "The Amazing Maurice")))
    }

    private func link(
        _ bookID: Int, series: Int? = nil, standsAlone: Bool = false, ownLook: Bool = false
    ) -> SeriesLinkV1 {
        SeriesLinkV1(
            accountID: "account", bookID: bookID, linkedSeriesID: series,
            standsAlone: standsAlone, ownLook: ownLook, chosenAt: Date(timeIntervalSince1970: 0))
    }

    func testStyleSeriesFollowsTheLinkElseTheShortestSeries() throws {
        var guards = book(1, series: 1018, position: 8, author: "Terry Pratchett")
        guards.seriesMemberships = [
            SeriesMembership(
                seriesID: 1018, name: "Discworld", position: 8, featured: true, size: 41),
            SeriesMembership(seriesID: 2001, name: "City Watch", position: 1, size: 8),
            SeriesMembership(
                seriesID: 3000, name: "Omnibus", position: 2, compilation: true, size: 2),
            SeriesMembership(seriesID: 4000, name: "One book", position: 1, size: 1),
            SeriesMembership(seriesID: 5000, name: "Unsized", position: 1),
        ]
        func style(_ link: SeriesLinkV1?) -> String? {
            SeriesDesigns.styleSeries(of: guards, link: link)
                .map { "\($0.id)@\($0.position.map(String.init(describing:)) ?? "nil")" }
        }
        XCTAssertEqual(style(nil), "2001@1.0", "The fewest books win; a compilation sorts last")
        XCTAssertEqual(style(link(1, series: 1018)), "1018@8.0")
        XCTAssertEqual(style(link(1, series: 9999)), "9999@nil", "A link names any series")
        XCTAssertNil(style(link(1, standsAlone: true)))
        XCTAssertEqual(style(link(1, ownLook: true)), "2001@1.0")

        // Unknown and one-book sizes sort last, then a featured series, then the lower ID.
        guards.seriesMemberships = [
            SeriesMembership(seriesID: 5000, name: "Unsized"),
            SeriesMembership(seriesID: 4000, name: "One book", size: 1),
        ]
        XCTAssertEqual(style(nil), "4000@nil")
        guards.seriesMemberships?
            .append(
                SeriesMembership(seriesID: 6000, name: "Featured", featured: true, size: 1))
        XCTAssertEqual(style(nil), "6000@nil")
        guards.seriesMemberships = []
        XCTAssertNil(style(nil), "A book in no series has no style series")
        guards.seriesMemberships = nil
        XCTAssertEqual(style(nil), "1018@8.0", "Books saved before memberships use seriesID")
    }

    /// Mirrors the iPhone companion's `SeriesLookTests`, so both apps label a series alike.
    func testSeriesLabelNamesTheLinkedElseTheShortestSeries() throws {
        // Making Money's Hardcover series.
        let discworld = SeriesMembership(
            seriesID: 1018, name: "Discworld", position: 36, featured: true, size: 41)
        let moist = SeriesMembership(
            seriesID: 10604, name: "Discworld - Moist von Lipwig", position: 2, size: 3)
        let industrial = SeriesMembership(
            seriesID: 10605, name: "Discworld - Industrial Revolution", position: 5, size: 6)
        var makingMoney = book(
            377256, series: 1018, position: 36, author: "Terry Pratchett", title: "Making Money")
        makingMoney.seriesMemberships = [discworld, moist, industrial]

        let shortest = try XCTUnwrap(SeriesDesigns.shownSeries(of: makingMoney, link: nil))
        XCTAssertEqual(SeriesDesigns.label(of: shortest), "Discworld - Moist von Lipwig 2 of 3")
        let linked = try XCTUnwrap(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, series: 10605)))
        XCTAssertEqual(
            SeriesDesigns.label(of: linked), "Discworld - Industrial Revolution 5 of 6")
        XCTAssertEqual(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, ownLook: true)), moist)
        XCTAssertNil(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, standsAlone: true)))
        XCTAssertNil(
            SeriesDesigns.shownSeries(of: makingMoney, link: link(377256, series: 9999)),
            "A link to a series Hardcover no longer lists for the book names none")

        // Without memberships, the featured series shows when it has a name.
        let older = book(6, series: 7, position: 4)
        XCTAssertEqual(
            SeriesDesigns.shownSeries(of: older, link: nil).map(SeriesDesigns.label(of:)),
            "Dungeon Crawler Carl Book 4")
        var unnamed = older
        unnamed.seriesName = nil
        XCTAssertNil(SeriesDesigns.shownSeries(of: unnamed, link: nil))

        // A place outside the series' size, or a size unknown, falls back to the position alone.
        func place(_ position: Double?, size: Int? = 3) -> String? {
            SeriesDesigns.place(
                in: SeriesMembership(seriesID: 1, name: "Series 1", position: position, size: size))
        }
        XCTAssertEqual(place(0), "Book 0")
        XCTAssertEqual(place(2.5), "2.5 of 3")
        XCTAssertEqual(place(4), "Book 4")
        XCTAssertEqual(place(2, size: nil), "Book 2")
        XCTAssertNil(place(nil))
    }

    func testLookKeysSplitDiscworldGroupsAndFirstAuthors() {
        func discworld(_ id: Int, _ title: String) -> Book {
            book(id, series: 1018, author: "Terry Pratchett, Stephen Baxter", title: title)
        }
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: discworld(1, "Guards! Guards!"), link: nil),
            SeriesLookKey(seriesID: 1018, group: "City Watch|terrypratchett"))
        XCTAssertNil(
            SeriesDesigns.lookKey(of: discworld(2, "The Amazing Maurice"), link: nil),
            "A Discworld book in no group draws its own design")
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: book(3), link: nil),
            SeriesLookKey(seriesID: 7, group: "|mattdinniman"))
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: book(4, author: ""), link: nil)?.group, "|")
        XCTAssertNil(SeriesDesigns.lookKey(of: book(5), link: link(5, standsAlone: true)))
        XCTAssertNil(SeriesDesigns.lookKey(of: book(6, series: nil), link: nil))
        XCTAssertEqual(
            SeriesDesigns.lookKey(of: book(7), link: link(7, series: 9))?.seriesID, 9)
    }

    func testSourcesGroupByStyleSeriesAndRankByItsPosition() {
        // Both books feature Discworld, but City Watch is their shortest series.
        func cityWatch(_ id: Int, featuredPosition: Double, position: Double) -> Book {
            var book = book(
                id, series: 1018, position: featuredPosition, author: "Terry Pratchett",
                title: "Unlisted \(id)")
            book.seriesMemberships = [
                SeriesMembership(
                    seriesID: 1018, name: "Discworld", position: featuredPosition,
                    featured: true, size: 41),
                SeriesMembership(seriesID: 2001, name: "City Watch", position: position, size: 8),
            ]
            return book
        }
        let books = [
            cityWatch(1, featuredPosition: 1, position: 2),
            cityWatch(2, featuredPosition: 9, position: 1),
            cityWatch(3, featuredPosition: 5, position: 3),
        ]
        let fonts = Dictionary(uniqueKeysWithValues: books.map { ($0.id, "Georgia-Bold") })
        XCTAssertEqual(
            SeriesDesigns.sources(books: books, fonts: fonts), [1: 2, 2: 2, 3: 2],
            "Book 2 is first in City Watch")
        XCTAssertEqual(
            SeriesDesigns.sources(
                books: books, fonts: fonts, links: [2: link(2, standsAlone: true)]),
            [1: 1, 3: 1])
    }

    func testANewLookCopiesTheEarliestUsableOriginalDesign() {
        func design(_ id: Int, day: Double, family: String = "Oswald", reuse: Bool = false)
            -> SpineDesignV1
        {
            SpineDesignV1(
                version: 1, accountID: "account", bookID: id,
                workItemHash: SpineCloudIdentity.workItemHash(accountID: "account", book: book(id)),
                coverHash: String(repeating: "b", count: 64), generatorVersion: "ios-pcc-v2",
                generatedAt: Date(timeIntervalSince1970: day * 86_400), backgroundHex: "#1F3A5A",
                foregroundHex: "#F4EEE2", accentHex: "#D8CBB0", typeface: "sans", weight: 700,
                uppercase: false, fontFamily: family, fontPostScriptName: "Oswald-Bold",
                provenance: reuse ? "series-reuse:9" : nil)
        }
        let members = (1...4).map { book($0) }
        let designs = [
            1: design(1, day: 1, reuse: true), 2: design(2, day: 3),
            3: design(3, day: 2), 4: design(4, day: 0, family: "Dancing Script"),
        ]
        let copied = SeriesDesigns.lookDesign(of: members, designs: designs)
        XCTAssertEqual(copied?.bookID, 3)
        XCTAssertEqual(copied?.fontFamily, "Oswald", "The look copies the design as stored")
        XCTAssertEqual(copied?.fontPostScriptName, "Oswald-Bold")
        XCTAssertEqual(
            SeriesDesigns.lookDesign(of: members, designs: [1: designs[1]!, 4: designs[4]!])?
                .bookID, 1, "Reuse copies count only when no member has an original")
        XCTAssertNil(SeriesDesigns.lookDesign(of: members, designs: [4: designs[4]!]))
        var onDevice = designs[3]!
        onDevice.provenance = "model:apple/on-device"
        XCTAssertEqual(
            SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: onDevice,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .provenance, "model:apple/on-device", "A look keeps its design's model tier")
        onDevice.provenance =
            "series-reuse:9 model:apple/on-device generated-colors:1A2B3C,F4E9D0,C08040"
        XCTAssertEqual(
            SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: onDevice,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .provenance, "model:apple/on-device", "A look copies only the model token")
        var standIn = designs[3]!
        standIn.provenance = "series-reuse:9 model:local font:system"
        XCTAssertEqual(
            SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: standIn,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .provenance, "model:local font:system", "A stand-in's look still awaits its font")
        onDevice.provenance = "generated-colors:1A2B3C,F4E9D0,C08040"
        XCTAssertNil(
            SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: onDevice,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .provenance, "A recolored Private Cloud Compute design gives a look no provenance")
        XCTAssertEqual(
            SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: onDevice,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .editedAt, Date(timeIntervalSince1970: 1_000),
            "A look in the reader's colors counts as edited, so no upgrade replaces it")
        onDevice.provenance = "reader-font"
        XCTAssertEqual(
            SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: onDevice,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .editedAt, Date(timeIntervalSince1970: 1_000),
            "A look in the reader's font counts as edited, so no upgrade replaces it")
        onDevice.provenance = "model:apple/on-device"
        XCTAssertNil(
            SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: onDevice,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .editedAt, "A look in the generator's colors stays unedited")
        var tagged = designs[2]!
        tagged.provenance = "generated-colors:1A2B3C,F4E9D0,C08040 series-reuse:9"
        XCTAssertTrue(tagged.isSeriesReuse, "Any provenance token can mark a reuse copy")
        tagged.provenance = "no-series-reuse:9"
        XCTAssertFalse(tagged.isSeriesReuse, "Only a token that starts with the tag counts")
        var renamed = members
        renamed[2].title = "Renamed"
        XCTAssertEqual(
            SeriesDesigns.lookDesign(of: renamed, designs: designs)?.bookID, 2,
            "A design made before the book changed doesn't count")
        var unnamed = designs[3]!
        unnamed.fontFamily = nil
        unnamed.fontPostScriptName = "Pacifico-Regular"
        XCTAssertFalse(
            SeriesDesigns.isUsableSource(unnamed),
            "A design that names a blocked face only by PostScript name can't start a look")
    }

    func testBooksOfAGroupWithALookDrawTheLookUnlessTheyKeepTheirOwn() throws {
        let books = [book(1, position: 1), book(2, position: 2), book(3, position: 3)]
        let own = companionDesign(3, family: "Oswald", postScriptName: "Oswald-Bold")
        let look = SeriesLookV1(
            accountID: "account", seriesID: 7, group: "|mattdinniman", sourceBookID: 2,
            origin: "ios-pcc-v2", createdAt: Date(timeIntervalSince1970: 1_000),
            backgroundHex: "#102030", foregroundHex: "#F0E0D0", accentHex: "#C0A060",
            typeface: "serif", weight: 600, uppercase: false, fontFamily: "EB Garamond",
            fontPostScriptName: "EBGaramond-SemiBold", instanceWeight: 600)
        let drawing = LibraryModel.seriesDrawing(
            of: books, designs: [3: own], links: [3: link(3, ownLook: true)],
            looks: [look.key: look])
        XCTAssertTrue(drawing.sources.isEmpty, "A group with a look lends no book's design")
        let first = try XCTUnwrap(drawing.looks[1])
        XCTAssertEqual(first.bookID, 1)
        XCTAssertEqual(first.backgroundHex, "#102030")
        XCTAssertEqual(first.fontPostScriptName, "EBGaramond-SemiBold")
        XCTAssertEqual(first.generatorVersion, "ios-pcc-v2")
        XCTAssertEqual(drawing.looks[2]?.backgroundHex, "#102030")
        XCTAssertNil(drawing.looks[3], "A book that keeps its own look draws its design")

        let without = LibraryModel.seriesDrawing(of: books, designs: [3: own])
        XCTAssertEqual(without.sources[2]?.id, 1, "Without a look, the best-ranked book lends")
    }

    /// The Apple TV names a design's model as the iPhone and Mac do, from the design alone.
    func testDesignsNameTheModelThatMadeThem() {
        func madeBy(_ provenance: String?, generator: String = "ios-pcc-v2") -> String {
            SpineDesignV1(
                version: 1, accountID: "account", bookID: 1,
                workItemHash: String(repeating: "a", count: 64),
                coverHash: String(repeating: "b", count: 64), generatorVersion: generator,
                generatedAt: Date(timeIntervalSince1970: 0), backgroundHex: "#1F3A5A",
                foregroundHex: "#F4EEE2", accentHex: "#D8CBB0", typeface: "serif", weight: 700,
                uppercase: false, provenance: provenance
            )
            .madeBy.name
        }
        let gemini = "Google Gemini (gemini-3.8-flash)"
        XCTAssertEqual(madeBy("model:google/gemini-3.8-flash"), gemini)
        XCTAssertEqual(madeBy("series-reuse:8 model:google/gemini-3.8-flash"), gemini)
        XCTAssertEqual(madeBy("model:anthropic/claude-haiku-5-5"), "Anthropic (claude-haiku-5-5)")
        XCTAssertEqual(madeBy("model:openAI/gpt-6-luna"), "OpenAI (gpt-6-luna)")
        XCTAssertEqual(madeBy("model:custom/qwen3-vl"), "OpenAI-compatible endpoint (qwen3-vl)")
        XCTAssertEqual(madeBy(nil), "Private Cloud Compute")
        XCTAssertEqual(madeBy("model:apple/on-device"), "Apple on-device model")
        XCTAssertEqual(madeBy(nil, generator: "mac-foundation-models-v1"), "Apple on-device model")
        XCTAssertEqual(
            madeBy("model:local", generator: "mac-foundation-models-v2"), "Apple on-device model")
        XCTAssertEqual(madeBy("model:local font:system"), "Default styling")
        XCTAssertEqual(madeBy(nil, generator: SeriesLookV1.localOrigin), "Default styling")
    }

    /// Mirrors the iPhone companion's `SpineDesignV1.modelToken`, so a look copied from a design
    /// records the same tier whichever device creates it.
    func testALookRecordsItsDesignsTierAsTheIPhoneReadsIt() {
        func look(_ provenance: String?, generator: String) -> String? {
            let design = SpineDesignV1(
                version: 1, accountID: "account", bookID: 1,
                workItemHash: String(repeating: "a", count: 64),
                coverHash: String(repeating: "b", count: 64), generatorVersion: generator,
                generatedAt: Date(timeIntervalSince1970: 0), backgroundHex: "#1F3A5A",
                foregroundHex: "#F4EEE2", accentHex: "#D8CBB0", typeface: "serif", weight: 700,
                uppercase: false, provenance: provenance)
            return SeriesLookV1(
                key: SeriesLookKey(seriesID: 7, group: "|mattdinniman"), design: design,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            .provenance
        }
        XCTAssertNil(look(nil, generator: "ios-pcc-v2"), "Private Cloud Compute records none")
        XCTAssertEqual(look(nil, generator: "mac-foundation-models-v1"), "model:apple/on-device")
        XCTAssertEqual(
            look("model:local", generator: "mac-foundation-models-v2"), "model:apple/on-device")
        XCTAssertEqual(look(nil, generator: "other-generator-v1"), "model:local")
        XCTAssertEqual(
            look("font:system", generator: "other-generator-v1"), "model:local font:system")
        XCTAssertEqual(
            look("model:google/gemini-3.8-flash", generator: "ios-pcc-v2"),
            "model:google/gemini-3.8-flash")
    }

    /// **Settings → Spines** counts the design each book draws: its series look, with the look's
    /// model, else its series source's design, else its own, and the books that draw none.
    func testSpineSettingsCountTheDesignEachBookDraws() {
        let series = [book(1, position: 1), book(2, position: 2), book(3, position: 3)]
        let look = SeriesLookV1(
            accountID: "account", seriesID: 7, group: "|mattdinniman", sourceBookID: 2,
            origin: "ios-pcc-v2", createdAt: Date(timeIntervalSince1970: 1_000),
            backgroundHex: "#102030", foregroundHex: "#F0E0D0", accentHex: "#C0A060",
            typeface: "serif", weight: 600, uppercase: false,
            provenance: "model:google/gemini-3.8-flash")
        let drawing = LibraryModel.seriesDrawing(
            of: series, links: [3: link(3, ownLook: true)], looks: [look.key: look])
        var onDevice = companionDesign(4, family: nil, postScriptName: nil)
        onDevice.provenance = "model:apple/on-device"
        let lender = book(6, series: 9)
        let others = [book(4, series: nil), book(5, series: nil), lender, book(7, series: 9)]
        let makers = SpineDesignMakers(
            books: series + others,
            designs: [
                3: companionDesign(3, family: nil, postScriptName: nil), 4: onDevice,
                6: companionDesign(6, family: nil, postScriptName: nil),
            ],
            sources: [6: lender, 7: lender], looks: drawing.looks)
        XCTAssertEqual(
            makers.makers,
            [
                .init(name: "Private Cloud Compute", books: 3),
                .init(name: "Google Gemini (gemini-3.8-flash)", books: 2),
                .init(name: "Apple on-device model", books: 1),
            ])
        XCTAssertEqual(makers.undesigned, 1, "Book 5 draws Book Wall's own look")
    }

    func testBookWallsLocalLookBecomesAPortableSeriesLook() {
        let key = SeriesLookKey(seriesID: 7, group: "|mattdinniman")
        func local(_ face: String) -> SeriesLookV1 {
            let style = BookWallLocalSpine.Style(
                background: StyleColor(red: 0, green: 0.2, blue: 0.4),
                foreground: StyleColor(red: 1, green: 1, blue: 1),
                typography: .init(fontName: face))
            return SeriesLookV1(
                key: key, localStyle: style, book: book(4), accountID: "account",
                createdAt: Date(timeIntervalSince1970: 1_000))
        }
        let georgia = local("Georgia-Bold")
        XCTAssertTrue(georgia.isValid(accountID: "account", key: key))
        XCTAssertEqual(georgia.origin, "tvos-local-v1")
        XCTAssertEqual(georgia.sourceBookID, 4)
        XCTAssertEqual(georgia.backgroundHex, "#003366")
        XCTAssertEqual(georgia.accentHex, georgia.foregroundHex)
        XCTAssertEqual(georgia.typeface, "serif")
        XCTAssertEqual(georgia.weight, 700)
        XCTAssertFalse(georgia.uppercase)
        XCTAssertEqual(georgia.fontPostScriptName, "Georgia-Bold")
        XCTAssertNil(georgia.fontFamily)
        XCTAssertNil(georgia.instanceWeight)
        XCTAssertNil(georgia.provenance, "The local origin marks the look's tier")
        XCTAssertEqual(local("ArialRoundedMTBold").typeface, "rounded")
        XCTAssertEqual(local("CourierNewPS-BoldMT").typeface, "monospaced")
        XCTAssertEqual(local("Futura-Bold").typeface, "sans")
        XCTAssertEqual(local(SpineFontPolicy.impactReplacement).fontFamily, "Bebas Neue")
    }

    private func companionDesign(
        _ bookID: Int, family: String?, postScriptName: String?, weight: Int = 700
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: "account", bookID: bookID,
            workItemHash: String(repeating: "a", count: 64),
            coverHash: String(repeating: "b", count: 64), generatorVersion: "ios-pcc-v2",
            generatedAt: Date(timeIntervalSince1970: 1_000_000), backgroundHex: "#1F3A5A",
            foregroundHex: "#F4EEE2", accentHex: "#D8CBB0", typeface: "serif", weight: weight,
            uppercase: true, fontFamily: family, fontPostScriptName: postScriptName)
    }

    func testCompanionDesignsLetterOnlyInAllowedUprightFaces() {
        func typography(_ family: String, _ name: String) -> BookWallLocalSpine.Typography {
            BookWallLocalSpine.typography(
                for: book(1), design: companionDesign(1, family: family, postScriptName: name))
        }
        XCTAssertEqual(typography("EB Garamond", "EBGaramond-Bold").fontName, "EBGaramond-Bold")
        XCTAssertEqual(typography("Impact", "Impact").fontName, SpineFontPolicy.impactReplacement)
        // A slanted script shows in its stand-in family at the design's weight, else in the
        // stand-in's Regular face. An italic shows in its upright face.
        let script = typography("Dancing Script", "DancingScript-Bold")
        XCTAssertEqual(script.standInFamily, "Patrick Hand")
        XCTAssertEqual(script.weight, 700)
        XCTAssertEqual(script.fontName, "PatrickHand-Regular")
        XCTAssertEqual(typography("Lora", "Lora-BoldIt").fontName, "Lora-Bold")
        for (family, name) in [("EB Garamond", "EBGaramond-Bold"), ("Lora", "Lora-BoldIt")] {
            XCTAssertNil(typography(family, name).standInFamily, name)
        }
        XCTAssertNil(typography("Impact", "Impact").standInFamily, "Bebas Neue ships with tvOS")
        XCTAssertEqual(typography("Lora", "Lora-Bold").typeface, "serif")
        XCTAssertTrue(typography("Lora", "Lora-Bold").uppercase)
    }

    func testCompanionDesignsDownloadTheFaceTheyDrawIn() {
        func request(_ family: String?, _ name: String, weight: Int = 700) -> String? {
            BookWallPreparation.fontRequest(
                for: companionDesign(1, family: family, postScriptName: name, weight: weight)
            )
            .map { "\($0.family):\($0.weight)" }
        }
        XCTAssertEqual(request("EB Garamond", "EBGaramond-Bold"), "EB Garamond:700")
        XCTAssertEqual(request("Lora", "Lora-BoldIt"), "Lora:700")
        // A slanted family downloads its stand-in at the design's weight, never itself.
        XCTAssertEqual(request("Dancing Script", "DancingScript-Bold"), "Patrick Hand:700")
        XCTAssertEqual(
            request("Dancing Script", "DancingScript-Bold", weight: 500), "Patrick Hand:500")
        XCTAssertEqual(request("Bangers", "Bangers-Regular"), "Bungee:700")
        XCTAssertEqual(request(nil, "Pacifico-Regular", weight: 600), "Patrick Hand:600")
        // A face whose letters lean downloads the upright stand-in too.
        XCTAssertEqual(request("Caveat", "Caveat-Regular"), "Patrick Hand:700")
        XCTAssertNil(request("Impact", "Impact"), "Bebas Neue ships with tvOS")
        for standIn in Set(SpineFontPolicy.slantedReplacements.values) {
            XCTAssertNotNil(SpineFontPolicy.standInFamilies[standIn], standIn)
        }
    }

    func testSeriesSourcesJudgeCompanionDesignsByTheirFace() {
        let books = [book(1, position: 1), book(2, position: 2), book(3, position: 3)]
        let allowed =
            LibraryModel.seriesDrawing(
                of: books,
                designs: [1: companionDesign(1, family: "Oswald", postScriptName: "Oswald-Bold")]
            )
            .sources
        XCTAssertEqual(allowed[2]?.id, 1)
        // A design saved in a blocked face draws in its upright stand-in, which leads the
        // series, as on the iPhone.
        for (family, name) in [
            ("Pacifico", "Pacifico-Regular"), ("Impact", "Impact"), ("Lora", "Lora-BoldIt"),
        ] {
            let remapped =
                LibraryModel.seriesDrawing(
                    of: books,
                    designs: [1: companionDesign(1, family: family, postScriptName: name)]
                )
                .sources
            XCTAssertEqual(remapped[2]?.id, 1, name)
            XCTAssertEqual(remapped[3]?.id, 1, name)
        }
    }

    func testSourcesRankByPositionThenFinishThenID() {
        XCTAssertTrue(SeriesDesigns.ranksBefore(book(9, position: 1), book(1, position: 2)))
        XCTAssertTrue(
            SeriesDesigns.ranksBefore(book(9, position: 3), book(1)),
            "A missing position ranks last")
        XCTAssertTrue(
            SeriesDesigns.ranksBefore(
                book(9, position: 2, finished: "2025-01-01"),
                book(1, position: 2, finished: "2026-01-01")))
        XCTAssertTrue(
            SeriesDesigns.ranksBefore(
                book(9, position: 2, finished: "2026-01-01"), book(1, position: 2)),
            "A missing finish ranks last")
        XCTAssertTrue(
            SeriesDesigns.ranksBefore(
                book(1, position: 2), book(9, position: 2, finished: "unknown date")),
            "A finish that doesn't parse ranks as missing")
        XCTAssertTrue(SeriesDesigns.ranksBefore(book(1, position: 2), book(9, position: 2)))
    }

    func testEachSeriesDrawsWithItsBestRankedUsableBook() {
        let books = [
            book(1, position: 1), book(2, position: 2), book(3, position: 3),
            book(4, position: 4, author: "Someone Else"), book(5, series: nil),
            book(6, series: 9, position: 1), book(7, series: 9, position: 2),
        ]
        var fonts = Dictionary(uniqueKeysWithValues: books.map { ($0.id, "Georgia-Bold") })
        fonts[1] = "Impact"
        fonts[6] = "Georgia-BoldItalic"
        let sources = SeriesDesigns.sources(books: books, fonts: fonts)
        XCTAssertNil(
            sources[1], "An Impact book ranks first, so it lends to no one and draws its own")
        XCTAssertEqual(sources[2], 2, "A source maps to itself")
        XCTAssertEqual(sources[3], 2)
        XCTAssertNil(sources[4], "A book by another author keeps its own design")
        XCTAssertNil(sources[5])
        XCTAssertNil(sources[6], "An italic book ranks first and draws its own, remapped upright")
        XCTAssertNil(sources[7], "Only an earlier book lends its design")
        XCTAssertEqual(
            SeriesDesigns.sources(books: books, fonts: fonts) { book, _ in book.id != 3 }[3], nil,
            "A book the source's font can't letter keeps its own design")

        let library = LibraryModel.seriesDrawing(of: books).sources
        XCTAssertEqual(library[3]?.id, 1, "Book Wall fonts are never blocked")
        XCTAssertEqual(library[1]?.id, 1)
        XCTAssertNil(library[4])
    }

    func testSourcesLendOnlyOwnDesignsInAnyBookOrder() {
        // Books 1 and 2 share a first author; book 3's first author is book 2's second. Book 2
        // draws book 1's design, and book 3 draws its own.
        let books = [
            book(1, position: 1, author: "Ann Author"),
            book(2, position: 2, author: "Ann Author, Co Writer"),
            book(3, position: 3, author: "Co Writer"),
        ]
        let fonts = Dictionary(uniqueKeysWithValues: books.map { ($0.id, "Georgia-Bold") })
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            XCTAssertEqual(
                SeriesDesigns.sources(books: order.map { books[$0] }, fonts: fonts),
                [1: 1, 2: 1], "\(order)")
        }
    }

    @MainActor
    func testAFontWithoutTheLettersGlyphsCannotLetterABook() {
        func canLetter(_ book: Book, _ fontName: String) -> Bool {
            BookWallPreparation.canLetter(
                book, in: BookWallLocalSpine.Typography(fontName: fontName))
        }
        XCTAssertTrue(canLetter(book(1, title: "Carl's Doomsday"), "Georgia-Bold"))
        XCTAssertFalse(canLetter(book(2, title: "ダンジョン"), "Georgia-Bold"))
        XCTAssertTrue(
            canLetter(book(3, title: "ダンジョン"), "NoSuchFont-Bold"),
            "A face that isn't loaded letters in the system face")
        XCTAssertTrue(
            canLetter(book(4, title: "Cafe\u{301}"), "Georgia-Bold"),
            "Decomposed accents are checked in precomposed form")
        XCTAssertTrue(
            canLetter(book(5, author: "", title: ""), "Georgia-Bold"),
            "A spine with nothing to letter passes")
        XCTAssertEqual(
            SeriesDesigns.lettering(of: book(4, title: "Straße"), uppercase: true),
            "STRASSE MATT DINNIMAN", "A design in capitals is checked in capitals")
        XCTAssertEqual(SeriesDesigns.lettering(of: book(5, title: "Mort")), "Mort Matt Dinniman")
    }

    @MainActor
    func testTheWallDrawsALookOnlyOnBooksItsFaceCanLetter() {
        let latin = book(1, title: "Carl's Doomsday")
        let japanese = book(2, title: "ダンジョン")
        let uninstalled = book(3, title: "ダンジョン")
        let own = companionDesign(2, family: "Oswald", postScriptName: "Oswald-Bold")
        let look = companionDesign(1, family: nil, postScriptName: "Georgia-Bold")
        let missing = companionDesign(3, family: nil, postScriptName: "NoSuchFont-Bold")
        let drawn = BookWallPreparation.drawnDesigns(
            of: [latin, japanese, uninstalled], designs: [2: own],
            looks: [1: look, 2: look, 3: missing])
        XCTAssertEqual(drawn[1], look, "Georgia letters the Latin title")
        XCTAssertEqual(drawn[2], own, "The Japanese title keeps its companion design")
        XCTAssertEqual(drawn[3], missing, "A face that isn't installed letters in the system face")
    }

    /// A book drawing with its source's design takes the source's cloth and font, and keeps its
    /// own cover's fold at the front joint.
    @MainActor
    func testTheWallDrawsTheSourcesStyleWithTheBooksOwnFold() async throws {
        func cover(_ color: UIColor, edge: UIColor) throws -> CGImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(
                size: CGSize(width: 400, height: 600), format: format
            )
            .image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
                edge.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 24, height: 600))
            }
            return try XCTUnwrap(image.cgImage)
        }
        let source = book(1, position: 1)
        let member = book(2, position: 2, title: "The Gate of the Feral Gods")
        let rasterizer = BookWallRasterizer()
        let design = await rasterizer.style(
            for: source, cover: try cover(.red, edge: .red), design: nil)
        let slot = try XCTUnwrap(BookWallLayout(books: [member]).slots.first)
        let images = await rasterizer.render(
            slot: slot, cover: try cover(.blue, edge: .green), source: design, design: nil,
            fontStyle: .serif)
        XCTAssertEqual(images.style, design, "The book wears its source's colors and font")
        let spine = try XCTUnwrap(images.spine)
        let cloth = try pixel(spine, x: spine.width / 30, y: spine.height / 2)
        let joint = try pixel(spine, x: spine.width / 30, y: 1)
        XCTAssertGreaterThan(cloth.red, cloth.green + 0.3, "The cloth is the source's red")
        XCTAssertGreaterThan(joint.green, cloth.green + 0.2, "The fold is the book's own green")
        let board = try XCTUnwrap(images.cover)
        let art = try pixel(board, x: board.width / 2, y: board.height / 2)
        XCTAssertGreaterThan(art.blue, art.red + 0.3, "The board keeps the book's own cover")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (
        red: Double, green: Double, blue: Double
    ) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(x), y: CGFloat(y) - CGFloat(image.height) + 1,
                width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }
}
