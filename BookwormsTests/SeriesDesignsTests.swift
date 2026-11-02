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

    /// A companion design made for `book` as it is now, so it can lend (`SeriesDesigns.isCurrent`).
    private func design(
        for book: Book, family: String? = "EB Garamond",
        postScriptName: String? = "EBGaramond-Bold"
    ) -> SpineDesignV1 {
        companionDesign(
            book.id, family: family, postScriptName: postScriptName,
            workItemHash: SpineCloudIdentity.workItemHash(accountID: "account", book: book))
    }

    private func designs(for books: [Book]) -> [Int: SpineDesignV1] {
        Dictionary(uniqueKeysWithValues: books.map { ($0.id, design(for: $0)) })
    }

    private func sameLook(_ book: Book, _ other: Book) -> Bool {
        guard let key = SeriesDesigns.lookKey(of: book, link: nil) else { return false }
        return key == SeriesDesigns.lookKey(of: other, link: nil)
    }

    func testBooksMatchOnTheSameSeriesAndFirstAuthor() {
        let carl = book(1)
        XCTAssertTrue(sameLook(carl, book(2, author: "matt dinnimán")))
        XCTAssertTrue(sameLook(carl, book(3, author: "Matt Dinniman, Jeff Hays")))
        XCTAssertFalse(
            sameLook(carl, book(3, author: "Jeff Hays, Matt Dinniman")),
            "Only the first author counts, so a look group has one key")
        XCTAssertTrue(sameLook(carl, book(4, author: "Matt  Dinniman.")))
        XCTAssertFalse(sameLook(carl, book(5, author: "Someone Else")))
        XCTAssertFalse(sameLook(carl, book(6, series: 8)))
        XCTAssertFalse(sameLook(book(7, series: nil), book(8, series: nil)))
    }

    func testDiscworldBooksShareADesignOnlyWithinTheirGroup() {
        func discworld(_ id: Int, _ title: String) -> Book {
            book(id, series: 1018, author: "Terry Pratchett", title: title)
        }
        let guards = discworld(1, "Guards! Guards!")
        XCTAssertTrue(sameLook(guards, discworld(2, "THUD")))
        XCTAssertTrue(sameLook(guards, discworld(3, "Night Watch: A Discworld Novel")))
        XCTAssertFalse(sameLook(guards, discworld(4, "Mort")))
        XCTAssertTrue(
            sameLook(
                discworld(5, "The Science of Discworld II: The Globe"),
                discworld(6, "The Science of Discworld")))
        // A book no group names keeps its own design.
        let maurice = discworld(7, "The Amazing Maurice and His Educated Rodents")
        XCTAssertFalse(sameLook(maurice, discworld(8, "The Amazing Maurice")))
    }

    private func link(
        _ bookID: Int, series: Int? = nil, standsAlone: Bool = false, ownLook: Bool = false
    ) -> SeriesLinkV1 {
        SeriesLinkV1(
            accountID: "account", bookID: bookID, linkedSeriesID: series,
            standsAlone: standsAlone, ownLook: ownLook, chosenAt: Date(timeIntervalSince1970: 0))
    }

    func testLookGroupsLeaveOutBooksThatKeepTheirOwnLook() {
        let books = [book(1), book(2), book(3), book(4, series: nil)]
        let groups = SeriesDesigns.lookGroups(books, links: [2: link(2, ownLook: true)])
        XCTAssertEqual(
            groups.mapValues { $0.map(\.id) },
            [SeriesLookKey(seriesID: 7, group: "|mattdinniman"): [1, 3]])
        XCTAssertEqual(
            SeriesDesigns.authorKeys(of: book(5, author: "Matt Dinniman, Jeff Hays")),
            ["mattdinniman", "jeffhays"])
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
        XCTAssertEqual(
            SeriesDesigns.label(of: SeriesMembership(seriesID: 1, name: "Series 1", size: 3)),
            "Series 1", "A label without a place is the series' name")
        var unlisted = older
        unlisted.seriesMemberships = []
        XCTAssertNil(
            SeriesDesigns.shownSeries(of: unlisted, link: nil),
            "A book Hardcover lists in no series names none")
    }

    private func member(_ id: Int, _ memberships: [SeriesMembership]) -> Book {
        Book(
            id: id, title: "Volume \(id)", author: "Terry Pratchett",
            seriesMemberships: memberships)
    }

    private func membership(_ seriesID: Int, position: Double? = nil) -> SeriesMembership {
        SeriesMembership(seriesID: seriesID, name: "Series \(seriesID)", position: position)
    }

    /// Mirrors the iPhone companion's `SeriesLookTests`, so both apps list a series alike.
    func testSeriesListingMarksTheReadersBooksInOrder() {
        func entry(_ id: Int, _ position: Double) -> SeriesInfo.SeriesBook {
            SeriesInfo.SeriesBook(
                id: id, title: "Volume \(id)", position: position, releaseYear: nil,
                coverURL: nil)
        }
        let info = SeriesInfo(
            id: 10605, name: "Discworld - Industrial Revolution",
            books: [entry(1, 1), entry(2, 2), entry(3, 3)])
        // The reader's edition of the second book has its own ID; a novella sits between books.
        let edition = member(20, [membership(10605, position: 2)])
        let novella = member(21, [membership(10605, position: 2.5)])
        let first = member(1, [membership(10605, position: 1)])
        let elsewhere = member(22, [membership(99, position: 1)])
        let library = [elsewhere, novella, edition, first]

        let listing = SeriesEntry.listings(infos: [10605: info], library: library)[10605] ?? []
        XCTAssertEqual(listing.map(\.position), [1, 2, 2.5, 3])
        XCTAssertEqual(listing.map(\.book?.id), [1, 20, 21, nil])

        // Without Hardcover's list, the library's own books in the series show.
        let older = book(23, series: 10605, position: 3)
        XCTAssertEqual(
            SeriesEntry.listings(infos: [:], library: library + [older])[10605]?.map(\.id),
            [1, 20, 21, 23])
    }

    /// The series label opens for a book in two or more series, or for one whose series lists
    /// two or more books, as the iPhone and Mac decide.
    func testSeriesOpensOnlyWithMoreThanTheBookToList() {
        func opens(_ book: Book, infos: [SeriesInfo], library: [Book]) -> Bool {
            let all = book.seriesMemberships ?? []
            let listings = SeriesEntry.listings(
                infos: Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) }),
                library: library)
            return ShownSeries(
                membership: all[0], all: all, infos: [:],
                listings: listings.filter { id, _ in all.contains { $0.seriesID == id } }
            )
            .opens
        }
        let alone = member(30, [membership(500, position: 1)])
        let solo = SeriesInfo(
            id: 500, name: "Series 500",
            books: [.init(id: 30, title: "A Volume", position: 1, releaseYear: nil, coverURL: nil)])
        XCTAssertFalse(opens(alone, infos: [solo], library: [alone]))
        XCTAssertFalse(opens(alone, infos: [], library: [alone]))

        // A novella the reader owns joins the list, so the series has two books to show.
        let novella = member(32, [membership(500, position: 1.5)])
        XCTAssertTrue(opens(alone, infos: [solo], library: [alone, novella]))
        let listed = SeriesInfo(
            id: 500, name: "Series 500",
            books: solo.books + [
                .init(id: 33, title: "A Sequel", position: 2, releaseYear: nil, coverURL: nil)
            ])
        XCTAssertTrue(opens(alone, infos: [listed], library: [alone]))

        // Two series to choose between open even with one book each.
        let both = member(34, [membership(500, position: 1), membership(501)])
        XCTAssertTrue(opens(both, infos: [], library: [both]))
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
        XCTAssertEqual(
            SeriesDesigns.sources(books: books, designs: designs(for: books)), [1: 2, 2: 2, 3: 2],
            "Book 2 is first in City Watch")
        XCTAssertEqual(
            SeriesDesigns.sources(
                books: books, designs: designs(for: books),
                links: [2: link(2, standsAlone: true)]),
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

        XCTAssertEqual(drawing.mates[1]?.map(\.id), [1, 2], "The look's books share its face")
        XCTAssertNil(drawing.mates[3])

        let without = LibraryModel.seriesDrawing(
            of: books, designs: [1: design(for: books[0]), 3: own])
        XCTAssertEqual(without.sources[2]?.id, 1, "Without a look, the best-ranked book lends")
        XCTAssertEqual(without.mates[2]?.map(\.id), [1, 2, 3])

        var progressed = books
        progressed[1].progress = 0.5
        progressed[1].rating = 4
        let synced = LibraryModel.seriesDrawing(
            of: progressed, designs: [1: design(for: books[0]), 3: own])
        XCTAssertEqual(
            synced.mates, without.mates, "Fields the glyph check doesn't read leave mates equal")
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
        _ bookID: Int, family: String?, postScriptName: String?, weight: Int = 700,
        workItemHash: String = String(repeating: "a", count: 64)
    ) -> SpineDesignV1 {
        SpineDesignV1(
            version: 1, accountID: "account", bookID: bookID, workItemHash: workItemHash,
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

    @MainActor
    func testFontLoadStopsDownloadsAtANetworkFailureAndReportsWhatRegistered() async {
        // Fictional faces that no test host registers.
        let designs = [
            companionDesign(1, family: "Fictional Serif", postScriptName: "FictionalSerif-Bold"),
            companionDesign(2, family: "Fictional Sans", postScriptName: "FictionalSans-Bold"),
            companionDesign(3, family: "Fictional Slab", postScriptName: "FictionalSlab-Bold"),
        ]
        var requested: [String] = []
        let offline = await BookWallPreparation.loadFonts(for: designs) { family, _, network in
            requested.append("\(family):\(network)")
            throw URLError(.timedOut)
        }
        XCTAssertEqual(offline, .init(registered: false, interruption: .timedOut))
        XCTAssertEqual(
            requested,
            ["Fictional Serif:true", "Fictional Sans:false", "Fictional Slab:false"],
            "A network failure stops the downloads but not the cache reads")

        // A face cached on disk registers after another face's network failure.
        let cached = await BookWallPreparation.loadFonts(for: designs) { family, _, network in
            if network { throw URLError(.notConnectedToInternet) }
            if family != "Fictional Slab" { throw URLError(.notConnectedToInternet) }
        }
        XCTAssertEqual(cached, .init(registered: true, interruption: .notConnectedToInternet))

        requested = []
        let retried = await BookWallPreparation.loadFonts(for: designs) { family, _, _ in
            requested.append(family)
        }
        XCTAssertEqual(retried, .init(registered: true))
        XCTAssertEqual(requested, ["Fictional Serif", "Fictional Sans", "Fictional Slab"])

        let rejected = await BookWallPreparation.loadFonts(for: designs) { _, _, _ in
            throw AIError.unavailableFont
        }
        XCTAssertEqual(rejected, .init(registered: false))
    }

    /// Prepares one coverless book whose companion design names a fictional face, so every
    /// font request goes to `download`, and returns the preparation and the requests it made.
    @MainActor
    private func prepareWall(
        download: @escaping (_ call: Int, _ preparation: BookWallPreparation) throws -> Void
    ) async -> (preparation: BookWallPreparation, calls: Int) {
        // The download closure reads the preparation it belongs to through this reference.
        @MainActor final class Reference { weak var preparation: BookWallPreparation? }
        let reference = Reference()
        var calls = 0
        let preparation = BookWallPreparation { _, _, _ in
            calls += 1
            try download(calls, reference.preparation!)
        }
        reference.preparation = preparation
        let design = companionDesign(
            1, family: "Fictional Serif", postScriptName: "FictionalSerif-Bold")
        await preparation.prepare([book(1, series: nil)], sources: [:], designs: [1: design])
        return (preparation, calls)
    }

    @MainActor
    func testPreparationRetriesSkippedFontsOnceBeforeTheWallShows() async {
        let (preparation, calls) = await prepareWall { call, preparation in
            if call == 1 { throw URLError(.notConnectedToInternet) }
            XCTAssertNil(preparation.prepared, "The wall waits for the retry")
            XCTAssertEqual(preparation.completedCount, 1, "The retry keeps the progress")
        }
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(preparation.prepared)
        XCTAssertEqual(preparation.completedCount, 1)
        XCTAssertNil(preparation.failure)
    }

    @MainActor
    func testPreparationKeepsTheShownWallUntilItsReplacementIsReady() async throws {
        var firstID: UUID?
        var checks = 0
        let (preparation, _) = await prepareWall { _, preparation in
            // Requests after the first wall is ready come from its replacement's preparation.
            guard let firstID else { return }
            XCTAssertEqual(preparation.prepared?.id, firstID, "The shown wall stays")
            checks += 1
        }
        firstID = try XCTUnwrap(preparation.prepared).id
        await preparation.prepare(
            [book(1, series: nil)], sources: [:],
            designs: [
                1: companionDesign(1, family: "Other Serif", postScriptName: "OtherSerif-Bold")
            ])
        XCTAssertGreaterThan(checks, 0)
        XCTAssertNotEqual(preparation.prepared?.id, firstID, "The new wall replaces it")
    }

    @MainActor
    func testPreparationSkipsTheFontRetryAfterATimeout() async {
        let (preparation, calls) = await prepareWall { _, _ in throw URLError(.timedOut) }
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(preparation.prepared)
    }

    /// A font style change in Settings prepares the wall again, so its shelf labels, hint, and
    /// format icons follow the style.
    @MainActor
    func testAFontStyleChangePreparesTheWallAgain() async throws {
        let (preparation, _) = await prepareWall { _, _ in throw URLError(.timedOut) }
        let wall = [book(1, series: nil)]
        let designs = [
            1: companionDesign(1, family: "Fictional Serif", postScriptName: "FictionalSerif-Bold")
        ]
        let firstID = try XCTUnwrap(preparation.prepared).id
        await preparation.prepare(wall, sources: [:], designs: designs, fontStyle: .serif)
        XCTAssertEqual(preparation.prepared?.id, firstID, "The same style keeps the wall")
        await preparation.prepare(wall, sources: [:], designs: designs, fontStyle: .sansSerif)
        XCTAssertNotEqual(preparation.prepared?.id, firstID, "A new style replaces the wall")
        XCTAssertEqual(preparation.prepared?.fontStyle, .sansSerif)
    }

    @MainActor
    func testPreparationCancelledDuringTheFontRetryPublishesNothing() async {
        let task = Task { @MainActor in
            await prepareWall { call, _ in
                if call == 1 { throw URLError(.notConnectedToInternet) }
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        let (preparation, calls) = await task.value
        XCTAssertEqual(calls, 2)
        XCTAssertNil(preparation.prepared, "A cancelled preparation never publishes its wall")
        XCTAssertNil(preparation.failure)
    }

    func testSeriesSourcesJudgeCompanionDesignsByTheirFace() {
        let books = [book(1, position: 1), book(2, position: 2), book(3, position: 3)]
        let allowed =
            LibraryModel.seriesDrawing(
                of: books,
                designs: [1: design(for: books[0], family: "Oswald", postScriptName: "Oswald-Bold")]
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
                    designs: [1: design(for: books[0], family: family, postScriptName: name)]
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

    func testEachSeriesDrawsWithItsBestRankedBookWithACurrentDesign() {
        let books = [
            book(1, position: 1), book(2, position: 2), book(3, position: 3),
            book(4, position: 4, author: "Someone Else"), book(5, series: nil),
            book(6, series: 9, position: 1), book(7, series: 9, position: 2),
            book(8, series: 9, position: 3),
        ]
        var designs = designs(for: books)
        designs[1] = nil
        designs[6] = companionDesign(6, family: nil, postScriptName: nil)
        let sources = SeriesDesigns.sources(books: books, designs: designs)
        XCTAssertNil(sources[1], "A book without a design lends to no one and draws its own")
        XCTAssertEqual(sources[2], 2, "A source maps to itself")
        XCTAssertEqual(sources[3], 2)
        XCTAssertNil(sources[4], "A book by another author keeps its own design")
        XCTAssertNil(sources[5])
        XCTAssertNil(sources[6], "A stale design draws its own book but lends to no one")
        XCTAssertEqual(sources[7], 7)
        XCTAssertEqual(sources[8], 7)

        let library = LibraryModel.seriesDrawing(of: books).sources
        XCTAssertTrue(library.isEmpty, "Local spines lend to no one, as on the iPhone")
    }

    func testSourcesLendOnlyOwnDesignsInAnyBookOrder() {
        // Books 1 and 2 share a first author; book 3's first author is book 2's second. Book 2
        // draws book 1's design, and book 3 draws its own.
        let books = [
            book(1, position: 1, author: "Ann Author"),
            book(2, position: 2, author: "Ann Author, Co Writer"),
            book(3, position: 3, author: "Co Writer"),
        ]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            XCTAssertEqual(
                SeriesDesigns.sources(books: order.map { books[$0] }, designs: designs(for: books)),
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

    /// A series keeps one font: when the shared face lacks a glyph for any book that draws it,
    /// every one of them letters the shared design in its system typeface.
    @MainActor
    func testASeriesLettersInTheSystemTypefaceWhenItsFaceLacksAGlyph() {
        let latin = book(1, title: "Carl's Doomsday")
        let japanese = book(2, title: "ダンジョン")
        let alsoLatin = book(3, title: "The Butcher's Masquerade")
        let look = companionDesign(1, family: nil, postScriptName: "Georgia-Bold")
        let looks = [1: look, 2: look, 3: look]
        let mixed = BookWallPreparation.drawnDesigns(
            of: [latin, alsoLatin], designs: [:], looks: looks,
            mates: [1: [latin, japanese], 2: [latin, japanese], 3: [alsoLatin]])
        XCTAssertEqual(
            mixed[1], look.inSystemTypeface,
            "A mate off the wall that Georgia can't letter moves the whole look to the system face")
        XCTAssertNil(mixed[1]?.fontPostScriptName)
        XCTAssertEqual(mixed[1]?.backgroundHex, look.backgroundHex, "The colors stay")
        XCTAssertEqual(mixed[3], look, "Georgia letters a look whose books are all Latin")

        let missing = companionDesign(1, family: nil, postScriptName: "NoSuchFont-Bold")
        XCTAssertEqual(
            BookWallPreparation.drawnDesigns(
                of: [japanese], designs: [:], looks: [2: missing], mates: [2: [latin, japanese]]
            )[2], missing, "A face that isn't installed letters in the system face anyway")

        let source = companionDesign(1, family: nil, postScriptName: "Georgia-Bold")
        let ranked = BookWallPreparation.drawnDesigns(
            of: [japanese], designs: [1: source], looks: [:], sources: [2: latin],
            mates: [2: [latin, japanese]])
        XCTAssertEqual(
            ranked[1], source.inSystemTypeface,
            "A source whose face can't letter a book that draws it letters in the system face")
        XCTAssertNil(ranked[2], "The book draws its source's entry")
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
