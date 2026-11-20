import Metal
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

/// One sample of a detail flight: the selected book's pose and the camera's depth. The pose is
/// RealityKit's `Transform`, the one RealityKit type the wall uses, for its plain rotation and
/// translation.
struct BookWallFlightFrame: Sendable {
    var pose: Transform
    var cameraDepth: Float
}

/// An open book's slow drift in its detail pose: a sine on each of its sideways and vertical
/// position and its yaw, eased in from rest.
struct BookWallDrift: Sendable {
    /// Sideways and vertical travel in scene units, and yaw in radians.
    let amplitudes: SIMD3<Float>
    /// Each axis's period in seconds.
    let periods: SIMD3<Float>
    let rampDuration: Float

    /// The offset and its velocity `seconds` after the drift starts. The third component is
    /// world-Y yaw in radians, not a depth displacement.
    func motion(at seconds: Float) -> (offset: SIMD3<Float>, velocity: SIMD3<Float>) {
        let t = min(1, seconds / rampDuration)
        let ramp = BookWallEasing.smootherstep(t)
        let derivative = 30 * t * t * (t - 1) * (t - 1) / rampDuration
        var offset = SIMD3<Float>.zero
        var velocity = SIMD3<Float>.zero
        for axis in 0..<3 {
            let frequency = 2 * Float.pi / periods[axis]
            let wave = sin(frequency * seconds)
            offset[axis] = amplitudes[axis] * wave * ramp
            velocity[axis] =
                amplitudes[axis]
                * (frequency * cos(frequency * seconds) * ramp + wave * derivative)
        }
        return (offset, velocity)
    }

    /// `pose` moved by the drift `seconds` after it starts.
    func posed(_ pose: Transform, at seconds: Float) -> Transform {
        let offset = motion(at: seconds).offset
        var moved = pose
        moved.translation.x += offset.x
        moved.translation.y += offset.y
        moved.rotation = simd_quatf(angle: offset.z, axis: [0, 1, 0]) * pose.rotation
        return moved
    }
}

/// A hardcover's part sizes, which its mesh is built from.
struct BookWallBookParts {
    static let pageCornerRadius: Float = 0.008
    /// The front artwork's height above the front board: the covering, and a gap that keeps the
    /// two surfaces apart in the depth buffer.
    static let coverSurfaceOffset = BookWallLayout.coverWrapThickness + 0.0005
    /// The spine plane's distance in front of the casing's spine wall. It spans the whole
    /// wall, so a larger gap would show as a lip at the boards' edges.
    static let spineFaceOffset: Float = 0.002
    /// The headband's depth from the spine wall, how far it stands beyond the pages, less than
    /// the boards' 0.03-unit overhang, and each stripe's length: about 1.6, 0.8, and 1.4 mm, as
    /// on the iPhone.
    static let headbandWidth: Float = 0.034
    static let headbandRaise: Float = 0.016
    static let headbandStripe: Float = 0.03
    /// The joint's distance from the spine edge and the width of its shading.
    static let hingeInset: Float = 0.085
    static let hingeWidth: Float = 0.06

    /// The whole book: head to tail, thickness with its covering, and spine to fore edge.
    let size: SIMD3<Float>
    let boardThickness: Float
    let foreedgeCornerRadius: Float
    let spineCornerRadius: Float
    let boardBevelWidth: Float
    let boardBevelDepth: Float
    let pageSize: SIMD3<Float>

    init(_ slot: BookWallLayout.Slot) {
        size = [slot.bookHeight, slot.collisionThickness, slot.coverWidth]
        boardThickness = min(0.045, slot.spineThickness * 0.12)
        let shortSide = min(slot.bookHeight, slot.coverWidth)
        foreedgeCornerRadius = shortSide * 0.005
        spineCornerRadius = shortSide * 0.0015
        boardBevelWidth = shortSide * 0.005
        boardBevelDepth = min(boardThickness * 0.18, boardBevelWidth)
        pageSize = [
            slot.bookHeight - 0.06, slot.spineThickness - boardThickness * 2 - 0.015,
            slot.coverWidth - 0.07,
        ]
    }

    /// The height of each exposed page edge, which runs along the book's thickness and keeps
    /// the leaves parallel.
    var pageEdgeHeight: Float { pageSize.y - Self.pageCornerRadius * 2 }

    /// The exposed page edges, as planes turned about the vertical axis: head, tail, and fore
    /// edge.
    var pageEdgeFaces: [(width: Float, position: SIMD3<Float>, angle: Float)] {
        let inset = Self.pageCornerRadius * 2
        return [
            (pageSize.z - inset, [-pageSize.x / 2 - 0.001, 0, 0], -.pi / 2),
            (pageSize.z - inset, [pageSize.x / 2 + 0.001, 0, 0], .pi / 2),
            (pageSize.x - inset, [0, 0, -pageSize.z / 2 - 0.001], .pi),
        ]
    }
}

/// The bookmark ribbon's motion: a chain of segments sliding out from under the focused book,
/// tail first, with a wave that damps out once it hangs free. No renderer simulates cloth, so
/// the motion is analytic.
enum BookWallRibbon {
    static let width: Float = 0.28
    static let segmentLength: Float = 0.21
    /// A fixed visible length of about two typical spines' thickness.
    static let segmentCount = 5
    static let slideTime: Float = 0.55
    static let settleTime: Float = 1.0

    /// One segment's pose in the ribbon's space, and the share of its length that shows.
    struct Segment: Sendable {
        var position: SIMD3<Float>
        var rotation: simd_quatf
        var visible: Float
    }

    /// The segments `elapsed` seconds after the ribbon starts to slide; `nil` for one still
    /// inside the book. Only the length below the book's bottom edge shows, so the ribbon never
    /// appears in front of the book.
    static func segments(at elapsed: Float) -> [Segment?] {
        let t = elapsed
        let length = Float(segmentCount) * segmentLength
        let slide = BookWallEasing.smootherstep(t / slideTime)
        // Path distance of the ribbon's top below the anchor; negative is inside the book.
        let offset = -length * (1 - slide)
        let damping = t >= settleTime ? 0 : t < slideTime ? 1 : exp(-(t - slideTime) / 0.15)
        var point = SIMD3<Float>.zero
        var started = false
        return (0..<segmentCount)
            .map { index in
                let top = offset + Float(index) * segmentLength
                guard top + segmentLength > 0 else { return nil }
                // The emerging segment shortens to its part below the edge.
                var visible: Float = 1
                if !started {
                    visible = min(1, (top + segmentLength) / segmentLength)
                    started = true
                }
                let freedom = min(1, max(0, top) / 1.2)
                let phase = 14 * t - 2.6 * top
                let swing = 0.42 * damping * freedom * sin(phase)
                let twist = 0.35 * damping * freedom * sin(phase + 1.2)
                let rotation =
                    simd_quatf(angle: swing, axis: [0, 0, 1])
                    * simd_quatf(angle: twist, axis: [0, 1, 0])
                let segment = Segment(position: point, rotation: rotation, visible: visible)
                point += simd_act(rotation, SIMD3<Float>(0, -segmentLength * visible, 0))
                return segment
            }
    }
}

/// Where the wall's flat extras sit: the shelf label, the shadow a pulled-out book casts on the
/// spine below it, and the bookmark ribbon.
struct BookWallDecor: Sendable {
    /// The book whose label shows, or `nil` for the hint.
    var labelBook: Int?
    /// The label's unit plane in the world, or `nil` when hidden.
    var label: simd_float4x4?
    var contactShadow: simd_float4x4?
    var contactShadowOpacity: Float = 0
    /// The ribbon's anchor under the focused book, or `nil` when hidden.
    var ribbon: Transform?
    /// Seconds since the ribbon and shadow started to arrive with the book's pull-out. The
    /// default is long past their arrival, for ones already in place.
    var elapsed: Float = 60
}

/// The wall's framing and lights, which the scene works out and its renderer draws with.
struct BookWallStage: Sendable {
    let cameraDepth: Float
    /// The camera's vertical field of view, in degrees.
    let fieldOfView: Float
    let fall: BookWallFall
    let pullOut: Float
    let pullOutDuration: Float
    let shelfLight: SIMD3<Float>
    let poolLight: SIMD3<Float>
    let topLightDirection: SIMD3<Float>
    /// The detail light level at which the rest of the wall starts to fade.
    let wallFadeStart: Float
    /// The environment light's exponent change at full detail level.
    let detailAmbientExponent: Float
    /// The wall image's distance behind the camera at the wall's resting camera depth.
    let backdropDistance: Float
    /// How much the open book's shadow darkens the wall, and its offset from directly behind
    /// the book, as a share of the book's outline on the wall.
    let detailShadowOpacity: Float
    let detailShadowOffset: SIMD2<Float>
}

/// Holds Book Wall's state across detail presentations, so returning does not replay the fall:
/// the shown wall's layout and framing, the book that focus pulled out, the open book's flight
/// and drift, and where the label, ribbon, and shadows go. It draws nothing. Its renderer
/// (`BookMetalWallHost`) draws the wall from what the scene hands it, on its own thread, and
/// reports back when a fall or a flight ends.
@MainActor
final class BookWallScene {
    private weak var renderer: BookMetalWallHost?
    /// The resting and detail wall images with their lighting baked in.
    private var bakedWall: (resting: CGImage, detail: CGImage)?
    private var hostViewportSize = CGSize.zero
    private var renderBounds: CGRect { CGRect(origin: .zero, size: hostViewportSize) }

