import Combine
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

/// Owns the 3D scene across detail presentations so returning does not replay the fall.
@MainActor
final class BookWallScene {
    let hostConfiguration = BookWallHostConfiguration()
    private weak var renderHost: (any BookWallRenderHost)?
    private var hostViewportSize = CGSize.zero
    private(set) var environmentResource: EnvironmentResource?
    var ambientExponent: Float {
        Self.restingAmbientExponent + Self.detailAmbientExponent * detailLightLevel
    }
    private var renderBounds: CGRect { CGRect(origin: .zero, size: hostViewportSize) }

    private static let coverWrapThickness = BookWallLayout.coverWrapThickness
    /// Vertical field of view, like a 50mm lens: long enough that books keep their shape as
    /// they move toward the camera or across the frame. Wider angles stretch the page edges.
    private static let fieldOfView: Float = 30
    private static let coverFaceGap: Float = 0.0005
    private static let coverSurfaceOffset = coverWrapThickness + coverFaceGap
    private static let fallGravity: Float = 22
    private static let minimumDropSpacing = 0.10
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
    /// stage spotlight read as the key light.
    private static let detailAmbientExponent: Float = -0.8
    /// Environment-light exponent while the wall rests; calibrates the lit backdrop against
    /// the SwiftUI background shown in other views.
    private static let restingAmbientExponent: Float = 0
    // Lighting uses point lights and one directional light. `SpotLight` produced no visible
    // light on Apple TV at any intensity, cone, or orientation, while point lights at the
    // same positions did. Point-light intensity is lumens emitted in every direction and
    // scene units are meters, so illuminance is about lumens / (4π × distance²).

    /// Direction from the detail pose toward its key light: above, right, and in front.
    /// The cover catches more light than the turned spine, and the shadow falls behind the
    /// book, down and to the left.
    private static let detailLightDirection = simd_normalize(SIMD3<Float>(1.2, 1.8, 5))
    /// Close enough that brightness falls off across the flight path and the wall behind.
    private static let detailLightDistance: Float = 3.2
    private static let detailLightIntensity: Float = 300_000
    /// A dim, steep directional light adds top light from above, in front, and to the right.
    /// It casts no shadow: a shadow map redraws the scene and samples it on every lit pixel.
    /// Soft shadow planes stand in for shadows (`updateDetailShadow` and
    /// `showContactShadow`).
    private static let topLightDirection = simd_normalize(SIMD3<Float>(0.8, 2.4, 3.2))
    private static let restingTopIntensity: Float = 200
    private static let detailTopIntensity: Float = 400
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
    /// How far focus pulls a book out of its stack, enough to expose its page edges and
    /// cast a shadow on the spine below.
    private static let focusPullOut: Float = 0.35
    private static let pullOutDuration: Float = 0.2
    /// The shelf light's offset from the stacks' center. Its falloff lights the middle
    /// stacks most and leaves a round pool on the wall behind them.
    private static let shelfLightOffset = SIMD3<Float>(0, 1.5, 4.5)
    private static let shelfLightIntensity: Float = 400_000
    /// A light hidden just behind the stacks catches the tops and edges of the upper books.
    /// Its glow on the wall is baked into the backdrop (`restingWallLight`).
    private static let poolLightIntensity: Float = 700_000
    /// The wall's lighting is baked into the backdrop image rather than lit live; a
    /// full-screen lit surface cost more GPU time than the rest of the scene. The factors
    /// scale each color channel of the wall image, which is shown without tone mapping.
    /// They were fitted to Simulator captures of the live-lit wall: a warm point light 3.3 units in front of the wall
    /// behind the stacks (the pool), the shelf light's faint wash, and the environment.
    private static let restingWallLight = BookWallBackdropBake.Lighting(
        base: [0.368, 0.331, 0.279], pool: [0.840, 0.680, 0.409], wash: [0.200, 0.156, 0.128])
    /// The pool is centered this far above the stacks' center, with the falloff of a point
    /// light `poolLightDistance` units from the wall. The wash is centered far above the frame.
    private static let poolHeightOffset: Float = 0.5
    private static let poolLightDistance: Float = 3.3
    private static let washHeightOffset: Float = 11.9
    private static let washLightDistance: Float = 33
    /// With details open, the dimmed environment and the distant key light leave the wall
    /// nearly flat, slightly darker toward the bottom. Fitted like `restingWallLight`.
    static let detailWallTop: SIMD3<Float> = [0.403, 0.348, 0.311]
    private static let detailWallBottom: SIMD3<Float> = [0.353, 0.292, 0.253]
    /// Space between the shelf's back and the backdrop. The baked lighting was fitted at
    /// this distance.
    private static let backdropGap: Float = 3.5
    private static let warmLight = UIColor(red: 1, green: 0.87, blue: 0.7, alpha: 1)
    /// Front-face height of the shelf, deep enough to carry a readable label.
    private static let shelfThickness: Float = 0.5
    /// The joint's distance from the spine edge and the width of its shading.
    private static let hingeInset: Float = 0.085
    private static let hingeWidth: Float = 0.06
    private static let hingeTexture = BookWallPageTexture.makeHinge()
        .flatMap {
            try? TextureResource(image: $0, options: .init(semantic: .color))
        }
    private static let softShadowTexture = BookWallBackdropBake.makeShadow(fadesDown: false)
        .flatMap { try? TextureResource(image: $0, options: .init(semantic: .color)) }
    private static let contactShadowTexture = BookWallBackdropBake.makeShadow(fadesDown: true)
        .flatMap { try? TextureResource(image: $0, options: .init(semantic: .color)) }
    /// Diagnostic: keeps the scene's light count constant so opening a book adds no light.
    private static let keepsDetailLightEnabled = PerformanceDiagnostics.isolates(
        "wall-warm-light")
    private static let idleVerticalPeriod: Float = 40
    private static let idleHorizontalPeriod: Float = 48
    private static let idleSwayPeriod: Float = 60
    private static let idleRampDuration: Float = 4
    private static let flightDuration: TimeInterval = 1.8
    private static let idleReturnFraction: Float = 0.35

    let root = AnchorEntity(world: .zero)
    let camera = PerspectiveCamera()
    private let detailLight = PointLight()
    private let topLight = DirectionalLight()
    private let shelfLight = PointLight()
    private let poolLight = PointLight()
    /// A red bookmark ribbon hanging from the focused book. Its segments are pooled so
    /// focus changes only reposition entities.
    private let ribbon = Entity()
    private var ribbonSegments: [ModelEntity] = []
    private var ribbonSubscription: Cancellable?
    private var ribbonElapsed: Float = 0
    private var ribbonCount = 0
    private var ribbonVisible = false
    private let shelfLabel = ModelEntity()
    private var labels: [Int: BookWallShelfLabel.Prepared] = [:]
    private var hintLabel: BookWallShelfLabel.Prepared?
    private let backdrop = ModelEntity()
    /// The detail wall image, in front of the resting one; it fades in as details open.
    private let detailBackdrop = ModelEntity()
    private var backdropDistance: Float = 0
    private var wallImage: CGImage?
    private var bakedWallKey: WallBakeKey?
    /// A soft shadow on the wall behind the detail book, and one under a pulled-out book.
    private let detailShadow = ModelEntity()
    private var detailShadowCorners: (id: Int, corners: [SIMD3<Float>])?
    private let contactShadow = ModelEntity()
    private var detailLightLevel: Float = 0
    private var shelf: ModelEntity?
    private var collisionSubscription: Cancellable?
    private var continuingCollisionSubscription: Cancellable?
    private var layout = BookWallLayout(books: [])
    private var signature: [Book] = []
    private var preparedBodies: [Int: ModelEntity] = [:]
    private var preparedWallID: UUID?
    private var bodies: [Int: ModelEntity] = [:]
    private var restingTransforms: [Int: Transform] = [:]
    private struct FlightFrame {
        var pose: Transform
        var cameraDepth: Float
    }

    private struct Flight {
        let id: UUID
        let body: ModelEntity
        let frames: [FlightFrame]
        let duration: TimeInterval
        let initialLightLevel: Float
        let targetLightLevel: Float
        let completion: CheckedContinuation<Bool, Never>
        var elapsed: TimeInterval = 0
    }

    private var flightFrames: [FlightFrame] = []
    private var flight: Flight?
    private var motionSubscription: Cancellable?
    private var idlePose: Transform?
    private var idleElapsed: TimeInterval = 0
    private var idleAmplitude = SIMD2<Float>.zero
    private var wallCameraDepth: Float = 9.5
    private var viewportSize = CGSize.zero
    private var dropHeight: Float = 3
    private var dropTask: Task<Void, Never>?
    private var landedIDs: Set<Int> = []
    private var isSettled = false
    /// Set by every change made from outside the scene; cleared once a frame shows it.
    private var hasUndrawnChange = true
    /// Keeps drawing until RealityKit's transform animations started by `highlight` finish.
    private var animatingUntil: CFTimeInterval = 0
    private var selectedID: Int?
    private var isFlyingOut = false
    private var onFocusFrames: ((_ frames: [Int: CGRect], _ settled: Bool) -> Void)?
    #if BOOKWORMS_DIAGNOSTICS
        private var motionMetrics = BookWallMotionMetrics()
    #endif

