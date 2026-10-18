import CoreText
import UIKit
import XCTest

@testable import Bookworms

final class BookWallLocalSpineTests: XCTestCase {
    @MainActor
    func testGenresSelectTwelveInstalledFaces() {
        let genres = [
            "Fantasy", "Science Fiction", "Mystery", "Horror", "Romance", "History",
            "Literary Fiction", "Memoir", "Young Adult", "Graphic Novel", "Poetry", "Humor",
        ]
        let names = genres.enumerated()
            .map { index, genre in
                BookWallLocalSpine.fontName(
                    for: Book(id: index + 1, title: "Book", author: "Author", genres: [genre]))
            }
        XCTAssertEqual(Set(names).count, 12)
        for name in names { XCTAssertNotNil(UIFont(name: name, size: 24), name) }
    }

    func testCoverColorsAlwaysProduceReadableText() {
        let book = Book(id: 1, title: "Book", author: "Author", genres: ["Fantasy"])
        for level in stride(from: 0.0, through: 1.0, by: 0.1) {
            let color = StyleColor(red: level, green: level, blue: level)
            let style = BookWallLocalSpine.style(
                for: book, samples: Array(repeating: color, count: 20))
            XCTAssertGreaterThanOrEqual(style.foreground.contrast(with: style.background), 4.5)
        }
    }

