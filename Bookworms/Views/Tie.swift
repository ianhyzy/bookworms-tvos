import UIKit

/// Twine tied twice around a Book Wall series bundle, near its head and its tail, with a bow on
/// the tail's twine and a paper tag (`SeriesTag`) that hangs from the bow and counts the series'
/// books, over the series name on a paper label (`PaperLabel`), as the iPhone companion's `Tie`
/// draws a Year Stack bundle.
///
/// `image(for:)` bakes all of it into one transparent image the size of the bundle's face during
/// preparation, so the wall shows it on one plane in front of the spines. Sizes are in pixels at
/// `pixelsPerUnit`, at which a typical wall bundle is about as many pixels long as a companion
/// bundle, so the companion's pixel sizes carry over.
enum Tie {
    /// Pixels per scene unit on both axes.
    static let pixelsPerUnit: CGFloat = 256

    private static let twine = UIColor(red: 0.8, green: 0.68, blue: 0.48, alpha: 1)
    private static let twineDark = UIColor(red: 0.5, green: 0.38, blue: 0.23, alpha: 1)
    private static let twineLight = UIColor(red: 0.93, green: 0.84, blue: 0.66, alpha: 1)

    /// The tie's sizes on a bundle `length` by `thickness` pixels.
    struct Geometry {
        let length: CGFloat
        let thickness: CGFloat

        /// The twine's width.
        var width: CGFloat { max(6, length * 0.011) }
        /// The middle of the twine near the head, from the bundle's head.
        var head: CGFloat { length * 0.08 }
        /// The middle of the twine near the tail, which carries the bow and tag.
        var tail: CGFloat { length * 0.82 }
        /// The bow's middle, from the bundle's top.
        var knot: CGFloat { thickness * 0.15 }
        /// The tag's height: 74 percent of the bundle's thickness, up to 150 pixels, which keeps
        /// the tag inside the bundle's face.
        var tagHeight: CGFloat { min(thickness * 0.74, 150) }
        var tagTop: CGFloat { knot + thickness * 0.05 }
        /// The room between the twine and the label's edge or lettering.
        var gap: CGFloat { max(12, thickness * 0.06) }
        /// Where the label starts, from the head: a gap before the head twine, which crosses it.
        var labelStart: CGFloat { head - width / 2 - gap }
        /// The paper between the label's lettering and its tail end: its ruled border, and a gap
        /// inside it.
        var labelPadding: CGFloat { thickness * PaperLabel.share * PaperLabel.border + gap }
        /// Where the label's lettering can start and must end, from the head: a gap past the
        /// head twine, and far enough from the tag that the label ends half a gap short of it.
        var letteringStart: CGFloat { head + width / 2 + gap }
        var letteringEnd: CGFloat {
            tail - SeriesTag.width(height: tagHeight) / 2 - gap / 2 - labelPadding
        }
    }