    private static let fallDamping: Float = 0.25
    private static let idleVerticalAmplitudePoints: CGFloat = 24
    private static let idleHorizontalAmplitudePoints: CGFloat = 6
    private static let idleSwayRadians: Float = .pi / 90
    /// Positive yaw moves the fore edge away and shows the spine; positive pitch shows the head.
    private static let detailYawRadians: Float = 0.44
    private static let detailPitchRadians: Float = 0.09
    /// Moves the model right within its column, as a fraction of the column width, to
    /// leave room for its shadow on the left.
    private static let detailShadowRoom: CGFloat = 0.12
    /// Environment-light exponent added at full detail level. Dimming the fill makes the
    /// detail key light read as the key light.
    private static let detailAmbientExponent: Float = -1.05
    /// Direction from the detail pose toward its key light: above, right, and in front.
    /// The cover catches more light than the turned spine, and the shadow falls behind the
    /// book, down and to the left.
    private static let detailLightDirection = simd_normalize(SIMD3<Float>(1.2, 1.8, 5))
    /// Close enough that brightness falls off across the flight path and the wall behind.
    private static let detailLightDistance: Float = 3.2
    /// A dim, steep directional light adds top light from above, in front, and to the right.
    /// It casts no shadow: the renderer draws soft shadow planes instead, behind the open book
    /// and under a pulled-out one.
    private static let topLightDirection = simd_normalize(SIMD3<Float>(0.8, 2.4, 3.2))
    /// How much the detail book's shadow darkens the wall, and a pulled-out book's shadow
    /// darkens the top of the spine below it.
    private static let detailShadowOpacity: Float = 0.45
    /// The detail shadow's offset from directly behind the book, as a fraction of the
    /// book's outline on the wall.
    private static let detailShadowOffset = SIMD2<Float>(-0.12, -0.08)
    private static let contactShadowOpacity: Float = 0.35
    /// How far a pulled-out book's shadow reaches down the spine below it: the pull-out
    /// depth along the top light's slope.
    private static var contactShadowHeight: Float {
        focusPullOut * topLightDirection.y / topLightDirection.z
    }
    private static let pullOutDuration: Float = 0.2
    /// The shelf light's offset from the stacks' center: 30 units out in front, beyond where
    /// any book flies to its details. From that far, every stack gets nearly the same light,
    /// with no hotspot on the middle one. A light within a flight path would flash on a book as
    /// it passed the light, so keep it out of the space between the stacks and the detail pose.
    private static let shelfLightOffset = SIMD3<Float>(0, 3.25, 30)
    /// The wall's lighting is baked into the backdrop image rather than lit live; a
    /// full-screen lit surface cost more GPU time than the rest of the scene. The factors
    /// scale each color channel of the wall image, which is shown without tone mapping.
    /// They start from a fit to Simulator captures of a live-lit version of the wall: a warm
    /// point light 3.3 units in front of the wall behind the stacks (the pool), the shelf
    /// light's faint wash, and the environment. Relative to that fit, the pool is 40 percent
    /// lower and wider and the base 6 percent brighter. `wall-raw-backdrop` shows the unlit
    /// image for refitting.
    private static let restingWallLight = BookWallBackdropBake.Lighting(
        base: [0.390, 0.351, 0.296], pool: [0.504, 0.408, 0.245], wash: [0.200, 0.156, 0.128])
    /// The pool is centered this far above the stacks' center, with the falloff of a point
    /// light `poolGlowDistance` units from the wall, farther than the live pool light
    /// (`poolLightDistance`), so the glow spreads wider. The wash is centered far above the
    /// frame.
    private static let poolHeightOffset: Float = 0.5
    private static let poolLightDistance: Float = 3.3
    private static let poolGlowDistance: Float = 5
    private static let washHeightOffset: Float = 11.9
    private static let washLightDistance: Float = 33
    /// With details open, the dimmed environment and the distant key light leave the wall
    /// nearly flat, slightly darker toward the bottom. Fitted like `restingWallLight`.
    static let detailWallTop: SIMD3<Float> = [0.403, 0.348, 0.311]
    private static let detailWallBottom: SIMD3<Float> = [0.353, 0.292, 0.253]
    /// Space between the shelf's back and the backdrop. The baked lighting was fitted at
    /// this distance.
    private static let backdropGap: Float = 3.5
    private static let idleVerticalPeriod: Float = 40
    private static let idleHorizontalPeriod: Float = 48
    private static let idleSwayPeriod: Float = 60
    private static let idleRampDuration: Float = 4
    private static let flightDuration: TimeInterval = 1.8
    private static let idleReturnFraction: Float = 0.35
    /// Detail light level at which the wall starts to fade.
    private static let wallFadeStart: Float = 0.35

    private var backdropDistance: Float = 0
    private var wallImage: CGImage?
    private var bakedWallKey: WallBakeKey?
    private var shelfThickness = BookWallScene.minimumShelfThickness
    private var layout = BookWallLayout(books: [])
    /// The wall the scene last showed. It outlives `BookWallView`, so a wall that prepared while
    /// the reader was away can appear in place when they return.
    var shownWall: BookWallPreparedWall?
    /// Where each book rests, by book ID.
    private var restingTransforms: [Int: Transform] = [:]
    private typealias FlightFrame = BookWallFlightFrame

    /// The flight the renderer is playing, and what waits for it to end.
    private var flight: (id: UUID, completion: CheckedContinuation<Bool, Never>)?
    /// The open book's planned path from the wall to its details.
    private var flightFrames: [FlightFrame] = []
    /// The detail light level the last flight ended at: 0 at the resting wall, 1 with details
    /// open.
    private var detailLightLevel: Float = 0
    /// Where the detail key light stands. It stays fixed in the world once placed for a detail
    /// pose, so the flying book moves into its light instead of carrying its lighting along.
    private var detailLightPosition = SIMD3<Float>.zero
    /// When the open book started to drift, on the media clock, or `nil` while it doesn't.
    private var idleStarted: CFTimeInterval?
    private var idleAmplitude = SIMD2<Float>.zero
    private var wallCameraDepth: Float = 9.5
    private var viewportSize = CGSize.zero
    private var dropHeight: Float = 3
    #if DEBUG && targetEnvironment(simulator)
        /// Falls that began, so tests can tell a wall that dropped from one that appeared in place.
        private(set) var fallsStarted = 0
        /// Falls a newer wall replaced before their books landed.
        private(set) var fallsCutShort = 0
    #endif
    /// False only while books fall. A wall with nothing to drop, before preparation or
    /// without books, rests.
    private var isSettled = true
    /// Settles a wall that Reduce Motion showed at rest.
    private var placement: Task<Void, Never>?
    /// The book that focus pulled out of its stack, which the ribbon hangs from.
    private var focusedID: Int?
    /// When the focused book's ribbon and shadow started to arrive, or `nil` for ones placed at
    /// rest.
    private var ribbonShownAt: CFTimeInterval?
    /// The book that is flying to or from its details, or open in them.
    private var openID: Int?
    private var onFocusFrames: ((_ frames: [Int: CGRect], _ settled: Bool) -> Void)?

    /// Draws this scene's wall with `renderer`, starting with what the scene shows now. A wall
    /// that is still falling falls from the start, since nothing drew its fall.
    func attach(_ renderer: BookMetalWallHost) {
        self.renderer = renderer
        if let bakedWall {
            renderer.setBackdrop(resting: bakedWall.resting, detail: bakedWall.detail)
        }
        if let shownWall, !shownWall.books.isEmpty {
            renderer.show(shownWall, stage: stage, falls: !isSettled)
            renderer.focus(focusedID, decor: decor)
        }
    }

    /// Where the label, contact shadow, and ribbon sit now.
    private var decor: BookWallDecor {
        var decor = BookWallDecor()
        // The label waits for the books to land.
        guard isSettled, let wall = shownWall else { return decor }
        let label = focusedID.flatMap { id in wall.labels[id].map { (book: id, width: $0.width) } }
        if let width = label?.width ?? wall.hint?.width {
            decor.labelBook = label?.book
            // The label lies on the shelf's front face, which faces the camera, so the wall's
            // own projection gives it the shelf's perspective. It grows with the front, so a
            // taller front letters it larger.
            let scale = shelfThickness / Self.minimumShelfThickness
            decor.label =
                Transform(
                    scale: [width * scale, BookWallShelfLabel.height * scale, 1],
                    translation: shelfCenter + [0, 0, shelfSize.z / 2 + 0.002]
                )
                .matrix
        }
        guard let focusedID, let resting = restingTransforms[focusedID],
            let slot = layout.slots.first(where: { $0.book.id == focusedID }),
            !PerformanceDiagnostics.isolates("wall-no-ribbon")
        else { return decor }
        // A fixed length of ribbon hangs from under the focused book's bottom board, toward the
        // tail. It turns with the book and sits just behind the pulled-out spine, in front of
        // the lower spines and shelf lip.
        let pulled = Self.pulledOut(resting)
        decor.ribbon = Transform(
            scale: .one, rotation: pulled.rotation,
            translation: pulled.translation
                + pulled.rotation.act([
                    slot.bookHeight * 0.3, -slot.collisionThickness / 2, slot.coverWidth / 2 - 0.04,
                ]))
        decor.elapsed = ribbonShownAt.map { Float(CACurrentMediaTime() - $0) } ?? decor.elapsed
        if let shadow = contactShadow(
            under: slot,
            lifted: resting.translation + resting.rotation.act([0, 0, slot.coverWidth / 2]))
        {
            decor.contactShadow = shadow
            decor.contactShadowOpacity = Self.contactShadowOpacity
        }
        return decor
    }

    /// The framing and lights the renderer draws the shown wall with.
    private var stage: BookWallStage {
        BookWallStage(
            cameraDepth: wallCameraDepth, fieldOfView: Self.fieldOfView,
            fall: BookWallFall(
                dropHeight: dropHeight, gravity: Self.fallGravity, damping: Self.fallDamping),
            pullOut: Self.focusPullOut, pullOutDuration: Self.pullOutDuration,
            shelfLight: SIMD3<Float>(0, BookWallLayout.stackCenterY, 0) + Self.shelfLightOffset,
            poolLight: [
                0, BookWallLayout.stackCenterY + Self.poolHeightOffset,
                -shelfSize.z / 2 - Self.backdropGap + Self.poolLightDistance,
            ],
            topLightDirection: Self.topLightDirection, wallFadeStart: Self.wallFadeStart,
            detailAmbientExponent: Self.detailAmbientExponent,
            backdropDistance: backdropDistance, detailShadowOpacity: Self.detailShadowOpacity,
            detailShadowOffset: Self.detailShadowOffset)
    }

    private var shelfSize: SIMD3<Float> { Self.shelfSize(for: layout, thickness: shelfThickness) }

    private var shelfCenter: SIMD3<Float> { Self.shelfCenter(for: layout, size: shelfSize) }

    func updateHostViewport(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        hostViewportSize = size
        updateSceneViewport()
    }

    func configure(
        prepared: BookWallPreparedWall, reduceMotion: Bool,
        onFocusFrames: @escaping (_ frames: [Int: CGRect], _ settled: Bool) -> Void
    ) {
        self.onFocusFrames = onFocusFrames
        guard prepared.id != shownWall?.id else {
            // An empty wall publishes no frames, yet the view still waits to hear it has settled.
            if prepared.books.isEmpty { onFocusFrames([:], true) } else { publishFocusFrames() }
            return
        }
        #if DEBUG && targetEnvironment(simulator)
            if !isSettled, !layout.slots.isEmpty { fallsCutShort += 1 }
        #endif
        cancelTransition()
        shownWall = prepared
        layout = prepared.layout
        shelfThickness = Self.shelfThickness(for: layout)
        restingTransforms = Dictionary(
            uniqueKeysWithValues: layout.slots.map {
                ($0.book.id, Self.restingTransform(for: $0, in: layout))
            })
        dropHeight = max(
            2.5, (layout.slots.map { $0.restingY + $0.spineThickness / 2 }.max() ?? 0) + 1.4)
        viewportSize = .zero
        guard !prepared.books.isEmpty else {
            isSettled = true
            renderer?.clear()
            onFocusFrames([:], true)
            return
        }
        isSettled = false
        updateSceneViewport()
        startFall(reduceMotion: reduceMotion)
    }

