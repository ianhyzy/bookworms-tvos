import SwiftUI

/// Shares column dimensions between native details and the wall's 3D presentation.
enum BookDetailCoverLayout {
    static let horizontalPadding: CGFloat = 80
    static let verticalPadding: CGFloat = 54
    static let columnFraction: CGFloat = 0.24
    static let wallNavigationCoverSize = CGSize(width: 300, height: 144)
    static let coverHeightFraction: CGFloat = 0.60
    static let backHeight: CGFloat = 64
    static let coverGap: CGFloat = 64
}

extension ShapeStyle where Self == Color {
    /// Labels and captions in book details: a step below the description's 0.86 opacity, and at
    /// least 4.5:1 against the backgrounds behind detail text in both appearances.
    static var detailCaption: Color { .primary.opacity(0.72) }
}

struct BookDetailView: View {
    @AppStorage("dateFormat") private var dateFormat = AppDateFormat.monthName
    let book: Book
    let style: SpineStyle
    @Environment(\.colorScheme) private var colorScheme
    /// Loads community reviews on request; `nil` when Hardcover can't supply them for this book.
    var loadReviews: (@MainActor () async throws -> [BookReview])?
    var showsCover = true
    var showsBackButton = true
    var onClose: (() -> Void)?
    /// Shows My Shelf filtered to the chosen author or genre. When `nil`, they appear as text.
    var onShowShelf: ((ShelfFilter) -> Void)?
    /// The book's series, shown as a button beside the author that opens the series pop-up.
    var series: SeriesInfo?
    /// Your library's copy of a series book, or `nil` when you don't have it.
    var libraryBook: (Int) -> Book? = { _ in nil }
    /// Opens details for another book in your library, chosen from the series pop-up.
    var onOpenBook: ((Book) -> Void)?
    @State private var showsSeries = false
    /// The series book chosen in the pop-up, opened after the pop-up finishes closing so that one
    /// presentation never starts while another is still dismissing.
    @State private var chosenSeriesBook: Book?
    @Environment(\.dismiss) private var dismiss
    @State private var showsReviews = false
    /// The entry point when focus moves into the metadata row: the first genre.
    @FocusState private var focusedGenre: String?
    @State private var readingDescription: ReviewPresentation?
    @State private var descriptionHeight: CGFloat = 0
    @State private var fullDescriptionHeight: CGFloat = 0
    /// Up to three most-tagged genres that read as English, filtered once when details open so
    /// saved snapshots from any source benefit without a sync.
    private let genres: [String]

    init(
        book: Book, style: SpineStyle,
        loadReviews: (@MainActor () async throws -> [BookReview])? = nil,
        showsCover: Bool = true,
        showsBackButton: Bool = true,
        onClose: (() -> Void)? = nil,
        onShowShelf: ((ShelfFilter) -> Void)? = nil,
        series: SeriesInfo? = nil,
        libraryBook: @escaping (Int) -> Book? = { _ in nil },
        onOpenBook: ((Book) -> Void)? = nil
    ) {
        self.book = book
        self.style = style
        self.loadReviews = loadReviews
        self.showsCover = showsCover
        self.showsBackButton = showsBackButton
        self.onClose = onClose
        self.onShowShelf = onShowShelf
        self.series = series
        self.libraryBook = libraryBook
        self.onOpenBook = onOpenBook
        genres = (book.genres ?? []).filter(HardcoverClient.isEnglishTag).prefix(3)
            .map(Book.displayGenre)
    }

