import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit
import simd

/// A prototype renderer that draws Book Wall's fall and focus with Metal on its own thread,
/// in place of RealityKit on the main thread. `--wall-renderer=metal` turns it on; it has no
/// detail flight, ribbon, shadows, or shelf label yet.
enum BookMetalWall {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--wall-renderer=metal")

    /// The drawable's size in pixels: 1080p, or the height `--wall-metal-height=` names.
    static let renderSize: CGSize = {
        let height = integer("--wall-metal-height=") ?? 1080
        let clamped = min(2160, max(540, height))
        return CGSize(width: clamped * 16 / 9, height: clamped)
    }()

    /// Measurement only. `--wall-metal-stress=N` draws and shades every book N times a frame,
    /// to find how much load a frame holds, or no books at 0, as a control, and `--wall-metal-continuous` keeps drawing a
    /// resting wall, to compare frame pacing with and without activity on the main thread.
    static let stress = max(0, integer("--wall-metal-stress=") ?? 1)
    static let drawsAtRest = ProcessInfo.processInfo.arguments.contains("--wall-metal-continuous")
    /// Measurement only. `--wall-metal-trace` logs each late frame with what preceded it and
    /// times the main thread, which adds a timer there.
    static let traces = ProcessInfo.processInfo.arguments.contains("--wall-metal-trace")
    /// Measurement only. `--wall-metal-bare` draws the wall above every other view, so the
    /// system composes nothing over it: no glass, text, or focus targets show.
    static let coversOverlays =
        isEnabled && ProcessInfo.processInfo.arguments.contains("--wall-metal-bare")
    /// Measurement only. `--wall-metal-commit-delay=MS` holds each frame's GPU work back until
    /// that long after its callback, so it reaches the GPU behind the system compositor's work
    /// for the same refresh instead of racing it.
    static let commitDelay =
        TimeInterval(min(12, max(0, integer("--wall-metal-commit-delay=") ?? 0))) / 1000
    /// Measurement only. `--wall-metal-rate=display` leaves the display link at the display's
    /// own rate instead of asking for exactly 60 frames a second, and `--wall-metal-poke`
    /// unpauses the running link again on every change from the main thread.
    static let followsDisplayRate = ProcessInfo.processInfo.arguments.contains(
        "--wall-metal-rate=display")
    static let pokes = ProcessInfo.processInfo.arguments.contains("--wall-metal-poke")
    /// How many refreshes ahead of its presentation a frame is drawn: 2, or the count
    /// `--wall-metal-latency=` names.
    static let frameLatency = Float(min(4, max(1, integer("--wall-metal-latency=") ?? 2)))
    /// The renderer's log in the app's caches, replaced at launch, so a run can be read from the
    /// Apple TV afterward without a console attached.
    static let logURL = URL.cachesDirectory.appending(path: "BookMetalWall.log")

    private static func integer(_ prefix: String) -> Int? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) }
    }
}

/// One book's drawn artwork, as the rasterizer made it.
struct BookWallArtwork {
    let style: BookWallLocalSpine.Style
    let spine: BookWallSpineTexture.Mips
    let cover: CGImage?
}

/// The framing, fall, and lights that the Metal renderer shares with `BookWallScene`.
struct BookWallStage: Sendable {
    let cameraDepth: Float
    /// The camera's vertical field of view, in degrees.
    let fieldOfView: Float
    let dropHeight: Float
    /// The time between one book's drop and the next.
    let dropSpacing: TimeInterval
    let gravity: Float
    let damping: Float
    let pullOut: Float
    let pullOutDuration: Float
    let shelfSize: SIMD3<Float>
    let shelfCenter: SIMD3<Float>
    let shelfColor: StyleColor
    let shelfLight: SIMD3<Float>
    let poolLight: SIMD3<Float>
    let topLightDirection: SIMD3<Float>
}

/// Triangles for one draw call. Each vertex is nine floats: position, normal, texture
/// coordinate, and the surface it belongs to, which the fragment shader colors by.
struct BookMetalMesh {
    /// Matches the `part` values in BookMetalWall.metal.
    enum Part: Float {
        case cloth, spine, cover, pageEdge, accent, lettering
    }

    static let floatsPerVertex = 9
    var vertices: [Float] = []
    var indices: [UInt32] = []

