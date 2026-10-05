import SwiftUI

/// Shared spacing for screen content and bottom navigation.
enum ShelfScreenLayout {
    static let verticalPadding: CGFloat = 52
    static let footerHeight: CGFloat = 66
    static let contentGap: CGFloat = 22
}

struct ShelfView: View {
    @AppStorage("dateFormat") private var dateFormat = AppDateFormat.monthName
    @AppStorage("woodBackground") private var woodBackground = true
    let library: LibraryModel
    @State private var social = SocialLibraryModel()
    @State private var coordinator: BookwormsCoordinator
    /// The sidebar selection. Ambient and Settings are sidebar destinations that leave
    /// `coordinator.current` on the last main view.
    @State private var sidebarItem: SidebarItem
    @State private var settingsSection = SettingsView.initialSection()
    @State private var ambient = AmbientController()
    @State private var preparedPages: [ShelfPage] = []
    /// Chooses the shelf photo; changes each time My Shelf appears.
    @State private var photoSeed = Int.random(in: 0..<1000)
    @State private var activity = InteractionActivity()
    @State private var hasEnteredShelf = false
    @State private var preparedArtwork: ViewArtworkKey?
    @State private var artworkGeneration = 0
    @State private var presentationStyles: [Int: SpineStyle] = [:]
    @State private var socialReturnRevision = 0
    @State private var bookWallScene = BookWallScene()
    @State private var bookWallPreparation = BookWallPreparation()
    @State private var bookWallPreparationRetry = 0
    @State private var wallDetail = BookWallDetailState()
    @State private var wallViewportFrame = CGRect.zero
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ShelfPalette {
        ShelfPalette(isDark: colorScheme == .dark, isWood: woodBackground)
    }

