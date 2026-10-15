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

/// The owner's standing type rule: no spine ever uses Impact, which tvOS ships as a web font.
enum SpineFontPolicy {
    /// The PostScript name that replaces Impact.
    ///
    /// Bebas Neue is a heavy condensed sans in Impact's role. tvOS ships it as a system font, and
    /// Google Fonts serves it, so every Bookworms app uses the same replacement.
    static let impactReplacement = "BebasNeue"

    /// Returns whether a family or PostScript name, in any case or style suffix, is allowed.
    static func allows(_ name: String) -> Bool {
        !name.lowercased().contains("impact")
    }

    /// Returns whether a family or PostScript name may letter a spine, as the iPhone
    /// companion's `BookAnalyzer.allowsFamily(_:)` rules: never Impact, and never an italic,
    /// oblique, or slanted face, in any case and with or without spaces. A PostScript style
    /// that ends in "It", such as "Lora-BoldIt", counts as italic. The listed display and script
    /// faces slant by design without saying so.
    static func allowsFamily(_ name: String) -> Bool {
        let lowered = name.lowercased().filter { !$0.isWhitespace }
        let blocked = [
            "impact", "italic", "oblique", "slanted", "bangers", "shrikhand", "dancingscript",
            "pacifico", "satisfy", "greatvibes", "lobster", "courgette", "homemadeapple",
            "rocksalt",
        ]
        let postScriptStyle = name.split(separator: "-").dropFirst().last
        return !blocked.contains { lowered.contains($0) }
            && postScriptStyle?.hasSuffix("It") != true
    }

    /// Returns `name`, or `impactReplacement` when `name` is Impact.
    static func allowedFontName(_ name: String) -> String {
        allows(name) ? name : impactReplacement
    }
}

struct SpineStyle: Codable, Hashable, Sendable {
    var background: StyleColor
    var foreground: StyleColor
    /// A PostScript name. A saved style that names Impact decodes as
    /// `SpineFontPolicy.impactReplacement`.
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
