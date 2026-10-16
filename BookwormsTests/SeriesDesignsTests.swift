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

    func testANewLookCopiesTheEarliestOriginalDesignInItsUprightFace() {
        func design(_ id: Int, day: Double, family: String = "Oswald", reuse: Bool = false)
            -> SpineDesignV1
        {
            SpineDesignV1(
                version: 1, accountID: "account", bookID: id,
                workItemHash: String(repeating: "a", count: 64),
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
        // As on the iPhone, a design in a blocked face counts in its upright stand-in.
        let script = SeriesDesigns.lookDesign(of: members, designs: designs)
        XCTAssertEqual(script?.bookID, 4)
        XCTAssertEqual(script?.fontFamily, "Kalam")
        XCTAssertNil(script?.fontPostScriptName)
        XCTAssertEqual(
            SeriesDesigns.lookDesign(
                of: members, designs: [1: designs[1]!, 2: designs[2]!, 3: designs[3]!])?
                .bookID, 3)
        XCTAssertEqual(
            SeriesDesigns.lookDesign(of: members, designs: [1: designs[1]!])?.bookID, 1,
            "Reuse copies count only when no member has an original")
        XCTAssertNil(SeriesDesigns.lookDesign(of: members, designs: [:]))
    }

    func testDesignsInBlockedFacesMapToTheIPhonesUprightFamilies() {
        func allowed(_ family: String?, _ name: String?) -> SpineDesignV1 {
            var design = companionDesign(1, family: family, postScriptName: name)
            design.instanceWeight = 700
            return design.withAllowedFont
        }
        let kept = allowed("EB Garamond", "EBGaramond-Bold")
        XCTAssertEqual(kept.fontPostScriptName, "EBGaramond-Bold")
        XCTAssertEqual(kept.instanceWeight, 700)
        for (family, name, shown) in [
            ("Pacifico", "Pacifico-Regular", "Permanent Marker"), ("Bangers", nil, "Bungee"),
            ("Lora Italic", "Lora-Italic", "Lora"), ("Lora", "Lora-BoldIt", "Lora"),
            ("Impact", "Impact", "Bebas Neue"), (nil, "Impact", "Bebas Neue"),
        ] as [(String?, String?, String)] {
            let design = allowed(family, name)
            XCTAssertEqual(design.fontFamily, shown, name ?? family ?? "")
            XCTAssertNil(design.fontPostScriptName)
            XCTAssertNil(design.instanceWeight)
        }
        XCTAssertNil(allowed("Oblique", nil).fontFamily, "No upright family remains")
        XCTAssertNil(allowed(nil, "Lora-BoldIt").fontFamily)
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
        XCTAssertEqual(script.standInFamily, "Kalam")
        XCTAssertEqual(script.weight, 700)
        XCTAssertEqual(script.fontName, "Kalam-Regular")
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
        XCTAssertEqual(request("Dancing Script", "DancingScript-Bold"), "Kalam:700")
        XCTAssertEqual(request("Dancing Script", "DancingScript-Bold", weight: 500), "Kalam:500")
        XCTAssertEqual(request("Bangers", "Bangers-Regular"), "Bungee:700")
        XCTAssertEqual(request(nil, "Pacifico-Regular", weight: 600), "Permanent Marker:600")
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

    func testAFontWithoutTheLettersGlyphsCannotLetterABook() {
        XCTAssertTrue(
            SeriesDesigns.canLetter(book(1, title: "Carl's Doomsday"), fontName: "Georgia-Bold"))
        XCTAssertFalse(
            SeriesDesigns.canLetter(book(2, title: "ダンジョン"), fontName: "Georgia-Bold"))
        XCTAssertFalse(
            SeriesDesigns.canLetter(book(3), fontName: "NoSuchFont-Bold"),
            "A missing font letters nothing")
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