    init() {
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = [0, -Self.fallGravity, 0]
        root.components.set(simulation)
        camera.position = [0, 0, 8.4]
        camera.camera = PerspectiveCameraComponent(
            fieldOfViewInDegrees: Self.fieldOfView, fieldOfViewOrientation: .vertical)
        root.addChild(camera)
        // The detail key light stays fixed in the world once placed for a detail pose, so the
        // flying book moves into its light instead of carrying its lighting along.
        detailLight.light = PointLightComponent(
            color: UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1), intensity: 0,
            attenuationRadius: 20)
        detailLight.isEnabled = Self.keepsDetailLightEnabled
        root.addChild(detailLight)
        topLight.light = DirectionalLightComponent(
            color: .white, intensity: Self.restingTopIntensity)
        topLight.look(at: .zero, from: Self.topLightDirection, relativeTo: nil)
        root.addChild(topLight)
        // A room lit mainly by one warm light in front of the stacks. The dim environment
        // keeps the outer stacks readable while the middle ones sit in the brightest light.
        shelfLight.light = PointLightComponent(
            color: Self.warmLight, intensity: Self.shelfLightIntensity, attenuationRadius: 30)
        root.addChild(shelfLight)
        poolLight.light = PointLightComponent(
            color: Self.warmLight, intensity: Self.poolLightIntensity, attenuationRadius: 20)
        root.addChild(poolLight)
        if PerformanceDiagnostics.isolates("wall-no-fill-lights") {
            shelfLight.isEnabled = false
            poolLight.isEnabled = false
        }
        shelfLabel.name = "book-wall-shelf-label"
        // The backdrops show the app's wall background with its lighting baked in. As camera
        // children scaled with their distance, they frame exactly like the SwiftUI background.
        backdrop.name = "book-wall-backdrop"
        camera.addChild(backdrop)
        detailBackdrop.isEnabled = false
        camera.addChild(detailBackdrop)
        detailShadow.isEnabled = false
        camera.addChild(detailShadow)
        // Shadow planes only darken what is behind them, so they never write depth.
        if let shadow = Self.softShadowTexture {
            var material = UnlitMaterial(texture: shadow)
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            material.writesDepth = false
            detailShadow.model = ModelComponent(mesh: Self.unitPlane, materials: [material])
        }
        if let shadow = Self.contactShadowTexture {
            var material = UnlitMaterial(texture: shadow)
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            material.writesDepth = false
            contactShadow.model = ModelComponent(mesh: Self.unitPlane, materials: [material])
        }
        // Transparent planes are otherwise sorted by their centers' distance. While the book
        // flies off-center, the drop shadow's center is farther away, so it drew before the
        // fading detail wall and hid that wall inside a lighter rectangle.
        let wallPlanes = ModelSortGroup()
        for (order, plane) in [backdrop, detailBackdrop, detailShadow].enumerated() {
            plane.components.set(ModelSortGroupComponent(group: wallPlanes, order: Int32(order)))
        }
        contactShadow.components.set(OpacityComponent(opacity: 0))
        ribbon.addChild(contactShadow)
        let disablesEnvironmentLighting = PerformanceDiagnostics.isolates("wall-no-ibl")
        if disablesEnvironmentLighting {
            // A zero weight disables the environment contribution for all root descendants;
            // a nil renderer resource alone does not specify the fallback lighting behavior.
            root.components.set(
                EnvironmentLightingConfigurationComponent(environmentLightingWeight: 0))
        }
        // A soft studio environment replaces the default lighting. It varies only from top to
        // bottom, so its orientation cannot matter.
        if !disablesEnvironmentLighting, let image = BookWallPageTexture.makeStudioEnvironment(),
            let environment = try? EnvironmentResource(equirectangular: image)
        {
            environmentResource = environment
        }
    }

    /// Attaches before preparation so physics and motion subscribe to the visible host.
    func attachHost(_ host: any BookWallRenderHost) {
        hasUndrawnChange = true
        if let current = renderHost, current === host { return }
        collisionSubscription?.cancel()
        continuingCollisionSubscription?.cancel()
        renderHost = host
        host.setAmbientExponent(ambientExponent)
        if !signature.isEmpty && !isSettled { observeLandings() }
        if flight != nil || idlePose != nil {
            motionSubscription?.cancel()
            motionSubscription = nil
            subscribeToMotion()
        }
        Task { @MainActor [weak self, weak host] in
            guard let self, let host, let current = renderHost, current === host else { return }
            refreshHostFocusFrames()
        }
    }

    /// Restores hit targets after the host attaches to an already settled wall.
    func refreshHostFocusFrames() {
        publishFocusFrames()
    }

    func detachHost(_ host: any BookWallRenderHost) {
        guard let current = renderHost, current === host else { return }
        cancelTransition()
        collisionSubscription?.cancel()
        continuingCollisionSubscription?.cancel()
        collisionSubscription = nil
        continuingCollisionSubscription = nil
        renderHost = nil
    }

    private func subscribe<E: RealityKit.Event>(to event: E.Type, handler: @escaping (E) -> Void)
        -> Cancellable?
    {
        renderHost?.subscribe(to: event, handler: handler)
    }

    /// Projects into full-screen points, independently of the renderer's pixel dimensions.
    func projectWithCamera(_ point: SIMD3<Float>) -> CGPoint? {
        project(point, cameraDepth: camera.position.z)
    }

    func updateHostViewport(size: CGSize) {
        hasUndrawnChange = true
        guard size.width > 0, size.height > 0 else { return }
        hostViewportSize = size
        updateSceneViewport()
    }

    func configure(
        prepared: BookWallPreparedWall, reduceMotion: Bool,
        onFocusFrames: @escaping (_ frames: [Int: CGRect], _ settled: Bool) -> Void
    ) {
        hasUndrawnChange = true
        self.onFocusFrames = onFocusFrames
        let books = prepared.books
        guard books != signature || prepared.id != preparedWallID else {
            publishFocusFrames()
            return
        }
        dropTask?.cancel()
        cancelTransition()
        signature = books
        preparedWallID = prepared.id
        layout = prepared.layout
        preparedBodies = prepared.bodies
        labels = prepared.labels
        hintLabel = prepared.hint
        dropHeight = max(
            2.5, (layout.slots.map { $0.restingY + $0.spineThickness / 2 }.max() ?? 0) + 1.4)
        viewportSize = .zero
        for body in bodies.values { body.removeFromParent() }
        for child in root.children
        where child !== camera && child !== detailLight
            && child !== topLight && child !== shelfLight && child !== poolLight
            && child !== ribbon
        {
            child.removeFromParent()
        }
        hideRibbon()
        detailShadowCorners = nil
        shelf = nil
        bodies.removeAll()
        restingTransforms.removeAll()
        flightFrames.removeAll()
        landedIDs.removeAll()
        isSettled = false
        selectedID = nil
        isFlyingOut = false
        guard !books.isEmpty else {
            onFocusFrames([:], true)
            return
        }
        updateSceneViewport()
        installShelf()
        startFall(reduceMotion: reduceMotion)
    }

    /// Reuses prepared hardcover models and textures for another fall.
    @discardableResult
    func replayFall(reduceMotion: Bool) -> Bool {
        hasUndrawnChange = true
        guard isSettled, !isFlyingOut, !bodies.isEmpty else { return false }
        dropTask?.cancel()
        preparedBodies = bodies
        for body in bodies.values { body.removeFromParent() }
        bodies.removeAll()
        restingTransforms.removeAll()
        flightFrames.removeAll()
        landedIDs.removeAll()
        selectedID = nil
        hideRibbon()
        isSettled = false
        startFall(reduceMotion: reduceMotion)
        return true
    }

    private func startFall(reduceMotion: Bool) {
        collisionSubscription?.cancel()
        continuingCollisionSubscription?.cancel()
        if !reduceMotion { observeLandings() }
        let slots = layout.slots
        let thickestBook = slots.map(\.collisionThickness).max() ?? 0
        // Leave enough vertical separation before another book enters the same column.
        let distanceBetweenBooks = Double(thickestBook + 0.15)
        let clearanceTime = sqrt(2 * distanceBetweenBooks / Double(Self.fallGravity))
        let columnSpacing = clearanceTime / Double(layout.columns)
        let spacing = max(Self.minimumDropSpacing, columnSpacing)
        dropTask = Task { [weak self] in
            guard let self else { return }
            for (index, slot) in slots.enumerated() {
                guard !Task.isCancelled else { return }
                if !reduceMotion, index > 0 {
                    try? await Task.sleep(for: .seconds(spacing))
                    guard !Task.isCancelled else { return }
                }
                addBook(slot, falls: !reduceMotion)
            }
            settle()
        }
    }

    private func observeLandings() {
        collisionSubscription = subscribe(to: CollisionEvents.Began.self) {
            [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleLanding(event.entityA, event.entityB, contactY: event.position.y)
            }
        }
        // Two falling books can touch before the lower one lands. Revisit that contact
        // after its support becomes stationary instead of waiting for another impact.
        continuingCollisionSubscription = subscribe(to: CollisionEvents.Updated.self) {
            [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleLanding(event.entityA, event.entityB, contactY: event.position.y)
            }
        }
    }

    private func handleLanding(_ first: Entity, _ second: Entity, contactY: Float) {
        land(first, on: second, contactY: contactY)
        land(second, on: first, contactY: contactY)
        settle()
    }

    private func land(_ fallingEntity: Entity, on supportEntity: Entity, contactY: Float) {
        guard !isSettled,
            let (id, body) = bodies.first(where: { $0.value === fallingEntity }),
            !landedIDs.contains(id),
            let slot = layout.slots.first(where: { $0.book.id == id }),
            var physics = body.physicsBody,
            physics.mode == .dynamic
        else { return }

        let supportTop: Float
        if supportEntity === shelf {
            supportTop = BookWallLayout.floorY
        } else if let (supportID, supportBody) = bodies.first(where: {
            $0.value === supportEntity
        }),
            let supportSlot = layout.slots.first(where: { $0.book.id == supportID }),
            supportSlot.column == slot.column, supportSlot.row < slot.row,
            supportBody.physicsBody?.mode == .kinematic
        {
            supportTop = supportBody.position.y + supportSlot.collisionThickness / 2
        } else {
            return
        }

        let landingY = supportTop + slot.collisionThickness / 2
        guard abs(contactY - supportTop) < max(0.12, slot.collisionThickness * 0.25),
            body.position.y < landingY + 0.8
        else { return }
        // Stop the downward momentum at a supported contact. Later impacts should not
        // throw books that have already come to rest back into the air.
        body.position.y = landingY
        body.components.set(PhysicsMotionComponent())
        physics.mode = .kinematic
        physics.isContinuousCollisionDetectionEnabled = false
        body.physicsBody = physics
        landedIDs.insert(id)
    }

    func settle() {
        hasUndrawnChange = true
        guard !isSettled, bodies.count == layout.slots.count,
            landedIDs.count == layout.slots.count
        else { return }
        dropTask?.cancel()
        collisionSubscription?.cancel()
        continuingCollisionSubscription?.cancel()
        for slot in layout.slots {
            guard let body = bodies[slot.book.id] else { continue }
            // Keep collision geometry after the fall. Selection follows a path that clears
            // neighboring boards before the book turns.
            if var physics = body.physicsBody {
                body.components.set(PhysicsMotionComponent())
                physics.mode = .kinematic
                physics.isContinuousCollisionDetectionEnabled = false
                body.physicsBody = physics
            }
            // Seat each book at its computed stack height. Contacts between moving bodies can
            // leave a book partly sunk into its support, which hides the bottom of its spine.
            // Kinematic bodies keep their collision shapes for selection and the return flight.
            body.position.y = slot.restingY
            restingTransforms[slot.book.id] = body.transform
        }
        isSettled = true
        showShelfLabel(for: selectedID)
        publishFocusFrames()
    }

    /// Sends each spine's rectangle at rest and whether the books have settled. Targets exist
    /// from the start of a fall, so entering the tab can focus a book while it falls; the view
    /// opens details only after settling. Never assigns focus.
    private func publishFocusFrames() {
        guard !layout.slots.isEmpty, renderBounds.width > 0, renderBounds.height > 0 else {
            return
        }
        onFocusFrames?(projectedFrames(), isSettled)
    }

    /// Shows the focused book's lettering on the shelf front, or the hint without focus.
    /// Labels are prepared ahead of time, so focus changes only swap a material.
    private func showShelfLabel(for id: Int?) {
        guard let label = id.flatMap({ labels[$0] }) ?? hintLabel else {
            shelfLabel.isEnabled = false
            return
        }
        var material = UnlitMaterial(texture: label.texture)
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        shelfLabel.model = ModelComponent(
            mesh: Self.unitPlane, materials: [material])
        shelfLabel.scale = [label.width, BookWallShelfLabel.height, 1]
        shelfLabel.isEnabled = true
    }

    private static let unitPlane = MeshResource.generatePlane(width: 1, height: 1)

    func highlight(_ id: Int?, reduceMotion: Bool) {
        hasUndrawnChange = true
        guard isSettled, !isFlyingOut, selectedID != id else { return }
        if let selectedID, let body = bodies[selectedID],
            let resting = restingTransforms[selectedID]
        {
            if reduceMotion {
                body.transform = resting
            } else {
                body.move(to: resting, relativeTo: root, duration: 0.18)
            }
        }
        selectedID = id
        // Both moves last at most the pull-out duration.
        animatingUntil = CACurrentMediaTime() + TimeInterval(Self.pullOutDuration) + 0.1
        showShelfLabel(for: id)
        // The ribbon leaves at once when focus moves; only its arrival animates.
        hideRibbon()
        guard let id, let body = bodies[id], var lifted = restingTransforms[id] else { return }
        showRibbon(for: id, animated: !reduceMotion)
        guard !reduceMotion else {
            body.transform = lifted
            return
        }
        // The case slides straight toward the viewer so the spine remains readable.
        lifted.translation.z += Self.focusPullOut
        body.move(
            to: lifted, relativeTo: root, duration: TimeInterval(Self.pullOutDuration),
            timingFunction: .easeOut)
    }

    /// Fits the shelf and the complete drop envelope to the host viewport.
    private func updateSceneViewport() {
        guard renderBounds.width > 0, renderBounds.height > 0,
            renderBounds.size != viewportSize
        else { return }
        viewportSize = renderBounds.size
        cancelTransition()
        let area = visibleArea
        let focal = focalLength
        var depth: Float = 1
        let front = (layout.slots.map(\.coverWidth).max() ?? 0.8) / 2
        for slot in layout.slots {
            // Include the drop, the shelf, and focus lift without changing book proportions.
            // Frame the settled stacks with room for the header controls above them. Books
            // start above the frame and fall into view.
            for y in [
                BookWallLayout.floorY - Self.shelfThickness - 0.06,
                slot.restingY + slot.spineThickness / 2 + 1.0,
            ] {
                for x in [slot.x - slot.bookHeight / 2 - 0.2, slot.x + slot.bookHeight / 2 + 0.2] {
                    // Spines sit flush at the deepest book's front; focus pulls one further out.
                    let point = SIMD3<Float>(x, y, front + Self.focusPullOut + 0.03)
                    depth = max(depth, requiredCameraDepth(for: point, in: area, focal: focal))
                }
            }
        }
        let shelfHalfWidth = layout.totalWidth / 2 + 0.7
        let shelfFront = (layout.slots.map(\.coverWidth).max() ?? 0.8) / 2 + 0.275
        for x in [-shelfHalfWidth, shelfHalfWidth] {
            let corner = SIMD3<Float>(x, BookWallLayout.floorY - Self.shelfThickness, shelfFront)
            depth = max(depth, requiredCameraDepth(for: corner, in: area, focal: focal))
        }
        wallCameraDepth = depth + 0.15
        setCameraDepth(wallCameraDepth)
        let frameTop = Float(renderBounds.midY) * wallCameraDepth / focal
        let thickest = layout.slots.map(\.spineThickness).max() ?? 0
        dropHeight = max(dropHeight, frameTop + thickest)
        fitBackdrop()
        publishFocusFrames()
    }

    private var focalLength: Float {
        Float(renderBounds.height) / (2 * tan(camera.camera.fieldOfViewInDegrees * .pi / 360))
    }

    private var visibleArea: CGRect {
        renderBounds.insetBy(dx: 72, dy: 72)
    }

    private func requiredCameraDepth(for point: SIMD3<Float>, in area: CGRect, focal: Float)
        -> Float
    {
        let horizontalRoom = Float(
            point.x < 0 ? renderBounds.midX - area.minX : area.maxX - renderBounds.midX)
        let verticalRoom = Float(
            point.y > 0 ? renderBounds.midY - area.minY : area.maxY - renderBounds.midY)
        return point.z
            + max(
                abs(point.x) * focal / max(1, horizontalRoom),
                abs(point.y) * focal / max(1, verticalRoom))
    }

    /// Uses the same vertical field of view as the camera, including during a planned dolly.
    private func project(_ point: SIMD3<Float>, cameraDepth: Float) -> CGPoint? {
        let distance = cameraDepth - point.z
        guard distance > camera.camera.near else { return nil }
        let scale = focalLength / distance
        return CGPoint(
            x: renderBounds.midX + CGFloat(point.x * scale),
            y: renderBounds.midY - CGFloat(point.y * scale))
    }

    private func corners(of slot: BookWallLayout.Slot, at pose: Transform) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for x in [-slot.bookHeight / 2, slot.bookHeight / 2] {
            for y in [
                -slot.spineThickness / 2 - Self.coverSurfaceOffset,
                slot.spineThickness / 2 + Self.coverSurfaceOffset,
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
            guard -center.z - depth.upperBound > camera.camera.near else { return false }
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
        let positionWeight = 1 - smootherstep(t)
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
        hasUndrawnChange = true
        guard !Task.isCancelled, isSettled, !isFlyingOut,
            renderHost != nil,
            let body = bodies[book.id], let resting = restingTransforms[book.id],
            let slot = layout.slots.first(where: { $0.book.id == book.id }),
            detailFrame.width > 0, detailFrame.height > 0, renderBounds.width > 0
        else { return false }
        let start = body.transform
        #if BOOKWORMS_DIAGNOSTICS
            let planningStart = CACurrentMediaTime()
        #endif
        body.stopAllAnimations()
        body.transform = start
        let stackFront = (layout.slots.map(\.coverWidth).max() ?? slot.coverWidth) / 2 + 0.02
        let radius =
            simd_length(
                SIMD3<Float>(
                    slot.bookHeight, slot.spineThickness + 2 * Self.coverSurfaceOffset,
                    slot.coverWidth + 0.02)) / 2
        var clear = resting
        clear.translation.z = stackFront + radius + 0.12
        var cameraDepth = wallCameraDepth + clear.translation.z - start.translation.z
        var planned: [FlightFrame]?
        // Fit the paired camera/book trajectory, not just its endpoints. No model scaling
        // or sideways screen clamp is used to hide a path that leaves the render surface.
        for _ in 0..<16 {
            if let destination = detailDestination(
                for: slot, detailFrame: detailFrame,
                cameraDepth: cameraDepth, reduceMotion: reduceMotion),
                destination.translation.z >= clear.translation.z
            {
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
        isFlyingOut = true
        selectedID = book.id
        flightFrames = frames
        placeDetailLight(at: destination.pose.translation)
        if reduceMotion {
            body.transform = destination.pose
            setCameraDepth(destination.cameraDepth)
            setDetailLightLevel(1)
            return true
        }
        let completed = await playFlight(
            frames, on: body, duration: Self.flightDuration, targetLightLevel: 1)
        return completed && !Task.isCancelled && bodies[book.id] === body && isFlyingOut
    }

    private func detailDestination(
        for slot: BookWallLayout.Slot, detailFrame: CGRect,
        cameraDepth: Float, reduceMotion: Bool
    ) -> Transform? {
        let top = max(
            BookDetailCoverLayout.wallNavigationCoverSize.height + 12,
            detailFrame.minY + BookDetailCoverLayout.verticalPadding)
        let bottom = min(
            visibleArea.maxY, detailFrame.maxY - BookDetailCoverLayout.verticalPadding)
        // Fit symmetrically around the screen's center rather than centering below
        // the Back button. The full sway remains below the navigation cover.
        let halfHeight = min(renderBounds.midY - top, bottom - renderBounds.midY)
        guard halfHeight > 0 else { return nil }
        let left = detailFrame.minX + BookDetailCoverLayout.horizontalPadding
        let width = detailFrame.width * BookDetailCoverLayout.wallColumnFraction
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

    func showOnlyDetailBook(_ presented: Bool, reduceMotion: Bool) {
        hasUndrawnChange = true
        guard isFlyingOut, let selectedID, let body = bodies[selectedID] else { return }
        for child in root.children
        where child !== camera && child !== body && child !== detailLight
            && child !== topLight
        {
            child.isEnabled = !presented
        }
        // The ribbon hides with the wall and returns with it only if it was showing.
        ribbon.isEnabled = !presented && ribbonVisible
        if presented && !reduceMotion { startDetailIdle(on: body) }
    }

    func returnFromDetail(reduceMotion: Bool) async {
        hasUndrawnChange = true
        guard isFlyingOut, let selectedID, let body = bodies[selectedID],
            let resting = restingTransforms[selectedID]
        else { return }
        let current = body.transform
        let motion = idleMotion
        idlePose = nil
        showOnlyDetailBook(false, reduceMotion: reduceMotion)
        if !reduceMotion, let destination = flightFrames.last {
            let offset = current.translation - destination.pose.translation
            let count = flightFrames.count - 1
            let frames = flightFrames.reversed().enumerated()
                .map { index, frame in
                    var result = frame
                    let progress = min(
                        1, Float(index) / Float(max(1, count)) / Self.idleReturnFraction)
                    let blendDuration = Float(Self.flightDuration) * Self.idleReturnFraction
                    result.pose.translation += Self.travel(
                        offset, .zero,
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
                    result.pose.rotation =
                        simd_quatf(angle: yaw, axis: [0, 1, 0]) * result.pose.rotation
                    return result
                }
            guard
                await playFlight(
                    frames, on: body, duration: Self.flightDuration, targetLightLevel: 0),
                !Task.isCancelled
            else {
                return
            }
        }
        stopMotion(completed: false)
        setDetailLightLevel(0)
        if reduceMotion { body.transform = resting }
        setCameraDepth(wallCameraDepth)
        flightFrames.removeAll()
        isFlyingOut = false
    }

    /// Finishes an interrupted fall while hidden so reentry cannot resume overlapping drops.
    func deactivate() {
        hasUndrawnChange = true
        cancelTransition()
        guard !isSettled, !layout.slots.isEmpty else { return }
        dropTask?.cancel()
        collisionSubscription?.cancel()
        continuingCollisionSubscription?.cancel()
        for slot in layout.slots {
            if bodies[slot.book.id] == nil { addBook(slot, falls: false) }
            guard let body = bodies[slot.book.id] else { continue }
            body.stopAllAnimations()
            body.position.y = slot.restingY
            body.orientation = simd_quatf()
            body.components.set(PhysicsMotionComponent())
            if var physics = body.physicsBody {
                physics.mode = .kinematic
                physics.isContinuousCollisionDetectionEnabled = false
                body.physicsBody = physics
            }
            landedIDs.insert(slot.book.id)
        }
        settle()
    }

    /// Cancels a presentation synchronously so stale tasks cannot leave a hidden wall.
    func cancelTransition() {
        hasUndrawnChange = true
        stopMotion(completed: false)
        setDetailLightLevel(0)
        idlePose = nil
        for child in root.children { child.isEnabled = true }
        for (id, pose) in restingTransforms {
            bodies[id]?.stopAllAnimations()
            bodies[id]?.transform = pose
        }
        flightFrames.removeAll()
        isFlyingOut = false
        selectedID = nil
        hideRibbon()
        setCameraDepth(wallCameraDepth)
    }

    private static let ribbonWidth: Float = 0.28
    private static let ribbonSegmentLength: Float = 0.21
    /// A fixed visible length of about two typical spines' thickness (1.32 units).
    private static let ribbonSegmentCount = 5
    private static let ribbonSlideTime: Float = 0.55
    private static let ribbonSettleTime: Float = 1.0
    private static let ribbonMaterial: PhysicallyBasedMaterial = {
        var material = surface(
            color: UIColor(red: 0.84, green: 0.1, blue: 0.12, alpha: 1), roughness: 0.4,
            specular: 0.35)
        material.faceCulling = .none
        return material
    }()
    private static let ribbonMesh = ribbonSegmentMesh(notched: false)
    private static let ribbonTailMesh = ribbonSegmentMesh(notched: true)

    /// A ribbon segment hanging down from its local origin; the tail has a swallowtail notch.
    /// Segments overlap slightly so no gap opens when neighbors bend.
    private static func ribbonSegmentMesh(notched: Bool) -> MeshResource? {
        let halfWidth = ribbonWidth / 2
        let length = ribbonSegmentLength * 1.08
        var positions: [SIMD3<Float>] = [
            [-halfWidth, 0, 0], [halfWidth, 0, 0], [halfWidth, -length, 0],
            [-halfWidth, -length, 0],
        ]
        var indices: [UInt32] = [0, 2, 1, 0, 3, 2]
        if notched {
            positions.append([0, -length + ribbonWidth * 0.6, 0])
            indices = [0, 4, 1, 1, 4, 2, 0, 3, 4]
        }
        var descriptor = MeshDescriptor(name: notched ? "ribbon-tail" : "ribbon")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(positions.map { _ in [0, 0, 1] })
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Hangs a fixed length of ribbon from under the focused book. It sits just behind the
    /// pulled-out spine, in front of the lower spines and shelf lip.
    private func showRibbon(for id: Int, animated: Bool) {
        guard let slot = layout.slots.first(where: { $0.book.id == id }),
            let resting = restingTransforms[id], let mesh = Self.ribbonMesh,
            let tail = Self.ribbonTailMesh, !PerformanceDiagnostics.isolates("wall-no-ribbon")
        else { return }
        if ribbon.parent == nil { root.addChild(ribbon) }
        let front = (layout.slots.map(\.coverWidth).max() ?? slot.coverWidth) / 2
        let top = resting.translation.y - slot.collisionThickness / 2
        ribbonCount = Self.ribbonSegmentCount
        while ribbonSegments.count < ribbonCount {
            let segment = ModelEntity(mesh: mesh, materials: [Self.ribbonMaterial])
            ribbon.addChild(segment)
            ribbonSegments.append(segment)
        }
        for (index, segment) in ribbonSegments.enumerated() {
            segment.isEnabled = index < ribbonCount
            segment.model?.mesh = index == ribbonCount - 1 ? tail : mesh
        }
        ribbon.position = [
            resting.translation.x + slot.bookHeight * 0.3, top,
            front + Self.focusPullOut - 0.04,
        ]
        ribbonVisible = true
        ribbon.isEnabled = true
        showContactShadow(under: slot, lifted: resting.translation)
        // Start after the book's 0.2-second pull-out. The ribbon hangs at the pulled-out
        // depth, so sliding earlier would put it in front of a book that has not moved yet.
        ribbonElapsed = animated ? -Self.pullOutDuration : Self.ribbonSettleTime
        poseRibbon()
        guard animated, ribbonSubscription == nil else { return }
        ribbonSubscription = subscribe(to: SceneEvents.Update.self) {
            [weak self] event in
            guard let self else { return }
            ribbonElapsed += Float(event.deltaTime)
            poseRibbon()
            if ribbonElapsed >= Self.ribbonSettleTime {
                ribbonSubscription?.cancel()
                ribbonSubscription = nil
            }
        }
    }

    /// Poses the ribbon as a chain sliding out of the book's underside, tail first. Only the
    /// length below the book's bottom edge is drawn, so it never appears in front of the book. A wave
    /// travels down the visible length while it slides, then damps out quickly once it hangs
    /// free. RealityKit has no cloth simulation, so the motion is analytic.
    private func poseRibbon() {
        let t = ribbonElapsed
        // The contact shadow darkens as the book slides out, during the ribbon's delay.
        let pulledOut = min(1, max(0, 1 + t / Self.pullOutDuration))
        contactShadow.components.set(
            OpacityComponent(opacity: Self.contactShadowOpacity * pulledOut))
        let length = Float(ribbonCount) * Self.ribbonSegmentLength
        let slide = Self.smootherstep(t / Self.ribbonSlideTime)
        // Path distance of the ribbon's top below the anchor; negative is inside the book.
        let offset = -length * (1 - slide)
        let damping =
            t >= Self.ribbonSettleTime
            ? 0 : t < Self.ribbonSlideTime ? 1 : exp(-(t - Self.ribbonSlideTime) / 0.15)
        var point = SIMD3<Float>.zero
        var started = false
        for index in 0..<ribbonCount {
            let segment = ribbonSegments[index]
            let top = offset + Float(index) * Self.ribbonSegmentLength
            guard top + Self.ribbonSegmentLength > 0 else {
                segment.isEnabled = false
                continue
            }
            segment.isEnabled = true
            // Draw nothing above the book's bottom edge. The emerging segment shortens to its
            // part below the edge, so the ribbon never depends on the moving book to hide it.
            var visible: Float = 1
            if !started {
                visible = min(1, (top + Self.ribbonSegmentLength) / Self.ribbonSegmentLength)
                started = true
            }
            segment.scale = [1, visible, 1]
            let freedom = min(1, max(0, top) / 1.2)
            let phase = 14 * t - 2.6 * top
            let swing = 0.42 * damping * freedom * sin(phase)
            let twist = 0.35 * damping * freedom * sin(phase + 1.2)
            let rotation =
                simd_quatf(angle: swing, axis: [0, 0, 1])
                * simd_quatf(angle: twist, axis: [0, 1, 0])
            segment.position = point
            segment.orientation = rotation
            point += simd_act(rotation, SIMD3<Float>(0, -Self.ribbonSegmentLength * visible, 0))
        }
    }

    private func hideRibbon() {
        ribbonSubscription?.cancel()
        ribbonSubscription = nil
        ribbonVisible = false
        ribbon.isEnabled = false
    }

    /// Raises the detail lights and dims the fill on the flight clock. The key light is
    /// world-fixed, so only its brightness changes while the book moves into its light.
    private func setDetailLightLevel(_ level: Float) {
        let level = min(1, max(0, level))
        guard level != detailLightLevel else { return }
        detailLightLevel = level
        detailLight.light.intensity = Self.detailLightIntensity * level
        topLight.light.intensity =
            Self.restingTopIntensity
            + (Self.detailTopIntensity - Self.restingTopIntensity) * level
        let enabled = level > 0 || Self.keepsDetailLightEnabled
        if detailLight.isEnabled != enabled { detailLight.isEnabled = enabled }
        // Hand the stage from the shelf light to the detail light.
        shelfLight.light.intensity = Self.shelfLightIntensity * (1 - level)
        // The pool light sits right behind the stacks and brightly lights their backs. It
        // finishes fading before the books turn translucent, and returns only after they are
        // opaque again, so those lit backs never show through.
        poolLight.light.intensity =
            Self.poolLightIntensity * (1 - Self.smootherstep(level / Self.wallFadeStart))
        // The wall's baked lighting follows by crossfading to the detail wall image.
        detailBackdrop.isEnabled = level > 0
        backdrop.isEnabled = level < 1
        if level >= 1 {
            detailBackdrop.components.remove(OpacityComponent.self)
        } else {
            detailBackdrop.components.set(OpacityComponent(opacity: level))
        }
        updateDetailShadow()
        renderHost?.setAmbientExponent(ambientExponent)
        // The rest of the wall fades out over the second half of the opening and back in
        // during the return, so hiding it for details is never a cut.
        setWallOpacity(
            1 - Self.smootherstep((level - Self.wallFadeStart) / (1 - Self.wallFadeStart)))
    }

    private var wallOpacity: Float = 1
    /// Detail light level at which the wall starts to fade.
    private static let wallFadeStart: Float = 0.35

    /// Sets the opacity of everything on the wall except the selected book and the lights.
    /// `OpacityComponent` applies to each entity's descendants, such as the shelf label.
    private func setWallOpacity(_ opacity: Float) {
        guard opacity != wallOpacity else { return }
        wallOpacity = opacity
        let selected = selectedID.flatMap { bodies[$0] }
        for child in root.children
        where child !== camera && child !== selected && !(child is PointLight)
            && child !== topLight
        {
            if opacity >= 1 {
                child.components.remove(OpacityComponent.self)
            } else {
                child.components.set(OpacityComponent(opacity: opacity))
            }
        }
    }

    private func placeDetailLight(at target: SIMD3<Float>) {
        detailLight.position = target + Self.detailLightDirection * Self.detailLightDistance
    }

    /// Replaces the backdrop with a rendering of the app's wall background, one pixel per
    /// point. Until the first call, the clear color fills the frame.
    func setBackdrop(_ image: CGImage) {
        hasUndrawnChange = true
        wallImage = image
        fitBackdrop()
    }

    /// Fills the frame behind the shelf at the resting camera depth. The camera dolly moves
    /// the backdrops with it, so the frame stays filled throughout a flight.
    private func fitBackdrop() {
        guard renderBounds.width > 0, renderBounds.height > 0 else { return }
        let shelfDepth = (layout.slots.map(\.coverWidth).max() ?? 0.8) + 0.55
        backdropDistance = wallCameraDepth + shelfDepth / 2 + Self.backdropGap
        placeBackdrops()
        bakeWall()
    }

    /// Moves the camera along its axis. Every camera-depth change goes through here so the
    /// backdrops stay behind the shelf.
    private func setCameraDepth(_ depth: Float) {
        camera.position.z = depth
        placeBackdrops()
    }

    /// Holds the camera-child backdrops `backdropGap` behind the shelf at any camera depth,
    /// each scaled with its distance so it frames exactly like the SwiftUI background. A
    /// plane that kept a fixed distance from the camera would enter the shelf during a long
    /// dolly; the fading wall would then draw before the detail image, and its depth would
    /// hide that image inside the wall's outline.
    private func placeBackdrops() {
        guard renderBounds.width > 0, renderBounds.height > 0, backdropDistance > 0 else { return }
        let distance = backdropDistance + camera.position.z - wallCameraDepth
        let aspect = Float(renderBounds.width / renderBounds.height)
        let halfAngle = tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
        // The detail image sits in front so the crossfade never depth-fights the resting one.
        for (plane, depth) in [(backdrop, distance), (detailBackdrop, distance - 0.05)] {
            let height = 2 * depth * halfAngle
            plane.position = [0, 0, -depth]
            plane.scale = [height * aspect, height, 1]
        }
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
        let stackCenter = BookWallLayout.floorY + BookWallLayout.maxStackHeight / 2
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
                    height: stackCenter + Self.poolHeightOffset, distance: Self.poolLightDistance),
                wash: glow(
                    height: stackCenter + Self.washHeightOffset, distance: Self.washLightDistance),
                detailTop: Self.detailWallTop, detailBottom: Self.detailWallBottom),
            let resting = try? TextureResource(
                image: images.resting, options: .init(semantic: .color)),
            let detail = try? TextureResource(
                image: images.detail, options: .init(semantic: .color))
        else { return }
        bakedWallKey = key
        // Without tone mapping, the baked image reaches the screen unchanged, which is what
        // the lighting factors were fitted against.
        func wallMaterial(_ texture: TextureResource) -> UnlitMaterial {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(texture: .init(texture))
            return material
        }
        backdrop.model = ModelComponent(mesh: Self.unitPlane, materials: [wallMaterial(resting)])
        detailBackdrop.model = ModelComponent(
            mesh: Self.unitPlane, materials: [wallMaterial(detail)])
    }

    /// Places a soft drop shadow on the wall behind the selected book: the book's outline
    /// as seen from the camera, projected onto the wall and shifted down and to the left,
    /// away from the key light. The book hides most of it. It darkens with the detail light.
    private func updateDetailShadow() {
        guard detailLightLevel > 0, backdropDistance > 0, let selectedID,
            let body = bodies[selectedID]
        else {
            detailShadow.isEnabled = false
            return
        }
        if detailShadowCorners?.id != selectedID {
            let bounds = body.visualBounds(relativeTo: body)
            let corners = (0..<8)
                .map { index in
                    SIMD3<Float>(
                        index & 1 == 0 ? bounds.min.x : bounds.max.x,
                        index & 2 == 0 ? bounds.min.y : bounds.max.y,
                        index & 4 == 0 ? bounds.min.z : bounds.max.z)
                }
            detailShadowCorners = (selectedID, corners)
        }
        guard let corners = detailShadowCorners?.corners else { return }
        // Just in front of the detail image.
        let wall = backdrop.position.z + 0.1
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in corners {
            // The camera looks down -Z from its origin, so scaling by depth projects a point
            // onto the wall along its line of sight.
            let point = body.convert(position: corner, to: camera)
            let onWall = SIMD2(point.x, point.y) * (wall / min(point.z, -0.01))
            low = simd_min(low, onWall)
            high = simd_max(high, onWall)
        }
        let size = (high - low) * (1 + 2 * BookWallBackdropBake.shadowSoftness)
        let center = (low + high) / 2 + (high - low) * Self.detailShadowOffset
        detailShadow.position = [center.x, center.y, wall]
        detailShadow.scale = [size.x, size.y, 1]
        detailShadow.components.set(
            OpacityComponent(opacity: Self.detailShadowOpacity * detailLightLevel))
        detailShadow.isEnabled = true
    }

    /// Shades the top of the spine below a pulled-out book, where the top light would cast
    /// its shadow. The shadow is a child of the ribbon, so it hides and returns with it.
    private func showContactShadow(under slot: BookWallLayout.Slot, lifted: SIMD3<Float>) {
        let below = layout.slots
            .filter { $0.column == slot.column && $0.restingY < slot.restingY }
            .max { $0.restingY < $1.restingY }
        guard let below, let belowResting = restingTransforms[below.book.id] else {
            contactShadow.isEnabled = false
            return
        }
        let left = max(
            lifted.x - slot.spineFaceWidth / 2,
            belowResting.translation.x - below.spineFaceWidth / 2)
        let right = min(
            lifted.x + slot.spineFaceWidth / 2,
            belowResting.translation.x + below.spineFaceWidth / 2)
        guard right > left else {
            contactShadow.isEnabled = false
            return
        }
        let height = Self.contactShadowHeight
        // The light comes from the right, so the shadow falls a little to the left.
        let shift = height * Self.topLightDirection.x / Self.topLightDirection.y
        let front = (layout.slots.map(\.coverWidth).max() ?? slot.coverWidth) / 2
        let top = belowResting.translation.y + below.collisionThickness / 2
        contactShadow.position =
            SIMD3<Float>((left + right) / 2 - shift, top - height / 2, front + 0.012)
            - ribbon.position
        contactShadow.scale = [right - left, height, 1]
        contactShadow.isEnabled = true
    }

    private func startDetailIdle(on body: ModelEntity) {
        guard idlePose == nil else { return }
        idlePose = body.transform
        idleElapsed = 0
        idleAmplitude = idleTranslationAmplitude(at: body.transform, cameraDepth: camera.position.z)
        subscribeToMotion()
    }

    /// Shares the analytic position and velocity used by idle rendering and return handoff.
    /// The third component holds world-Y yaw in radians, not a depth displacement.
    private var idleMotion: (offset: SIMD3<Float>, velocity: SIMD3<Float>) {
        guard idlePose != nil else { return (.zero, .zero) }
        let seconds = Float(idleElapsed)
        let t = min(1, seconds / Self.idleRampDuration)
        let ramp = Self.smootherstep(t)
        let derivative = 30 * t * t * (t - 1) * (t - 1) / Self.idleRampDuration
        let amplitudes = SIMD3<Float>(idleAmplitude.x, idleAmplitude.y, Self.idleSwayRadians)
        let periods = SIMD3<Float>(
            Self.idleHorizontalPeriod, Self.idleVerticalPeriod, Self.idleSwayPeriod)
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

    private func subscribeToMotion() {
        guard motionSubscription == nil else { return }
        motionSubscription = subscribe(to: SceneEvents.Update.self) {
            [weak self] event in
            guard let self else { return }
            #if BOOKWORMS_DIAGNOSTICS
                let phase = flight == nil ? "idle" : "flight"
                let started = CACurrentMediaTime()
            #endif
            advanceMotion(by: event.deltaTime)
            #if BOOKWORMS_DIAGNOSTICS
                if PerformanceDiagnostics.enabled {
                    motionMetrics.record(
                        delta: event.deltaTime, callbackSeconds: CACurrentMediaTime() - started,
                        phase: phase)
                    if motionSubscription == nil { motionMetrics.flush() }
                }
            #endif
        }
    }

    /// True while an open book only drifts in its detail pose, between flights.
    var isDrifting: Bool { flight == nil && idlePose != nil }

    /// Whether the renderer host must draw at the next display refresh. The wall draws only while
    /// books fall, a flight, drift, ribbon, or pull-out animates, or a change has not been shown,
    /// so the system compositor can reuse overlays such as glass while the wall is still.
    var needsFrame: Bool {
        hasUndrawnChange || !isSettled || motionSubscription != nil || ribbonSubscription != nil
            || CACurrentMediaTime() < animatingUntil
    }

    /// Records that the host drew every change made so far.
    func didDrawFrame() { hasUndrawnChange = false }

    /// Draws at the next refresh, for changes outside the scene such as a resized or resumed host.
    func setNeedsFrame() { hasUndrawnChange = true }

    private func advanceMotion(by delta: TimeInterval) {
        if var flight {
            flight.elapsed += delta
            let progress = min(1, Float(flight.elapsed / flight.duration))
            let sample = progress * Float(flight.frames.count - 1)
            let index = min(Int(sample), flight.frames.count - 2)
            let fraction = sample - Float(index)
            let from = flight.frames[index]
            let to = flight.frames[index + 1]
            flight.body.transform = Self.interpolated(from.pose, to.pose, progress: fraction)
            setCameraDepth(from.cameraDepth + (to.cameraDepth - from.cameraDepth) * fraction)
            let lightingProgress = Self.smootherstep(progress)
            setDetailLightLevel(
                flight.initialLightLevel
                    + (flight.targetLightLevel - flight.initialLightLevel) * lightingProgress)
            self.flight = flight
            if progress == 1 { stopMotion(completed: true) }
        } else if let idlePose, let selectedID, let body = bodies[selectedID] {
            idleElapsed += delta
            let motion = idleMotion
            var pose = idlePose
            pose.translation.x += motion.offset.x
            pose.translation.y += motion.offset.y
            pose.rotation =
                simd_quatf(angle: motion.offset.z, axis: [0, 1, 0]) * idlePose.rotation
            body.transform = pose
        }
        updateDetailShadow()
    }

    private func stopMotion(completed: Bool) {
        motionSubscription?.cancel()
        motionSubscription = nil
        let completion = flight?.completion
        flight = nil
        completion?.resume(returning: completed)
    }

    private func playFlight(
        _ frames: [FlightFrame], on body: ModelEntity, duration: TimeInterval,
        targetLightLevel: Float
    )
        async -> Bool
    {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                guard !Task.isCancelled else {
                    completion.resume(returning: false)
                    return
                }
                stopMotion(completed: false)
                idlePose = nil
                flight = Flight(
                    id: id, body: body, frames: frames, duration: duration,
                    initialLightLevel: detailLightLevel, targetLightLevel: targetLightLevel,
                    completion: completion)
                subscribeToMotion()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.flight?.id == id { self?.cancelTransition() }
            }
        }
    }

    private static func smootherstep(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
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
                    cameraProgress = Self.smootherstep(t)
                } else {
                    let t = (time - extractionFraction) / (1 - extractionFraction)
                    pose.translation = Self.travel(
                        clear.translation, destination.translation,
                        startVelocity: velocity * (1 - extractionFraction) / extractionFraction,
                        endVelocity: .zero, progress: t)
                    pose.rotation = simd_slerp(
                        start.rotation, destination.rotation, Self.smootherstep(t))
                    cameraProgress = 1
                }
                return FlightFrame(
                    pose: pose,
                    cameraDepth: wallCameraDepth + (cameraDepth - wallCameraDepth) * cameraProgress)
            }
    }

    private static func interpolated(_ from: Transform, _ to: Transform, progress: Float)
        -> Transform
    {
        Transform(
            scale: .one, rotation: simd_slerp(from.rotation, to.rotation, progress),
            translation: from.translation + (to.translation - from.translation) * progress)
    }

    private func installShelf() {
        let half = layout.totalWidth / 2
        let depth = layout.slots.map(\.coverWidth).max() ?? 0.8
        let shelfSize = SIMD3<Float>(half * 2 + 1.4, Self.shelfThickness, depth + 0.55)
        let shelfColor = UIColor(red: 0.32, green: 0.21, blue: 0.14, alpha: 1)
        let shelfMaterial: any RealityKit.Material
        if PerformanceDiagnostics.isolates("wall-unlit-shelf") {
            // This constant tint isolates shading cost; it is not a fitted lighting bake.
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: shelfColor)
            shelfMaterial = material
        } else {
            shelfMaterial = Self.surface(color: shelfColor, roughness: 0.9)
        }
        let shelf = ModelEntity(
            mesh: .generateBox(size: shelfSize, cornerRadius: 0.015),
            materials: [shelfMaterial])
        shelf.name = "book-wall-shelf"
        shelf.position = [0, BookWallLayout.floorY - shelfSize.y / 2, 0]
        let shelfShape = ShapeResource.generateBox(size: shelfSize)
        shelf.collision = CollisionComponent(shapes: [shelfShape])
        shelf.physicsBody = PhysicsBodyComponent(
            shapes: [shelfShape], mass: 1,
            material: .generate(staticFriction: 0.95, dynamicFriction: 0.8, restitution: 0),
            mode: .static)
        root.addChild(shelf)
        self.shelf = shelf
        // The label lies on the front face, which faces the camera, so the scene's own
        // projection gives it the shelf's perspective.
        shelfLabel.position = [0, 0, shelfSize.z / 2 + 0.002]
        shelfLabel.isEnabled = false
        shelf.addChild(shelfLabel)
        let stackCenter = BookWallLayout.floorY + BookWallLayout.maxStackHeight / 2
        shelfLight.position = SIMD3<Float>(0, stackCenter, 0) + Self.shelfLightOffset
        poolLight.position = [
            0, stackCenter + Self.poolHeightOffset,
            -shelfSize.z / 2 - Self.backdropGap + Self.poolLightDistance,
        ]
    }

    private func addBook(_ slot: BookWallLayout.Slot, falls: Bool) {
        guard let body = preparedBodies.removeValue(forKey: slot.book.id) else { return }
        body.stopAllAnimations()
        var position = restingPosition(for: slot)
        if falls { position.y = dropHeight }
        body.position = position
        // Flat covers make supported contact agree with the stacked collision geometry.
        // A locked roll would leave one corner embedded in the book below it.
        body.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        body.components.set(PhysicsMotionComponent())
        if var physics = body.physicsBody {
            physics.mode = falls ? .dynamic : .static
            // PhysX supports continuous collision detection only on dynamic bodies. On a static
            // or kinematic body it logs an error on every update, costing main-thread time.
            physics.isContinuousCollisionDetectionEnabled = falls
            body.physicsBody = physics
        }
        root.addChild(body)
        bodies[slot.book.id] = body
        if !falls { landedIDs.insert(slot.book.id) }
    }

    /// A nonmetallic surface with reduced reflectance. The studio environment is bright in
    /// every direction, so the default reflectance adds a gray haze that lifts dark colors
    /// and desaturates the rest.
    static func surface(color: UIColor, roughness: Float, specular: Float = 0.1)
        -> PhysicallyBasedMaterial
    {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0)
        material.specular = .init(floatLiteral: specular)
        return material
    }

    private static let casingName = "hardcover-casing"
    private static let spineFaceName = "hardcover-spine"
    private static let coverFaceName = "hardcover-cover"

    private static func caseMaterial(_ style: BookWallLocalSpine.Style) -> PhysicallyBasedMaterial {
        surface(color: style.background.uiColor, roughness: 0.56)
    }

    private static func spineMaterial(_ spine: TextureResource) -> PhysicallyBasedMaterial {
        var material = surface(color: .white, roughness: 0.56)
        material.baseColor = .init(texture: .init(spine))
        return material
    }

    private static func coverMaterial(
        _ cover: TextureResource?, style: BookWallLocalSpine.Style
    ) -> any RealityKit.Material {
        guard let cover else { return UnlitMaterial(color: style.background.uiColor) }
        // The shaped covering reflects a soft edge highlight without tinting the artwork.
        var paper = surface(color: .white, roughness: 0.52, specular: 0.25)
        paper.baseColor = .init(texture: .init(cover))
        return paper
    }

    /// Replaces a built book's cover-derived materials in place, so a cover that downloads
    /// after preparation reaches the wall without rebuilding or moving the book. The caller
    /// must ask the scene for a frame afterward.
    static func applyArtwork(
        to body: ModelEntity, style: BookWallLocalSpine.Style, spine: TextureResource,
        cover: TextureResource
    ) {
        let materials: [String: any RealityKit.Material] = [
            casingName: caseMaterial(style),
            spineFaceName: spineMaterial(spine),
            coverFaceName: coverMaterial(cover, style: style),
        ]
        for case let part as ModelEntity in body.children {
            guard let material = materials[part.name] else { continue }
            part.model?.materials = [material]
        }
    }

    /// Builds the hardcover and its collision shape before the wall opens.
    static func makeBook(
        slot: BookWallLayout.Slot, style: BookWallLocalSpine.Style,
        spine: TextureResource, cover: TextureResource?, pageEdge: TextureResource?
    ) -> ModelEntity {
        let size = SIMD3<Float>(slot.bookHeight, slot.collisionThickness, slot.coverWidth)
        let boardThickness: Float = min(0.045, slot.spineThickness * 0.12)
        let shortSide = min(slot.bookHeight, slot.coverWidth)
        let foreedgeCornerRadius = shortSide * 0.005
        let spineCornerRadius = shortSide * 0.0015
        let boardBevelWidth = shortSide * 0.005
        let boardBevelDepth = min(boardThickness * 0.18, boardBevelWidth)
        let pageSize = SIMD3<Float>(
            slot.bookHeight - 0.06, slot.spineThickness - boardThickness * 2 - 0.015,
            slot.coverWidth - 0.07)
        let pageCornerRadius: Float = 0.008
        let body = ModelEntity(
            mesh: .generateBox(size: pageSize, cornerRadius: pageCornerRadius),
            materials: [
                Self.surface(color: BookWallPageTexture.paperColor, roughness: 0.85)
            ])
        body.name = "book-\(slot.book.id)"
        let plain = PerformanceDiagnostics.isolates("wall-no-details")
        if let pageEdge, !plain {
            // Box UV orientation differs per face, so each exposed page edge gets its own
            // plane whose height runs along the book's thickness and keeps the leaves parallel.
            var paper = Self.surface(color: .white, roughness: 0.85)
            paper.baseColor = .init(texture: .init(pageEdge))
            let edgeHeight = pageSize.y - pageCornerRadius * 2
            let faces: [(width: Float, position: SIMD3<Float>, angle: Float)] = [
                (pageSize.z, [-pageSize.x / 2 - 0.001, 0, 0], -.pi / 2),  // Head
                (pageSize.z, [pageSize.x / 2 + 0.001, 0, 0], .pi / 2),  // Tail
                (pageSize.x, [0, 0, -pageSize.z / 2 - 0.001], .pi),  // Fore edge
            ]
            for face in faces {
                let plane = ModelEntity(
                    mesh: .generatePlane(
                        width: face.width - pageCornerRadius * 2, height: edgeHeight),
                    materials: [paper])
                plane.position = face.position
                plane.orientation = simd_quatf(angle: face.angle, axis: [0, 1, 0])
                body.addChild(plane)
            }
        }
        // Both cover faces flow through the same full-height spine contour. The open
        // fore edge still exposes the paper block inside the continuous casing.
        let casing = ModelEntity(
            mesh: BookWallHardcoverMesh.casing(
                size: size, boardThickness: boardThickness + Self.coverWrapThickness,
                foreedgeCornerRadius: foreedgeCornerRadius, spineCornerRadius: spineCornerRadius,
                spineWallDepth: (size.z - pageSize.z) / 2,
                bevelWidth: boardBevelWidth, bevelDepth: boardBevelDepth),
            materials: [caseMaterial(style)])
        casing.name = Self.casingName
        body.addChild(casing)
        let shape = ShapeResource.generateBox(size: size)
        body.collision = CollisionComponent(shapes: [shape])
        var physics = PhysicsBodyComponent(
            shapes: [shape],
            mass: max(0.25, slot.bookHeight * slot.spineThickness * slot.coverWidth * 3),
            material: .generate(staticFriction: 0.95, dynamicFriction: 0.8, restitution: 0),
            mode: .static)
        physics.isTranslationLocked = (x: false, y: false, z: true)
        physics.isRotationLocked = (x: true, y: true, z: true)
        physics.linearDamping = 0.25
        physics.angularDamping = 0.8
        body.physicsBody = physics
        // The spine plane is opaque and shares the case's surface settings, so it shades like
        // the case around it without a visible label edge, and the GPU skips the case's spine
        // face behind it.
        let face = ModelEntity(
            mesh: .generatePlane(
                width: slot.spineFaceWidth, height: slot.spineFaceHeight),
            materials: [spineMaterial(spine)])
        face.name = Self.spineFaceName
        face.position.z = slot.coverWidth / 2 + 0.009
        body.addChild(face)
        let coverFace = ModelEntity(
            mesh: BookWallHardcoverMesh.coverSurface(
                width: slot.coverWidth, height: slot.bookHeight,
                foreedgeCornerRadius: foreedgeCornerRadius, spineCornerRadius: spineCornerRadius,
                bevelWidth: boardBevelWidth, bevelDepth: boardBevelDepth),
            materials: [coverMaterial(cover, style: style)])
        coverFace.name = Self.coverFaceName
        coverFace.position.y = slot.spineThickness / 2 + Self.coverSurfaceOffset
        // The spine faces +Z, so the cover's top edge points toward -X on the upper face.
        coverFace.orientation =
            simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        if let hinge = Self.hingeTexture, !plain {
            // A hardcover's front board flexes at a joint beside the spine. The decal shades
            // that groove over the artwork; the spine lies at the surface's -X edge.
            var material = UnlitMaterial(texture: hinge)
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            let groove = ModelEntity(
                mesh: .generatePlane(
                    width: Self.hingeWidth, height: slot.bookHeight - boardBevelWidth * 2),
                materials: [material])
            groove.position = [-slot.coverWidth / 2 + Self.hingeInset, 0, 0.0008]
            coverFace.addChild(groove)
        }
        body.addChild(coverFace)
        return body
    }

    /// Where `addBook` places a book once it rests: a fall can shift it slightly, and settling
    /// records and republishes the landed pose.
    private func restingPosition(for slot: BookWallLayout.Slot) -> SIMD3<Float> {
        let seed = Float((UInt64(bitPattern: Int64(slot.book.id)) &* 1_103_515_245) % 100) / 100
        // Spines sit flush on one front plane. Centered books of different depths would put
        // deeper spines nearer the camera, where they hide part of the book above or below.
        let front = (layout.slots.map(\.coverWidth).max() ?? slot.coverWidth) / 2
        return [slot.x + (seed - 0.5) * 0.18, slot.restingY, front - slot.coverWidth / 2]
    }

    /// Projects each spine at rest: its landed pose once settled, otherwise its planned pose.
    /// The root has an identity transform, so these root-relative poses are world poses.
    private func projectedFrames() -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for slot in layout.slots {
            let pose =
                (restingTransforms[slot.book.id]
                ?? Transform(translation: restingPosition(for: slot)))
                .matrix
            var points: [CGPoint] = []
            for x in [-slot.spineFaceWidth / 2, slot.spineFaceWidth / 2] {
                for y in [-slot.spineFaceHeight / 2, slot.spineFaceHeight / 2] {
                    let corner = pose * SIMD4<Float>(x, y, slot.coverWidth / 2 + 0.009, 1)
                    if let point = projectWithCamera([corner.x, corner.y, corner.z]),
                        point.x.isFinite, point.y.isFinite
                    {
                        points.append(point)
                    }
                }
            }
            guard points.count == 4, let bounds = Self.bounds(of: points) else { continue }
            let width = max(44, bounds.width)
            let height = max(30, bounds.height)
            frames[slot.book.id] = CGRect(
                x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                width: width, height: height)
        }
        let outside = frames.values.filter { !renderBounds.contains($0) }.count
        BookWallHostLog.write("focusFrames=\(frames.count) outsideViewport=\(outside)")
        return frames
    }
}

