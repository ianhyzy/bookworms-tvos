import RealityKit
import simd

/// Builds a continuous hardcover with separate foreedge and bound-edge corner profiles.
@MainActor
enum BookWallHardcoverMesh {
    private static let cornerIntervals = 6
    private static let bevelIntervals = 3

    /// Joins both covers through a continuous spine that shares their full outer outline.
    static func casing(
        size: SIMD3<Float>, boardThickness: Float, foreedgeCornerRadius: Float,
        spineCornerRadius: Float, spineWallDepth: Float, bevelWidth: Float, bevelDepth: Float
    ) -> MeshResource {
        let maximumRadius = min(size.x, size.z) / 2
        let foreedgeRadius = min(foreedgeCornerRadius, maximumRadius)
        let spineRadius = min(spineCornerRadius, maximumRadius)
        let thickness = min(boardThickness, size.y / 2)
        let bevel = min(bevelWidth, maximumRadius)
        let rollDepth = min(bevelDepth, bevel, thickness * 0.25)
        var geometry = Geometry(
            width: size.x, height: size.z,
            cornerRadii: [foreedgeRadius, foreedgeRadius, spineRadius, spineRadius],
            spineWallDepth: min(max(spineWallDepth, spineRadius), size.z / 2))
        let halfDepth = size.y / 2

        for side: Float in [-1, 1] {
            geometry.beginSurface()
            let center = side * (halfDepth - thickness / 2)
            for step in 0...bevelIntervals {
                let angle = Float(step) / Float(bevelIntervals) * .pi / 2
                let sine: Float = step == bevelIntervals ? 1 : sin(angle)
                let cosine: Float = step == bevelIntervals ? 0 : cos(angle)
                let normal = bevelNormal(sine: sine, cosine: cosine, width: bevel, depth: rollDepth)
                geometry.appendRing(
                    inset: bevel * (1 - sine),
                    depth: center - thickness / 2 + rollDepth * (1 - cosine),
                    outwardNormal: normal.x, faceNormal: -normal.y,
                    connectsSpine: side < 0)
            }
            for step in (0...bevelIntervals).reversed() {
                let angle = Float(step) / Float(bevelIntervals) * .pi / 2
                let sine: Float = step == bevelIntervals ? 1 : sin(angle)
                let cosine: Float = step == bevelIntervals ? 0 : cos(angle)
                let normal = bevelNormal(sine: sine, cosine: cosine, width: bevel, depth: rollDepth)
                geometry.appendRing(
                    inset: bevel * (1 - sine),
                    depth: center + thickness / 2 - rollDepth * (1 - cosine),
                    outwardNormal: normal.x, faceNormal: normal.y,
                    connectsSpine: side > 0 && step < bevelIntervals)
            }
            geometry.appendCap(front: false, depth: center - thickness / 2)
            geometry.appendCap(front: true, depth: center + thickness / 2)
        }
        geometry.appendSpine(from: -halfDepth + rollDepth, to: halfDepth - rollDepth)

        // The construction uses an XY outline with thickness on Z. Rotate it into
        // the book's X/Z outline and Y thickness without reversing its winding.
        geometry.positions = geometry.positions.map { [$0.x, $0.z, -$0.y] }
        geometry.normals = geometry.normals.map { [$0.x, $0.z, -$0.y] }
        do {
            return try geometry.resource(name: "book-wall-hardcover-casing", includesTexture: false)
        } catch {
            return .generateBox(size: size, cornerRadius: min(spineRadius, rollDepth))
        }
    }

