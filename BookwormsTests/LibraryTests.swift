import TVServices
import XCTest

@testable import Bookworms

final class LibraryTests: XCTestCase {
    func testDateFormatsAndFinishedCalendarDateValidation() {
        let book = Book(id: 1, title: "Book", author: "Author", finished: "2026-01-01")
        XCTAssertEqual(book.finishedLabel, "Jan 01, 2026")
        XCTAssertEqual(book.finishedLabel(format: .monthFirst), "01/01/2026")
        XCTAssertEqual(book.finishedLabel(format: .dayFirst), "01/01/2026")
        XCTAssertEqual(book.finishedLabel(format: .iso), "2026-01-01")
        let monthEnd = Book(id: 2, title: "Book", author: "Author", finished: "2026-01-31")
        XCTAssertEqual(monthEnd.finishedLabel(format: .monthFirst), "01/31/2026")
        XCTAssertEqual(monthEnd.finishedLabel(format: .dayFirst), "31/01/2026")
        let invalid = Book(id: 3, title: "Book", author: "Author", finished: "2026-02-30")
        XCTAssertEqual(invalid.finishedLabel(format: .iso), "Date not recorded")
    }

    func testShelfDistributionAnchorsEdgesAndSharesGaps() {
        let widths: [CGFloat] = [120, 200, 80, 160]
        let available: CGFloat = 1000
        let centers = widths.indices.map {
            ShelfLayout.center(at: $0, widths: widths, availableWidth: available)
        }
        XCTAssertEqual(centers[0] - widths[0] / 2, 0, accuracy: 0.001)
        XCTAssertEqual(centers[3] + widths[3] / 2, available, accuracy: 0.001)
        let gaps = (1..<widths.count)
            .map {
                centers[$0] - widths[$0] / 2 - centers[$0 - 1] - widths[$0 - 1] / 2
            }
        XCTAssertEqual(gaps[0], gaps[1], accuracy: 0.001)
        XCTAssertEqual(gaps[1], gaps[2], accuracy: 0.001)
        XCTAssertEqual(ShelfLayout.center(at: 0, widths: [120], availableWidth: available), 500)
        XCTAssertEqual(ShelfLayout.distributedGap(widths: [], availableWidth: available), 0)
        XCTAssertEqual(
            ShelfLayout.distributedGap(widths: [400, 582], availableWidth: available), 18)
    }

    func testCompletedReadUsesItsEditionAndDate() throws {
        let json = """
            [{"id":9,"last_read_date":"2025-01-01","rating":4.5,
              "book":{"id":1,"title":"A book","pages":900},
              "edition":{"id":10,"pages":450,"reading_format":{"format":"Hardcover"}},
              "user_book_reads":[{"finished_at":"2026-09-09","edition":{"id":11,"pages":310,"reading_format":{"format":"Audiobook"}}}]}]
            """
        let rows = try JSONDecoder().decode([UserBook].self, from: Data(json.utf8))
        let result = HardcoverClient.normalize(rows)
        XCTAssertEqual(result.first?.finished, "2026-09-09")
        XCTAssertEqual(result.first?.pages, 310)
        XCTAssertEqual(result.first?.format, "Audiobook")
    }

    func testReaderLibraryBookUsesTheirEditionFormatAndCover() throws {
        let source = try JSONDecoder()
            .decode(
                SourceBook.self,
                from: Data(
                    #"{"id":5,"title":"Shared","image":{"url":"https://example.com/default","width":400,"height":600}}"#
                        .utf8))
        let edition = try JSONDecoder()
            .decode(
                Edition.self,
                from: Data(
                    #"{"id":6,"image":{"url":"https://example.com/edition","width":400,"height":600},"reading_format":{"format":"Listened"}}"#
                        .utf8))
        let book = HardcoverSocialClient.book(source, edition: edition)
        XCTAssertEqual(book.formatLabel, "Audiobook")
        XCTAssertEqual(book.detailCoverURL, URL(string: "https://example.com/edition"))
        XCTAssertEqual(book.coverURL, URL(string: "https://example.com/default"))
    }

