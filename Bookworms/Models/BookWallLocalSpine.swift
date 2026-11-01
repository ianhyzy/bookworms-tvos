import CoreText
import Foundation
import UIKit

/// Builds a portable-looking spine from a companion design, or from local book metadata and the
/// selected cover image when the book has no design.
enum BookWallLocalSpine {
    struct Style: Equatable, Sendable {
        let background: StyleColor
        let foreground: StyleColor
        let typography: Typography
        /// The companion design's accent, or `nil` for a style without one.
        var designAccent: StyleColor? = nil

        /// The color of a five-star book's sprayed edges and of its headband's second stripe,
        /// as on the iPhone: the design's accent, else the lettering mixed 45 percent toward
        /// the cloth, as the iPhone's look without a design mixes it.
        var accent: StyleColor { designAccent ?? foreground.mixed(with: background, 0.45) }
    }

    /// The spine's face and title case.
    struct Typography: Equatable, Sendable {
        /// A PostScript name, used when the face is registered in this process.
        let fontName: String?
        /// The Google Fonts family of an upright stand-in for a blocked face, drawn in its
        /// registered face nearest `weight` before `fontName`, the stand-in's Regular face.
        var standInFamily: String?
        /// The system face for a missing `fontName`: "serif", "sans", "rounded", or "monospaced".
        var typeface = "sans"
        /// The stand-in's or the system face's weight, from 400 to 700.
        var weight = 600
        var uppercase = false

        /// The stand-in's registered face nearest `weight`, else `fontName`, else the system
        /// face for `typeface` and `weight`.
        func font(size: CGFloat) -> UIFont {
            if let font = loadedFont(size: size) { return font }
            let system = UIFont.systemFont(
                ofSize: size,
                weight: weight >= 700
                    ? .bold : weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
            let design: UIFontDescriptor.SystemDesign =
                switch typeface {
                case "serif": .serif
                case "rounded": .rounded
                case "monospaced": .monospaced
                default: .default
                }
            return system.fontDescriptor.withDesign(design)
                .map { UIFont(descriptor: $0, size: size) } ?? system
        }

        /// The stand-in's registered face nearest `weight`, else `fontName`, or `nil` when
        /// neither is registered and the spine draws in the system face.
        func loadedFont(size: CGFloat) -> UIFont? {
            if let standInFamily,
                let face = GoogleFontLibrary.registeredFace(family: standInFamily, nearest: weight)
            {
                return CTFontCreateCopyWithAttributes(face, size, nil, nil) as UIFont
            }
            return fontName.flatMap { UIFont(name: $0, size: size) }
        }
    }

    /// The companion design's face, or the genre face without one. A design in a face the type
    /// rules block shows in `SpineFontPolicy.allowedFontName(_:)`'s upright replacement, such
    /// as Bebas Neue for Impact. A face that slants by design shows in its stand-in family
    /// (`SpineFontPolicy.standInFamily(for:)`) at the design's weight, or its Regular face, such
    /// as Patrick Hand for Dancing Script Bold. A face that is not installed shows in the design's system typeface.
    static func typography(for book: Book, design: SpineDesignV1?) -> Typography {
        guard let design else { return Typography(fontName: fontName(for: book)) }
        let fontName = design.fontPostScriptName.map(SpineFontPolicy.allowedFontName)
        return Typography(
            fontName: fontName,
            standInFamily: design.fontPostScriptName.flatMap(SpineFontPolicy.standInFamily),
            typeface: design.typeface, weight: design.weight, uppercase: design.uppercase)
    }

    /// Uses the companion design's colors and type when one exists; otherwise samples the cover.
    /// A design whose colors don't parse keeps its type, which `BookWallLayout` measured the
    /// spine's lettering in, over colors sampled from the cover.
    static func style(for book: Book, cover: CGImage?, design: SpineDesignV1? = nil) -> Style {
        if let design, let background = try? StyleColor(hex: design.backgroundHex),
            let foreground = try? StyleColor(hex: design.foregroundHex)
        {
            return Style(
                background: background, foreground: foreground,
                typography: typography(for: book, design: design),
                designAccent: try? StyleColor(hex: design.accentHex))
        }
        let sampled = style(for: book, samples: cover.flatMap(sampleColors) ?? [])
        guard let design else { return sampled }
        return Style(
            background: sampled.background, foreground: sampled.foreground,
            typography: typography(for: book, design: design))
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
        return Style(
            background: background, foreground: foreground,
            typography: typography(for: book, design: nil))
    }

