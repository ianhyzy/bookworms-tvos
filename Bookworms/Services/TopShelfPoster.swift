import CoreGraphics
import Foundation
import ImageIO

/// Draws the My Shelf light sweep into copies of current-read covers for Top Shelf, which
/// renders posters itself and can't overlay app views.
///
/// Posters are written to the App Group container, named by book and progress so the system
/// reloads an image when progress changes. The cover comes from `ArtworkStore`, which shares the
/// download with shelf preparation; a book whose cover can't be loaded keeps its HTTPS cover.
enum TopShelfPoster {
    static var directory: URL? {
        TopShelfSnapshot.fileURL?.deletingLastPathComponent()
            .appending(
                path: "top-shelf-posters", directoryHint: .isDirectory)
    }

    /// Returns `books` with `posterURL` set for each current read whose poster was written, and
    /// removes posters that no book uses.
    static func render(_ books: [TopShelfBook], artwork: ArtworkStore) async -> [TopShelfBook] {
        guard let directory else { return books }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result = books
        for index in result.indices {
            guard let progress = result[index].progress else { continue }
            let book = result[index]
            let file = directory.appending(
                path: "\(book.id)-\(Int((progress * 1000).rounded())).jpg")
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
        let kept = Set(result.compactMap { $0.posterURL?.lastPathComponent })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        where !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        return result
    }

    /// Returns a JPEG of the cover with the unread part dimmed and a white line at `progress`,
    /// matching `CoverView`'s sweep proportions.
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
        let line = max(2, width * 0.012)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 0.5))
        context.fill(CGRect(x: x, y: 0, width: width - x, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        context.fill(
            CGRect(x: min(max(0, x - line / 2), width - line), y: 0, width: line, height: height))
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