    var body: some View {
        GeometryReader { geometry in
            let coverColumnWidth = geometry.size.width * BookDetailCoverLayout.columnFraction
            ZStack {
                if showsCover {
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [
                                Color(
                                    red: style.background.red * 0.34,
                                    green: style.background.green * 0.34,
                                    blue: style.background.blue * 0.34), .black,
                            ]
                            : [
                                Color(
                                    red: 0.85 + style.background.red * 0.15,
                                    green: 0.85 + style.background.green * 0.15,
                                    blue: 0.85 + style.background.blue * 0.15),
                                Color(red: 0.97, green: 0.96, blue: 0.94),
                            ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                    RadialGradient(
                        colors: [style.background.color.opacity(0.20), .clear], center: .leading,
                        startRadius: 50, endRadius: 900
                    )
                    .ignoresSafeArea()
                }
                // The left column is a full-height focus section, so Left from any control in the
                // text column returns to Back.
                HStack(alignment: .top, spacing: 56) {
                    VStack(alignment: .leading, spacing: BookDetailCoverLayout.coverGap) {
                        if showsBackButton {
                            Button {
                                close()
                            } label: {
                                Label("Back to view", systemImage: "chevron.left")
                            }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("back-to-shelf")
                            .frame(height: BookDetailCoverLayout.backHeight)
                        } else {
                            Color.clear.frame(height: BookDetailCoverLayout.backHeight)
                                .accessibilityHidden(true)
                        }
                        Group {
                            if showsCover {
                                CoverView(book: book)
                            } else {
                                Color.clear.accessibilityHidden(true)
                            }
                        }
                        .frame(
                            width: coverColumnWidth,
                            height: geometry.size.height
                                * BookDetailCoverLayout.coverHeightFraction
                        )
                        Spacer(minLength: 0)
                    }
                    .frame(width: coverColumnWidth)
                    .focusSection()
                    // Two sibling sections, not nested ones: the header starts level with Back, so
                    // Right from Back reaches the header (the author button, or the histogram when
                    // the author is text), and the full-width description section catches Down
                    // from the metadata row.
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(book.title)
                                    .appFont(size: 56, weight: .semibold)
                                    .lineLimit(3).minimumScaleFactor(0.7)
                                    .accessibilityIdentifier("detail-title")
                                // A full-width section, so Up from the histogram reaches the
                                // author. The series button sits beside the author and wraps
                                // below it when the row is too narrow.
                                HStack {
                                    FlowLayout(spacing: 16) {
                                        author
                                        seriesButton
                                    }
                                    Spacer(minLength: 0)
                                }
                                .focusSection()
                                factsLine
                            }
                            // Its own section, so Down from the author lands on a genre or the
                            // histogram instead of skipping to Show more, which aligns with it.
                            metadata.focusSection()
                                .defaultFocus(
                                    $focusedGenre, genres.first, priority: .userInitiated)
                        }
                        .focusSection()
                        description.focusSection()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, BookDetailCoverLayout.horizontalPadding)
                .padding(.vertical, BookDetailCoverLayout.verticalPadding)
            }
        }
        .onExitCommand { close() }
        .sheet(item: $readingDescription) { ReviewReadingView(review: $0).appTypography() }
        .sheet(isPresented: $showsReviews) {
            if let loadReviews {
                BookReviewsView(book: book, load: loadReviews).appTypography()
            }
        }
    }

    private func openChosenSeriesBook() {
        if let chosen = chosenSeriesBook { onOpenBook?(chosen) }
        chosenSeriesBook = nil
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// The description truncated to the remaining height. A hidden full-height copy detects
    /// overflow, which offers **Show more** to read the whole text in a sheet.
    private var description: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(descriptionText)
                .appFont(size: 27).lineSpacing(8)
                .foregroundStyle(.primary.opacity(0.86))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    descriptionHeight = $0
                }
                .background(alignment: .topLeading) {
                    Text(descriptionText)
                        .appFont(size: 27).lineSpacing(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            fullDescriptionHeight = $0
                        }
                }
                .clipped()
                .accessibilityIdentifier("book-description")
            if fullDescriptionHeight > descriptionHeight + 1,
                !PerformanceDiagnostics.isolates("wall-no-show-more")
            {
                let showMore = Button("Show more") {
                    readingDescription = ReviewPresentation(
                        title: book.title, text: descriptionText, spoilers: false)
                }
                // Book Wall shows details over its live 3D scene, without the cover. Glass there
                // samples a layer that changes every frame, which kept the open state at 40 fps
                // on Apple TV 4K (2nd generation); the flat platter reads nothing behind it.
                Group {
                    if showsCover || PerformanceDiagnostics.isolates("wall-show-more-glass") {
                        showMore.buttonStyle(.glass)
                    } else if PerformanceDiagnostics.isolates("wall-show-more-bordered") {
                        showMore.buttonStyle(.bordered)
                    } else {
                        showMore.buttonStyle(FlatButtonStyle()).focusEffectDisabled()
                    }
                }
                .accessibilityIdentifier("show-full-description")
            }
        }
        .padding(.bottom, 10)
    }

    private var descriptionText: String {
        guard let description = book.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
        else {
            return "No description is available from your sources."
        }
        return description
    }

    /// The labeled facts under the author: reading format, publication year, and length, such as
    /// "1098 pages" or "742 minutes" for an audiobook. Missing facts are left out.
    private var facts: [(symbol: String, label: String, value: String)] {
        [
            book.formatLabel.map { (book.formatSymbol, "Format", $0) },
            book.publicationYear.map { ("calendar", "Published", String($0)) },
            book.lengthLabel.map { ("text.book.closed", "Length", $0) },
        ]
        .compactMap(\.self)
    }

    /// The facts in one row, which wraps when it is too long for the column.
    private var factsLine: some View {
        FlowLayout(spacing: 26) {
            ForEach(facts, id: \.label) { fact in
                Label("\(fact.label): \(fact.value)", systemImage: fact.symbol)
                    .labelStyle(CompactLabelStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detail-fact-\(fact.label)")
            }
        }
        .appFont(size: 26).foregroundStyle(.detailCaption).lineLimit(1)
    }

    /// The finish date when one is recorded, then genres, then the rating histogram, which opens
    /// reviews when Hardcover can supply them.
    private var metadata: some View {
        HStack(alignment: .top, spacing: 44) {
            if book.finished != nil {
                metadataItem(
                    "Finished", value: book.finishedLabel(format: dateFormat),
                    symbol: "checkmark.circle"
                )
                .fixedSize()
            }
            if !genres.isEmpty {
                Group {
                    if let onShowShelf {
                        genreButtons(onShowShelf)
                    } else {
                        metadataItem(
                            "Genres",
                            // A non-breaking space keeps each dot with the genre before it when
                            // wrapping.
                            value: genres.joined(separator: "\u{00A0}· "), symbol: "tag", lines: 3
                        )
                    }
                }
                // Genres size first and wrap only when the chart would drop below its minimum
                // width; the chart takes what they leave.
                .layoutPriority(1)
            }
            Group {
                if loadReviews != nil {
                    Button {
                        showsReviews = true
                    } label: {
                        RatingsView(book: book)
                    }
                    .buttonStyle(FocusHighlightButtonStyle())
                    // Keeps the focus highlight clear of the facts line and description.
                    .padding(.vertical, 12)
                    .focusEffectDisabled()
                    .accessibilityHint("Shows community reviews.")
                    .accessibilityIdentifier("community-reviews")
                } else {
                    RatingsView(book: book)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The author as a compact capsule button when details can filter My Shelf, otherwise text.
    @ViewBuilder private var author: some View {
        if let onShowShelf {
            Button {
                onShowShelf(.author(book.author))
            } label: {
                Label(book.author, systemImage: "person")
                    .labelStyle(CompactLabelStyle())
                    .appFont(size: 29, weight: .medium)
            }
            .buttonStyle(FlatButtonStyle(horizontalPadding: 18, verticalPadding: 6))
            .accessibilityHint("Shows your books by this author.")
            .accessibilityIdentifier("detail-author")
        } else {
            Text(book.author).appFont(size: 34).foregroundStyle(.primary.opacity(0.9))
        }
    }

    /// "#3 · Ana and Din Mysteries" beside the author; opens every main book in the series.
    @ViewBuilder private var seriesButton: some View {
        if let series, series.books.count > 1 {
            let position = book.seriesPosition ?? series.books.first { $0.id == book.id }?.position
            Button {
                showsSeries = true
            } label: {
                Label(
                    [position.map(SeriesInfo.positionLabel), series.name].compactMap(\.self)
                        .joined(separator: " · "),
                    systemImage: "books.vertical"
                )
                .labelStyle(CompactLabelStyle())
                .appFont(size: 26, weight: .medium)
                .lineLimit(1)
            }
            // Matches the height of the author capsule, whose text is larger.
            .buttonStyle(FlatButtonStyle(horizontalPadding: 18, verticalPadding: 8))
            .accessibilityHint("Shows every book in the series.")
            .accessibilityIdentifier("detail-series")
            .fullScreenCover(isPresented: $showsSeries, onDismiss: openChosenSeriesBook) {
                SeriesPopup(
                    series: series, currentID: book.id, libraryBook: libraryBook,
                    onOpen: { chosen in
                        if chosen.id != book.id { chosenSeriesBook = chosen }
                        showsSeries = false
                    }
                )
                .appTypography()
                .onExitCommand { showsSeries = false }
                // Details stay visible, dimmed, around the card.
                .presentationBackground(.black.opacity(0.55))
            }
        }
    }

    /// The Genres label above one capsule button per genre.
    private func genreButtons(_ onShowShelf: @escaping (ShelfFilter) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "tag").frame(width: 20)
                Text("Genres")
            }
            .appFont(size: 18).foregroundStyle(.detailCaption)
            .accessibilityHidden(true)
            FlowLayout(spacing: 10) {
                ForEach(genres, id: \.self) { genre in
                    Button {
                        onShowShelf(.genre(genre))
                    } label: {
                        Text(genre).appFont(size: 21, weight: .medium)
                    }
                    .buttonStyle(FlatButtonStyle(horizontalPadding: 14, verticalPadding: 5))
                    .focused($focusedGenre, equals: genre)
                    .accessibilityHint("Shows your books in this genre.")
                    .accessibilityIdentifier("detail-genre-\(genre)")
                }
            }
        }
    }

    private func metadataItem(_ title: String, value: String, symbol: String, lines: Int = 2)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
            }
            .appFont(size: 18).foregroundStyle(.detailCaption)
            Text(value).appFont(size: 23, weight: .medium).lineLimit(lines)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A capsule with flat fills and the tvOS focus look: a translucent platter that turns white and
/// lifts with focus. Unlike glass, it never samples the content behind it.
private struct FlatButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 30
    var verticalPadding: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        Platter(
            configuration: configuration, horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding)
    }

    private struct Platter: View {
        let configuration: Configuration
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(isFocused ? Color.black : Color.primary)
                .background(isFocused ? Color.white : Color.primary.opacity(0.12), in: .capsule)
                .scaleEffect(isFocused && !reduceMotion ? 1.06 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Shows a rounded highlight behind the label only while focused. The highlight extends past the
/// label so the content stays aligned with neighboring, unfocusable metadata.
private struct FocusHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .padding(18)
                .background(.primary.opacity(isFocused ? 0.12 : 0), in: .rect(cornerRadius: 20))
                .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .padding(-18)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Community reviews of one book, fetched from Hardcover when the sheet opens. Each card shows up
/// to five lines. Pressing a card, which also confirms any spoiler warning, shows the whole review
/// in place of the list; Back returns to that card.
struct BookReviewsView: View {
    private enum Focus: Hashable {
        case review(Int)
        case reader
    }

    @AppStorage("spoilerPolicy") private var spoilerPolicy = SpoilerPolicy.alwaysHide
    let book: Book
    let load: @MainActor () async throws -> [BookReview]
    @State private var reviews: [BookReview]?
    @State private var failure: String?
    @State private var reading: BookReview?
    /// The review the reader last showed; the list's default focus when the reader closes.
    @State private var lastReadID: Int?
    @State private var readerScroll = ScrollPosition(y: 0)
    @State private var readerOffset: CGFloat = 0
    @State private var readerMaximumOffset: CGFloat = 0
    @FocusState private var focus: Focus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// Space inside the clipping scroll view for a focused card's lift and shadow.
    private static let liftMargin: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(book.title).appFont(size: 44, weight: .semibold).lineLimit(1)
                .padding(.horizontal, Self.liftMargin)
                // Space between the title and the edge where cards scroll out of view.
                .padding(.bottom, 28)
            ZStack {
                // The list stays mounted while reading so its scroll position survives.
                list
                    .opacity(reading == nil ? 1 : 0)
                    .disabled(reading != nil)
                if let reading {
                    // A slight zoom echoes the tvOS focus lift; Reduce Motion keeps only the fade.
                    // The reader leaves at once: it holds focus until removed, so an animated
                    // exit would delay focus returning to the card by the length of the fade.
                    reader(reading)
                        .transition(
                            .asymmetric(
                                insertion: reduceMotion
                                    ? .opacity : .scale(scale: 0.94).combined(with: .opacity),
                                removal: .identity))
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 50)
        .frame(width: 1500, height: 920)
        .task {
            do {
                reviews = try await load()
            } catch {
                failure = error.localizedDescription
            }
        }
        .onExitCommand {
            // Back closes an open review first. Handling it here, not only on the reader pane,
            // keeps a Back press from dismissing the popup if the pane hasn't taken focus yet.
            if reading != nil {
                closeReader()
            } else {
                dismiss()
            }
        }
    }

    /// Closing removes the focused reader, so the focus engine picks the list's default focus:
    /// the card that opened the review. The list is disabled until this update, so an explicit
    /// focus write here would target a disabled card.
    private func closeReader() {
        withAnimation(readerAnimation) { reading = nil }
    }

    private var readerAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }

    @ViewBuilder
    private var list: some View {
        if let reviews, !reviews.isEmpty {
            ScrollView {
                LazyVStack(spacing: 28) {
                    ForEach(reviews) { review in
                        BookReviewCard(
                            review: review,
                            hidesSpoilers: review.hasSpoilers
                                && (spoilerPolicy == .alwaysHide || book.isRead != true)
                        ) {
                            readerScroll = ScrollPosition(y: 0)
                            readerOffset = 0
                            lastReadID = review.id
                            withAnimation(readerAnimation) { reading = review }
                        }
                        .focused($focus, equals: .review(review.id))
                    }
                }
                .padding(.horizontal, Self.liftMargin).padding(.vertical, Self.liftMargin)
            }
            // Clip only the top and bottom, where cards scroll under the header. The focused
            // card's shadow may spread past the sides of the list.
            .scrollClipDisabled()
            .mask { Rectangle().padding(.horizontal, -Self.liftMargin * 2) }
            .defaultFocus($focus, lastReadID.map { Focus.review($0) }, priority: .userInitiated)
        } else {
            Group {
                if let failure {
                    Text(failure)
                } else if reviews != nil {
                    Text("No written reviews on Hardcover yet.")
                } else {
                    ProgressView()
                }
            }
            .appFont(size: 28).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The whole review. Opening it disables the list, and the pane takes focus when it appears so
    /// that Up, Down, and Back reach it.
    private func reader(_ review: BookReview) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            BookReviewHeader(review: review)
            ScrollView {
                Text(review.text).appFont(size: 28).lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
            }
            .scrollPosition($readerScroll)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) {
                max(0, $0.contentSize.height - $0.containerSize.height)
            } action: { _, value in
                readerMaximumOffset = value
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 24))
        .padding(.horizontal, Self.liftMargin).padding(.vertical, Self.liftMargin)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .reader)
        .onMoveCommand { direction in
            guard direction == .up || direction == .down else { return }
            readerOffset = min(
                readerMaximumOffset, max(0, readerOffset + (direction == .down ? 180 : -180)))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                readerScroll.scrollTo(y: readerOffset)
            }
        }
        .onAppear { focus = .reader }
        .onExitCommand { closeReader() }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Press up or down to read more. Press Back to return to the reviews.")
        .accessibilityIdentifier("review-reader")
    }
}

