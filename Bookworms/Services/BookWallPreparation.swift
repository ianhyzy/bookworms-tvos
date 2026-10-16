import CoreGraphics
import CoreText
import Foundation
import Observation
import RealityKit
import UIKit

/// Artwork and layout that are ready before the 3D wall starts its falling animation.
@MainActor
struct BookWallPreparedWall {
    /// Distinguishes rebuilt walls whose books are equal, so the scene shows the entities that
    /// later cover recovery updates.
    let id = UUID()
    let books: [Book]
    /// The series design sources the wall was prepared for (`LibraryModel.seriesSources`).
    let sources: [Int: Book]
    /// The companion designs the wall was prepared for (`LibraryModel.spineDesigns`), keyed by
    /// book ID, for wall books and their series sources.
    let designs: [Int: SpineDesignV1]
    /// The series looks the wall was prepared for (`LibraryModel.lookDesigns`), keyed by book ID.
    let looks: [Int: SpineDesignV1]
    /// The design each spine was drawn from, by book ID: its series look when the look's face
    /// can letter the book, else its companion design.
    let drawn: [Int: SpineDesignV1]
    /// The source each book's spine draws with: its series source, when that source's face can
    /// letter the book. Other books draw their own.
    let drawsWith: [Int: Book]
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

    func isReady(
        for books: [Book], sources: [Int: Book], designs: [Int: SpineDesignV1],
        looks: [Int: SpineDesignV1]
    ) -> Bool {
        prepared?.books == books && prepared?.sources == sources && prepared?.designs == designs
            && prepared?.looks == looks
    }

