import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit
import simd

/// Book Wall's renderer: Metal on its own thread, so work on the main thread can't delay a
/// frame. `BookWallScene` lays the wall out, plans flights, and places the label, ribbon, and
/// shadows; preparation builds each page's meshes and uploads its textures (`BookMetalPage`);
/// this draws them.
enum BookMetalWall {
    /// The drawable's size in pixels: 1080p, or the height `--wall-metal-height=` names.
    static let renderSize: CGSize = {
        let height = integer("--wall-metal-height=") ?? 1080
        let clamped = min(2160, max(540, height))
        return CGSize(width: clamped * 16 / 9, height: clamped)
    }()

    #if BOOKWORMS_DIAGNOSTICS
        /// `--wall-metal-stress=N` draws and shades every book N times a frame, to find how
        /// much load a frame holds, or no books at 0, as a control.
        static let stress = max(0, integer("--wall-metal-stress=") ?? 1)
        /// `--wall-metal-continuous` keeps drawing a resting wall, so its frame pacing can be
        /// measured.
        static let drawsAtRest = ProcessInfo.processInfo.arguments.contains(
            "--wall-metal-continuous")
        /// `--wall-metal-trace` logs each late frame with what preceded it and times the main
        /// thread, which adds a timer there.
        static let traces = ProcessInfo.processInfo.arguments.contains("--wall-metal-trace")
        /// The renderer's log in the app's caches, replaced at launch, so a run can be read
        /// from the Apple TV afterward without a console attached.
        static let logURL = URL.cachesDirectory.appending(path: "BookMetalWall.log")
    #else
        static let stress = 1
        static let drawsAtRest = false
    #endif

    private static func integer(_ prefix: String) -> Int? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) }
    }
}

/// The GPU that draws Book Wall. Preparation uploads a page's meshes and textures through it,
/// off the main actor, and the renderer draws with the same device.
final class BookMetalDevice: @unchecked Sendable {
    /// `nil` when Metal can't supply a device or a command queue.
    static let shared = BookMetalDevice()

    let device: any MTLDevice
    /// Generates the mip levels of uploaded textures, apart from the renderer's queue, so an
    /// upload never takes a place among its frames.
    private let uploads: any MTLCommandQueue

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let uploads = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.uploads = uploads
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

    /// Uploads `image` as Display P3 with the sRGB transfer curve. With `mipmapped`, this
    /// returns once the GPU has made the mip levels, because the renderer's queue doesn't order
    /// its frames after another queue's work.
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
        if mipmapped, let buffer = uploads.makeCommandBuffer(),
            let blit = buffer.makeBlitCommandEncoder()
        {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }
}

/// An uploaded texture, which preparation makes off the main actor and the renderer samples.
struct BookMetalTexture: @unchecked Sendable {
    let texture: any MTLTexture

    /// Uploads `image`, or returns `nil` when Metal can't make its texture.
    init?(_ image: CGImage, mipmapped: Bool) {
        guard let texture = BookMetalDevice.shared?.makeTexture(image, mipmapped: mipmapped)
        else { return nil }
        self.texture = texture
    }

    /// Uploads a spine's mip chain, or returns `nil` when Metal can't make its texture.
    init?(_ mips: BookWallSpineTexture.Mips) {
        guard let texture = BookMetalDevice.shared?.makeTexture(mips) else { return nil }
        self.texture = texture
    }
}

/// Triangles for one draw call. Each vertex is nine floats: position, normal, texture
/// coordinate, and the surface it belongs to, which the fragment shader colors by.
struct BookMetalMesh: Sendable {
    /// Matches the `part` values in BookMetalWall.metal.
    enum Part: Float {
        case cloth, spine, cover, pageEdge, accent, lettering
    }

    static let floatsPerVertex = 9
    var vertices: [Float] = []
    var indices: [UInt32] = []

    init() {}

    /// A hardcover as one mesh, built from `BookWallBookParts` and `BookWallHardcoverMesh`.
    /// Each vertex names the surface it belongs to, so a book draws in one call. The front
    /// board is the same mesh with or without cover art, so a cover that arrives late needs no
    /// new mesh.
    init(book slot: BookWallLayout.Slot) {
        let parts = BookWallBookParts(slot)
        let (size, pageSize) = (parts.size, parts.pageSize)
        // Both cover faces flow through the same full-height spine contour. The open fore edge
        // still exposes the paper block inside the continuous casing.
        append(
            BookWallHardcoverMesh.casingData(
                size: size,
                boardThickness: parts.boardThickness + BookWallLayout.coverWrapThickness,
                foreedgeCornerRadius: parts.foreedgeCornerRadius,
                spineCornerRadius: parts.spineCornerRadius,
                spineWallDepth: (size.z - pageSize.z) / 2,
                bevelWidth: parts.boardBevelWidth, bevelDepth: parts.boardBevelDepth),
            as: .cloth)
        for face in parts.pageEdgeFaces {
            appendPlane(
                width: face.width, height: parts.pageEdgeHeight, as: .pageEdge,
                transform: Transform(
                    rotation: simd_quatf(angle: face.angle, axis: [0, 1, 0]),
                    translation: face.position))
        }
        append(
            BookWallHardcoverMesh.headbandData(
                length: pageSize.x, thickness: parts.pageEdgeHeight, depth: pageSize.z,
                width: BookWallBookParts.headbandWidth, raise: BookWallBookParts.headbandRaise,
                stripe: BookWallBookParts.headbandStripe),
            as: .accent, alternate: .lettering)
        // The spine plane covers the flat spine wall, so the cloth's shading and the cover's
        // fold reach the boards' rounded edges.
        appendPlane(
            width: slot.spineWallWidth, height: slot.spineWallHeight, as: .spine,
            transform: Transform(
                translation: [0, 0, slot.coverWidth / 2 + BookWallBookParts.spineFaceOffset]))
        // The spine faces +Z, so the cover's top edge points toward -X on the upper face.
        append(
            BookWallHardcoverMesh.coverSurfaceData(
                width: slot.coverWidth, height: slot.bookHeight,
                foreedgeCornerRadius: parts.foreedgeCornerRadius,
                spineCornerRadius: parts.spineCornerRadius,
                bevelWidth: parts.boardBevelWidth, bevelDepth: parts.boardBevelDepth),
            as: .cover,
            transform: Transform(
                rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
                    * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]),
                translation: [
                    0, slot.spineThickness / 2 + BookWallBookParts.coverSurfaceOffset, 0,
                ]))
    }

    /// Adds `mesh`'s triangles after this mesh's.
    mutating func append(_ mesh: BookMetalMesh) {
        let base = UInt32(vertices.count / Self.floatsPerVertex)
        vertices += mesh.vertices
        indices += mesh.indices.map { base + $0 }
    }

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
    var detailLightPosition: SIMD4<Float>
    var detailLightColor: SIMD4<Float>
}

