import Foundation
import UIKit

/// Builds a portable-looking spine from local book metadata and the selected cover image.
enum BookWallLocalSpine {
    struct Style: Equatable, Sendable {
        let background: StyleColor
        let foreground: StyleColor
        let accent: StyleColor
        let fontName: String
    }

    static func style(for book: Book, cover: CGImage?) -> Style {
        let samples = cover.flatMap(sampleColors) ?? []
        return style(for: book, samples: samples)
    }

    static func style(for book: Book, samples: [StyleColor]) -> Style {
        let fallback = SpineStyle.fallback(for: book)
        let ranked = rankedColors(samples)
        let background = ranked.first?.color ?? fallback.background
        let white = StyleColor(red: 1, green: 1, blue: 1)
        let black = StyleColor(red: 0, green: 0, blue: 0)
        let safeText =
            white.contrast(with: background) >= black.contrast(with: background) ? white : black
        let foreground =
            ranked.dropFirst()
            .first {
                $0.color.contrast(with: background) >= 4.5
            }?
            .color ?? safeText
        let accent =
            ranked.dropFirst()
            .first {
                $0.color.contrast(with: background) >= 2.0
            }?
            .color ?? foreground
        return Style(
            background: background, foreground: foreground, accent: accent,
            fontName: fontName(for: book))
    }

    /// Uses the first recognized ranked genre, falling back to a general-fiction face.
    static func fontName(for book: Book) -> String {
        for tag in book.genres ?? [] {
            let genre = tag.lowercased()
            if genre.contains("litrpg") || genre.contains("fantasy") || genre.contains("magic") {
                return "Georgia-Bold"
            }
            if genre.contains("science fiction") || genre.contains("sci-fi")
                || genre.contains("space opera") || genre.contains("cyberpunk")
            {
                return "Futura-Bold"
            }
            if genre.contains("mystery") || genre.contains("thriller") || genre.contains("crime") {
                return "DINCondensed-Bold"
            }
            if genre.contains("horror") || genre.contains("gothic") {
                return "Impact"
            }
            if genre.contains("romance") || genre.contains("love story") {
                return "Avenir-Heavy"
            }
            if genre.contains("history") || genre.contains("historical") {
                return "TimesNewRomanPS-BoldMT"
            }
            if genre.contains("literary") || genre.contains("classics") {
                return "AvenirNext-DemiBold"
            }
            if genre.contains("biography") || genre.contains("memoir") {
                return "HelveticaNeue-Bold"
            }
            if genre.contains("young adult") || genre.contains("middle grade") {
                return "ArialRoundedMTBold"
            }
            if genre.contains("graphic novel") || genre.contains("comics") {
                return "Arial-BoldMT"
            }
            if genre.contains("poetry") || genre.contains("verse") {
                return "Verdana-Bold"
            }
            if genre.contains("humor") || genre.contains("humour") || genre.contains("satire") {
                return "CourierNewPS-BoldMT"
            }
        }
        return "AvenirNext-DemiBold"
    }

    private struct RankedColor {
        let color: StyleColor
    }

    private struct Bucket {
        var count = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0

        mutating func add(_ color: StyleColor) {
            count += 1
            red += color.red
            green += color.green
            blue += color.blue
        }

        var average: StyleColor {
            StyleColor(
                red: red / Double(count), green: green / Double(count),
                blue: blue / Double(count))
        }
    }

    private static func rankedColors(_ samples: [StyleColor]) -> [RankedColor] {
        var bins: [Int: Bucket] = [:]
        for color in samples {
            let red = min(7, Int(color.red * 8))
            let green = min(7, Int(color.green * 8))
            let blue = min(7, Int(color.blue * 8))
            let key = (red << 6) | (green << 3) | blue
            bins[key, default: Bucket()].add(color)
        }
        return
            bins.sorted { left, right in
                left.value.count == right.value.count
                    ? left.key < right.key : left.value.count > right.value.count
            }
            .map { RankedColor(color: $0.value.average) }
    }

    private static func sampleColors(_ image: CGImage) -> [StyleColor]? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var colors: [StyleColor] = []
            colors.reserveCapacity(side * side)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Double(bytes[index + 3]) / 255
                guard alpha >= 0.5 else { continue }
                colors.append(
                    StyleColor(
                        red: min(1, Double(bytes[index]) / 255 + 1 - alpha),
                        green: min(1, Double(bytes[index + 1]) / 255 + 1 - alpha),
                        blue: min(1, Double(bytes[index + 2]) / 255 + 1 - alpha)))
            }
            return colors
        }
    }
}

extension StyleColor {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}