    /// Drops the shown wall's books again.
    func replayFall(reduceMotion: Bool) -> Bool {
        guard isSettled, openID == nil, !layout.slots.isEmpty else { return false }
        focusedID = nil
        startFall(reduceMotion: reduceMotion)
        return true
    }

    /// Shows the wall falling from the drop height, or at rest with Reduce Motion. A fall ends
    /// when the renderer reports that every book has landed (`fallEnded(of:)`); without a
    /// renderer, it waits for one to attach or for `deactivate()`.
    private func startFall(reduceMotion: Bool) {
        #if DEBUG && targetEnvironment(simulator)
            if !reduceMotion { fallsStarted += 1 }
        #endif
        isSettled = false
        if let shownWall { renderer?.show(shownWall, stage: stage, falls: !reduceMotion) }
        placement?.cancel()
        guard reduceMotion else { return }
        // The view hears that the books rest after the call that showed them returns, as it
        // does after a fall, so it can first record that they are no longer settled.
        placement = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// Ends the fall of `wall`, whose books the renderer has drawn landing.
    func fallEnded(of wall: BookWallPreparedWall) {
        guard wall.id == shownWall?.id else { return }
        settle()
    }

    private func settle() {
        guard !isSettled else { return }
        placement?.cancel()
        isSettled = true
        renderer?.focus(focusedID, decor: decor)
        publishFocusFrames()
    }

    /// Sends each spine's rectangle at rest and whether the books have settled. Targets exist
    /// from the start of a fall, so entering the wall can focus a book while it falls; the view
    /// opens details only after settling. Never assigns focus.
    private func publishFocusFrames() {
        guard !layout.slots.isEmpty, renderBounds.width > 0, renderBounds.height > 0 else {
            return
        }
        // Frames use the wall's resting camera depth, whatever the current dolly, so they match
        // `plannedFocusFrames`.
        onFocusFrames?(
            Self.focusFrames(for: layout, cameraDepth: wallCameraDepth, in: renderBounds),
            isSettled)
    }

    /// Pulls `id`'s book out of its stack and seats the book that was out, with the label,
    /// ribbon, and shadow that go with it. The renderer eases both books.
    func highlight(_ id: Int?, reduceMotion: Bool) {
        guard isSettled, openID == nil, focusedID != id else { return }
        focusedID = id
        // The ribbon leaves at once when focus moves; only its arrival animates.
        ribbonShownAt = reduceMotion ? nil : CACurrentMediaTime()
        renderer?.focus(id, decor: decor)
    }

    /// Fits the shelf and the complete drop envelope to the host viewport.
    private func updateSceneViewport() {
        guard renderBounds.width > 0, renderBounds.height > 0,
            renderBounds.size != viewportSize
        else { return }
        viewportSize = renderBounds.size
        cancelTransition()
        wallCameraDepth = Self.wallCameraDepth(
            fitting: layout, shelfThickness: shelfThickness, in: renderBounds)
        let frameTop = Float(renderBounds.midY) * wallCameraDepth / focalLength
        let thickest = layout.slots.map(\.spineThickness).max() ?? 0
        dropHeight = max(dropHeight, frameTop + thickest)
        fitBackdrop()
        publishFocusFrames()
    }

    private var focalLength: Float { Self.focalLength(in: renderBounds) }

    private var visibleArea: CGRect { Self.visibleArea(in: renderBounds) }

    private func requiredCameraDepth(for point: SIMD3<Float>, in area: CGRect, focal: Float)
        -> Float
    {
        Self.requiredCameraDepth(for: point, in: area, of: renderBounds, focal: focal)
    }

    /// Uses the same vertical field of view as the camera, including during a planned dolly.
    private func project(_ point: SIMD3<Float>, cameraDepth: Float) -> CGPoint? {
        guard cameraDepth - point.z > Self.cameraNear else { return nil }
        return Self.project(point, cameraDepth: cameraDepth, in: renderBounds)
    }

    private func corners(of slot: BookWallLayout.Slot, at pose: Transform) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for x in [-slot.bookHeight / 2, slot.bookHeight / 2] {
            for y in [
                -slot.spineThickness / 2 - BookWallBookParts.coverSurfaceOffset,
                slot.spineThickness / 2 + BookWallBookParts.coverSurfaceOffset,
            ] {
                for z in [-slot.coverWidth / 2 - 0.01, slot.coverWidth / 2 + 0.01] {
                    points.append(pose.translation + simd_act(pose.rotation, SIMD3<Float>(x, y, z)))
                }
            }
        }
        return points
    }

    /// Fits every yaw angle and independent drift phase against the viewing frustum.
    private func fitsMotionEnvelope(
        of slot: BookWallLayout.Slot, at pose: Transform, cameraDepth: Float,
        inside area: CGRect, yawAllowance: Float, translationAllowance: SIMD2<Float>
    ) -> Bool {
        let focal = focalLength
        let left = Float(area.minX - renderBounds.midX) / focal
        let right = Float(area.maxX - renderBounds.midX) / focal
        let bottom = Float(renderBounds.midY - area.maxY) / focal
        let top = Float(renderBounds.midY - area.minY) / focal
        // Each inward-facing plane passes through the camera. Keeping all swept
        // corners inside these planes avoids the excess space of a world-axis box.
        let planes: [SIMD3<Float>] = [
            [1, 0, left], [-1, 0, -right], [0, 1, bottom], [0, -1, -top],
        ]
        let center = pose.translation - SIMD3<Float>(0, 0, cameraDepth)
        for point in corners(of: slot, at: pose) {
            let relative = point - pose.translation
            let depth = Self.yawRange(relative.z, -relative.x, limit: yawAllowance)
            guard -center.z - depth.upperBound > Self.cameraNear else { return false }
            for plane in planes {
                let rotation = Self.yawRange(
                    plane.x * relative.x + plane.z * relative.z,
                    plane.x * relative.z - plane.z * relative.x, limit: yawAllowance)
                let drift =
                    abs(plane.x) * translationAllowance.x
                    + abs(plane.y) * translationAllowance.y
                guard
                    simd_dot(plane, center) + plane.y * relative.y + rotation.lowerBound
                        - drift >= 0
                else { return false }
            }
        }
        return true
    }

    /// Includes interior extrema of a cosine/sine pair, which endpoint-only fits miss.
    private static func yawRange(_ cosine: Float, _ sine: Float, limit: Float)
        -> ClosedRange<Float>
    {
        let first = cosine * cos(limit) - sine * sin(limit)
        let last = cosine * cos(limit) + sine * sin(limit)
        var lower = min(first, last)
        var upper = max(first, last)
        let magnitude = hypot(cosine, sine)
        if abs(atan2(sine, cosine)) <= limit { upper = magnitude }
        if abs(atan2(-sine, -cosine)) <= limit { lower = -magnitude }
        return lower...upper
    }

    private func idleTranslationAmplitude(at pose: Transform, cameraDepth: Float) -> SIMD2<Float> {
        SIMD2<Float>(
            Float(Self.idleHorizontalAmplitudePoints), Float(Self.idleVerticalAmplitudePoints))
            * ((cameraDepth - pose.translation.z) / focalLength)
    }

    /// Bounds the quintic return correction, including its initial velocity tangent.
    private static func returnAllowance(amplitude: Float, period: Float, progress: Float) -> Float {
        let t = max(0, min(1, progress))
        let positionWeight = 1 - BookWallEasing.smootherstep(t)
        let velocityWeight = t * pow(1 - t, 3) * (1 + 3 * t)
        // During the ramp, |sin(ωt)| <= ωt and the ramp's peak slope is 1.875/duration.
        let maximumSpeed = 2.875 * amplitude * (2 * .pi / period)
        let blendDuration = Float(flightDuration) * idleReturnFraction
        return amplitude * positionWeight + maximumSpeed * blendDuration * velocityWeight
    }

