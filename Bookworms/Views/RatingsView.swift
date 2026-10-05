import Charts
import SwiftUI

struct RatingsView: View {
    let book: Book
    /// Shows a **Reviews** cue when the chart is the label of a button that opens reviews.
    var opensReviews = false

    private var buckets: [RatingBucket] {
        let counts = Dictionary(
            (book.ratingDistribution ?? []).map { ($0.rating, $0.count) }, uniquingKeysWith: +)
        return (1...10)
            .map { RatingBucket(rating: Double($0) / 2, count: counts[Double($0) / 2] ?? 0) }
    }

    /// The half-star bucket that holds your rating. Only its bar is solid white.
    private var yourBucket: Double? { book.rating.map { ($0 * 2).rounded() / 2 } }

    /// Your rating, then the community average, as rows of a grid that aligns their stars.
    private var ratings: [(label: String, stars: String)] {
        [
            book.rating.map {
                ("You", "★\($0.formatted(.number.precision(.fractionLength(0...1))))")
            },
            book.communityRating.map {
                ("Community", "★\($0.formatted(.number.precision(.fractionLength(1))))")
            },
        ]
        .compactMap(\.self)
    }

    var body: some View {
        // The chart sits beside the text, not under it, which keeps the block short and leaves the
        // height to the description. Stacking the two ratings keeps the text narrow for the chart.
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                if ratings.isEmpty {
                    Text("Unavailable").appFont(size: 23, weight: .medium)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(ratings, id: \.label) { rating in
                            GridRow {
                                Text(rating.label)
                                Text(rating.stars).monospacedDigit()
                            }
                        }
                    }
                    .appFont(size: 23, weight: .medium)
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 16) {
                    if book.communityRating != nil {
                        Text("\((book.ratingsCount ?? 0).formatted()) ratings").fixedSize()
                    }
                    if opensReviews {
                        // Fixed so the cue keeps its full width beside the chart.
                        HStack(spacing: 7) {
                            Text("Reviews").fixedSize()
                            Image(systemName: "chevron.right")
                        }
                    }
                }
                .appFont(size: 18).foregroundStyle(.detailCaption).padding(.top, 4)
            }
            .lineLimit(1).fixedSize()
            if let distribution = book.ratingDistribution, !distribution.isEmpty {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Rating", bucket.rating), y: .value("Readers", bucket.count),
                        width: .fixed(16)
                    )
                    .foregroundStyle(Color.primary.opacity(bucket.rating == yourBucket ? 1 : 0.45))
                    .cornerRadius(3)
                    .accessibilityLabel("\(bucket.rating.formatted()) stars")
                    .accessibilityValue(
                        "\(bucket.count) ratings\(bucket.rating == yourBucket ? ", your rating" : "")"
                    )
                }
                .chartXScale(domain: 0.25...5.25)
                .chartXAxis {
                    AxisMarks(values: [1, 2, 3, 4, 5]) { _ in
                        // Hierarchical chart styles can inherit the series palette.
                        AxisValueLabel(anchor: .top).foregroundStyle(Color.detailCaption)
                    }
                }
                .chartYAxis(.hidden)
                // Takes the width the genres beside the block leave, within these bounds.
                .frame(minWidth: 220, maxWidth: 340).frame(height: 88)
                .accessibilityLabel("Community rating distribution")
                .accessibilityIdentifier("rating-distribution")
            }
        }
    }
}
