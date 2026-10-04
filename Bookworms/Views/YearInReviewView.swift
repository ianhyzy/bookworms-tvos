import SwiftUI

/// One year of reading: headline totals, books per month, top genres and formats, records, and a
/// shelf of the year's covers. The header's year menu changes the year in place.
///
/// Statistics come from `LibraryModel.readingYears`, prepared when the library changes. The
/// header and the cover row are focus sections. Focus is assigned only when the row appears and
/// when `returnRevision` changes after a modal dismissal.
struct YearInReviewView: View {
    let library: LibraryModel
    let coordinator: BookwormsCoordinator
    let palette: ShelfPalette
    let onSelect: (Book) -> Void
    let onActivity: () -> Void
    let returnRevision: Int
    @FocusState private var focusedBook: Int?
    @AppStorage("dateFormat") private var dateFormat = AppDateFormat.monthName
    /// Chooses the shelf photo; changes each time the view appears.
    @State private var photoSeed = Int.random(in: 0..<1000)

    private var review: YearInReview? { library.yearInReview(coordinator.reviewYear) }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    Spacer()
                    if review != nil { yearMenu }
                }
                .padding(.top, 54)
                .focusSection()

                if let review {
                    totals(review)
                    // Tall enough for the highlights panel's three labeled rows; a shorter frame
                    // lets its background spill into the tiles and shelf.
                    HStack(alignment: .top, spacing: 24) {
                        monthlyChart(review)
                        highlights(review).frame(width: review.longest == nil ? 620 : 540)
                        if review.longest != nil { records(review).frame(width: 540) }
                    }
                    .frame(height: 300)
                    // The shelf takes whatever height the fixed rows and caption leave.
                    GeometryReader { space in
                        coverShelf(
                            review, width: geometry.size.width,
                            rowHeight: min(360, max(150, space.size.height - Self.boardHeight))
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    caption(review).frame(height: 118, alignment: .topLeading)
                } else {
                    empty
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .onAppear { photoSeed = Int.random(in: 0..<1000) }
        .onChange(of: returnRevision) {
            guard focusedBook == nil, let review else { return }
            focusedBook = entryID(review)
        }
        .onChange(of: focusedBook) {
            guard let focusedBook else { return }
            coordinator.reviewSelection = focusedBook
            onActivity()
        }
    }

    private func entryID(_ review: YearInReview) -> Int? {
        let remembered = coordinator.reviewSelection.flatMap { id in
            review.shelf.contains { $0.id == id } ? id : nil
        }
        return remembered ?? review.shelf.first?.id
    }

    private var yearMenu: some View {
        let selected = review?.year
        return Menu {
            ForEach(library.readingYears) { year in
                Button {
                    coordinator.reviewYear = year.year
                    // Show the start of the new year's shelf rather than the old selection.
                    coordinator.reviewSelection = nil
                    onActivity()
                } label: {
                    if year.year == selected {
                        Label(String(year.year), systemImage: "checkmark")
                    } else {
                        Text(verbatim: String(year.year))
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: selected.map { String($0) } ?? "")
                Image(systemName: "chevron.up.chevron.down")
                    .font(HeaderOptionTypography.iconFont)
            }
            .sharedPillButtonLabel()
        }
        .performanceGlassButton()
        .accessibilityLabel("Year")
        .accessibilityValue(selected.map { String($0) } ?? "")
        .accessibilityIdentifier("review-year-options")
    }

    // MARK: - Statistics

    private func totals(_ review: YearInReview) -> some View {
        HStack(spacing: 24) {
            tile(
                "Books read", value: review.books.count.formatted(),
                detail: "Finished in \(String(review.year))")
            tile(
                "Pages", value: review.pages > 0 ? review.pages.formatted() : "—",
                detail: review.booksWithPages == 0
                    ? "No page counts recorded"
                    : review.booksWithPages == review.books.count
                        ? "Across every book"
                        : "Across \(review.booksWithPages) of \(review.books.count) books")
            ratingTile(review)
            tile(
                "Busiest month",
                value: review.busiestMonth.map { Self.monthNames[$0 - 1] } ?? "—",
                detail: review.busiestMonth.map {
                    Self.bookCount(review.monthlyCounts[$0 - 1])
                } ?? "")
        }
        .frame(height: 150)
    }

    private func tile(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appFont(size: 24).foregroundStyle(.secondary)
            Text(value).appFont(size: 54, weight: .semibold).lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).appFont(size: 22).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }

    private func ratingTile(_ review: YearInReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Average rating").appFont(size: 24).foregroundStyle(.secondary)
            if let average = review.averageRating {
                HStack(alignment: .center, spacing: 16) {
                    Text(average.formatted(.number.precision(.fractionLength(1))))
                        .appFont(size: 54, weight: .semibold)
                    StarRating(rating: (average * 2).rounded() / 2, size: 24)
                }
                Text("From \(Self.bookCount(review.ratedBooks)) rated")
                    .appFont(size: 22).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("—").appFont(size: 54, weight: .semibold)
                Text("No ratings recorded").appFont(size: 22).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }

    /// Twelve static bars scaled to the busiest month, with each month's count above its bar.
    private func monthlyChart(_ review: YearInReview) -> some View {
        let most = max(1, review.monthlyCounts.max() ?? 0)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Books by month").appFont(size: 24).foregroundStyle(.secondary)
            GeometryReader { geometry in
                // Room for the count above each bar and the month name below it.
                let barSpace = max(20, geometry.size.height - 76)
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(0..<12, id: \.self) { month in
                        let count = review.monthlyCounts[month]
                        VStack(spacing: 8) {
                            Text(verbatim: count > 0 ? String(count) : " ")
                                .appFont(size: 22, weight: .medium)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    count > 0
                                        ? AnyShapeStyle(Self.barGradient)
                                        : AnyShapeStyle(HierarchicalShapeStyle.quaternary)
                                )
                                .frame(
                                    height: count > 0
                                        ? max(8, barSpace * CGFloat(count) / CGFloat(most)) : 4)
                            Text(Self.monthInitials[month]).appFont(size: 22)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Books by month")
        .accessibilityValue(
            review.monthlyCounts.enumerated().filter { $0.element > 0 }
                .map { "\(Self.monthNames[$0.offset]) \($0.element)" }
                .joined(separator: ", "))
    }

    private func highlights(_ review: YearInReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top genres").appFont(size: 24).foregroundStyle(.secondary)
            if review.genres.isEmpty {
                Text("No genres recorded").appFont(size: 28, weight: .medium)
            } else {
                Text(review.genres.prefix(4).map(\.name).joined(separator: " · "))
                    .appFont(size: 28, weight: .medium).lineLimit(1).minimumScaleFactor(0.8)
            }
            if let author = review.topAuthor {
                Text("Most-read author").appFont(size: 24).foregroundStyle(.secondary)
                    .padding(.top, 10)
                Text("\(author.name) · \(Self.bookCount(author.count))")
                    .appFont(size: 28, weight: .medium).lineLimit(1)
            }
            if !review.formats.isEmpty {
                Text("Formats").appFont(size: 24).foregroundStyle(.secondary)
                    .padding(.top, 10)
                HStack(spacing: 32) {
                    ForEach(review.formats, id: \.name) { format in
                        HStack(spacing: 10) {
                            Image(systemName: Book.formatSymbol(forLabel: format.name))
                            Text(format.count.formatted())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(format.name): \(Self.bookCount(format.count))")
                    }
                }
                .appFont(size: 28, weight: .medium)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }

    /// The year's longest, shortest, and highest-rated books, in the highlights panel's style.
    private func records(_ review: YearInReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let book = review.longest, let pages = book.pages {
                record("Longest", book, detail: "\(pages.formatted()) pages")
            }
            if let book = review.shortest, let pages = book.pages {
                record("Shortest", book, detail: "\(pages.formatted()) pages").padding(.top, 10)
            }
            if let book = review.favorite, let rating = book.rating {
                record(
                    "Highest rated", book,
                    detail: "★ " + rating.formatted(.number.precision(.fractionLength(0...1)))
                )
                .padding(.top, 10)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }

    private func record(_ title: String, _ book: Book, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).appFont(size: 24).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Text(book.spineTitle).lineLimit(1)
                Text(" · \(detail)").fixedSize()
            }
            .appFont(size: 28, weight: .medium)
        }
    }

    // MARK: - Covers

    /// The year's covers standing on a shelf, in fixed-width columns so pages stay the same size
    /// whatever the covers' proportions.
    private func coverShelf(_ review: YearInReview, width: CGFloat, rowHeight: CGFloat)
        -> some View
    {
        let coverHeight = rowHeight * 0.92
        let rowWidth = width - 2 * PagedRowLayout.edgeInset
        let columns = max(
            1, Int((rowWidth + ShelfLayout.gap) / (coverHeight * 2 / 3 + ShelfLayout.gap)))
        let columnWidth = (rowWidth - CGFloat(columns - 1) * ShelfLayout.gap) / CGFloat(columns)
        let entryID = entryID(review)
        return VStack(spacing: 0) {
            PagedRow(
                pages: review.shelf.chunked(into: columns), height: rowHeight,
                alignment: .bottom, capacity: columns,
                emptySpacePhoto: ShelfPhoto.names(seed: photoSeed)[0],
                selectedID: focusedBook ?? entryID,
                chevronStyle: AnyShapeStyle(palette.text.opacity(0.45)),
                width: {
                    min(columnWidth, coverHeight * (library.coverRatios[$0.id] ?? 2.0 / 3.0))
                }
            ) { book in
                Button {
                    onSelect(book)
                } label: {
                    CoverView(
                        book: book, standsOnShelf: true,
                        onAspectRatio: { library.recordCoverRatio($0, for: book.id) }
                    )
                    .frame(height: coverHeight)
                }
                .buttonStyle(CoverButtonStyle())
                .focusEffectDisabled()
                .focused($focusedBook, equals: book.id)
                .accessibilityLabel("\(book.title), by \(book.author)")
                .accessibilityHint("Open book details")
                .accessibilityIdentifier("year-book-\(book.id)")
            }
            .focusSection()
            .defaultFocus($focusedBook, entryID, priority: .userInitiated)
            .onAppear { focusedBook = entryID }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("year-shelf")
            ShelfBoard(palette: palette)
        }
    }

    private func caption(_ review: YearInReview) -> some View {
        let book =
            review.shelf.first { $0.id == (focusedBook ?? coordinator.reviewSelection) }
        return Group {
            if let book {
                BookCaption(book: book, dateFormat: dateFormat)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shelfSummary(review)).appFont(size: 33, weight: .medium).lineLimit(1)
                    Text("Select a cover to look inside").appFont(size: 29).opacity(0.82)
                }
            }
        }
        .foregroundStyle(palette.text)
        .accessibilityHidden(true)
    }

    private func shelfSummary(_ review: YearInReview) -> String {
        review.shelf.count < review.books.count
            ? "Your \(review.shelf.count) highest-rated books of \(String(review.year))"
            : "Every book you finished in \(String(review.year))"
    }

    private var empty: some View {
        VStack(spacing: 22) {
            Text("Your year in books").appFont(size: 38, weight: .medium)
            Text(
                library.isConnected || library.isSample
                    ? "Books with a recorded finish date appear here, grouped by year."
                    : "Connect Hardcover in Settings to see what you read each year."
            )
            .appFont(size: 26).multilineTextAlignment(.center).frame(maxWidth: 850)
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Formatting

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        return calendar
    }()
    private static let monthNames = calendar.standaloneMonthSymbols
    /// Single-letter labels keep twelve bars legible beside the highlights and records panels.
    private static let monthInitials = calendar.veryShortStandaloneMonthSymbols

    /// `ShelfBoard`'s default surface depth plus edge height.
    private static let boardHeight: CGFloat = 26

    private static func bookCount(_ count: Int) -> String {
        count == 1 ? "1 book" : "\(count.formatted()) books"
    }

    /// Gold bars, the chart's one accent color.
    private static var barGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1, green: 0.87, blue: 0.36), Color(red: 0.95, green: 0.68, blue: 0.1),
            ], startPoint: .top, endPoint: .bottom)
    }
}
