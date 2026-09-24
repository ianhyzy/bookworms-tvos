import AppKit
import CoreImage.CIFilterBuiltins
import Vision

let filter = CIFilter.qrCodeGenerator()
let url = "https://hardcover.app/link"
filter.message = Data(url.utf8)
filter.correctionLevel = "M"
let raw = filter.outputImage!
// Four white modules around the code keep its edges detectable on dark screens.
let extent = raw.extent.insetBy(dx: -4, dy: -4)
let bordered = raw.composited(over: CIImage(color: .white).cropped(to: extent))
let scaled = bordered.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
let cg = CIContext().createCGImage(scaled, from: scaled.extent)!
let bitmap = NSBitmapImageRep(cgImage: cg)
try bitmap.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(cgImage: cg).perform([request])
precondition(request.results?.first?.payloadStringValue == url)
print("QR decoded successfully: \(url)")