    /// The bundle's tie, label, and tag, on a transparent image whose top edge is the bundle's
    /// top and whose left edge is the books' heads.
    static func image(for bundle: BookWallLayout.SeriesBundle) -> CGImage? {
        let size = CGSize(
            width: (CGFloat(bundle.length) * pixelsPerUnit).rounded(),
            height: (CGFloat(bundle.thickness) * pixelsPerUnit).rounded())
        guard size.width > 0, size.height > 0 else { return nil }
        let tie = Geometry(length: size.width, thickness: size.height)
        // Where the lettering may run, clear of the spines' bands, as the companion's
        // `ShareSpine.letteringBox` places it on a bundle.
        let band = CGFloat(bundle.topSpineThickness) * pixelsPerUnit
        let inset =
            max(6, tie.length * 0.035) + max(2, band * 0.07) + max(10, tie.thickness * 0.12)
        let start = max(inset, tie.letteringStart)
        let end = min(tie.length - inset, tie.letteringEnd)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let cg = context.cgContext
                // The twine and tag go over the label, so the head twine holds it.
                PaperLabel.draw(
                    bundle.name, tie: tie, letteringStart: start,
                    letteringWidth: max(0, end - start), in: cg)
                for middle in [tie.head, tie.tail] {
                    drawBand(
                        in: CGRect(
                            x: middle - tie.width / 2, y: 0, width: tie.width,
                            height: tie.thickness), context: cg)
                }
                let tag = CGRect(
                    x: tie.tail - SeriesTag.width(height: tie.tagHeight) / 2, y: tie.tagTop,
                    width: SeriesTag.width(height: tie.tagHeight), height: tie.tagHeight)
                SeriesTag.draw(count: bundle.books.count, in: tag, context: cg)
                // The tag's string runs from the bow down through the tag's hole.
                let hole = tag.minY + tag.height * SeriesTag.hole
                let string = tie.width * 0.45
                twine.setFill()
                UIBezierPath(
                    roundedRect: CGRect(
                        x: tie.tail - string / 2, y: tie.knot, width: string,
                        height: hole - tie.knot), cornerRadius: string / 2
                )
                .fill()
                drawBow(at: CGPoint(x: tie.tail, y: tie.knot), width: tie.width, context: cg)
            }
            .cgImage
    }

    /// The twine across the face: rounded across its width, twisted along it, and shaded where
    /// it wraps over the top and bottom edges.
    private static func drawBand(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 1, height: 0), blur: 3,
            color: UIColor(white: 0, alpha: 0.35).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.clip(to: rect)
        BookWallSpineTexture.drawGradient(
            [(twineDark, 0), (twineLight, 1 / 3), (twine, 2 / 3), (twineDark, 1)],
            from: CGPoint(x: rect.minX, y: 0), to: CGPoint(x: rect.maxX, y: 0), in: context)
        // Diagonal strokes, a little less than a width apart, read as the twine's twist.
        let pitch = rect.width * 0.9
        context.setStrokeColor(twineDark.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(max(1, rect.width * 0.14))
        for y in stride(from: rect.minY - rect.width, through: rect.maxY, by: pitch) {
            context.move(to: CGPoint(x: rect.minX, y: y + rect.width * 0.7))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
        BookWallSpineTexture.drawGradient(
            [
                (UIColor(white: 0, alpha: 0.4), 0), (.clear, 0.06), (.clear, 0.94),
                (UIColor(white: 0, alpha: 0.4), 1),
            ], from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.maxY), in: context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A bow centered on `knot`: two loops either side of the knot, with its ends hanging down.
    private static func drawBow(at knot: CGPoint, width: CGFloat, context: CGContext) {
        func loop(size: CGSize, angle: CGFloat, anchorTop: Bool, offset: CGPoint) {
            context.saveGState()
            context.translateBy(x: knot.x, y: knot.y)
            if anchorTop {
                // Turned about its top end, which stays at the knot.
                context.translateBy(x: offset.x, y: offset.y - size.height / 2)
                context.rotate(by: angle)
                context.translateBy(x: 0, y: size.height / 2)
            } else {
                context.translateBy(x: offset.x, y: offset.y)
                context.rotate(by: angle)
            }
            let path = UIBezierPath(
                roundedRect: CGRect(
                    x: -size.width / 2, y: -size.height / 2, width: size.width,
                    height: size.height), cornerRadius: min(size.width, size.height) / 2)
            twine.setFill()
            path.fill()
            twineDark.setStroke()
            path.lineWidth = 1
            path.stroke()
            context.restoreGState()
        }
        for side: CGFloat in [-1, 1] {
            loop(
                size: CGSize(width: width * 0.8, height: width * 3.2),
                angle: side * 18 * .pi / 180, anchorTop: true,
                offset: CGPoint(x: 0, y: width * 1.6))
            loop(
                size: CGSize(width: width * 3.4, height: width * 1.7),
                angle: side * 22 * .pi / 180, anchorTop: false,
                offset: CGPoint(x: side * width * 1.6, y: 0))
        }
        let center = UIBezierPath(
            ovalIn: CGRect(
                x: knot.x - width * 0.8, y: knot.y - width * 0.8, width: width * 1.6,
                height: width * 1.6))
        twine.setFill()
        center.fill()
        twineDark.setStroke()
        center.lineWidth = 1
        center.stroke()
    }
}

/// A cream library label with a ruled border, pasted flat across a bundle's face, lettered with
/// the series name in dark ink, as the iPhone companion's `PaperLabel` draws it.
enum PaperLabel {
    /// The label's height as a share of the bundle's thickness: as tall as the face allows,
    /// with a little cloth showing above and below.
    static let share: CGFloat = 0.88
    /// The ruled border's inner edge, inset from the label's edges, as a share of its height.
    static let border: CGFloat = 0.08
    /// The lettering's dark ink, which the tag's count shares.
    static let ink = UIColor(red: 61 / 255, green: 41 / 255, blue: 23 / 255, alpha: 1)
    /// The smallest lettering, in pixels, as on the companion's share images.
    static let minimumLettering: CGFloat = 30
    /// The smallest size two-line lettering starts at.
    static let wrappedLettering: CGFloat = 36

    /// The series name in a semibold serif, the companion's label face.
    static func font(size: CGFloat) -> UIFont {
        AppFontStyle.serif.uiFont(size: size, weight: .semibold)
    }

    /// Draws the label from the tie's `labelStart` to a little past its lettering, which starts
    /// at `letteringStart` and fits within `letteringWidth`, centered on the bundle's thickness.
    static func draw(
        _ name: String, tie: Tie.Geometry, letteringStart: CGFloat, letteringWidth: CGFloat,
        in context: CGContext
    ) {
        let height = tie.thickness * share
        let lettering = fit(name, width: letteringWidth, height: height)
        let lineWidth = min(
            letteringWidth, lettering.lines.map { width(of: $0, font: lettering.font) }.max() ?? 0)
        let label = CGRect(
            x: tie.labelStart, y: (tie.thickness - height) / 2,
            width: letteringStart + lineWidth + tie.labelPadding - tie.labelStart,
            height: height)
        context.saveGState()
        // Pasted flat, the paper shows only its edge.
        context.setShadow(
            offset: .zero, blur: 2, color: UIColor(white: 0, alpha: 0.35).cgColor)
        let paper = UIBezierPath(roundedRect: label, cornerRadius: height * 0.05)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        paper.addClip()
        BookWallSpineTexture.drawGradient(
            [
                (UIColor(red: 250 / 255, green: 242 / 255, blue: 222 / 255, alpha: 1), 0),
                (UIColor(red: 237 / 255, green: 224 / 255, blue: 194 / 255, alpha: 1), 1),
            ], from: CGPoint(x: 0, y: label.minY), to: CGPoint(x: 0, y: label.maxY),
            in: context)
        context.endTransparencyLayer()
        context.restoreGState()
        let rule = max(1, height * 0.02)
        let ruled = UIBezierPath(
            roundedRect: label.insetBy(
                dx: height * border - rule / 2, dy: height * border - rule / 2),
            cornerRadius: height * 0.03)
        ruled.lineWidth = rule
        UIColor(red: 0.6, green: 0.45, blue: 0.32, alpha: 1).setStroke()
        ruled.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: lettering.font, .foregroundColor: ink,
        ]
        let top = label.midY - CGFloat(lettering.lines.count) * lettering.font.lineHeight / 2
        for (index, line) in lettering.lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: attributes)
            let bounds = CGRect(
                x: letteringStart, y: top + CGFloat(index) * lettering.font.lineHeight,
                width: letteringWidth, height: lettering.font.lineHeight)
            text.draw(
                with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                context: nil)
        }
    }

    /// The first way of lettering `name` that fits a box `width` by `height` pixels, as the
    /// companion's `ShareSpine.options(_:thickness:)` tries them: at sizes from half the label's
    /// height down to `minimumLettering`, one line, then on a label tall enough for two lines at
    /// `wrappedLettering`, two balanced lines. When nothing fits, one line at the minimum size,
    /// which drawing truncates.
    static func fit(_ name: String, width: CGFloat, height: CGFloat) -> (
        font: UIFont, lines: [String]
    ) {
        // The lettering centers its lines in 84 percent of the label's height.
        let room = height * 0.84
        let one = max(minimumLettering, height * 0.5)
        let two = height * 0.32
        let wrapped = balanced(name)
        var factor: CGFloat = 1
        while true {
            let size = max(minimumLettering, one * factor)
            let font = font(size: size)
            if self.width(of: name, font: font) <= width, font.lineHeight <= room {
                return (font, [name])
            }
            if let wrapped, two >= wrappedLettering, two * factor > minimumLettering * 0.92 {
                let font = self.font(size: max(minimumLettering, two * factor))
                if wrapped.allSatisfy({ self.width(of: $0, font: font) <= width }),
                    2 * font.lineHeight <= room
                {
                    return (font, wrapped)
                }
            }
            if size == minimumLettering { return (font, [name]) }
            factor *= 0.92
        }
    }

    /// `text` broken at the space nearest its middle, or `nil` when it has no space.
    static func balanced(_ text: String) -> [String]? {
        let characters = Array(text)
        guard
            let space = characters.indices.filter({ characters[$0] == " " })
                .min(by: { abs($0 - characters.count / 2) < abs($1 - characters.count / 2) })
        else { return nil }
        return [String(characters[..<space]), String(characters[(space + 1)...])]
    }

    private static func width(of text: String, font: UIFont) -> CGFloat {
        // 2 percent wider than measured, in case drawing sets it a little wider.
        (text as NSString).size(withAttributes: [.font: font]).width * 1.02
    }
}

