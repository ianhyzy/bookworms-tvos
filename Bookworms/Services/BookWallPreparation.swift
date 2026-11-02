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
    /// The books sharing each wall book's design (`LibraryModel.seriesMates`), keyed by book ID.
    let mates: [Int: [Book]]
    /// The app font style the shelf labels, the hint, and the spines' format icons use.
    let fontStyle: AppFontStyle
    /// The design each spine was drawn from, by book ID, for wall books and their series
    /// sources: its series look, else its companion design, in its system typeface when the
    /// face it shares lacks a glyph (`BookWallPreparation.drawnDesigns`).
    let drawn: [Int: SpineDesignV1]
    /// The series source each book's spine draws with. Other books draw their own.
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
    @ObservationIgnored private var missingCovers: [Book] = []
    private let rasterizer = BookWallRasterizer()
    private let downloadFont: FontDownload?

    /// Creates a preparation that downloads faces with `downloadFont`, which tests pass in place
    /// of `GoogleFontLibrary`.
    init(downloadFont: FontDownload? = nil) {
        self.downloadFont = downloadFont
    }

    /// Prepares `books` in `fontStyle`, each drawn in its series look from `looks`, else in its
    /// series source's design when `sources` (`LibraryModel.seriesSources`) gives one, else in
    /// its companion design from `designs`, else from its cover. A shared design letters in its
    /// face only when the face can letter every book in `mates` that draws it; otherwise all of
    /// them letter it in its system typeface, as on the iPhone. The checks run here, once.
    ///
    /// A wall prepared earlier stays in `prepared` until the new one is ready, so a design, link,
    /// or look that arrives while the wall is on screen replaces it in place. When the new wall
    /// can't be built, the earlier one stays and `failure` describes the problem.
    func prepare(
        _ books: [Book], sources: [Int: Book], designs: [Int: SpineDesignV1] = [:],
        looks: [Int: SpineDesignV1] = [:], mates: [Int: [Book]] = [:],
        fontStyle: AppFontStyle = .serif
    ) async {
        failure = nil
        if let prepared, prepared.books == books, prepared.sources == sources,
            prepared.designs == designs, prepared.looks == looks, prepared.mates == mates,
            prepared.fontStyle == fontStyle
        {
            // A cancelled preparation may have left covers to retry.
            await retryMissingCovers(in: prepared, fontStyle: fontStyle)
            return
        }
        completedCount = 0
        totalCount = books.count

        // Glyph checks and layout measure lettering, so each face must be registered first.
        let faces = Array(designs.values) + looks.values
        let fonts = await Self.loadFonts(for: faces, download: downloadFont)
        guard !Task.isCancelled,
            var built = await build(
                books, sources: sources, designs: designs, looks: looks, mates: mates,
                fontStyle: fontStyle)
        else {
            if !Task.isCancelled { failure = "A book could not be prepared. Select Retry." }
            return
        }
        // Faces a network failure skipped get one more try once everything else is ready. A
        // face that arrives letters a rebuilt wall before the wall shows, so no spine changes
        // in view; a face that fails again waits for the next preparation. A host that timed
        // out gets no retry, which would hold the wall for another request timeout. The rebuild
        // keeps the progress count, and a rebuild that fails keeps the first wall.
        if fonts.interruption != nil, fonts.interruption != .timedOut,
            await Self.loadFonts(for: faces, download: downloadFont).registered,
            !Task.isCancelled,
            let rebuilt = await build(
                books, sources: sources, designs: designs, looks: looks, mates: mates,
                fontStyle: fontStyle, countsProgress: false)
        {
            built = rebuilt
        }
        guard !Task.isCancelled else { return }
        prepared = built.wall
        missingCovers = built.missing
        await retryMissingCovers(in: built.wall, fontStyle: fontStyle)
    }

    /// Drops the prepared wall and its progress, so Book Wall shows its waiting dialog until the
    /// next preparation finishes. Call it when the library the wall was prepared from ends, such
    /// as the example profile, whose wall must never show as the reader's own.
    func discard() {
        prepared = nil
        missingCovers = []
        failure = nil
        completedCount = 0
    }

    /// Draws every book of the wall with the faces registered now, adding each drawn book to
    /// `completedCount` when `countsProgress` is true. Returns `nil` when the task is cancelled
    /// or a book's spine, cover, or shelf label texture can't be made, and otherwise the wall
    /// and the books whose covers it was drawn without.
    private func build(
        _ books: [Book], sources: [Int: Book], designs: [Int: SpineDesignV1],
        looks: [Int: SpineDesignV1], mates: [Int: [Book]], fontStyle: AppFontStyle,
        countsProgress: Bool = true
    ) async -> (wall: BookWallPreparedWall, missing: [Book])? {
        let drawn = Self.drawnDesigns(
            of: books, designs: designs, looks: looks, sources: sources, mates: mates)
        func typography(of book: Book) -> BookWallLocalSpine.Typography {
            BookWallLocalSpine.typography(for: book, design: drawn[book.id])
        }
        var drawsWith: [Int: Book] = [:]
        var typographies: [Int: BookWallLocalSpine.Typography] = [:]
        for book in books {
            if let source = sources[book.id], source.id != book.id {
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
        guard !Task.isCancelled else { return nil }
        // Spines letter in points at the wall's viewing scale, which its layout sets: a wider
        // wall frames from farther away. A layout grown at one scale can frame a little
        // farther, so it is laid out again at the scale it shows at, up to three more times,
        // until the two agree to within 1%.
        var scale = BookWallLayout.nominalPointsPerUnit
        var layout = await rasterizer.layout(
            books: books, coverRatios: preparation.ratios, typographies: typographies,
            pointsPerUnit: scale)
        for _ in 0..<3 {
            let shown = BookWallScene.spinePointsPerUnit(for: layout)
            guard abs(shown - scale) > scale * 0.01, !Task.isCancelled else { break }
            scale = shown
            layout = await rasterizer.layout(
                books: books, coverRatios: preparation.ratios, typographies: typographies,
                pointsPerUnit: scale)
        }
        guard !Task.isCancelled else { return nil }
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
            guard !Task.isCancelled else { return nil }
            let cover = try? await ArtworkStore.shared.detailImage(
                for: slot.book, maximumPixelSize: 400, allowsNetwork: false)
            guard !Task.isCancelled else { return nil }
            if cover == nil, !slot.book.coverURLs.isEmpty { missing.append(slot.book) }
            let source = await sourceStyle(
                for: slot.book, drawsWith: drawsWith, designs: drawn, cache: &styles)
            let images = await rasterizer.render(
                slot: slot, cover: cover, source: source, design: drawn[slot.book.id],
                fontStyle: fontStyle)
            guard !Task.isCancelled else { return nil }
            // A texture that can't be made fails the wall, which offers Retry, rather than
            // drawing a book without its spine, cover, or shelf label.
            guard let spine = try? await images.spineMips?.texture() else { return nil }
            var coverTexture: TextureResource?
            if let coverImage = images.cover {
                guard
                    let texture = try? await TextureResource.generate(
                        from: coverImage, options: .init(semantic: .color))
                else { return nil }
                coverTexture = texture
            }
            if let label = images.label {
                guard let prepared = await BookWallShelfLabel.prepare(label) else { return nil }
                labels[slot.book.id] = prepared
            }
            guard !Task.isCancelled else { return nil }
            bodies[slot.book.id] = BookWallScene.makeBook(
                slot: slot, style: images.style, spine: spine, cover: coverTexture,
                pageEdge: pageEdge)
            if countsProgress { completedCount += 1 }
            await Task.yield()
        }
        guard !Task.isCancelled else { return nil }
        var hint: BookWallShelfLabel.Prepared?
        if let image = BookWallShelfLabel.make("Choose a spine to open its book.", style: fontStyle)
        {
            guard let prepared = await BookWallShelfLabel.prepare(image) else { return nil }
            hint = prepared
        }
        let wall = BookWallPreparedWall(
            books: books, sources: sources, designs: designs, looks: looks, mates: mates,
            fontStyle: fontStyle, drawn: drawn, drawsWith: drawsWith, layout: layout,
            bodies: bodies, labels: labels, hint: hint)
        return (wall, missing)
    }

    /// Downloads missing covers again after 30 seconds, as the shelf does after a failure. A
    /// recovered cover replaces the materials in place of its book and of every wall book that
    /// draws in its series design, since the source's cover sets their colors; each slot keeps
    /// the proportions it was laid out with. A redrawn book that was drawn without a cover of its
    /// own keeps its plain board in the new colors; one drawn with a cover whose cached copy can't
    /// be read keeps its materials. Covers that still fail wait for the next preparation pass.
    private func retryMissingCovers(in wall: BookWallPreparedWall, fontStyle: AppFontStyle)
        async
    {
        let failed = missingCovers
        let failedIDs = Set(failed.map(\.id))
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
            guard let body = wall.bodies[slot.book.id] else { continue }
            let cover = try? await ArtworkStore.shared.detailImage(
                for: slot.book, maximumPixelSize: 400, allowsNetwork: false)
            // Only a book that was drawn without its cover may draw a plain board.
            guard cover != nil || slot.book.coverURLs.isEmpty || failedIDs.contains(slot.book.id)
            else { continue }
            let source = await sourceStyle(
                for: slot.book, drawsWith: wall.drawsWith, designs: wall.drawn, cache: &styles)
            let images = await rasterizer.render(
                slot: slot, cover: cover, source: source, design: wall.drawn[slot.book.id],
                fontStyle: fontStyle)
            guard let spine = try? await images.spineMips?.texture() else { continue }
            var coverTexture: TextureResource?
            if let coverImage = images.cover {
                coverTexture = try? await TextureResource.generate(
                    from: coverImage, options: .init(semantic: .color))
                guard coverTexture != nil else { continue }
            }
            guard !Task.isCancelled, prepared?.id == wall.id else { continue }
            BookWallScene.applyArtwork(
                to: body, book: slot.book, style: images.style, spine: spine, cover: coverTexture)
            restored.insert(slot.book.id)
            coverRevision &+= 1
        }
        guard prepared?.id == wall.id else { return }
        missingCovers.removeAll { recovered.contains($0.id) && restored.contains($0.id) }
    }
}

