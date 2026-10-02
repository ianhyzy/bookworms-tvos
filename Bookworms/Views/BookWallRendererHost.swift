import Combine
import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

#if BOOKWORMS_DIAGNOSTICS
    import os
#endif

/// Presents the shared wall scene through a Metal surface with an explicit pixel budget.
struct BookWallRendererView: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let scene: BookWallScene

    func makeCoordinator() -> BookWallRendererCoordinator {
        BookWallRendererCoordinator()
    }

    func makeUIView(context: Context) -> BookWallRendererSurface {
        let surface = BookWallRendererSurface(frame: .zero)
        context.coordinator.connect(scene: scene, surface: surface)
        context.coordinator.setSceneActive(scenePhase == .active)
        return surface
    }

    func updateUIView(_ surface: BookWallRendererSurface, context: Context) {
        context.coordinator.connect(scene: scene, surface: surface)
        context.coordinator.setSceneActive(scenePhase == .active)
    }

    static func dismantleUIView(
        _ surface: BookWallRendererSurface, coordinator: BookWallRendererCoordinator
    ) {
        coordinator.dispose()
        surface.coordinator = nil
    }
}

/// Keeps rendering lifecycle and errors inside the representable's noninteractive surface.
@MainActor
final class BookWallRendererSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    // UIView constructs this layer from layerClass, so the cast follows that invariant.
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    weak var coordinator: BookWallRendererCoordinator?
    private let errorLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.16, green: 0.11, blue: 0.08, alpha: 1)
        isOpaque = true
        isUserInteractionEnabled = false
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = false
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.maximumDrawableCount = 3
        // RealityRenderer's output uses Display P3 primaries with the sRGB transfer curve.
        // Tag those primaries so Core Animation preserves the scene's saturated colors.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.textColor = .white
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        errorLabel.isHidden = true
        addSubview(errorLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        errorLabel.frame = bounds.insetBy(dx: 120, dy: 120)
        coordinator?.viewportChanged(size: bounds.size)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.setAttached(window != nil)
    }

    func showError(_ message: String) {
        errorLabel.text = "Book Wall renderer could not continue.\n\(message)"
        errorLabel.isHidden = false
        bringSubviewToFront(errorLabel)
    }

    func clearError() {
        errorLabel.text = nil
        errorLabel.isHidden = true
    }
}

/// Serializes scene updates while allowing two GPU frames to overlap presentation.
@MainActor
final class BookWallRendererCoordinator: NSObject, BookWallRenderHost {
    private weak var surface: BookWallRendererSurface?
    private var scene: BookWallScene?
    private var renderer: RealityRenderer?
    private var commandQueue: (any MTLCommandQueue)?
    private var presentationPipeline: (any MTLRenderPipelineState)?
    /// Runs presentation when a frame's GPU work signals its slot's event.
    private let presentListener = MTLSharedEventListener(
        dispatchQueue: DispatchQueue(label: "Book Wall presentation"))
    /// Retains frame resources until their final GPU writer completes; presentation may follow.
    @MainActor
    private final class FrameSlot {
        let event: any MTLSharedEvent
        let colorTexture: any MTLTexture
        let cameraOutput: RealityRenderer.CameraOutput
        var submittedAt: CFTimeInterval?

        init(event: any MTLSharedEvent, texture: any MTLTexture) throws {
            self.event = event
            colorTexture = texture
            cameraOutput = try RealityRenderer.CameraOutput(
                .singleProjection(colorTexture: texture))
        }
    }

    private var frameSlots: [FrameSlot] = []
    private var displayLink: CADisplayLink?
    private var frameSerial: UInt64 = 0
    private var generation: UInt64 = 0
    private var previousTimestamp: CFTimeInterval?
    private var isAttached = false
    private var isApplicationActive = false
    private var failed = false
    private var lastGeometryLog: String?
    private var publishedInitialFocusFrames = false
    private var lastLoggedPauseState: Bool?
    private var loggedInitialSubmission = false

    #if BOOKWORMS_DIAGNOSTICS
        private static let pipelineSignposter = OSSignposter(
            subsystem: "gay.ian.Bookworms.performance", category: .pointsOfInterest)
        private var diagnosticWindowStarted: CFTimeInterval?
        private var diagnosticStartingInFlight = 0
        private var diagnosticTicks = 0
        private var skipsDriftFrame = false
        private var diagnosticSubmissions = 0
        private var diagnosticCompletions = 0
        private var diagnosticMaxSlotLifetime: CFTimeInterval = 0
        private var diagnosticMaxCompletionDispatch: CFTimeInterval = 0
        private var diagnosticSkipped = 0
        private var diagnosticIdle = 0
        private var diagnosticLastTick: CFTimeInterval?
        private var diagnosticMaxTickGap: CFTimeInterval = 0
        private var diagnosticMaxInFlight = 0
        private var diagnosticSubmitTime: CFTimeInterval = 0
    #endif

