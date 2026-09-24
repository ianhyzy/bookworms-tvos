import UIKit
import XCTest

@testable import Bookworms

@MainActor
final class CacheTests: XCTestCase {
    func testInkDensityDistinguishesLightAndHeavyFaces() {
        let light = "HelveticaNeue-UltraLight"
        let heavy = "HelveticaNeue-Bold"
        XCTAssertLessThan(
            SpineFontProfile.bucket(fontName: light), SpineFontProfile.bucket(fontName: heavy))
        XCTAssertGreaterThan(
            SpineFontProfile.sizeScale(fontName: light), SpineFontProfile.sizeScale(fontName: heavy)
        )
        XCTAssertEqual(
            SpineFontProfile.bucket(fontName: heavy), SpineFontProfile.bucket(fontName: heavy))
    }

    func testVisualAdjustmentPreservesTitleFloorAndHierarchy() {
        for scale: CGFloat in [0.94, 1, 1.06] {
            let result = SpineTextMetrics.typography(
                title: "Dune", author: "Frank Herbert", fontName: "Georgia-Bold",
                length: 450, height: 70, maximumTitle: 52, maximumAuthor: 22,
                hasSubtitle: false, visualScale: scale)
            XCTAssertGreaterThanOrEqual(result.titleSize, 23)
            XCTAssertGreaterThanOrEqual(result.titleSize, result.authorSize + 4)
            XCTAssertGreaterThanOrEqual(result.authorSize, 16)
        }
    }

    func testAuthorLinesKeepAVisibleGapWithoutFontLeading() throws {
        let layout = SpineAuthorLayout.make(
            "Robin Hobb", fontName: "Georgia-Italic",
            size: 24, width: 65)
        XCTAssertGreaterThan(layout.lines.count, 1)
        for index in 1..<layout.lines.count {
            let previous = layout.lines[index - 1]
            XCTAssertEqual(
                layout.lines[index].top - previous.top - previous.bounds.height,
                24 * 0.12, accuracy: 0.01)
        }
        let font = try XCTUnwrap(UIFont(name: "Georgia-Italic", size: 24))
        XCTAssertLessThan(layout.size.height, CGFloat(layout.lines.count) * font.lineHeight)
    }

    func testApparentSizeAdjustmentsStaySubtleForBothCases() {
        for name in ["Georgia", "HelveticaNeue-Bold", "Georgia-Italic"] {
            for text in ["ROBIN HOBB", "Robin Hobb"] {
                let scale = SpineFontProfile.sizeScale(fontName: name, text: text)
                XCTAssertGreaterThanOrEqual(scale, 0.94)
                XCTAssertLessThanOrEqual(scale, 1.06)
            }
        }
    }

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
        XCTAssertFalse(
            LibraryModel.needsRefresh(syncedAt: now.addingTimeInterval(-86399), now: now))
        XCTAssertTrue(LibraryModel.needsRefresh(syncedAt: now.addingTimeInterval(-86400), now: now))
        XCTAssertFalse(LibraryModel.needsRefresh(syncedAt: now.addingTimeInterval(1), now: now))
        XCTAssertTrue(LibraryModel.needsRefresh(syncedAt: nil, now: now))
    }

    func testFontFittingCacheRespectsAvailableSpace() {
        let large = SpineTextMetrics.fittedSize(
            "Assassin’s Quest", fontName: "Georgia-Bold", maximum: 48, width: 280, height: 65,
            preferSingleLine: true)
        let small = SpineTextMetrics.fittedSize(
            "Assassin’s Quest", fontName: "Georgia-Bold", maximum: 48, width: 140, height: 35,
            preferSingleLine: true)
        XCTAssertLessThan(small, large)
        XCTAssertEqual(
            large,
            SpineTextMetrics.fittedSize(
                "Assassin’s Quest", fontName: "Georgia-Bold", maximum: 48, width: 280, height: 65,
                preferSingleLine: true))
    }
    func testTitleHierarchyFitsWithoutShrinkingAuthorOnRoomySpine() {
        let result = SpineTextMetrics.typography(
            title: "Raising Steam", author: "Terry Pratchett", fontName: "Georgia-Bold",
            length: 450, height: 70, maximumTitle: 52, maximumAuthor: 22, hasSubtitle: false)
        XCTAssertGreaterThanOrEqual(result.titleSize, result.authorSize + 4)
        let fittedAuthor = SpineTextMetrics.fittedSize(
            "Terry Pratchett", fontName: "Georgia-Bold", maximum: 22,
            width: 450 * 0.22, height: 70)
        XCTAssertEqual(result.authorSize, fittedAuthor)
        XCTAssertEqual(result.titleLength + result.authorLength, 450 * 0.97, accuracy: 0.001)
    }

    func testDifficultTitleDoesNotForceAuthorBelowReadabilityFloor() {
        let result = SpineTextMetrics.typography(
            title: String(repeating: "Unbroken", count: 15), author: "Alex",
            fontName: "Georgia-Bold", length: 320, height: 48,
            maximumTitle: 36, maximumAuthor: 22, hasSubtitle: false)
        XCTAssertGreaterThanOrEqual(result.authorSize, 16)
        XCTAssertLessThan(result.titleSize, result.authorSize + 4)
        XCTAssertGreaterThanOrEqual(result.authorLength, 320 * 0.13 - 0.001)
    }

    func testLongAuthorIsNotShrunkFurtherToEnforceHierarchy() {
        let author = "Alexandria Montgomery and Christopher Wellington"
        let baseline = SpineTextMetrics.fittedSize(
            author, fontName: "Georgia-Bold",
            maximum: 22, width: 260 * 0.22, height: 30)
        let result = SpineTextMetrics.typography(
            title: "An exceptionally long title for a narrow book", author: author,
            fontName: "Georgia-Bold", length: 260, height: 30,
            maximumTitle: 30, maximumAuthor: 22, hasSubtitle: true)
        XCTAssertGreaterThanOrEqual(result.authorSize, min(16, baseline))
        XCTAssertLessThanOrEqual(result.titleSize, 30)
    }

    func testTitleLegibilityCanBorrowHeightWithoutChangingWidth() {
        let book = Book(
            id: 446730, title: "The Dungeon Anarchist's Cookbook", author: "Matt Dinniman",
            format: "Ebook")
        var style = SpineStyle.fallback(for: book)
        style.fontName = "Georgia-Bold"
        let natural = SpineDimensions(width: 82, height: 300)
        let before = SpineTextMetrics.typography(for: book, style: style, dimensions: natural)
        let adjusted = SpineTextMetrics.readableDimensions(
            for: book, style: style, natural: natural, rowHeight: 600)
        let after = SpineTextMetrics.typography(for: book, style: style, dimensions: adjusted)
        XCTAssertLessThan(before.titleSize, 23)
        XCTAssertGreaterThan(adjusted.height, natural.height)
        XCTAssertEqual(adjusted.width, natural.width)
        XCTAssertLessThanOrEqual(adjusted.height, 588)
        XCTAssertGreaterThanOrEqual(after.titleSize, 23)
    }

    func testReadableTitleKeepsNaturalBookHeight() {
        let book = Book(id: 1, title: "Dune", author: "Frank Herbert")
        let style = SpineStyle.fallback(for: book)
        let natural = SpineDimensions(width: 90, height: 480)
        XCTAssertEqual(
            SpineTextMetrics.readableDimensions(
                for: book, style: style, natural: natural, rowHeight: 600), natural)
    }

}
