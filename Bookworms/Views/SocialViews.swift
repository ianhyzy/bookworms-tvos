import SwiftUI

/// Standard typography for top-right view option buttons and reader pickers.
/// Matches the native tvOS menu bar title pill in size (29pt) and weight (.semibold).
enum HeaderOptionTypography {
    static let iconFont: Font = .system(size: 18, weight: .semibold)
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 6
}

/// Applies header typography in the user's chosen font style.
private struct SharedPillButtonLabel: ViewModifier {
    @AppStorage("fontStyle") private var fontStyle = AppFontStyle.serif
    func body(content: Content) -> some View {
        content
            .font(.system(size: 29, weight: .semibold, design: fontStyle.design))
            .padding(.horizontal, HeaderOptionTypography.horizontalPadding)
            .padding(.vertical, HeaderOptionTypography.verticalPadding)
    }
}

extension View {
    func sharedPillButtonLabel() -> some View {
        modifier(SharedPillButtonLabel())
    }
}

/// Following, Compare Shelves, and Book Club content.
///
/// The focus engine owns directional movement. Header controls, cover rows, and review actions are
/// focus sections, so movement between them is native. Focus is assigned only when content appears
/// and when `returnRevision` changes after a modal dismissal.
struct SocialViews: View {
    let library: LibraryModel
    let social: SocialLibraryModel
    @Bindable var coordinator: BookwormsCoordinator
    let onSelect: (Book) -> Void
    let onActivity: () -> Void
    let returnRevision: Int
    @FocusState private var focusedItem: Int?
    @FocusState private var isReaderPickerFocused: Bool
    @State private var review: ReviewPresentation?
    @AppStorage("dateFormat") private var dateFormat = AppDateFormat.monthName
    /// Chooses the Compare Shelves shelf photos; changes each time the view appears.
    @State private var photoSeed = Int.random(in: 0..<1000)
    @State private var upperRequest: ShelfBookFocusRequest?
    @State private var lowerRequest: ShelfBookFocusRequest?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("spoilerPolicy") private var spoilerPolicy = SpoilerPolicy.alwaysHide
    private var reader: ReaderProfile? { social.presentation.reader }

    var body: some View {
        Group {
            switch coordinator.current {
            case .following: following
            case .comparison: comparison
            case .shared: shared
            case .shelf, .yearInReview: EmptyView()
            }
        }
        .task(id: social.following.map(\.id)) {
            if coordinator.preferences.readerID == nil
                || !social.following.contains(where: { $0.id == coordinator.preferences.readerID })
            {
                if let randomID = social.following.randomElement()?.id {
                    coordinator.preferences.readerID = randomID
                    social.prepare(coordinator.preferences)
                }
            }
        }
        .onChange(of: returnRevision) { restoreContentFocus() }
        .onChange(of: focusedItem) {
            guard let focusedItem else { return }
            if coordinator.current == .following { coordinator.feedSelection = focusedItem }
            if coordinator.current == .shared { coordinator.sharedSelection = focusedItem }
            onActivity()
        }
        .sheet(item: $review) { ReviewReadingView(review: $0).appTypography() }
    }

    private func selectBook(_ book: Book) {
        onSelect(book)
    }

    private func isBookReadByUser(_ bookID: Int) -> Bool {
        if library.isBookReadByUser(bookID) { return true }
        guard library.hardcoverConnected || library.isSample else { return false }
        if let mine = social.presentation.mine.first(where: { $0.id == bookID }) {
            return mine.finished != nil || mine.book.isRead == true
        }
        return false
    }

    /// Restores the remembered item when nothing in the content already has focus.
    private func restoreContentFocus() {
        guard !isReaderPickerFocused else { return }
        switch coordinator.current {
        case .following:
            if focusedItem == nil {
                focusedItem = coordinator.feedSelection ?? feed.first?.id
            }
        case .shared:
            if focusedItem == nil {
                if !sharedBooks.isEmpty {
                    focusedItem = coordinator.sharedSelection ?? sharedBooks.first?.id
                } else if !social.following.isEmpty {
                    isReaderPickerFocused = true
                }
            }
        case .comparison:
            if !social.presentation.mine.isEmpty {
                requestRow(coordinator.comparisonRow)
            } else if !social.following.isEmpty {
                isReaderPickerFocused = true
            }
        case .shelf, .yearInReview: break
        }
    }