extension BookWallPreparation {
    /// The design each of `books` and their series sources draws, by book ID: its series look
    /// from `looks`, else its companion design from `designs`. A book with a series source in
    /// `sources` draws the source's entry.
    ///
    /// A shared design, a look or a source's design, letters in its face only when the face can
    /// letter every book in `mates` that draws it (`canLetter(_:in:)`), including books outside
    /// the wall. Otherwise every one of them draws it in its system typeface
    /// (`SpineDesignV1.inSystemTypeface`), so a series keeps one font, as on the iPhone.
    /// Register the faces (`loadFonts(for:)`) before calling this.
    static func drawnDesigns(
        of books: [Book], designs: [Int: SpineDesignV1], looks: [Int: SpineDesignV1],
        sources: [Int: Book] = [:], mates: [Int: [Book]] = [:]
    ) -> [Int: SpineDesignV1] {
        var drawn = designs
        // Each group's books share one mates list, so its glyph check runs once.
        var letters: [Int: Bool] = [:]
        func lettersAll(_ mates: [Book], in design: SpineDesignV1) -> Bool {
            guard let first = mates.first?.id else { return true }
            if let known = letters[first] { return known }
            let typography = BookWallLocalSpine.typography(for: mates[0], design: design)
            let known = mates.allSatisfy { canLetter($0, in: typography) }
            letters[first] = known
            return known
        }
        for book in books {
            if let look = looks[book.id] {
                let mates = mates[book.id] ?? [book]
                drawn[book.id] = lettersAll(mates, in: look) ? look : look.inSystemTypeface
            } else if let source = sources[book.id], let design = designs[source.id],
                !lettersAll(mates[book.id] ?? [book, source], in: design)
            {
                drawn[source.id] = design.inSystemTypeface
            }
        }
        return drawn
    }