    /// Renders the wall background once per palette and size for Book Wall's lit backdrop,
    /// at one pixel per point to match the scene's 1080p render cap.
    private func renderWallBackdrop() {
        let size = wallViewportFrame.size
        guard size.width > 0, size.height > 0 else { return }
        let renderer = ImageRenderer(
            content: WoodBackground(palette: palette).frame(width: size.width, height: size.height))
        renderer.scale = 1
        if let image = renderer.cgImage { bookWallScene.setBackdrop(image) }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    private var controlsVisible: Bool { activity.controlsVisible }
    private var wallBooks: [Book] {
        let year = Calendar.current.component(.year, from: .now)
        return library.readingYears.first { $0.year == year }?.books ?? []
    }
    private var wallPreparationKey: BookWallPreparationKey {
        BookWallPreparationKey(
            loaded: library.hasLoadedLibrarySnapshot,
            enabled: coordinator.preferences.orderedViews.contains(.bookWall),
            books: wallBooks, retry: bookWallPreparationRetry)
    }
    private var waitsForBookWall: Binding<Bool> {
        Binding(
            get: {
                coordinator.current == .bookWall
                    && !bookWallPreparation.isReady(for: wallBooks)
            },
            set: { presented in
                if !presented && !bookWallPreparation.isReady(for: wallBooks) {
                    showView(.shelf)
                }
            })
    }
    @State private var openedDevelopmentDetail = false
    @State private var appliedDevelopmentPage = false
    @State private var selectedBook: Book?
    /// The book whose details applied the shelf filter, and the view those details opened over.
    @State private var filterOrigin: (book: Book, view: BookwormsView)?
    private enum SidebarItem: Hashable {
        case view(BookwormsView)
        case ambient
        case settings
    }
    private var isShowingMainView: Bool {
        if case .view = sidebarItem { true } else { false }
    }
    @State private var lastSelectedID: Int?
    @State private var lastFocusedID: Int?
    @State private var focusedBook: Int?
    @State private var bookFocusRequest: ShelfBookFocusRequest?

    #if DEBUG && targetEnvironment(simulator)
        private var scenarioShelfState: [String: Any] {
            [
                "artworkReady": preparedArtwork == artworkKey,
                "pagesReady": !preparedPages.isEmpty,
                "hasEnteredShelf": hasEnteredShelf,
                "focusedBook": focusedBook ?? -1,
                "requestedBook": bookFocusRequest?.id ?? -1,
            ]
        }
    #endif

    init(library: LibraryModel) {
        self.library = library
        #if DEBUG && targetEnvironment(simulator)
            let scenario = ScenarioRuntime.current
            let coordinator =
                scenario.map { BookwormsCoordinator(defaults: $0.defaults) }
                ?? BookwormsCoordinator()
            if let scenario {
                _social = State(initialValue: scenario.socialModel())
                _ambient = State(initialValue: scenario.ambientController())
            }
        #else
            let coordinator = BookwormsCoordinator()
        #endif
        _coordinator = State(initialValue: coordinator)
        _sidebarItem = State(initialValue: .view(coordinator.current))
    }

    /// Maps sidebar selection to the coordinator. Only main views change `coordinator.current`.
    private var sidebarSelection: Binding<SidebarItem> {
        Binding(
            get: { sidebarItem },
            set: { item in
                sidebarItem = item
                if case .view(let view) = item { coordinator.current = view }
            })
    }

    /// Selects `view`, or the first sidebar view when the user has hidden it.
    private func showView(_ view: BookwormsView) {
        let shown =
            coordinator.preferences.orderedViews.contains(view)
            ? view : coordinator.preferences.orderedViews[0]
        sidebarItem = .view(shown)
        coordinator.current = shown
    }

    /// The tab hierarchy with its backgrounds and overlays.
    private var tabs: some View {
        TabView(selection: sidebarSelection) {
            ForEach(coordinator.preferences.orderedViews) { view in
                Tab(view.rawValue, systemImage: view.systemImage, value: SidebarItem.view(view)) {
                    tabContent(for: view)
                }
            }
            Tab("Ambient", systemImage: "play.rectangle", value: SidebarItem.ambient) {
                ambientLauncher
            }
            Tab("Settings", systemImage: "gearshape", value: SidebarItem.settings) {
                SettingsView(
                    library: library, social: social, coordinator: coordinator,
                    section: $settingsSection, onShowShelf: { showView(.shelf) })
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background {
            // Measured on every tab, so Book Wall can place its spine targets in its first
            // render, before its renderer exists.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { frame in
                    wallViewportFrame = frame
                }
            if sidebarItem == .view(.bookWall) {
                ZStack {
                    WoodBackground(palette: palette)
                    BookWallRendererView(scene: bookWallScene)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea()
                .task(
                    id: WallBackdropKey(
                        isDark: palette.isDark, isWood: palette.isWood,
                        width: wallViewportFrame.width, height: wallViewportFrame.height)
                ) {
                    renderWallBackdrop()
                }
            }
        }
        .environment(\.artworkGeneration, artworkGeneration)
        .tvOSSidebarHeader {
            sidebarHeader
        }
        .overlay { BookWallDetailOverlay(state: wallDetail, palette: palette) }
    }

    var body: some View {
        // The tab hierarchy and these lifecycle modifiers are separate expressions; together
        // they exceed the type checker's time limit.
        tabs
            .fullScreenCover(isPresented: waitsForBookWall) {
                bookWallWaitingView
            }
            #if BOOKWORMS_DIAGNOSTICS
                .background { PerformanceDiagnosticObserver().allowsHitTesting(false) }
            #endif
            #if DEBUG && targetEnvironment(simulator)
                .overlay(alignment: .topLeading) {
                    if let scenario = ScenarioRuntime.current { ScenarioProbe(runtime: scenario) }
                }
                .background(alignment: .topLeading) {
                    if FocusTransitionProbe.isEnabled {
                        FocusTransitionProbe().frame(width: 1, height: 1)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: ScenarioRuntime.commandNotification)
                ) { notification in
                    if let scenario = ScenarioRuntime.current,
                        let command = notification.object as? String
                    {
                        _ = scenario.handle(
                            scenario.commandURL(command), library: library, ambient: ambient,
                            availableViews: availableAmbientViews, shelfState: scenarioShelfState)
                    }
                }
            #endif
            .onChange(of: canHideControls, initial: true) {
                activity.scheduleHiding(allowed: canHideControls)
            }
            .onDisappear { activity.scheduleHiding(allowed: false) }
            .task(id: wallPreparationKey, priority: .utility) {
                let key = wallPreparationKey
                guard key.loaded, key.enabled else { return }
                await bookWallPreparation.prepare(key.books)
            }
            .onChange(of: bookWallPreparation.coverRevision) { bookWallScene.setNeedsFrame() }
            .onChange(of: coordinator.preferences, initial: true) {
                social.prepare(coordinator.preferences)
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    recordActivity()
                    library.reloadCredentialAvailability()
                    Task {
                        await library.becameActive()
                        await loadSocial()
                    }
                } else {
                    ambient.stop()
                }
            }
            .task(id: artworkKey) { await prepareArtwork() }
            .onChange(of: voiceOver) {
                if voiceOver { ambient.stop() }
                recordActivity()
            }
            .task(
                id:
                    "\(library.hardcoverConnected):\(library.hardcoverEnabled):\(library.isSample)"
            ) { await loadSocial() }
            .task(id: library.connectionRevision) {
                // Explicit reconnection retries social permissions even after a denied daily attempt.
                if library.connectionRevision > 0 { await loadSocial(manual: true) }
            }
            .task(
                id: SocialLoadKey(
                    readerID: coordinator.preferences.readerID,
                    enabled: coordinator.preferences.activeViews)
            ) {
                if !ambient.isActive { await loadSocial() }
            }
            .onChange(of: ambient.isActive) { library.setAmbientActive(ambient.isActive) }
            .onChange(of: coordinator.current) {
                // Disabling the current view in Settings falls back to My Shelf without leaving Settings.
                if isShowingMainView { sidebarItem = .view(coordinator.current) }
                if coordinator.current == .comparison || coordinator.current == .shared {
                    ensureComparisonReader()
                }
                recordActivity()
                focusedBook = nil
                bookFocusRequest = nil
            }
            .onPlayPauseCommand { recordActivity() }
            .onOpenURL { url in
                #if DEBUG && targetEnvironment(simulator)
                    if ScenarioRuntime.current?
                        .handle(
                            url, library: library, ambient: ambient,
                            availableViews: availableAmbientViews, shelfState: scenarioShelfState)
                        == true
                    {
                        return
                    }
                #endif
                guard let id = BookLink.id(from: url) else { return }
                showView(.shelf)
                library.requestedBookID = id
            }
            .fullScreenCover(
                item: $selectedBook, onDismiss: restoreSelection
            ) { book in
                BookDetailView(
                    book: library.book(withID: book.id) ?? book,
                    style: library.style(for: book),
                    loadReviews: reviewLoader(for: book),
                    onShowShelf: { filter in
                        // The book matches its own author and genres, so focus returns to it.
                        lastFocusedID = book.id
                        filterOrigin = (book, coordinator.current)
                        library.shelfFilter = filter
                        showView(.shelf)
                        selectedBook = nil
                    },
                    series: library.series(for: library.book(withID: book.id) ?? book),
                    libraryBook: { library.book(withID: $0) },
                    onOpenBook: { chosen in
                        lastFocusedID = chosen.id
                        selectedBook = chosen
                    }
                )
                .appTypography()
                .id(book.id)
            }
            .fullScreenCover(
                isPresented: Binding(get: { ambient.isActive }, set: { if !$0 { ambient.stop() } }),
                onDismiss: finishAmbientDismissal
            ) {
                AmbientView(
                    controller: ambient, library: library, social: social,
                    preferences: coordinator.preferences
                )
                .appTypography()
                #if DEBUG && targetEnvironment(simulator)
                    .overlay(alignment: .topLeading) {
                        if let scenario = ScenarioRuntime.current {
                            ScenarioProbe(runtime: scenario)
                        }
                    }
                #endif
            }
    }

    private func finishAmbientDismissal() {
        library.setAmbientActive(false)
        restoreSelection()
    }

    private struct ViewArtworkKey: Equatable {
        let libraryRevision: Int
        let books: [Book]
        let avatarURLs: [URL]
    }

    private struct BookWallPreparationKey: Equatable {
        let loaded: Bool
        let enabled: Bool
        let books: [Book]
        let retry: Int
    }

    private var bookWallWaitingView: some View {
        ZStack {
            WoodBackground(palette: palette)
            VStack(spacing: 28) {
                Text("Preparing Book Wall").appFont(size: 52)
                if let failure = bookWallPreparation.failure {
                    Text(failure).appFont(size: 28)
                    Button("Retry") { bookWallPreparationRetry &+= 1 }
                } else {
                    ProgressView()
                    Text(
                        library.hasLoadedLibrarySnapshot
                            ? "\(bookWallPreparation.completedCount) of \(bookWallPreparation.totalCount) book spines ready"
                            : "Loading your library…"
                    )
                    .appFont(size: 28)
                }
                Button("Back to My Shelf") { showView(.shelf) }
            }
            .padding(72)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    /// Content waits for the first artwork preparation that includes books, then stays mounted.
    private var hasPreparedArtwork: Bool {
        guard let preparedArtwork else { return false }
        return !preparedArtwork.books.isEmpty || artworkKey.books.isEmpty
    }

    private var artworkKey: ViewArtworkKey {
        var books = Array(library.books.prefix(BookLimit.maximum))
        var avatars: [URL] = []
        if let ownerAvatar = social.snapshot?.owner.avatarURL {
            avatars.append(ownerAvatar)
        }
        // The selected comparison reader appears beside ratings and reviews.
        if let readerAvatar = social.reader(coordinator.preferences.readerID)?.avatarURL {
            avatars.append(readerAvatar)
        }
        let enabled = coordinator.preferences.activeViews
        if enabled.contains(.following) {
            books += social.activities.prefix(20).compactMap(\.book)
            avatars += social.activities.prefix(20).compactMap { $0.reader.avatarURL }
        }
        if enabled.contains(.comparison) {
            books += social.presentation.mine.prefix(BookLimit.maximum).map(\.book)
            books += social.presentation.theirs.prefix(BookLimit.maximum).map(\.book)
        }
        if enabled.contains(.shared) {
            books += social.presentation.shared.prefix(BookLimit.maximum).map { $0.mine.book }
        }
        if enabled.contains(.friendsPicks) {
            let picks = social.presentation.picks.prefix(BookLimit.maximum)
            books += picks.map(\.book)
            avatars += picks.flatMap { $0.fans.prefix(3).compactMap(\.avatarURL) }
        }
        // Ambient My Shelf leads with them; at most a handful on any date.
        if coordinator.preferences.ambientOrderedViews.contains(.shelf) {
            books += library.onThisDay.prefix(BookLimit.maximum)
        }
        // Only the chosen year; choosing another year prepares its covers, as choosing a reader
        // does for Compare Shelves.
        if enabled.contains(.yearInReview),
            let review = library.yearInReview(coordinator.reviewYear)
        {
            books += review.shelf
        }
        var seen = Set<Int>()
        return ViewArtworkKey(
            libraryRevision: library.artworkRevision,
            books: books.filter { seen.insert($0.id).inserted }, avatarURLs: avatars)
    }

    private struct SocialLoadKey: Equatable {
        let readerID: Int?
        let enabled: [BookwormsView]
    }

    private func ensureComparisonReader() {
        guard !social.following.isEmpty else { return }
        if coordinator.preferences.readerID == nil
            || !social.following.contains(where: { $0.id == coordinator.preferences.readerID })
        {
            coordinator.preferences.readerID = social.following.randomElement()?.id
        }
    }

    private func loadSocial(manual: Bool = false) async {
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--cached-social-preview") {
                social.useCachedSnapshotForPreview()
                ensureComparisonReader()
                return
            }
        #endif
        if library.isSample {
            social.useSample(books: library.books)
            ensureComparisonReader()
        } else {
            social.leaveSample()
            ensureComparisonReader()
            await social.load(
                token: library.hardcoverTokenForSync(),
                readerID: coordinator.preferences.readerID, manual: manual,
                enabledViews: Set(coordinator.preferences.activeViews))
            ensureComparisonReader()
            if let current = coordinator.preferences.readerID,
                social.books(for: current).isEmpty
            {
                await social.load(
                    token: library.hardcoverTokenForSync(),
                    readerID: current, manual: manual,
                    enabledViews: Set(coordinator.preferences.activeViews))
            }
        }
    }

    private var canHideControls: Bool {
        (focusedBook != nil || coordinator.current != .shelf) && !voiceOver
            && !library.books.isEmpty && isShowingMainView && selectedBook == nil
            && !ambient.isActive
    }

    private func recordActivity() {
        PerformanceDiagnostics.event("RecordActivity")
        activity.record()
    }

    private func requestBookFocus(_ id: Int?) {
        guard let id else { return }
        bookFocusRequest = ShelfBookFocusRequest(
            id: id, revision: (bookFocusRequest?.revision ?? 0) &+ 1)
    }

    /// Returns a loader for community reviews, or `nil` when Hardcover can't supply them. It
    /// checks cached credential flags now and reads the token only when the reviews sheet opens.
    private func reviewLoader(for book: Book) -> (@MainActor () async throws -> [BookReview])? {
        if library.isSample { return { SampleLibrary.reviews } }
        guard book.isHardcoverBook, library.hardcoverEnabled, library.hardcoverConnected
        else { return nil }
        return { [library] in
            guard let token = library.hardcoverTokenForSync() else {
                throw HardcoverError.invalidToken
            }
            return try await HardcoverSocialClient().reviews(book: book.id, token: token)
        }
    }

    /// Prefetches covers and avatars for the active views, then moves focus into the first view
    /// once. Kept out of `body`, whose modifier chain is near the type checker's time limit.
    private func prepareArtwork() async {
        let key = artworkKey
        let preparation = await ArtworkStore.shared.prefetch(
            books: key.books, avatarURLs: key.avatarURLs)
        guard !Task.isCancelled, key == artworkKey else { return }
        for (id, ratio) in preparation.ratios { library.recordCoverRatio(ratio, for: id) }
        let firstShelfEntry =
            !hasEnteredShelf && !library.books.isEmpty && coordinator.current == .shelf
        let firstPreparation = !hasPreparedArtwork
        preparedArtwork = key
        artworkGeneration &+= 1
        // Later preparations keep content mounted and must not move focus.
        if firstShelfEntry || firstPreparation {
            DispatchQueue.main.async {
                // A newer library can replace the prepared books before this focus transaction runs.
                guard key == artworkKey, preparedArtwork == key else { return }
                // Selecting a main view later moves focus into it natively.
                guard isShowingMainView, selectedBook == nil, !ambient.isActive else { return }
                if coordinator.current == .shelf {
                    guard
                        let entry =
                            preparedPages.first?.books.first?.id ?? library.books.first?.id
                    else { return }
                    hasEnteredShelf = true
                    requestBookFocus(entry)
                } else {
                    socialReturnRevision += 1
                }
            }
        }
        // Browsing covers follow the library's and don't wait for the retry below; a newer
        // preparation cancels this one and resumes after the covers already saved.
        _ = await ArtworkStore.shared.prefetchBrowsing(library.browsingCoverURLs)
        // Retry covers that failed, such as after a timeout, once. Mounted covers reload from the
        // local cache when the generation changes; browsing itself never downloads.
        if !preparation.failed.isEmpty {
            guard (try? await Task.sleep(for: .seconds(30))) != nil, key == artworkKey else {
                return
            }
            await ArtworkStore.shared.forgetFailures()
            let retry = await ArtworkStore.shared.prefetch(
                books: preparation.failed, avatarURLs: [])
            guard !Task.isCancelled, key == artworkKey else { return }
            if !retry.ratios.isEmpty {
                for (id, ratio) in retry.ratios { library.recordCoverRatio(ratio, for: id) }
                artworkGeneration &+= 1
            }
        }

    }

    /// Reopens the details that filtered My Shelf, over the view they opened from, and clears the
    /// filter. `nil` without such a filter, so Back keeps opening the sidebar.
    // ponytail: one level of history; after chained filters, Back reopens the latest origin.
    private var returnToFilterOrigin: (() -> Void)? {
        guard let origin = filterOrigin, library.shelfFilter != nil else { return nil }
        return {
            filterOrigin = nil
            library.shelfFilter = nil
            lastFocusedID = origin.book.id
            showView(origin.view)
            // Book Wall reopens its own details for a book it holds; other views use the cover.
            if coordinator.current == .bookWall,
                wallBooks.contains(where: { $0.id == origin.book.id })
            {
                coordinator.wallSelection = origin.book.id
                wallDetail.requestedBookID = origin.book.id
            } else {
                selectedBook = origin.book
            }
        }
    }

    private func restoreSelection() {
        recordActivity()
        guard isShowingMainView else { return }
        if coordinator.current == .shelf {
            requestBookFocus(lastFocusedID ?? lastSelectedID)
        } else {
            socialReturnRevision += 1
        }
    }

    private func openRequestedBook() {
        guard let id = library.requestedBookID,
            let book = library.book(withID: id)
        else { return }
        lastSelectedID = id
        lastFocusedID = id
        selectedBook = book
        library.requestedBookID = nil
    }

    private var availableAmbientViews: [BookwormsView] {
        AmbientView.available(
            library: library, social: social, preferences: coordinator.preferences)
    }

    @ViewBuilder
    private func tabContent(for view: BookwormsView) -> some View {
        GeometryReader { geometry in
            let rowHeight = geometry.size.height * 0.60
            // Matches the shelf's horizontal padding and PagedRow's inner edge insets.
            let available = geometry.size.width - 160 - 2 * PagedRowLayout.edgeInset
            ZStack(alignment: .bottomTrailing) {
                // The wall renders behind the TabView in a full-screen surface. Its tab
                // stays transparent so sidebar chrome remains above the same 3D models.
                if view != .bookWall { WoodBackground(palette: palette) }
                VStack(alignment: .leading, spacing: 0) {
                    if !hasPreparedArtwork {
                        ProgressView("Loading view…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if view == .bookWall {
                        if let prepared = bookWallPreparation.prepared,
                            prepared.books == wallBooks
                        {
                            BookWallView(
                                library: library, coordinator: coordinator, scene: bookWallScene,
                                prepared: prepared, viewportFrame: wallViewportFrame,
                                isActive: sidebarItem == .view(.bookWall),
                                reviewLoader: reviewLoader(for:),
                                onShowShelf: { book, filter in
                                    lastFocusedID = book.id
                                    filterOrigin = (book, .bookWall)
                                    library.shelfFilter = filter
                                    showView(.shelf)
                                },
                                series: { library.series(for: library.book(withID: $0.id) ?? $0) },
                                libraryBook: { library.book(withID: $0) },
                                // A series book opens in the cover details, even one on the wall.
                                onOpenBook: { selectedBook = $0 },
                                onActivity: recordActivity,
                                returnRevision: socialReturnRevision,
                                detailState: wallDetail
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ProgressView("Preparing Book Wall…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if view == .yearInReview {
                        YearInReviewView(
                            library: library, coordinator: coordinator, palette: palette,
                            onSelect: {
                                selectedBook = $0
                                recordActivity()
                            }, onActivity: recordActivity,
                            returnRevision: socialReturnRevision
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if view != .shelf {
                        SocialViews(
                            library: library, social: social, coordinator: coordinator,
                            onSelect: {
                                selectedBook = $0
                                recordActivity()
                            }, onActivity: recordActivity,
                            returnRevision: socialReturnRevision
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if library.books.isEmpty {
                        emptyShelf.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 30)
                        if !preparedPages.isEmpty {
                            shelfRow(rowHeight: rowHeight)
                        } else {
                            ProgressView("Preparing shelf…").frame(height: rowHeight)
                        }
                        ShelfBoard(palette: palette)
                        selectionCaption.frame(height: 134, alignment: .topLeading)
                            .padding(.top, 24)
                        Spacer(minLength: 12)
                        shelfStatus
                    }
                }
                .padding(
                    .horizontal,
                    view == .bookWall ? 0 : (view == .following || view == .comparison ? 48 : 80)
                )
                .padding(.top, view.hasHeader ? 0 : ShelfScreenLayout.verticalPadding)
                // Year in Review's covers need the height more than the caption needs the margin.
                .padding(
                    .bottom,
                    view == .bookWall
                        ? 0
                        : view == .yearInReview
                            ? ShelfScreenLayout.verticalPadding / 2
                            : ShelfScreenLayout.verticalPadding
                )

                if !view.hasHeader {
                    controls
                        .padding(.trailing, 80)
                        .padding(.bottom, ShelfScreenLayout.verticalPadding)
                }
            }
            .ignoresSafeArea(edges: view.hasHeader ? .top : [])
            // The one place main content handles Back: a shelf that details filtered returns to
            // those details. Everywhere else the handler is `nil` and Back opens the sidebar.
            .onExitCommand(perform: view == .shelf ? returnToFilterOrigin : nil)
            .task(
                id: ShelfPreparationKey(
                    revision: library.presentationRevision, fontRevision: library.fontRevision,
                    width: available, height: rowHeight)
            ) {
                guard available > 0, rowHeight > 0 else { return }
                if !preparedPages.isEmpty {
                    do { try await activity.waitUntilQuiet() } catch { return }
                }
                let measurement = PerformanceDiagnostics.begin("DeferredRepack")
                defer { measurement.end() }
                let candidates = Dictionary(
                    library.books.compactMap { book in
                        library.savedSpineStyle(for: book).map { (book.id, $0) }
                    }, uniquingKeysWith: { first, _ in first })
                let styles =
                    BookPresentation.showsGeneratedSpines
                    ? BookPresentation.uniformStyles(books: library.books, styles: candidates) : [:]
                let updated = BookPresentation.pages(
                    books: library.books, styles: styles, coverRatios: library.coverRatios,
                    width: available, rowHeight: rowHeight)
                presentationStyles = styles
                preparedPages = updated
                openRequestedBook()
            }
            .onChange(of: preparedPages.map { $0.books.map(\.id) }, initial: true) {
                #if DEBUG
                    if !appliedDevelopmentPage,
                        let argument = ProcessInfo.processInfo.arguments.first(where: {
                            $0.hasPrefix("--start-shelf-page=")
                        }),
                        let requestedPage = Int(argument.dropFirst("--start-shelf-page=".count)),
                        preparedPages.indices.contains(requestedPage)
                    {
                        appliedDevelopmentPage = true
                        lastFocusedID = preparedPages[requestedPage].books.first?.id
                        requestBookFocus(lastFocusedID)
                    }
                    if !openedDevelopmentDetail,
                        let argument = ProcessInfo.processInfo.arguments.first(where: {
                            $0.hasPrefix("--show-book=")
                        }),
                        let id = Int(argument.dropFirst("--show-book=".count)),
                        let book = library.books.first(where: { $0.id == id })
                    {
                        openedDevelopmentDetail = true
                        lastSelectedID = id
                        selectedBook = book
                    }
                #endif
                openRequestedBook()
            }
            .onChange(of: library.requestedBookID) { openRequestedBook() }
        }
    }

    /// The Hardcover profile above the sidebar list. The photo centers on the rows' icons and the
    /// name starts where their titles start; the name takes the sidebar's font, like the rows.
    /// Offsets measured from the tvOS 27 sidebar on Apple TV.
    private var sidebarHeader: some View {
        HStack(spacing: 14) {
            Group {
                if let avatarURL = social.snapshot?.owner.avatarURL {
                    CachedAvatarView(url: avatarURL)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            Text(social.snapshot?.owner.displayName ?? "Bookworms")
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 12)
    }

    /// Chooses ambient timing and starts playback. The sidebar item opens this page instead of
    /// starting playback directly, so moving focus through the sidebar never starts it.
    private var ambientLauncher: some View {
        let available = !availableAmbientViews.isEmpty && !voiceOver
        return VStack(spacing: 26) {
            Image(systemName: "play.rectangle").appFont(size: 80, weight: .ultraLight)
                .foregroundStyle(palette.text)
                .accessibilityHidden(true)
            Text("Ambient mode").appFont(size: 42).foregroundStyle(palette.text)
            Text(
                voiceOver
                    ? "Ambient mode is unavailable while VoiceOver is running."
                    : availableAmbientViews.isEmpty
                        ? "Ambient mode needs at least one chosen view with content."
                        : "Rotates the views you choose below on a dimmed screen. Content changes every minute. Press any button to stop."
            )
            .appFont(size: 25).multilineTextAlignment(.center).frame(maxWidth: 850)
            .foregroundStyle(palette.text)
            // Two columns, like Settings: timing on the left, views on the right. Each column is a
            // focus section so Left and Right move between them from any row.
            HStack(alignment: .top, spacing: 64) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("View interval").appFont(size: 26, weight: .medium)
                        .foregroundStyle(palette.text)
                    Picker(
                        "Ambient view interval", selection: $coordinator.preferences.ambientMinutes
                    ) {
                        ForEach([5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Session length").appFont(size: 26, weight: .medium)
                        .foregroundStyle(palette.text)
                        .padding(.top, 10)
                    Picker("Ambient session", selection: $coordinator.preferences.sessionMinutes) {
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("Until stopped").tag(0)
                    }
                    .pickerStyle(.segmented)
                }
                // Wide enough for four session segments, including "Until stopped".
                .frame(width: 920)
                .focusSection()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Views").appFont(size: 26, weight: .medium)
                        .foregroundStyle(palette.text)
                    // One full-width row per view, in sidebar order, so names never truncate.
                    ForEach(ambientChoices) { view in
                        Toggle(
                            view.rawValue,
                            isOn: Binding(
                                get: { coordinator.preferences.ambientOrderedViews.contains(view) },
                                set: { coordinator.setInAmbient(view, $0) }
                            )
                        )
                        .font(.system(size: 24))
                        .accessibilityIdentifier("ambient-view-\(view)")
                    }
                    Text("Hiding a view from the menu doesn't remove it here.")
                        .appFont(size: 22).foregroundStyle(palette.text).opacity(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 460)
                .focusSection()
            }
            .padding(.top, 10)
            Button("Start ambient mode") {
                library.setAmbientActive(true)
                if !ambient.start(
                    views: availableAmbientViews,
                    preferences: coordinator.preferences, voiceOver: voiceOver)
                {
                    library.setAmbientActive(false)
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(!available)
            .accessibilityIdentifier("start-ambient")
            // A full-width section catches Down from any view toggle, not only the centered one.
            .frame(maxWidth: .infinity)
            .focusSection()
        }
        // Text takes the palette color individually; controls keep system colors so focused
        // controls stay legible. The page uses the system font throughout, like Settings: its
        // native segmented pickers can't take the app font, so matching them avoids mixed faces.
        .fontDesign(.default)
        .environment(\.appFontStyle, .sansSerif)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WoodBackground(palette: palette) }
    }

    /// Views the Ambient page offers as toggles, in sidebar order.
    private var ambientChoices: [BookwormsView] {
        BookwormsView.allCases.filter(\.supportsAmbient)
    }

    private var controls: some View {
        ViewSpecificControls(library: library, coordinator: coordinator)
    }

    private var selectionCaption: some View {
        let book = library.books.first { $0.id == (focusedBook ?? lastFocusedID) }
        return Group {
            if let book {
                BookCaption(
                    book: book, dateFormat: dateFormat,
                    comparesCommunity: library.shelfPreferences.sort == .hotTakes)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select a book to look inside").appFont(size: 33, weight: .medium)
                    Text("Use the remote to explore your shelf").appFont(size: 29).opacity(0.82)
                }
            }
        }
        .foregroundStyle(palette.text)
        .accessibilityHidden(true)
    }

    private var shelfStatus: some View {
        HStack(spacing: 22) {
            if let filter = library.shelfFilter {
                Button {
                    library.shelfFilter = nil
                } label: {
                    Label(filter.name, systemImage: "xmark")
                }
                .buttonStyle(.glass)
                .appFont(size: 24, weight: .medium)
                .accessibilityLabel("Clear filter: \(filter.name)")
                .accessibilityIdentifier("clear-shelf-filter")
            }
            if library.isSample {
                Text("Sample shelf").appFont(size: 21)
                    .foregroundStyle(palette.text.opacity(0.6))
            }
            Spacer()
        }
        // A full-width section, so Down from any cover reaches the filter's clear button.
        .focusSection()
    }

    private func shelfRow(rowHeight: CGFloat) -> some View {
        ShelfRow(
            library: library, pages: preparedPages, rowHeight: rowHeight, palette: palette,
            entryBookID: lastFocusedID,
            focusRequest: bookFocusRequest,
            presentationStyles: presentationStyles,
            emptySpacePhoto: ShelfPhoto.names(seed: photoSeed)[0],
            onFocus: { id in
                focusedBook = id
                if let id { lastFocusedID = id }
                recordActivity()
            },
            onSelect: { book in
                recordActivity()
                lastSelectedID = book.id
                selectedBook = book
            }
        )
        .onAppear { photoSeed = Int.random(in: 0..<1000) }
    }

    private var emptyShelf: some View {
        VStack(spacing: 26) {
            Image(systemName: "books.vertical").appFont(size: 80, weight: .ultraLight)
                .accessibilityHidden(true)
            Text(
                library.shelfFilter != nil
                    ? "No books on your shelf match"
                    : library.isConnected ? "Your shelf is waiting" : "Make room for your books"
            )
            .appFont(size: 42)
            Text(
                library.isConnected
                    ? "No books match your shelf choices. Change Show in Settings → Shelf."
                    : "Connect a source in Settings to explore your books."
            )
            .appFont(size: 25).multilineTextAlignment(.center).frame(maxWidth: 850)
            if let filter = library.shelfFilter {
                Button("Show all books") { library.shelfFilter = nil }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Clear filter: \(filter.name)")
                    .accessibilityIdentifier("clear-shelf-filter")
            } else {
                HStack(spacing: 24) {
                    Button("Choose sources") {
                        settingsSection = .sources
                        sidebarItem = .settings
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("choose-sources")
                    Button("Explore a sample shelf") { library.showSample() }.buttonStyle(.glass)
                }
            }
        }
        .foregroundStyle(palette.text)
    }
}

extension BookwormsView {
    /// Views whose top-right header holds their options, level with the sidebar title.
    fileprivate var hasHeader: Bool {
        self == .comparison || self == .shared || self == .yearInReview || self == .bookWall
    }
}

struct SpineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Identifies a rendering of the wall background for the lit 3D backdrop.
private struct WallBackdropKey: Hashable {
    let isDark: Bool
    let isWood: Bool
    let width: CGFloat
    let height: CGFloat
}

/// Shows Book Wall's Back overlay while details are open. It reads the detail state itself, so
/// opening or closing details updates this overlay rather than `ShelfView`'s whole body.
private struct BookWallDetailOverlay: View {
    let state: BookWallDetailState
    let palette: ShelfPalette

    var body: some View {
        if state.isPresented {
            BookWallDetailNavigationCover(palette: palette, detailFrame: state.frame) {
                state.closeRevision += 1
            }
            .transition(
                PerformanceDiagnostics.isolates("wall-instant-cover-exit")
                    ? .asymmetric(insertion: .opacity, removal: .identity) : .opacity)
        }
    }
}

/// Places Back above the tab control, which tvOS draws outside the selected tab's content.
private struct BookWallDetailNavigationCover: View {
    let palette: ShelfPalette
    let detailFrame: CGRect
    let onBack: () -> Void
    @FocusState private var backFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if !PerformanceDiagnostics.isolates("wall-no-detail-corner") {
                    // The wood sample covers the floating tab pill only while details are open.
                    // Darken it like the detail wall image near the top of the frame.
                    WoodBackground(palette: palette)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .colorMultiply(
                            Color(
                                red: Double(BookWallScene.detailWallTop.x),
                                green: Double(BookWallScene.detailWallTop.y),
                                blue: Double(BookWallScene.detailWallTop.z))
                        )
                        .mask(alignment: .topLeading) {
                            LinearGradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: 0.94),
                                    .init(color: .clear, location: 1),
                                ], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(
                                width: BookDetailCoverLayout.wallNavigationCoverSize.width,
                                height: BookDetailCoverLayout.wallNavigationCoverSize.height)
                        }
                        .mask(alignment: .topLeading) {
                            LinearGradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: 0.94),
                                    .init(color: .clear, location: 1),
                                ], startPoint: .top, endPoint: .bottom
                            )
                            .frame(
                                width: BookDetailCoverLayout.wallNavigationCoverSize.width,
                                height: BookDetailCoverLayout.wallNavigationCoverSize.height)
                        }
                }
                if !PerformanceDiagnostics.isolates("wall-no-detail-back") {
                    // Back sits where cover details place it, in a full-height section over the
                    // book's column, so Left from any detail control reaches it. Like cover
                    // details, opening focuses Back first.
                    VStack(alignment: .leading, spacing: 0) {
                        Button(action: onBack) {
                            Label("Back to view", systemImage: "chevron.left")
                        }
                        .buttonStyle(.glass)
                        .focused($backFocused)
                        .onAppear { backFocused = true }
                        .accessibilityIdentifier("back-to-shelf")
                        .frame(height: BookDetailCoverLayout.backHeight)
                        Spacer(minLength: 0)
                    }
                    .frame(
                        width: detailFrame.width * BookDetailCoverLayout.columnFraction,
                        alignment: .leading
                    )
                    .focusSection()
                    .padding(.leading, detailFrame.minX + BookDetailCoverLayout.horizontalPadding)
                    .padding(.top, detailFrame.minY + BookDetailCoverLayout.verticalPadding)
                }
            }
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onBack)
    }
}

struct WoodBackground: View {
    let palette: ShelfPalette
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.wallTop, palette.wallBottom], startPoint: .top, endPoint: .bottom)
        }
        .overlay {
            if palette.isWood {
                // Bundled textures stay available offline and need no animated drawing or blur passes.
                GeometryReader { geometry in
                    Image(palette.woodAsset)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(palette.woodOpacity)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

private struct SpineFocusLighting: View {
    let book: Book
    let library: LibraryModel
    let rowHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = library.style(for: book)
        let tint =
            style.background.luminance < 0.15 ? style.foreground.color : style.background.color
        Circle()
            .fill(
                RadialGradient(
                    colors: [tint.opacity(colorScheme == .dark ? 0.16 : 0.09), .clear],
                    center: .center, startRadius: 0, endRadius: rowHeight * 0.6)
            )
            .frame(width: rowHeight * 1.2, height: rowHeight * 1.2)
            .scaleEffect(x: 0.65, y: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A revision makes repeated returns to the same book observable.
struct ShelfBookFocusRequest: Equatable {
    let id: Int
    let revision: Int
}

/// A framed photo standing in a shelf's empty space, centered in the width it is given, bottom
/// aligned on the shelf, with the resting shadow covers use. Decorative and not focusable.
struct ShelfPhoto: View {
    let name: String
    let rowHeight: CGFloat

    private static let names = ["ShelfPhoto1", "ShelfPhoto2", "ShelfPhoto3"]

    /// Every photo, starting at a position chosen by `seed`. Views pick a random seed when they
    /// appear; a two-shelf view gives its shelves the first two photos, which always differ.
    static func names(seed: Int) -> [String] {
        let start = abs(seed % names.count)
        return Array(names[start...] + names[..<start])
    }

    var body: some View {
        // Covers stand at 92% of the row height (`BookPresentation.pages`); the photo matches them.
        let height = rowHeight * 0.92
        Image(name)
            .resizable()
            .scaledToFit()
            .shadow(color: .black.opacity(0.25), radius: height * 0.008, y: height * 0.01)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottom)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// The focused book's format icon and title, its author, primary genre, and finish date, then its
/// rating. My Shelf and Year in Review share it so their captions match.
struct BookCaption: View {
    let book: Book
    let dateFormat: AppDateFormat
    /// Replaces the stars with your rating beside the community's, for the Hot Takes sort.
    var comparesCommunity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                if !book.formatParts.isEmpty {
                    // One icon per format. Symbols differ in width; fixed frames keep them even.
                    HStack(spacing: 4) {
                        ForEach(book.formatParts, id: \.self) { format in
                            Image(systemName: Book.formatSymbol(forLabel: format))
                                .appFont(size: 28, weight: .medium)
                                .frame(width: 40, height: 40)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(book.formatLabel ?? "")
                }
                HStack(spacing: 10) {
                    Text(book.title).lineLimit(1)
                    // Fixed so a long title truncates before the status does.
                    if book.isReading == true {
                        Text("(Currently Reading)").fixedSize()
                    }
                }
                .appFont(size: 33, weight: .medium)
            }
            Text(
                [
                    book.author, book.primaryGenre,
                    book.finished.map { _ in book.finishedLabel(format: dateFormat) },
                ]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            )
            .appFont(size: 29).opacity(0.82).lineLimit(1)
            if comparesCommunity, let rating = book.rating, let community = book.communityRating,
                community > 0
            {
                Text(
                    "You ★\(rating.formatted(.number.precision(.fractionLength(0...1)))) · Community ★\(community.formatted(.number.precision(.fractionLength(1))))"
                )
                .appFont(size: 29).opacity(0.82).padding(.top, 4)
            } else if let rating = book.rating {
                StarRating(rating: rating, size: 26).padding(.top, 4)
            }
        }
    }
}

/// A caption line with the format icon and `Book.readingSummary`, styled like the author line.
/// My Shelf and Compare Shelves share it so their captions match.
struct ReadingLine: View {
    let book: Book
    let dateFormat: AppDateFormat

    var body: some View {
        // A full-size symbol makes this line read larger than the author line at the same point
        // size, so it uses the small scale and sits on the text baseline.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if book.formatLabel != nil {
                Image(systemName: book.formatSymbol).imageScale(.small).accessibilityHidden(true)
            }
            Text(book.readingSummary(dateFormat: dateFormat))
        }
        .appFont(size: 29).opacity(0.82).lineLimit(1)
    }
}

/// Five stars in half steps, like Hardcover's rating display, in the surrounding text color. A
/// static top-lit highlight and a small shadow give the stars some depth without animation.
struct StarRating: View {
    let rating: Double
    var size: CGFloat = 34

    var body: some View {
        stars
            .overlay {
                LinearGradient(
                    colors: [.white.opacity(0.35), .clear, .black.opacity(0.15)],
                    startPoint: .top, endPoint: .bottom
                )
                .mask { stars }
            }
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(rating.formatted(.number.precision(.fractionLength(0...1)))) out of 5 stars")
    }

    private var stars: some View {
        HStack(spacing: size * 0.12) {
            ForEach(0..<5, id: \.self) { index in
                let fill = rating - Double(index)
                Image(
                    systemName: fill >= 0.75
                        ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star"
                )
                .font(.system(size: size, weight: .semibold))
                // Filled, half, and empty symbols differ slightly in width; a fixed frame keeps
                // the row the same width for every rating.
                .frame(width: size * 1.15, height: size * 1.1)
            }
        }
    }
}

/// A bookcase shelf board: a top surface that recedes toward the wall and a lit front edge that
/// casts a shadow on the wall below.
///
/// Place it after a row of books; it shifts up behind the row so book bases stand partway into
/// the surface.
struct ShelfBoard: View {
    let palette: ShelfPalette
    var surfaceDepth: CGFloat = 16
    var edgeHeight: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            // Darker at the back, where the wall shades it.
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            palette.shelf.mix(with: .black, by: 0.35),
                            palette.shelf.mix(with: .black, by: 0.1),
                        ], startPoint: .top, endPoint: .bottom)
                )
                .frame(height: surfaceDepth)
            Rectangle().fill(palette.shelf.gradient)
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                }
                .frame(height: edgeHeight)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 6)
        .padding(.top, -surfaceDepth * 0.6)
        .zIndex(-1)
        .accessibilityHidden(true)
    }
}

/// Shared measurements for `PagedRow` and the layouts that pack its pages.
enum PagedRowLayout {
    /// Keeps each page's outer items, their focus lift, and shadows inside the scroll view's clip.
    static let edgeInset: CGFloat = 24
}

/// Lays out fixed pages of items in one horizontally paged scroll view.
///
/// Every item stays mounted, so the focus engine moves within and across pages natively. The row
/// scrolls to the page that contains `selectedID` but never assigns focus.
struct PagedRow<Item: Identifiable, Content: View>: View where Item.ID == Int {
    let pages: [[Item]]
    let height: CGFloat
    var alignment: VerticalAlignment = .center
    /// The gap for a last page with fewer than `capacity` items, which starts at the leading edge
    /// instead of spreading across the row. Earlier pages always spread.
    var partialPageGap = ShelfLayout.gap
    /// Items that fill a page. Rows of variable-width items leave this unset, so only their last
    /// page counts as partial.
    var capacity = Int.max
    /// A framed photo to stand in a partial last page's empty space when at least 40% of the row
    /// is empty. For book shelves only.
    var emptySpacePhoto: String?
    /// The item whose page stays visible, usually the focused or remembered item.
    let selectedID: Int?
    let chevronStyle: AnyShapeStyle
    let width: (Item) -> CGFloat
    @ViewBuilder let content: (Item) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .leading)
    @State private var visiblePage = 0
    /// The page most recently scrolled to, and when, so rapid page changes skip the animation.
    @State private var targetPage: Int?
    @State private var lastScroll = Date.distantPast
    /// Room for focus lift and shadows, which the horizontal scroll view would otherwise clip.
    private let focusOverflow: CGFloat = 40