    /// Pulls straight out of the stack before turning, with one clock for book and camera.
    func flyToDetail(
        _ book: Book, detailFrame: CGRect, reduceMotion: Bool
    ) async -> Bool {
        guard !Task.isCancelled, isSettled, openID == nil, let renderer,
            let resting = restingTransforms[book.id],
            let slot = layout.slots.first(where: { $0.book.id == book.id }),
            detailFrame.width > 0, detailFrame.height > 0, renderBounds.width > 0
        else { return false }
        // The flight starts where the book is: pulled out when it has focus.
        let start = focusedID == book.id ? Self.pulledOut(resting) : resting
        #if BOOKWORMS_DIAGNOSTICS
            let planningStart = CACurrentMediaTime()
        #endif
        let stackFront = layout.maxCoverWidth / 2 + 0.02
        let radius =
            simd_length(
                SIMD3<Float>(
                    slot.bookHeight, slot.spineThickness + 2 * BookWallBookParts.coverSurfaceOffset,
                    slot.coverWidth + 0.02)) / 2
        let clear = Self.pulledOut(resting, toDepth: stackFront + radius + 0.12)
        var cameraDepth = wallCameraDepth + clear.translation.z - start.translation.z
        var planned: [FlightFrame]?
        // Fit the paired camera/book trajectory, not just its endpoints. No model scaling
        // or sideways screen clamp is used to hide a path that leaves the render surface.
        for _ in 0..<16 {
            if let destination = detailDestination(
                for: slot, detailFrame: detailFrame,
                cameraDepth: cameraDepth, reduceMotion: reduceMotion)
            {
                // The destination keeps its distance from the camera, so the camera moves
                // back, in its usual steps, until the destination clears the stacks, without
                // spending tries on a large book with a wide board.
                guard destination.translation.z >= clear.translation.z else {
                    let shortfall = clear.translation.z - destination.translation.z
                    cameraDepth += (shortfall / 1.5).rounded(.up) * 1.5
                    continue
                }
                let frames = flightPath(
                    from: start, clear: clear, destination: destination, cameraDepth: cameraDepth)
                let amplitude = idleTranslationAmplitude(at: destination, cameraDepth: cameraDepth)
                let fits =
                    reduceMotion
                    || frames.enumerated()
                        .allSatisfy { index, frame in
                            // The reverse path starts at any idle pose, with its current velocity.
                            let time = Float(index) / Float(frames.count - 1)
                            let progress = (1 - time) / Self.idleReturnFraction
                            return fitsMotionEnvelope(
                                of: slot, at: frame.pose, cameraDepth: frame.cameraDepth,
                                inside: visibleArea.insetBy(dx: 12, dy: 12),
                                yawAllowance: Self.returnAllowance(
                                    amplitude: Self.idleSwayRadians, period: Self.idleSwayPeriod,
                                    progress: progress),
                                translationAllowance: SIMD2<Float>(
                                    Self.returnAllowance(
                                        amplitude: amplitude.x, period: Self.idleHorizontalPeriod,
                                        progress: progress),
                                    Self.returnAllowance(
                                        amplitude: amplitude.y, period: Self.idleVerticalPeriod,
                                        progress: progress)))
                        }
                if fits {
                    planned = frames
                    break
                }
            }
            cameraDepth += 1.5
        }
        guard let frames = planned, let destination = frames.last else { return false }
        #if BOOKWORMS_DIAGNOSTICS
            if PerformanceDiagnostics.enabled {
                let message =
                    "BookWallPlan milliseconds=\((CACurrentMediaTime() - planningStart) * 1000)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        #endif
        openID = book.id
        flightFrames = frames
        detailLightPosition =
            destination.pose.translation + Self.detailLightDirection * Self.detailLightDistance
        if reduceMotion {
            detailLightLevel = 1
            renderer.fly(
                book.id,
                BookWallFlight(frames: [destination], duration: 0, fromLevel: 1, toLevel: 1),
                light: detailLightPosition, completion: nil)
            return true
        }
        let completed = await playFlight(frames, of: book.id, toLevel: 1)
        return completed && !Task.isCancelled && openID == book.id
    }

    private func detailDestination(
        for slot: BookWallLayout.Slot, detailFrame: CGRect,
        cameraDepth: Float, reduceMotion: Bool
    ) -> Transform? {
        // Below Back, where cover details place the cover.
        let top = max(
            BookDetailCoverLayout.wallNavigationCoverSize.height + 12,
            detailFrame.minY + BookDetailCoverLayout.verticalPadding
                + BookDetailCoverLayout.backHeight + BookDetailCoverLayout.coverGap)
        let bottom = min(
            visibleArea.maxY, detailFrame.maxY - BookDetailCoverLayout.verticalPadding)
        // Fit symmetrically around the screen's center rather than centering below
        // the Back button. The full sway remains below Back.
        let halfHeight = min(renderBounds.midY - top, bottom - renderBounds.midY)
        guard halfHeight > 0 else { return nil }
        let left = detailFrame.minX + BookDetailCoverLayout.horizontalPadding
        let width = detailFrame.width * BookDetailCoverLayout.columnFraction
        let area = CGRect(
            x: left + width * Self.detailShadowRoom, y: renderBounds.midY - halfHeight,
            width: width,
            height: halfHeight * 2
        )
        .intersection(visibleArea)
        .insetBy(
            dx: reduceMotion ? 12 : 20, dy: reduceMotion ? 12 : 20)
        guard area.width > 0, area.height > 0 else { return nil }
        let center = CGPoint(x: area.midX, y: area.midY)
        let focal = focalLength
        let ray = SIMD3<Float>(
            Float(center.x - renderBounds.midX) / focal,
            Float(renderBounds.midY - center.y) / focal,
            -1)
        let faceRotation =
            simd_quatf(angle: -.pi / 2, axis: [0, 0, 1])
            * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        // Face the camera ray, then turn the spine toward the viewer and tip the head
        // forward. A face-on pose hides the casing and pages and reads as a flat card.
        let yaw = atan2(-ray.x, 1) + Self.detailYawRadians
        // Tilt before turning so the pitch stays on the book's own horizontal axis;
        // applying it after the turn rolls the book instead.
        let rotation =
            simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: Self.detailPitchRadians, axis: [1, 0, 0]) * faceRotation
        func pose(at distance: Float) -> Transform {
            var pose = Transform(
                scale: .one, rotation: rotation,
                translation: SIMD3<Float>(0, 0, cameraDepth) + ray * distance)
            // Perspective offsets the visible silhouette from the model's origin.
            // Center the neutral silhouette before reserving its complete motion.
            for _ in 0..<3 {
                let projected = corners(of: slot, at: pose)
                    .compactMap {
                        project($0, cameraDepth: cameraDepth)
                    }
                guard projected.count == 8, let bounds = Self.bounds(of: projected) else { break }
                pose.translation.x += Float(center.x - bounds.midX) * distance / focal
                pose.translation.y -= Float(center.y - bounds.midY) * distance / focal
            }
            return pose
        }
        func fits(_ pose: Transform) -> Bool {
            fitsMotionEnvelope(
                of: slot, at: pose, cameraDepth: cameraDepth, inside: area,
                yawAllowance: reduceMotion ? 0 : Self.idleSwayRadians,
                translationAllowance: reduceMotion
                    ? .zero : idleTranslationAmplitude(at: pose, cameraDepth: cameraDepth))
        }
        var near: Float = 0.1
        var far: Float = max(1, slot.bookHeight)
        while !fits(pose(at: far)) && far < 10_000 { far *= 2 }
        guard fits(pose(at: far)) else { return nil }
        for _ in 0..<24 {
            let middle = (near + far) / 2
            if fits(pose(at: middle)) { far = middle } else { near = middle }
        }
        return pose(at: far)
    }

    /// Starts the open book's slow drift in its detail pose, once its details show.
    func startDetailDrift(reduceMotion: Bool) {
        guard openID != nil, !reduceMotion, idleStarted == nil,
            let destination = flightFrames.last
        else { return }
        idleAmplitude = idleTranslationAmplitude(
            at: destination.pose, cameraDepth: destination.cameraDepth)
        let started = CACurrentMediaTime()
        idleStarted = started
        // The renderer drifts the book on the media clock, which the return reads.
        renderer?.drift(drift, since: started)
    }

    func returnFromDetail(reduceMotion: Bool) async {
        guard let book = openID else { return }
        // The return starts from the drift's offset and velocity now, so it starts where the
        // book is on screen.
        let motion = idleStarted.map { drift.motion(at: Float(CACurrentMediaTime() - $0)) }
        idleStarted = nil
        if !reduceMotion {
            var frames = Array(flightFrames.reversed())
            if let motion {
                let count = frames.count - 1
                let blendDuration = Float(Self.flightDuration) * Self.idleReturnFraction
                for index in frames.indices {
                    let progress = min(
                        1, Float(index) / Float(max(1, count)) / Self.idleReturnFraction)
                    frames[index].pose.translation += Self.travel(
                        SIMD3<Float>(motion.offset.x, motion.offset.y, 0), .zero,
                        startVelocity: SIMD3<Float>(motion.velocity.x, motion.velocity.y, 0)
                            * blendDuration,
                        endVelocity: .zero, progress: progress)
                    let yaw =
                        Self.travel(
                            SIMD3<Float>(0, 0, motion.offset.z), .zero,
                            startVelocity: SIMD3<Float>(0, 0, motion.velocity.z) * blendDuration,
                            endVelocity: .zero, progress: progress
                        )
                        .z
                    frames[index].pose.rotation =
                        simd_quatf(angle: yaw, axis: [0, 1, 0]) * frames[index].pose.rotation
                }
            }
            guard await playFlight(frames, of: book, toLevel: 0), !Task.isCancelled else { return }
        }
        // The reversed flight left the book where it started: pulled out when it has focus.
        endFlight(completed: false)
        detailLightLevel = 0
        flightFrames.removeAll()
        openID = nil
        renderer?.endDetail()
    }

    /// Finishes an interrupted fall while hidden so reentry cannot resume overlapping drops.
    func deactivate() {
        cancelTransition()
        guard !isSettled, !layout.slots.isEmpty else { return }
        renderer?.seat()
        settle()
    }

    /// Cancels a presentation synchronously so stale tasks cannot leave a hidden wall.
    func cancelTransition() {
        endFlight(completed: false)
        detailLightLevel = 0
        idleStarted = nil
        flightFrames.removeAll()
        openID = nil
        focusedID = nil
        renderer?.endDetail()
        renderer?.focus(nil, decor: decor)
    }

    /// Replaces the backdrop with a rendering of the app's wall background, one pixel per
    /// point. Until the first call, the clear color fills the frame.
    func setBackdrop(_ image: CGImage) {
        wallImage = image
        fitBackdrop()
    }

    /// Places the wall image `backdropGap` behind the shelf at the resting camera depth, where
    /// it fills the frame, and bakes its lighting. The renderer moves it with the camera, so
    /// the frame stays filled throughout a flight.
    private func fitBackdrop() {
        guard renderBounds.width > 0, renderBounds.height > 0 else { return }
        backdropDistance = wallCameraDepth + shelfSize.z / 2 + Self.backdropGap
        bakeWall()
    }

    private struct WallBakeKey: Equatable {
        let image: ObjectIdentifier
        let size: CGSize
        let cameraDepth: Float
        let distance: Float
    }

    /// Bakes the resting and detail lighting into the wall image when the image or the
    /// framing changes. The glows are placed by projecting their world positions through
    /// the resting camera, which is where the backdrop image fills the frame.
    private func bakeWall() {
        guard let wallImage else { return }
        let key = WallBakeKey(
            image: ObjectIdentifier(wallImage), size: renderBounds.size,
            cameraDepth: wallCameraDepth, distance: backdropDistance)
        guard key != bakedWallKey else { return }
        let pixelsPerPoint = CGFloat(wallImage.width) / renderBounds.width
        // Image pixels per world unit on the wall plane.
        let pixelsPerUnit = CGFloat(focalLength / backdropDistance) * pixelsPerPoint
        let stackCenter = BookWallLayout.stackCenterY
        func glow(height: Float, distance: Float) -> BookWallBackdropBake.Glow {
            BookWallBackdropBake.Glow(
                center: CGPoint(
                    x: CGFloat(wallImage.width) / 2,
                    y: CGFloat(wallImage.height) / 2 - CGFloat(height) * pixelsPerUnit),
                radius: CGFloat(distance) * pixelsPerUnit)
        }
        // Diagnostic: shows the unlit wall image, for fitting the lighting factors.
        let raw = PerformanceDiagnostics.isolates("wall-raw-backdrop")
        guard
            let images = BookWallBackdropBake.render(
                wallImage,
                resting: raw ? .init(base: .one, pool: .zero, wash: .zero) : Self.restingWallLight,
                pool: glow(
                    height: stackCenter + Self.poolHeightOffset, distance: Self.poolGlowDistance),
                wash: glow(
                    height: stackCenter + Self.washHeightOffset, distance: Self.washLightDistance),
                detailTop: Self.detailWallTop, detailBottom: Self.detailWallBottom)
        else { return }
        bakedWallKey = key
        bakedWall = images
        renderer?.setBackdrop(resting: images.resting, detail: images.detail)
    }

