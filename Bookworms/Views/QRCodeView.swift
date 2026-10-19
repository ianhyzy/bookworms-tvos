import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code that opens `url` on a phone, black on white with a four-module quiet zone, so a
/// guest can follow up on Hardcover without typing.
///
/// `QRCodeRenderer` draws the code off the main actor when the view appears or its URL changes,
/// and keeps recent codes, so reopening details reuses them. Focus changes never draw a code.
struct QRCodeView: View {
    /// The side of a book or profile code. Every Hardcover book and profile link encodes as a
    /// code 37 modules wide with its quiet zone, so this is four points per module, and modules
    /// stay whole pixels at 1080p.
    static let linkSide: CGFloat = 148

    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
            } else {
                Color.white
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: url) {
            let text = url.absoluteString
            image =
                await Task.detached(priority: .userInitiated) {
                    QRCodeRenderer.shared.image(for: text)
                }
                .value
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("QR code that opens \(url.host() ?? "")\(url.path())")
    }
}

/// Draws QR codes with Core Image and keeps the 32 most recent. `CIContext` and `NSCache` are
/// thread-safe, so any thread can call it.
final class QRCodeRenderer: @unchecked Sendable {
    static let shared = QRCodeRenderer()
    private let context = CIContext()
    private let cache = NSCache<NSString, CGImage>()

    init() { cache.countLimit = 32 }

    /// The code for `text` at one pixel per module, including the quiet zone, or `nil` when Core
    /// Image can't encode it.
    func image(for text: String) -> CGImage? {
        if let cached = cache.object(forKey: text as NSString) { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // The generator's output already has a one-module border.
        let extent = code.extent.insetBy(dx: -3, dy: -3)
        let bordered = code.composited(over: CIImage(color: .white).cropped(to: extent))
        guard let image = context.createCGImage(bordered, from: extent) else { return nil }
        cache.setObject(image, forKey: text as NSString)
        return image
    }
}