    /// Whether a spine in `typography` can letter `book`: false only when its face is registered
    /// (`BookWallLocalSpine.Typography.loadedFont(size:)`) and lacks a glyph of the book's title
    /// and author, in capitals when `typography` draws in capitals. A face that isn't registered
    /// passes, since the spine letters in the system face, as the iPhone companion's check does.
    static func canLetter(_ book: Book, in typography: BookWallLocalSpine.Typography) -> Bool {
        guard let face = typography.loadedFont(size: 12) else { return true }
        return SeriesDesigns.canLetter(book, font: face as CTFont, uppercase: typography.uppercase)
    }

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

    /// Downloads and registers one Google Fonts face by family and weight. Without
    /// `allowsNetwork`, it registers only a face cached on disk and throws otherwise.
    typealias FontDownload =
        @MainActor (_ family: String, _ weight: Int, _ allowsNetwork: Bool) async throws -> Void

    /// Whether `loadFonts(for:download:)` registered a face, and the network failure, if any,
    /// that stopped it before it tried every face.
    struct FontLoad: Equatable {
        var registered = false
        var interruption: URLError.Code?
    }

    /// Downloads and registers each design's Google Fonts face once per family and weight.
    /// A book whose face does not load uses the system face for its design's typeface and
    /// weight. A network failure stops further downloads, so an unreachable host delays the
    /// wall by at most one request timeout per call; the remaining faces still register from
    /// the disk cache.
    ///
    /// The design's own face counts as registered by its recorded name, or once this process
    /// downloaded its family at its weight (`GoogleFontLibrary.downloadedName`), whose file can
    /// name the face otherwise. A family's registered Regular face, for example, does not stand
    /// in for its Bold. A stand-in family counts as registered with any face, since each one
    /// ships a single weight (`SpineFontPolicy.standInFamilies`).
    /// Tests pass `download` in place of `GoogleFontLibrary`.
    static func loadFonts(
        for designs: some Sequence<SpineDesignV1>,
        download: FontDownload? = nil
    ) async -> FontLoad {
        var load = FontLoad()
        var requested = Set<String>()
        var allowsNetwork = true
        for design in designs {
            guard let name = design.fontPostScriptName, let request = fontRequest(for: design)
            else { continue }
            let (family, weight) = request
            let registered =
                SpineFontPolicy.standInFamily(for: name) == nil
                ? SpineFontPolicy.uprightName(name).flatMap { UIFont(name: $0, size: 12) } != nil
                    || GoogleFontLibrary.downloadedName(family: family, weight: weight) != nil
                : GoogleFontLibrary.registeredFace(family: family, nearest: weight) != nil
            guard !registered else { continue }
            guard requested.insert("\(family):\(weight)").inserted else { continue }
            guard !Task.isCancelled else { return load }
            do {
                if let download {
                    try await download(family, weight, allowsNetwork)
                } else {
                    _ = try await GoogleFontLibrary.shared.download(
                        family: family, weight: weight, allowsNetwork: allowsNetwork)
                }
                load.registered = true
            } catch let error as URLError where allowsNetwork {
                load.interruption = error.code
                allowsNetwork = false
            } catch {
                continue
            }
        }
        return load
    }
}