    /// Where the shadow of a pulled-out book, whose spine's middle rests at `lifted`, falls on
    /// the top of the spine below it, as the top light would cast it, on that spine as it
    /// turns; `nil` for a book with nothing below it.
    private func contactShadow(under slot: BookWallLayout.Slot, lifted: SIMD3<Float>)
        -> simd_float4x4?
    {
        let below = layout.slots
            .filter { $0.column == slot.column && $0.restingY < slot.restingY }
            .max { $0.restingY < $1.restingY }
        guard let below, let belowResting = restingTransforms[below.book.id] else { return nil }
        let belowSpine =
            belowResting.translation + belowResting.rotation.act([0, 0, below.coverWidth / 2])
        let left = max(
            lifted.x - slot.spineFaceWidth / 2, belowSpine.x - below.spineFaceWidth / 2)
        let right = min(
            lifted.x + slot.spineFaceWidth / 2, belowSpine.x + below.spineFaceWidth / 2)
        guard right > left else { return nil }
        let height = Self.contactShadowHeight
        // The light comes from the right, so the shadow falls a little to the left.
        let shift = height * Self.topLightDirection.x / Self.topLightDirection.y
        let top = belowResting.translation.y + below.collisionThickness / 2
        // On the spine below, which turns its own way.
        let across = (left + right) / 2 - shift - belowSpine.x
        let place =
            belowSpine + belowResting.rotation.act([across, 0, 0.012])
            + [0, top - height / 2 - belowSpine.y, 0]
        return Transform(
            scale: [right - left, height, 1], rotation: belowResting.rotation, translation: place
        )
        .matrix
    }

    private var drift: BookWallDrift {
        BookWallDrift(
            amplitudes: [idleAmplitude.x, idleAmplitude.y, Self.idleSwayRadians],
            periods: [Self.idleHorizontalPeriod, Self.idleVerticalPeriod, Self.idleSwayPeriod],
            rampDuration: Self.idleRampDuration)
    }

    private func endFlight(completed: Bool) {
        let completion = flight?.completion
        flight = nil
        completion?.resume(returning: completed)
    }

    /// Plays `frames` on the renderer's thread while the detail light level moves to `toLevel`.
    /// Returns whether the flight reached its last frame.
    private func playFlight(_ frames: [FlightFrame], of book: Int, toLevel: Float) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                guard !Task.isCancelled, let renderer else {
                    completion.resume(returning: false)
                    return
                }
                endFlight(completed: false)
                idleStarted = nil
                flight = (id, completion)
                renderer.fly(
                    book,
                    BookWallFlight(
                        frames: frames, duration: Self.flightDuration,
                        fromLevel: detailLightLevel, toLevel: toLevel),
                    light: detailLightPosition
                ) { [weak self] in
                    guard let self, flight?.id == id else { return }
                    detailLightLevel = toLevel
                    endFlight(completed: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.flight?.id == id { self?.cancelTransition() }
            }
        }
    }

    /// Quintic Hermite interpolation preserves velocity and zero acceleration at clearance.
    private static func travel(
        _ from: SIMD3<Float>, _ to: SIMD3<Float>, startVelocity: SIMD3<Float>,
        endVelocity: SIMD3<Float>, progress t: Float
    ) -> SIMD3<Float> {
        let distance = to - from
        let a = 10 * distance - 6 * startVelocity - 4 * endVelocity
        let b = -15 * distance + 8 * startVelocity + 7 * endVelocity
        let c = 6 * distance - 3 * startVelocity - 3 * endVelocity
        return from + startVelocity * t + a * (t * t * t) + b * (t * t * t * t) + c
            * (t * t * t * t * t)
    }

    private func flightPath(
        from start: Transform, clear: Transform, destination: Transform, cameraDepth: Float
    ) -> [FlightFrame] {
        let extractionFraction: Float = 0.35
        let velocity = (clear.translation - start.translation) * 0.55
        return (0...180)
            .map { frame in
                let time = Float(frame) / 180
                var pose = start
                let cameraProgress: Float
                if time <= extractionFraction {
                    let t = time / extractionFraction
                    pose.translation = Self.travel(
                        start.translation, clear.translation, startVelocity: .zero,
                        endVelocity: velocity, progress: t)
                    cameraProgress = BookWallEasing.smootherstep(t)
                } else {
                    let t = (time - extractionFraction) / (1 - extractionFraction)
                    pose.translation = Self.travel(
                        clear.translation, destination.translation,
                        startVelocity: velocity * (1 - extractionFraction) / extractionFraction,
                        endVelocity: .zero, progress: t)
                    pose.rotation = simd_slerp(
                        start.rotation, destination.rotation, BookWallEasing.smootherstep(t))
                    cameraProgress = 1
                }
                return FlightFrame(
                    pose: pose,
                    cameraDepth: wallCameraDepth + (cameraDepth - wallCameraDepth) * cameraProgress)
            }
    }
}

