import SwiftUI
import UIKit
import XCTest

@testable import Bookworms

@MainActor
final class CacheTests: XCTestCase {
    private func record() -> AIStyleRecord {
        AIStyleRecord(
            bookID: 1, style: .fallback(for: SampleLibrary.books[0]),
            font: DownloadedFont(
                family: "Example", postScriptName: "Example-Regular",
                filePath: "/old-container/font.ttf", licensePath: "/old-container/LICENSE.txt"),
            weight: 400, provider: .google, model: "fixture", coverHash: "cover-hash",
            generatedAt: Date(), rationale: "Saved choice")
    }

    func testPaidChoiceSurvivesCacheRemovalAndMissingFont() throws {
        let suite = "BookwormsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "ai-styles.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([1: record()]).write(to: file)
        let store = AIStyleStore(defaults: defaults, cacheURL: file)
        XCTAssertEqual(store.load()[1]?.coverHash, "cover-hash")
        try FileManager.default.removeItem(at: directory)
        let recovered = AIStyleStore(defaults: defaults, cacheURL: file).load()
        XCTAssertEqual(recovered[1]?.font.family, "Example")
        XCTAssertEqual(recovered[1]?.style, record().style)
    }

    func testMalformedPreferencesRecoverFromDiskCopy() throws {
        let suite = "BookwormsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIStyleStore(
            defaults: defaults, cacheURL: directory.appending(path: "styles.json"))
        try store.save([1: record()])
        defaults.set(Data("broken".utf8), forKey: AIStyleStore.key)
        XCTAssertEqual(store.load()[1]?.coverHash, "cover-hash")
        try FileManager.default.removeItem(at: directory)
        XCTAssertEqual(store.load()[1]?.coverHash, "cover-hash")
    }

    func testCapacityFailurePreservesSavedChoices() throws {
        let suite = "BookwormsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIStyleStore(
            defaults: defaults, cacheURL: directory.appending(path: "styles.json"))
        try store.save([1: record()])
        defaults.set(Data(repeating: 1, count: 450_000), forKey: "other-preferences")
        XCTAssertThrowsError(try store.save([:]))
        XCTAssertEqual(store.load().count, 1)
    }

    func testCloudBackedSaveKeepsDurableSubsetAndRecoversNewerDiskDesign() throws {
        let suite = "BookwormsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIStyleStore(
            defaults: defaults, cacheURL: directory.appending(path: "styles.json"))
        let old = record()
        try store.save([1: old])
        let durable = defaults.data(forKey: AIStyleStore.key)
        defaults.set(Data(repeating: 1, count: 450_000), forKey: "other-preferences")
        let newer = AIStyleRecord(
            bookID: 1, style: old.style, font: old.font, weight: old.weight,
            provider: old.provider, model: old.model, coverHash: "new-cover",
            generatedAt: old.generatedAt.addingTimeInterval(10), rationale: "new choice")
        try store.save([1: newer], cloudBacked: true)
        XCTAssertEqual(defaults.data(forKey: AIStyleStore.key), durable)
        XCTAssertEqual(store.load()[1]?.coverHash, "new-cover")
        let merged = CloudLibraryArchive(designs: [1: newer])
            .merging(CloudLibraryArchive(designs: [1: old]))
        XCTAssertEqual(merged.designs[1]?.coverHash, "new-cover")
    }

    func testDailyRefreshDoesNotBypassClockRollback() {
        let now = Date()
        func isDue(syncedAt: Date?) -> Bool {
            RefreshPolicy.isDue(
                lastAttempt: syncedAt, lastSuccess: syncedAt, hasSnapshot: true, manual: false,
                now: now)
        }
        XCTAssertFalse(isDue(syncedAt: now.addingTimeInterval(-86399)))
        XCTAssertTrue(isDue(syncedAt: now.addingTimeInterval(-86400)))
        XCTAssertFalse(isDue(syncedAt: now.addingTimeInterval(1)))
        XCTAssertTrue(isDue(syncedAt: nil))
    }

    private func lettering(
        _ title: String, author: String = "Frank Herbert", length: CGFloat = 420,
        thickness: CGFloat
    ) -> SpineLettering {
        SpineTextMetrics.lettering(
            title: title, author: author, fontName: "Georgia-Bold", length: length,
            thickness: thickness)
    }

    /// The width of each of `lettering`'s title lines at its size.
    private func titleLineWidths(_ lettering: SpineLettering) -> [CGFloat] {
        let font = SpineTextMetrics.uiFont(name: lettering.fontName, size: lettering.titleSize)
        return lettering.title.components(separatedBy: "\n")
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
    }

    func testTitleStartsFromTheBoxWithoutACap() {
        // An 88% box on a thick spine letters a short title larger than 58 points.
        let result = lettering("Dune", thickness: 110)
        XCTAssertGreaterThan(result.titleSize, 58)
        XCTAssertLessThanOrEqual(result.titleSize, 110 * 0.88)
        XCTAssertEqual(result.title, "Dune")
    }

    func testTitleBreaksBetweenWordsAndFitsItsWidth() {
        for thickness: CGFloat in [40, 60, 90] {
            let title = "The Hitchhiker's Guide to the Galaxy"
            let result = lettering(title, thickness: thickness)
            XCTAssertEqual(result.title.replacingOccurrences(of: "\n", with: " "), title)
            for width in titleLineWidths(result) {
                XCTAssertLessThanOrEqual(width, result.titleWidth + 0.01)
            }
        }
        // A title without spaces keeps to one line.
        XCTAssertFalse(lettering("三体", thickness: 70).title.contains("\n"))
    }

    func testTwoLinesWhenLargerThanOne() {
        let result = lettering("Small Gods", length: 300, thickness: 100)
        XCTAssertEqual(result.title, "Small\nGods")
        let oneLine = lettering("SmallGods", length: 300, thickness: 100)
        XCTAssertGreaterThan(result.titleSize, oneLine.titleSize)
    }

    func testThirdLineOnlyBelowTitleFloor() {
        let roomy = lettering("The Name of the Wind", thickness: 80)
        XCTAssertGreaterThanOrEqual(roomy.titleSize, SpineTextMetrics.minimumTitleSize)
        XCTAssertLessThanOrEqual(roomy.title.components(separatedBy: "\n").count, 2)
        let tight = lettering(
            "The Dungeon Anarchist's Cookbook", author: "Matt Dinniman", length: 262,
            thickness: 82)
        XCTAssertEqual(tight.title.components(separatedBy: "\n").count, 3)
        XCTAssertLessThan(tight.titleSize, SpineTextMetrics.minimumTitleSize)
    }

    func testSpineLengthensBeforeTakingAThirdLine() {
        // Three lines reach the floor at the natural length, but a longer spine letters the
        // title on two lines at 23 points or more, so the spine lengthens instead.
        let book = Book(
            id: 446730, title: "The Dungeon Anarchist's Cookbook", author: "Matt Dinniman",
            format: "Ebook")
        var style = SpineStyle.fallback(for: book)
        style.fontName = "Georgia-Bold"
        let natural = SpineDimensions(width: 118, height: 466)
        let threeLines = SpineTextMetrics.lettering(for: book, style: style, dimensions: natural)
        let twoLines = SpineTextMetrics.lettering(
            for: book, style: style, dimensions: natural, maximumLines: 2)
        XCTAssertLessThan(twoLines.titleSize, SpineTextMetrics.minimumTitleSize)
        XCTAssertEqual(threeLines.title.components(separatedBy: "\n").count, 3)

        let adjusted = SpineTextMetrics.readableDimensions(
            for: book, style: style, natural: natural, rowHeight: 600)
        let drawn = SpineTextMetrics.lettering(for: book, style: style, dimensions: adjusted)
        XCTAssertGreaterThan(adjusted.height, natural.height)
        XCTAssertEqual(drawn.title.components(separatedBy: "\n").count, 2)
        XCTAssertGreaterThanOrEqual(drawn.titleSize, SpineTextMetrics.minimumTitleSize)
    }

    /// SwiftUI lays the measured text out within the room UIKit measured for it.
    func testSwiftUIDrawsLetteringWithinItsMeasuredRoom() {
        let cases: [(String, String, CGFloat, CGFloat)] = [
            ("The Hitchhiker's Guide to the Galaxy", "Douglas Adams", 420, 60),
            ("The Dungeon Anarchist's Cookbook", "Matt Dinniman", 262, 82),
            ("Small Gods", "Terry Pratchett", 300, 100),
            ("Eragon", "Christopher Paolini", 300, 40),
        ]
        for (title, author, length, thickness) in cases {
            let result = lettering(title, author: author, length: length, thickness: thickness)
            func size(_ text: String, _ fontSize: CGFloat) -> CGSize {
                UIHostingController(
                    rootView: Text(verbatim: text)
                        .font(SpineTextMetrics.font(name: result.fontName, size: fontSize))
                        .fixedSize()
                )
                .sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
            }
            let titleSize = size(result.title, result.titleSize)
            XCTAssertLessThanOrEqual(titleSize.width, result.titleWidth + 0.5, title)
            XCTAssertLessThanOrEqual(titleSize.height, thickness * 0.88 + 0.5, title)
            guard result.authorFits else { continue }
            let authorSize = size(result.author, result.authorSize)
            XCTAssertLessThanOrEqual(authorSize.width, result.authorWidth + 0.5, author)
            XCTAssertLessThanOrEqual(authorSize.height, thickness * 0.88 + 0.5, author)
        }
    }

    func testAuthorForms() {
        XCTAssertEqual(
            SpineView.shortAuthor("Neil Gaiman, Terry Pratchett"), "Neil Gaiman, Terry Pratchett")
        XCTAssertEqual(SpineView.shortAuthor("A One, B Two, C Three"), "A One et al.")
        XCTAssertEqual(SpineView.twoLines("David Foster Wallace"), "David Foster\nWallace")
        XCTAssertEqual(SpineView.surname("Ursula K. Le Guin"), "Le Guin")
        XCTAssertEqual(SpineView.surname("Walter M. Miller Jr."), "Miller Jr.")
        XCTAssertNil(SpineView.surname("Homer"))
    }

    func testAuthorKeepsMinimumAndFallsBackToSurname() {
        let author = "Christopher Paolini"
        for thickness: CGFloat in [40, 60, 100] {
            let result = lettering("Eragon", author: author, length: 300, thickness: thickness)
            XCTAssertGreaterThanOrEqual(result.authorSize, SpineTextMetrics.minimumAuthorSize)
            XCTAssertTrue(result.authorFits)
            XCTAssertTrue(
                [author, "Christopher\nPaolini", "Paolini"].contains(result.author), result.author)
            if result.titleSize >= SpineTextMetrics.minimumAuthorSize + SpineTextMetrics.titleLead {
                XCTAssertGreaterThanOrEqual(
                    result.titleSize, result.authorSize + SpineTextMetrics.titleLead)
            }
        }
        // A thin spine has no room for the whole name, so it letters the surname.
        let thin = lettering(
            "The Inheritance Cycle", author: author, length: 300, thickness: 40)
        XCTAssertEqual(thin.author, "Paolini")
    }

    func testFormatIconReservesTailRoom() {
        var book = Book(id: 1, title: "Dune: Deluxe Edition", author: "Frank Herbert")
        let style = SpineStyle.fallback(for: book)
        let dimensions = SpineDimensions(width: 70, height: 420)
        let plain = SpineTextMetrics.lettering(for: book, style: style, dimensions: dimensions)
        book.format = "Ebook"
        let withIcon = SpineTextMetrics.lettering(for: book, style: style, dimensions: dimensions)
        XCTAssertEqual(plain.length, 420)
        XCTAssertEqual(withIcon.length, 420 - SpineTextMetrics.formatIconRoom)
        // The shelf spine stops a title at its first colon and draws no subtitle.
        XCTAssertFalse(plain.title.localizedCaseInsensitiveContains("deluxe"))
    }

    func testTitleFloorLengthensThenThickensSpine() {
        let book = Book(
            id: 446730, title: "The Dungeon Anarchist's Cookbook", author: "Matt Dinniman",
            format: "Ebook")
        var style = SpineStyle.fallback(for: book)
        style.fontName = "Georgia-Bold"
        let natural = SpineDimensions(width: 82, height: 300)
        let before = SpineTextMetrics.lettering(for: book, style: style, dimensions: natural)
        let adjusted = SpineTextMetrics.readableDimensions(
            for: book, style: style, natural: natural, rowHeight: 600)
        let after = SpineTextMetrics.lettering(for: book, style: style, dimensions: adjusted)
        XCTAssertLessThan(before.titleSize, 23)
        XCTAssertGreaterThan(adjusted.height, natural.height)
        XCTAssertEqual(adjusted.width, natural.width)
        XCTAssertLessThanOrEqual(adjusted.height, 600)
        XCTAssertGreaterThanOrEqual(after.titleSize, 23)

        // A title that still can't reach the floor at the shelf's full height thickens.
        let long = Book(
            id: 2,
            title: "Extraordinarily Unpronounceable Supercalifragilistic Antidisestablishment",
            author: "Alex")
        let thin = SpineDimensions(width: 50, height: 300)
        let grown = SpineTextMetrics.readableDimensions(
            for: long, style: style, natural: thin, rowHeight: 600)
        XCTAssertEqual(grown.height, min(600, 50 * ShelfLayout.slendernessRange.upperBound))
        XCTAssertGreaterThan(grown.width, thin.width)
    }

    func testReadableTitleKeepsNaturalBookHeight() {
        let book = Book(id: 1, title: "Dune", author: "Frank Herbert")
        let style = SpineStyle.fallback(for: book)
        let natural = SpineDimensions(width: 90, height: 480)
        XCTAssertEqual(
            SpineTextMetrics.readableDimensions(
                for: book, style: style, natural: natural, rowHeight: 600), natural)
    }

    func testPreparedPagesCarryTheMeasuredLettering() throws {
        let books = Array(SampleLibrary.books.prefix(6))
        let styles = Dictionary(
            uniqueKeysWithValues: books.map { ($0.id, SpineStyle.fallback(for: $0)) })
        let pages = BookPresentation.pages(
            books: books, styles: styles, coverRatios: [:], width: 1600, rowHeight: 500)
        for page in pages {
            for book in page.books {
                let dimensions = try XCTUnwrap(page.dimensions[book.id])
                XCTAssertEqual(
                    page.letterings[book.id],
                    SpineTextMetrics.lettering(
                        for: book, style: try XCTUnwrap(styles[book.id]), dimensions: dimensions))
            }
        }
    }

    func testTrimRemovesOldestFilesAndKeepsFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appending(path: "browse"), withIntermediateDirectories: true)
        for (index, name) in ["old", "middle", "new"].enumerated() {
            let file = directory.appending(path: name)
            try Data(count: 100).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index) * 100)],
                ofItemAtPath: file.path())
        }
        ArtworkStore.trim(directory, to: 200)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path())
        XCTAssertEqual(Set(remaining), ["browse", "middle", "new"])
    }
}
