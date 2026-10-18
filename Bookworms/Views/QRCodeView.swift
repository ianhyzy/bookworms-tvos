import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code that opens `url` on a phone, black on white with a four-module quiet zone, so a
/// guest can follow up on Hardcover without typing.
///
/// Core Image draws the code once each time the view appears or its URL changes; focus changes
/// and redraws reuse it.
struct QRCodeView: View {
    let url: URL
    @State private var image: CGImage?

    private static let context = CIContext()

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
            } else {
                Color.white
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: url) { image = Self.image(for: url.absoluteString) }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("QR code that opens \(url.host() ?? "")\(url.path())")
    }

    /// The code for `text` at one pixel per module, including the quiet zone, or `nil` when Core
    /// Image can't encode it.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let bordered = code.composited(over: CIImage(color: .white).cropped(to: extent))
        return context.createCGImage(bordered, from: extent)
    }
}