    /// Adds `data` in `part`. A mesh with face materials, whose quads don't share vertices,
    /// draws its second material's quads in `alternate`.
    mutating func append(
        _ data: BookWallMeshData, as part: Part, alternate: Part? = nil,
        transform: Transform = .identity
    ) {
        let base = UInt32(vertices.count / Self.floatsPerVertex)
        let matrix = transform.matrix
        for index in data.positions.indices {
            let position = matrix * SIMD4<Float>(data.positions[index], 1)
            let normal = transform.rotation.act(data.normals[index])
            let uv =
                data.textureCoordinates.isEmpty ? SIMD2<Float>.zero : data.textureCoordinates[index]
            var vertexPart = part
            if let alternate, data.faceMaterials.indices.contains(index / 4 * 2),
                data.faceMaterials[index / 4 * 2] != 0
            {
                vertexPart = alternate
            }
            vertices += [
                position.x, position.y, position.z, normal.x, normal.y, normal.z, uv.x, uv.y,
                vertexPart.rawValue,
            ]
        }
        indices += data.indices.map { base + $0 }
    }

    /// Adds a plane facing +Z before `transform`, with the texture's bottom left at its
    /// bottom left, as RealityKit's generated planes map theirs.
    mutating func appendPlane(width: Float, height: Float, as part: Part, transform: Transform) {
        var data = BookWallMeshData()
        data.positions = [
            [-width / 2, -height / 2, 0], [width / 2, -height / 2, 0],
            [width / 2, height / 2, 0], [-width / 2, height / 2, 0],
        ]
        data.normals = Array(repeating: [0, 0, 1], count: 4)
        data.textureCoordinates = [[0, 0], [1, 0], [1, 1], [0, 1]]
        data.indices = [0, 1, 2, 0, 2, 3]
        append(data, as: part, transform: transform)
    }

    /// Adds a box centered on the origin.
    mutating func appendBox(size: SIMD3<Float>, as part: Part) {
        let quarter = Float.pi / 2
        let faces: [(SIMD2<Float>, simd_quatf, SIMD3<Float>)] = [
            ([size.x, size.y], simd_quatf(angle: 0, axis: [0, 1, 0]), [0, 0, size.z / 2]),
            ([size.x, size.y], simd_quatf(angle: .pi, axis: [0, 1, 0]), [0, 0, -size.z / 2]),
            ([size.z, size.y], simd_quatf(angle: quarter, axis: [0, 1, 0]), [size.x / 2, 0, 0]),
            (
                [size.z, size.y], simd_quatf(angle: -quarter, axis: [0, 1, 0]), [-size.x / 2, 0, 0]
            ),
            ([size.x, size.z], simd_quatf(angle: -quarter, axis: [1, 0, 0]), [0, size.y / 2, 0]),
            ([size.x, size.z], simd_quatf(angle: quarter, axis: [1, 0, 0]), [0, -size.y / 2, 0]),
        ]
        for (extent, rotation, center) in faces {
            appendPlane(
                width: extent.x, height: extent.y, as: part,
                transform: Transform(rotation: rotation, translation: center))
        }
    }
}

/// Per-frame shader constants. Matches `Frame` in BookMetalWall.metal.
private struct BookMetalFrame {
    var viewProjection: simd_float4x4
    var cameraPosition: SIMD4<Float>
    var shelfLightPosition: SIMD4<Float>
    var shelfLightColor: SIMD4<Float>
    var poolLightPosition: SIMD4<Float>
    var poolLightColor: SIMD4<Float>
    var topLightDirection: SIMD4<Float>
    var topLightColor: SIMD4<Float>
    var ambientTop: SIMD4<Float>
    var ambientBottom: SIMD4<Float>
}

/// Per-book shader constants. Matches `Book` in BookMetalWall.metal.
private struct BookMetalBook {
    var model = matrix_identity_float4x4
    var cloth = SIMD4<Float>.zero
    var paper = SIMD4<Float>.zero
    var accent = SIMD4<Float>.zero
    var lettering = SIMD4<Float>.zero
    var hinge = SIMD4<Float>.zero
}

extension StyleColor {
    /// This sRGB color as linear Display P3, the renderer's working space.
    fileprivate var linearP3: SIMD4<Float> {
        func linear(_ channel: Double) -> Float {
            Float(channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4))
        }
        let color = SIMD3<Float>(linear(red), linear(green), linear(blue))
        return SIMD4<Float>(
            simd_dot([0.8225, 0.1774, 0], color), simd_dot([0.0332, 0.9669, 0], color),
            simd_dot([0.0171, 0.0724, 0.9108], color), 1)
    }
}

