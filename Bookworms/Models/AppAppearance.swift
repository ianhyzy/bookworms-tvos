import SwiftUI
import UIKit

/// Explicit display choices; source dates and cache timestamps remain unchanged.
enum AppDateFormat: String, CaseIterable, Identifiable {
    case monthName, monthFirst, dayFirst, iso
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monthName: "Jan 01, 2026"
        case .monthFirst: "01/31/2026"
        case .dayFirst: "31/01/2026"
        case .iso: "2026-01-31"
        }
    }
    private var pattern: String {
        switch self {
        case .monthName: "MMM dd, yyyy"
        case .monthFirst: "MM/dd/yyyy"
        case .dayFirst: "dd/MM/yyyy"
        case .iso: "yyyy-MM-dd"
        }
    }
    private static let formatters: [Self: DateFormatter] = Dictionary(
        uniqueKeysWithValues: allCases.map { option in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = option.pattern
            return (option, formatter)
        })
    func string(from date: Date) -> String {
        Self.formatters[self]!.string(from: date)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct ShelfPalette {
    let isDark: Bool
    var isWood: Bool = true
    var woodAsset: String { isDark ? "WalnutWood" : "OakWood" }
    var woodOpacity: Double { isDark ? 0.24 : 0.42 }

    var wallTop: Color {
        if !isWood {
            return isDark
                ? Color(red: 0.055, green: 0.07, blue: 0.09) : Color(white: 0.94)
        }
        return isDark
            ? Color(red: 0.19, green: 0.14, blue: 0.10) : Color(red: 0.91, green: 0.85, blue: 0.74)
    }
    var wallBottom: Color {
        if !isWood {
            return isDark
                ? Color(red: 0.055, green: 0.07, blue: 0.09) : Color(white: 0.94)
        }
        return isDark
            ? Color(red: 0.12, green: 0.085, blue: 0.06)
            : Color(red: 0.77, green: 0.67, blue: 0.54)
    }
    var shelf: Color {
        if !isWood {
            return isDark ? Color(white: 0.22) : Color(white: 0.80)
        }
        return isDark
            ? Color(red: 0.30, green: 0.20, blue: 0.13) : Color(red: 0.54, green: 0.38, blue: 0.23)
    }
    var text: Color {
        if !isWood {
            return isDark ? Color(white: 0.94) : Color(white: 0.15)
        }
        return isDark
            ? Color(red: 0.94, green: 0.89, blue: 0.81) : Color(red: 0.23, green: 0.18, blue: 0.13)
    }
}

/// System font families shared by every app-owned screen except Settings.
enum AppFontStyle: String, CaseIterable, Identifiable {
    case serif, sansSerif
    var id: String { rawValue }
    var title: String { self == .serif ? "Serif" : "Sans-serif" }
    /// `.serif` is New York on Apple platforms.
    var design: Font.Design { self == .serif ? .serif : .default }

    /// New York reads lighter than SF at the same weight, so regular serif text uses medium.
    /// Heavier weights are unchanged to preserve the heading hierarchy.
    func displayWeight(_ weight: Font.Weight) -> Font.Weight {
        self == .serif && weight == .regular ? .medium : weight
    }

    func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(
            ofSize: size, weight: self == .serif && weight == .regular ? .medium : weight)
        let design: UIFontDescriptor.SystemDesign = self == .serif ? .serif : .default
        return UIFont(
            descriptor: base.fontDescriptor.withDesign(design) ?? base.fontDescriptor, size: size)
    }
}

extension EnvironmentValues {
    @Entry var appFontStyle = AppFontStyle.serif
}

private struct AppTypography: ViewModifier {
    @AppStorage("fontStyle") private var style = AppFontStyle.serif
    func body(content: Content) -> some View {
        content.fontDesign(style.design).environment(\.appFontStyle, style)
    }
}

/// Sets a system font whose design comes from `appTypography()` and whose weight follows
/// `AppFontStyle.displayWeight(_:)`.
private struct AppFont: ViewModifier {
    @Environment(\.appFontStyle) private var style
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: style.displayWeight(weight)))
    }
}

extension View {
    /// Apply at presentation roots so open sheets also respond to preference changes.
    func appTypography() -> some View { modifier(AppTypography()) }

    /// Use for app-owned text instead of `.font(.system(size:weight:))`, outside Settings.
    func appFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(AppFont(size: size, weight: weight))
    }
}