/// The wall's geometry as functions of its layout and viewport, which preparation also uses off
/// the main actor.
nonisolated extension BookWallScene {
    /// Vertical field of view, like a 50mm lens: long enough that books keep their shape as
    /// they move toward the camera or across the frame. Wider angles stretch the page edges.
    fileprivate static let fieldOfView: Float = 30
    /// Nothing nearer the camera than this is drawn or fitted.
    fileprivate static let cameraNear: Float = 0.01
    fileprivate static let fallGravity: Float = 22
    private static let minimumDropSpacing = 0.10
    /// How far focus pulls a book out of its stack, enough to expose its page edges and
    /// cast a shadow on the spine below.
    fileprivate static let focusPullOut: Float = 0.35
    /// How far the shelf extends beyond the deepest cover, front and back together.
    private static let shelfDepthAllowance: Float = 0.55
    /// The shelf front's height where the label already letters at `minimumLabelPoints`.
    /// Wider walls get a taller front (`shelfThickness(for:)`).
    static let minimumShelfThickness: Float = 0.5
    /// The smallest point size the shelf label may show at: the app's legibility minimum for
    /// text read from viewing distance.
    static let minimumLabelPoints: Float = 23
    /// The full-screen canvas the wall fills on Apple TV, in points, which the label's size
    /// is fitted to.
    private static let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// The camera's focal length in points; the camera's field of view is always `fieldOfView`.
    private static func focalLength(in bounds: CGRect) -> Float {
        Float(bounds.height) / (2 * tan(fieldOfView * .pi / 360))
    }

    private static func visibleArea(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: 72, dy: 72)
    }

    private static func requiredCameraDepth(
        for point: SIMD3<Float>, in area: CGRect, of bounds: CGRect, focal: Float
    ) -> Float {
        let horizontalRoom = Float(
            point.x < 0 ? bounds.midX - area.minX : area.maxX - bounds.midX)
        let verticalRoom = Float(point.y > 0 ? bounds.midY - area.minY : area.maxY - bounds.midY)
        return point.z
            + max(
                abs(point.x) * focal / max(1, horizontalRoom),
                abs(point.y) * focal / max(1, verticalRoom))
    }

    private static func project(_ point: SIMD3<Float>, cameraDepth: Float, in bounds: CGRect)
        -> CGPoint?
    {
        let distance = cameraDepth - point.z
        guard distance > 0 else { return nil }
        let scale = focalLength(in: bounds) / distance
        return CGPoint(
            x: bounds.midX + CGFloat(point.x * scale), y: bounds.midY - CGFloat(point.y * scale))
    }

    /// The camera depth that frames `layout`'s settled stacks, the header room above them, the
    /// shelf, and the focus pull-out inside `bounds`, without changing book proportions. Books
    /// start above the frame and fall into view.
    private static func wallCameraDepth(
        fitting layout: BookWallLayout, shelfThickness: Float, in bounds: CGRect
    ) -> Float {
        let area = visibleArea(in: bounds)
        let focal = focalLength(in: bounds)
        var depth: Float = 1
        let front = layout.maxCoverWidth / 2
        for slot in layout.slots {
            for y in [
                layout.floorY - shelfThickness - 0.06,
                slot.restingY + slot.spineThickness / 2 + 1.0,
            ] {
                for x in [slot.x - slot.bookHeight / 2 - 0.2, slot.x + slot.bookHeight / 2 + 0.2] {
                    // Spines' middles sit at the deepest book's front, a turned spine's end a
                    // little nearer, and focus pulls one further out.
                    let turned = slot.bookHeight / 2 * sin(maximumStackTurn)
                    let point = SIMD3<Float>(x, y, front + focusPullOut + turned + 0.03)
                    depth = max(
                        depth, requiredCameraDepth(for: point, in: area, of: bounds, focal: focal))
                }
            }
        }
        let shelfHalfWidth = layout.totalWidth / 2 + 0.7
        for x in [-shelfHalfWidth, shelfHalfWidth] {
            let corner = SIMD3<Float>(
                x, layout.floorY - shelfThickness, front + shelfDepthAllowance / 2)
            depth = max(
                depth, requiredCameraDepth(for: corner, in: area, of: bounds, focal: focal))
        }
        return depth + 0.15
    }

    /// The shelf front's height for `layout`. The camera frames a wider wall from farther away,
    /// so where the label would letter below `minimumLabelPoints`, the front extends downward
    /// and the label grows with it. The shelf's top stays at the floor, where the books rest.
    static func shelfThickness(for layout: BookWallLayout) -> Float {
        var thickness = minimumShelfThickness
        // A taller front moves the camera back only when the shelf's bottom edge sets the
        // frame, and then by less than the label grows, so a few passes settle it. Rounding up
        // to hundredths of a unit keeps each pass's result at or above the minimum.
        while true {
            let points = labelPoints(for: layout, shelfThickness: thickness)
            guard points < minimumLabelPoints else { return thickness }
            thickness = (thickness * minimumLabelPoints / points * 100).rounded(.up) / 100
        }
    }

    /// The point size the shelf label letters at on the Apple TV screen, with a front
    /// `shelfThickness` tall.
    static func labelPoints(for layout: BookWallLayout, shelfThickness: Float) -> Float {
        let cameraDepth = wallCameraDepth(
            fitting: layout, shelfThickness: shelfThickness, in: screenBounds)
        let shelfFront = layout.maxCoverWidth / 2 + shelfDepthAllowance / 2
        let letterSize =
            BookWallShelfLabel.height * BookWallShelfLabel.letterShare * shelfThickness
            / minimumShelfThickness
        return letterSize * focalLength(in: screenBounds) / (cameraDepth - shelfFront)
    }

    /// The resting wall's scale at its spine plane on the 1920 × 1080-point screen, in points
    /// per scene unit. `BookWallPreparation` letters spines at this scale, so the shelf's point
    /// sizes, such as its 23-point title floor, hold on the Apple TV screen.
    static func spinePointsPerUnit(for layout: BookWallLayout) -> Float {
        let cameraDepth = wallCameraDepth(
            fitting: layout, shelfThickness: shelfThickness(for: layout), in: screenBounds)
        return focalLength(in: screenBounds) / (cameraDepth - layout.maxCoverWidth / 2)
    }

    /// Spine rectangles for `layout` at rest, in full-screen points for `viewport`.
    ///
    /// Needs neither a renderer nor a configured scene, so `BookWallView` mounts its focus
    /// targets in the page's first render, before the sidebar hands focus to the page. These are
    /// the frames the scene publishes until the books settle. Never assigns focus.
    static func plannedFocusFrames(for layout: BookWallLayout, viewport: CGSize) -> [Int: CGRect] {
        let bounds = CGRect(origin: .zero, size: viewport)
        guard !layout.slots.isEmpty, bounds.width > 0, bounds.height > 0 else { return [:] }
        return focusFrames(
            for: layout,
            cameraDepth: wallCameraDepth(
                fitting: layout, shelfThickness: shelfThickness(for: layout), in: bounds),
            in: bounds)
    }

    private static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The shelf's size for `layout`, with a front `thickness` tall: wider than the stacks and
    /// deeper than the deepest cover.
    static func shelfSize(for layout: BookWallLayout, thickness: Float) -> SIMD3<Float> {
        [layout.totalWidth + 1.4, thickness, layout.maxCoverWidth + shelfDepthAllowance]
    }

    /// The middle of a shelf of `size`, whose top is the floor the books rest on.
    static func shelfCenter(for layout: BookWallLayout, size: SIMD3<Float>) -> SIMD3<Float> {
        [0, layout.floorY - size.y / 2, 0]
    }

    /// `layout`'s books as its fall drops them: one after another in the order of its slots,
    /// each to the height it rests at.
    static func fallingBooks(of layout: BookWallLayout) -> [BookWallFall.Book] {
        let spacing = dropSpacing(for: layout)
        return layout.slots.enumerated()
            .map { order, slot in
                BookWallFall.Book(
                    rest: slot.restingY, column: slot.column, delay: Double(order) * spacing)
            }
    }

    /// The time between one book's drop and the next.
    private static func dropSpacing(for layout: BookWallLayout) -> TimeInterval {
        let thickestBook = layout.slots.map(\.collisionThickness).max() ?? 0
        // Leave enough vertical separation before another book enters the same column.
        let distanceBetweenBooks = Double(thickestBook + 0.15)
        let clearanceTime = sqrt(2 * distanceBetweenBooks / Double(fallGravity))
        let columnSpacing = clearanceTime / Double(layout.columns)
        return max(minimumDropSpacing, columnSpacing)
    }

    /// How far a stacked book turns at most about the vertical axis, in radians: about
    /// 4 degrees, as the iPhone's stacks turn theirs. Most books turn much less.
    static let maximumStackTurn: Float = 0.07

    /// Where a book rests in its stack.
    ///
    /// Each book lies a little off its column's middle and turns a few degrees about the
    /// vertical axis through its spine's middle, so its spine faces a little left or right and
    /// the stack looks placed by hand. It stays level on the book below. Both come from the
    /// book's ID, and each book stays inside its column, so books never meet the next column's
    /// books as they fall.
    static func restingTransform(
        for slot: BookWallLayout.Slot, in layout: BookWallLayout
    ) -> Transform {
        let id = UInt64(bitPattern: Int64(slot.book.id))
        let seed = Float((id &* 1_103_515_245) % 100) / 100
        let even = Float((id &* 2_654_435_761 &+ 40_503) % 1000) / 500 - 1
        // A turned book's fore edge moves across by its depth times the turn's sine, which the
        // column's room beside its longest book must hold.
        let room = max(0, slot.laneWidth - slot.bookHeight)
        let limit = asin(min(1, room / max(slot.coverWidth, 0.01)))
        let turn = min(maximumStackTurn, limit) * even * abs(even)
        let rotation = simd_quatf(angle: turn, axis: [0, 1, 0])
        let reach = slot.bookHeight / 2 * cos(turn)
        let fore = -slot.coverWidth * sin(turn)
        let half = slot.laneWidth / 2
        let spineX = min(
            max(slot.x + (seed - 0.5) * 0.18, slot.x - half + reach - min(0, fore)),
            slot.x + half - reach - max(0, fore))
        // Spines sit on one front plane at their middles. Centered books of different depths
        // would put deeper spines nearer the camera, where they hide part of the book above or
        // below.
        let front = layout.maxCoverWidth / 2
        return Transform(
            scale: .one, rotation: rotation,
            translation: [spineX, slot.restingY, front]
                + rotation.act([0, 0, -slot.coverWidth / 2]))
    }

    /// A resting book pulled out of its stack by `focusPullOut`, along the way its spine faces,
    /// so the spine stays readable.
    private static func pulledOut(_ resting: Transform) -> Transform {
        var pose = resting
        pose.translation += resting.rotation.act([0, 0, focusPullOut])
        return pose
    }

    /// A resting book pulled out of its stack along the way its spine faces, as focus pulls it,
    /// until its middle reaches `depth`.
    static func pulledOut(_ resting: Transform, toDepth depth: Float) -> Transform {
        let outward = resting.rotation.act([0, 0, 1])
        var pose = resting
        pose.translation += outward * ((depth - resting.translation.z) / outward.z)
        return pose
    }

    /// Projects each spine at rest. These are world poses, so the same frames serve before
    /// and after the books land.
    fileprivate static func focusFrames(
        for layout: BookWallLayout, cameraDepth: Float, in viewport: CGRect
    ) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for slot in layout.slots {
            let pose = restingTransform(for: slot, in: layout).matrix
            var points: [CGPoint] = []
            for x in [-slot.spineFaceWidth / 2, slot.spineFaceWidth / 2] {
                for y in [-slot.spineFaceHeight / 2, slot.spineFaceHeight / 2] {
                    let corner =
                        pose
                        * SIMD4<Float>(
                            x, y, slot.coverWidth / 2 + BookWallBookParts.spineFaceOffset, 1)
                    if let point = project(
                        [corner.x, corner.y, corner.z], cameraDepth: cameraDepth, in: viewport),
                        point.x.isFinite, point.y.isFinite
                    {
                        points.append(point)
                    }
                }
            }
            guard points.count == 4, let rect = bounds(of: points) else { continue }
            let width = max(44, rect.width)
            let height = max(30, rect.height)
            frames[slot.book.id] = CGRect(
                x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        return frames
    }
}

extension BookWallLayout {
    /// The deepest book's cover width. Spines sit flush at half of it, and the shelf's depth
    /// follows it.
    var maxCoverWidth: Float { slots.map(\.coverWidth).max() ?? 0.8 }
}

/// Fits source art to the front board with a narrow, synthesized casing bleed. Only the joint
/// fold covers source art.
enum BookWallCoverTexture {
    /// How far the fold reaches onto the front board from the joint: 3 mm at Book Wall's
    /// scale, where a book about 4 units long stands for one about 20 cm long.
    static let foldReach: Float = 0.06

    /// Fits `image` to the front board, then folds the cover's `edgeColors` (head to tail)
    /// and, at half strength, the `cloth` over the joint, as the spine shows them.
    static func make(
        image: CGImage, slot: BookWallLayout.Slot, cloth: StyleColor, edgeColors: [StyleColor]
    ) -> CGImage? {
        let clothColor = cloth.uiColor
        let size = CGSize(width: 512, height: CGFloat(slot.bookHeight / slot.coverWidth) * 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let cg = context.cgContext
                clothColor.setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                let source = CGSize(width: image.width, height: image.height)
                let margin = CGSize(width: size.width * 0.003, height: size.height * 0.003)
                let inner = CGRect(origin: .zero, size: size)
                    .insetBy(dx: margin.width, dy: margin.height)
                // The model uses this cover's aspect ratio. Fit instead of cropping if an
                // unavailable ratio required a fallback when the layout was prepared.
                let scale = min(inner.width / source.width, inner.height / source.height)
                let imageRect = CGRect(
                    x: (size.width - source.width * scale) / 2,
                    y: (size.height - source.height * scale) / 2,
                    width: source.width * scale, height: source.height * scale)
                UIImage(cgImage: image).draw(in: imageRect)
                // Repeat the actual outer pixel row or column into the tiny new margin, then
                // fade only that margin into the case. Apart from the joint fold below, no tint
                // or gradient touches source art.
                if let top = image.cropping(
                    to: CGRect(x: 0, y: 0, width: image.width, height: 1))
                {
                    drawBleed(
                        top,
                        in: CGRect(
                            x: imageRect.minX, y: imageRect.minY - margin.height,
                            width: imageRect.width, height: margin.height),
                        start: CGPoint(x: 0, y: imageRect.minY),
                        end: CGPoint(x: 0, y: imageRect.minY - margin.height),
                        caseColor: clothColor, context: cg)
                }
                if let right = image.cropping(
                    to: CGRect(x: image.width - 1, y: 0, width: 1, height: image.height))
                {
                    drawBleed(
                        right,
                        in: CGRect(
                            x: imageRect.maxX, y: imageRect.minY,
                            width: margin.width, height: imageRect.height),
                        start: CGPoint(x: imageRect.maxX, y: 0),
                        end: CGPoint(x: imageRect.maxX + margin.width, y: 0),
                        caseColor: clothColor, context: cg)
                }
                if let bottom = image.cropping(
                    to: CGRect(x: 0, y: image.height - 1, width: image.width, height: 1))
                {
                    drawBleed(
                        bottom,
                        in: CGRect(
                            x: imageRect.minX, y: imageRect.maxY,
                            width: imageRect.width, height: margin.height),
                        start: CGPoint(x: 0, y: imageRect.maxY),
                        end: CGPoint(x: 0, y: imageRect.maxY + margin.height),
                        caseColor: clothColor, context: cg)
                }
                if let left = image.cropping(
                    to: CGRect(x: 0, y: 0, width: 1, height: image.height))
                {
                    drawBleed(
                        left,
                        in: CGRect(
                            x: imageRect.minX - margin.width, y: imageRect.minY,
                            width: margin.width, height: imageRect.height),
                        start: CGPoint(x: imageRect.minX, y: 0),
                        end: CGPoint(x: imageRect.minX - margin.width, y: 0),
                        caseColor: clothColor, context: cg)
                }
                // The artwork's left edge is the joint (`BookWallHardcoverMesh.coverSurfaceData`).
                let fold = CGRect(
                    x: 0, y: 0, width: size.width * CGFloat(foldReach / slot.coverWidth),
                    height: size.height)
                BookWallSpineTexture.drawFold(
                    edgeColors, opacity: 1, in: fold, jointAtLeft: true, context: cg)
                if !edgeColors.isEmpty {
                    BookWallSpineTexture.drawFold(
                        [cloth], opacity: 0.5, in: fold, jointAtLeft: true, context: cg)
                }
            }
            .cgImage
    }