/// Presents the wall through the Metal renderer.
struct BookMetalWallView: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let scene: BookWallScene
    /// Whether an opaque view covers the surface. A covered surface stops drawing.
    var isCovered = false

    func makeCoordinator() -> BookMetalWallHost { BookMetalWallHost() }

    func makeUIView(context: Context) -> BookMetalWallSurface {
        let surface = BookMetalWallSurface(frame: .zero)
        context.coordinator.connect(scene: scene, surface: surface)
        context.coordinator.setSceneActive(scenePhase == .active && !isCovered)
        return surface
    }

    func updateUIView(_ surface: BookMetalWallSurface, context: Context) {
        context.coordinator.setSceneActive(scenePhase == .active && !isCovered)
    }

    static func dismantleUIView(_ surface: BookMetalWallSurface, coordinator: BookMetalWallHost) {
        coordinator.dispose()
    }
}

@MainActor
final class BookMetalWallSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    // UIView constructs this layer from layerClass, so the cast follows that invariant.
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    weak var host: BookMetalWallHost?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BookWallRendererSurface.clearColor
        isOpaque = true
        isUserInteractionEnabled = false
        metalLayer.isOpaque = true
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.drawableSize = BookMetalWall.renderSize
        // Textures and colors are Display P3 with the sRGB transfer curve, as on the
        // RealityKit wall.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Core Animation resizes the drawable to the view's pixels when its bounds change.
        if metalLayer.drawableSize != BookMetalWall.renderSize {
            metalLayer.drawableSize = BookMetalWall.renderSize
        }
        host?.viewportChanged(size: bounds.size)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        host?.setAttached(window != nil)
    }
}

/// Builds GPU resources from the scene's wall on the main actor and hands them to the
/// render thread.
@MainActor
final class BookMetalWallHost {
    private weak var scene: BookWallScene?
    private var renderer: BookMetalRenderer?
    private var shown: BookWallPreparedWall?
    private var isAttached = false
    private var isSceneActive = false

    func connect(scene: BookWallScene, surface: BookMetalWallSurface) {
        self.scene = scene
        surface.host = self
        isAttached = surface.window != nil
        renderer = BookMetalRenderer(layer: surface.metalLayer) { [weak self] wallID in
            Task { @MainActor [weak self] in
                guard let self, let shown, shown.id == wallID else { return }
                self.scene?.finishMetalFall(of: shown)
            }
        }
        viewportChanged(size: surface.bounds.size)
        scene.attachMetalWall(self)
    }

    func dispose() {
        renderer?.stop()
        renderer = nil
        shown = nil
    }

    func viewportChanged(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // The scene frames the wall and publishes focus frames for this viewport.
        scene?.updateHostViewport(size: size)
    }

    func setAttached(_ attached: Bool) {
        isAttached = attached
        renderer?.setActive(isAttached && isSceneActive)
    }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        renderer?.setActive(isAttached && isSceneActive)
    }

    func setBackdrop(_ image: CGImage) {
        guard let renderer, let texture = renderer.makeTexture(image, mipmapped: false) else {
            return
        }
        renderer.setBackdrop(texture)
    }

    func focus(_ id: Int?) {
        renderer?.focus(id)
    }

    /// Shows `wall`, falling from the drop height or at rest.
    // ponytail: builds meshes and uploads textures here, on the main actor, when the wall
    // appears. Move this into BookWallPreparation when this renderer replaces RealityKit.
    func show(_ wall: BookWallPreparedWall, stage: BookWallStage, falls: Bool) {
        guard let renderer else { return }
        shown = wall
        var mesh = BookMetalMesh()
        var items: [BookMetalRenderer.Item] = []

        mesh.appendBox(size: stage.shelfSize, as: .cloth)
        var shelf = BookMetalBook()
        shelf.cloth = stage.shelfColor.linearP3
        items.append(
            BookMetalRenderer.Item(
                id: nil, indexStart: 0, indexCount: mesh.indices.count, spine: nil, cover: nil,
                uniforms: shelf,
                rest: Transform(translation: stage.shelfCenter), column: -1,
                delay: 0))

        let pageEdge = BookWallPageTexture.make()
            .flatMap {
                renderer.makeTexture($0, mipmapped: true)
            }
        for (order, slot) in wall.layout.slots.enumerated() {
            guard let artwork = wall.artwork[slot.book.id] else { continue }
            let cover = artwork.cover.flatMap { renderer.makeTexture($0, mipmapped: true) }
            let start = mesh.indices.count
            let bookMesh = BookWallScene.metalMesh(for: slot, hasCover: cover != nil)
            let base = UInt32(mesh.vertices.count / BookMetalMesh.floatsPerVertex)
            mesh.vertices += bookMesh.vertices
            mesh.indices += bookMesh.indices.map { base + $0 }
            let style = artwork.style
            var uniforms = BookMetalBook()
            uniforms.cloth = style.background.linearP3
            uniforms.paper = BookWallPageEdges.tint(of: slot.book, accent: style.accent).linearP3
            uniforms.accent = style.accent.linearP3
            uniforms.lettering = style.foreground.linearP3
            if cover != nil {
                let hinge = BookWallScene.hinge(of: slot)
                uniforms.hinge = [hinge.x, hinge.y, 0, 0]
            }
            items.append(
                BookMetalRenderer.Item(
                    id: slot.book.id, indexStart: start, indexCount: bookMesh.indices.count,
                    spine: renderer.makeTexture(artwork.spine), cover: cover, uniforms: uniforms,
                    rest: BookWallScene.restingTransform(for: slot, in: wall.layout),
                    column: slot.column,
                    delay: Double(order) * stage.dropSpacing))
        }
        renderer.show(
            wallID: wall.id, mesh: mesh, items: items, pageEdge: pageEdge, stage: stage,
            falls: falls)
    }
}