/// The reviewer's photo and name with their rating.
private struct BookReviewHeader: View {
    let review: BookReview

    var body: some View {
        HStack {
            ReaderLabel(
                name: review.reader.displayName, avatarURL: review.reader.avatarURL, size: 28)
            Spacer()
            LikesLabel(count: review.likes).padding(.trailing, 12)
            if let rating = review.rating {
                Text(String(format: "%.1f ★", rating)).appFont(size: 28, weight: .semibold)
            }
        }
    }
}

private struct BookReviewCard: View {
    let review: BookReview
    let hidesSpoilers: Bool
    let onRead: () -> Void
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        Button(action: onRead) {
            VStack(alignment: .leading, spacing: 16) {
                BookReviewHeader(review: review)
                if hidesSpoilers {
                    Text("Review contains spoilers").appFont(size: 26).italic()
                        .foregroundStyle(.secondary)
                } else {
                    // A hidden full-height copy detects whether five lines truncate the review.
                    Text(review.text).appFont(size: 26).lineSpacing(6).lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            shownHeight = $0
                        }
                        .background(alignment: .topLeading) {
                            Text(review.text).appFont(size: 26).lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) {
                                    $0.size.height
                                } action: {
                                    fullHeight = $0
                                }
                        }
                }
                if hidesSpoilers || fullHeight > shownHeight + 1 {
                    Text(hidesSpoilers ? "Reveal review" : "Read more")
                        .appFont(size: 22, weight: .semibold).foregroundStyle(.tint)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
        .accessibilityIdentifier("book-review-\(review.id)")
    }
}

