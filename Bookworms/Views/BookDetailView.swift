import SwiftUI

struct BookDetailView: View {
    @AppStorage("dateFormat") private var dateFormat = AppDateFormat.monthName
    let book: Book
    let style: SpineStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var descriptionOffset: CGFloat = 0
    @State private var maximumOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
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
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Label("Back to view", systemImage: "chevron.left")
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("back-to-shelf")
                        Spacer()
                    }
                    HStack(alignment: .top, spacing: 72) {
                        VStack(alignment: .leading, spacing: 24) {
                            CoverView(book: book)
                                .frame(
                                    width: geometry.size.width * 0.25,
                                    height: geometry.size.height * 0.52
                                )
                            RatingsView(book: book)
                        }
                        .frame(width: geometry.size.width * 0.25)
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
                            Divider().overlay(.primary.opacity(0.12))
                            ScrollView {
                                Text(descriptionText)
                                    .appFont(size: 27).lineSpacing(8)
                                    .foregroundStyle(.primary.opacity(0.86))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 30)
                                    .accessibilityIdentifier("book-description")
                            }
                            .scrollPosition($scrollPosition)
                            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                                max(0, geometry.contentSize.height - geometry.containerSize.height)
                            } action: { _, value in
                                maximumOffset = value
                            }
                            .scrollIndicators(.hidden)
                            .accessibilityLabel("Book description")
                            .accessibilityHint(
                                "Press up or down to read more. Press Back to return to the shelf.")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 80).padding(.vertical, 54)
            }
        }
        // Route remote presses directly to the description without requiring scrollbar focus.
        .onMoveCommand { direction in
            if direction == .down {
                moveDescription(by: 180)
            } else if direction == .up {
                moveDescription(by: -180)
            }
        }
        .onExitCommand { dismiss() }
    }

    private func moveDescription(by distance: CGFloat) {
        descriptionOffset = min(maximumOffset, max(0, descriptionOffset + distance))
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            scrollPosition.scrollTo(y: descriptionOffset)
        }
    }

    private var descriptionText: String {
        guard let description = book.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
        else {
            return "No description is available from your sources."
        }
        return description
    }

    private var metadata: some View {
        HStack(alignment: .top, spacing: 32) {
            metadataItem(
                "Finished", value: book.finishedLabel(format: dateFormat),
                symbol: "checkmark.circle")
            if let rating = book.rating {
                metadataItem(
                    "Your rating",
                    value: "\(rating.formatted(.number.precision(.fractionLength(0...2)))) / 5",
                    symbol: "star")
            }
            if let pages = book.pages, pages > 0 {
                metadataItem("Length", value: "\(pages) pages", symbol: "text.book.closed")
            }
            if let format = book.formatLabel {
                metadataItem("Format", value: format, symbol: book.formatSymbol)
            }
        }
        .padding(.vertical, 10)
    }

    private func metadataItem(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
            }
            .appFont(size: 18).foregroundStyle(.secondary)
            Text(value).appFont(size: 23, weight: .medium).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}
