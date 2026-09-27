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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if let average = book.communityRating {
                        Text("\(average.formatted(.number.precision(.fractionLength(2)))) ★")
                            .appFont(size: 23, weight: .medium).monospacedDigit()
                        Text("\((book.ratingsCount ?? 0).formatted()) ratings")
                            .appFont(size: 18).foregroundStyle(.secondary)
                    } else {
                        Text("Unavailable").appFont(size: 23, weight: .medium)
                    }
                }
                .accessibilityElement(children: .combine)
                if opensReviews {
                    Spacer(minLength: 12)
                    HStack(spacing: 7) {
                        Text("Reviews")
                        Image(systemName: "chevron.right")
                    }
                    .appFont(size: 18).foregroundStyle(.secondary)
                }
            }
            if let distribution = book.ratingDistribution, !distribution.isEmpty {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Rating", bucket.rating), y: .value("Readers", bucket.count),
                        width: .fixed(20)
                    )
                    .foregroundStyle(
                        Color.primary.opacity(bucket.rating == bucket.rating.rounded() ? 0.6 : 0.35)
                    )
                    .cornerRadius(3)
                    .accessibilityLabel("\(bucket.rating.formatted()) stars")
                    .accessibilityValue("\(bucket.count) ratings")
                }
                .chartXScale(domain: 0.25...5.25)
                .chartXAxis {
                    AxisMarks(values: [1, 2, 3, 4, 5]) { _ in
                        // Hierarchical chart styles can inherit the series palette.
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 64)
                .padding(.top, 6)
                .accessibilityLabel("Community rating distribution")
                .accessibilityIdentifier("rating-distribution")
            }
        }
    }
}