    private static func drawBleed(
        _ edge: CGImage, in rect: CGRect, start: CGPoint, end: CGPoint,
        caseColor: UIColor, context: CGContext
    ) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [caseColor.withAlphaComponent(0).cgColor, caseColor.cgColor] as CFArray,
                locations: [0, 1])
        else { return }
        context.saveGState()
        context.clip(to: rect)
        UIImage(cgImage: edge).draw(in: rect)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }
}

/// Bakes the wall's lighting into the backdrop image and draws the soft shadow textures.
/// Baking replaces a full-screen lit surface, which cost more GPU time than the rest of the
/// scene, with an unlit one.
enum BookWallBackdropBake {
    /// Per-channel factors for display color values: base + pool × falloff + wash × falloff.
    struct Lighting {
        let base: SIMD3<Float>
        let pool: SIMD3<Float>
        let wash: SIMD3<Float>
    }

    /// A point light's footprint on the wall, in image pixels. `radius` is the light's
    /// distance from the wall.
    struct Glow {
        let center: CGPoint
        let radius: CGFloat
    }

    /// The fraction of each side of a shadow texture that fades out.
    static let shadowSoftness: Float = 0.18

    /// Returns the wall image lit for the resting wall and for the detail view.
    /// Illuminance from a point light falls off as (d² / (d² + r²))^1.5 on a wall `d` away,
    /// at distance `r` from the point nearest the light.
    static func render(
        _ image: CGImage, resting: Lighting, pool: Glow, wash: Glow, detailTop: SIMD3<Float>,
        detailBottom: SIMD3<Float>
    ) -> (resting: CGImage, detail: CGImage)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let source = bitmap(width: width, height: height),
            let restingContext = bitmap(width: width, height: height),
            let detailContext = bitmap(width: width, height: height)
        else { return nil }
        source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let input = source.data?.assumingMemoryBound(to: UInt8.self),
            let restingOutput = restingContext.data?.assumingMemoryBound(to: UInt8.self),
            let detailOutput = detailContext.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let rowBytes = source.bytesPerRow
        func falloff(_ glow: Glow, _ dx: Float, _ dy: Float) -> Float {
            let d2 = Float(glow.radius * glow.radius)
            let ratio = d2 / (d2 + dx * dx + dy * dy)
            return ratio * ratio.squareRoot()
        }
        // ponytail: one pass on the CPU when the image or framing changes; move it off the
        // main actor if it ever shows up as a hitch.
        for y in 0..<height {
            let detail =
                detailTop + (detailBottom - detailTop) * (Float(y) / Float(max(1, height - 1)))
            let poolY = Float(y) - Float(pool.center.y)
            let washY = Float(y) - Float(wash.center.y)
            for x in 0..<width {
                let lighting =
                    resting.base
                    + resting.pool * falloff(pool, Float(x) - Float(pool.center.x), poolY)
                    + resting.wash * falloff(wash, Float(x) - Float(wash.center.x), washY)
                let offset = y * rowBytes + x * 4
                for channel in 0..<3 {
                    let value = Float(input[offset + channel])
                    restingOutput[offset + channel] = UInt8(
                        min(255, value * lighting[channel] + 0.5))
                    detailOutput[offset + channel] = UInt8(min(255, value * detail[channel] + 0.5))
                }
                restingOutput[offset + 3] = 255
                detailOutput[offset + 3] = 255
            }
        }
        guard let restingImage = restingContext.makeImage(),
            let detailImage = detailContext.makeImage()
        else { return nil }
        return (restingImage, detailImage)
    }

    /// A black shadow whose alpha fades over `shadowSoftness` of each side. With
    /// `fadesDown`, it also fades from its top edge to its bottom edge, like a shadow cast
    /// from just above.
    static func makeShadow(fadesDown: Bool) -> CGImage? {
        let size = 64
        guard let context = bitmap(width: size, height: size),
            let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let soft = shadowSoftness
        func edge(_ value: Float) -> Float {
            // Distance into the texture from the nearer side, relative to the soft margin.
            let t = min(1, max(0, min(value, 1 - value) / soft))
            return t * t * (3 - 2 * t)
        }
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size)
                let v = (Float(y) + 0.5) / Float(size)
                var alpha = edge(u)
                if fadesDown {
                    // Row 0 is the top of the image.
                    alpha *= (1 - v) * (1 - v)
                } else {
                    alpha *= edge(v)
                }
                // Premultiplied black.
                let offset = y * context.bytesPerRow + x * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = UInt8(alpha * 255)
            }
        }
        return context.makeImage()
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// Draws the page-edge texture that every book shares.
enum BookWallPageTexture {
    static let paperColor = UIColor(red: 0.93, green: 0.90, blue: 0.82, alpha: 1)

    /// Horizontal lines are leaves; the plane's height runs through the book's thickness.
    /// Darkening at both ends suggests the boards' shade on the outer leaves.
    static func make() -> CGImage? {
        let size = CGSize(width: 64, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let cg = context.cgContext
                paperColor.setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                // A fixed seed keeps every preparation identical. Low contrast avoids
                // shimmering when mipmaps shrink the leaves below one pixel.
                var seed: UInt32 = 0x9E37_79B9
                for row in 0..<Int(size.height) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let shade = CGFloat(seed >> 24) / 255 * 0.09
                    UIColor(red: 0.45, green: 0.38, blue: 0.28, alpha: shade).setFill()
                    cg.fill(CGRect(x: 0, y: CGFloat(row), width: size.width, height: 1))
                }
                let edge = size.height * 0.08
                for (start, end) in [(0, edge), (size.height, size.height - edge)] {
                    guard
                        let gradient = CGGradient(
                            colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [
                                UIColor(white: 0, alpha: 0.22).cgColor,
                                UIColor(white: 0, alpha: 0).cgColor,
                            ] as CFArray, locations: [0, 1])
                    else { continue }
                    cg.drawLinearGradient(
                        gradient, start: CGPoint(x: 0, y: start), end: CGPoint(x: 0, y: end),
                        options: [])
                }
            }
            .cgImage
    }
}

/// Draws shelf-front lettering at a fixed density, so every label shares one letter size and
/// its plane width follows its text.
enum BookWallShelfLabel {
    /// A drawn label, uploaded for the renderer.
    struct Prepared: @unchecked Sendable {
        let texture: any MTLTexture
        /// The label's width in scene units on a front `BookWallScene.minimumShelfThickness`
        /// tall.
        let width: Float

        /// Uploads `image`, or returns `nil` when its texture can't be made.
        init?(_ image: CGImage) {
            guard let texture = BookMetalDevice.shared?.makeTexture(image, mipmapped: true)
            else { return nil }
            self.texture = texture
            width = Float(CGFloat(image.width) / BookWallShelfLabel.pixelsPerUnit)
        }
    }

    /// Label height in scene units on a front `BookWallScene.minimumShelfThickness` tall. The
    /// texture is drawn at this height; a taller front scales the label up.
    static let height: Float = 0.38
    /// The lettering's point size as a share of the label's height.
    static let letterShare: Float = 0.74
    static let maximumWidth: Float = 12
    private static let pixelsPerUnit: CGFloat = 128
    /// Warm gilt, like lettering stamped into a wooden shelf.
    private static let giltColor = StyleColor(red: 0.95, green: 0.86, blue: 0.66)
    private static let gilt = giltColor.uiColor
    /// The shelf's wood, which the label is lettered on.
    static let wood = StyleColor(red: 0.32, green: 0.21, blue: 0.14)

    /// Letters `text`, which names `book` when it has one, in gilt.
    static func make(_ text: String, book: Book? = nil, style: AppFontStyle) -> CGImage? {
        let pixelHeight = (CGFloat(height) * pixelsPerUnit).rounded()
        // The line nearly fills the label. `BookWallScene.shelfThickness(for:)` sizes the shelf
        // front, and the label with it, so the lettering shows at 23 points or larger.
        let font = style.uiFont(size: pixelHeight * CGFloat(letterShare))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        func attributes(_ color: UIColor) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        }
        let maximum = CGFloat(maximumWidth) * pixelsPerUnit
        let measured = (text as NSString).size(withAttributes: attributes(gilt)).width
        let size = CGSize(width: min(maximum, measured.rounded(.up) + 8), height: pixelHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in
                let line = (pixelHeight - font.lineHeight) / 2
                let rect = CGRect(x: 0, y: line, width: size.width, height: font.lineHeight)
                // A dark edge above the letters reads as a shallow engraving.
                (text as NSString)
                    .draw(
                        in: rect.offsetBy(dx: 0, dy: -1),
                        withAttributes: attributes(UIColor(white: 0, alpha: 0.55)))
                HouseOfLeaves.attributed(
                    text, of: book, attributes: attributes(gilt),
                    lettering: HouseOfLeaves.lettering(on: wood, ink: giltColor)
                )
                .draw(in: rect)
            }
            .cgImage
    }
}

/// Draws a Book Wall spine: flat cloth, the lettering, and the cover's fold onto the spine,
/// as the iPhone companion's flat cloth spine draws them.
enum BookWallSpineTexture {
    /// Spine texture pixels per point at the wall's viewing scale (`slot.pointsPerUnit`), on
    /// both axes, so glyphs keep their proportions on thick books. At twice the screen's
    /// density, the resting wall samples mip level 1, about one texel per 1080p screen point,
    /// and a book brought closer in its detail pose samples the sharper level 0.
    static let pixelsPerPoint: CGFloat = 2
    /// The share of the spine's thickness that the cover's fold covers from the front joint.
    /// It fades out within the lettering's margin and the headroom above its first line's
    /// letters, so the lettering's contrast check against the flat cloth still holds.
    static let foldShare: CGFloat = 0.09

