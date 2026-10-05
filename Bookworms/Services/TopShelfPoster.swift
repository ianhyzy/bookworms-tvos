import CoreGraphics
import Foundation
import ImageIO

/// Draws the My Shelf vertical light sweep into copies of current-read covers for Top Shelf, which
/// renders posters itself and can't overlay app views.
///
/// Posters are written to the App Group container, named by book and progress so the system
/// reloads an image when progress changes. The cover comes from `ArtworkStore`, which shares the
/// download with shelf preparation; a book whose cover can't be loaded keeps its HTTPS cover.
enum TopShelfPoster {
    /// Shared with `CoverView` so the app and Top Shelf sweeps match.
    static let dimOpacity = 0.4
    static let bleedOpacity = 0.2
    /// The width of the light bleeding left from the reader's place, as a fraction of the cover.
    static let bleedFraction = 0.1

    static var directory: URL? {
        TopShelfSnapshot.fileURL?.deletingLastPathComponent()
            .appending(
                path: "top-shelf-posters", directoryHint: .isDirectory)
    }

    /// Returns `books` with `posterURL` set for each current read whose poster was written.
    static func render(_ books: [TopShelfBook], artwork: ArtworkStore) async -> [TopShelfBook] {
        guard let directory else { return books }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result = books
        for index in result.indices {
            guard let progress = result[index].progress else { continue }
            let book = result[index]
            let file = directory.appending(
                path: "\(book.id)-\(Int((progress * 1000).rounded()))-soft.jpg")
            if !FileManager.default.fileExists(atPath: file.path()) {
                guard
                    let data = try? await artwork.data(
                        for: book.imageURL, maximumPixelSize: 800),
                    let jpeg = sweep(data, progress: progress)
                else { continue }
                guard (try? jpeg.write(to: file, options: .atomic)) != nil else { continue }
            }
            result[index].posterURL = file
        }
        return result
    }

    /// Removes posters that none of `books` uses.
    static func removeUnused(keeping books: [TopShelfBook]) {
        guard let directory else { return }
        let kept = Set(books.compactMap { $0.posterURL?.lastPathComponent })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        where !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Returns a JPEG of the cover with the unread part dimmed and light bleeding left from
    /// `progress`, matching `CoverView`'s sweep.
    static func sweep(_ data: Data, progress: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let x = width * min(1, max(0, progress))
        let bleed = min(x, width * bleedFraction)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: dimOpacity))
        context.fill(CGRect(x: x, y: 0, width: width - x, height: height))
        if bleed > 0,
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: bleedOpacity)]
                    as CFArray, locations: [0, 1])
        {
            context.saveGState()
            context.clip(to: CGRect(x: x - bleed, y: 0, width: bleed, height: height))
            context.drawLinearGradient(
                gradient, start: CGPoint(x: x - bleed, y: 0), end: CGPoint(x: x, y: 0),
                options: [])
            context.restoreGState()
        }
        guard let swept = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, swept, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
