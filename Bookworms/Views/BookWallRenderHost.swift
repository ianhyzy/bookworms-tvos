import Combine
import RealityKit
import UIKit

/// Adapts host-owned rendering APIs without changing the wall's entities or motion.
@MainActor
protocol BookWallRenderHost: AnyObject {
    func subscribe<E: RealityKit.Event>(to event: E.Type, handler: @escaping (E) -> Void)
        -> Cancellable
    func project(_ point: SIMD3<Float>) -> CGPoint?
    func setAmbientExponent(_ exponent: Float)
}

/// Launch-only choices keep renderer experiments outside the TV interface.
struct BookWallHostConfiguration {
    let renderSize: CGSize
    let internalSize: CGSize
    let preferredFramesPerSecond: Int
    let antialiasingEnabled: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ name: String) -> String? {
            arguments.first(where: { $0.hasPrefix("--\(name)=") })?
                .split(separator: "=", maxSplits: 1).last.map(String.init)
        }
        let sizes = [
            "1080": CGSize(width: 1920, height: 1080),
            "900": CGSize(width: 1600, height: 900),
            "720": CGSize(width: 1280, height: 720),
        ]
        renderSize = sizes[value("wall-output") ?? "1080"] ?? sizes["1080"]!
        let diagnosticSize =
            PerformanceDiagnostics.isolates("wall-720p")
            ? "720"
            : PerformanceDiagnostics.isolates("wall-900p") ? "900" : "1080"
        let requested = sizes[value("wall-internal") ?? diagnosticSize] ?? renderSize
        internalSize = requested.width <= renderSize.width ? requested : renderSize
        preferredFramesPerSecond = value("wall-fps") == "30" ? 30 : 60
        // 4× multisampling smooths the drifting book's edges at no measured cost on Apple TV.
        antialiasingEnabled = value("wall-antialiasing") != "off"
    }
}

/// Records prototype surface facts without logging library content or credentials.
enum BookWallHostLog {
    static func write(_ message: String) {
        FileHandle.standardError.write(Data(("BookWallHost " + message + "\n").utf8))
    }
}
