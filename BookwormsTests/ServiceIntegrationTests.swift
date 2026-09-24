import UIKit
import XCTest

@testable import Bookworms

final class ServiceIntegrationTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalResponseStub.self]
        return URLSession(configuration: configuration)
    }

    func testWholeViewPrefetchServesEverySizeOfflineAcrossLaunches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let books = (1...20)
            .map {
                Book(
                    id: $0, title: "Fixture", author: "Author",
                    coverURL: URL(string: "https://image.invalid/\(UUID().uuidString)"))
            }
        let store = ArtworkStore(root: root, session: session())
        let preparation = await store.prefetch(books: books, avatarURLs: [])
        XCTAssertEqual(preparation.ratios.count, 20)
        XCTAssertTrue(preparation.failed.isEmpty)
        let restored = ArtworkStore(root: root, session: session())
        for book in books {
            for size in CoverSize.buckets {
                let image = try await restored.detailImage(
                    for: book, maximumPixelSize: size, allowsNetwork: false)
                XCTAssertLessThanOrEqual(max(image.width, image.height), size)
            }
            XCTAssertEqual(LocalResponseStub.count(for: book.coverURL!.absoluteString), 1)
        }
    }

    func testCacheOnlyMissNeverDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://image.invalid/\(UUID().uuidString)")!
        let store = ArtworkStore(root: root, session: session())
        do {
            _ = try await store.detailImage(
                for: Book(id: 1, title: "Missing", author: "Fixture", coverURL: url),
                allowsNetwork: false)
            XCTFail("An unprepared image should report a cache miss.")
        } catch {}
        XCTAssertEqual(LocalResponseStub.count(for: url.absoluteString), 0)
    }

    func testFailedPreferredCoverFallsBackToAlternateAndReportsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = URL(string: "https://status404.invalid/\(UUID().uuidString)")!
        let good = URL(string: "https://image.invalid/\(UUID().uuidString)")!
        let store = ArtworkStore(root: root, session: session())
        let book = Book(
            id: 99, title: "Fixture", author: "Author", coverURL: good, detailCoverURL: broken)
        _ = try await store.detailImage(for: book)
        _ = try await store.detailImage(for: book, maximumPixelSize: 800)
        XCTAssertEqual(LocalResponseStub.count(for: broken.absoluteString), 1)
        XCTAssertEqual(LocalResponseStub.count(for: good.absoluteString), 1)
        let missing = Book(id: 100, title: "Fixture", author: "Author", detailCoverURL: broken)
        let preparation = await store.prefetch(
            books: [missing, Book(id: 101, title: "No cover", author: "Author")], avatarURLs: [])
        XCTAssertEqual(preparation.failureCount, 1)
        XCTAssertTrue(preparation.failed.isEmpty, "A 404 is permanent, so it is not retried")
    }

    func testMemoryCacheServesNearestSizeLargerFirst() throws {
        let cache = CoverImageCache()
        let book = Book(
            id: 7, title: "Fixture", author: "Author",
            detailCoverURL: URL(string: "https://image.invalid/cover"))
        func image(_ size: Int) throws -> CGImage {
            try XCTUnwrap(
                UIGraphicsImageRenderer(
                    size: CGSize(width: size, height: size),
                    format: {
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 1
                        return format
                    }()
                )
                .image { _ in }.cgImage)
        }
        XCTAssertNil(cache.image(for: book, size: 1200))
        cache.setImage(try image(40), for: book, size: 800)
        XCTAssertEqual(cache.image(for: book, size: 1200)?.width, 40)
        cache.setImage(try image(60), for: book, size: 2400)
        XCTAssertEqual(cache.image(for: book, size: 1200)?.width, 60)
    }

    func testCWACompletesPaginationAndRejectsCycles() async throws {
        let client = CWAClient(session: session())
        let books = try await client.fetchBooks(
            configuration: CWAConfiguration(server: "https://pages.invalid", username: "test"),
            password: "fixture")
        XCTAssertEqual(Set(books.map(\.title)), ["First", "Second"])
        do {
            _ = try await client.fetchBooks(
                configuration: CWAConfiguration(server: "https://cycle.invalid", username: "test"),
                password: "fixture")
            XCTFail("A pagination cycle must not replace the saved library with partial results.")
        } catch SourceError.incomplete {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCWAMapsHTTPFailuresAndRejectsExternalPaging() async {
        let client = CWAClient(session: session())
        for status in [401, 403, 404, 429, 503] {
            do {
                _ = try await client.fetchBooks(
                    configuration: CWAConfiguration(
                        server: "https://status\(status).invalid", username: "test"),
                    password: "fixture")
                XCTFail("HTTP failure must not return an empty successful library.")
            } catch {
                let text = UserFacingError.message(error)
                if status == 403 { XCTAssertTrue(text.contains("permission")) }
                if status == 401 { XCTAssertTrue(text.contains("login")) }
                if status == 404 { XCTAssertTrue(text.contains("not found")) }
            }
        }
        do {
            _ = try await client.fetchBooks(
                configuration: CWAConfiguration(
                    server: "https://external.invalid", username: "test"), password: "fixture")
            XCTFail("External pagination must not receive credentials.")
        } catch SourceError.unsafeLink {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCWAPathPrefixDoesNotAuthorizeSiblingPath() async {
        do {
            _ = try await CWAClient(session: session())
                .request(
                    URL(string: "https://unused.invalid/library-other/opds")!,
                    configuration: CWAConfiguration(
                        server: "https://unused.invalid/library", username: "test"),
                    password: "fixture")
            XCTFail("A sibling path is outside the configured base.")
        } catch SourceError.unsafeLink {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNestedOPDSSummaryPreservesText() throws {
        let xml = LocalResponseStub.feed(
            title: "Nested", id: "nested",
            summary: "<div xmlns='http://www.w3.org/1999/xhtml'>Before <em>inside</em> after.</div>"
        )
        let feed = try OPDSFeed.parse(
            Data(xml.utf8), url: URL(string: "https://local.invalid/opds")!,
            server: "https://local.invalid")
        XCTAssertEqual(feed.books.first?.description, "Before inside after.")
    }

    @MainActor
    func testArtworkSharesDownloadsDownsamplesAndRecoversFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://image.invalid/\(UUID().uuidString)")!
        let store = ArtworkStore(root: root, session: session())
        async let a = store.data(for: url, maximumPixelSize: 400)
        async let b = store.data(for: url, maximumPixelSize: 400)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        let image = try XCTUnwrap(UIImage(data: first)?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 400)
        XCTAssertEqual(LocalResponseStub.count(for: url.absoluteString), 1)
        let recovered = try await ArtworkStore(root: root, session: session())
            .data(for: url, maximumPixelSize: 400)
        XCTAssertEqual(first, recovered)
        XCTAssertEqual(LocalResponseStub.count(for: url.absoluteString), 1)
    }

    @MainActor
    func testArtworkCoalescesDifferentDisplaySizes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://image.invalid/\(UUID().uuidString)")!
        let store = ArtworkStore(root: root, session: session())
        async let tile = store.data(for: url, maximumPixelSize: 400)
        async let detail = store.data(for: url, maximumPixelSize: 1400)
        let (small, large) = try await (tile, detail)
        let smallImage = try XCTUnwrap(UIImage(data: small)?.cgImage)
        let largeImage = try XCTUnwrap(UIImage(data: large)?.cgImage)
        XCTAssertLessThanOrEqual(max(smallImage.width, smallImage.height), 400)
        XCTAssertGreaterThan(max(largeImage.width, largeImage.height), 400)
        XCTAssertEqual(LocalResponseStub.count(for: url.absoluteString), 1)
    }

    func testSourceSnapshotRoundTripAndCorruptionRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SourceLibraryStore(url: root.appending(path: "sources.json"))
        let snapshot = SourceSnapshot(
            source: .cwa, accountID: "fixture", books: SampleLibrary.books, syncedAt: Date())
        try store.save([snapshot])
        XCTAssertEqual(store.load().first?.books, snapshot.books)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testProviderMalformedAndEmptyResponsesAreRejected() {
        for provider in AIProvider.allCases {
            for body in ["{}", "[]", "not JSON"] {
                XCTAssertThrowsError(
                    try AIStyleGenerator.responseText(Data(body.utf8), provider: provider))
            }
        }
        XCTAssertThrowsError(
            try AIStyleGenerator.decode(StyleProposal.self, text: "```json\n{}\n```"))
    }

    func testEntireFontCatalogIsCachedAndUnlicensedDownloadIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = GoogleFontLibrary(root: root, session: session())
        let catalog = try await library.catalog()
        XCTAssertEqual(catalog.count, 125)
        XCTAssertEqual(catalog.last?.family, "Fixture 124")
        let recovered = try await GoogleFontLibrary(root: root, session: session()).catalog()
        XCTAssertEqual(recovered.count, 125)
        do {
            _ = try await library.download(family: "Fixture 124")
            XCTFail("Fonts without a supported license must not be installed.")
        } catch AIError.unavailableFont {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testGoogleFontAntiXSSIPrefixPreservesJSON() {
        let json = "{\"familyMetadataList\":[]}"
        XCTAssertEqual(GoogleFontLibrary.cleanJSON(Data(")]}'\n\(json)".utf8)), Data(json.utf8))
        XCTAssertEqual(GoogleFontLibrary.cleanJSON(Data(json.utf8)), Data(json.utf8))
    }
}

/// Every response is generated locally; unexpected URLs fail instead of reaching the network.
private final class LocalResponseStub: URLProtocol, @unchecked Sendable {
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Int] = [:]
    }
    private static let counts = Counts()
    static func count(for key: String) -> Int { counts.lock.withLock { counts.values[key] ?? 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func feed(title: String, id: String, summary: String = "", next: String? = nil) -> String
    {
        """
        <feed xmlns="http://www.w3.org/2005/Atom">
        \(next.map { "<link rel='next' href='\($0)'/>" } ?? "")
        <entry><id>\(id)</id><title>\(title)</title><summary>\(summary)</summary>
        <link rel="http://opds-spec.org/acquisition" href="/download"/></entry></feed>
        """
    }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.counts.lock.withLock { Self.counts.values[url.absoluteString, default: 0] += 1 }
        let status: Int
        let data: Data
        switch url.host {
        case "fonts.google.com":
            status = 200
            if url.path == "/metadata/fonts" {
                data = try! JSONSerialization.data(withJSONObject: [
                    "familyMetadataList": (0..<125)
                        .map {
                            ["family": "Fixture \($0)", "category": "Serif", "isOpenSource": true]
                                as [String: Any]
                        }
                ])
            } else {
                data = Data(#"{"manifest":{"files":[],"fileRefs":[]}}"#.utf8)
            }
        case "pages.invalid":
            XCTAssertTrue(
                request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
            status = 200
            data = Data(
                Self.feed(
                    title: url.path == "/second" ? "Second" : "First", id: url.path,
                    next: url.path == "/second" ? nil : "/second"
                )
                .utf8)
        case "cycle.invalid":
            status = 200
            data = Data(Self.feed(title: "Cycle", id: "cycle", next: "/opds/new").utf8)
        case "external.invalid":
            status = 200
            data = Data(
                Self.feed(title: "External", id: "external", next: "https://never.invalid/page")
                    .utf8)
        case let host? where host.hasPrefix("status"):
            status = Int(host.dropFirst(6).prefix(3))!
            data = Data()
        case "image.invalid":
            status = 200
            // Core Graphics avoids main-thread UIKit work inside URLProtocol's callback.
            let context = CGContext(
                data: nil, width: 1200, height: 1800, bitsPerComponent: 8,
                bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(red: 0.3, green: 0.2, blue: 0.1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
            let output = NSMutableData()
            let destination = CGImageDestinationCreateWithData(
                output, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
            data = output as Data
        default:
            XCTFail("Unexpected request: \(url.host ?? "missing host")")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?
            .urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