    private struct Slot: Identifiable {
        let item: Item
        let leading: CGFloat
        let trailing: CGFloat
        /// The photo asset for the empty space after this item, on a partial last page.
        var photo: String?
        var id: Int { item.id }
    }

    var body: some View {
        GeometryReader { geometry in
            let pageWidth = geometry.size.width
            ScrollView(.horizontal) {
                HStack(alignment: alignment, spacing: 0) {
                    ForEach(slots(pageWidth: pageWidth)) { slot in
                        content(slot.item)
                            .frame(width: width(slot.item))
                            .padding(.leading, slot.leading)
                            .padding(.trailing, slot.trailing)
                            .overlay(alignment: .bottomTrailing) {
                                if let photo = slot.photo {
                                    ShelfPhoto(name: photo, rowHeight: height)
                                        .frame(width: slot.trailing - PagedRowLayout.edgeInset)
                                        .padding(.trailing, PagedRowLayout.edgeInset)
                                }
                            }
                    }
                }
                .frame(
                    height: height, alignment: Alignment(horizontal: .center, vertical: alignment)
                )
                .padding(.vertical, focusOverflow)
            }
            .scrollPosition($position)
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Int.self) {
                Int(($0.contentOffset.x / max(1, pageWidth)).rounded())
            } action: { _, page in
                visiblePage = page
            }
            .padding(.vertical, -focusOverflow)
            .onAppear { scroll(to: selectedID, pageWidth: pageWidth, animated: false) }
            .onChange(of: selectedID) {
                scroll(to: selectedID, pageWidth: pageWidth, animated: true)
            }
            .onChange(of: pages.map { $0.map(\.id) }) {
                scroll(to: selectedID, pageWidth: pageWidth, animated: false)
            }
            .onChange(of: pageWidth) {
                scroll(to: selectedID, pageWidth: pageWidth, animated: false)
            }
        }
        .frame(height: height)
        .overlay(alignment: .leading) {
            if visiblePage > 0 {
                chevron("chevron.left").offset(x: -36)
                    .accessibilityLabel("More items to the left")
                    .accessibilityIdentifier("more-books-left")
            }
        }
        .overlay(alignment: .trailing) {
            if visiblePage < pages.count - 1 {
                chevron("chevron.right").offset(x: 36)
                    .accessibilityLabel("More items to the right")
                    .accessibilityIdentifier("more-books")
            }
        }
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .appFont(size: 26, weight: .light)
            .foregroundStyle(chevronStyle)
            .allowsHitTesting(false)
    }

    /// Pads each item so that every page spans exactly one row width, keeping paging aligned.
    /// Items occupy the page width minus `PagedRowLayout.edgeInset` on each side.
    private func slots(pageWidth: CGFloat) -> [Slot] {
        let inset = PagedRowLayout.edgeInset
        let layoutWidth = max(0, pageWidth - 2 * inset)
        var result: [Slot] = []
        for (pageIndex, page) in pages.enumerated() {
            let widths = page.map(width)
            let spreads = pageIndex < pages.count - 1 || page.count >= capacity
            let gap =
                spreads
                ? ShelfLayout.distributedGap(widths: widths, availableWidth: layoutWidth)
                : partialPageGap
            let used = widths.reduce(0, +) + gap * CGFloat(max(0, page.count - 1))
            let lead = inset
            let empty = layoutWidth - used
            let photo =
                BookPresentation.showsShelfPhotos && !spreads && empty >= 0.4 * layoutWidth
                ? emptySpacePhoto : nil
            for (index, item) in page.enumerated() {
                let isLast = index == page.count - 1
                result.append(
                    Slot(
                        item: item, leading: index == 0 ? lead : gap,
                        trailing: isLast ? max(0, pageWidth - used - lead) : 0,
                        photo: isLast ? photo : nil))
            }
        }
        return result
    }

    /// Scrolls to the page containing `id`. A page change within the animation's duration of the
    /// previous one jumps instead, so fast input never stacks scroll animations.
    private func scroll(to id: Int?, pageWidth: CGFloat, animated: Bool) {
        let page = id.flatMap { id in pages.firstIndex { $0.contains { $0.id == id } } } ?? 0
        let duration = 0.3
        guard !animated || page != targetPage else { return }
        let settled = Date().timeIntervalSince(lastScroll) > duration
        targetPage = page
        lastScroll = Date()
        withAnimation(animated && settled && !reduceMotion ? .easeInOut(duration: duration) : nil) {
            position.scrollTo(x: CGFloat(page) * pageWidth)
        }
    }
}

