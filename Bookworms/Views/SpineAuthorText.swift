import CoreText
import SwiftUI

struct SpineAuthorText: View {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    let width: CGFloat
    let height: CGFloat
    let color: Color

    var body: some View {
        let layout = SpineAuthorLayout.make(
            text, fontName: fontName, size: fontSize, width: width * 0.96)
        Canvas { context, size in
            context.withCGContext { graphics in
                graphics.setFillColor(UIColor(color).cgColor)
                for line in layout.lines {
                    graphics.saveGState()
                    // Core Text uses an upward baseline; Canvas uses a downward vertical axis.
                    graphics.translateBy(
                        x: size.width / 2 - line.bounds.midX,
                        y: (size.height - layout.size.height) / 2 + line.top + line.bounds.maxY)
                    graphics.scaleBy(x: 1, y: -1)
                    graphics.textMatrix = .identity
                    graphics.textPosition = .zero
                    CTLineDraw(line.text, graphics)
                    graphics.restoreGState()
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}
