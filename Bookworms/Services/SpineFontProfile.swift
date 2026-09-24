import CoreText
import UIKit

/// Estimates visual density, not reading ability. Unusual letterforms still need visual review.
@MainActor
enum SpineFontProfile {
    private static var buckets: [String: Int] = [:]

    static func bucket(fontName: String) -> Int {
        let font = UIFont(name: fontName, size: 64) ?? .systemFont(ofSize: 64, weight: .medium)
        if let saved = buckets[font.fontName] { return saved }
        let face = CTFontCreateWithName(font.fontName as CFString, 64, nil)
        // Sample both cases without word spacing. Measure ink inside each glyph's own bounds so
        // narrow faces and generous font side bearings are not measured as lighter strokes.
        let letters = Array("HAMBURGEFONhamburgefon".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: letters.count)
        CTFontGetGlyphsForCharacters(face, letters, &glyphs, letters.count)
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        let density: CGFloat? = pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
            else { return nil }
            var coverage: [CGFloat] = []
            for glyph in glyphs where glyph != 0 {
                guard let path = CTFontCreatePathForGlyph(face, glyph, nil) else { continue }
                let bounds = path.boundingBoxOfPath
                guard bounds.width > 0, bounds.height > 0 else { continue }
                context.clear(CGRect(x: 0, y: 0, width: side, height: side))
                context.saveGState()
                context.scaleBy(x: 60 / bounds.width, y: 60 / bounds.height)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                context.addPath(path)
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath()
                context.restoreGState()
                let sum = buffer.bindMemory(to: UInt8.self).reduce(0) { $0 + Int($1) }
                coverage.append(CGFloat(sum) / (255 * 60 * 60))
            }
            return coverage.isEmpty ? nil : coverage.reduce(0, +) / CGFloat(coverage.count)
        }
        let result =
            density.map { value in
                [CGFloat(0.22), 0.30, 0.40, 0.50].filter { value >= $0 }.count + 1
            } ?? 3
        // Key the resolved face so a temporary fallback cannot hide a later font download.
        buckets[font.fontName] = result
        return result
    }

    /// Matches apparent letter height first; visual weight contributes only a small correction.
    static func sizeScale(fontName: String, text: String? = nil) -> CGFloat {
        guard let text else { return 1 + CGFloat(3 - bucket(fontName: fontName)) * 0.03 }
        let font = UIFont(name: fontName, size: 64) ?? .systemFont(ofSize: 64, weight: .medium)
        let reference = UIFont.systemFont(ofSize: 64, weight: .medium)
        let capitals = text == text.uppercased() && text != text.lowercased()
        let actual = capitals ? font.capHeight : font.xHeight
        let target = capitals ? reference.capHeight : reference.xHeight
        guard actual > 0 else { return 1 }
        // Partial normalization preserves the cover's character instead of equalizing every face.
        let heightScale = pow(target / actual, 0.35)
        let weightScale = 1 + CGFloat(3 - bucket(fontName: fontName)) * 0.0075
        return min(1.06, max(0.94, heightScale * weightScale))
    }
}
