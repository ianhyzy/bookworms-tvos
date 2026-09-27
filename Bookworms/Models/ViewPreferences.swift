import Foundation
import Observation

enum BookwormsView: String, Codable, CaseIterable, Identifiable {
    case shelf = "My Shelf"
    case yearInReview = "Year in Review"
    case following = "Following"
    case comparison = "Compare Shelves"
    case shared = "Book Club"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .shelf: "books.vertical.fill"
        case .yearInReview: "calendar"
        case .following: "person.2.fill"
        case .comparison: "rectangle.split.2x1.fill"
        case .shared: "shared.with.you"
        }
    }

    /// Whether the view needs Hardcover social data.
    var isSocial: Bool { self == .following || self == .comparison || self == .shared }

    /// Whether ambient mode can show this view. Year in Review is interactive only.
    var supportsAmbient: Bool { self != .yearInReview }
}

enum SharedReadsSort: String, Codable, CaseIterable, Identifiable {
    case agreement = "Rating agreement"
    case disagreement = "Rating disagreement"
    var id: String { rawValue }
}

enum SpoilerPolicy: String, Codable, CaseIterable, Identifiable {
    case alwaysHide = "Always hide"
    case showIfRead = "Show for read books"
    var id: String { rawValue }
}

/// The most books a shelf, comparison row, or shared-reads view shows, and the default count.
///
/// Every book in a view keeps its decoded cover in memory, but an Apple TV 4K with 3 GB peaked
/// under 80 MB with 30-book views, so memory does not constrain this. Users on older devices can
/// lower the count in Settings.
enum BookLimit {
    static let maximum = 40
}

struct ViewPreferences: Codable, Equatable {
    var enabled: [BookwormsView] = BookwormsView.allCases
    var readerID: Int?
    var comparisonOrder = ComparisonOrder.rating
    var sharedReadsSort = SharedReadsSort.agreement
    var comparisonCount = BookLimit.maximum
    /// Views ambient mode cycles through, chosen on the Ambient page. `nil` includes every view.
    /// Independent of `enabled`, which only controls the sidebar.
    var ambientViews: [BookwormsView]?
    var ambientMinutes = 10
    var sessionMinutes = 0
    /// Views the user has been offered in the sidebar. Preferences saved before a view existed
    /// decode as `nil` here, so `validate()` adds later views to the sidebar once.
    var offeredViews: [BookwormsView]? = BookwormsView.allCases
    /// Views in the sidebar, in display order. My Shelf is always included.
    var orderedViews: [BookwormsView] {
        BookwormsView.allCases.filter { $0 == .shelf || enabled.contains($0) }
    }
    /// Views ambient mode may show, in display order. My Shelf is always included.
    var ambientOrderedViews: [BookwormsView] {
        BookwormsView.allCases.filter {
            $0.supportsAmbient && ($0 == .shelf || ambientViews?.contains($0) ?? true)
        }
    }
    /// Views that need prepared data and artwork: those in the sidebar or in ambient mode.
    var activeViews: [BookwormsView] {
        BookwormsView.allCases.filter {
            orderedViews.contains($0) || ambientOrderedViews.contains($0)
        }
    }
    mutating func validate() {
        let offered = offeredViews ?? [.shelf, .following, .comparison, .shared]
        enabled += BookwormsView.allCases.filter { !offered.contains($0) }
        offeredViews = BookwormsView.allCases
        enabled = orderedViews
        comparisonCount = min(BookLimit.maximum, max(1, comparisonCount))
        if ![5, 10, 15].contains(ambientMinutes) { ambientMinutes = 10 }
        if ![0, 30, 60, 120].contains(sessionMinutes) { sessionMinutes = 0 }
    }
}

@MainActor @Observable
final class BookwormsCoordinator {
    var current = BookwormsView.shelf
    var preferences: ViewPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) {
                defaults.set(data, forKey: "viewPreferences")
            }
            if !preferences.orderedViews.contains(current) { current = .shelf }
        }
    }
    var feedSelection: Int?
    var sharedSelection: Int?
    /// The year Year in Review shows for this session. `nil` shows the most recent year.
    var reviewYear: Int?
    var reviewSelection: Int?
    var comparisonRow = 0
    /// The focused book's position within its visible Compare Shelves page, shared by both rows.
    var comparisonColumn = 0
    let upper = ComparisonRowState()
    let lower = ComparisonRowState()
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var saved =
            defaults.data(forKey: "viewPreferences")
            .flatMap { try? JSONDecoder().decode(ViewPreferences.self, from: $0) }
            ?? ViewPreferences()
        saved.validate()
        preferences = saved
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--start-view=")
        }) {
            let requested = String(argument.dropFirst("--start-view=".count))
            if let target = BookwormsView.allCases.first(where: {
                $0.rawValue.caseInsensitiveCompare(requested) == .orderedSame
                    || "\($0)".caseInsensitiveCompare(requested) == .orderedSame
            }) {
                current = target
            }
        }
    }
    func switchView(_ direction: Int) {
        let views = preferences.orderedViews
        let index = views.firstIndex(of: current) ?? 0
        current = views[(index + direction + views.count) % views.count]
    }
    func setInAmbient(_ view: BookwormsView, _ included: Bool) {
        guard view != .shelf else { return }
        var views = preferences.ambientOrderedViews
        views.removeAll { $0 == view }
        if included { views.append(view) }
        preferences.ambientViews = views
    }
    func setEnabled(_ view: BookwormsView, _ enabled: Bool) {
        guard view != .shelf else { return }
        preferences.enabled.removeAll { $0 == view }
        if enabled { preferences.enabled.append(view) }
    }
}

@MainActor @Observable
final class ComparisonRowState {
    var selectedID: Int?
}
