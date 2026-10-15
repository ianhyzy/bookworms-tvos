import CoreText
import Foundation
import SwiftUI

struct StyleColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    func contrast(with other: StyleColor) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
    static let paper = StyleColor(red: 0.98, green: 0.94, blue: 0.83)
    static let ink = StyleColor(red: 0.08, green: 0.09, blue: 0.10)
    static func seed(_ id: Int) -> UInt64 { UInt64(bitPattern: Int64(id)) &* 2_654_435_761 }
}

/// The owner's standing type rules: no spine ever uses Impact, which tvOS ships as a web font,
/// or an italic, oblique, or slanted face.
enum SpineFontPolicy {
    /// The PostScript name that replaces Impact.
    ///
    /// Bebas Neue is a heavy condensed sans in Impact's role. tvOS ships it as a system font, and
    /// Google Fonts serves it, so every Bookworms app uses the same replacement.
    static let impactReplacement = "BebasNeue"

    /// Upright stand-ins, keyed by lowercased family without spaces, for Google Fonts families
    /// that slant by design without declaring it: the allowed display or hand-drawn family
    /// nearest in weight and role, as the iPhone companion maps them.
    static let slantedReplacements = [
        "bangers": "Bungee-Regular", "shrikhand": "ChangaOne",
        "dancingscript": "Kalam-Regular", "pacifico": "PermanentMarker-Regular",
        "satisfy": "Caveat-Regular", "greatvibes": "Caveat-Regular",
        "lobster": "PermanentMarker-Regular", "courgette": "Kalam-Regular",
        "homemadeapple": "Caveat-Regular", "rocksalt": "PermanentMarker-Regular",
    ]

    /// The Book Wall's general-fiction face, for a blocked name with no closer upright face.
    static let uprightFallback = "AvenirNext-DemiBold"

    /// Returns whether a family or PostScript name, in any case and with or without spaces, is
    /// allowed.
    ///
    /// Blocks Impact, italic, oblique, and slanted names, a PostScript style that ends in "It"
    /// (such as "Lora-BoldIt"), and the families in `slantedReplacements`, which slant without
    /// declaring it.
    static func allows(_ name: String) -> Bool {
        let lowered = name.lowercased().filter { !$0.isWhitespace }
        let blocked = ["impact", "italic", "oblique", "slanted"] + slantedReplacements.keys
        let postScriptStyle = name.split(separator: "-").dropFirst().last
        return !blocked.contains { lowered.contains($0) }
            && postScriptStyle?.hasSuffix("It") != true
    }

    /// Returns `name`, or the allowed upright PostScript name a saved style shows instead.
    ///
    /// | Saved name | Shown as |
    /// | --- | --- |
    /// | Impact, in any spelling | `BebasNeue` |
    /// | `Bangers-Regular` | `Bungee-Regular` |
    /// | `Shrikhand-Regular` | `ChangaOne` |
    /// | A slanted script, such as `DancingScript-Bold` | An upright hand-drawn face |
    /// | An italic face, such as `Lora-BoldItalic` or `Lora-It` | `Lora-Bold`, `Lora-Regular` |
    /// | Anything else blocked | `AvenirNext-DemiBold` |
    ///
    /// An upright name that is not installed falls back to the system font, which is upright.
    static func allowedFontName(_ name: String) -> String {
        guard !allows(name) else { return name }
        if name.lowercased().contains("impact") { return impactReplacement }
        let slantWords = ["Italic", "Oblique", "Slanted"]
        let parts = name.split(separator: "-", maxSplits: 1)
        let family = (parts.first ?? "").split(whereSeparator: \.isWhitespace)
            .filter { word in !slantWords.contains { $0.lowercased() == word.lowercased() } }
            .joined()
        if let mapped = slantedReplacements[family.lowercased()] { return mapped }
        var style = parts.count > 1 ? String(parts[1]) : ""
        for word in slantWords {
            style = style.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        if style.hasSuffix("It") { style.removeLast(2) }
        let upright = family + "-" + (style.isEmpty ? "Regular" : style)
        return !family.isEmpty && allows(upright) ? upright : uprightFallback
    }

    /// Returns whether a loaded face is upright: it has neither the italic trait nor a slant.
    static func isUpright(_ font: CTFont) -> Bool {
        let traits = CTFontCopyTraits(font) as? [CFString: Any]
        let slant = (traits?[kCTFontSlantTrait] as? NSNumber)?.doubleValue ?? 0
        return !CTFontGetSymbolicTraits(font).contains(.traitItalic) && abs(slant) < 0.01
    }
}

struct SpineStyle: Codable, Hashable, Sendable {
    var background: StyleColor
    var foreground: StyleColor
    /// A PostScript name. A saved style that names a blocked face, such as Impact or an italic,
    /// decodes as `SpineFontPolicy.allowedFontName(_:)`.
    var fontName: String
    var uppercase: Bool
    var recognizedTitle: Bool
    var provenance: String

    static func fallback(for book: Book) -> SpineStyle {
        let palettes = [
            StyleColor(red: 0.18, green: 0.29, blue: 0.28),
            StyleColor(red: 0.38, green: 0.20, blue: 0.16),
            StyleColor(red: 0.23, green: 0.28, blue: 0.39),
            StyleColor(red: 0.46, green: 0.36, blue: 0.22),
            StyleColor(red: 0.30, green: 0.22, blue: 0.34),
        ]
        let seed = StyleColor.seed(book.seriesID ?? book.id)
        return SpineStyle(
            background: palettes[Int(seed % UInt64(palettes.count))], foreground: .paper,
            fontName: seed.isMultiple(of: 2) ? "Georgia-Bold" : "AvenirNextCondensed-DemiBold",
            uppercase: false, recognizedTitle: false, provenance: "Local fallback")
    }
}

extension SpineStyle {
    /// Decodes a saved, cached, or iCloud style, replacing a blocked font before any view
    /// renders it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        background = try container.decode(StyleColor.self, forKey: .background)
        foreground = try container.decode(StyleColor.self, forKey: .foreground)
        fontName = SpineFontPolicy.allowedFontName(
            try container.decode(String.self, forKey: .fontName))
        uppercase = try container.decode(Bool.self, forKey: .uppercase)
        recognizedTitle = try container.decode(Bool.self, forKey: .recognizedTitle)
        provenance = try container.decode(String.self, forKey: .provenance)
    }
}

extension StyleColor {
    init(hex: String) throws {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            throw AIError.invalidResponse
        }
        self.init(
            red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255,
            blue: Double(number & 255) / 255)
    }

    func readable(on background: StyleColor) -> StyleColor {
        if contrast(with: background) >= 4.5 { return self }
        let white = StyleColor(red: 1, green: 1, blue: 1)
        let black = StyleColor(red: 0, green: 0, blue: 0)
        let target =
            background.contrast(with: white) >= background.contrast(with: black) ? white : black
        for step in 1...10 {
            let blend = Double(step) / 10
            let candidate = StyleColor(
                red: red * (1 - blend) + target.red * blend,
                green: green * (1 - blend) + target.green * blend,
                blue: blue * (1 - blend) + target.blue * blend)
            if candidate.contrast(with: background) >= 4.5 { return candidate }
        }
        return target
    }
}
