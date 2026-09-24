import CoreText
import UIKit

/// Packs shaped name lines by their visible ink, preserving kerning and script connections.
@MainActor
struct SpineAuthorLayout {
    struct Line {
        let text: CTLine
        let bounds: CGRect
        let top: CGFloat
    }
    let lines: [Line]
    let size: CGSize
    private struct Key: Hashable {
        let text: String
        let font: String
        let size: CGFloat
        let width: CGFloat
    }
    private static var layouts: [Key: SpineAuthorLayout] = [:]
    private static var fits: [FitKey: CGFloat] = [:]
    private struct FitKey: Hashable {
        let key: Key
        let height: CGFloat
    }

    static func make(_ text: String, fontName: String, size: CGFloat, width: CGFloat) -> Self {
        let font = UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size, weight: .medium)
        let key = Key(text: text, font: font.fontName, size: size, width: width)
        if let cached = layouts[key] { return cached }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [Line] = []
        var offset = 0
        var top: CGFloat = 0
        var widest: CGFloat = 0
        // Use a visible gap, not a font-wide line box that reserves space for unused flourishes.
        let gap = max(2, size * 0.12)
        while offset < attributed.length {
            let count = max(
                1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(max(1, width))))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            if !bounds.isEmpty {
                lines.append(Line(text: line, bounds: bounds, top: top))
                top += bounds.height + gap
                widest = max(widest, bounds.width)
            }
            offset += count
        }
        let result = Self(lines: lines, size: CGSize(width: widest, height: max(0, top - gap)))
        if layouts.count >= 1024 { layouts.removeAll(keepingCapacity: true) }
        layouts[key] = result
        return result
    }

    static func fittedSize(
        _ text: String, fontName: String, maximum: CGFloat,
        width: CGFloat, height: CGFloat
    ) -> CGFloat {
        let resolved = UIFont(name: fontName, size: maximum)?.fontName ?? "system"
        let key = FitKey(
            key: Key(text: text, font: resolved, size: maximum, width: width), height: height)
        if let cached = fits[key] { return cached }
        var size = maximum
        while size > 8 {
            let layout = make(text, fontName: fontName, size: size, width: width * 0.96)
            if layout.size.width <= width * 0.96 && layout.size.height <= height * 0.9 { break }
            size -= 0.5
        }
        if fits.count >= 1024 { fits.removeAll(keepingCapacity: true) }
        fits[key] = size
        return size
    }
}
