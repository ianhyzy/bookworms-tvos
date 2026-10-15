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
    /// The series design sources the wall was prepared for (`LibraryModel.seriesSources`).
    let sources: [Int: Book]
    /// The source each book's spine draws with: its series source, when that source's font can
    /// letter the book. Other books draw their own.
    let designs: [Int: Book]
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
    /// Books with a cover URL whose cover the wall was prepared without: wall books, and
    /// series sources outside the wall whose cover sets their series-mates' colors.
    private var missingCovers: [Book] = []
    private let rasterizer = BookWallRasterizer()

    func isReady(for books: [Book], sources: [Int: Book]) -> Bool {
        prepared?.books == books && prepared?.sources == sources
    }

    /// Prepares `books`, each drawn in its series source's design from `sources`
    /// (`LibraryModel.seriesSources`) when that source's font can letter it, checked here once.
    func prepare(_ books: [Book], sources: [Int: Book]) async {
        let fontStyle =
            AppFontStyle(rawValue: UserDefaults.standard.string(forKey: "fontStyle") ?? "")
            ?? .serif
        if let prepared, prepared.books == books, prepared.sources == sources {
            // A cancelled preparation may have left covers to retry.
            await retryMissingCovers(in: prepared, fontStyle: fontStyle)
            return
        }
        prepared = nil
        missingCovers = []
        failure = nil
        completedCount = 0
        totalCount = books.count

        var designs: [Int: Book] = [:]
        for book in books {
            guard let source = sources[book.id], source.id != book.id,
                SeriesDesigns.canLetter(
                    book, fontName: BookWallLocalSpine.fontName(for: source))
            else { continue }
            designs[book.id] = source
        }
        // A source finished in another year is not on the wall, but its cover sets the colors.
        let ids = Set(books.map(\.id))
        var outside: [Int: Book] = [:]
        for source in designs.values where !ids.contains(source.id) { outside[source.id] = source }
        let preparation = await ArtworkStore.shared.prefetch(
            books: books + outside.values.sorted { $0.id < $1.id }, avatarURLs: [])
        guard !Task.isCancelled else { return }
        let layout = BookWallLayout(
            books: books, coverRatios: preparation.ratios,
            fonts: designs.mapValues(BookWallLocalSpine.fontName(for:)))
        var styles: [Int: BookWallLocalSpine.Style] = [:]
        var bodies: [Int: ModelEntity] = [:]
        var labels: [Int: BookWallShelfLabel.Prepared] = [:]
        var missing: [Book] = []
        for source in outside.values where source.coverURL != nil {
            if (try? await ArtworkStore.shared.detailImage(
                for: source, maximumPixelSize: 400, allowsNetwork: false)) == nil
            {
                missing.append(source)
            }
        }
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
            let design = await design(for: slot.book, in: designs, cache: &styles)
            let images = await rasterizer.render(
                slot: slot, cover: cover, design: design, fontStyle: fontStyle)
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
            books: books, sources: sources, designs: designs, layout: layout, bodies: bodies,
            labels: labels, hint: hint)
        prepared = wall
        missingCovers = missing
        await retryMissingCovers(in: wall, fontStyle: fontStyle)
    }

    /// Downloads missing covers again after 30 seconds, as the shelf does after a failure. A
    /// recovered cover replaces the materials in place of its book and of every wall book that
    /// draws in its series design, since the source's cover sets their colors; each slot keeps
    /// the proportions it was laid out with. Covers that still fail wait for the next
    /// preparation pass.
    private func retryMissingCovers(in wall: BookWallPreparedWall, fontStyle: AppFontStyle)
        async
    {
        let failed = missingCovers
        guard !failed.isEmpty, (try? await Task.sleep(for: .seconds(30))) != nil else { return }
        await ArtworkStore.shared.forgetFailures()
        _ = await ArtworkStore.shared.prefetch(books: failed, avatarURLs: [])
        var recovered = Set<Int>()
        for book in failed {
            if (try? await ArtworkStore.shared.detailImage(
                for: book, maximumPixelSize: 400, allowsNetwork: false)) != nil
            {
                recovered.insert(book.id)
            }
        }
        let redrawn = wall.layout.slots.filter { slot in
            recovered.contains(slot.book.id)
                || wall.designs[slot.book.id].map { recovered.contains($0.id) } == true
        }
        var styles: [Int: BookWallLocalSpine.Style] = [:]
        // Sources outside the wall have nothing to redraw once their cover loads.
        var restored = recovered.subtracting(wall.layout.slots.map(\.book.id))
        for slot in redrawn {
            guard !Task.isCancelled, prepared?.id == wall.id else { return }
            guard let body = wall.bodies[slot.book.id],
                let cover = try? await ArtworkStore.shared.detailImage(
                    for: slot.book, maximumPixelSize: 400, allowsNetwork: false)
            else { continue }
            let design = await design(for: slot.book, in: wall.designs, cache: &styles)
            let images = await rasterizer.render(
                slot: slot, cover: cover, design: design, fontStyle: fontStyle)
            guard let spineImage = images.spine, let coverImage = images.cover,
                let spine = try? await TextureResource.generate(
                    from: spineImage, options: .init(semantic: .color)),
                let coverTexture = try? await TextureResource.generate(
                    from: coverImage, options: .init(semantic: .color)),
                !Task.isCancelled, prepared?.id == wall.id
            else { continue }
            BookWallScene.applyArtwork(
                to: body, style: images.style, spine: spine, cover: coverTexture)
            restored.insert(slot.book.id)
            coverRevision &+= 1
        }
        guard prepared?.id == wall.id else { return }
        missingCovers.removeAll { recovered.contains($0.id) && restored.contains($0.id) }
    }
}

