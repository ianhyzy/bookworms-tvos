import SwiftUI
import UIKit

struct SpineView: View {
    let book: Book
    let style: SpineStyle
    let dimensions: SpineDimensions
    let isFocused: Bool
    // Font registration changes outside SwiftUI; this value invalidates the resolved lettering.
    var fontRevision: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = dimensions.width
        let height = dimensions.height
        let title = style.uppercase ? book.spineTitle.uppercased() : book.spineTitle
        // Account for outer padding, the rule, and explicit gaps before rotating the text.
        let textLength = SpineTextMetrics.textLength(for: book, height: height)
        let textHeight = width - SpineTextMetrics.crossSpinePadding
        let typography = SpineTextMetrics.typography(
            for: book, style: style, dimensions: dimensions)
        ZStack {
            // Shadow the book shape only; shadowing the text layers creates costly offscreen passes.
            RoundedRectangle(cornerRadius: 4).fill(style.background.color.gradient)
                .shadow(
                    color: .black.opacity(isFocused ? 0.42 : 0.24), radius: isFocused ? 16 : 5,
                    x: 3, y: isFocused ? 6 : 2)
            // Pale paper needs a shallow crease; dark cloth can support stronger relief.
            let relief = 0.025 + 0.12 * (1 - style.background.luminance)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(relief), location: 0),
                    .init(color: .clear, location: 0.08),
                    .init(color: .white.opacity(relief * 0.55), location: 0.14),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.90),
                    .init(color: .black.opacity(relief * 0.65), location: 1),
                ], startPoint: .leading, endPoint: .trailing
            )
            .clipShape(.rect(cornerRadius: 4))
            VStack(spacing: 0) {
                Rectangle().fill(style.foreground.color.opacity(0.4)).frame(height: 1)
                    .padding(.horizontal, 14)
                Spacer().frame(height: 12)
                HStack(spacing: textLength * 0.03) {
                    VStack(spacing: 4) {
                        Text(title)
                            .font(
                                SpineTextMetrics.font(
                                    name: style.fontName, size: typography.titleSize)
                            )
                            .textRenderer(SpineTextRenderer(fontSize: typography.titleSize))
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle = book.spineSubtitle {
                            Text(subtitle)
                                .font(
                                    .system(
                                        size: SpineTextMetrics.fittedSize(
                                            subtitle, fontName: nil, maximum: 20,
                                            width: typography.titleLength - 2
                                                * SpineTextMetrics.titleEndPadding,
                                            height: textHeight * 0.26))
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, SpineTextMetrics.titleEndPadding)
                    .frame(width: typography.titleLength, height: textHeight)
                    SpineAuthorText(
                        text: book.author, fontName: style.fontName,
                        fontSize: typography.authorSize, width: typography.authorLength,
                        height: textHeight, color: style.foreground.color)
                }
                .multilineTextAlignment(.center)
                .frame(width: textLength, height: textHeight)
                .rotationEffect(.degrees(90))
                .frame(width: width, height: textLength)
                if book.format != nil {
                    Image(systemName: book.formatSymbol)
                        .appFont(size: 18)
                        .frame(height: 18)
                        .padding(.top, 24)
                }
            }
            .foregroundStyle(style.foreground.color)
            .padding(.vertical, 20)
        }
        .frame(width: width, height: height)
        .overlay {
            RoundedRectangle(cornerRadius: 4).fill(.white.opacity(isFocused ? 0.09 : 0))
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1, anchor: .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
    }
}