/// Per-book shader constants. Matches `Book` in BookMetalWall.metal.
private struct BookMetalBook {
    var model = matrix_identity_float4x4
    var cloth = SIMD4<Float>.zero
    var paper = SIMD4<Float>.zero
    var accent = SIMD4<Float>.zero
    var lettering = SIMD4<Float>.zero
    /// The front board: x and y are the joint's middle and half width across the artwork, and
    /// z is 1 when the board shows cover art and 0 when it is plain cloth.
    var cover = SIMD4<Float>.zero
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

/// A wall page as the renderer draws it: every book's mesh in one pair of buffers, with its
/// uploaded textures and shader constants. Preparation builds a page's books and its
/// `Contents` off the main actor, so showing a wall builds and uploads nothing.
@MainActor
final class BookMetalPage {
    /// One book's uploaded artwork: its spine and cover textures and its colors.
    struct Artwork: @unchecked Sendable {
        fileprivate let spine: any MTLTexture
        fileprivate let cover: (any MTLTexture)?
        fileprivate let uniforms: BookMetalBook

        /// Uploads `spine` and `cover`, drawn for `slot`'s book in `style`. Returns `nil` when
        /// Metal can't make a texture.
        init?(
            slot: BookWallLayout.Slot, style: BookWallLocalSpine.Style,
            spine: BookWallSpineTexture.Mips, cover: CGImage?
        ) {
            guard let shared = BookMetalDevice.shared, let spine = shared.makeTexture(spine)
            else { return nil }
            var coverTexture: (any MTLTexture)?
            if let cover {
                guard let texture = shared.makeTexture(cover, mipmapped: true) else { return nil }
                coverTexture = texture
            }
            var uniforms = BookMetalBook()
            uniforms.cloth = style.background.linearP3
            uniforms.paper = BookWallPageEdges.tint(of: slot.book, accent: style.accent).linearP3
            uniforms.accent = style.accent.linearP3
            uniforms.lettering = style.foreground.linearP3
            // Where the joint's shading falls across the front artwork, as shares of its width
            // from the spine edge: its middle and its half width.
            uniforms.cover = [
                BookWallBookParts.hingeInset / slot.coverWidth,
                BookWallBookParts.hingeWidth / 2 / slot.coverWidth, coverTexture == nil ? 0 : 1, 0,
            ]
            self.spine = spine
            self.cover = coverTexture
            self.uniforms = uniforms
        }
    }

    /// One book, ready to draw: its mesh, its artwork, and where it rests.
    struct Book: Sendable {
        fileprivate let id: Int
        fileprivate let mesh: BookMetalMesh
        fileprivate let artwork: Artwork
        fileprivate let rest: Transform
        /// Half the book's box, for the shadow it casts on the wall when open.
        fileprivate let halfSize: SIMD3<Float>
        fileprivate let column: Int

        init(slot: BookWallLayout.Slot, artwork: Artwork, in layout: BookWallLayout) {
            id = slot.book.id
            mesh = BookMetalMesh(book: slot)
            self.artwork = artwork
            rest = BookWallScene.restingTransform(for: slot, in: layout)
            halfSize = SIMD3(slot.bookHeight, slot.collisionThickness, slot.coverWidth) / 2
            column = slot.column
        }
    }

    /// A page's GPU buffers and what to draw from them.
    struct Contents: @unchecked Sendable {
        fileprivate let id = UUID()
        fileprivate let vertices: any MTLBuffer
        fileprivate let indices: any MTLBuffer
        /// One buffer per frame in flight, each holding every item's constants.
        // Three, since the display link keeps at most two frames in flight at its frame
        // latency of 2.
        fileprivate let uniforms: [any MTLBuffer]
        /// The shelf, then each book in the order books drop.
        fileprivate var items: [BookMetalRenderer.Item]
        /// Each book's part in the fall, in the order of `items` after the shelf.
        fileprivate let falling: [BookWallFall.Book]
        fileprivate let pageEdge: (any MTLTexture)?