/// An icon and title with a tight gap and a small icon, for compact capsule buttons.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Places views left to right and wraps to a new line when the next one doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += subviews[index].sizeThatFits(.unspecified).width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if var last = rows.last, last.width + spacing + size.width <= width {
                last.indices.append(index)
                last.width += spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(indices: [index], width: size.width, height: size.height))
            }
        }
        return rows
    }
}

/// Every main book in a series, in order, on pages of two rows with the series name above them.
/// Each book shows its position, publication year, and full title. Books you haven't read, or
/// that aren't out yet, are faded. Selecting a book in your library opens it.
///
/// Covers come from the library artwork tier or the browsing tier, which prepares them after
/// sync; opening the pop-up fetches any that are still missing, nearest the current book first.
/// Pages scroll with focus, and chevrons mark further pages.
private struct SeriesPopup: View {
    let series: SeriesInfo
    let currentID: Int
    let libraryBook: (Int) -> Book?
    let onOpen: (Book) -> Void
    @FocusState private var focused: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Advances as covers arrive, so `CoverView` reloads from the local cache.
    @State private var artworkGeneration = 0
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var visiblePage = 0

    private static let columns = 7
    private static let coverSize = CGSize(width: 160, height: 240)
    private static let columnWidth: CGFloat = 180
    private static let columnSpacing: CGFloat = 36
    private static let rowSpacing: CGFloat = 34
    /// Room inside each page for focus lift, which the scroll view would otherwise clip.
    private static let inset: CGFloat = 24
    private static var pageWidth: CGFloat {
        CGFloat(columns) * columnWidth + CGFloat(columns - 1) * columnSpacing + 2 * inset
    }