    /// The colors down a cover's spine-side edge, head to tail, for the fold of the cover onto
    /// the spine and the front board's joint.
    ///
    /// Averages the art 2 to 4 percent in from the left edge, past the frame lines that scans
    /// often carry at the very edge, in 48 rows, and softens them along the height, as the
    /// iPhone companion's `CoverEdge` does. It redraws the cover once at 50 by 48 pixels; an
    /// unreadable image gives no colors.
    static func edgeColors(of image: CGImage) -> [StyleColor] {
        let (width, rows) = (50, 48)
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: rows, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows))
            return true
        }
        guard drew else { return [] }
        // The bitmap's first row is the image's top, the head.
        let column = (0..<rows)
            .map { row in
                let offset = (row * width + 1) * 4
                return SIMD3(
                    Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
            }
        let weights: [Double] = [1, 4, 6, 4, 1]
        return (0..<rows)
            .map { row in
                var sum = SIMD3<Double>.zero
                for (index, weight) in weights.enumerated() {
                    sum += column[min(rows - 1, max(0, row + index - 2))] * weight
                }
                let color = sum / 16 / 255
                return StyleColor(red: color.x, green: color.y, blue: color.z)
            }
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
                return SpineFontPolicy.impactReplacement
            }
            if genre.contains("romance") || genre.contains("love story") {
                return "Avenir-Heavy"
            }
            if genre.contains("history") || genre.contains("historical") {
                return "TimesNewRomanPS-BoldMT"
            }
            if genre.contains("literary") || genre.contains("classics") {
                return SpineFontPolicy.uprightFallback
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
        return SpineFontPolicy.uprightFallback
    }

    /// The portable typeface nearest a genre face from `fontName(for:)`: "serif", "sans",
    /// "rounded", or "monospaced".
    static func typeface(ofGenreFace name: String) -> String {
        switch name {
        case "Georgia-Bold", "TimesNewRomanPS-BoldMT": "serif"
        case "ArialRoundedMTBold": "rounded"
        case "CourierNewPS-BoldMT": "monospaced"
        default: "sans"
        }
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

/// What the reading history shows on a Book Wall book's page edges, by the iPhone's rules
/// (`PageEdges` there): a five-star book's edges are sprayed in its spine's accent, and other
/// books' edges yellow with the time since the reader first finished them.
enum BookWallPageEdges {
    static let fresh = StyleColor(red: 237 / 255, green: 230 / 255, blue: 209 / 255)
    /// Paper after `yellowingYears` or more.
    static let aged = StyleColor(red: 214 / 255, green: 184 / 255, blue: 124 / 255)
    static let yellowingYears = 15.0

    /// Whether the book has sprayed edges, which five-star books get.
    static func isSprayed(_ book: Book) -> Bool { (book.rating ?? 0) >= 5 }

    /// A five-star book's edges are `accent` with a little of the fresh paper. Other books'
    /// edges yellow quickly at first, then more slowly, until they are fully aged after
    /// `yellowingYears`, in eighths. Unfinished books have fresh pages.
    static func color(of book: Book, accent: StyleColor, now: Date = .now) -> StyleColor {
        if isSprayed(book) { return accent.mixed(with: fresh, 0.12) }
        guard let finished = book.finishes.compactMap(day).min() else { return fresh }
        let years = max(0, now.timeIntervalSince(finished) / (365.25 * 86_400))
        let age = (min(1, years / yellowingYears).squareRoot() * 8).rounded() / 8
        return fresh.mixed(with: aged, age)
    }

    /// The edges' color as a share of the fresh paper's, channel by channel, at most 1, which
    /// tints the wall's paper materials while keeping their look for fresh pages.
    static func tint(of book: Book, accent: StyleColor, now: Date = .now) -> StyleColor {
        let color = color(of: book, accent: accent, now: now)
        return StyleColor(
            red: min(1, color.red / fresh.red), green: min(1, color.green / fresh.green),
            blue: min(1, color.blue / fresh.blue))
    }

    /// The noon of a `yyyy-MM-dd` date, or of a timestamp that starts with one.
    private static func day(_ text: String) -> Date? {
        guard text.count >= 10 else { return nil }
        return try? Date(String(text.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
    }
}

extension StyleColor {
    /// The color `amount` of the way from this one to `other`.
    func mixed(with other: StyleColor, _ amount: Double) -> StyleColor {
        StyleColor(
            red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }
}