        /// Joins `books`, in the order `layout` drops them, and the shelf they rest on into one
        /// pair of buffers. Returns `nil` when Metal can't make a buffer.
        init?(books: [Book], layout: BookWallLayout) {
            guard let shared = BookMetalDevice.shared else { return nil }
            let shelfSize = BookWallScene.shelfSize(
                for: layout, thickness: BookWallScene.shelfThickness(for: layout))
            var mesh = BookMetalMesh()
            mesh.appendBox(size: shelfSize, as: .cloth)
            var shelf = BookMetalBook()
            shelf.cloth = BookWallShelfLabel.wood.linearP3
            var items = [
                BookMetalRenderer.Item(
                    id: nil, indexStart: 0, indexCount: mesh.indices.count, spine: nil, cover: nil,
                    uniforms: shelf,
                    rest: Transform(
                        translation: BookWallScene.shelfCenter(for: layout, size: shelfSize)),
                    halfSize: .zero)
            ]
            let spacing = BookWallScene.dropSpacing(for: layout)
            var falling: [BookWallFall.Book] = []
            for (order, book) in books.enumerated() {
                items.append(
                    BookMetalRenderer.Item(
                        id: book.id, indexStart: mesh.indices.count,
                        indexCount: book.mesh.indices.count, spine: book.artwork.spine,
                        cover: book.artwork.cover, uniforms: book.artwork.uniforms,
                        rest: book.rest, halfSize: book.halfSize))
                mesh.append(book.mesh)
                falling.append(
                    BookWallFall.Book(
                        rest: book.rest.translation.y, column: book.column,
                        delay: Double(order) * spacing))
            }
            let device = shared.device
            guard
                let vertices = device.makeBuffer(
                    bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<Float>.stride),
                let indices = device.makeBuffer(
                    bytes: mesh.indices, length: mesh.indices.count * MemoryLayout<UInt32>.stride)
            else { return nil }
            var uniforms: [any MTLBuffer] = []
            for _ in 0..<3 {
                guard
                    let buffer = device.makeBuffer(
                        length: items.count * MemoryLayout<BookMetalBook>.stride,
                        options: .storageModeShared)
                else { return nil }
                uniforms.append(buffer)
            }
            self.vertices = vertices
            self.indices = indices
            self.uniforms = uniforms
            self.items = items
            self.falling = falling
            // One shared page-edge texture serves every book; without it pages stay plain.
            pageEdge = BookWallPageTexture.make()
                .flatMap {
                    shared.makeTexture($0, mipmapped: true)
                }
        }
    }

    fileprivate private(set) var contents: Contents
    /// The renderer that last showed this page, which draws a replaced cover at once.
    fileprivate weak var renderer: BookMetalRenderer?

    init(_ contents: Contents) {
        self.contents = contents
    }

    /// Replaces `book`'s artwork, for a cover that arrived after the page was prepared. A
    /// renderer that is showing the page swaps it in where the book is, without moving
    /// anything.
    func replaceArtwork(of book: Int, with artwork: Artwork) {
        guard let index = contents.items.firstIndex(where: { $0.id == book }) else { return }
        contents.items[index].show(artwork)
        renderer?.replaceArtwork(of: book, onPage: contents.id, with: artwork)
    }
}

/// Why the wall's renderer stopped, shared with the Retry button on Book Wall's page. The surface
/// is noninteractive and hidden from accessibility, so the page shows the error.
@MainActor @Observable
final class BookWallRendererStatus {
    /// The renderer's error, or nil while it runs.
    var failure: String?
    /// Replaces the renderer that reports here, which `retry()` calls.
    @ObservationIgnored var reconnect: (@MainActor () -> Void)?

    /// Connects a new renderer on the current surface before returning, so the press that
    /// calls this knows whether the wall runs again. Returns `true` when it does. A renderer
    /// that fails again sets `failure` and waits for the next Retry.
    func retry() -> Bool {
        reconnect?()
        return failure == nil
    }

    /// Shown when Metal can't supply what a renderer needs to start.
    nonisolated static let unavailableMetal =
        "Metal could not create a device, command queue, or render pipeline."

    #if DEBUG && targetEnvironment(simulator)
        /// Scenario hook: `--test-fail-book-wall-renderer` fails the first connection and
        /// `--test-fail-book-wall-renderer=N` the first N, so UI tests can reach Retry.
        /// Returns whether this connection is one that fails.
        static func takeScenarioFailure() -> Bool {
            guard scenarioFailures > 0 else { return false }
            scenarioFailures -= 1
            return true
        }

        private static var scenarioFailures: Int = {
            let arguments = ProcessInfo.processInfo.arguments
            let prefix = "--test-fail-book-wall-renderer="
            if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
                return Int(argument.dropFirst(prefix.count)) ?? 0
            }
            return arguments.contains("--test-fail-book-wall-renderer") ? 1 : 0
        }()
    #endif
}