/// Draws cover-derived spine and board artwork away from the UI actor.
actor BookWallRasterizer {
    struct Images: Sendable {
        let style: BookWallLocalSpine.Style
        /// The lettered cloth spine with the cover's fold.
        let spine: CGImage?
        /// `spine`'s mip chain, from which preparation makes its texture.
        let spineMips: BookWallSpineTexture.Mips?
        let cover: CGImage?
        let label: CGImage?
    }

    /// Lays out the wall and measures its lettering here, off the main actor.
    func layout(
        books: [Book], coverRatios: [Int: Double],
        typographies: [Int: BookWallLocalSpine.Typography], pointsPerUnit: Float
    ) -> BookWallLayout {
        let measurement = PerformanceDiagnostics.begin("BookWallLayout")
        defer { measurement.end() }
        return BookWallLayout(
            books: books, coverRatios: coverRatios, typographies: typographies,
            pointsPerUnit: pointsPerUnit)
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
        let spine = BookWallSpineTexture.make(for: slot, style: style, fontStyle: fontStyle)
            .flatMap {
                BookWallSpineTexture.filled(
                    $0, book: slot.book, cloth: style.background, edgeColors: edge)
            }
        return Images(
            style: style, spine: spine, spineMips: spine.flatMap(BookWallSpineTexture.Mips.init),
            cover: board, label: label)
    }
}
