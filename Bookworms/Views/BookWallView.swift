import RealityKit
import SwiftUI

/// Keeps native tab focus controls aligned with the full-screen 3D wall.
struct BookWallView: View {
    let library: LibraryModel
    let coordinator: BookwormsCoordinator
    let scene: BookWallScene
    let prepared: BookWallPreparedWall
    let viewportFrame: CGRect
    let isActive: Bool
    let reviewLoader: (Book) -> (@MainActor () async throws -> [BookReview])?
    /// Shows My Shelf filtered to the author or genre chosen in the given book's details.
    let onShowShelf: (Book, ShelfFilter) -> Void
    let series: (Book) -> SeriesInfo?
    let libraryBook: (Int) -> Book?
    /// Opens details for another library book, chosen from the series pop-up.
    let onOpenBook: (Book) -> Void
    let onActivity: () -> Void
    let returnRevision: Int
    let detailState: BookWallDetailState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedBook: Int?
    @State private var frames: [Int: CGRect] = [:]
    @State private var isSettled = false
    @State private var hasSettledOnce = false
    @State private var openingBookID: Int?
    @State private var detailBook: Book?
    @State private var isReturning = false
    @State private var transitionTask: Task<Void, Never>?
    @State private var transitionRevision = 0
    @State private var configurationRevision = 0
    @State private var openingFailed = false
    #if DEBUG && targetEnvironment(simulator)
        /// Counts completed falls so UI tests can confirm that Drop again ran a replay. With
        /// Reduce Motion, the status text can clear before a test reads it.
        @State private var completedFalls = 0
    #endif

