import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class SocialLibraryModel {
    private(set) var snapshot: SocialSnapshot? {
        didSet {
            if snapshot?.activities != oldValue?.activities {
                activities = FeedActivity.latestPerBook(snapshot?.activities ?? [])
            }
            // Sync dates and feed updates do not change comparison ordering or intersections.
            if snapshot?.mine != oldValue?.mine || snapshot?.readerBooks != oldValue?.readerBooks
                || snapshot?.following != oldValue?.following
            {
                rebuildPresentation()
            }
        }
    }
    private(set) var presentation = SocialPresentation()
    private(set) var presentationRevision = 0
    @ObservationIgnored private var presentationPreferences = ViewPreferences()

    func prepare(_ preferences: ViewPreferences) {
        guard
            preferences.readerID != presentationPreferences.readerID
                || preferences.comparisonOrder != presentationPreferences.comparisonOrder
                || preferences.comparisonCount != presentationPreferences.comparisonCount
                || preferences.sharedReadsSort != presentationPreferences.sharedReadsSort
        else { return }
        presentationPreferences = preferences
        rebuildPresentation()
    }

    private func rebuildPresentation() {
        presentation = SocialPresentation(snapshot: snapshot, preferences: presentationPreferences)
        presentationRevision += 1
    }
    private(set) var status = "Connect Hardcover in Sources to use social views."
    private(set) var isLoading = false
    private(set) var revision = 0
    @ObservationIgnored private let client: any SocialLibraryFetching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheRoot: URL
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var requestRevision = 0
    @ObservationIgnored private var requestedReader: Int?
    @ObservationIgnored private var requestedViews: Set<BookwormsView> = []
    @ObservationIgnored private var lastManualLoad: Date?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var isSample = false

    init(
        client: any SocialLibraryFetching = HardcoverSocialClient(),
        defaults: UserDefaults = .standard,
        cacheRoot: URL = URL.cachesDirectory.appending(path: "Bookworms/social"),
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.defaults = defaults
        self.cacheRoot = cacheRoot
        self.now = now
    }
    var following: [ReaderProfile] { snapshot?.following ?? [] }
    private(set) var activities: [FeedActivity] = []
    var mine: [ReaderBook] { snapshot?.mine ?? [] }
    func reader(_ id: Int?) -> ReaderProfile? { following.first { $0.id == id } }
    func books(for id: Int?) -> [ReaderBook] {
        guard let id, reader(id) != nil else { return [] }
        return snapshot?.readerBooks[id] ?? []
    }
    func shared(with id: Int?, limit: Int) -> [SharedRead] {
        SharedRead.ranked(mine: mine, theirs: books(for: id), limit: limit)
    }

    func load(
        token: String?, readerID: Int?, manual: Bool = false,
        enabledViews: Set<BookwormsView> = Set(BookwormsView.allCases)
    ) async {
        guard !isSample else { return }
        guard let token, (try? HardcoverToken(token)) != nil else {
            activeTask?.cancel()
            requestRevision += 1
            identity = nil
            snapshot = nil
            isLoading = false
            status = "Connect Hardcover in Sources to use social views."
            return
        }
        let socialViews = enabledViews.filter(\.isSocial)
        guard !socialViews.isEmpty else {
            activeTask?.cancel()
            requestRevision += 1
            activeTask = nil
            isLoading = false
            status = "Social views are disabled."
            return
        }
        let fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }
            .joined()
        if identity == fingerprint, requestedReader == readerID,
            requestedViews == socialViews, let activeTask
        {
            await activeTask.value
            return
        }
        if manual, identity == fingerprint,
            let lastManualLoad, now().timeIntervalSince(lastManualLoad) < 10
        {
            return
        }
        if manual { lastManualLoad = now() }
        activeTask?.cancel()
        requestRevision += 1
        let request = requestRevision
        requestedReader = readerID
        requestedViews = socialViews
        let needsComparison = socialViews.contains(.comparison) || socialViews.contains(.shared)
        if identity != fingerprint {
            snapshot = nil
            identity = fingerprint
            // A credential fingerprint is local-only and never enters requests or iCloud.
            if let ownerID = defaults.object(forKey: "socialOwner.\(fingerprint)") as? Int,
                let data = try? Data(contentsOf: cacheRoot.appending(path: "\(ownerID).json"))
            {
                snapshot = try? JSONDecoder().decode(SocialSnapshot.self, from: data)
            }
        }
        if PerformanceDiagnostics.isolates("background") { return }
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if request == requestRevision {
                    isLoading = false
                    activeTask = nil
                }
            }
            do {
                var current: SocialSnapshot
                if let snapshot {
                    current = snapshot
                } else {
                    let owner = try await client.owner(token: token)
                    try Task.checkCancellation()
                    guard request == requestRevision else { return }
                    defaults.set(owner.id, forKey: "socialOwner.\(fingerprint)")
                    current = SocialSnapshot(owner: owner)
                    if let data = try? Data(
                        contentsOf: cacheRoot.appending(path: "\(owner.id).json")),
                        let cached = try? JSONDecoder().decode(SocialSnapshot.self, from: data)
                    {
                        current = cached
                    }
                }
                if begin(
                    owner: current.owner.id, dataset: "following", manual: manual,
                    lastSuccess: current.dates["following"])
                {
                    current.following = try await client.following(
                        owner: current.owner.id, token: token)
                    let allowed = Set(current.following.map(\.id))
                    current.readerBooks = current.readerBooks.filter { allowed.contains($0.key) }
                    current.activities.removeAll { !allowed.contains($0.reader.id) }
                    current.dates["following"] = now()
                    try install(current, request: request)
                }
                if socialViews.contains(.following),
                    begin(
                        owner: current.owner.id, dataset: "feed", manual: manual,
                        lastSuccess: current.dates["feed"])
                {
                    current.activities = try await client.feed(
                        users: current.following.map(\.id), token: token)
                    current.dates["feed"] = now()
                    try install(current, request: request)
                }
                if needsComparison,
                    begin(
                        owner: current.owner.id, dataset: "mine", manual: manual,
                        lastSuccess: current.dates["mine"])
                {
                    current.mine = try await client.library(user: current.owner.id, token: token)
                    current.dates["mine"] = now()
                    try install(current, request: request)
                }
                if needsComparison, let readerID,
                    current.following.contains(where: { $0.id == readerID }),
                    begin(
                        owner: current.owner.id, dataset: "reader.\(readerID)", manual: manual,
                        lastSuccess: current.dates["reader.\(readerID)"])
                {
                    current.readerBooks[readerID] = try await client.library(
                        user: readerID, token: token)
                    current.dates["reader.\(readerID)"] = now()
                    try install(current, request: request)
                }
                try install(current, request: request)
                status =
                    "Social data is cached. Automatic checks run once a day; Sync now checks sooner."
            } catch {
                guard !Task.isCancelled, request == requestRevision else { return }
                switch error {
                case HardcoverError.insufficientScope, HardcoverError.forbidden,
                    HardcoverError.invalidToken:
                    if let owner = snapshot?.owner.id {
                        try? FileManager.default.removeItem(
                            at: cacheRoot.appending(path: "\(owner).json"))
                    }
                    snapshot = nil
                    revision += 1
                    status =
                        "Hardcover social access was denied. Reconnect with read:social and read:users as well as the library read permissions, then select Sync social data."
                default:
                    status =
                        "Social data could not refresh. Cached data is retained. "
                        + UserFacingError.message(error)
                }
            }
        }
        activeTask = task
        await task.value
    }

    private func begin(owner: Int, dataset: String, manual: Bool, lastSuccess: Date?) -> Bool {
        let key = "socialAttempt.\(owner).\(dataset)"
        let successful =
            lastSuccess ?? defaults.object(forKey: "socialSuccess.\(owner).\(dataset)") as? Date
        guard
            RefreshPolicy.isDue(
                lastAttempt: defaults.object(forKey: key) as? Date,
                lastSuccess: successful, hasSnapshot: lastSuccess != nil, manual: manual, now: now()
            )
        else { return false }
        defaults.set(now(), forKey: key)
        return true
    }

    private func install(_ value: SocialSnapshot, request: Int) throws {
        let measurement = PerformanceDiagnostics.begin("SocialInstall")
        defer { measurement.end() }
        try Task.checkCancellation()
        guard request == requestRevision else { throw CancellationError() }
        snapshot = value
        for (dataset, date) in value.dates {
            defaults.set(date, forKey: "socialSuccess.\(value.owner.id).\(dataset)")
        }
        revision += 1
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(value)
            .write(to: cacheRoot.appending(path: "\(value.owner.id).json"), options: .atomic)
    }

    func leaveSample() {
        if isSample {
            isSample = false
            snapshot = nil
            identity = nil
        }
    }

    func useSample(books: [Book] = SampleLibrary.books) {
        guard !isSample else { return }
        activeTask?.cancel()
        requestRevision += 1
        isSample = true
        isLoading = false
        let me = ReaderProfile(id: -1, username: "sample", name: "You", avatarURL: nil)
        let other = ReaderProfile(
            id: -2, username: "sample-reader", name: "Sample reader", avatarURL: nil)
        let mine =
            books
            .map { book in
                ReaderBook(
                    book: book, rating: book.rating ?? 4,
                    review: book.id == 4
                        ? nil
                        : (book.id == 3
                            ? String(
                                repeating: "A memorable read with a distinctive voice. ", count: 40)
                            : "A memorable read with a distinctive voice."),
                    hasSpoilers: book.id == 2,
                    finished: book.finished)
            }
        let theirs = mine.map {
            ReaderBook(
                book: $0.book, rating: 4.5,
                review: $0.review == nil ? nil : "I enjoyed the characters and the setting.",
                hasSpoilers: false, finished: $0.finished)
        }
        snapshot = SocialSnapshot(
            owner: me, following: [other],
            activities: mine.map {
                FeedActivity(
                    id: $0.id, reader: other,
                    createdAt: ISO8601DateFormatter()
                        .string(from: Date(timeIntervalSince1970: 1_700_000_000 - Double($0.id))),
                    summary: "Finished reading",
                    book: $0.book, likes: 2, rating: $0.rating, review: $0.review,
                    hasSpoilers: $0.hasSpoilers)
            }, mine: mine, readerBooks: [other.id: theirs])
        status = "Sample social data. No accounts or AI requests are used."
        revision += 1
    }
}