    func testUnknownCompletionStaysUnknownAndRereadsDeduplicate() throws {
        let json = """
            [{"id":1,"book":{"id":1,"title":"Unknown"}},
             {"id":2,"last_read_date":"2024-01-01","book":{"id":2,"title":"Reread"}},
             {"id":3,"last_read_date":"2026-01-01","book":{"id":2,"title":"Reread"}}]
            """
        let result = HardcoverClient.normalize(
            try JSONDecoder().decode([UserBook].self, from: Data(json.utf8)))
        XCTAssertEqual(result.map(\.id), [2, 1])
        XCTAssertEqual(result.first?.finished, "2026-01-01")
        XCTAssertNil(result.last?.finished)
    }

    func testSparseShelfDoesNotStretchAndPaginationPreservesOrder() {
        let books = SampleLibrary.books
        let pages = ShelfLayout.plan(for: books, width: 560, rowHeight: 500)
        XCTAssertEqual(pages.flatMap { $0.books }.map(\.id), books.map(\.id))
        for page in pages {
            let width = page.dimensions.values.reduce(CGFloat(0)) { $0 + $1.width }
            XCTAssertLessThanOrEqual(
                width + CGFloat(max(0, page.books.count - 1)) * ShelfLayout.gap, 560)
        }
        let narrow = ShelfLayout.dimensions(for: books[2], among: books, rowHeight: 500)
        let wide = ShelfLayout.dimensions(for: books[3], among: books, rowHeight: 500)
        XCTAssertLessThan(narrow.width, wide.width)
    }