    /// Carries the source artwork over the front bevel without adding a painted border.
    /// The front is at Z = 0; its outer rim recedes by `bevelDepth` into the covering.
    static func coverSurface(
        width: Float, height: Float, foreedgeCornerRadius: Float, spineCornerRadius: Float,
        bevelWidth: Float, bevelDepth: Float
    ) -> MeshResource {
        let maximumRadius = min(width, height) / 2
        let foreedgeRadius = min(foreedgeCornerRadius, maximumRadius)
        let spineRadius = min(spineCornerRadius, maximumRadius)
        let bevel = min(bevelWidth, maximumRadius)
        let rollDepth = min(bevelDepth, bevel)
        // The artwork's left edge maps to the casing's bound edge after its rotation.
        var geometry = Geometry(
            width: width, height: height,
            cornerRadii: [foreedgeRadius, spineRadius, spineRadius, foreedgeRadius])
        for step in (0...bevelIntervals).reversed() {
            let angle = Float(step) / Float(bevelIntervals) * .pi / 2
            let sine: Float = step == bevelIntervals ? 1 : sin(angle)
            let cosine: Float = step == bevelIntervals ? 0 : cos(angle)
            let normal = bevelNormal(sine: sine, cosine: cosine, width: bevel, depth: rollDepth)
            geometry.appendRing(
                inset: bevel * (1 - sine),
                depth: -rollDepth * (1 - cosine),
                outwardNormal: normal.x, faceNormal: normal.y)
        }
        geometry.appendCap(front: true, depth: 0)
        do {
            return try geometry.resource(name: "book-wall-hardcover-artwork", includesTexture: true)
        } catch {
            return .generatePlane(
                width: width, height: height, cornerRadius: min(foreedgeRadius, spineRadius))
        }
    }

    /// Matches the normal to the unequal width and depth of the elliptical edge roll.
    private static func bevelNormal(
        sine: Float, cosine: Float, width: Float, depth: Float
    ) -> SIMD2<Float> {
        simd_normalize([sine / max(width, 0.000001), cosine / max(depth, 0.000001)])
    }

    @MainActor
    private struct Geometry {
        let width: Float
        let height: Float
        let cornerRadii: SIMD4<Float>
        let spineWallDepth: Float?
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var textureCoordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        private var ringStarts: [UInt32] = []

        private var ringCount: Int {
            4 * (cornerIntervals + 1) + (spineWallDepth == nil ? 0 : 2)
        }

        private var spineRange: Range<Int> {
            (2 * (cornerIntervals + 1))..<(ringCount - 1)
        }

        init(
            width: Float, height: Float, cornerRadii: SIMD4<Float>, spineWallDepth: Float? = nil
        ) {
            self.width = width
            self.height = height
            self.cornerRadii = cornerRadii
            self.spineWallDepth = spineWallDepth
        }

        mutating func beginSurface() {
            ringStarts.removeAll(keepingCapacity: true)
        }

        mutating func appendRing(
            inset: Float, depth: Float, outwardNormal: Float, faceNormal: Float,
            connectsSpine: Bool = true, connectsOtherEdges: Bool = true
        ) {
            let start = UInt32(positions.count)
            for corner in 0..<4 {
                // The face roll can be wider than the silhouette's corner radius.
                // Offset the inner rectangle and let its corner become square.
                let radius = max(0, cornerRadii[corner] - inset)
                let center = SIMD2<Float>(
                    (corner == 0 || corner == 3 ? 1 : -1) * (width / 2 - inset - radius),
                    (corner < 2 ? 1 : -1) * (height / 2 - inset - radius))
                for step in 0...cornerIntervals {
                    let angle =
                        (Float(corner) + Float(step) / Float(cornerIntervals)) * .pi / 2
                    let direction = SIMD2<Float>(cos(angle), sin(angle))
                    let point = center + direction * radius
                    positions.append([point.x, point.y, depth])
                    normals.append([
                        direction.x * outwardNormal, direction.y * outwardNormal, faceNormal,
                    ])
                    // Match RealityKit's generated-plane UV orientation for the existing
                    // cover texture. The bevel carries edge pixels without stretching the face.
                    textureCoordinates.append([point.x / width + 0.5, point.y / height + 0.5])
                }
                if let spineWallDepth, corner == 1 || corner == 3 {
                    // Split the head and tail where the inner spine meets the pages.
                    // The spine owns these short straight runs through both boards.
                    let side: Float = corner == 1 ? -1 : 1
                    let point = SIMD2<Float>(
                        side * (width / 2 - inset), -height / 2 + spineWallDepth)
                    positions.append([point.x, point.y, depth])
                    normals.append([side * outwardNormal, 0, faceNormal])
                    textureCoordinates.append([point.x / width + 0.5, point.y / height + 0.5])
                }
            }
            if let previous = ringStarts.last {
                for index in 0..<ringCount {
                    let isSpine = spineRange.contains(index)
                    guard isSpine ? connectsSpine : connectsOtherEdges else { continue }
                    let next = UInt32((index + 1) % ringCount)
                    let current = UInt32(index)
                    appendTriangle(previous + current, previous + next, start + next)
                    appendTriangle(previous + current, start + next, start + current)
                }
            }
            ringStarts.append(start)
        }

