import SwiftUI

/// One reader's comparison shelf. Pages are repacked only after input settles.
struct ComparisonBookshelf: View {
    let library: LibraryModel
    let books: [ReaderBook]
    @Bindable var state: ComparisonRowState
    let rowHeight: CGFloat
    let width: CGFloat
    var activatesOnAppear = true
    var emptySpacePhoto: String?
    var isLoading = false
    /// The shared page position where focus lands when it enters this row from the other row.
    let column: Int
    let focusRequest: ShelfBookFocusRequest?
    let onSelect: (Book) -> Void
    /// Receives the focused book's position within its page.
    let onFocus: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("woodBackground") private var woodBackground = true
    private let styles: [Int: SpineStyle] = [:]
    @State private var pages: [ShelfPage] = []
    @State private var activity = InteractionActivity()
    private var palette: ShelfPalette {
        ShelfPalette(isDark: colorScheme == .dark, isWood: woodBackground)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !pages.isEmpty {
                ShelfRow(
                    library: library, pages: pages, rowHeight: rowHeight, palette: palette,
                    entryBookID: state.selectedID, entryColumn: column,
                    focusRequest: focusRequest,
                    presentationStyles: styles, activatesOnAppear: activatesOnAppear,
                    emptySpacePhoto: emptySpacePhoto,
                    onFocus: { id in
                        guard let id else { return }
                        state.selectedID = id
                        activity.record()
                        let page = pages.first { $0.books.contains { $0.id == id } }
                        onFocus(page?.books.firstIndex { $0.id == id } ?? 0)
                    }, onSelect: onSelect
                )
            } else {
                Text(isLoading ? "Loading books…" : "No books match this ordering")
                    .appFont(size: 25)
                    .frame(height: rowHeight)
            }
            ShelfBoard(palette: palette, surfaceDepth: 10, edgeHeight: 7)
        }
        .task(
            id: ComparisonPreparationKey(
                books: books, revision: library.presentationRevision, width: width,
                height: rowHeight)
        ) {
            if !pages.isEmpty {
                do { try await activity.waitUntilQuiet() } catch { return }
            }
            // Equal columns keep both rows' books vertically aligned.
            pages = BookPresentation.columnPages(
                books: books.map(\.book), width: width, rowHeight: rowHeight)
        }
    }
}