/// Presents the wall through the Metal renderer.
struct BookMetalWallView: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let scene: BookWallScene
    let status: BookWallRendererStatus
    /// Whether an opaque view covers the surface. A covered surface stops drawing.
    var isCovered = false

    func makeCoordinator() -> BookMetalWallHost { BookMetalWallHost() }

    func makeUIView(context: Context) -> BookMetalWallSurface {
        let surface = BookMetalWallSurface(frame: .zero)
        context.coordinator.connect(scene: scene, surface: surface, status: status)
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

    /// Dark wood that fills the surface until the wall image arrives.
    static let clearColor = UIColor(red: 0.16, green: 0.11, blue: 0.08, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.clearColor
        isOpaque = true
        isUserInteractionEnabled = false
        metalLayer.isOpaque = true
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.drawableSize = BookMetalWall.renderSize
        // Textures and colors are Display P3 with the sRGB transfer curve. Tagging the layer
        // as sRGB instead desaturates the wall through the compositor's color conversion.
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

/// Owns the renderer's lifecycle on its surface, and hands it what `BookWallScene` shows.
@MainActor
final class BookMetalWallHost {
    private weak var scene: BookWallScene?
    private weak var surface: BookMetalWallSurface?
    private weak var status: BookWallRendererStatus?
    private var renderer: BookMetalRenderer?
    private var shown: BookWallPreparedWall?
    private var isAttached = false
    private var isSceneActive = false
    /// What to run on the main actor when each flight ends, by the renderer's token.
    private var flightEnds: [UInt64: @MainActor () -> Void] = [:]
    private var lastFlight: UInt64 = 0

    func connect(
        scene: BookWallScene, surface: BookMetalWallSurface, status: BookWallRendererStatus
    ) {
        self.scene = scene
        self.surface = surface
        self.status = status
        surface.host = self
        isAttached = surface.window != nil
        status.reconnect = { [weak self] in self?.start() }
        start()
    }

    /// Starts a renderer on the surface and shows the scene's wall, or reports why it can't.
    /// Retry calls this again.
    private func start() {
        guard let scene, let surface, let status else { return }
        renderer?.stop()
        renderer = nil
        #if DEBUG && targetEnvironment(simulator)
            let fails = BookWallRendererStatus.takeScenarioFailure()
        #else
            let fails = false
        #endif
        if !fails { renderer = makeRenderer(on: surface) }
        guard let renderer else {
            status.failure = BookWallRendererStatus.unavailableMetal
            return
        }
        if status.failure != nil { status.failure = nil }
        renderer.setActive(isAttached && isSceneActive)
        viewportChanged(size: surface.bounds.size)
        scene.attach(self)
    }

    private func makeRenderer(on surface: BookMetalWallSurface) -> BookMetalRenderer? {
        BookMetalRenderer(
            layer: surface.metalLayer,
            onLanded: { [weak self] page in
                Task { @MainActor [weak self] in
                    guard let self, let shown, shown.resources?.contents.id == page else { return }
                    self.scene?.fallEnded(of: shown)
                }
            },
            onFlightEnded: { [weak self] token in
                Task { @MainActor [weak self] in self?.flightEnds.removeValue(forKey: token)?() }
            })
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

    func setBackdrop(resting: CGImage, detail: CGImage) {
        guard let renderer, let shared = BookMetalDevice.shared,
            let texture = shared.makeTexture(resting, mipmapped: false)
        else { return }
        renderer.setBackdrop(texture, detail: shared.makeTexture(detail, mipmapped: false))
    }

    /// Flies `book` along `flight`, with the detail key light at `light`. `completion` runs when
    /// the flight ends, unless `endDetail()` or another flight replaces it first. The book holds
    /// the last frame until then.
    func fly(
        _ book: Int, _ flight: BookWallFlight, light: SIMD3<Float>,
        completion: (@MainActor () -> Void)?
    ) {
        flightEnds.removeAll()
        lastFlight += 1
        flightEnds[lastFlight] = completion
        renderer?
            .fly(
                BookMetalRenderer.Detail(
                    book: book, flight: flight, light: light, token: lastFlight))
    }

    /// Drifts the open book about the pose its flight ended at, on the media clock from
    /// `started`.
    func drift(_ drift: BookWallDrift, since started: CFTimeInterval) {
        renderer?.drift(drift, since: started)
    }

    /// Returns the wall to rest: no open book, the resting light, and the wall's camera.
    func endDetail() {
        flightEnds.removeAll()
        renderer?.endDetail()
    }

    func focus(_ id: Int?, decor: BookWallDecor) {
        renderer?.focus(id, decor: decor)
    }

    /// Clears the wall, leaving the wall image, for a wall with no books.
    func clear() {
        shown = nil
        flightEnds.removeAll()
        renderer?.clear()
    }

    /// Puts every book that is still falling in its place.
    func seat() {
        renderer?.seat()
    }

    /// Shows `wall`'s prepared page, falling from the drop height or at rest.
    func show(_ wall: BookWallPreparedWall, stage: BookWallStage, falls: Bool) {
        guard let renderer, let page = wall.resources else { return }
        shown = wall
        page.renderer = renderer
        renderer.show(
            page.contents, labels: wall.labels.mapValues(\.texture.texture),
            hint: wall.hint?.texture.texture, stage: stage, falls: falls)
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
        var spine: (any MTLTexture)?
        var cover: (any MTLTexture)?
        var uniforms: BookMetalBook
        let rest: Transform
        /// Half the book's box, for the shadow it casts on the wall when open.
        let halfSize: SIMD3<Float>

        mutating func show(_ artwork: BookMetalPage.Artwork) {
            spine = artwork.spine
            cover = artwork.cover
            uniforms = artwork.uniforms
        }
    }

    /// The page on screen: its prepared contents, its labels, and how the scene frames it.
    private struct Page {
        var contents: BookMetalPage.Contents
        /// Each book's shelf label, and the hint shown without focus.
        let labels: [Int: any MTLTexture]
        let hint: (any MTLTexture)?
        let stage: BookWallStage
    }

    /// A book's flight to or from its details, and its drift once there.
    fileprivate struct Detail {
        let book: Int
        let flight: BookWallFlight
        let light: SIMD3<Float>
        let token: UInt64
        /// When the flight started; `nil` until its first frame.
        var start: CFTimeInterval?
        var hasEnded = false
        var drift: BookWallDrift?
        var driftStart: CFTimeInterval = 0
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
        var detail: Detail?
        var detailBackdrop: (any MTLTexture)?
        var decor = BookWallDecor()
        /// When the decor's ribbon and shadow started to arrive; `nil` until the next frame.
        var decorStart: CFTimeInterval?
        #if BOOKWORMS_DIAGNOSTICS
            var maxGPUSeconds: CFTimeInterval = 0
            var totalGPUSeconds: CFTimeInterval = 0
            var gpuFrames = 0
            /// The last finished frame's GPU time, from its first GPU work to its last, which
            /// includes time the system compositor's work ran in between.
            var lastGPUSeconds: CFTimeInterval = 0
            /// The longest the main thread went without running its heartbeat.
            var mainMaxGap: CFTimeInterval = 0
        #endif
    }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let bookPipeline: any MTLRenderPipelineState
    private let backdropPipeline: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState
    private let backdropDepthState: any MTLDepthStencilState
    private let clearingDepthState: any MTLDepthStencilState
    private let decalPipeline: any MTLRenderPipelineState
    private let decalDepthState: any MTLDepthStencilState
    private var white: (any MTLTexture)?
    private var ribbonTail: (any MTLTexture)?
    private var softShadow: (any MTLTexture)?
    private var contactShadow: (any MTLTexture)?
    private let link: CAMetalDisplayLink
    /// Reports the page whose books have all landed.
    private let onLanded: @Sendable (UUID) -> Void
    private let onFlightEnded: @Sendable (UInt64) -> Void
    private let lock = NSLock()
    private var state = State()
    private var thread: Thread?

    // Render-thread state.
    private var multisampleColor: (any MTLTexture)?
    private var multisampleDepth: (any MTLTexture)?
    private var frameIndex = 0
    #if BOOKWORMS_DIAGNOSTICS
        private var lastTarget: CFTimeInterval?
        private var lastLead: CFTimeInterval = 0
        private var lastEntry: CFTimeInterval = 0
        private var heartbeat: (any DispatchSourceTimer)?
        private var windowStart: CFTimeInterval?
        private var windowFrames = 0
        private var windowLate = 0
        private var windowMaxGap: CFTimeInterval = 0
        private var windowMaxEncode: CFTimeInterval = 0
    #endif

    private static let sampleCount = 4
    private static let bookStride = MemoryLayout<BookMetalBook>.stride
    /// Light levels in linear light, fitted by eye to the RealityKit wall: a spine facing the
    /// camera shows at about nine tenths of its texture's color.
    private static let shelfLightColor = SIMD4<Float>(0.50, 0.44, 0.36, 1)
    private static let poolLightColor = SIMD4<Float>(3.2, 2.5, 1.6, 1)
    private static let topLightColor = SIMD4<Float>(0.2, 0.2, 0.2, 1)
    private static let ambientTop = SIMD4<Float>(0.34, 0.33, 0.32, 1)
    private static let ambientBottom = SIMD4<Float>(0.18, 0.17, 0.16, 1)
    /// The ribbon's red, a little under full brightness, as a lit surface in this room shows.
    private static let ribbonColor: SIMD4<Float> = {
        var color = StyleColor(red: 0.84, green: 0.1, blue: 0.12).linearP3 * 0.8
        color.w = 1
        return color
    }()
    /// The detail key light's level at its distance from the detail pose.
    private static let detailLightColor = SIMD4<Float>(0.62, 0.57, 0.50, 1)

    @MainActor
    init?(
        layer: CAMetalLayer, onLanded: @escaping @Sendable (UUID) -> Void,
        onFlightEnded: @escaping @Sendable (UInt64) -> Void
    ) {
        guard let shared = BookMetalDevice.shared, let queue = shared.device.makeCommandQueue(),
            let library = shared.device.makeDefaultLibrary()
        else { return nil }
        let device = shared.device
        layer.device = device
        self.device = device
        self.queue = queue
        self.onLanded = onLanded
        self.onFlightEnded = onFlightEnded

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
        // The same pass fades the wall out by drawing the backdrop over it.
        backdrop.colorAttachments[0].isBlendingEnabled = true
        backdrop.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        backdrop.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        let depth = MTLDepthStencilDescriptor()
        // Under the stress multiplier, each repeated book passes the depth test again, so its
        // pixels are shaded again.
        depth.depthCompareFunction = BookMetalWall.stress > 1 ? .lessEqual : .less
        depth.isDepthWriteEnabled = true
        let noDepth = MTLDepthStencilDescriptor()
        noDepth.depthCompareFunction = .always
        noDepth.isDepthWriteEnabled = false
        // Flat extras, such as the label, the ribbon, and shadows: blended over what is behind
        // them, hidden by what is in front, and never written to depth.
        let decals = MTLRenderPipelineDescriptor()
        decals.label = "Book Wall decals"
        decals.vertexFunction = library.makeFunction(name: "bookDecalVertex")
        decals.fragmentFunction = library.makeFunction(name: "bookDecalFragment")
        decals.colorAttachments[0].pixelFormat = layer.pixelFormat
        decals.colorAttachments[0].isBlendingEnabled = true
        decals.colorAttachments[0].sourceRGBBlendFactor = .one
        decals.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        decals.depthAttachmentPixelFormat = .depth32Float
        decals.rasterSampleCount = Self.sampleCount
        let decalDepth = MTLDepthStencilDescriptor()
        decalDepth.depthCompareFunction = .lessEqual
        decalDepth.isDepthWriteEnabled = false
        // The wall image drawn over a fading wall also resets depth to the far plane, so the
        // open book draws in front of the wall it has left.
        let clearing = MTLDepthStencilDescriptor()
        clearing.depthCompareFunction = .always
        clearing.isDepthWriteEnabled = true
        guard let bookPipeline = try? device.makeRenderPipelineState(descriptor: books),
            let backdropPipeline = try? device.makeRenderPipelineState(descriptor: backdrop),
            let depthState = device.makeDepthStencilState(descriptor: depth),
            let backdropDepthState = device.makeDepthStencilState(descriptor: noDepth),
            let clearingDepthState = device.makeDepthStencilState(descriptor: clearing),
            let decalPipeline = try? device.makeRenderPipelineState(descriptor: decals),
            let decalDepthState = device.makeDepthStencilState(descriptor: decalDepth)
        else { return nil }
        self.decalPipeline = decalPipeline
        self.decalDepthState = decalDepthState
        self.clearingDepthState = clearingDepthState
        self.bookPipeline = bookPipeline
        self.backdropPipeline = backdropPipeline
        self.depthState = depthState
        self.backdropDepthState = backdropDepthState

        link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        // Two refreshes between a frame's callback and its presentation, which the three
        // uniform buffers below rely on.
        link.preferredFrameLatency = 2
        link.isPaused = true
        super.init()
        link.delegate = self
        let thread = Thread(target: self, selector: #selector(runThread), object: nil)
        white =
            Self.image(width: 1, height: 1) { context in
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            .flatMap { shared.makeTexture($0, mipmapped: false) }
        // The ribbon's last segment, with a swallowtail notch as deep as on the RealityKit wall.
        ribbonTail =
            Self.image(width: 64, height: 64) { context in
                let notch =
                    64 * CGFloat(BookWallRibbon.width * 0.6 / (BookWallRibbon.segmentLength * 1.08))
                context.move(to: CGPoint(x: 0, y: 64))
                context.addLine(to: CGPoint(x: 64, y: 64))
                context.addLine(to: CGPoint(x: 64, y: 0))
                context.addLine(to: CGPoint(x: 32, y: notch))
                context.addLine(to: CGPoint(x: 0, y: 0))
                context.fillPath()
            }
            .flatMap { shared.makeTexture($0, mipmapped: true) }
        softShadow = BookWallBackdropBake.makeShadow(fadesDown: false)
            .flatMap { shared.makeTexture($0, mipmapped: false) }
        contactShadow = BookWallBackdropBake.makeShadow(fadesDown: true)
            .flatMap { shared.makeTexture($0, mipmapped: false) }
        #if BOOKWORMS_DIAGNOSTICS
            if BookMetalWall.traces { startHeartbeat() }
        #endif
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
        #if BOOKWORMS_DIAGNOSTICS
            heartbeat?.cancel()
            heartbeat = nil
        #endif
    }

    func setActive(_ active: Bool) {
        lock.withLock { state.isActive = active }
        wake()
    }

    func setBackdrop(_ texture: any MTLTexture, detail: (any MTLTexture)?) {
        lock.withLock {
            state.backdrop = texture
            state.detailBackdrop = detail
        }
        wake()
    }

    fileprivate func fly(_ detail: Detail) {
        lock.withLock { state.detail = detail }
        wake()
    }

    func drift(_ drift: BookWallDrift, since started: CFTimeInterval) {
        lock.withLock {
            state.detail?.drift = drift
            state.detail?.driftStart = started
        }
        wake()
    }

    func endDetail() {
        lock.withLock { state.detail = nil }
        wake()
    }

    fileprivate func replaceArtwork(
        of book: Int, onPage page: UUID, with artwork: BookMetalPage.Artwork
    ) {
        lock.withLock {
            guard state.page?.contents.id == page,
                let index = state.page?.contents.items.firstIndex(where: { $0.id == book })
            else { return }
            state.page?.contents.items[index].show(artwork)
        }
        wake()
    }

    /// Ends the fall with every book in its place.
    func seat() {
        lock.withLock { state.falls = false }
        wake()
    }

    func clear() {
        lock.withLock {
            state.page = nil
            state.falls = false
            state.focused = nil
            state.pulls.removeAll()
            state.decor = BookWallDecor()
            state.detail = nil
        }
        wake()
    }

    func focus(_ id: Int?, decor: BookWallDecor) {
        lock.withLock {
            state.decor = decor
            state.decorStart = nil
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
        _ contents: BookMetalPage.Contents, labels: [Int: any MTLTexture],
        hint: (any MTLTexture)?, stage: BookWallStage, falls: Bool
    ) {
        lock.withLock {
            state.page = Page(contents: contents, labels: labels, hint: hint, stage: stage)
            state.falls = falls
            state.fallStart = nil
            state.focused = nil
            state.pulls.removeAll()
            state.decor = BookWallDecor()
            state.detail = nil
        }
        wake()
    }

    /// A small white drawing on a clear ground, for the ribbon's textures.
    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        draw(context)
        return context.makeImage()
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
        guard link.isPaused == active else { return }
        #if BOOKWORMS_DIAGNOSTICS
            lastTarget = nil
        #endif
        link.isPaused = !active
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update)
    {
        #if BOOKWORMS_DIAGNOSTICS
            let encodeStart = CACurrentMediaTime()
        #endif
        let time = update.targetPresentationTimestamp
        let snapshot = lock.withLock {
            if state.falls, state.fallStart == nil { state.fallStart = time }
            for id in state.pulls.keys where state.pulls[id]?.start == nil {
                state.pulls[id]?.start = time
            }
            if state.detail != nil, state.detail?.start == nil { state.detail?.start = time }
            if state.decorStart == nil { state.decorStart = time }
            return state
        }
        guard let page = snapshot.page else {
            // A wall with no books shows the wall image alone.
            drawEmptyWall(into: update.drawable, backdrop: snapshot.backdrop)
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
        let items = page.contents.items
        var heights = items.map(\.rest.translation.y)
        var landed = true
        if snapshot.falls, let fallStart = snapshot.fallStart {
            let fall = stage.fall.heights(of: page.contents.falling, after: time - fallStart)
            // The shelf comes first and doesn't fall.
            heights.replaceSubrange(1..., with: fall.heights)
            landed = fall.landed
        }
        var animating = snapshot.falls && !landed
        // The open book's pose, the camera's depth, and the detail light level.
        var flown: (book: Int, pose: Transform)?
        var cameraDepth = stage.cameraDepth
        var level: Float = 0
        var lightPosition = SIMD3<Float>.zero
        if let detail = snapshot.detail, let start = detail.start,
            let sample = detail.flight.sample(at: time - start)
        {
            var pose = sample.pose
            cameraDepth = sample.cameraDepth
            if !sample.isOver {
                animating = true
            } else if !detail.hasEnded {
                lock.withLock {
                    if state.detail?.token == detail.token { state.detail?.hasEnded = true }
                }
                onFlightEnded(detail.token)
            }
            if let drift = detail.drift {
                pose = drift.posed(pose, at: Float(time - detail.driftStart))
                animating = true
            }
            level = sample.level
            lightPosition = detail.light
            flown = (detail.book, pose)
        }
        // The rest of the wall fades out over the later part of the opening.
        let wallOpacity =
            1
            - BookWallEasing.smootherstep((level - stage.wallFadeStart) / (1 - stage.wallFadeStart))
        var flownIndex: Int?

        // The wall's flat extras, which arrive with the focused book's pull-out.
        struct Decal {
            var model: simd_float4x4
            var tint: SIMD4<Float>
            var texture: (any MTLTexture)?
        }
        var wallDecals: [Decal] = []
        let decor = snapshot.decor
        let arrival =
            decor.elapsed + Float(time - (snapshot.decorStart ?? time)) - stage.pullOutDuration
        if let model = decor.label,
            let label = decor.labelBook.flatMap({ page.labels[$0] }) ?? page.hint
        {
            wallDecals.append(Decal(model: model, tint: [1, 1, 1, 1], texture: label))
        }
        if let model = decor.contactShadow {
            let opacity =
                decor.contactShadowOpacity * min(1, max(0, 1 + arrival / stage.pullOutDuration))
            wallDecals.append(
                Decal(model: model, tint: [1, 1, 1, opacity], texture: contactShadow))
        }
        if let anchor = decor.ribbon {
            let length = BookWallRibbon.segmentLength * 1.08
            let shape = Transform(
                scale: [BookWallRibbon.width, length, 1], translation: [0, -length / 2, 0]
            )
            .matrix
            let segments = BookWallRibbon.segments(at: arrival)
            for (index, segment) in segments.enumerated() {
                guard let segment else { continue }
                let pose = Transform(
                    scale: [1, segment.visible, 1], rotation: segment.rotation,
                    translation: segment.position
                )
                .matrix
                wallDecals.append(
                    Decal(
                        model: anchor.matrix * pose * shape, tint: Self.ribbonColor,
                        texture: index == segments.count - 1 ? ribbonTail : white))
            }
            if arrival < BookWallRibbon.settleTime { animating = true }
        }
        // The open book's soft shadow on the wall: its outline as the camera sees it, cast
        // onto the wall image and shifted away from the key light.
        var shadow: Decal?
        if level > 0, let flown, let item = items.first(where: { $0.id == flown.book }) {
            let wall = -(stage.backdropDistance + cameraDepth - stage.cameraDepth) + 0.1
            var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            let matrix = flown.pose.matrix
            for corner in 0..<8 {
                let local = SIMD3<Float>(
                    corner & 1 == 0 ? -item.halfSize.x : item.halfSize.x,
                    corner & 2 == 0 ? -item.halfSize.y : item.halfSize.y,
                    corner & 4 == 0 ? -item.halfSize.z : item.halfSize.z)
                let world = matrix * SIMD4(local, 1)
                // The camera looks down -Z, so scaling by depth casts a point onto the wall
                // along its line of sight.
                let onWall = SIMD2(world.x, world.y) * (wall / min(world.z - cameraDepth, -0.01))
                low = simd_min(low, onWall)
                high = simd_max(high, onWall)
            }
            let size = (high - low) * (1 + 2 * BookWallBackdropBake.shadowSoftness)
            let center = (low + high) / 2 + (high - low) * stage.detailShadowOffset
            shadow = Decal(
                model: Transform(
                    scale: [size.x, size.y, 1],
                    translation: [center.x, center.y, wall + cameraDepth]
                )
                .matrix,
                tint: [1, 1, 1, stage.detailShadowOpacity * level], texture: softShadow)
        }
        let ring = page.contents.uniforms[frameIndex % page.contents.uniforms.count]
        frameIndex += 1
        let constants = ring.contents().bindMemory(to: BookMetalBook.self, capacity: items.count)
        for (index, item) in items.enumerated() {
            var pose = item.rest
            pose.translation.y = heights[index]
            if let flown, item.id == flown.book {
                pose = flown.pose
                flownIndex = index
            } else if let id = item.id, let pull = snapshot.pulls[id], let start = pull.start {
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
                * Transform(translation: [0, 0, -cameraDepth]).matrix,
            cameraPosition: [0, 0, cameraDepth, 1],
            // The stage passes from the shelf and pool lights to the detail key light, the
            // top light doubles, and the room dims, as on the RealityKit wall.
            shelfLightPosition: SIMD4(stage.shelfLight, 1),
            shelfLightColor: Self.shelfLightColor * (1 - level),
            poolLightPosition: SIMD4(stage.poolLight, 1),
            poolLightColor: Self.poolLightColor
                * (1 - BookWallEasing.smootherstep(level / stage.wallFadeStart)),
            topLightDirection: SIMD4(stage.topLightDirection, 0),
            topLightColor: Self.topLightColor * (1 + level),
            ambientTop: Self.ambientTop * pow(2, stage.detailAmbientExponent * level),
            ambientBottom: Self.ambientBottom * pow(2, stage.detailAmbientExponent * level),
            detailLightPosition: SIMD4(lightPosition, 1),
            detailLightColor: Self.detailLightColor * level)

        let pass = Self.pass(color: targets.color, depth: targets.depth, into: drawable)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        /// Draws the wall image, crossfaded toward its detail lighting, at `opacity`.
        func drawBackdrop(opacity: Float, clearsDepth: Bool = false) {
            guard let backdrop = snapshot.backdrop else { return }
            var mix = SIMD4<Float>(level, opacity, 0, 0)
            encoder.setRenderPipelineState(backdropPipeline)
            encoder.setDepthStencilState(clearsDepth ? clearingDepthState : backdropDepthState)
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.setFragmentTexture(snapshot.detailBackdrop ?? backdrop, index: 1)
            encoder.setFragmentBytes(&mix, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        func drawDecals(_ decals: [Decal]) {
            guard !decals.isEmpty else { return }
            encoder.setRenderPipelineState(decalPipeline)
            encoder.setDepthStencilState(decalDepthState)
            encoder.setCullMode(.none)
            for decal in decals {
                var constants = (decal.model, decal.tint)
                let length = MemoryLayout.stride(ofValue: constants)
                encoder.setVertexBytes(&constants, length: length, index: 3)
                encoder.setFragmentBytes(&constants, length: length, index: 3)
                encoder.setFragmentTexture(decal.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        func drawBooks(_ indices: some Sequence<Int>) {
            encoder.setRenderPipelineState(bookPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.back)
            encoder.setFragmentTexture(page.contents.pageEdge, index: 2)
            for index in indices {
                let item = items[index]
                let offset = index * Self.bookStride
                encoder.setVertexBufferOffset(offset, index: 2)
                encoder.setFragmentBufferOffset(offset, index: 2)
                encoder.setFragmentTexture(item.spine, index: 0)
                encoder.setFragmentTexture(item.cover, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: item.indexCount, indexType: .uint32,
                    indexBuffer: page.contents.indices,
                    indexBufferOffset: item.indexStart * MemoryLayout<UInt32>.stride)
            }
        }
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(page.contents.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<BookMetalFrame>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<BookMetalFrame>.stride, index: 1)
        encoder.setVertexBuffer(ring, offset: 0, index: 2)
        encoder.setFragmentBuffer(ring, offset: 0, index: 2)
        drawBackdrop(opacity: 1)
        // While the wall fades, the open book draws after the fade, in front of everything.
        let fades = wallOpacity < 1 && flownIndex != nil
        let wall = items.indices.filter { !(fades && $0 == flownIndex) }
        if wallOpacity > 0 || !fades {
            for _ in 0..<BookMetalWall.stress { drawBooks(wall) }
            drawDecals(wallDecals)
            // Before the wall fades, the open book is still among the stacks, which hide
            // most of its shadow.
            if !fades, let shadow { drawDecals([shadow]) }
        }
        if fades, let flownIndex {
            // Drawing the wall image over the wall at the wall's lost opacity is the wall
            // fading out over that image. The open book has cleared the stacks by now.
            drawBackdrop(opacity: 1 - wallOpacity, clearsDepth: true)
            if let shadow { drawDecals([shadow]) }
            drawBooks(CollectionOfOne(flownIndex))
        }
        encoder.endEncoding()
        buffer.present(drawable)
        #if BOOKWORMS_DIAGNOSTICS
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
        #endif
        buffer.commit()

        if snapshot.falls, landed {
            lock.withLock { if state.page?.contents.id == page.contents.id { state.falls = false } }
            onLanded(page.contents.id)
        }
        #if BOOKWORMS_DIAGNOSTICS
            record(
                target: time, entry: encodeStart, encode: CACurrentMediaTime() - encodeStart,
                books: items.count - 1)
        #endif
        // A still wall keeps its last frame until the main thread changes something.
        if !animating, !BookMetalWall.drawsAtRest {
            #if BOOKWORMS_DIAGNOSTICS
                lastTarget = nil
            #endif
            link.isPaused = true
        }
    }

    private func drawEmptyWall(into drawable: any CAMetalDrawable, backdrop: (any MTLTexture)?) {
        guard
            let targets = multisampleTargets(
                width: drawable.texture.width, height: drawable.texture.height),
            let buffer = queue.makeCommandBuffer()
        else { return }
        let pass = Self.pass(color: targets.color, depth: targets.depth, into: drawable)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let backdrop {
            var mix = SIMD4<Float>(0, 1, 0, 0)
            encoder.setRenderPipelineState(backdropPipeline)
            encoder.setDepthStencilState(backdropDepthState)
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.setFragmentTexture(backdrop, index: 1)
            encoder.setFragmentBytes(&mix, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// A pass that clears, draws multisampled, and resolves into `drawable`.
    private static func pass(
        color: any MTLTexture, depth: any MTLTexture, into drawable: any CAMetalDrawable
    ) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.02, green: 0.01, blue: 0.006, alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        return pass
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

    #if BOOKWORMS_DIAGNOSTICS
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
                                format:
                                    "BookMetalWallLate gapMS=%.1f leadMS=%.1f previousLeadMS=%.1f "
                                    + "callbackGapMS=%.1f lastGPUMS=%.2f mainMaxGapMS=%.1f\n",
                                gap * 1000, lead * 1000, lastLead * 1000,
                                (entry - lastEntry) * 1000,
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
                "BookMetalWallPipeline frames=\(windowFrames) late=\(windowLate) "
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
    #endif

    /// A right-handed perspective projection onto Metal's 0-to-1 depth range.
    private static func projection(fieldOfView degrees: Float, aspect: Float) -> simd_float4x4 {
        // Nothing comes within a unit of the camera, and a near plane this far out leaves the
        // depth buffer enough precision to keep a cover's artwork above its board, half a
        // thousandth of a unit below, after the camera moves back for a flight.
        let (near, far): (Float, Float) = (1, 200)
        let scale = 1 / tan(degrees * .pi / 360)
        return simd_float4x4(
            [scale / aspect, 0, 0, 0], [0, scale, 0, 0], [0, 0, far / (near - far), -1],
            [0, 0, near * far / (near - far), 0])
    }
}
