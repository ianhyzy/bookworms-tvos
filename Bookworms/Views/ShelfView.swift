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
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ShelfPalette {
        ShelfPalette(isDark: colorScheme == .dark, isWood: woodBackground)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    private var controlsVisible: Bool { activity.controlsVisible }
    @State private var openedDevelopmentDetail = false
    @State private var appliedDevelopmentPage = false
    @State private var selectedBook: Book?
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

    private func showView(_ view: BookwormsView) {
        sidebarItem = .view(view)
        coordinator.current = view
    }

    var body: some View {
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
        .environment(\.artworkGeneration, artworkGeneration)
        .tvOSSidebarHeader {
            sidebarHeader
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
        .task(id: artworkKey) {
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
            // Retry covers that failed, such as after a timeout, once. Mounted covers reload from the
            // local cache when the generation changes; browsing itself never downloads.
            guard !preparation.failed.isEmpty,
                (try? await Task.sleep(for: .seconds(30))) != nil, key == artworkKey
            else { return }
            await ArtworkStore.shared.forgetFailures()
            let retry = await ArtworkStore.shared.prefetch(
                books: preparation.failed, avatarURLs: [])
            guard !Task.isCancelled, key == artworkKey, !retry.ratios.isEmpty else { return }
            for (id, ratio) in retry.ratios { library.recordCoverRatio(ratio, for: id) }
            artworkGeneration &+= 1
        }
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
                style: library.style(for: book)
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
                    if let scenario = ScenarioRuntime.current { ScenarioProbe(runtime: scenario) }
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
                WoodBackground(palette: palette)
                VStack(alignment: .leading, spacing: 0) {
                    if !hasPreparedArtwork {
                        ProgressView("Loading view…")
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
                .padding(.horizontal, view == .following || view == .comparison ? 48 : 80)
                .padding(
                    .top,
                    view == .comparison || view == .shared ? 0 : ShelfScreenLayout.verticalPadding
                )
                .padding(.bottom, ShelfScreenLayout.verticalPadding)

                if view != .shared && view != .comparison {
                    controls
                        .padding(.trailing, 80)
                        .padding(.bottom, ShelfScreenLayout.verticalPadding)
                }
            }
            .ignoresSafeArea(edges: view == .comparison || view == .shared ? .top : [])
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

    private var sidebarHeader: some View {
        HStack(spacing: 14) {
            if let avatarURL = social.snapshot?.owner.avatarURL {
                CachedAvatarView(url: avatarURL)
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
            }
            Text(social.snapshot?.owner.displayName ?? "Bookworms")
                .appFont(size: 24, weight: .semibold)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 8)
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
            VStack(alignment: .leading, spacing: 14) {
                Text("View interval").appFont(size: 26, weight: .medium)
                    .foregroundStyle(palette.text)
                Picker("Ambient view interval", selection: $coordinator.preferences.ambientMinutes)
                {
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
                Text("Views").appFont(size: 26, weight: .medium)
                    .foregroundStyle(palette.text)
                    .padding(.top, 10)
                HStack(spacing: 20) {
                    ForEach(BookwormsView.allCases.filter { $0 != .shelf }) { view in
                        Toggle(
                            view.rawValue,
                            isOn: Binding(
                                get: { coordinator.preferences.ambientOrderedViews.contains(view) },
                                set: { coordinator.setInAmbient(view, $0) }
                            )
                        )
                        .appFont(size: 24)
                        .accessibilityIdentifier("ambient-view-\(view)")
                    }
                }
                Text("My Shelf always plays. Hiding a view from the menu doesn't remove it here.")
                    .appFont(size: 22).foregroundStyle(palette.text).opacity(0.7)
            }
            .frame(maxWidth: 1000)
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
        // controls stay legible.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WoodBackground(palette: palette) }
    }

    private var controls: some View {
        ViewSpecificControls(library: library, coordinator: coordinator)
    }

    private var selectionCaption: some View {
        let book = library.books.first { $0.id == (focusedBook ?? lastFocusedID) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(book?.title ?? "Select a book to look inside")
                .appFont(size: 33, weight: .medium).lineLimit(1)
            Text(
                book.map {
                    [$0.author, $0.genres?.prefix(2).joined(separator: ", ")].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                } ?? "Use the remote to explore your shelf"
            )
            .appFont(size: 29).opacity(0.82).lineLimit(1)
            if let book {
                ReadingLine(book: book, dateFormat: dateFormat)
            } else {
                Text(" ").appFont(size: 29)
            }
        }
        .foregroundStyle(palette.text)
        .accessibilityHidden(true)
    }

    private var shelfStatus: some View {
        HStack(spacing: 22) {
            if library.isSample {
                Text("Sample shelf").appFont(size: 21)
                    .foregroundStyle(palette.text.opacity(0.6))
            }
            Spacer()
        }
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
            Text(library.isConnected ? "Your shelf is waiting" : "Make room for your books")
                .appFont(size: 42)
            Text(
                library.isConnected
                    ? "No books match your shelf choices. Change Show in Settings → Shelf."
                    : "Connect a source in Settings to explore your books."
            )
            .appFont(size: 25).multilineTextAlignment(.center).frame(maxWidth: 850)
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
        .foregroundStyle(palette.text)
    }
}

struct SpineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
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

/// A caption line with the format icon and `Book.readingSummary`, styled like the author line.
/// My Shelf and Compare Shelves share it so their captions match.
struct ReadingLine: View {
    let book: Book
    let dateFormat: AppDateFormat

    var body: some View {
        HStack(spacing: 10) {
            if book.formatLabel != nil {
                Image(systemName: book.formatSymbol).accessibilityHidden(true)
            }
            Text(book.readingSummary(dateFormat: dateFormat))
        }
        .appFont(size: 29).opacity(0.82).lineLimit(1)
    }
}

/// Five gold stars in half steps, like Hardcover's rating display. A static gradient and a small
/// shadow give the stars some depth without animation.
struct StarRating: View {
    let rating: Double
    var size: CGFloat = 34

    var body: some View {
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
        .foregroundStyle(
            LinearGradient(
                colors: [
                    Color(red: 1, green: 0.87, blue: 0.36),
                    Color(red: 0.95, green: 0.68, blue: 0.1),
                ], startPoint: .top, endPoint: .bottom)
        )
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(rating.formatted(.number.precision(.fractionLength(0...1)))) out of 5 stars")
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
                !spreads && empty >= 0.4 * layoutWidth ? emptySpacePhoto : nil
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
