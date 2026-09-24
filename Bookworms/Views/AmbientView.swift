import SwiftUI

struct AmbientView: View {
    let controller: AmbientController
    let library: LibraryModel
    let social: SocialLibraryModel
    let preferences: ViewPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusState private var exitFocused: Bool
    @AppStorage("woodBackground") private var woodBackground = true
    /// Combined with the content index so each ambient change shows a new shelf photo.
    @State private var photoSeed = Int.random(in: 0..<1000)
    @AppStorage("spoilerPolicy") private var spoilerPolicy = SpoilerPolicy.alwaysHide

    static func available(
        library: LibraryModel, social: SocialLibraryModel, preferences: ViewPreferences
    ) -> [BookwormsView] {
        let measurement = PerformanceDiagnostics.begin("AmbientEligibility")
        defer { measurement.end() }
        return preferences.ambientOrderedViews.filter { view in
            switch view {
            case .shelf: !library.books.isEmpty
            case .following: !social.activities.isEmpty
            case .comparison:
                !social.presentation.mine.isEmpty || !social.presentation.theirs.isEmpty
            case .shared:
                !social.presentation.shared.isEmpty
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if woodBackground {
                    WoodBackground(palette: ShelfPalette(isDark: true, isWood: true))
                        .scaleEffect(1.08)
                        .scaleEffect(x: controller.layoutVariant.isMultiple(of: 2) ? 1 : -1, y: 1)
                        .offset(x: controller.layoutVariant < 2 ? -16 : 16)
                } else {
                    Color(red: 0.045, green: 0.055, blue: 0.065).ignoresSafeArea()
                }
                // Full-screen presentation can propose zero size during its mounting transaction.
                if geometry.size.width > 320 && geometry.size.height > 320 {
                    presentation(
                        size: CGSize(
                            width: geometry.size.width - 160, height: geometry.size.height - 160)
                    )
                    .id("\(controller.view.rawValue):\(controller.contentIndex)")
                    .transition(.opacity)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.6),
                        value: controller.contentIndex
                    )
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.6), value: controller.view
                    )
                    .padding(80)
                    .offset(
                        x: [-24.0, 24, 16, -16][controller.layoutVariant],
                        y: [-16.0, -8, 16, 8][controller.layoutVariant]
                    )
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.6),
                        value: controller.layoutVariant)
                }
                Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
                Button {
                    controller.stop()
                } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
                }
                .buttonStyle(AmbientExitButtonStyle()).focused($exitFocused).focusEffectDisabled()
                .accessibilityLabel("Stop ambient mode")
                .accessibilityIdentifier("stop-ambient")
                .onMoveCommand { _ in controller.stop() }
                .onExitCommand { controller.stop() }
                .onPlayPauseCommand { controller.stop() }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: ContentVersion(bookIDs: library.books.map(\.id), socialRevision: social.revision))
        {
            exitFocused = true
            // Availability includes a full-library intersection; reuse it until the content changes.
            let views = Self.available(library: library, social: social, preferences: preferences)
            while controller.isActive && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                controller.tick(
                    views: views, voiceOver: voiceOver, sceneActive: scenePhase == .active)
            }
        }
        .onChange(of: scenePhase) { if scenePhase != .active { controller.stop() } }
        .onChange(of: voiceOver) { if voiceOver { controller.stop() } }
        .onDisappear { controller.stop() }
    }

    private struct ContentVersion: Equatable {
        let bookIDs: [Int]
        let socialRevision: Int
    }

    private var photos: [String] { ShelfPhoto.names(seed: photoSeed + controller.contentIndex) }

    @ViewBuilder private func presentation(size: CGSize) -> some View {
        switch controller.view {
        case .shelf:
            ambientShelf(books: library.books, size: size, photo: photos[0])
        case .comparison:
            VStack(spacing: 35) {
                ambientShelf(
                    books: social.presentation.mine.map(\.book),
                    size: CGSize(width: size.width, height: (size.height - 35) / 2),
                    coversOnly: true, photo: photos[0])
                ambientShelf(
                    books: social.presentation.theirs.map(\.book),
                    size: CGSize(width: size.width, height: (size.height - 35) / 2),
                    coversOnly: true, photo: photos[1])
            }
        case .following:
            if !social.activities.isEmpty {
                ActivityCard(
                    activity: social.activities[
                        controller.contentIndex % min(10, social.activities.count)],
                    isAmbient: true
                )
                .frame(maxHeight: .infinity, alignment: .center)
            }
        case .shared:
            let books = social.presentation.shared
            if !books.isEmpty {
                let shared = books[controller.contentIndex % books.count]
                HStack(spacing: 55) {
                    CoverView(book: shared.mine.book)
                        .frame(width: size.width / 3, height: size.height * 0.8)
                    VStack(alignment: .leading, spacing: 25) {
                        Text(shared.mine.book.title).appFont(size: 40, weight: .semibold)
                            .lineLimit(3)
                        Text(shared.mine.book.author).appFont(size: 28)
                        ambientReview(
                            "You", avatarURL: social.snapshot?.owner.avatarURL, item: shared.mine)
                        let reader = social.reader(preferences.readerID)
                        ambientReview(
                            reader?.displayName ?? "Reader", avatarURL: reader?.avatarURL,
                            item: shared.theirs)
                    }
                }
            }
        }
    }

    private func ambientShelf(books: [Book], size: CGSize, coversOnly: Bool = false, photo: String)
        -> some View
    {
        let candidates = Dictionary(
            books.compactMap { book in library.savedSpineStyle(for: book).map { (book.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let styles =
            (coversOnly || !BookPresentation.showsGeneratedSpines)
            ? [:] : BookPresentation.uniformStyles(books: books, styles: candidates)
        let pages = BookPresentation.pages(
            books: books, styles: styles, coverRatios: library.coverRatios, width: size.width,
            rowHeight: size.height - 20)
        return VStack(spacing: 0) {
            if !pages.isEmpty {
                let index = controller.contentIndex % pages.count
                let page = pages[index]
                // Full pages spread across the shelf; a partial last page starts at the left.
                HStack(
                    alignment: .bottom,
                    spacing: index < pages.count - 1
                        ? ShelfLayout.distributedGap(
                            widths: page.books.map { page.dimensions[$0.id]?.width ?? 0 },
                            availableWidth: size.width)
                        : ShelfLayout.gap
                ) {
                    ForEach(page.books) { book in
                        if let dimensions = page.dimensions[book.id] {
                            if let style = styles[book.id] {
                                SpineView(
                                    book: book, style: style, dimensions: dimensions,
                                    isFocused: false, fontRevision: library.fontRevision)
                            } else {
                                CoverView(book: book, standsOnShelf: true)
                                    .frame(width: dimensions.width, height: dimensions.height)
                            }
                        }
                    }
                }
                .frame(width: size.width, height: size.height - 20, alignment: .bottomLeading)
                .overlay(alignment: .bottomTrailing) {
                    let used =
                        page.books.reduce(0) { $0 + (page.dimensions[$1.id]?.width ?? 0) }
                        + ShelfLayout.gap * CGFloat(max(0, page.books.count - 1))
                    if index == pages.count - 1, size.width - used >= 0.4 * size.width {
                        ShelfPhoto(name: photo, rowHeight: size.height - 20)
                            .frame(width: size.width - used)
                    }
                }
                ShelfBoard(
                    palette: ShelfPalette(isDark: true, isWood: woodBackground),
                    surfaceDepth: 12, edgeHeight: 7)
            }
        }
    }

    private func ambientReview(_ name: String, avatarURL: URL?, item: ReaderBook) -> some View {
        let isBookRead = library.isBookReadByUser(item.id)
        let hidesSpoilers = item.hasSpoilers && (spoilerPolicy == .alwaysHide || !isBookRead)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ReaderLabel(name: name, avatarURL: avatarURL, size: 30, weight: .regular)
                Text("· \(item.rating.map { String(format: "%.1f ★", $0) } ?? "Not rated")")
                    .appFont(size: 30)
            }
            Text(
                hidesSpoilers
                    ? "Review contains spoilers" : (item.reviewText ?? "No written review")
            )
            .appFont(size: 25).lineLimit(5)
        }
    }
}

// A plain tvOS button still draws a focus background. This input target must stay invisible.
private struct AmbientExitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