/// Presents prepared shelf pages as one paged row of book buttons.
///
/// Native focus handles movement within and between pages. The row assigns focus only when it
/// appears and when `focusRequest` changes, such as after returning from book details. Focus that
/// enters the row from another section lands on `entryBookID`. When `entryColumn` is set, focus
/// instead lands on that position within the page containing `entryBookID`.
struct ShelfRow: View {
    let library: LibraryModel
    let pages: [ShelfPage]
    let rowHeight: CGFloat
    let palette: ShelfPalette
    let entryBookID: Int?
    var entryColumn: Int?
    let focusRequest: ShelfBookFocusRequest?
    let presentationStyles: [Int: SpineStyle]
    var activatesOnAppear = true
    var emptySpacePhoto: String?
    let onFocus: (Int?) -> Void
    let onSelect: (Book) -> Void
    @FocusState private var focusedBook: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func contains(_ id: Int) -> Bool {
        pages.contains { $0.books.contains { $0.id == id } }
    }

    private var entryID: Int? {
        let remembered = entryBookID.flatMap { contains($0) ? $0 : nil }
        guard let entryColumn else { return remembered ?? pages.first?.books.first?.id }
        let page =
            remembered.flatMap { id in pages.first { $0.books.contains { $0.id == id } } }
            ?? pages.first
        guard let books = page?.books, !books.isEmpty else { return nil }
        return books[min(max(0, entryColumn), books.count - 1)].id
    }