/// A manila luggage tag with a reinforced string hole, showing a series' book count, as the
/// iPhone companion's `SeriesTag` draws it.
enum SeriesTag {
    /// The hole's center, as a share of the tag's height from its top.
    static let hole: CGFloat = 0.17
    /// The count's size as a share of the tag's height.
    static let countShare: CGFloat = 0.42

    static func width(height: CGFloat) -> CGFloat { height * 0.64 }

    /// Draws the tag in `rect`, with its shadow, and punches its hole through what lies under it.
    static func draw(count: Int, in rect: CGRect, context: CGContext) {
        let shape = outline(rect)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 1, height: 2), blur: 6,
            color: UIColor(white: 0, alpha: 0.35).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        shape.addClip()
        BookWallSpineTexture.drawGradient(
            [
                (UIColor(red: 0.97, green: 0.92, blue: 0.81, alpha: 1), 0),
                (UIColor(red: 0.91, green: 0.84, blue: 0.69, alpha: 1), 1),
            ], from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.maxY), in: context)
        context.restoreGState()
        shape.lineWidth = max(1, rect.width * 0.025)
        UIColor(red: 0.66, green: 0.54, blue: 0.36, alpha: 1).setStroke()
        shape.stroke()
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * hole)
        UIColor(red: 0.84, green: 0.73, blue: 0.53, alpha: 1).setFill()
        circle(at: center, diameter: rect.width * 0.3).fill()
        let font = PaperLabel.font(size: rect.height * countShare)
        let text = count.formatted()
        let room = rect.width * 0.8
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        let fitted =
            measured > room ? font.withSize(font.pointSize * max(0.5, room / measured)) : font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fitted, .foregroundColor: PaperLabel.ink,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString)
            .draw(
                at: CGPoint(
                    x: rect.midX - size.width / 2,
                    y: rect.minY + rect.height * 0.62 - size.height / 2),
                withAttributes: attributes)
        // Punched through, so the bundle shows in the hole.
        circle(at: center, diameter: rect.width * 0.14).fill(with: .clear, alpha: 1)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func circle(at center: CGPoint, diameter: CGFloat) -> UIBezierPath {
        UIBezierPath(
            ovalIn: CGRect(
                x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter,
                height: diameter))
    }

    /// A luggage tag's outline: a card with its top corners cut off and its bottom corners
    /// rounded.
    private static func outline(_ rect: CGRect) -> UIBezierPath {
        let cut = rect.width * 0.28
        let radius = rect.width * 0.08
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return UIBezierPath(cgPath: path)
    }
}

extension BookWallLocalSpine {
    /// The largest step in OKLab lightness between a bundled book's cloth and its design's.
    static let clothStep = 0.04

    /// The cloth of `book`'s spine in a bundle that wears `design`: the design's own, stepped by
    /// up to `clothStep` in OKLab lightness, as `book` decides, away from the design's ink, as
    /// the iPhone companion's `ShareSpine.cloth(_:book:)` steps a bundle's slices.
    ///
    /// The step only widens the gap between the cloth and the ink, so a dark design stays dark
    /// and a light one light. Where the gamut would narrow it instead, the book keeps the
    /// design's cloth.
    static func cloth(_ design: Style, book: Book) -> StyleColor {
        var lab = design.background.oklab
        let away: Double = design.foreground.oklab.l > lab.l ? -1 : 1
        lab.l = min(1, max(0, lab.l + away * clothStep * SpineView.unit(book.id, salt: 81)))
        let stepped = StyleColor(oklab: lab)
        let own = design.background.contrast(with: design.foreground)
        return stepped.contrast(with: design.foreground) >= own ? stepped : design.background
    }
}
