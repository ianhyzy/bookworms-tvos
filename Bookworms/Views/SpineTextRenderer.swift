import SwiftUI

/// Preserves italic and decorative glyphs that extend beyond their typographic bounds.
struct SpineTextRenderer: TextRenderer {
    let fontSize: CGFloat

    // Drawing padding expands the raster surface without changing line wrapping or label spacing.
    // Bangers, for example, draws several points beyond the advance of its last letter.
    var displayPadding: EdgeInsets {
        let overhang = max(4, fontSize * 0.25)
        return EdgeInsets(top: overhang, leading: overhang, bottom: overhang, trailing: overhang)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            context.draw(line)
        }
    }
}