    var body: some View {
        let dimensions = pages.reduce(into: [Int: SpineDimensions]()) {
            $0.merge($1.dimensions) { first, _ in first }
        }
        let pageEnds = Set(pages.dropLast().compactMap { $0.books.last?.id })
        PagedRow(
            pages: pages.map(\.books), height: rowHeight, alignment: .bottom,
            emptySpacePhoto: emptySpacePhoto, selectedID: focusedBook ?? entryID,
            chevronStyle: AnyShapeStyle(palette.text.opacity(0.45)),
            width: { dimensions[$0.id]?.width ?? 0 }
        ) { book in
            if let bookDimensions = dimensions[book.id] {
                bookButton(book, dimensions: bookDimensions, endsPage: pageEnds.contains(book.id))
            }
        }
        .focusSection()
        .defaultFocus($focusedBook, entryID, priority: .userInitiated)
        .onChange(of: focusedBook) { onFocus(focusedBook) }
        .onAppear {
            if activatesOnAppear { focusedBook = entryID }
        }
        .task {
            // Focus can be unavailable during the first appearance pass.
            if activatesOnAppear && focusedBook == nil { focusedBook = entryID }
        }
        .onChange(of: focusRequest) { _, request in
            guard let request, contains(request.id) else { return }
            focusedBook = request.id
        }
    }