    private var feed: [FeedActivity] { Array(social.activities.prefix(20)) }

    private var following: some View {
        Group {
            if social.activities.isEmpty {
                empty(
                    "Your following feed",
                    "Connect Hardcover with social read permissions in Settings. Activity from people you follow appears here."
                )
            } else {
                GeometryReader { geometry in
                    let pageSize = 4
                    let spacing: CGFloat = 28
                    let cardWidth =
                        (geometry.size.width - 2 * PagedRowLayout.edgeInset
                            - CGFloat(pageSize - 1) * spacing) / CGFloat(pageSize)
                    let cardHeight = geometry.size.height - 30
                    let entryID = coordinator.feedSelection ?? feed.first?.id

                    PagedRow(
                        pages: feed.chunked(into: pageSize), height: geometry.size.height,
                        alignment: .top, partialPageGap: spacing, capacity: pageSize,
                        selectedID: focusedItem ?? entryID,
                        chevronStyle: AnyShapeStyle(.secondary.opacity(0.6)),
                        width: { _ in cardWidth }
                    ) { activity in
                        activityColumn(activity, cardWidth: cardWidth, cardHeight: cardHeight)
                    }
                    .focusSection()
                    .defaultFocus($focusedItem, entryID, priority: .userInitiated)
                    .onAppear { focusedItem = entryID }
                }
            }
        }
    }

    private func activityColumn(_ activity: FeedActivity, cardWidth: CGFloat, cardHeight: CGFloat)
        -> some View
    {
        VStack(spacing: 16) {
            Button {
                if let book = activity.book {
                    selectBook(book)
                } else {
                    review = ReviewPresentation(
                        title: activity.reader.displayName,
                        text: activity.summary, spoilers: false)
                }
            } label: {
                ActivityCard(
                    activity: activity,
                    isBookRead: isBookReadByUser(activity.book?.id ?? activity.id),
                    isCompact: true,
                    coverHeight: max(260, cardHeight - 340)
                )
                .frame(
                    width: cardWidth,
                    height: cardHeight - (activity.review != nil ? 70 : 0),
                    alignment: .top)
            }
            .buttonStyle(CoverButtonStyle())
            .focusEffectDisabled()
            .background(
                focusedItem == activity.id && activity.book == nil
                    ? Color.primary.opacity(0.12) : .clear,
                in: .rect(cornerRadius: 12)
            )
            .focused($focusedItem, equals: activity.id)
            .accessibilityIdentifier("activity-\(activity.id)")
            if let text = activity.review {
                let isRead = isBookReadByUser(activity.book?.id ?? activity.id)
                let hidesSpoilers =
                    activity.hasSpoilers && (spoilerPolicy == .alwaysHide || !isRead)
                Button("Read review") {
                    review = ReviewPresentation(
                        title: activity.reader.displayName, text: text,
                        spoilers: hidesSpoilers)
                }
                .buttonStyle(.glass).frame(width: cardWidth)
                .accessibilityIdentifier("activity-review-\(activity.id)")
            }
        }
    }

    private var comparison: some View {
        GeometryReader { geometry in
            let rowHeight = max(120, min(300, (geometry.size.height - 414) / 2))
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 20) {
                    Spacer()
                    comparisonOrderMenu
                    readerPicker
                }
                .padding(.top, 54)
                .focusSection()

                if let reader {
                    VStack(alignment: .leading, spacing: 2) {
                        ReaderLabel(name: "You", avatarURL: ownerAvatar, size: 24)
                        ComparisonBookshelf(
                            library: library,
                            books: social.presentation.mine,
                            state: coordinator.upper, rowHeight: rowHeight,
                            width: geometry.size.width - 2 * PagedRowLayout.edgeInset,
                            activatesOnAppear: coordinator.comparisonRow == 0,
                            emptySpacePhoto: ShelfPhoto.names(seed: photoSeed)[0],
                            isLoading: social.isLoading,
                            column: coordinator.comparisonColumn,
                            focusRequest: upperRequest,
                            onSelect: selectBook,
                            onFocus: { column in
                                coordinator.comparisonRow = 0
                                coordinator.comparisonColumn = column
                                onActivity()
                            }
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("comparison-upper")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ReaderLabel(
                            name: reader.displayName, avatarURL: reader.avatarURL, size: 24)
                        // One profile photo's height (1.5 × 24 points) keeps a lifted cover clear of
                        // the reader's name; the caption below moves down with the row.
                        Color.clear.frame(height: 36)
                        ComparisonBookshelf(
                            library: library,
                            books: social.presentation.theirs,
                            state: coordinator.lower, rowHeight: rowHeight,
                            width: geometry.size.width - 2 * PagedRowLayout.edgeInset,
                            activatesOnAppear: coordinator.comparisonRow == 1,
                            emptySpacePhoto: ShelfPhoto.names(seed: photoSeed)[1],
                            isLoading: social.isLoading,
                            column: coordinator.comparisonColumn,
                            focusRequest: lowerRequest,
                            onSelect: selectBook,
                            onFocus: { column in
                                coordinator.comparisonRow = 1
                                coordinator.comparisonColumn = column
                                onActivity()
                            }
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("comparison-lower")
                    }
                    comparisonCaption(reader: reader).frame(height: 124, alignment: .topLeading)
                } else {
                    empty(
                        "Choose a reader",
                        "Select someone you follow above or in Settings → Views to compare your books."
                    )
                }
            }
        }
        .onAppear { photoSeed = Int.random(in: 0..<1000) }
    }

