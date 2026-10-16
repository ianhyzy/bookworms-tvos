import Foundation

/// Measures spine lettering contrast and nudges a failing pair until it is readable at TV
/// distance without discarding the cover's tint.
///
/// `apca(text:background:)` uses the APCA SAPC-4 (0.1.9) constants. OKLab conversion follows
/// Björn Ottosson's reference matrices, with sRGB output clamped to the gamut.
enum SpineContrast {
    /// The side of a color pair that `resolve(foreground:background:minimumLc:)` changed.
    enum Side: Sendable {
        case foreground
        case background
    }

    struct Resolution: Hashable, Sendable {
        var foreground: StyleColor
        var background: StyleColor
        var lcBefore: Double
        var lcAfter: Double
        /// `nil` when the original pair already met the target.
        var nudged: Side?
    }

    struct Lab: Hashable, Sendable {
        var l: Double
        var a: Double
        var b: Double
    }

    /// WCAG 2 contrast ratio, from 1 to 21.
    static func wcag(_ first: StyleColor, _ second: StyleColor) -> Double {
        first.contrast(with: second)
    }

    /// Signed APCA lightness contrast: positive for dark text on a light background, negative for
    /// light text on a dark background.
    static func apca(text: StyleColor, background: StyleColor) -> Double {
        func luminance(_ color: StyleColor) -> Double {
            // APCA linearizes with a plain 2.4 exponent, not the piecewise sRGB curve.
            let value =
                0.2126729 * pow(color.red, 2.4) + 0.7151522 * pow(color.green, 2.4)
                + 0.0721750 * pow(color.blue, 2.4)
            return value < 0.022 ? value + pow(0.022 - value, 1.414) : value
        }
        let textY = luminance(text)
        let backgroundY = luminance(background)
        if backgroundY > textY {
            let contrast = (pow(backgroundY, 0.56) - pow(textY, 0.57)) * 1.14
            return contrast < 0.1 ? 0 : (contrast - 0.027) * 100
        }
        let contrast = (pow(backgroundY, 0.65) - pow(textY, 0.62)) * 1.14
        return contrast > -0.1 ? 0 : (contrast + 0.027) * 100
    }

    static func lab(_ color: StyleColor) -> Lab {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let red = linear(color.red)
        let green = linear(color.green)
        let blue = linear(color.blue)
        let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
        return Lab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func color(_ lab: Lab) -> StyleColor {
        let l = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l3 = l * l * l
        let m3 = m * m * m
        let s3 = s * s * s
        func gamma(_ value: Double) -> Double {
            let clamped = max(0, min(1, value))
            return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return StyleColor(
            red: gamma(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            green: gamma(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            blue: gamma(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }

    /// Returns a pair whose absolute APCA contrast reaches `minimumLc` when possible.
    ///
    /// The foreground's OKLab lightness moves first and keeps the proposed polarity: dark ink
    /// moves toward black and light ink toward white. When APCA reports no polarity, the
    /// background's lightness chooses it. If the foreground reaches that extreme without meeting
    /// the target, it stays there and the background moves away from it: lighter under black ink,
    /// darker under white ink. Chroma eases toward zero near the lightness extremes so the result
    /// stays in gamut. If neither side reaches the target, the result keeps the extreme
    /// foreground on the original background.
    static func resolve(foreground: StyleColor, background: StyleColor, minimumLc: Double)
        -> Resolution
    {
        let before = apca(text: foreground, background: background)
        guard abs(before) < minimumLc else {
            return Resolution(
                foreground: foreground, background: background, lcBefore: before,
                lcAfter: before, nudged: nil)
        }
        // APCA is positive for dark text and 0 for pairs too close in lightness to have a polarity.
        let darkText = before == 0 ? lab(background).l >= 0.5 : before > 0
        func stepped(_ start: Lab, toward target: Double, passes: (StyleColor) -> Bool)
            -> StyleColor?
        {
            var current = start
            for _ in 0..<24 {
                current.l += (target - current.l) * 0.18
                let chroma = max(0.15, 1 - abs(current.l - 0.5) * 1.6)
                let candidate = color(Lab(l: current.l, a: start.a * chroma, b: start.b * chroma))
                if passes(candidate) { return candidate }
            }
            return nil
        }
        if let nudged = stepped(
            lab(foreground), toward: darkText ? 0 : 1,
            passes: { abs(apca(text: $0, background: background)) >= minimumLc })
        {
            return Resolution(
                foreground: nudged, background: background, lcBefore: before,
                lcAfter: apca(text: nudged, background: background), nudged: .foreground)
        }
        let extreme =
            darkText ? StyleColor(red: 0, green: 0, blue: 0) : StyleColor(red: 1, green: 1, blue: 1)
        if let nudged = stepped(
            lab(background), toward: darkText ? 1 : 0,
            passes: { abs(apca(text: extreme, background: $0)) >= minimumLc })
        {
            return Resolution(
                foreground: extreme, background: nudged, lcBefore: before,
                lcAfter: apca(text: extreme, background: nudged), nudged: .background)
        }
        return Resolution(
            foreground: extreme, background: background, lcBefore: before,
            lcAfter: apca(text: extreme, background: background), nudged: .foreground)
    }
}
