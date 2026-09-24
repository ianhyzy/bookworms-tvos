import CryptoKit
import Foundation
import ImageIO
import UIKit
import os

/// Decode sizes for covers. Views request the smallest bucket that covers their on-screen pixels,
/// so the memory cache holds a few reusable sizes instead of one per frame height.
enum CoverSize {
    static let buckets = [400, 800, 1200, 1800, 2400]

    /// The smallest bucket at least `pixels` tall, or the largest bucket.
    static func bucket(forPixels pixels: Double) -> Int {
        buckets.first { Double($0) >= pixels } ?? buckets[buckets.count - 1]
    }
}

enum CoverImageCacheKey {
    static func key(for book: Book, size: Int) -> String {
        let urlString = book.detailCoverURL?.absoluteString ?? book.coverURL?.absoluteString ?? ""
        return "\(book.id):\(urlString)@\(size)"
    }
}

final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSString, CGImage>()

    init(totalCostLimit: Int = 120_000_000, countLimit: Int = 64) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    func exactImage(for book: Book, size: Int) -> CGImage? {
        let key = CoverImageCacheKey.key(for: book, size: size)
        return cache.object(forKey: key as NSString)
    }

    /// The exact size if cached, otherwise the nearest cached size: the smallest larger one, then
    /// the largest smaller one. A smaller result is a placeholder until the exact size loads.
    func image(for book: Book, size: Int) -> CGImage? {
        if let exact = exactImage(for: book, size: size) {
            return exact
        }
        let larger = CoverSize.buckets.filter { $0 > size }
        let smaller = CoverSize.buckets.filter { $0 < size }.reversed()
        for fallbackSize in larger + smaller {
            if let fallback = exactImage(for: book, size: fallbackSize) {
                return fallback
            }
        }
        return nil
    }

    func uiImage(for book: Book, size: Int) -> UIImage? {
        guard let cgImage = image(for: book, size: size) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func setImage(_ image: CGImage, for book: Book, size: Int) {
        let key = CoverImageCacheKey.key(for: book, size: size)
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

actor ArtworkStore {
    static let shared: ArtworkStore = {
        #if DEBUG && targetEnvironment(simulator)
            if let root = ScenarioNetwork.state.artworkRoot {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ScenarioURLProtocol.self]
                return ArtworkStore(
                    root: root, session: URLSession(configuration: configuration),
                    usesSavedCWAConfiguration: false)
            }
        #endif
        return ArtworkStore()
    }()
    private let root: URL
    private let session: URLSession
    private let usesSavedCWAConfiguration: Bool
    private var pendingDownloads: [URL: Task<Data, Error>] = [:]
    private var failedDownloads: [URL: Date] = [:]
    nonisolated let imageCache: CoverImageCache
    private static let log = Logger(subsystem: "gay.ian.Bookworms", category: "Artwork")

    init(
        root: URL = URL.cachesDirectory.appending(
            path: "Bookworms/artwork", directoryHint: .isDirectory),
        session: URLSession = .shared,
        usesSavedCWAConfiguration: Bool = true,
        imageCache: CoverImageCache = .shared
    ) {
        self.root = root
        self.session = session
        self.usesSavedCWAConfiguration = usesSavedCWAConfiguration
        self.imageCache = imageCache
    }

    /// Decodes the book's cover at `maximumPixelSize` and caches it in memory.
    ///
    /// Nonisolated so decoding runs off the actor; only the disk and download work is serialized.
    nonisolated func detailImage(
        for book: Book, maximumPixelSize: Int = 2400, allowsNetwork: Bool = true
    ) async throws -> CGImage {
        let size = min(2400, max(400, maximumPixelSize))
        if let cached = imageCache.exactImage(for: book, size: size) { return cached }
        let data = try await detailData(
            for: book, maximumPixelSize: 2400, allowsNetwork: allowsNetwork)
        let measurement = PerformanceDiagnostics.begin("ArtworkDecode")
        defer { measurement.end() }
        let image = try Self.thumbnail(data, size: size)
        imageCache.setImage(image, for: book, size: size)
        return image
    }

    func data(for url: URL, maximumPixelSize: Int = 1400, allowsNetwork: Bool = true) async throws
        -> Data
    {
        let original = try await originalData(for: url, allowsNetwork: allowsNetwork)
        return maximumPixelSize >= 2400 ? original : try resized(original, size: maximumPixelSize)
    }

    private func file(for url: URL, suffix: String) -> URL {
        let key = SHA256.hash(data: Data((url.absoluteString + suffix).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appending(path: key)
    }

    /// One reusable source serves tiles, shelves, ambient playback, and details across launches.
    private func originalData(for url: URL, allowsNetwork: Bool) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.badURL) }
        let canonical = file(for: url, suffix: "@source2400")
        // Reuse older size-specific files rather than downloading artwork again after an update.
        for suffix in ["@source2400", "@2400", "@2200", "", "@800", "@400"] {
            let cachedFile = file(for: url, suffix: suffix)
            if let cached = try? Data(contentsOf: cachedFile),
                CGImageSourceCreateWithData(cached as CFData, nil) != nil
            {
                if cachedFile != canonical { try? cached.write(to: canonical, options: .atomic) }
                return cached
            }
        }
        guard allowsNetwork else { throw URLError(.resourceUnavailable) }
        if let task = pendingDownloads[url] { return try await task.value }
        guard Date().timeIntervalSince(failedDownloads[url] ?? .distantPast) >= 300 else {
            throw URLError(.resourceUnavailable)
        }
        let task = Task {
            let data = try await self.fetchOriginal(url)
            let original = try self.resized(data, size: 2400)
            try FileManager.default.createDirectory(
                at: self.root, withIntermediateDirectories: true)
            try original.write(to: canonical, options: .atomic)
            self.prune()
            return original
        }
        pendingDownloads[url] = task
        defer { pendingDownloads[url] = nil }
        do {
            let data = try await task.value
            failedDownloads[url] = nil
            return data
        } catch {
            failedDownloads[url] = Date()
            throw error
        }
    }

    private nonisolated static func thumbnail(_ data: Data, size: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(2400, max(400, size)),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    private func resized(_ data: Data, size: Int) throws -> Data {
        let image = try Self.thumbnail(data, size: size)
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, "public.jpeg" as CFString, 1, nil)
        else { throw URLError(.cannotDecodeContentData) }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw URLError(.cannotDecodeContentData)
        }
        return output as Data
    }

    private func fetchOriginal(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let started = Date()
        let data: Data
        let response: URLResponse
        if usesSavedCWAConfiguration,
            let configData = UserDefaults.standard.data(forKey: "cwaConfiguration"),
            let config = try? JSONDecoder().decode(CWAConfiguration.self, from: configData),
            let base = try? config.baseURL(), SourceRedirectPolicy.sameOrigin(base, url),
            let password = CredentialStore.read(account: "cwa-password")
        {
            data = try await CWAClient.shared.request(
                url, configuration: config, password: password)
            response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        } else {
            (data, response) = try await OfflineTestPolicy.data(for: request, session: session)
        }
        await APIUsageStore.shared.record(
            service: "artwork",
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            duration: Date().timeIntervalSince(started))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 || (500...599).contains(status) { throw URLError(.badServerResponse) }
        guard status == 200, data.count <= 15_000_000 else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    /// Returns the preferred cover, `detailCoverURL`, or the alternate `coverURL` if it fails.
    /// Sync chooses both from the library snapshot; rendering never queries Hardcover for covers.
    func detailData(
        for book: Book, maximumPixelSize: Int = 2400, allowsNetwork: Bool = true
    ) async throws -> Data {
        var attempted = Set<URL>()
        var lastError: Error = URLError(.cannotDecodeContentData)
        for url in [book.detailCoverURL, book.coverURL].compactMap(\.self)
        where attempted.insert(url).inserted {
            do {
                return try await data(
                    for: url, maximumPixelSize: maximumPixelSize, allowsNetwork: allowsNetwork)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    /// Cover aspect ratios by book ID, and the books whose covers could not be prepared.
    struct Preparation: Sendable {
        var ratios: [Int: Double] = [:]
        /// Books whose covers failed for a reason that may pass, such as a timeout. Missing,
        /// rejected, or undecodable images are not retried.
        var failed: [Book] = []
        var failureCount = 0
    }

    private nonisolated static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .badServerResponse,
        ]
        .contains(code)
    }

    /// Stores the complete bounded collections' covers on disk before their views mount.
    ///
    /// Reads each cover's dimensions from its header without decoding pixels; views decode the
    /// size they display. Books without a cover URL are not reported as failed.
    func prefetch(books: [Book], avatarURLs: [URL]) async -> Preparation {
        var result = Preparation()
        for start in stride(from: 0, to: books.count, by: 4) {
            guard !Task.isCancelled else { return result }
            let batch = Array(books[start..<min(start + 4, books.count)])
            await withTaskGroup(of: (Book, Double?, Bool).self) { group in
                for book in batch where book.detailCoverURL != nil || book.coverURL != nil {
                    group.addTask {
                        guard !Task.isCancelled else { return (book, nil, false) }
                        let data: Data
                        do {
                            data = try await self.detailData(for: book)
                        } catch {
                            return (book, nil, Self.isTransient(error))
                        }
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                                as? [CFString: Any],
                            let width = properties[kCGImagePropertyPixelWidth] as? Double,
                            let height = properties[kCGImagePropertyPixelHeight] as? Double,
                            width > 0, height > 0
                        else { return (book, nil, false) }
                        return (book, width / height, false)
                    }
                }
                for await (book, ratio, transient) in group {
                    if let ratio {
                        result.ratios[book.id] = ratio
                    } else {
                        result.failureCount += 1
                        if transient { result.failed.append(book) }
                    }
                }
            }
        }
        for url in Set(avatarURLs) {
            guard !Task.isCancelled else { break }
            _ = try? await data(for: url, maximumPixelSize: 400)
        }
        if result.failureCount > 0, !Task.isCancelled {
            Self.log.notice(
                "\(result.failureCount, privacy: .public) of \(books.count, privacy: .public) covers failed; retrying book IDs \(result.failed.map(\.id), privacy: .public)"
            )
        }
        return result
    }

    /// Clears download backoff so a deliberate retry of failed covers can reach the network.
    func forgetFailures() {
        failedDownloads.removeAll()
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Array(keys))) ?? []
        let entries =
            files.compactMap { url -> (url: URL, size: Int, modified: Date)? in
                guard url.pathExtension != "json",
                    let values = try? url.resourceValues(forKeys: keys)
                else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified < $1.modified }
        var size = entries.reduce(0) { $0 + $1.size }
        for entry in entries where size > 180_000_000 {
            try? FileManager.default.removeItem(at: entry.url)
            size -= entry.size
        }
    }
}