    func connect(scene: BookWallScene, surface: BookWallRendererSurface) {
        if self.scene === scene, self.surface === surface {
            viewportChanged(size: surface.bounds.size)
            return
        }
        dispose()
        self.scene = scene
        self.surface = surface
        surface.coordinator = self
        surface.clearError()
        isAttached = surface.window != nil
        isApplicationActive = UIApplication.shared.applicationState == .active
        failed = false
        do {
            try prepare(scene: scene, surface: surface)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationBecameActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationResignedActive),
                name: UIApplication.willResignActiveNotification, object: nil)
            let link = CADisplayLink(target: self, selector: #selector(renderFrame(_:)))
            let rate = Float(scene.hostConfiguration.preferredFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: rate, maximum: rate, preferred: rate)
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
            updatePauseState()
            viewportChanged(size: surface.bounds.size)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func prepare(scene: BookWallScene, surface: BookWallRendererSurface) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.unavailableMetal
        }
        surface.metalLayer.device = device
        surface.metalLayer.drawableSize = scene.hostConfiguration.renderSize
        let textureSize = scene.hostConfiguration.internalSize
        guard let queue = device.makeCommandQueue() else { throw RendererError.unavailableMetal }
        commandQueue = queue
        let library = try device.makeLibrary(source: Self.presentationShader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Book Wall presentation"
        descriptor.vertexFunction = library.makeFunction(name: "wallPresentationVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "wallPresentationFragment")
        descriptor.colorAttachments[0].pixelFormat = surface.metalLayer.pixelFormat
        presentationPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        // RealityKit renders into each slot's own texture, never into a drawable: on Apple TV,
        // rendering straight into drawables dropped much of the scene during detail flights.
        // Three slots let RealityKit finish one frame while it encodes the next.
        for index in 0..<3 {
            guard let event = device.makeSharedEvent() else { throw RendererError.unavailableMetal }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: Int(textureSize.width),
                height: Int(textureSize.height), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let color = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.unavailableTexture
            }
            color.label = "Book Wall color \(index)"
            frameSlots.append(try FrameSlot(event: event, texture: color))
        }
        let realityRenderer = try RealityRenderer()
        realityRenderer.activeCamera = scene.camera
        realityRenderer.cameraSettings.antialiasing =
            scene.hostConfiguration.antialiasingEnabled ? .multisample4X : .none
        realityRenderer.cameraSettings.isToneMappingEnabled = true
        realityRenderer.cameraSettings.colorBackground = .color(
            UIColor(red: 0.16, green: 0.11, blue: 0.08, alpha: 1).cgColor)
        realityRenderer.extendedDynamicRangeOutput = false
        realityRenderer.lighting.resource = scene.environmentResource
        realityRenderer.lighting.intensityExponent = scene.ambientExponent
        renderer = realityRenderer
        realityRenderer.entities.append(scene.root)
        scene.attachHost(self)
    }

    func subscribe<E: RealityKit.Event>(
        to event: E.Type, handler: @escaping (E) -> Void
    ) -> Cancellable {
        guard let renderer else {
            assertionFailure("The renderer must exist before attaching the wall scene.")
            return AnyCancellable {}
        }
        let subscription = renderer.subscribe(to: event, handler)
        return AnyCancellable { subscription.cancel() }
    }

    func project(_ point: SIMD3<Float>) -> CGPoint? {
        scene?.projectWithCamera(point)
    }

    func setAmbientExponent(_ exponent: Float) {
        renderer?.lighting.intensityExponent = exponent
    }

    func viewportChanged(size: CGSize) {
        guard let scene, let surface else { return }
        scene.updateHostViewport(size: size)
        let output = scene.hostConfiguration.renderSize
        if surface.metalLayer.drawableSize != output {
            surface.metalLayer.drawableSize = output
        }
        let message =
            "BookWallRendererViewport points=\(size.width)x\(size.height) "
            + "drawable=\(output.width)x\(output.height) "
            + "internal=\(scene.hostConfiguration.internalSize.width)x\(scene.hostConfiguration.internalSize.height) "
            + "antialiasing=\(scene.hostConfiguration.antialiasingEnabled ? "4x" : "none") "
            + "fpsRequest=\(scene.hostConfiguration.preferredFramesPerSecond) slots=3 drawables=3 "
            + "scaled=\(scene.hostConfiguration.internalSize != output) dynamicRange=standard "
            + "viewScale=\(surface.contentScaleFactor) layerScale=\(surface.metalLayer.contentsScale)"
        if message != lastGeometryLog {
            lastGeometryLog = message
            Self.log(message)
        }
    }

