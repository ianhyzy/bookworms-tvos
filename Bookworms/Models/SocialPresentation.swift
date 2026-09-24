import Foundation

/// Prepared rows shared by interactive views and ambient playback.
struct SocialPresentation {
    var reader: ReaderProfile?
    var mine: [ReaderBook] = []
    var theirs: [ReaderBook] = []
    var shared: [SharedRead] = []
    var myRatings: [Int: Double] = [:]
    var theirRatings: [Int: Double] = [:]

    init() {}

    init(snapshot: SocialSnapshot?, preferences: ViewPreferences) {
        guard let snapshot else { return }
        reader = snapshot.following.first { $0.id == preferences.readerID }
        guard let reader else { return }
        let other = snapshot.readerBooks[reader.id] ?? []
        // Index complete libraries so a rating remains available outside either visible top 20.
        myRatings = snapshot.mine.reduce(into: [:]) { $0[$1.id] = $1.rating }
        theirRatings = other.reduce(into: [:]) { $0[$1.id] = $1.rating }
        mine = preferences.comparisonOrder.select(snapshot.mine, limit: preferences.comparisonCount)
        theirs = preferences.comparisonOrder.select(other, limit: preferences.comparisonCount)
        shared = SharedRead.ranked(
            mine: snapshot.mine, theirs: other, sort: preferences.sharedReadsSort,
            limit: preferences.comparisonCount)
    }
}