        mutating func appendSpine(from lowerDepth: Float, to upperDepth: Float) {
            guard let spineWallDepth else { return }
            beginSurface()
            appendRing(inset: 0, depth: lowerDepth, outwardNormal: 1, faceNormal: 0)
            appendRing(
                inset: 0, depth: upperDepth, outwardNormal: 1, faceNormal: 0,
                connectsOtherEdges: false)

            // The nearly square corners lead into straight head and tail surfaces.
            // Their depth reaches the page block independently of the corner radius.
            guard let ringStart = ringStarts.first else { return }
            let outline = (spineRange.lowerBound...spineRange.upperBound)
                .map {
                    positions[Int(ringStart) + $0]
                }
            for front in [false, true] {
                let depth = front ? upperDepth : lowerDepth
                let center = UInt32(positions.count)
                positions.append([0, -height / 2 + spineWallDepth / 2, depth])
                normals.append([0, 0, front ? 1 : -1])
                textureCoordinates.append(.zero)
                let start = UInt32(positions.count)
                for point in outline {
                    positions.append([point.x, point.y, depth])
                    normals.append([0, 0, front ? 1 : -1])
                    textureCoordinates.append(.zero)
                }
                for index in outline.indices {
                    let current = start + UInt32(index)
                    let next = start + UInt32((index + 1) % outline.count)
                    appendTriangle(center, front ? current : next, front ? next : current)
                }
            }

            // Close the inside of the U against the page block. The fore edge remains
            // open, while the two outer bevels flow directly into the spine wall.
            let innerSpine = -height / 2 + spineWallDepth
            let start = UInt32(positions.count)
            positions.append(contentsOf: [
                [-width / 2, innerSpine, lowerDepth], [-width / 2, innerSpine, upperDepth],
                [width / 2, innerSpine, upperDepth], [width / 2, innerSpine, lowerDepth],
            ])
            normals.append(contentsOf: Array(repeating: [0, 1, 0], count: 4))
            textureCoordinates.append(contentsOf: Array(repeating: .zero, count: 4))
            appendTriangle(start, start + 1, start + 2)
            appendTriangle(start, start + 2, start + 3)
        }

        mutating func appendCap(front: Bool, depth: Float) {
            guard let ringStart = front ? ringStarts.last : ringStarts.first else { return }
            let center = UInt32(positions.count)
            positions.append([0, 0, depth])
            normals.append([0, 0, front ? 1 : -1])
            textureCoordinates.append([0.5, 0.5])
            for index in 0..<ringCount {
                let current = ringStart + UInt32(index)
                let next = ringStart + UInt32((index + 1) % ringCount)
                appendTriangle(center, front ? current : next, front ? next : current)
            }
        }

        private mutating func appendTriangle(_ first: UInt32, _ second: UInt32, _ third: UInt32) {
            let origin = positions[Int(first)]
            let cross = simd_cross(positions[Int(second)] - origin, positions[Int(third)] - origin)
            // Collapsed inner corners and adjacent rim rings can share vertices.
            guard simd_length_squared(cross) > 1e-20 else { return }
            indices.append(contentsOf: [first, second, third])
        }

        func resource(name: String, includesTexture: Bool) throws -> MeshResource {
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = .init(positions)
            descriptor.normals = .init(normals)
            if includesTexture { descriptor.textureCoordinates = .init(textureCoordinates) }
            descriptor.materials = .allFaces(0)
            descriptor.primitives = .triangles(indices)
            return try MeshResource.generate(from: [descriptor])
        }
    }
}