    private func requestRow(_ row: Int) {
        let state = row == 0 ? coordinator.upper : coordinator.lower
        let books = row == 0 ? social.presentation.mine : social.presentation.theirs
        guard let id = state.selectedID ?? books.first?.id else { return }
        let request = ShelfBookFocusRequest(
            id: id,
            revision: (row == 0 ? upperRequest?.revision : lowerRequest?.revision).map { $0 + 1 }
                ?? 1)
        if row == 0 { upperRequest = request } else { lowerRequest = request }
        coordinator.comparisonRow = row
    }

    /// Two columns under the rows: the selected book's title, author, and reading line, then
    /// both readers' star ratings, yours on top to match the rows.
    private func comparisonCaption(reader: ReaderProfile) -> some View {
        let isMine = coordinator.comparisonRow == 0
        let id = isMine ? coordinator.upper.selectedID : coordinator.lower.selectedID
        let rows = isMine ? social.presentation.mine : social.presentation.theirs
        let selected = rows.first { $0.id == id }
        // Your library has your read edition; a reader's row has their edition and last read date.
        let book = selected.map { selected in
            if isMine, let owned = library.book(withID: selected.id) { return owned }
            var book = selected.book
            book.finished = book.finished ?? selected.finished
            return book
        }
        let yourRating = selected.flatMap {
            isMine ? $0.rating : social.presentation.myRatings[$0.id]
        }
        let theirRating = selected.flatMap {
            isMine ? social.presentation.theirRatings[$0.id] : $0.rating
        }
        return HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 6) {
                Text(book?.title ?? "Select a book").appFont(size: 33, weight: .medium)
                    .lineLimit(1)
                Text(book?.author ?? "")
                    .appFont(size: 29).opacity(0.82).lineLimit(1)
                    .accessibilityIdentifier("comparison-author")
                if let book { ReadingLine(book: book, dateFormat: dateFormat) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selected != nil {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                    ratingRow("You", avatarURL: ownerAvatar, yourRating)
                    ratingRow(reader.displayName, avatarURL: reader.avatarURL, theirRating)
                }
                .padding(.vertical, 14).padding(.horizontal, 24)
                .background(.regularMaterial, in: .rect(cornerRadius: 28))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("comparison-ratings")
            }
        }
    }

    private var ownerAvatar: URL? { social.snapshot?.owner.avatarURL }

    private func ratingRow(_ name: String, avatarURL: URL?, _ rating: Double?) -> some View {
        GridRow {
            ReaderLabel(name: name, avatarURL: avatarURL, size: 26)
            // Stars always take their space, so rows keep their size when a rating is missing.
            ZStack(alignment: .leading) {
                StarRating(rating: rating ?? 0).opacity(rating == nil ? 0 : 1)
                if rating == nil {
                    Text("Not rated").appFont(size: 26).opacity(0.7)
                }
            }
        }
    }

    private var sharedBooks: [SharedRead] {
        social.presentation.shared
    }
    private var shared: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 20) {
                    Spacer()
                    readerPicker
                    sharedSortMenu
                }
                .padding(.top, 54)
                .focusSection()

                if let reader, !sharedBooks.isEmpty {
                    let pageSize = 7
                    let entryID = coordinator.sharedSelection ?? sharedBooks.first?.id

                    VStack(alignment: .leading, spacing: 16) {
                        PagedRow(
                            pages: sharedBooks.chunked(into: pageSize), height: 292,
                            partialPageGap: 75, capacity: pageSize,
                            selectedID: focusedItem ?? entryID,
                            chevronStyle: AnyShapeStyle(.secondary.opacity(0.6)),
                            // Wide covers shrink to fit so seven covers and their minimum gaps fit a page.
                            width: {
                                min(
                                    (geometry.size.width - 2 * PagedRowLayout.edgeInset
                                        - CGFloat(pageSize - 1) * 28) / CGFloat(pageSize),
                                    280 * (library.coverRatios[$0.id] ?? 2.0 / 3.0))
                            }
                        ) { shared in
                            SharedCoverButton(book: shared.mine.book, library: library) {
                                selectBook(shared.mine.book)
                            }
                            .focused($focusedItem, equals: shared.id)
                            .accessibilityIdentifier("shared-\(shared.id)")
                        }
                        .padding(.vertical, 14)
                        .focusSection()
                        .defaultFocus($focusedItem, entryID, priority: .userInitiated)
                        .accessibilityIdentifier("shared-cover-rail")
                        .onAppear { focusedItem = entryID }

                        if let selected = sharedBooks.first(where: {
                            $0.id == coordinator.sharedSelection
                        }) ?? sharedBooks.first {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(alignment: .firstTextBaseline, spacing: 24) {
                                    Text(selected.mine.book.title)
                                        .appFont(size: 32, weight: .semibold).lineLimit(1)
                                    Text(selected.mine.book.author).appFont(size: 25)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                                .background(.regularMaterial, in: .rect(cornerRadius: 24))

                                HStack(alignment: .top, spacing: 28) {
                                    reviewPanel("You", avatarURL: ownerAvatar, item: selected.mine)
                                    reviewPanel(
                                        reader.displayName, avatarURL: reader.avatarURL,
                                        item: selected.theirs)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .focusSection()
                            }
                            .frame(
                                maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    empty(
                        "Book Club",
                        reader == nil
                            ? "Choose a reader above or in Settings → Views."
                            : "No books with ratings from both readers are available."
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func reviewPanel(_ name: String, avatarURL: URL?, item: ReaderBook) -> some View {
        SharedReviewCard(
            name: name, avatarURL: avatarURL, item: item, isBookRead: isBookReadByUser(item.id),
            // The card's own Reveal review press is the spoiler confirmation.
            onRead: {
                review = ReviewPresentation(
                    title: name, text: item.reviewText ?? "", spoilers: false)
            }
        )
        .id("\(name)-\(item.id)")
    }

    private func empty(_ title: String, _ message: String) -> some View {
        VStack(spacing: 22) {
            Text(title).appFont(size: 38, weight: .medium)
            Text(message).appFont(size: 26).multilineTextAlignment(.center)
                .frame(maxWidth: 850)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sharedSortMenu: some View {
        Menu {
            ForEach(SharedReadsSort.allCases) { sort in
                Button {
                    coordinator.preferences.sharedReadsSort = sort
                    // Show the start of the reordered list rather than the old selection.
                    coordinator.sharedSelection = nil
                    onActivity()
                } label: {
                    if sort == coordinator.preferences.sharedReadsSort {
                        Label(sort.rawValue, systemImage: "checkmark")
                    } else {
                        Text(sort.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(coordinator.preferences.sharedReadsSort.rawValue)
                Image(systemName: "chevron.up.chevron.down")
                    .font(HeaderOptionTypography.iconFont)
            }
            .sharedPillButtonLabel()
        }
        .performanceGlassButton()
        .accessibilityLabel("Book Club sort options")
        .accessibilityValue(coordinator.preferences.sharedReadsSort.rawValue)
        .accessibilityIdentifier("view-options")
    }

    @ViewBuilder
    private var comparisonOrderMenu: some View {
        Menu {
            ForEach(ComparisonOrder.allCases) { order in
                Button {
                    coordinator.preferences.comparisonOrder = order
                    onActivity()
                } label: {
                    if order == coordinator.preferences.comparisonOrder {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(coordinator.preferences.comparisonOrder.rawValue)
                Image(systemName: "chevron.up.chevron.down")
                    .font(HeaderOptionTypography.iconFont)
            }
            .sharedPillButtonLabel()
        }
        .performanceGlassButton()
        .accessibilityLabel("Side by side ordering options")
        .accessibilityValue(coordinator.preferences.comparisonOrder.rawValue)
        .accessibilityIdentifier("comparison-order-options")
    }

    @ViewBuilder
    private var readerPicker: some View {
        if !social.following.isEmpty {
            Menu {
                Button {
                    pickRandomReader()
                } label: {
                    Label("Random reader", systemImage: "shuffle")
                }
                Divider()
                ForEach(social.following) { follow in
                    Button {
                        selectReader(follow.id)
                    } label: {
                        if follow.id == coordinator.preferences.readerID {
                            Label(follow.displayName, systemImage: "checkmark")
                        } else {
                            Text(follow.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if let reader {
                        // Matches the pill's 29-point semibold text.
                        ReaderLabel(
                            name: reader.displayName, avatarURL: reader.avatarURL, size: 29,
                            weight: .semibold, avatarScale: 1.1)
                    } else {
                        Image(systemName: "person.crop.circle")
                        Text("Select reader")
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(HeaderOptionTypography.iconFont)
                }
                .sharedPillButtonLabel()
            }
            .performanceGlassButton()
            .focused($isReaderPickerFocused)
            .accessibilityLabel(reader.map { "Reader: \($0.displayName)" } ?? "Select reader")
            .accessibilityIdentifier("reader-picker-menu")
        }
    }

    private func selectReader(_ id: Int) {
        coordinator.preferences.readerID = id
        coordinator.sharedSelection = nil
        coordinator.lower.selectedID = nil
        social.prepare(coordinator.preferences)
    }

    private func pickRandomReader() {
        let others = social.following.filter { $0.id != coordinator.preferences.readerID }
        let pick = (others.isEmpty ? social.following : others).randomElement()
        if let pick {
            selectReader(pick.id)
        }
    }
}

extension Array {
    /// Consecutive groups of `size` elements; the last group can be shorter.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Sizes the cover from the prepared aspect ratio so paged layout matches the rendered artwork.
private struct SharedCoverButton: View {
    let book: Book
    let library: LibraryModel
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            CoverView(
                book: book,
                onAspectRatio: { library.recordCoverRatio($0, for: book.id) }
            )
            .frame(height: 280)
        }
        .buttonStyle(CoverButtonStyle())
        .focusEffectDisabled()
    }
}

private struct SharedReviewCard: View {
    @AppStorage("fontStyle") private var fontStyle = AppFontStyle.serif
    @AppStorage("spoilerPolicy") private var spoilerPolicy = SpoilerPolicy.alwaysHide
    let name: String
    let avatarURL: URL?
    let item: ReaderBook
    let isBookRead: Bool
    let onRead: () -> Void

    var body: some View {
        let hidesSpoilers =
            item.hasSpoilers && (spoilerPolicy == .alwaysHide || !isBookRead)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                ReaderLabel(name: name, avatarURL: avatarURL, size: 34)
                Spacer()
                Text(item.rating.map { String(format: "%.1f ★", $0) } ?? "Not rated")
                    .appFont(size: 34, weight: .semibold)
            }
            Divider()
            GeometryReader { geometry in
                if hidesSpoilers {
                    let actionAvailable = item.reviewText != nil
                    VStack(spacing: 24) {
                        Spacer()
                        Text("Review contains spoilers")
                            .appFont(size: 28)
                            .italic()
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                        if actionAvailable {
                            Button(action: onRead) {
                                Text("Reveal review")
                                    .sharedPillButtonLabel()
                            }
                            .performanceGlassButton()
                            .accessibilityIdentifier("shared-review-\(name)")
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    let text = item.reviewText ?? "No written review"
                    // Measure at the same font and width as the rendered text, including explicit line breaks.
                    let fullHeight = (text as NSString)
                        .boundingRect(
                            with: CGSize(
                                width: max(1, geometry.size.width),
                                height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            attributes: [.font: fontStyle.uiFont(size: 28)], context: nil
                        )
                        .height.rounded(.up)
                    let overflow = item.reviewText != nil && fullHeight > geometry.size.height
                    let actionAvailable = item.reviewText != nil && overflow
                    VStack(alignment: .leading, spacing: 18) {
                        Text(text).appFont(size: 28)
                            .lineLimit(
                                actionAvailable
                                    ? max(1, Int((geometry.size.height - 90) / 36)) : nil
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if actionAvailable {
                            Button(action: onRead) {
                                Text("Read review")
                                    .sharedPillButtonLabel()
                            }
                            .performanceGlassButton()
                            .accessibilityIdentifier("shared-review-\(name)")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
    }
}

struct ActivityCard: View {
    @AppStorage("dateFormat") private var dateFormat = AppDateFormat.monthName
    @AppStorage("spoilerPolicy") private var spoilerPolicy = SpoilerPolicy.alwaysHide
    let activity: FeedActivity
    var isBookRead = false
    var isAmbient = false
    var isCompact = false
    var coverHeight: CGFloat = 420
    var body: some View {
        let layout =
            isCompact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 26))
        layout {
            if let book = activity.book {
                CoverView(book: book)
                    .frame(width: isCompact ? nil : 160, height: isCompact ? coverHeight : 225)
                    .accessibilityIdentifier("activity-cover-\(activity.id)")
            }
            VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
                HStack(spacing: 10) {
                    Group {
                        if let url = activity.reader.avatarURL {
                            CachedAvatarView(url: url)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable().scaledToFit()
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(.circle)
                    .accessibilityHidden(true)
                    Text(activity.reader.displayName)
                        .appFont(size: isCompact ? 24 : 28, weight: .semibold)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                Text(activity.summary).appFont(size: isCompact ? 23 : 26)
                    .lineLimit(isCompact ? 1 : 2)
                if let book = activity.book {
                    Text(book.title).appFont(size: isCompact ? 27 : 30, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(book.author).appFont(size: 24).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let rating = activity.rating { Text(String(format: "%.1f ★", rating)) }
                if let review = activity.review, !isCompact {
                    let hidesSpoilers =
                        activity.hasSpoilers && (spoilerPolicy == .alwaysHide || !isBookRead)
                    Text(hidesSpoilers ? "Review contains spoilers" : review)
                        .appFont(size: 23).lineLimit(2)
                }
                if let date = activity.date {
                    Text(dateFormat.string(from: date))
                        .appFont(size: 21).foregroundStyle(.secondary)
                }
                if activity.likes > 0 {
                    Label("\(activity.likes) likes", systemImage: "heart").appFont(size: 21)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(isCompact ? 16 : 22).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReviewPresentation: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let spoilers: Bool
}

struct ReviewReadingView: View {
    let review: ReviewPresentation
    @State private var revealed = false
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var offset: CGFloat = 0
    @State private var maximumOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Button("Back") { dismiss() }.buttonStyle(.glass)
            Text(review.title).font(.title)
            if review.spoilers && !revealed {
                Text("This review contains spoilers.")
                Button("Reveal spoilers") { revealed = true }.buttonStyle(.glassProminent)
            } else {
                ScrollView {
                    Text(review.text).appFont(size: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition($scrollPosition)
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) {
                    max(0, $0.contentSize.height - $0.containerSize.height)
                } action: { _, value in
                    maximumOffset = value
                }
            }
        }
        .onMoveCommand { direction in
            guard !review.spoilers || revealed, direction == .up || direction == .down else {
                return
            }
            offset = min(maximumOffset, max(0, offset + (direction == .down ? 180 : -180)))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(y: offset)
            }
        }
        .onExitCommand { dismiss() }
        .padding(70)
        .frame(width: 1400, height: 800)
    }
}

/// A reader's profile photo and name, as Hardcover shows them. The photo scales with the text
/// size; readers without a photo get a person symbol.
struct ReaderLabel: View {
    let name: String
    let avatarURL: URL?
    let size: CGFloat
    var weight: Font.Weight = .medium
    /// The photo's diameter relative to `size`. Header pills use a smaller photo so they keep
    /// the same height as the pills beside them.
    var avatarScale: CGFloat = 1.5

    var body: some View {
        HStack(spacing: size * 0.4) {
            Group {
                if let avatarURL {
                    CachedAvatarView(url: avatarURL)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: size * avatarScale, height: size * avatarScale)
            .clipShape(.circle)
            .accessibilityHidden(true)
            Text(name).appFont(size: size, weight: weight).lineLimit(1)
        }
    }
}

struct CachedAvatarView: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard
                let data = try? await ArtworkStore.shared.data(
                    for: url, maximumPixelSize: 400, allowsNetwork: true),
                !Task.isCancelled
            else { return }
            image = UIImage(data: data)
        }
    }
}