    func testFallbackIsSeriesConsistentAndReadable() {
        let first = SpineStyle.fallback(for: SampleLibrary.books[0])
        let second = SpineStyle.fallback(for: SampleLibrary.books[7])
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.background.contrast(with: first.foreground), 4.5)
    }
    @MainActor func testBookLimitIsBoundedAndRestoresHiddenBooks() {
        let library = LibraryModel()
        library.bookCount = 20
        library.showSample()
        let original = library.books
        library.bookCount = -20
        XCTAssertEqual(library.bookCount, 1)
        XCTAssertEqual(library.books, Array(original.prefix(1)))
        library.bookCount = 1000
        XCTAssertEqual(library.bookCount, BookLimit.maximum)
        XCTAssertEqual(library.books, original)
        library.bookCount = 20
    }

    func testDimensionsStayBookShapedAndVaryWithinASeries() {
        let books = SampleLibrary.books
        let sizes = books.map { ShelfLayout.dimensions(for: $0, among: books, rowHeight: 500) }
        XCTAssertGreaterThan(Set(sizes.map(\.height)).count, 1)
        for size in sizes {
            XCTAssertTrue((380...480).contains(size.height))
            XCTAssertGreaterThanOrEqual(size.height / size.width, 3.1 - 0.001)
            XCTAssertLessThanOrEqual(size.height / size.width, 11.5 + 0.001)
        }
    }

    func testProviderRequestsKeepKeysOutOfURLsAndUseCorrectFormats() throws {
        for provider in AIProvider.allCases {
            let configuration = AIConfiguration(
                provider: provider, model: "vision-model",
                endpoint: "https://example.com/v1/chat/completions")
            let request = try AIStyleGenerator.request(
                prompt: "Return JSON", images: [Data([1, 2, 3])], configuration: configuration,
                key: "test-key")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.url!.absoluteString.contains("test-key"))
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            switch provider {
            case .google:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
                XCTAssertNotNil(body["contents"])
            case .anthropic:
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertNotNil(body["messages"])
            case .openAI:
                XCTAssertEqual(body["store"] as? Bool, false)
                XCTAssertNotNil(body["input"])
            case .generic: XCTAssertNotNil(body["messages"])
            }
        }
        XCTAssertThrowsError(
            try AIConfiguration(provider: .generic, model: "test", endpoint: "http://example.com")
                .validatedURL())
        XCTAssertNotEqual(
            AIConfiguration(provider: .generic, endpoint: "https://one.com").credentialAccount,
            AIConfiguration(provider: .generic, endpoint: "https://two.com").credentialAccount)
    }

    func testCustomProviderAcceptsNamespacedModelIDs() throws {
        let configuration = AIConfiguration(
            provider: .generic, model: "vendor/vision-model",
            endpoint: "https://example.com/v1/chat/completions")
        XCTAssertEqual(try configuration.validatedURL().host, "example.com")
        XCTAssertThrowsError(
            try AIConfiguration(provider: .google, model: "vendor/vision-model").validatedURL())
    }

    func testProviderResponsesAndColorValidation() throws {
        let fixtures: [(AIProvider, String)] = [
            (
                .google,
                #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"ignore"},{"text":"{}"}]}}]}"#
            ),
            (.anthropic, #"{"content":[{"type":"text","text":"{}"}]}"#),
            (.openAI, #"{"output":[{"content":[{"type":"output_text","text":"{}"}]}]}"#),
            (.generic, #"{"choices":[{"message":{"content":"{}"}}]}"#),
        ]
        for (provider, json) in fixtures {
            XCTAssertEqual(
                try AIStyleGenerator.responseText(Data(json.utf8), provider: provider), "{}")
            XCTAssertThrowsError(
                try AIStyleGenerator.responseText(Data("{}".utf8), provider: provider))
        }
        XCTAssertThrowsError(try StyleColor(hex: "not-a-color"))
        let background = try StyleColor(hex: "#777777")
        XCTAssertGreaterThanOrEqual(
            try StyleColor(hex: "#777777").readable(on: background).contrast(with: background), 4.5)
    }

    func testReadingSummaryShowsFormatAndDate() {
        var book = Book(
            id: 1, title: "Fixture", author: "Author", finished: "2026-01-01", format: "Listened")
        XCTAssertEqual(book.readingSummary(dateFormat: .monthName), "Audiobook • Jan 01, 2026")
        book.format = "Read"
        book.finished = nil
        XCTAssertEqual(book.readingSummary(dateFormat: .monthName), "Physical")
    }

    @MainActor
    func testColumnPagesAlignRowsOfDifferentLengths() {
        let books = (1...9).map { Book(id: $0, title: "Book \($0)", author: "Author") }
        let upper = BookPresentation.columnPages(books: books, width: 1600, rowHeight: 300)
        let lower = BookPresentation.columnPages(
            books: Array(books.prefix(5)), width: 1600, rowHeight: 300)
        XCTAssertEqual(upper.first?.books.count, 8)
        XCTAssertEqual(upper.map(\.books.count), [8, 1])
        XCTAssertEqual(lower.map(\.books.count), [5])
        let upperSize = upper[0].dimensions[1]
        XCTAssertEqual(upperSize, lower[0].dimensions[1], "Both rows use the same column width")
        XCTAssertEqual((upperSize?.width ?? 0) * 8 + ShelfLayout.gap * 7, 1600, accuracy: 0.01)
    }

    func testDetailCoverPrefersLargePortraitToSquareAndThumbnails() {
        let small = CoverImage(
            url: URL(string: "https://example.com/small"), width: 128, height: 197)
        let square = CoverImage(
            url: URL(string: "https://example.com/audio"), width: 3000, height: 3000)
        let portrait = CoverImage(
            url: URL(string: "https://example.com/print"), width: 978, height: 1500)
        XCTAssertEqual(HardcoverClient.bestCover(in: [small, square, portrait])?.url, portrait.url)
        XCTAssertNil(
            HardcoverClient.bestCover(in: [square, small]),
            "Square art and thumbnails are not covers")
        let headshot = CoverImage(
            url: URL(string: "https://example.com/author"), width: 200, height: 202)
        XCTAssertNil(HardcoverClient.coverURLs(edition: nil, book: headshot).preferred)
        XCTAssertNil(HardcoverClient.bestCover(in: []))

        let edition = CoverImage(
            url: URL(string: "https://example.com/edition"), width: 850, height: 1300)
        let sharper = CoverImage(
            url: URL(string: "https://example.com/default"), width: 1600, height: 2400)
        let choice = HardcoverClient.coverURLs(edition: edition, book: portrait)
        XCTAssertEqual(choice.preferred, edition.url, "A similar-size edition wins")
        XCTAssertEqual(choice.alternate, portrait.url)
        XCTAssertEqual(
            HardcoverClient.coverURLs(edition: edition, book: sharper).preferred, sharper.url,
            "A clearly larger default wins")
        XCTAssertEqual(
            HardcoverClient.coverURLs(edition: nil, book: portrait).preferred, portrait.url)
        XCTAssertNil(HardcoverClient.coverURLs(edition: nil, book: portrait).alternate)
    }

    func testGenresAndCommunityRatingsRemainSeparateFromPersonalScore() throws {
        let json =
            #"[{"id":1,"rating":5,"book":{"id":10,"title":"Test","rating":3.7,"ratings_count":20,"ratings_distribution":[{"rating":3.5,"count":12},{"rating":4,"count":8}],"cached_tags":{"Genre":[{"tag":"Fiction","count":10},{"tag":"Fantasy","count":5}]}}}]"#
        let books = HardcoverClient.normalize(
            try JSONDecoder().decode([UserBook].self, from: Data(json.utf8)))
        XCTAssertEqual(books.first?.genres, ["Fantasy"])
        XCTAssertEqual(books.first?.rating, 5)
        XCTAssertEqual(books.first?.communityRating, 3.7)
        XCTAssertEqual(books.first?.ratingDistribution?.reduce(0) { $0 + $1.count }, 20)
    }

    func testAppearanceOverrideAndSystemDefault() {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }

    func testShelfPaletteVariants() {
        let darkWood = ShelfPalette(isDark: true)
        XCTAssertTrue(darkWood.isWood)
        XCTAssertEqual(darkWood.woodAsset, "WalnutWood")
        XCTAssertEqual(darkWood.woodOpacity, 0.24)

        let lightWood = ShelfPalette(isDark: false)
        XCTAssertTrue(lightWood.isWood)
        XCTAssertEqual(lightWood.woodAsset, "OakWood")
        XCTAssertEqual(lightWood.woodOpacity, 0.42)

        let darkPlain = ShelfPalette(isDark: true, isWood: false)
        XCTAssertFalse(darkPlain.isWood)
        XCTAssertEqual(darkPlain.wallTop, darkPlain.wallBottom)

        let lightPlain = ShelfPalette(isDark: false, isWood: false)
        XCTAssertFalse(lightPlain.isWood)
        XCTAssertEqual(lightPlain.wallTop, lightPlain.wallBottom)
        XCTAssertNotEqual(darkPlain.shelf, darkWood.shelf)
        XCTAssertNotEqual(lightPlain.shelf, lightWood.shelf)
    }

    func testTopShelfContentUsesPostersAndValidatedBookLinks() throws {
        let books = (1...12)
            .map {
                TopShelfBook(
                    id: $0, title: "Book \($0)",
                    imageURL: URL(string: "https://example.com/\($0).jpg")!)
            }
        let content = try XCTUnwrap(TopShelfSnapshot.content(for: books))
        XCTAssertEqual(content.sections.first?.items.count, 10)
        let item = try XCTUnwrap(content.sections.first?.items.first)
        XCTAssertEqual(item.imageShape, .poster)
        XCTAssertEqual(item.displayAction?.url, URL(string: "bookworms://book/1"))
        XCTAssertEqual(BookLink.id(from: books[0].actionURL), 1)
        XCTAssertNil(TopShelfSnapshot.content(for: []))
        for value in [
            "https://book/1", "bookworms://other/1", "bookworms://book/-1",
            "bookworms://book/1?token=x", "bookworms://book/1/2",
        ] {
            XCTAssertNil(BookLink.id(from: URL(string: value)!))
        }
    }

}