    /// Draws `slot`'s lettering on a transparent image the size of the spine plane
    /// (`spineWallWidth` by `spineWallHeight`), lying flat with the head on the left and the
    /// front board's edge at the top, as the shelf's `SpineView` draws it before turning it
    /// upright: the title at the head end, the author at the tail end, and the format icon in
    /// the room at the tail, turned as the shelf's upright icon turns when its spine lies flat.
    ///
    /// `slot.lettering` was measured in points at the wall's viewing scale, so the image
    /// draws in those points, scaled to `pixelsPerPoint`, and every glyph and margin keeps the
    /// place the rule measured for it. `fontStyle` sets the icon's weight, as `appFont` does on
    /// the shelf.
    static func make(
        for slot: BookWallLayout.Slot, style: BookWallLocalSpine.Style,
        fontStyle: AppFontStyle = .serif
    ) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let points = CGFloat(slot.pointsPerUnit)
        let size = CGSize(
            width: (CGFloat(slot.spineWallWidth) * points * pixelsPerPoint).rounded(),
            height: (CGFloat(slot.spineWallHeight) * points * pixelsPerPoint).rounded())
        let length = CGFloat(slot.spineWallWidth) * points
        let thickness = CGFloat(slot.spineWallHeight) * points
        let image = UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                context.cgContext.scaleBy(x: size.width / length, y: size.height / thickness)
                draw(slot.lettering, of: slot.book, style: style, thickness: thickness)
                if slot.book.format != nil {
                    drawFormatIcon(
                        for: slot.book, ink: style.foreground, fontStyle: fontStyle,
                        pixelsPerPoint: size.height / thickness,
                        center: CGPoint(
                            x: SpineTextMetrics.formatIconCenter(
                                for: slot.book, length: length, thickness: thickness),
                            y: thickness / 2))
                }
            }
        return image.cgImage
    }

    /// Draws `lettering` in a row `thickness` points across, as `SpineView`'s lettering row
    /// lays it out: each block centered across the row, the title's lines from the head-end
    /// inset at their measured pitch and shift, and the author's lines centered on each other
    /// with the widest at the tail-end inset. An author that doesn't fit whole truncates at
    /// its tail.
    private static func draw(
        _ lettering: SpineLettering, of book: Book, style: BookWallLocalSpine.Style,
        thickness: CGFloat
    ) {
        let ink = style.foreground.uiColor
        let titleFont = style.typography.font(size: lettering.titleSize)
        let titleLines = lettering.title.components(separatedBy: "\n")
        // Each line's box is centered on its pitch, then shifted, as `SpineView` frames it.
        var y =
            (thickness - CGFloat(titleLines.count) * lettering.titlePitch) / 2
            + (lettering.titlePitch - titleFont.lineHeight) / 2 + lettering.titleShift
        for line in titleLines {
            // A spine letters "house" in the blue alone, as `SpineView` does, even where dark
            // ink on a light spine would otherwise glow.
            HouseOfLeaves.attributed(
                line, of: book, attributes: [.font: titleFont, .foregroundColor: ink],
                lettering: HouseOfLeaves.Lettering(
                    blue: HouseOfLeaves.lettering(on: style.background, ink: style.foreground).blue,
                    glows: false)
            )
            .draw(at: CGPoint(x: lettering.inset, y: y))
            y += lettering.titlePitch
        }
        let authorFont = style.typography.font(size: lettering.authorSize)
        let tail = lettering.length - lettering.inset
        guard lettering.authorFits else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = .right
            (lettering.author as NSString)
                .draw(
                    in: CGRect(
                        x: tail - lettering.authorWidth,
                        y: (thickness - authorFont.lineHeight) / 2, width: lettering.authorWidth,
                        height: authorFont.lineHeight),
                    withAttributes: [
                        .font: authorFont, .foregroundColor: ink, .paragraphStyle: paragraph,
                    ])
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: authorFont, .foregroundColor: ink]
        let authorLines = lettering.author.components(separatedBy: "\n")
        y = (thickness - CGFloat(authorLines.count) * authorFont.lineHeight) / 2
        for line in authorLines {
            let width = (line as NSString).size(withAttributes: attributes).width
            (line as NSString)
                .draw(
                    at: CGPoint(x: tail - (lettering.authorWidth + width) / 2, y: y),
                    withAttributes: attributes)
            y += authorFont.lineHeight
        }
    }

    /// Draws `book`'s format symbol centered on `center`, at the shelf's icon size, in the
    /// hierarchical rendering `SpineView` draws it in, so the Ebook symbol's screen keeps its
    /// faint fill. The shelf draws the symbol upright on a standing spine; this spine lies with
    /// its head on the left, so the symbol turns a quarter turn counterclockwise, its top toward
    /// the head. The context is scaled to points; the symbol is made at the texture's
    /// `pixelsPerPoint` and drawn unscaled, since a symbol drawn into a scaled context comes out
    /// as a magnified bitmap.
    private static func drawFormatIcon(
        for book: Book, ink: StyleColor, fontStyle: AppFontStyle, pixelsPerPoint: CGFloat,
        center: CGPoint
    ) {
        let configuration =
            UIImage.SymbolConfiguration(
                font: fontStyle.uiFont(size: SpineTextMetrics.formatIconSize * pixelsPerPoint)
            )
            .applying(UIImage.SymbolConfiguration(hierarchicalColor: ink.uiColor))
        guard
            let symbol = UIImage(systemName: book.formatSymbol, withConfiguration: configuration),
            let context = UIGraphicsGetCurrentContext()
        else { return }
        context.saveGState()
        context.scaleBy(x: 1 / pixelsPerPoint, y: 1 / pixelsPerPoint)
        context.translateBy(x: center.x * pixelsPerPoint, y: center.y * pixelsPerPoint)
        context.rotate(by: -.pi / 2)
        symbol.draw(
            in: CGRect(
                x: -symbol.size.width / 2, y: -symbol.size.height / 2,
                width: symbol.size.width, height: symbol.size.height))
        context.restoreGState()
    }

    /// Composites the lettering over flat cloth, for an opaque, lit spine surface: the cloth's
    /// relief along the boards' edges and, on a thick book, blind-stamped bands, as `SpineView`
    /// draws them; then the lettering; then the cover's `edgeColors` (head to tail) folding
    /// over the front joint at half strength. Lit lettering reads about 10% dimmer than unlit
    /// lettering, so a light additive pass brightens it.
    static func filled(
        _ lettering: CGImage, book: Book, cloth: StyleColor, edgeColors: [StyleColor]
    ) -> CGImage? {
        let size = CGSize(width: lettering.width, height: lettering.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let cg = context.cgContext
                cloth.uiColor.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let shade = SpineView.relief(on: cloth)
                drawGradient(
                    [
                        (UIColor(white: 0, alpha: shade), 0), (.clear, 0.05), (.clear, 0.95),
                        (UIColor(white: 0, alpha: shade * 0.65), 1),
                    ],
                    from: .zero, to: CGPoint(x: 0, y: size.height), in: cg)
                if SpineView.stamps(book) {
                    let band = SpineView.bands(length: size.width, thickness: size.height)
                    let shades = SpineView.bandShades(on: cloth)
                    let lines = CGRect(
                        x: 0, y: size.height * 0.1, width: band.line,
                        height: size.height * 0.8)
                    for slot in [band.inset, size.width - band.inset - band.slot] {
                        // The shadow is on the head's side, the highlight on the tail's.
                        let x = slot + (band.slot - band.line * 2) / 2
                        UIColor(white: 0, alpha: shades.shadow).setFill()
                        cg.fill(lines.offsetBy(dx: x, dy: 0))
                        UIColor(white: 1, alpha: shades.light).setFill()
                        cg.fill(lines.offsetBy(dx: x + band.line, dy: 0))
                    }
                }
                let image = UIImage(cgImage: lettering)
                image.draw(in: CGRect(origin: .zero, size: size))
                image.draw(
                    in: CGRect(origin: .zero, size: size), blendMode: .plusLighter, alpha: 0.1)
                drawFold(
                    edgeColors, opacity: 0.5,
                    in: CGRect(x: 0, y: 0, width: size.width, height: size.height * foldShare),
                    jointAtLeft: false, context: cg)
            }
        return image.cgImage
    }

    /// A spine texture's full mip chain, each level drawn by Core Graphics from the level above
    /// at half its size.
    ///
    /// Mip levels the GPU generates for an sRGB texture average in linear light, which thins
    /// dark lettering on light cloth and thickens light lettering on dark cloth; at Book Wall's
    /// viewing scale, dark SemiBold lettering read like a light face. Core Graphics averages the
    /// encoded values, as its text antialiasing does, so each level keeps the lettering's weight.
    /// `BookWallRasterizer` draws the chain off the main actor.
    struct Mips: Sendable {
        let width: Int
        let height: Int
        /// Each level's premultiplied RGBA bytes in Display P3, rows packed, largest first.
        let levels: [Data]

        /// Draws `spine`'s chain down to one pixel, or returns `nil` when a level can't be
        /// drawn.
        init?(_ spine: CGImage) {
            guard let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
            var levels: [Data] = []
            var source = spine
            var (width, height) = (spine.width, spine.height)
            while true {
                var data = Data(count: width * height * 4)
                let drawn = data.withUnsafeMutableBytes { buffer -> CGImage? in
                    guard
                        let context = CGContext(
                            data: buffer.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return nil }
                    context.interpolationQuality = .high
                    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return context.makeImage()
                }
                guard let drawn else { return nil }
                levels.append(data)
                guard width > 1 || height > 1 else { break }
                (source, width, height) = (drawn, max(1, width / 2), max(1, height / 2))
            }
            (self.width, self.height, self.levels) = (spine.width, spine.height, levels)
        }
    }

    /// Draws `colors`, spread evenly along the joint side of `rect` (its top edge, or its left
    /// edge when `jointAtLeft` is true), fading from `opacity` at the joint to clear at the far
    /// side with a smoothstep ease, as the companion's fold does.
    static func drawFold(
        _ colors: [StyleColor], opacity: CGFloat, in rect: CGRect, jointAtLeft: Bool,
        context: CGContext
    ) {
        guard !colors.isEmpty, rect.width > 0, rect.height > 0 else { return }
        // A gradient needs two stops; one color fills the joint evenly.
        let colors = colors.count == 1 ? colors + colors : colors
        let count = CGFloat(colors.count - 1)
        let along = colors.enumerated().map { ($1.uiColor, CGFloat($0) / count) }
        let fade = stride(from: CGFloat(0), through: 1, by: 0.125)
            .map { share in
                (UIColor(white: 0, alpha: opacity * (1 - share * share * (3 - 2 * share))), share)
            }
        let corner = CGPoint(x: rect.minX, y: rect.minY)
        let width = CGPoint(x: rect.maxX, y: rect.minY)
        let height = CGPoint(x: rect.minX, y: rect.maxY)
        context.saveGState()
        context.clip(to: rect)
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        drawGradient(along, from: corner, to: jointAtLeft ? height : width, in: context)
        // Keeps the colors only as far as the fade's alpha.
        context.setBlendMode(.destinationIn)
        drawGradient(fade, from: corner, to: jointAtLeft ? width : height, in: context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Fills the current clip with a linear gradient through `stops` (color, location).
    static func drawGradient(
        _ stops: [(UIColor, CGFloat)], from start: CGPoint, to end: CGPoint, in context: CGContext
    ) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: stops.map(\.0.cgColor) as CFArray, locations: stops.map(\.1))
        else { return }
        context.drawLinearGradient(
            gradient, start: start, end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