    private func bookButton(_ book: Book, dimensions: SpineDimensions, endsPage: Bool) -> some View
    {
        Button {
            onSelect(book)
        } label: {
            if let style = presentationStyles[book.id] {
                SpineView(
                    book: book, style: style, dimensions: dimensions,
                    isFocused: focusedBook == book.id,
                    fontRevision: library.fontRevision)
            } else {
                CoverView(
                    book: book, standsOnShelf: true,
                    progressStyle: library.shelfPreferences.progressStyle,
                    onAspectRatio: { library.recordCoverRatio($0, for: book.id) }
                )
                .frame(width: dimensions.width, height: dimensions.height)
            }
        }
        .buttonStyle(CoverButtonStyle())
        .focusEffectDisabled()
        .background {
            ZStack {
                if focusedBook == book.id, presentationStyles[book.id] != nil {
                    SpineFocusLighting(book: book, library: library, rowHeight: rowHeight)
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.3), value: focusedBook == book.id)
        }
        .focused($focusedBook, equals: book.id)
        .accessibilityLabel("\(book.title), by \(book.author)")
        .accessibilityHint(
            endsPage ? "Open book details. Move right for more books." : "Open book details"
        )
        .accessibilityIdentifier("book-\(book.id)")
    }
}

extension View {
    @ViewBuilder
    fileprivate func tvOSSidebarHeader<Content: View>(@ViewBuilder _ content: () -> Content)
        -> some View
    {
        if #available(tvOS 27.0, *) {
            self.tabViewSidebarHeader(content: content)
        } else {
            self
        }
    }
}