/// Keeps source art intact and blends only a narrow, synthesized casing bleed.
enum BookWallCoverTexture {
    static func make(image: CGImage, slot: BookWallLayout.Slot, edgeColor: UIColor) -> CGImage? {
        let size = CGSize(width: 512, height: CGFloat(slot.bookHeight / slot.coverWidth) * 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                let cg = context.cgContext
                edgeColor.setFill()
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
                // fade only that margin into the case. No tint or gradient touches source art.
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
                        caseColor: edgeColor, context: cg)
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
                        caseColor: edgeColor, context: cg)
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
                        caseColor: edgeColor, context: cg)
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
                        caseColor: edgeColor, context: cg)
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

/// Draws textures shared across the scene: page-edge leaves, the hinge, and the studio.
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

    /// A groove profile across its width: a soft shadow with a faint highlight on the
    /// fore-edge side, where the board rises out of the joint.
    static func makeHinge() -> CGImage? {
        let size = CGSize(width: 64, height: 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                for column in 0..<Int(size.width) {
                    // Map pixel centers to -1...1 across the groove; +1 is the fore-edge side.
                    let t = (CGFloat(column) + 0.5) / size.width * 2 - 1
                    let shade = exp(-pow(t / 0.28, 2)) * 0.30
                    let light = exp(-pow((t - 0.55) / 0.16, 2)) * 0.16
                    let color =
                        light > shade
                        ? UIColor(white: 1, alpha: light) : UIColor(white: 0, alpha: shade)
                    color.setFill()
                    context.cgContext.fill(
                        CGRect(x: CGFloat(column), y: 0, width: 1, height: size.height))
                }
            }
            .cgImage
    }

    /// A neutral equirectangular studio: brightest overhead, slightly dimmer at the horizon,
    /// and darker underfoot. Neutral white keeps book colors from shifting.
    static func makeStudioEnvironment() -> CGImage? {
        let size = CGSize(width: 256, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                guard
                    let gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [
                            UIColor(white: 1, alpha: 1).cgColor,
                            UIColor(white: 0.85, alpha: 1).cgColor,
                            UIColor(white: 0.35, alpha: 1).cgColor,
                        ] as CFArray, locations: [0, 0.5, 1])
                else { return }
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            .cgImage
    }
}