    @MainActor
    func testCoverSamplingUsesItsDominantColor() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
            .image { context in
                UIColor(red: 0.75, green: 0.12, blue: 0.18, alpha: 1).setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            }
        let cover = try XCTUnwrap(image.cgImage)
        let book = Book(id: 1, title: "Book", author: "Author")
        let style = BookWallLocalSpine.style(for: book, cover: cover)
        XCTAssertGreaterThan(style.background.red, style.background.green * 3)
        XCTAssertGreaterThanOrEqual(style.foreground.contrast(with: style.background), 4.5)
    }

    @MainActor
    func testEdgeColorsFollowTheCoversSpineSideFromHeadToTail() throws {
        // The spine side is red at the head and green at the tail; the rest of the art is blue.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 96))
            .image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 100, height: 96))
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 6, height: 48))
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 48, width: 6, height: 48))
            }
        let colors = BookWallLocalSpine.edgeColors(of: try XCTUnwrap(image.cgImage))
        XCTAssertEqual(colors.count, 48)
        let head = try XCTUnwrap(colors.first)
        let tail = try XCTUnwrap(colors.last)
        XCTAssertGreaterThan(head.red, 0.9)
        XCTAssertLessThan(head.blue, 0.1)
        XCTAssertGreaterThan(tail.green, 0.9)
        XCTAssertLessThan(tail.blue, 0.1)
    }

    @MainActor
    func testSpineCornersAreNearlySquare() {
        XCTAssertEqual(SpineView.cornerRadius(thickness: 20), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SpineView.cornerRadius(thickness: 40), 1)
        XCTAssertEqual(SpineView.cornerRadius(thickness: 160), 1)
    }

    @MainActor
    func testOnlyBooksAtLeast32MillimetersThickHaveStampedBands() {
        for id in 1...40 {
            let doorstopper = Book(id: id, title: "Book", author: "Author", pages: 1_100)
            let novel = Book(id: id, title: "Book", author: "Author", pages: 320)
            let unknown = Book(id: id, title: "Book", author: "Author")
            XCTAssertTrue(SpineView.stamps(doorstopper), "\(id)")
            XCTAssertFalse(SpineView.stamps(novel), "\(id)")
            XCTAssertFalse(SpineView.stamps(unknown), "\(id)")
            for pages in [100, 500, 700, 900, 1_400] {
                let book = Book(id: id, title: "Book", author: "Author", pages: pages)
                let thickness = SpineView.thickness(of: book)
                XCTAssertEqual(thickness % 4, 0)
                XCTAssertEqual(SpineView.stamps(book), thickness >= 32)
            }
        }
        // Without variety, a 721-page book is 28.2 mm thick, which rounds to 28 mm.
        let thicknesses = (1...200)
            .map { SpineView.thickness(of: Book(id: $0, title: "B", author: "A", pages: 721)) }
        XCTAssertEqual(thicknesses.min(), 28)
    }

    /// The owner's standing rule: no spine ever uses Impact, in any spelling, from any source.
    @MainActor
    func testImpactCanNeverBeChosenOrRendered() async throws {
        for name in [
            "Impact", "impact", "IMPACT", "Impact-Regular", "Impact Bold", "ImpactMT", " Impact ",
        ] {
            XCTAssertFalse(SpineFontPolicy.allows(name), name)
            XCTAssertEqual(SpineFontPolicy.allowedFontName(name), "BebasNeue")
        }
        XCTAssertNotNil(UIFont(name: SpineFontPolicy.impactReplacement, size: 24))

        let horror = Book(id: 1, title: "Book", author: "Author", genres: ["Gothic Horror"])
        XCTAssertEqual(BookWallLocalSpine.fontName(for: horror), "BebasNeue")
        XCTAssertTrue(SpineFontPolicy.allows(SpineStyle.fallback(for: horror).fontName))

        // A style saved before this rule, in preferences, the cache, or iCloud, loads without it.
        let saved = Data(
            """
            {"background":{"red":0.1,"green":0.1,"blue":0.1},
            "foreground":{"red":0.9,"green":0.9,"blue":0.9},"fontName":"Impact",
            "uppercase":true,"recognizedTitle":false,"provenance":"Local"}
            """
            .utf8)
        let style = try JSONDecoder().decode(SpineStyle.self, from: saved)
        XCTAssertEqual(style.fontName, "BebasNeue")
        XCTAssertTrue(style.uppercase)
        var georgia = style
        georgia.fontName = "Georgia-Bold"
        XCTAssertEqual(
            try JSONDecoder().decode(SpineStyle.self, from: JSONEncoder().encode(georgia)), georgia)

        // Generation never offers, downloads, or restores Impact.
        let prompt = AIStyleGenerator.stylePrompt(
            book: horror,
            catalog: [
                GoogleFontFamily(family: "Impact", category: "Sans Serif", isOpenSource: true),
                GoogleFontFamily(family: "Oswald", category: "Sans Serif", isOpenSource: true),
            ])
        XCTAssertTrue(prompt.contains("Never choose Impact."))
        XCTAssertFalse(prompt.contains("Impact|"))
        XCTAssertTrue(prompt.contains("Oswald|Sans Serif"))
        let fonts = GoogleFontLibrary(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        do {
            _ = try await fonts.download(family: "Impact", weight: 400)
            XCTFail("Impact downloaded")
        } catch AIError.invalidFont {}
    }

    /// The owner's standing rule: no italics. A saved style in a slanted or italic face loads in
    /// an allowed upright one.
    func testSlantedSavedFontsLoadUpright() throws {
        let expected = [
            "Impact": "BebasNeue", "Bangers-Regular": "Bungee-Regular",
            "Shrikhand-Regular": "ChangaOne", "Bangers Italic": "Bungee-Regular",
            "Lora-Italic": "Lora-Regular", "Lora-BoldItalic": "Lora-Bold",
            "Lora Italic": "Lora-Regular",
            "EBGaramond-It": "EBGaramond-Regular", "SourceSans3-SemiboldIt": "SourceSans3-Semibold",
            "Georgia-BoldItalic": "Georgia-Bold", "Italic": "AvenirNext-DemiBold",
            "Georgia-Bold": "Georgia-Bold",
        ]
        for (saved, shown) in expected {
            XCTAssertEqual(SpineFontPolicy.allowedFontName(saved), shown, saved)
            XCTAssertTrue(SpineFontPolicy.allows(shown), shown)
        }
        XCTAssertNotNil(UIFont(name: "Georgia-Bold", size: 24))
        XCTAssertNotNil(UIFont(name: SpineFontPolicy.uprightFallback, size: 24))

        for (saved, shown) in ["Bangers-Regular": "Bungee-Regular", "Lora-BoldItalic": "Lora-Bold"]
        {
            let data = Data(
                """
                {"background":{"red":0.1,"green":0.1,"blue":0.1},
                "foreground":{"red":0.9,"green":0.9,"blue":0.9},"fontName":"\(saved)",
                "uppercase":false,"recognizedTitle":true,"provenance":"Saved"}
                """
                .utf8)
            XCTAssertEqual(try JSONDecoder().decode(SpineStyle.self, from: data).fontName, shown)
        }

        // A loaded face with the italic trait is passed over, whatever its name says.
        let italic = CTFontCreateWithName("Georgia-Italic" as CFString, 24, nil)
        let upright = CTFontCreateWithName("Georgia" as CFString, 24, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(italic) as String, "Georgia-Italic")
        XCTAssertFalse(SpineFontPolicy.isUpright(italic))
        XCTAssertTrue(SpineFontPolicy.isUpright(upright))
        let descriptors = [italic, upright].map { CTFontCopyFontDescriptor($0) }
        let chosen = try XCTUnwrap(GoogleFontLibrary.uprightFace(in: descriptors, nearest: 400))
        XCTAssertEqual(CTFontCopyPostScriptName(chosen) as String, "Georgia")
        XCTAssertNil(GoogleFontLibrary.uprightFace(in: [descriptors[0]], nearest: 400))
    }

    /// The owner's rule for stand-ins: a blocked face shows in its stand-in family at the
    /// design's weight, and a saved style in a blocked family restores as the stand-in.
    func testStandInsFollowTheDesignWeight() throws {
        let families = [
            "Bangers": "Bungee", "Bangers-Regular": "Bungee", "Shrikhand": "Changa One",
            "Dancing Script": "Patrick Hand", "DancingScript-Bold": "Patrick Hand",
            "Great Vibes": "Patrick Hand", "Pacifico-Regular": "Patrick Hand",
            // Faces whose letters lean without declaring a slant.
            "Kalam-Bold": "Patrick Hand", "Caveat-Regular": "Patrick Hand",
            "Shadows Into Light": "Patrick Hand",
        ]
        for (name, family) in families {
            XCTAssertEqual(SpineFontPolicy.standInFamily(for: name), family, name)
        }
        for name in ["Bungee", "PatrickHand-Regular", "Lora", "Lora-BoldItalic", "Impact"] {
            XCTAssertNil(SpineFontPolicy.standInFamily(for: name), name)
        }

        // The upright face nearest the weight wins, never an italic of that weight.
        let avenir = [
            "AvenirNext-Regular", "AvenirNext-Medium", "AvenirNext-DemiBold", "AvenirNext-Bold",
            "AvenirNext-BoldItalic",
        ]
        .map { CTFontCopyFontDescriptor(CTFontCreateWithName($0 as CFString, 24, nil)) }
        func nearest(_ weight: Int) -> String? {
            GoogleFontLibrary.uprightFace(in: avenir, nearest: weight)
                .map { CTFontCopyPostScriptName($0) as String }
        }
        XCTAssertEqual(nearest(600), "AvenirNext-DemiBold")
        XCTAssertEqual(nearest(700), "AvenirNext-Bold")
        XCTAssertEqual(nearest(900), "AvenirNext-Bold")
        XCTAssertEqual(nearest(400), "AvenirNext-Regular")

        // A registered family resolves its face nearest the weight, then the Regular name, then
        // the system face. Avenir Next, a system family, plays a downloaded stand-in.
        let registered = try XCTUnwrap(
            GoogleFontLibrary.registeredFace(family: "Avenir Next", nearest: 700))
        XCTAssertEqual(CTFontCopyPostScriptName(registered) as String, "AvenirNext-Bold")
        XCTAssertNil(GoogleFontLibrary.registeredFace(family: "Not A Font Family", nearest: 700))
        func font(_ family: String, _ name: String?, weight: Int) -> UIFont {
            BookWallLocalSpine.Typography(fontName: name, standInFamily: family, weight: weight)
                .font(size: 24)
        }
        let standIn = font("Avenir Next", "Georgia-Bold", weight: 600)
        XCTAssertEqual(standIn.fontName, "AvenirNext-DemiBold")
        XCTAssertEqual(standIn.pointSize, 24)
        let regular = font("Not A Font Family", "Georgia-Bold", weight: 600)
        XCTAssertEqual(regular.fontName, "Georgia-Bold")
        let system = font("Not A Font Family", "Not-A-Font", weight: 700)
        XCTAssertEqual(system.familyName, UIFont.systemFont(ofSize: 24, weight: .bold).familyName)
    }

    func testFontFilesFollowTheRequestedWeight() {
        let kalam = ["Kalam-Light.ttf", "Kalam-Regular.ttf", "Kalam-Bold.ttf"]
        XCTAssertEqual(GoogleFontLibrary.fileName(for: 700, in: kalam), "Kalam-Bold.ttf")
        XCTAssertEqual(GoogleFontLibrary.fileName(for: 600, in: kalam), "Kalam-Bold.ttf")
        XCTAssertEqual(GoogleFontLibrary.fileName(for: 500, in: kalam), "Kalam-Regular.ttf")
        // An exact static file beats the variable file, which beats a nearer static file.
        let caveat = [
            "Caveat-VariableFont_wght.ttf", "static/Caveat-Regular.ttf",
            "static/Caveat-SemiBold.ttf",
        ]
        XCTAssertEqual(GoogleFontLibrary.fileName(for: 600, in: caveat), caveat[2])
        XCTAssertEqual(GoogleFontLibrary.fileName(for: 700, in: caveat), caveat[0])
        // Equally near files resolve heavier above 500 and lighter otherwise.
        let pair = ["Family-Regular.ttf", "Family-SemiBold.ttf"]
        XCTAssertEqual(GoogleFontLibrary.fileName(for: 500, in: pair), "Family-Regular.ttf")
        XCTAssertEqual(GoogleFontLibrary.fileName(for: 500, in: pair.reversed()), pair[0])
        // A family with one face downloads it at any weight.
        for single in ["Bungee-Regular.ttf", "ChangaOne.ttf"] {
            XCTAssertEqual(GoogleFontLibrary.fileName(for: 700, in: [single]), single)
        }
        XCTAssertNil(GoogleFontLibrary.fileName(for: 400, in: []))
    }

    /// The same file lists and picks as the iOS app's
    /// `testFontFilesPreferTheWeightThenTheRegularWidthAndTextSize`, so both apps download the
    /// file whose PostScript names a design records.
    func testFontFilesPreferTheRegularWidthAndTextSizeAsTheIPhoneDoes() {
        let pick = GoogleFontLibrary.fileName(for:in:)
        let noto = [
            "NotoSans[wdth,wght].ttf", "static/NotoSans_Condensed-Bold.ttf",
            "static/NotoSans_ExtraCondensed-Bold.ttf", "static/NotoSans-Bold.ttf",
            "static/NotoSans-Regular.ttf",
        ]
        XCTAssertEqual(pick(700, noto), "static/NotoSans-Bold.ttf")
        XCTAssertEqual(pick(500, noto), "NotoSans[wdth,wght].ttf")
        let lato = ["Lato-Light.ttf", "Lato-Regular.ttf", "Lato-Bold.ttf"]
        XCTAssertEqual(pick(500, lato), "Lato-Regular.ttf")
        XCTAssertEqual(pick(600, lato), "Lato-Bold.ttf")
        let archivo = ["static/ArchivoNarrow-Regular.ttf", "static/ArchivoNarrow-Bold.ttf"]
        XCTAssertEqual(pick(700, archivo), "static/ArchivoNarrow-Bold.ttf")
        let condensed = ["static/LeagueGothic_Condensed-Regular.ttf"]
        XCTAssertEqual(pick(500, condensed), condensed[0])
        let league = [
            "LeagueGothic-Regular-VariableFont_wdth.ttf",
            "static/LeagueGothic_Condensed-Regular.ttf", "static/LeagueGothic-Regular.ttf",
        ]
        XCTAssertEqual(pick(400, league), "static/LeagueGothic-Regular.ttf")
        let merriweather = [
            "Merriweather-VariableFont_opsz,wdth,wght.ttf",
            "static/Merriweather_120pt-SemiBold.ttf",
            "static/Merriweather_120pt_SemiCondensed-SemiBold.ttf",
            "static/Merriweather_24pt_SemiCondensed-SemiBold.ttf",
            "static/Merriweather_24pt-SemiBold.ttf", "static/Merriweather_36pt-SemiBold.ttf",
        ]
        XCTAssertEqual(pick(600, merriweather), "static/Merriweather_24pt-SemiBold.ttf")
        XCTAssertEqual(pick(500, merriweather), merriweather[0])
        let bodoni = [
            "static/BodoniModa_9pt-Bold.ttf", "static/BodoniModa_18pt-Bold.ttf",
            "static/BodoniModa_28pt-Bold.ttf", "static/BodoniModa_72pt-Bold.ttf",
        ]
        XCTAssertEqual(pick(700, bodoni), "static/BodoniModa_28pt-Bold.ttf")
    }
}