    private var pages: [[SeriesInfo.SeriesBook]] { series.books.chunked(into: Self.columns * 2) }

    private func page(of id: Int?) -> Int {
        (series.books.firstIndex { $0.id == id } ?? 0) / (Self.columns * 2)
    }

    private var readCount: Int {
        series.books.filter { isRead(libraryBook($0.id)) }.count
    }

    private func isRead(_ book: Book?) -> Bool {
        guard let book else { return false }
        return book.isReading != true && (book.finished != nil || book.isRead == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text(series.name).appFont(size: 44, weight: .semibold)
                Text("\(readCount) of \(series.books.count) read")
                    .appFont(size: 26).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.inset)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, books in
                        pageView(books).id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .frame(width: Self.pageWidth)
            .scrollPosition($position)
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .defaultFocus($focused, currentID, priority: .userInitiated)
            .environment(\.artworkGeneration, artworkGeneration)
            .onScrollGeometryChange(for: Int.self) {
                Int(($0.contentOffset.x / Self.pageWidth).rounded())
            } action: { _, page in
                visiblePage = page
            }
            // Scrolls to the focused book's page; focus itself stays with the focus engine.
            .onChange(of: focused) {
                guard let focused else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    position.scrollTo(id: page(of: focused))
                }
            }
            .onAppear { position.scrollTo(id: page(of: currentID)) }
            .overlay(alignment: .leading) {
                if visiblePage > 0 { chevron("chevron.left").offset(x: -40) }
            }
            .overlay(alignment: .trailing) {
                if visiblePage < pages.count - 1 { chevron("chevron.right").offset(x: 40) }
            }
        }
        .padding(.vertical, 50).padding(.horizontal, 60)
        .background(.regularMaterial, in: .rect(cornerRadius: 44))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await prepareCovers() }
    }

    private func pageView(_ books: [SeriesInfo.SeriesBook]) -> some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(books.chunked(into: Self.columns).enumerated()), id: \.offset) {
                _, row in
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(row) { item($0) }
                }
            }
        }
        .padding(Self.inset)
        .frame(width: Self.pageWidth, alignment: .topLeading)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .appFont(size: 30, weight: .light)
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Fetches covers the browsing tier doesn't have yet, nearest the current book first, and
    /// reloads the covers after each batch. Cancelled when the pop-up closes.
    private func prepareCovers() async {
        let current = series.books.firstIndex { $0.id == currentID } ?? 0
        let missing = series.books.enumerated()
            .sorted { abs($0.offset - current) < abs($1.offset - current) }
            .compactMap { offset, entry in
                libraryBook(entry.id).map { $0.detailCoverURL ?? $0.coverURL } ?? entry.coverURL
            }
        for start in stride(from: 0, to: missing.count, by: 6) {
            guard !Task.isCancelled else { return }
            let fetched = await ArtworkStore.shared.prefetchBrowsing(
                Array(missing[start..<min(start + 6, missing.count)]))
            if fetched > 0 { artworkGeneration += 1 }
        }
    }

    private func item(_ entry: SeriesInfo.SeriesBook) -> some View {
        let owned = libraryBook(entry.id)
        let book =
            owned
            ?? Book(id: entry.id, title: entry.title, author: "", coverURL: entry.coverURL)
        let unreleased =
            (entry.releaseYear ?? 0) > Calendar.current.component(.year, from: .now)
        let faded = !isRead(owned) && entry.id != currentID
        return Button {
            if let owned { onOpen(owned) }
        } label: {
            VStack(spacing: 8) {
                CoverView(book: book)
                    .frame(width: Self.coverSize.width, height: Self.coverSize.height)
                    .opacity(faded ? 0.4 : 1)
                Text(
                    [SeriesInfo.positionLabel(entry.position), entry.releaseYear.map(String.init)]
                        .compactMap(\.self).joined(separator: " · ")
                )
                .appFont(size: 22, weight: .medium)
                // Titles wrap rather than truncate; long ones shrink slightly to fit two lines.
                Text(
                    entry.id == currentID
                        ? "This book" : unreleased ? "\(entry.title) (not out yet)" : entry.title
                )
                .appFont(size: 19).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                .frame(height: 48, alignment: .top)
            }
            .frame(width: Self.columnWidth)
        }
        .buttonStyle(CoverButtonStyle())
        .focusEffectDisabled()
        .focused($focused, equals: entry.id)
        .accessibilityLabel(
            "\(SeriesInfo.positionLabel(entry.position)), \(entry.title)"
                + (owned == nil ? ", not in your library" : "")
        )
        .accessibilityIdentifier("series-book-\(entry.id)")
    }
}