    /// Prepares `books`, each drawn in its series look from `looks`, else its companion design
    /// from `designs`, else from its cover. A look draws only on a book its face can letter;
    /// another book keeps its companion design, as on the iPhone. A book with a series source
    /// in `sources` (`LibraryModel.seriesSources`) draws in the source's design when the
    /// source's face can letter it. Both checks run here, once.
    func prepare(
        _ books: [Book], sources: [Int: Book], designs: [Int: SpineDesignV1] = [:],
        looks: [Int: SpineDesignV1] = [:]
    ) async {
        let fontStyle =
            AppFontStyle(rawValue: UserDefaults.standard.string(forKey: "fontStyle") ?? "")
            ?? .serif
        if let prepared, prepared.books == books, prepared.sources == sources,
            prepared.designs == designs, prepared.looks == looks
        {
            // A cancelled preparation may have left covers to retry.
            await retryMissingCovers(in: prepared, fontStyle: fontStyle)
            return
        }
        prepared = nil
        missingCovers = []
        failure = nil
        completedCount = 0
        totalCount = books.count

        // Glyph checks and layout measure lettering, so each face must be registered first,
        // including the companion design a book keeps when its look's face can't letter it.
        await Self.loadFonts(for: Array(designs.values) + looks.values)
        guard !Task.isCancelled else { return }
        var drawn = designs
        for book in books {
            guard let look = looks[book.id] else { continue }
            let face = BookWallLocalSpine.typography(for: book, design: look).font(size: 12)
            if SeriesDesigns.canLetter(book, font: face as CTFont) { drawn[book.id] = look }
        }
        func typography(of book: Book) -> BookWallLocalSpine.Typography {
            BookWallLocalSpine.typography(for: book, design: drawn[book.id])
        }
        var drawsWith: [Int: Book] = [:]
        var typographies: [Int: BookWallLocalSpine.Typography] = [:]
        for book in books {
            if let source = sources[book.id], source.id != book.id,
                SeriesDesigns.canLetter(book, font: typography(of: source).font(size: 12) as CTFont)
            {
                drawsWith[book.id] = source
                typographies[book.id] = typography(of: source)
            } else if drawn[book.id] != nil {
                typographies[book.id] = typography(of: book)
            }
        }
        // A source finished in another year is not on the wall, but its cover sets the colors.
        let ids = Set(books.map(\.id))
        var outside: [Int: Book] = [:]
        for source in drawsWith.values where !ids.contains(source.id) {
            outside[source.id] = source
        }
        let preparation = await ArtworkStore.shared.prefetch(
            books: books + outside.values.sorted { $0.id < $1.id }, avatarURLs: [])
        guard !Task.isCancelled else { return }
        let layout = BookWallLayout(
            books: books, coverRatios: preparation.ratios, typographies: typographies)
        var styles: [Int: BookWallLocalSpine.Style] = [:]
        var bodies: [Int: ModelEntity] = [:]
        var labels: [Int: BookWallShelfLabel.Prepared] = [:]
        var missing: [Book] = []
        for source in outside.values where !source.coverURLs.isEmpty {
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
            if cover == nil, !slot.book.coverURLs.isEmpty { missing.append(slot.book) }
            let source = await sourceStyle(
                for: slot.book, drawsWith: drawsWith, designs: drawn, cache: &styles)
            let images = await rasterizer.render(
                slot: slot, cover: cover, source: source, design: drawn[slot.book.id],
                fontStyle: fontStyle)
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
            books: books, sources: sources, designs: designs, looks: looks, drawn: drawn,
            drawsWith: drawsWith, layout: layout, bodies: bodies, labels: labels, hint: hint)
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
                || wall.drawsWith[slot.book.id].map { recovered.contains($0.id) } == true
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
            let source = await sourceStyle(
                for: slot.book, drawsWith: wall.drawsWith, designs: wall.drawn, cache: &styles)
            let images = await rasterizer.render(
                slot: slot, cover: cover, source: source, design: wall.drawn[slot.book.id],
                fontStyle: fontStyle)
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
    /// The style `book` draws with when `drawsWith` gives it a series source: the source's,
    /// from the source's companion design or else its own cover. `nil` for a book that draws
    /// its own.
    fileprivate func sourceStyle(
        for book: Book, drawsWith: [Int: Book], designs: [Int: SpineDesignV1],
        cache: inout [Int: BookWallLocalSpine.Style]
    ) async -> BookWallLocalSpine.Style? {
        guard let source = drawsWith[book.id] else { return nil }
        if let style = cache[source.id] { return style }
        let cover = try? await ArtworkStore.shared.detailImage(
            for: source, maximumPixelSize: 400, allowsNetwork: false)
        let style = await rasterizer.style(for: source, cover: cover, design: designs[source.id])
        cache[source.id] = style
        return style
    }

    /// The Google Fonts family and weight to download for the face `design` draws in
    /// (`BookWallLocalSpine.typography(for:design:)`), or `nil` for a design without a PostScript
    /// name, one without a family whose face isn't blocked, or one whose blocked face has no
    /// downloadable stand-in.
    ///
    /// A blocked family is never downloaded. A slanted one, such as Dancing Script, loads its
    /// upright stand-in (`SpineFontPolicy.standInFamily(for:)`) at the design's weight, as the
    /// iPhone companion does. An italic face of an allowed family loads the family's upright
    /// face, which `SpineFontPolicy.allowedFontName(_:)` names.
    nonisolated static func fontRequest(for design: SpineDesignV1) -> (family: String, weight: Int)?
    {
        guard let name = design.fontPostScriptName else { return nil }
        if let family = design.fontFamily, SpineFontPolicy.allows(family) {
            return (family, design.instanceWeight ?? design.weight)
        }
        return SpineFontPolicy.standInFamily(for: name).map { ($0, design.weight) }
    }

    /// Downloads and registers each design's Google Fonts face once per family and weight.
    /// A book whose face does not load uses the system face for its design's typeface and
    /// weight. A network failure stops further downloads until the next preparation, so an
    /// unreachable host delays the wall by at most one request timeout.
    ///
    /// A face counts as registered only at the requested weight: a stand-in family's face of
    /// that weight, or the design's own face by name. A registered Kalam Regular, for example,
    /// does not stand in for Kalam Bold.
    fileprivate static func loadFonts(for designs: some Sequence<SpineDesignV1>) async {
        var requested = Set<String>()
        for design in designs {
            guard let name = design.fontPostScriptName, let request = fontRequest(for: design)
            else { continue }
            let (family, weight) = request
            let registered =
                SpineFontPolicy.standInFamily(for: name) == nil
                ? UIFont(name: SpineFontPolicy.allowedFontName(name), size: 12) != nil
                : GoogleFontLibrary.registeredFace(family: family, nearest: weight)
                    .map(GoogleFontLibrary.cssWeight) == weight
            guard !registered else { continue }
            guard requested.insert("\(family):\(weight)").inserted else { continue }
            guard !Task.isCancelled else { return }
            do {
                _ = try await GoogleFontLibrary.shared.download(family: family, weight: weight)
            } catch is URLError {
                return
            } catch {
                continue
            }
        }
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

    func style(for book: Book, cover: CGImage?, design: SpineDesignV1?)
        -> BookWallLocalSpine.Style
    {
        BookWallLocalSpine.style(for: book, cover: cover, design: design)
    }

    /// Draws `slot`'s spine, board, and shelf label in `source`, the series source's style,
    /// when the book has one, else in its companion `design` or its cover's colors. A book drawn
    /// in another book's style keeps its own cover on its board and its own cover's fold onto
    /// the spine and board; its bands follow its own thickness.
    func render(
        slot: BookWallLayout.Slot, cover: CGImage?, source: BookWallLocalSpine.Style?,
        design: SpineDesignV1?, fontStyle: AppFontStyle
    ) -> Images {
        let style =
            source ?? BookWallLocalSpine.style(for: slot.book, cover: cover, design: design)
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
