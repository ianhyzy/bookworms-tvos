import CoreGraphics
import Foundation
import Observation
import RealityKit

/// Artwork and layout that are ready before the 3D wall starts its falling animation.
@MainActor
struct BookWallPreparedWall {
    /// Distinguishes rebuilt walls whose books are equal, so the scene shows the entities that
    /// later cover recovery updates.
    let id = UUID()
    let books: [Book]
    let layout: BookWallLayout
    let bodies: [Int: ModelEntity]
    /// Shelf-front lettering for each book and for the resting hint.
    let labels: [Int: BookWallShelfLabel.Prepared]
    let hint: BookWallShelfLabel.Prepared?
}

/// Prepares current-year books once the library snapshot loads, without mounting the 3D scene.
@MainActor @Observable
final class BookWallPreparation {
    private(set) var prepared: BookWallPreparedWall?
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var failure: String?
    /// Increments when a recovered cover replaces a prepared book's artwork, so the visible
    /// scene can draw again.
    private(set) var coverRevision = 0
    /// Prepared books that have a cover URL but were built without their cover.
    private var missingCovers: [Book] = []
    private let rasterizer = BookWallRasterizer()

    func isReady(for books: [Book]) -> Bool { prepared?.books == books }

    func prepare(_ books: [Book]) async {
        let fontStyle =
            AppFontStyle(rawValue: UserDefaults.standard.string(forKey: "fontStyle") ?? "")
            ?? .serif
        if let prepared, prepared.books == books {
            // A cancelled preparation may have left covers to retry.
            await retryMissingCovers(in: prepared, fontStyle: fontStyle)
            return
        }
        prepared = nil
        missingCovers = []
        failure = nil
        completedCount = 0
        totalCount = books.count

        let preparation = await ArtworkStore.shared.prefetch(books: books, avatarURLs: [])
        guard !Task.isCancelled else { return }
        let layout = BookWallLayout(books: books, coverRatios: preparation.ratios)
        var bodies: [Int: ModelEntity] = [:]
        var labels: [Int: BookWallShelfLabel.Prepared] = [:]
        var missing: [Book] = []
        // One shared page-edge texture serves every book; without it pages stay plain.
        var pageEdge: TextureResource?
        if let image = BookWallPageTexture.make() {
            pageEdge = try? await TextureResource.generate(
                from: image, options: .init(semantic: .color))
        }
        for slot in layout.slots {
            guard !Task.isCancelled else { return }
            let cover = try? await ArtworkStore.shared.detailImage(
                for: slot.book, maximumPixelSize: 400, allowsNetwork: false)
            guard !Task.isCancelled else { return }
            if cover == nil, slot.book.coverURL != nil { missing.append(slot.book) }
            let images = await rasterizer.render(slot: slot, cover: cover, fontStyle: fontStyle)
            guard !Task.isCancelled else { return }
            guard let spineImage = images.spine,
                let spine = try? await TextureResource.generate(
                    from: spineImage, options: .init(semantic: .color))
            else {
                failure = "A book spine could not be prepared. Select Retry."
                return
            }
            let coverTexture: TextureResource?
            if let coverImage = images.cover {
                coverTexture = try? await TextureResource.generate(
                    from: coverImage, options: .init(semantic: .color))
            } else {
                coverTexture = nil
            }
            if let label = images.label {
                labels[slot.book.id] = await BookWallShelfLabel.prepare(label)
            }
            guard !Task.isCancelled else { return }
            bodies[slot.book.id] = BookWallScene.makeBook(
                slot: slot, style: images.style, spine: spine, cover: coverTexture,
                pageEdge: pageEdge)
            completedCount += 1
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        var hint: BookWallShelfLabel.Prepared?
        if let image = BookWallShelfLabel.make("Choose a spine to open its book.", style: fontStyle)
        {
            hint = await BookWallShelfLabel.prepare(image)
        }
        let wall = BookWallPreparedWall(
            books: books, layout: layout, bodies: bodies, labels: labels, hint: hint)
        prepared = wall
        missingCovers = missing
        await retryMissingCovers(in: wall, fontStyle: fontStyle)
    }

    /// Downloads missing covers again after 30 seconds, as the shelf does after a failure. A
    /// recovered cover replaces the book's materials in place; its slot keeps the proportions
    /// it was laid out with. Covers that still fail wait for the next preparation pass.
    private func retryMissingCovers(in wall: BookWallPreparedWall, fontStyle: AppFontStyle)
        async
    {
        let failed = missingCovers
        guard !failed.isEmpty, (try? await Task.sleep(for: .seconds(30))) != nil else { return }
        await ArtworkStore.shared.forgetFailures()
        _ = await ArtworkStore.shared.prefetch(books: failed, avatarURLs: [])
        for book in failed {
            guard !Task.isCancelled, prepared?.books == wall.books else { return }
            guard let slot = wall.layout.slots.first(where: { $0.book.id == book.id }),
                let body = wall.bodies[book.id],
                let cover = try? await ArtworkStore.shared.detailImage(
                    for: book, maximumPixelSize: 400, allowsNetwork: false)
            else { continue }
            let images = await rasterizer.render(slot: slot, cover: cover, fontStyle: fontStyle)
            guard let spineImage = images.spine, let coverImage = images.cover,
                let spine = try? await TextureResource.generate(
                    from: spineImage, options: .init(semantic: .color)),
                let coverTexture = try? await TextureResource.generate(
                    from: coverImage, options: .init(semantic: .color)),
                !Task.isCancelled, prepared?.books == wall.books
            else { continue }
            BookWallScene.applyArtwork(
                to: body, style: images.style, spine: spine, cover: coverTexture)
            missingCovers.removeAll { $0.id == book.id }
            coverRevision &+= 1
        }
    }
}

/// Draws cover-derived spine and board artwork away from the UI actor.
private actor BookWallRasterizer {
    struct Images: Sendable {
        let style: BookWallLocalSpine.Style
        /// Lettering and lines over the spine color.
        let spine: CGImage?
        let cover: CGImage?
        let label: CGImage?
    }

    func render(slot: BookWallLayout.Slot, cover: CGImage?, fontStyle: AppFontStyle) -> Images {
        let style = BookWallLocalSpine.style(for: slot.book, cover: cover)
        let board = cover.flatMap {
            BookWallCoverTexture.make(
                image: $0, slot: slot, edgeColor: style.background.uiColor)
        }
        let label = BookWallShelfLabel.make(
            "\(slot.book.title) · \(slot.book.author)", style: fontStyle)
        let spine = BookWallSpineTexture.make(for: slot, style: style)
            .flatMap {
                BookWallSpineTexture.filled($0, background: style.background.uiColor)
            }
        return Images(style: style, spine: spine, cover: board, label: label)
    }
}
