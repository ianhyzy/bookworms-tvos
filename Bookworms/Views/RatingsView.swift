import Charts
import SwiftUI

struct RatingsView: View {
    let book: Book

    private var buckets: [RatingBucket] {
        let counts = Dictionary(
            (book.ratingDistribution ?? []).map { ($0.rating, $0.count) }, uniquingKeysWith: +)
        return (1...10)
            .map { RatingBucket(rating: Double($0) / 2, count: counts[Double($0) / 2] ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let average = book.communityRating {
                    Image(systemName: "star.fill").appFont(size: 22).foregroundStyle(.yellow)
                    Text(average.formatted(.number.precision(.fractionLength(2))))
                        .appFont(size: 34, weight: .semibold).monospacedDigit()
                    Text("\((book.ratingsCount ?? 0).formatted()) ratings")
                        .appFont(size: 20).foregroundStyle(.secondary)
                } else {
                    Text("Community ratings unavailable").appFont(size: 20)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if let distribution = book.ratingDistribution, !distribution.isEmpty {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Rating", bucket.rating), y: .value("Readers", bucket.count),
                        width: .fixed(22)
                    )
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .cornerRadius(3)
                    .accessibilityLabel("\(bucket.rating.formatted()) stars")
                    .accessibilityValue("\(bucket.count) ratings")
                }
                .chartXScale(domain: 0.25...5.25)
                .chartXAxis {
                    AxisMarks(values: [1, 2, 3, 4, 5]) { _ in
                        // Hierarchical chart styles can inherit the series palette.
                        AxisValueLabel().foregroundStyle(Color.primary)
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 95)
                .accessibilityLabel("Community rating distribution")
                .accessibilityIdentifier("rating-distribution")
            }
        }
    }
}