/// Draws shelf-front lettering at a fixed density, so every label shares one letter size and
/// its plane width follows its text.
enum BookWallShelfLabel {
    struct Prepared {
        let texture: TextureResource
        let width: Float
    }

    /// Label height in scene units, within the shelf's front face.
    static let height: Float = 0.38
    static let maximumWidth: Float = 12
    private static let pixelsPerUnit: CGFloat = 128
    /// Warm gilt, like lettering stamped into a wooden shelf.
    private static let gilt = UIColor(red: 0.95, green: 0.86, blue: 0.66, alpha: 1)

    static func make(_ text: String, style: AppFontStyle) -> CGImage? {
        let pixelHeight = (CGFloat(height) * pixelsPerUnit).rounded()
        let font = style.uiFont(size: pixelHeight * 0.62)
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
                (text as NSString).draw(in: rect, withAttributes: attributes(gilt))
            }
            .cgImage
    }

    static func prepare(_ image: CGImage) async -> Prepared? {
        guard
            let texture = try? await TextureResource.generate(
                from: image, options: .init(semantic: .color))
        else { return nil }
        return Prepared(texture: texture, width: Float(CGFloat(image.width) / pixelsPerUnit))
    }
}

enum BookWallSpineTexture {
    static func make(for slot: BookWallLayout.Slot, style: BookWallLocalSpine.Style) -> CGImage? {
        let book = slot.book
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // Matching pixels per world unit on both axes keeps glyphs from stretching on thick books.
        let size = CGSize(
            width: (CGFloat(slot.spineFaceWidth) * 420).rounded(),
            height: (CGFloat(slot.spineFaceHeight) * 420).rounded())
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let inset = max(18, size.width * 0.045)
            let stripeWidth = max(4, size.height * 0.025)
            // The accent stripes stay quiet so the lettering leads.
            style.accent.uiColor.withAlphaComponent(0.4).setFill()
            for x in [inset, size.width - inset - stripeWidth] {
                context.cgContext.fill(
                    CGRect(
                        x: x, y: size.height * 0.1, width: stripeWidth,
                        height: size.height * 0.8))
            }
            let descriptor =
                UIFont(name: style.fontName, size: 40)?.fontDescriptor
                ?? UIFont.systemFont(ofSize: 40, weight: .semibold).fontDescriptor
            let titleBounds = CGRect(
                x: inset * 1.6, y: size.height * BookWallLayout.titleTop,
                width: size.width - inset * 3.2, height: size.height * BookWallLayout.titleShare)
            drawText(
                book.title, descriptor: descriptor, color: style.foreground.uiColor,
                in: titleBounds,
                maximumSize: Int(size.height),
                minimumSize: Int(BookWallLayout.minimumTitleFontSize))
            let authorBounds = CGRect(
                x: inset * 1.6,
                y: size.height * (BookWallLayout.titleTop + BookWallLayout.titleShare),
                width: size.width - inset * 3.2, height: size.height * BookWallLayout.authorShare)
            drawText(
                book.author, descriptor: descriptor, color: style.foreground.uiColor,
                in: authorBounds,
                maximumSize: Int(size.height * BookWallLayout.authorShare),
                minimumSize: Int(BookWallLayout.minimumAuthorFontSize))
        }
        return image.cgImage
    }

    /// Composites the lettering over the spine color, for an opaque, lit spine surface.
    /// Lit lettering reads about 10% dimmer than unlit lettering, so a light additive pass
    /// brightens it.
    static func filled(_ lettering: CGImage, background: UIColor) -> CGImage? {
        let size = CGSize(width: lettering.width, height: lettering.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                background.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let image = UIImage(cgImage: lettering)
                image.draw(in: CGRect(origin: .zero, size: size))
                image.draw(
                    in: CGRect(origin: .zero, size: size), blendMode: .plusLighter, alpha: 0.1)
            }
        return image.cgImage
    }

    private static func drawText(
        _ text: String, descriptor: UIFontDescriptor, color: UIColor, in bounds: CGRect,
        maximumSize: Int, minimumSize: Int
    ) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return }
        var chosenFont = UIFont(descriptor: descriptor, size: CGFloat(minimumSize))
        var chosenLines = wrappedLines(words, font: chosenFont, width: bounds.width)
        var lower = minimumSize
        var upper = max(minimumSize, maximumSize)
        // A larger font cannot fit when a smaller one already overflows. Search for the
        // largest size that fits the bounds, so thick spines get large lettering, without
        // measuring every intermediate point size.
        while lower <= upper {
            let size = lower + (upper - lower) / 2
            let font = UIFont(descriptor: descriptor, size: CGFloat(size))
            let lines = wrappedLines(words, font: font, width: bounds.width)
            if CGFloat(lines.count) * font.lineHeight <= bounds.height,
                lines.allSatisfy({ lineWidth($0, font: font) <= bounds.width })
            {
                chosenFont = font
                chosenLines = lines
                lower = size + 1
            } else {
                upper = size - 1
            }
        }
        let firstY = bounds.midY - CGFloat(chosenLines.count) * chosenFont.lineHeight / 2
        for (index, line) in chosenLines.enumerated() {
            (line as NSString)
                .draw(
                    at: CGPoint(
                        x: bounds.midX - lineWidth(line, font: chosenFont) / 2,
                        y: firstY + CGFloat(index) * chosenFont.lineHeight),
                    withAttributes: [.font: chosenFont, .foregroundColor: color])
        }
    }

    private static func wrappedLines(_ words: [String], font: UIFont, width: CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if !current.isEmpty, lineWidth(candidate, font: font) > width {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func lineWidth(_ line: String, font: UIFont) -> CGFloat {
        (line as NSString).size(withAttributes: [.font: font]).width
    }
}