    private var books: [Book] { prepared.books }
    private var entryID: Int? {
        #if DEBUG && targetEnvironment(simulator)
            // Scenario hook: chooses the entry book for Simulator captures.
            if let argument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix("--book-wall-entry=")
            }),
                let id = Int(argument.dropFirst("--book-wall-entry=".count)),
                books.contains(where: { $0.id == id })
            {
                return id
            }
        #endif
        if let remembered = coordinator.wallSelection,
            books.contains(where: { $0.id == remembered })
        {
            return remembered
        }
        return books.first?.id
    }

    #if DEBUG && targetEnvironment(simulator)
        @MainActor private static var openedEntryForScenario = false
    #endif

    var body: some View {
        GeometryReader { geometry in
            // RealityKit projects into the full-screen canvas. Tab content can have a
            // different origin, so convert both hit targets and detail destinations.
            let tabFrame = geometry.frame(in: .global)
            let tabOrigin = CGPoint(
                x: tabFrame.minX - viewportFrame.minX,
                y: tabFrame.minY - viewportFrame.minY)
            // Details occupy the rectangle cover details do. The tab extends above the viewport,
            // under the top safe area that cover details respect, so restore that inset.
            let topInset = max(0, -tabOrigin.y)
            let detailFrame = CGRect(
                x: tabOrigin.x, y: tabOrigin.y + topInset,
                width: geometry.size.width, height: geometry.size.height - topInset)
            // Until the scene publishes frames for this configuration, the planned resting
            // frames place the spines, so they exist in the tab's first render and the
            // sidebar's focus handoff finds the entry book through `.defaultFocus`.
            let spineFrames =
                frames.isEmpty
                ? BookWallScene.plannedFocusFrames(
                    for: prepared.layout, viewport: viewportFrame.size)
                : frames
            ZStack(alignment: .topLeading) {
                if let detailBook, !PerformanceDiagnostics.isolates("wall-no-detail-panel") {
                    BookDetailView(
                        book: detailBook, style: library.style(for: detailBook),
                        loadReviews: reviewLoader(detailBook), showsCover: false,
                        showsBackButton: false,
                        onClose: closeDetail,
                        onShowShelf: { onShowShelf(detailBook, $0) },
                        series: series(detailBook),
                        libraryBook: libraryBook,
                        onOpenBook: onOpenBook
                    )
                    .padding(.top, topInset)
                    .appTypography()
                    .id(detailBook.id)
                    .transition(
                        PerformanceDiagnostics.isolates("wall-instant-panel-exit")
                            ? .asymmetric(insertion: .opacity, removal: .identity) : .opacity)
                }
                // Spine targets exist from the tab's first render at each book's resting
                // position and stay mounted while books fall. Opening details waits for the
                // books to settle.
                if detailBook == nil && !isReturning {
                    ZStack(alignment: .topLeading) {
                        ForEach(books) { book in
                            if let frame = spineFrames[book.id] {
                                Button {
                                    openDetail(
                                        book,
                                        detailFrame: detailFrame)
                                } label: {
                                    // Fully transparent, so the compositor has no layer to
                                    // blend over the 3D wall; focus does not need visible
                                    // content.
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(.white.opacity(0))
                                }
                                .buttonStyle(CoverButtonStyle())
                                .focusEffectDisabled()
                                .focused($focusedBook, equals: book.id)
                                // Keep the selected button mounted and focused throughout
                                // its flight; other books cannot start competing flights.
                                .disabled(openingBookID != nil && openingBookID != book.id)
                                .accessibilityLabel("\(book.title), \(book.author)")
                                .accessibilityHint("Open book details")
                                .accessibilityIdentifier("book-wall-\(book.id)")
                                // Position last: modifiers after `.position` apply to a
                                // container that fills the tab, which accessibility would
                                // then report as every spine's frame.
                                .frame(width: frame.width, height: frame.height)
                                .position(
                                    x: frame.midX - tabOrigin.x,
                                    y: frame.midY - tabOrigin.y
                                )
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .focusSection()
                    .defaultFocus($focusedBook, entryID, priority: .userInitiated)
                    // The targets are invisible, so they appear and leave at once. Inside the
                    // detail fade, an animated removal kept all of them updating on the main
                    // thread for the whole animation, which delayed the wall's frames.
                    .transition(.identity)
                    // Back from a shelf that these details filtered reopens them here, once the
                    // books have settled.
                    .task(id: isSettled ? detailState.requestedBookID : nil) {
                        guard isSettled, let id = detailState.requestedBookID else { return }
                        detailState.requestedBookID = nil
                        guard let book = books.first(where: { $0.id == id }) else { return }
                        openDetail(
                            book, detailFrame: detailFrame)
                    }
                    #if DEBUG && targetEnvironment(simulator)
                        // Scenario hook: opens the entry book once so Simulator captures can
                        // show the detail pose without remote input.
                        .task(id: isSettled) {
                            guard isSettled,
                                ProcessInfo.processInfo.arguments.contains(
                                    "--book-wall-open-entry"),
                                !Self.openedEntryForScenario,
                                let book = books.first(where: { $0.id == entryID })
                            else { return }
                            try? await Task.sleep(for: .seconds(2))
                            Self.openedEntryForScenario = true
                            openDetail(
                                book, detailFrame: detailFrame)
                        }
                    #endif
                }
                if hasSettledOnce && !books.isEmpty && detailBook == nil
                    && !(isReturning && PerformanceDiagnostics.isolates("wall-late-replay"))
                    && !PerformanceDiagnostics.isolates("wall-no-replay")
                {
                    HStack {
                        Spacer()
                        Button(action: replayFall) {
                            Label("Drop again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .disabled(openingBookID != nil || isReturning)
                        .accessibilityHint("Drop the books onto the shelf again")
                        .accessibilityIdentifier("book-wall-replay")
                    }
                    .padding(.top, 34)
                    .padding(.trailing, 80)
                    .focusSection()
                }
                if detailBook == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if books.isEmpty {
                            Text("Books finished this year will appear here.")
                                .appFont(size: 32)
                        } else if !isSettled {
                            Text(
                                reduceMotion ? "Arranging books…" : "Books are falling into place…"
                            )
                            .appFont(size: 25)
                        } else if openingFailed {
                            Text("This book could not open. Please try again.")
                                .appFont(size: 25)
                        }
                        // The focused title and the resting hint appear on the shelf front.
                        Spacer()
                    }
                    .padding(.leading, 250)
                    .padding(.trailing, 300)
                    .padding(.top, 34)
                    .padding(.bottom, 32)
                    .frame(
                        width: geometry.size.width, height: geometry.size.height,
                        alignment: .topLeading
                    )
                    .allowsHitTesting(false)
                }
                #if DEBUG && targetEnvironment(simulator)
                    Text(String(completedFalls))
                        .font(.system(size: 1)).foregroundStyle(.clear)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("book-wall-fall-probe")
                #endif
            }
        }
        .task(id: ConfigurationKey(books: books, isActive: isActive)) {
            cancelTransition()
            configurationRevision &+= 1
            guard isActive else {
                scene.deactivate()
                return
            }
            let revision = configurationRevision
            isSettled = false
            hasSettledOnce = false
            // Empty frames fall back to the planned layout, so the spines stay mounted.
            frames = [:]
            scene.configure(prepared: prepared, reduceMotion: reduceMotion) { newFrames, settled in
                guard revision == configurationRevision else { return }
                frames = newFrames
                guard settled, !isSettled else { return }
                isSettled = true
                hasSettledOnce = !books.isEmpty
                #if DEBUG && targetEnvironment(simulator)
                    completedFalls += 1
                #endif
                // Focus can reach a spine while its book falls; it pulls out once it rests.
                scene.highlight(focusedBook, reduceMotion: reduceMotion)
            }
        }
        .onChange(of: focusedBook) {
            guard isActive, openingBookID == nil, detailBook == nil, !isReturning else { return }
            if let focusedBook { coordinator.wallSelection = focusedBook }
            scene.highlight(focusedBook, reduceMotion: reduceMotion)
            openingFailed = false
            if focusedBook != nil { onActivity() }
        }
        .onChange(of: returnRevision) {
            guard isActive, openingBookID == nil, detailBook == nil, !isReturning else { return }
            // This revision denotes a modal dismissal, not a data or layout change.
            if focusedBook == nil { focusedBook = entryID }
        }
        .onChange(of: detailState.closeRevision) { closeDetail() }
        .onChange(of: viewportFrame.size) {
            if openingBookID != nil || detailBook != nil || isReturning { cancelTransition() }
        }
        .onChange(of: isActive) {
            if !isActive {
                configurationRevision &+= 1
                cancelTransition()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                cancelTransition()
                scene.deactivate()
            }
        }
        .onDisappear {
            configurationRevision &+= 1
            cancelTransition()
            scene.deactivate()
        }
    }

    private var detailFade: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.35) }

    private struct ConfigurationKey: Equatable {
        let books: [Book]
        let isActive: Bool
    }

    private func openDetail(_ book: Book, detailFrame: CGRect) {
        guard isActive, isSettled, openingBookID == nil, detailBook == nil, !isReturning,
            viewportFrame.width > 0, viewportFrame.height > 0
        else { return }
        transitionRevision &+= 1
        let revision = transitionRevision
        openingBookID = book.id
        openingFailed = false
        coordinator.wallSelection = book.id
        onActivity()
        transitionTask = Task { @MainActor in
            let completed = await scene.flyToDetail(
                book, detailFrame: detailFrame, reduceMotion: reduceMotion)
            guard !Task.isCancelled, transitionRevision == revision else { return }
            openingBookID = nil
            transitionTask = nil
            guard completed else {
                scene.cancelTransition()
                scene.highlight(focusedBook, reduceMotion: reduceMotion)
                openingFailed = true
                return
            }
            scene.showOnlyDetailBook(true, reduceMotion: reduceMotion)
            // The wall has already faded in the scene; the text fades in after the book lands.
            detailState.frame = detailFrame.offsetBy(
                dx: viewportFrame.minX, dy: viewportFrame.minY)
            withAnimation(detailFade) {
                detailBook = book
                detailState.isPresented = true
            }
        }
    }

    private func replayFall() {
        guard isActive, isSettled, detailBook == nil, openingBookID == nil, !isReturning,
            scene.replayFall(reduceMotion: reduceMotion)
        else { return }
        // The spine targets stay mounted, so a focused Drop again keeps focus.
        isSettled = false
        openingFailed = false
        onActivity()
    }

    private func closeDetail() {
        guard let book = detailBook, !isReturning else { return }
        transitionRevision &+= 1
        let revision = transitionRevision
        isReturning = true
        // The text fades out while the book only drifts, then the book flies back. Removing the
        // detail views stalls the main thread briefly, which a still book hides and a moving one
        // shows as a stutter. Reduce Motion has no fade, so the return starts at once.
        withAnimation(detailFade) {
            detailState.isPresented = false
            detailBook = nil
        } completion: {
            guard transitionRevision == revision else { return }
            transitionTask = Task { @MainActor in
                await scene.returnFromDetail(reduceMotion: reduceMotion)
                guard !Task.isCancelled, transitionRevision == revision else { return }
                transitionTask = nil
                isReturning = false
                // Closing details is an explicit focus-restoration entry event.
                focusedBook = book.id
                onActivity()
            }
        }
    }

    private func cancelTransition() {
        transitionRevision &+= 1
        transitionTask?.cancel()
        transitionTask = nil
        scene.cancelTransition()
        openingBookID = nil
        detailBook = nil
        isReturning = false
        detailState.isPresented = false
    }
}

/// Book Wall's detail presentation, shared with the Back overlay that `ShelfView` places above
/// the tab control. Keeping it out of `ShelfView`'s own state means opening or closing details
/// updates only the views that read it, not the whole tab hierarchy.
@MainActor @Observable
final class BookWallDetailState {
    var isPresented = false
    /// Increments when the overlay's Back closes details.
    var closeRevision = 0
    /// A wall book whose details open once the wall settles.
    var requestedBookID: Int?
    /// The open details' frame in global coordinates, which positions the Back overlay.
    var frame = CGRect.zero
}
