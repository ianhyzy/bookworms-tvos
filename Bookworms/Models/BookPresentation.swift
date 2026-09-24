import Foundation

/// A missing key or design always uses source artwork, never a synthesized spine.
@MainActor
enum BookPresentation {
    /// Temporarily hide generated artwork and provider configuration without removing saved designs.
    nonisolated static let showsGeneratedSpines = false
    nonisolated static let spineGenerationEnabled = false
    /// Temporarily hide the Calibre Web Automated source in Settings. Its client, saved
    /// configuration, credentials, and sync remain.
    nonisolated static let offersCWA = false

    static func usesSpine(hasSavedKey: Bool, hasDesign: Bool, fontAvailable: Bool) -> Bool {
        hasSavedKey && hasDesign && fontAvailable
    }

    /// Keep the whole shelf in cover mode until every displayed book has a usable design.
    static func uniformStyles(books: [Book], styles: [Int: SpineStyle]) -> [Int: SpineStyle] {
        books.allSatisfy { styles[$0.id] != nil } ? styles : [:]
    }

    /// Pages of equal-width columns, so rows that share `width` and `rowHeight` line their books up
    /// vertically, as the two Compare Shelves rows do. The column count fits a typical 2:3 cover;
    /// each cover keeps its proportions within its column and stands on the shelf.
    static func columnPages(books: [Book], width: CGFloat, rowHeight: CGFloat) -> [ShelfPage] {
        let height = rowHeight * 0.92
        let gap = ShelfLayout.gap
        let columns = max(1, Int((width + gap) / (height * 2 / 3 + gap)))
        let size = SpineDimensions(
            width: (width - CGFloat(columns - 1) * gap) / CGFloat(columns), height: height)
        return stride(from: 0, to: books.count, by: columns).enumerated()
            .map { index, start in
                let group = Array(books[start..<min(start + columns, books.count)])
                return ShelfPage(
                    id: index, books: group,
                    dimensions: Dictionary(uniqueKeysWithValues: group.map { ($0.id, size) }))
            }
    }

    static func pages(
        books: [Book], styles: [Int: SpineStyle], coverRatios: [Int: Double],
        width: CGFloat, rowHeight: CGFloat
    ) -> [ShelfPage] {
        let measurement = PerformanceDiagnostics.begin("ShelfPages")
        defer { measurement.end() }
        var pages: [ShelfPage] = []
        var group: [Book] = []
        var dimensions: [Int: SpineDimensions] = [:]
        var used: CGFloat = 0
        for book in books {
            let size: SpineDimensions
            if let style = styles[book.id] {
                let natural = ShelfLayout.dimensions(for: book, among: books, rowHeight: rowHeight)
                size = SpineTextMetrics.readableDimensions(
                    for: book, style: style, natural: natural, rowHeight: rowHeight)
            } else {
                let ratio = coverRatios[book.id] ?? (2.0 / 3.0)
                let height = rowHeight * 0.92
                let naturalWidth = height * max(0.1, min(10, ratio))
                let scale = min(1, max(1, width) / naturalWidth)
                size = SpineDimensions(width: naturalWidth * scale, height: height * scale)
            }
            let next = used + (group.isEmpty ? 0 : ShelfLayout.gap) + size.width
            if !group.isEmpty && next > width {
                pages.append(ShelfPage(id: pages.count, books: group, dimensions: dimensions))
                group = []
                dimensions = [:]
                used = 0
            }
            used += (group.isEmpty ? 0 : ShelfLayout.gap) + size.width
            group.append(book)
            dimensions[book.id] = size
        }
        if !group.isEmpty {
            pages.append(ShelfPage(id: pages.count, books: group, dimensions: dimensions))
        }
        return pages
    }
}

/// Layout invalidation depends on content and geometry, never focus or remote input.
struct ShelfPreparationKey: Equatable {
    let revision: Int
    let fontRevision: Int
    let width: CGFloat
    let height: CGFloat
}

struct ComparisonPreparationKey: Equatable {
    let books: [ReaderBook]
    let revision: Int
    let width: CGFloat
    let height: CGFloat
}
