import SwiftUI

/// Shares column dimensions between native details and the wall's 3D presentation.
enum BookDetailCoverLayout {
    static let horizontalPadding: CGFloat = 80
    static let verticalPadding: CGFloat = 54
    static let columnFraction: CGFloat = 0.24
    static let wallColumnFraction: CGFloat = 0.32
    static let wallNavigationCoverSize = CGSize(width: 300, height: 144)
    static let coverHeightFraction: CGFloat = 0.60
    static let backHeight: CGFloat = 64
    static let coverGap: CGFloat = 64
    static let detailColumnGap: CGFloat = 80
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
    @Environment(\.dismiss) private var dismiss
    @State private var showsReviews = false
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
        onClose: (() -> Void)? = nil
    ) {
        self.book = book
        self.style = style
        self.loadReviews = loadReviews
        self.showsCover = showsCover
        self.showsBackButton = showsBackButton
        self.onClose = onClose
        genres = (book.genres ?? []).filter(HardcoverClient.isEnglishTag).prefix(3)
            .map(Book.displayGenre)
    }

    var body: some View {
        GeometryReader { geometry in
            let coverColumnWidth =
                geometry.size.width
                * (showsCover
                    ? BookDetailCoverLayout.columnFraction
                    : BookDetailCoverLayout.wallColumnFraction)
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
                HStack(
                    alignment: .top,
                    spacing: showsCover ? 56 : BookDetailCoverLayout.detailColumnGap
                ) {
                    VStack(alignment: .leading, spacing: BookDetailCoverLayout.coverGap) {
                        if showsBackButton {
                            Button {
                                close()
                            } label: {
                                Label("Back to view", systemImage: "chevron.left")
                            }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("back-to-shelf")
                            .padding(.leading, showsCover ? 0 : 60)
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
                    // Right from Back and Up from Show more both reach the histogram, and the
                    // full-width description section catches Down from the histogram.
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(book.title)
                                    .appFont(size: 56, weight: .semibold)
                                    .lineLimit(3).minimumScaleFactor(0.7)
                                    .accessibilityIdentifier("detail-title")
                                Text(book.author).appFont(size: 30)
                                    .foregroundStyle(.secondary)
                            }
                            metadata
                        }
                        .focusSection()
                        Divider().overlay(.primary.opacity(0.12))
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

    /// Reading facts in two columns, then genres, then the community histogram, which takes the
    /// remaining width and opens reviews when Hardcover can supply them.
    private var metadata: some View {
        var items = [
            ("Finished", book.finishedLabel(format: dateFormat), "checkmark.circle")
        ]
        if let rating = book.rating {
            items.append(
                (
                    "Your rating",
                    "\(rating.formatted(.number.precision(.fractionLength(0...2)))) / 5", "star"
                ))
        }
        if let pages = book.pages, pages > 0 {
            items.append(("Length", "\(pages) pages", "text.book.closed"))
        }
        if let format = book.formatLabel {
            items.append(("Format", format, book.formatSymbol))
        }
        return HStack(alignment: .top, spacing: showsCover ? 44 : 28) {
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 20) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                    GridRow {
                        metadataItem(items[index].0, value: items[index].1, symbol: items[index].2)
                        if index + 1 < items.count {
                            metadataItem(
                                items[index + 1].0, value: items[index + 1].1,
                                symbol: items[index + 1].2)
                        }
                    }
                }
            }
            .fixedSize()
            if !genres.isEmpty {
                metadataItem(
                    "Genres",
                    // A non-breaking space keeps each dot with the genre before it when wrapping.
                    value: genres.joined(separator: "\u{00A0}· "), symbol: "tag", lines: 5
                )
                .frame(width: showsCover ? 330 : 250, alignment: .leading)
            }
            Group {
                if loadReviews != nil {
                    Button {
                        showsReviews = true
                    } label: {
                        RatingsView(book: book, opensReviews: true)
                    }
                    .buttonStyle(FocusHighlightButtonStyle())
                    .focusEffectDisabled()
                    .accessibilityHint("Shows community reviews.")
                    .accessibilityIdentifier("community-reviews")
                } else {
                    RatingsView(book: book)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private func metadataItem(_ title: String, value: String, symbol: String, lines: Int = 2)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
            }
            .appFont(size: 18).foregroundStyle(.secondary)
            Text(value).appFont(size: 23, weight: .medium).lineLimit(lines)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A capsule with flat fills and the tvOS focus look: a translucent platter that turns white and
/// lifts with focus. Unlike glass, it never samples the content behind it.
private struct FlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Platter(configuration: configuration)
    }

    private struct Platter: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
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