    func setAttached(_ attached: Bool) {
        isAttached = attached
        updatePauseState()
    }

    func setSceneActive(_ active: Bool) {
        isApplicationActive = active
        updatePauseState()
    }

    @objc private func applicationBecameActive() {
        isApplicationActive = true
        updatePauseState()
    }

    @objc private func applicationResignedActive() {
        isApplicationActive = false
        updatePauseState()
    }

    private func updatePauseState() {
        let paused = failed || !isAttached || !isApplicationActive
        let changed = displayLink?.isPaused != paused
        displayLink?.isPaused = paused
        if displayLink != nil, paused != lastLoggedPauseState {
            lastLoggedPauseState = paused
            Self.log(
                "BookWallRendererClock paused=\(paused) attached=\(isAttached) "
                    + "active=\(isApplicationActive) failed=\(failed)")
        }
        if changed {
            #if BOOKWORMS_DIAGNOSTICS
                if paused {
                    flushPipelineMetrics(reason: "pause")
                    diagnosticLastTick = nil
                }
            #endif
            previousTimestamp = nil
            // A resumed surface may have lost its last frame.
            if !paused { scene?.setNeedsFrame() }
        }
    }

    @objc private func renderFrame(_ link: CADisplayLink) {
        guard !failed, isAttached, isApplicationActive,
            let surface, surface.bounds.width > 0, surface.bounds.height > 0,
            let renderer
        else { return }
        #if BOOKWORMS_DIAGNOSTICS
            // A gap longer than one refresh means the main thread missed display-link callbacks.
            if let lastTick = diagnosticLastTick {
                diagnosticMaxTickGap = max(diagnosticMaxTickGap, link.timestamp - lastTick)
            }
            diagnosticLastTick = link.timestamp
            if PerformanceDiagnostics.isolates("wall-detail-30"), scene?.isDrifting == true {
                skipsDriftFrame.toggle()
                if skipsDriftFrame { return }
            }
            let frameStarted = CACurrentMediaTime()
            if diagnosticWindowStarted == nil {
                diagnosticWindowStarted = frameStarted
                diagnosticStartingInFlight = frameSlots.filter { $0.submittedAt != nil }.count
                diagnosticMaxInFlight = diagnosticStartingInFlight
            }
            diagnosticTicks += 1
            defer {
                diagnosticSubmitTime = max(
                    diagnosticSubmitTime, CACurrentMediaTime() - frameStarted)
                // One-second windows let summaries count submitted frames per second.
                if diagnosticTicks >= 60 { flushPipelineMetrics(reason: "window") }
            }
        #endif
        if frameSlots.contains(where: { slot in
            slot.submittedAt.map { link.timestamp - $0 > 5 } ?? false
        }) {
            fail("Metal did not complete a submitted frame within five seconds.")
            return
        }
        // A still wall keeps its last frame, so the compositor can reuse overlays such as glass.
        // The next drawn frame then advances one refresh rather than the time spent idle.
        if let scene, !scene.needsFrame {
            previousTimestamp = nil
            #if BOOKWORMS_DIAGNOSTICS
                diagnosticIdle += 1
            #endif
            return
        }
        // Do not wait for a frame slot or grow an unbounded frame queue.
        guard let slot = frameSlots.first(where: { $0.submittedAt == nil }) else {
            #if BOOKWORMS_DIAGNOSTICS
                diagnosticSkipped += 1
            #endif
            return
        }
        // After a late frame, advance at most two refreshes, so motion and physics continue from
        // where they were instead of jumping ahead by the stalled time.
        let refresh = link.targetTimestamp - link.timestamp
        let deltaTime = min(
            previousTimestamp.map { max(link.timestamp - $0, 0) } ?? refresh, 2 * refresh)
        previousTimestamp = link.timestamp
        slot.submittedAt = CACurrentMediaTime()
        frameSerial += 1
        let serial = frameSerial
        let currentGeneration = generation
        do {
            if !loggedInitialSubmission { Self.log("BookWallRendererSubmit begin") }
            guard let commandQueue, let presentationPipeline else {
                throw RendererError.unavailableMetal
            }
            // Present on a background queue once the GPU has finished all of the frame's work,
            // taking a drawable only then. RealityKit can finish a frame's work only while it
            // schedules the next one, so holding a drawable from the start of each frame left
            // too few for 60 fps. Remove these transfer annotations when Metal declares
            // Sendable.
            nonisolated(unsafe) let layer = surface.metalLayer
            nonisolated(unsafe) let texture = slot.colorTexture
            nonisolated(unsafe) let queue = commandQueue
            nonisolated(unsafe) let pipeline = presentationPipeline
            let release: @Sendable (String?) -> Void = { [weak self] failure in
                let completedAt = CACurrentMediaTime()
                Task { @MainActor [weak self] in
                    self?
                        .completeFrame(
                            slot, generation: currentGeneration, completedAt: completedAt,
                            failure: failure)
                }
            }
            slot.event.notify(presentListener, atValue: serial) { _, _ in
                guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer()
                else {
                    release(nil)
                    return
                }
                buffer.label = "Book Wall present \(serial)"
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.texture
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                    release("Metal could not create the presentation encoder.")
                    return
                }
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                buffer.present(drawable)
                buffer.addCompletedHandler { completed in
                    release(
                        completed.status == .error
                            ? completed.error?.localizedDescription ?? "Metal presentation failed."
                            : nil)
                }
                buffer.commit()
            }
            try renderer.updateAndRender(
                deltaTime: deltaTime, cameraOutput: slot.cameraOutput,
                actionsAfterRender: [.signal(slot.event, value: serial)])
            scene?.didDrawFrame()
            #if BOOKWORMS_DIAGNOSTICS
                diagnosticSubmissions += 1
                diagnosticMaxInFlight = max(
                    diagnosticMaxInFlight, frameSlots.filter { $0.submittedAt != nil }.count)
            #endif
            if !loggedInitialSubmission {
                loggedInitialSubmission = true
                Self.log("BookWallRendererSubmit scheduled")
            }
        } catch {
            slot.submittedAt = nil
            fail(error.localizedDescription)
        }
    }

    /// Releases one frame's resources on the main actor. GPU completion is not presentation.
    private func completeFrame(
        _ slot: FrameSlot, generation completedGeneration: UInt64,
        completedAt: CFTimeInterval, failure: String?
    ) {
        guard generation == completedGeneration, slot.submittedAt != nil else { return }
        #if BOOKWORMS_DIAGNOSTICS
            if diagnosticWindowStarted != nil, let submittedAt = slot.submittedAt {
                let releasedAt = CACurrentMediaTime()
                diagnosticCompletions += 1
                // Includes CPU submission, GPU work, and the completion's main-actor hop.
                diagnosticMaxSlotLifetime = max(
                    diagnosticMaxSlotLifetime, releasedAt - submittedAt)
                diagnosticMaxCompletionDispatch = max(
                    diagnosticMaxCompletionDispatch, releasedAt - completedAt)
            }
        #endif
        slot.submittedAt = nil
        if let failure {
            fail(failure)
        } else if !failed && !publishedInitialFocusFrames {
            publishedInitialFocusFrames = true
            Self.log("BookWallRendererGPU completed")
            scene?.refreshHostFocusFrames()
        }
    }

    #if BOOKWORMS_DIAGNOSTICS
        /// Logs a bounded window to stderr and Instruments; counters describe submission,
        /// resource ownership, and CPU waits rather than onscreen frame presentation.
        private func flushPipelineMetrics(reason: String) {
            guard let started = diagnosticWindowStarted else { return }
            let ended = CACurrentMediaTime()
            let inFlight = frameSlots.filter { $0.submittedAt != nil }.count
            let message =
                "BookWallRendererPipeline generation=\(generation) reason=\(reason) "
                + "uptime=\(ended) windowMS=\((ended - started) * 1_000) "
                + "ticks=\(diagnosticTicks) submitted=\(diagnosticSubmissions) "
                + "completed=\(diagnosticCompletions) skipped=\(diagnosticSkipped) "
                + "idle=\(diagnosticIdle) "
                + "startInFlight=\(diagnosticStartingInFlight) endInFlight=\(inFlight) "
                + "maxInFlight=\(diagnosticMaxInFlight) "
                + "maxSlotLifetimeMS=\(diagnosticMaxSlotLifetime * 1_000) "
                + "maxCompletionDispatchMS=\(diagnosticMaxCompletionDispatch * 1_000) "
                + "maxCallbackMS=\(diagnosticSubmitTime * 1_000) "
                + "viewScale=\(surface?.contentScaleFactor ?? 0) "
                + "layerScale=\(surface?.metalLayer.contentsScale ?? 0)"
            if PerformanceDiagnostics.enabled {
                Self.log(message)
                Self.pipelineSignposter.emitEvent(
                    "BookWallRendererPipeline", "\(message, privacy: .public)")
                if reason == "window" {
                    BookWallPipelineLog.append([
                        "epoch": Date().timeIntervalSince1970,
                        "windowMS": (ended - started) * 1_000, "ticks": Double(diagnosticTicks),
                        "submitted": Double(diagnosticSubmissions),
                        "skipped": Double(diagnosticSkipped), "idle": Double(diagnosticIdle),
                        "maxTickGapMS": diagnosticMaxTickGap * 1_000,
                    ])
                }
            }
            diagnosticWindowStarted = reason == "window" ? ended : nil
            diagnosticStartingInFlight = reason == "window" ? inFlight : 0
            diagnosticTicks = 0
            diagnosticSubmissions = 0
            diagnosticCompletions = 0
            diagnosticSkipped = 0
            diagnosticIdle = 0
            diagnosticMaxTickGap = 0
            diagnosticMaxInFlight = reason == "window" ? inFlight : 0
            diagnosticSubmitTime = 0
            diagnosticMaxSlotLifetime = 0
            diagnosticMaxCompletionDispatch = 0
        }
    #endif

    private func fail(_ message: String) {
        #if BOOKWORMS_DIAGNOSTICS
            flushPipelineMetrics(reason: "failure")
        #endif
        failed = true
        displayLink?.isPaused = true
        // A stopped render clock cannot finish a flight's continuation.
        scene?.detachHost(self)
        surface?.showError(message)
        Self.log("BookWallRendererError \(message)")
    }

    func dispose() {
        #if BOOKWORMS_DIAGNOSTICS
            flushPipelineMetrics(reason: "dispose")
        #endif
        generation += 1
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
        if let scene {
            scene.detachHost(self)
            renderer?.entities.remove(scene.root)
        }
        scene = nil
        surface?.coordinator = nil
        surface = nil
        renderer = nil
        commandQueue = nil
        presentationPipeline = nil
        frameSlots.removeAll()
        frameSerial = 0
        previousTimestamp = nil
        lastGeometryLog = nil
        publishedInitialFocusFrames = false
        lastLoggedPauseState = nil
        loggedInitialSubmission = false
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    // Sampling and attachment conversion preserve sRGB on both sides of the presentation
    // pass. Linear filtering also supports smaller internal textures without extra assets.
    private static let presentationShader = """
        #include <metal_stdlib>
        using namespace metal;
        struct WallPresentationVertex {
            float4 position [[position]];
            float2 uv;
        };
        vertex WallPresentationVertex wallPresentationVertex(uint vertexID [[vertex_id]]) {
            const float2 positions[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
            const float2 coordinates[] = { float2(0, 1), float2(2, 1), float2(0, -1) };
            WallPresentationVertex result;
            result.position = float4(positions[vertexID], 0, 1);
            result.uv = coordinates[vertexID];
            return result;
        }
        fragment float4 wallPresentationFragment(
            WallPresentationVertex input [[stage_in]], texture2d<float> color [[texture(0)]]) {
            constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge,
                filter::linear);
            return float4(color.sample(linearSampler, input.uv).rgb, 1);
        }
        """

    private enum RendererError: LocalizedError {
        case unavailableMetal
        case unavailableTexture
        case unavailableEncoder

        var errorDescription: String? {
            switch self {
            case .unavailableMetal:
                "Metal could not create a device, command queue, or render event."
            case .unavailableTexture: "Metal could not allocate the internal color texture."
            case .unavailableEncoder: "Metal could not create the presentation encoder."
            }
        }
    }
}

#if BOOKWORMS_DIAGNOSTICS
    /// Appends the renderer's one-second pipeline windows to a file in the app's caches, replacing
    /// it at launch. `scripts/profile-book-wall.py` copies it from the TV after a run, so these
    /// counts survive gaps in the data Instruments streams over the network.
    @MainActor
    enum BookWallPipelineLog {
        static let url = URL.cachesDirectory.appending(path: "BookWallPipeline.jsonl")
        private static let handle: FileHandle? = {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return try? FileHandle(forWritingTo: url)
        }()

        static func append(_ fields: [String: Double]) {
            guard
                let line = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
            else { return }
            handle?.write(line + Data("\n".utf8))
        }
    }
#endif