/// Draws the wall from a display link on its own thread, so work on the main thread cannot
/// delay a frame. Books move as functions of the frame's presentation time: the fall is the
/// closed form of a damped drop onto the book below, and focus eases one book out.
final class BookMetalRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    fileprivate struct Item {
        /// The book's ID, or `nil` for the shelf.
        let id: Int?
        let indexStart: Int
        let indexCount: Int
        let spine: (any MTLTexture)?
        let cover: (any MTLTexture)?
        var uniforms: BookMetalBook
        let rest: Transform
        let column: Int
        /// When the book starts to fall, after the fall starts.
        let delay: TimeInterval
    }

    private struct Page {
        let wallID: UUID
        let vertices: any MTLBuffer
        let indices: any MTLBuffer
        /// One buffer per frame in flight, each holding every item's constants.
        // ponytail: three buffers, since the display link keeps at most two frames in
        // flight. Size the ring from `preferredFrameLatency` if that changes.
        let uniforms: [any MTLBuffer]
        let items: [Item]
        let pageEdge: (any MTLTexture)?
        let stage: BookWallStage
    }

    private struct Pull {
        var from: Float
        var to: Float
        var start: CFTimeInterval?
    }

    /// Everything the main thread hands to the render thread, guarded by `lock`.
    private struct State {
        var page: Page?
        var backdrop: (any MTLTexture)?
        /// When the fall started; `nil` with `falls` set means it starts at the next frame.
        var fallStart: CFTimeInterval?
        var falls = false
        var focused: Int?
        var pulls: [Int: Pull] = [:]
        var isActive = false
        var maxGPUSeconds: CFTimeInterval = 0
        var totalGPUSeconds: CFTimeInterval = 0
        var gpuFrames = 0
        /// The last finished frame's GPU time, from its first GPU work to its last, which
        /// includes time the system compositor's work ran in between.
        var lastGPUSeconds: CFTimeInterval = 0
        /// The longest the main thread went without running its heartbeat.
        var mainMaxGap: CFTimeInterval = 0
    }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let bookPipeline: any MTLRenderPipelineState
    private let backdropPipeline: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState
    private let backdropDepthState: any MTLDepthStencilState
    private let link: CAMetalDisplayLink
    private let onLanded: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var state = State()
    private var thread: Thread?

    // Render-thread state.
    private var multisampleColor: (any MTLTexture)?
    private var multisampleDepth: (any MTLTexture)?
    private var frameIndex = 0
    private var lastTarget: CFTimeInterval?
    private var lastLead: CFTimeInterval = 0
    private var lastEntry: CFTimeInterval = 0
    private var heartbeat: (any DispatchSourceTimer)?
    private var windowStart: CFTimeInterval?
    private var windowFrames = 0
    private var windowLate = 0
    private var windowMaxGap: CFTimeInterval = 0
    private var windowMaxEncode: CFTimeInterval = 0

    private static let sampleCount = 4
    private static let bookStride = MemoryLayout<BookMetalBook>.stride
    /// Light levels in linear light, fitted by eye to the RealityKit wall: a spine facing the
    /// camera shows at about nine tenths of its texture's color.
    private static let shelfLightColor = SIMD4<Float>(0.50, 0.44, 0.36, 1)
    private static let poolLightColor = SIMD4<Float>(3.2, 2.5, 1.6, 1)
    private static let topLightColor = SIMD4<Float>(0.2, 0.2, 0.2, 1)
    private static let ambientTop = SIMD4<Float>(0.34, 0.33, 0.32, 1)
    private static let ambientBottom = SIMD4<Float>(0.18, 0.17, 0.16, 1)

    @MainActor
    init?(layer: CAMetalLayer, onLanded: @escaping @Sendable (UUID) -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary()
        else { return nil }
        layer.device = device
        self.device = device
        self.queue = queue
        self.onLanded = onLanded

        let vertex = MTLVertexDescriptor()
        let float = MemoryLayout<Float>.stride
        for (index, (format, offset)) in [
            (MTLVertexFormat.float3, 0), (.float3, 3), (.float2, 6), (.float, 8),
        ]
        .enumerated() {
            vertex.attributes[index].format = format
            vertex.attributes[index].offset = offset * float
            vertex.attributes[index].bufferIndex = 0
        }
        vertex.layouts[0].stride = BookMetalMesh.floatsPerVertex * float

        let books = MTLRenderPipelineDescriptor()
        books.label = "Book Wall books"
        books.vertexFunction = library.makeFunction(name: "bookVertex")
        books.fragmentFunction = library.makeFunction(name: "bookFragment")
        books.vertexDescriptor = vertex
        books.colorAttachments[0].pixelFormat = layer.pixelFormat
        books.depthAttachmentPixelFormat = .depth32Float
        books.rasterSampleCount = Self.sampleCount

        let backdrop = MTLRenderPipelineDescriptor()
        backdrop.label = "Book Wall backdrop"
        backdrop.vertexFunction = library.makeFunction(name: "bookBackdropVertex")
        backdrop.fragmentFunction = library.makeFunction(name: "bookBackdropFragment")
        backdrop.colorAttachments[0].pixelFormat = layer.pixelFormat
        backdrop.depthAttachmentPixelFormat = .depth32Float
        backdrop.rasterSampleCount = Self.sampleCount

        let depth = MTLDepthStencilDescriptor()
        // Under the stress multiplier, each repeated book passes the depth test again, so its
        // pixels are shaded again.
        depth.depthCompareFunction = BookMetalWall.stress > 1 ? .lessEqual : .less
        depth.isDepthWriteEnabled = true
        let noDepth = MTLDepthStencilDescriptor()
        noDepth.depthCompareFunction = .always
        noDepth.isDepthWriteEnabled = false
        guard let bookPipeline = try? device.makeRenderPipelineState(descriptor: books),
            let backdropPipeline = try? device.makeRenderPipelineState(descriptor: backdrop),
            let depthState = device.makeDepthStencilState(descriptor: depth),
            let backdropDepthState = device.makeDepthStencilState(descriptor: noDepth)
        else { return nil }
        self.bookPipeline = bookPipeline
        self.backdropPipeline = backdropPipeline
        self.depthState = depthState
        self.backdropDepthState = backdropDepthState

        link = CAMetalDisplayLink(metalLayer: layer)
        if !BookMetalWall.followsDisplayRate {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 60, preferred: 60)
        }
        link.preferredFrameLatency = BookMetalWall.frameLatency
        link.isPaused = true
        super.init()
        link.delegate = self
        let thread = Thread(target: self, selector: #selector(runThread), object: nil)
        if BookMetalWall.traces { startHeartbeat() }
        thread.name = "Book Wall renderer"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    // MARK: Main-thread interface

    func stop() {
        guard let thread else { return }
        thread.cancel()
        // Wakes the run loop so the thread sees the cancellation.
        perform(#selector(resume), on: thread, with: nil, waitUntilDone: false)
        self.thread = nil
    }

    func setActive(_ active: Bool) {
        lock.withLock { state.isActive = active }
        wake()
    }

    func setBackdrop(_ texture: any MTLTexture) {
        lock.withLock { state.backdrop = texture }
        wake()
    }

    func focus(_ id: Int?) {
        lock.withLock {
            guard state.focused != id else { return }
            // Each move starts from where the book is at the next frame, so a book that is
            // still easing out turns back smoothly.
            if let previous = state.focused {
                state.pulls[previous, default: Pull(from: 1, to: 1)].to = 0
                state.pulls[previous]?.start = nil
            }
            if let id {
                state.pulls[id, default: Pull(from: 0, to: 0)].to = 1
                state.pulls[id]?.start = nil
            }
            state.focused = id
        }
        wake()
    }

    fileprivate func show(
        wallID: UUID, mesh: BookMetalMesh, items: [Item], pageEdge: (any MTLTexture)?,
        stage: BookWallStage, falls: Bool
    ) {
        guard !mesh.indices.isEmpty,
            let vertices = device.makeBuffer(
                bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<Float>.stride),
            let indices = device.makeBuffer(
                bytes: mesh.indices, length: mesh.indices.count * MemoryLayout<UInt32>.stride)
        else { return }
        var uniforms: [any MTLBuffer] = []
        for _ in 0..<3 {
            guard
                let buffer = device.makeBuffer(
                    length: items.count * Self.bookStride, options: .storageModeShared)
            else { return }
            uniforms.append(buffer)
        }
        let page = Page(
            wallID: wallID, vertices: vertices, indices: indices, uniforms: uniforms,
            items: items, pageEdge: pageEdge, stage: stage)
        lock.withLock {
            state.page = page
            state.falls = falls
            state.fallStart = nil
            state.focused = nil
            state.pulls.removeAll()
        }
        wake()
    }

    /// Uploads a spine's prepared mip chain.
    func makeTexture(_ mips: BookWallSpineTexture.Mips) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: mips.width, height: mips.height, mipmapped: true)
        descriptor.mipmapLevelCount = mips.levels.count
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var (width, height) = (mips.width, mips.height)
        for (level, data) in mips.levels.enumerated() {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level,
                    withBytes: base, bytesPerRow: width * 4)
            }
            (width, height) = (max(1, width / 2), max(1, height / 2))
        }
        return texture
    }

    /// Uploads `image` as Display P3 with the sRGB transfer curve.
    func makeTexture(_ image: CGImage, mipmapped: Bool) -> (any MTLTexture)? {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: mipmapped)
        guard let bytes = context.data, let texture = device.makeTexture(descriptor: descriptor)
        else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
            bytesPerRow: width * 4)
        if mipmapped, let buffer = queue.makeCommandBuffer(),
            let blit = buffer.makeBlitCommandEncoder()
        {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        return texture
    }

    private func wake() {
        guard let thread else { return }
        perform(#selector(resume), on: thread, with: nil, waitUntilDone: false)
    }

    // MARK: Render thread

    @objc private func runThread() {
        link.add(to: .current, forMode: .default)
        // A paused link alone may not keep the run loop alive.
        RunLoop.current.add(Port(), forMode: .default)
        while !Thread.current.isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        link.invalidate()
    }

    @objc private func resume() {
        let active = lock.withLock { state.isActive }
        // Every change on the main thread wakes the link, often while it runs. Leave a running
        // link alone, so those wakes can't disturb its pacing.
        guard link.isPaused == active || BookMetalWall.pokes else { return }
        lastTarget = nil
        link.isPaused = !active
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update)
    {
        let encodeStart = CACurrentMediaTime()
        let time = update.targetPresentationTimestamp
        let snapshot = lock.withLock {
            if state.falls, state.fallStart == nil { state.fallStart = time }
            for id in state.pulls.keys where state.pulls[id]?.start == nil {
                state.pulls[id]?.start = time
            }
            return state
        }
        guard let page = snapshot.page else {
            link.isPaused = true
            return
        }
        let stage = page.stage
        let drawable = update.drawable
        let size = (width: drawable.texture.width, height: drawable.texture.height)
        guard let targets = multisampleTargets(width: size.width, height: size.height),
            let buffer = queue.makeCommandBuffer()
        else { return }

        // Poses.
        var heights = page.items.map(\.rest.translation.y)
        var landed = true
        if snapshot.falls, let fallStart = snapshot.fallStart {
            // How far the last book of each column still is above its place.
            var above: [Int: Float] = [:]
            for (index, item) in page.items.enumerated() where item.id != nil {
                let seconds = Float(time - fallStart - item.delay)
                let rest = item.rest.translation.y
                var height = stage.dropHeight
                if seconds > 0 {
                    // A drop from rest under gravity `g` with linear damping `k` has fallen
                    // (g / k) · (t − (1 − e^(−kt)) / k) after `t` seconds.
                    let damping = stage.damping
                    let fallen =
                        stage.gravity / damping
                        * (seconds - (1 - exp(-damping * seconds)) / damping)
                    height = stage.dropHeight - fallen
                }
                // A book stops on its place, or on the book below it while that one still
                // falls, so it lands the moment its support has.
                height = max(height, rest + (above[item.column] ?? 0))
                above[item.column] = height - rest
                heights[index] = height
                if height > rest { landed = false }
            }
        }
        var animating = snapshot.falls && !landed
        let ring = page.uniforms[frameIndex % page.uniforms.count]
        frameIndex += 1
        let constants = ring.contents()
            .bindMemory(to: BookMetalBook.self, capacity: page.items.count)
        for (index, item) in page.items.enumerated() {
            var pose = item.rest
            pose.translation.y = heights[index]
            if let id = item.id, let pull = snapshot.pulls[id], let start = pull.start {
                let progress = min(1, Float(time - start) / stage.pullOutDuration)
                if progress < 1 { animating = true }
                // Ease out, as the RealityKit wall's pull-out does.
                let eased = 1 - (1 - progress) * (1 - progress)
                let amount = pull.from + (pull.to - pull.from) * eased
                pose.translation += pose.rotation.act([0, 0, stage.pullOut * amount])
            }
            var uniforms = item.uniforms
            uniforms.model = pose.matrix
            constants[index] = uniforms
        }

        let aspect = Float(size.width) / Float(size.height)
        var frame = BookMetalFrame(
            viewProjection: Self.projection(fieldOfView: stage.fieldOfView, aspect: aspect)
                * Transform(translation: [0, 0, -stage.cameraDepth]).matrix,
            cameraPosition: [0, 0, stage.cameraDepth, 1],
            shelfLightPosition: SIMD4(stage.shelfLight, 1), shelfLightColor: Self.shelfLightColor,
            poolLightPosition: SIMD4(stage.poolLight, 1), poolLightColor: Self.poolLightColor,
            topLightDirection: SIMD4(stage.topLightDirection, 0),
            topLightColor: Self.topLightColor, ambientTop: Self.ambientTop,
            ambientBottom: Self.ambientBottom)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.color
        pass.colorAttachments[0].resolveTexture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.02, green: 0.01, blue: 0.006, alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let backdrop = snapshot.backdrop {
            encoder.setRenderPipelineState(backdropPipeline)
            encoder.setDepthStencilState(backdropDepthState)
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.setRenderPipelineState(bookPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(page.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<BookMetalFrame>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<BookMetalFrame>.stride, index: 1)
        encoder.setVertexBuffer(ring, offset: 0, index: 2)
        encoder.setFragmentBuffer(ring, offset: 0, index: 2)
        encoder.setFragmentTexture(page.pageEdge, index: 2)
        for _ in 0..<BookMetalWall.stress {
            for (index, item) in page.items.enumerated() {
                let offset = index * Self.bookStride
                encoder.setVertexBufferOffset(offset, index: 2)
                encoder.setFragmentBufferOffset(offset, index: 2)
                encoder.setFragmentTexture(item.spine, index: 0)
                encoder.setFragmentTexture(item.cover, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: item.indexCount, indexType: .uint32,
                    indexBuffer: page.indices,
                    indexBufferOffset: item.indexStart * MemoryLayout<UInt32>.stride)
            }
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            let seconds = completed.gpuEndTime - completed.gpuStartTime
            lock.withLock {
                state.lastGPUSeconds = seconds
                state.maxGPUSeconds = max(state.maxGPUSeconds, seconds)
                state.totalGPUSeconds += seconds
                state.gpuFrames += 1
            }
        }
        let wait = encodeStart + BookMetalWall.commitDelay - CACurrentMediaTime()
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        buffer.commit()

        if snapshot.falls, landed {
            lock.withLock { if state.page?.wallID == page.wallID { state.falls = false } }
            onLanded(page.wallID)
        }
        record(
            target: time, entry: encodeStart, encode: CACurrentMediaTime() - encodeStart,
            books: page.items.count - 1)
        // A still wall keeps its last frame until the main thread changes something.
        if !animating, !BookMetalWall.drawsAtRest {
            lastTarget = nil
            link.isPaused = true
        }
    }

    private func multisampleTargets(width: Int, height: Int)
        -> (color: any MTLTexture, depth: any MTLTexture)?
    {
        if let color = multisampleColor, let depth = multisampleDepth, color.width == width,
            color.height == height
        {
            return (color, depth)
        }
        func target(_ format: MTLPixelFormat) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = Self.sampleCount
            descriptor.usage = .renderTarget
            // The resolved frame goes to the drawable, so the samples need no memory of
            // their own on a tile-based GPU. The Simulator's GPU may not be one.
            #if targetEnvironment(simulator)
                descriptor.storageMode = .private
            #else
                descriptor.storageMode = .memoryless
            #endif
            return device.makeTexture(descriptor: descriptor)
        }
        guard let color = target(.bgra8Unorm_srgb), let depth = target(.depth32Float) else {
            return nil
        }
        multisampleColor = color
        multisampleDepth = depth
        return (color, depth)
    }

    /// Logs one line a second while frames draw: how many drew, how many arrived more than
    /// half a refresh late, the longest gap between frames, the longest time this thread spent
    /// on a frame, and the mean and longest GPU time of a frame.
    private func record(
        target: CFTimeInterval, entry: CFTimeInterval, encode: CFTimeInterval, books: Int
    ) {
        // How long before its presentation time the callback ran. A late frame with the usual
        // lead means the system skipped a callback; a short lead means this thread ran late.
        let lead = target - entry
        if let lastTarget {
            let gap = target - lastTarget
            windowMaxGap = max(windowMaxGap, gap)
            if gap > 1.5 / 60 {
                windowLate += 1
                if BookMetalWall.traces {
                    let (gpu, main) = lock.withLock {
                        defer { state.mainMaxGap = 0 }
                        return (state.lastGPUSeconds, state.mainMaxGap)
                    }
                    Self.write(
                        String(
                            format: "BookMetalWallLate gapMS=%.1f leadMS=%.1f previousLeadMS=%.1f "
                                + "callbackGapMS=%.1f lastGPUMS=%.2f mainMaxGapMS=%.1f\n",
                            gap * 1000, lead * 1000, lastLead * 1000, (entry - lastEntry) * 1000,
                            gpu * 1000, main * 1000))
                }
            }
        }
        lastTarget = target
        lastLead = lead
        lastEntry = entry
        windowFrames += 1
        windowMaxEncode = max(windowMaxEncode, encode)
        let start = windowStart ?? target
        windowStart = start
        guard target - start >= 1 else { return }
        let gpu = lock.withLock {
            defer {
                state.maxGPUSeconds = 0
                state.totalGPUSeconds = 0
                state.gpuFrames = 0
            }
            return (
                max: state.maxGPUSeconds,
                mean: state.totalGPUSeconds / Double(max(1, state.gpuFrames))
            )
        }
        let size = multisampleColor.map { "\($0.width)x\($0.height)" } ?? "none"
        let message =
            "BookMetalWallPipeline frames=\(windowFrames) late=\(windowLate)"
            + String(
                format: "maxGapMS=%.1f maxThreadMS=%.2f meanGPUMS=%.2f maxGPUMS=%.2f ",
                windowMaxGap * 1000, windowMaxEncode * 1000, gpu.mean * 1000, gpu.max * 1000)
            + String(format: "leadMS=%.1f ", lastLead * 1000)
            + "size=\(size) books=\(books) stress=\(BookMetalWall.stress)\n"
        Self.write(message)
        windowStart = nil
        windowFrames = 0
        windowLate = 0
        windowMaxGap = 0
        windowMaxEncode = 0
    }

    private static let logFile: FileHandle? = {
        try? FileManager.default.removeItem(at: BookMetalWall.logURL)
        FileManager.default.createFile(atPath: BookMetalWall.logURL.path, contents: nil)
        return try? FileHandle(forWritingTo: BookMetalWall.logURL)
    }()

    /// Writes to standard error and to `BookMetalWall.logURL`. Only the render thread calls it.
    private static func write(_ message: String) {
        let data = Data(message.utf8)
        FileHandle.standardError.write(data)
        logFile?.write(data)
    }

    /// Times the main thread with a timer every 4 ms, recording its longest gap.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var last = CACurrentMediaTime()
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            let now = CACurrentMediaTime()
            let gap = now - last
            last = now
            guard let self else { return }
            lock.withLock { state.mainMaxGap = max(state.mainMaxGap, gap) }
        }
        timer.resume()
        heartbeat = timer
    }

    /// A right-handed perspective projection onto Metal's 0-to-1 depth range.
    private static func projection(fieldOfView degrees: Float, aspect: Float) -> simd_float4x4 {
        let (near, far): (Float, Float) = (0.1, 200)
        let scale = 1 / tan(degrees * .pi / 360)
        return simd_float4x4(
            [scale / aspect, 0, 0, 0], [0, scale, 0, 0], [0, 0, far / (near - far), -1],
            [0, 0, near * far / (near - far), 0])
    }
}