extension BookWallPreparation {
    /// The style `book` draws with when `designs` gives it a series source: the source's, from
    /// the source's own cover. `nil` for a book that draws its own.
    fileprivate func design(
        for book: Book, in designs: [Int: Book], cache: inout [Int: BookWallLocalSpine.Style]
    ) async -> BookWallLocalSpine.Style? {
        guard let source = designs[book.id] else { return nil }
        if let style = cache[source.id] { return style }
        let cover = try? await ArtworkStore.shared.detailImage(
            for: source, maximumPixelSize: 400, allowsNetwork: false)
        let style = await rasterizer.style(for: source, cover: cover)
        cache[source.id] = style
        return style
    }
}

/// Draws cover-derived spine and board artwork away from the UI actor.
actor BookWallRasterizer {
    struct Images: Sendable {
        let style: BookWallLocalSpine.Style
        /// The lettered cloth spine with the cover's fold.
        let spine: CGImage?
        let cover: CGImage?
        let label: CGImage?
    }

    func style(for book: Book, cover: CGImage?) -> BookWallLocalSpine.Style {
        BookWallLocalSpine.style(for: book, cover: cover)
    }

    /// Draws `slot`'s spine, board, and shelf label. A book with a series source draws in
    /// `design`, the source's colors and font, and keeps its own cover on its board and its own
    /// cover's fold onto the spine and board; its bands follow its own thickness.
    func render(
        slot: BookWallLayout.Slot, cover: CGImage?, design: BookWallLocalSpine.Style?,
        fontStyle: AppFontStyle
    ) -> Images {
        let style = design ?? BookWallLocalSpine.style(for: slot.book, cover: cover)
        let edge = cover.map(BookWallLocalSpine.edgeColors(of:)) ?? []
        let board = cover.flatMap {
            BookWallCoverTexture.make(
                image: $0, slot: slot, cloth: style.background, edgeColors: edge)
        }
        let label = BookWallShelfLabel.make(
            "\(slot.book.title) · \(slot.book.author)", book: slot.book, style: fontStyle)
        let spine = BookWallSpineTexture.make(for: slot, style: style)
            .flatMap {
                BookWallSpineTexture.filled(
                    $0, book: slot.book, cloth: style.background, edgeColors: edge)
            }
        return Images(style: style, spine: spine, cover: board, label: label)
    }
}
