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
            // Sync dates do not change comparison ordering, intersections, or picks; feed ratings
            // feed Friends' Picks.
            if snapshot?.mine != oldValue?.mine || snapshot?.readerBooks != oldValue?.readerBooks
                || snapshot?.following != oldValue?.following
                || snapshot?.activities != oldValue?.activities
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

    /// Hardcover books the reader's library marks read, which Friends' Picks leaves out.
    func setReadBooks(_ ids: Set<Int>) {
        guard ids != readBookIDs else { return }
        readBookIDs = ids
        rebuildPresentation()
    }

    @ObservationIgnored private var readBookIDs: Set<Int> = []

    private func rebuildPresentation() {
        presentation = SocialPresentation(
            snapshot: snapshot, preferences: presentationPreferences, readBookIDs: readBookIDs)
        presentationRevision += 1
    }
    private(set) var status = "Connect Hardcover to use social views."
    private(set) var isLoading = false
    /// Whether the latest load failed before Feed's activity settled, for a reason other than a
    /// denied login or permission, such as the network, so asking the reader to connect would be
    /// wrong. A failure in a library fetched after the feed leaves it false.
    private(set) var loadFailed = false
    /// What Feed shows without activity: a loading note while social data loads, a note that
    /// followed readers have no activity once their activity has loaded and the latest load
    /// succeeded, a note that activity couldn't load after a failed load or while an account's
    /// data lacks activity, and otherwise how to connect.
    var emptyFeedMessage: String {
        if isLoading { return "Loading activity from people you follow…" }
        if !loadFailed, snapshot?.dates["feed"] != nil {
            return "People you follow have no recent activity."
        }
        if loadFailed || snapshot != nil {
            return "Activity from people you follow couldn't load. Try again later."
        }
        return
            "Connect Hardcover with social read permissions in Settings. Activity from people you follow appears here."
    }
    /// What Compare Shelves and Book Club show without a reader to compare with: a pointer to the
    /// reader picker when the reader follows someone, and otherwise a loading note while social
    /// data loads, how to follow readers once an empty Following list has loaded, a note that the
    /// list couldn't load after a failed load or while an account's data lacks it, and otherwise
    /// how to connect.
    var noReaderMessage: String {
        if !following.isEmpty { return "Choose a reader above." }
        if isLoading { return "Loading the people you follow…" }
        if snapshot?.dates["following"] != nil {
            return "Follow readers on Hardcover to compare your books with theirs."
        }
        if loadFailed || snapshot != nil {
            return "The people you follow couldn't load. Try again later."
        }
        return
            "Connect Hardcover with social read permissions in Settings to compare your books with people you follow."
    }
    private(set) var revision = 0
    @ObservationIgnored private let client: any SocialLibraryFetching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: SocialSnapshotCache
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
        cache = SocialSnapshotCache(root: cacheRoot)
        self.now = now
    }
    var following: [ReaderProfile] { snapshot?.following ?? [] }
    private(set) var activities: [FeedActivity] = []
    func reader(_ id: Int?) -> ReaderProfile? { following.first { $0.id == id } }
    func books(for id: Int?) -> [ReaderBook] {
        guard let id, reader(id) != nil else { return [] }
        return snapshot?.readerBooks[id] ?? []
    }

    /// Loads the social datasets the enabled views need, each on its own daily gate.
    ///
    /// `account` is the Hardcover account `token` belongs to, when known; the cache is keyed on
    /// it so a renewed token keeps cached data. When Hardcover rejects `token`, `renewToken`
    /// replaces it once and the load continues with the replacement.
    func load(
        token: String?, account: String? = nil, readerID: Int?, manual: Bool = false,
        enabledViews: Set<BookwormsView> = Set(BookwormsView.allCases),
        renewToken: (@MainActor (String) async throws -> String)? = nil
    ) async {
        guard !isSample else { return }
        guard let token, (try? HardcoverToken(token)) != nil else {
            activeTask?.cancel()
            requestRevision += 1
            identity = nil
            snapshot = nil
            isLoading = false
            loadFailed = false
            status = "Connect Hardcover to use social views."
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
        let fingerprint = SHA256.hash(data: Data((account ?? token).utf8)).hex
        // A manual load replaces a matching load in flight, so its bypass of the daily gates
        // isn't lost.
        if !manual, identity == fingerprint, requestedReader == readerID,
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
        let needsPicks = socialViews.contains(.friendsPicks)
        if identity != fingerprint {
            snapshot = nil
            identity = fingerprint
        }
        isLoading = true
        loadFailed = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if request == requestRevision {
                    isLoading = false
                    activeTask = nil
                }
            }
            var token = token
            var renewToken = renewToken
            var renewalFailed = false
            var feedSettled = false
            // Sends one request. The first rejected token is renewed, and every later request in
            // this load uses the replacement.
            @MainActor func authorized<T>(_ send: (String) async throws -> T) async throws -> T {
                do {
                    return try await send(token)
                } catch HardcoverError.invalidToken {
                    guard let renew = renewToken else { throw HardcoverError.invalidToken }
                    renewToken = nil
                    do {
                        token = try await renew(token)
                    } catch {
                        renewalFailed = true
                        throw error
                    }
                    return try await send(token)
                }
            }
            // Hardcover denying one followed reader's library leaves that library empty, as on
            // iPhone and Mac. A denial of the owner's, Following, or Feed requests still reaches
            // the handler below, which clears the snapshot.
            @MainActor func readerLibrary(_ id: Int) async throws -> [ReaderBook] {
                do {
                    return try await authorized { try await client.library(user: id, token: $0) }
                } catch HardcoverError.forbidden {
                    return []
                }
            }
            do {
                // The account's cached copy shows before any request. An account or credential
                // fingerprint is local-only and never enters requests or iCloud.
                if snapshot == nil,
                    let ownerID = defaults.object(forKey: "socialOwner.\(fingerprint)") as? Int,
                    let cached = await cache.load(owner: ownerID)
                {
                    guard isCurrent(request) else { return }
                    snapshot = cached
                }
                if PerformanceDiagnostics.isolates("background") { return }
                var current: SocialSnapshot
                if let snapshot {
                    current = snapshot
                } else {
                    // A credential this device hasn't used can belong to an account that
                    // already has a cache file.
                    let owner = try await authorized { try await client.owner(token: $0) }
                    let cached = await cache.load(owner: owner.id)
                    guard isCurrent(request) else { return }
                    defaults.set(owner.id, forKey: "socialOwner.\(fingerprint)")
                    current = cached ?? SocialSnapshot(owner: owner)
                }
                // Fetches `dataset` when it's due, then shows and saves it. A failed fetch
                // starts the dataset's five-minute backoff. A fetch that ends because a newer
                // load replaced this one doesn't, so the newer load can fetch the dataset.
                @MainActor func refresh(
                    _ dataset: String, _ fetch: () async throws -> Void
                ) async throws {
                    let key = "\(current.owner.id).\(dataset)"
                    let lastSuccess = current.dates[dataset]
                    guard
                        RefreshPolicy.isDue(
                            lastAttempt: defaults.object(forKey: "socialAttempt.\(key)") as? Date,
                            lastSuccess: lastSuccess
                                ?? defaults.object(forKey: "socialSuccess.\(key)") as? Date,
                            hasSnapshot: lastSuccess != nil, manual: manual, now: now())
                    else { return }
                    do {
                        try await fetch()
                    } catch {
                        if isCurrent(request) {
                            defaults.set(now(), forKey: "socialAttempt.\(key)")
                        }
                        throw error
                    }
                    current.dates[dataset] = now()
                    try await install(current, request: request)
                }
                try await refresh("following") {
                    current.following = try await authorized {
                        try await client.following(owner: current.owner.id, token: $0)
                    }
                    let allowed = Set(current.following.map(\.id))
                    current.readerBooks = current.readerBooks.filter { allowed.contains($0.key) }
                    current.activities.removeAll { !allowed.contains($0.reader.id) }
                }
                if socialViews.contains(.following) || needsPicks {
                    do {
                        try await refresh("feed") {
                            current.activities = try await authorized {
                                try await client.feed(users: current.following.map(\.id), token: $0)
                            }
                        }
                    } catch {
                        // Friends' Picks can rank from libraries alone, so a transient feed
                        // failure only stops the sync when the Feed view shows it. Credential and
                        // permission failures always reach the handler below. So does a failed
                        // renewal, since later requests would send the rejected token and report
                        // the login as denied.
                        switch error {
                        case HardcoverError.insufficientScope, HardcoverError.forbidden,
                            HardcoverError.invalidToken:
                            throw error
                        default:
                            if socialViews.contains(.following) || Task.isCancelled
                                || renewalFailed
                            {
                                throw error
                            }
                        }
                    }
                }
                feedSettled = true
                if needsComparison || needsPicks {
                    try await refresh("mine") {
                        current.mine = try await authorized {
                            try await client.library(user: current.owner.id, token: $0)
                        }
                    }
                }
                // Each library refreshes on its own daily gate, which Compare Shelves and
                // Friends' Picks share. The selected reader's library comes first.
                var readers: [Int] = []
                if needsComparison, let readerID,
                    current.following.contains(where: { $0.id == readerID })
                {
                    readers.append(readerID)
                }
                if needsPicks {
                    for id in FriendPick.readersToSync(current, limit: Self.pickReaderLimit)
                    where !readers.contains(id) {
                        readers.append(id)
                    }
                }
                for id in readers {
                    try await refresh("reader.\(id)") {
                        current.readerBooks[id] = try await readerLibrary(id)
                    }
                }
                // Each due dataset installed as it arrived. `snapshot` is still nil only when this
                // load fetched the owner and nothing was due, so it installs the cached copy; any
                // other load with nothing due leaves the cache file and `revision` alone.
                if snapshot == nil { try await install(current, request: request) }
                guard isCurrent(request) else { return }
                status =
                    "Social data is cached. Automatic checks run once a day."
            } catch {
                guard isCurrent(request) else { return }
                switch error {
                case HardcoverError.insufficientScope, HardcoverError.forbidden,
                    HardcoverError.invalidToken:
                    // A first load can be denied before it installs the cache file it read.
                    let owner =
                        snapshot?.owner.id
                        ?? defaults.object(forKey: "socialOwner.\(fingerprint)") as? Int
                    snapshot = nil
                    revision += 1
                    // Only Settings → Sources shows this, so it names that page's buttons. A
                    // missing permission leaves the login working, so the button there is
                    // Disconnect Hardcover. A rejected login gets the library's message rather
                    // than one blaming social access.
                    status =
                        switch error {
                        case HardcoverError.insufficientScope:
                            "Bookworms needs permission to see the readers you follow. Disconnect Hardcover, then connect it again to allow it."
                        case HardcoverError.invalidToken:
                            HardcoverError.invalidToken.localizedDescription
                        default:
                            "Hardcover denied access to social data."
                        }
                    if let owner { await cache.remove(owner: owner) }
                default:
                    loadFailed = !feedSettled
                    status =
                        "Social data could not refresh. Cached data is retained. "
                        + UserFacingError.hardcoverMessage(error)
                }
            }
        }
        activeTask = task
        await task.value
    }

    /// Whether the load numbered `request` is the newest one and hasn't been cancelled.
    private func isCurrent(_ request: Int) -> Bool {
        !Task.isCancelled && request == requestRevision
    }

    /// Shows `value` and saves it to the cache. Throws `CancellationError` without showing it
    /// when a newer load replaced the load numbered `request`.
    private func install(_ value: SocialSnapshot, request: Int) async throws {
        guard isCurrent(request) else { throw CancellationError() }
        let measurement = PerformanceDiagnostics.begin("SocialInstall")
        snapshot = value
        loadFailed = false
        for (dataset, date) in value.dates {
            defaults.set(date, forKey: "socialSuccess.\(value.owner.id).\(dataset)")
        }
        revision += 1
        measurement.end()
        try await cache.save(value)
    }

    /// The most followed readers whose libraries Friends' Picks downloads.
    static let pickReaderLimit = 10

    #if DEBUG && targetEnvironment(simulator)
        /// Shows the newest cached social snapshot without a credential or network requests, for
        /// previewing downloaded data in the simulator. Like the sample, it blocks later loads.
        func useCachedSnapshotForPreview() async {
            guard let cached = await cache.newest() else { return }
            activeTask?.cancel()
            isSample = true
            snapshot = cached
            status = "Cached social data for simulator preview."
            revision += 1
        }
    #endif

    func leaveSample() {
        if isSample {
            isSample = false
            snapshot = nil
            identity = nil
        }
    }

    /// The sample's first followed reader, whom UI tests start with.
    static let sampleReaderID = -2

    func useSample(books: [Book] = SampleLibrary.books) {
        guard !isSample else { return }
        activeTask?.cancel()
        requestRevision += 1
        isSample = true
        isLoading = false
        let me = ReaderProfile(id: -1, username: "sample", name: "You", avatarURL: nil)
        let other = ReaderProfile(
            id: Self.sampleReaderID, username: "sample-reader", name: "Sample reader",
            avatarURL: nil)
        let second = ReaderProfile(
            id: -3, username: "sample-reader-2", name: "Theo Marsh", avatarURL: nil)
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
        // Two books only the reader has read, rated below the shared ones so Compare Shelves
        // keeps its order, give Friends' Picks content.
        let theirs =
            mine.map {
                ReaderBook(
                    book: $0.book, rating: 4.5,
                    review: $0.review == nil ? nil : "I enjoyed the characters and the setting.",
                    hasSpoilers: false, finished: $0.finished)
            }
            + SampleLibrary.friendPicks.map {
                ReaderBook(
                    book: $0, rating: 4, review: nil, hasSpoilers: false, finished: $0.finished)
            }
        // The second reader shares every other book, rated differently, so the reader picker
        // offers a real choice. Their own books stay below Friends' Picks' rating threshold.
        let ratings = [3, 5, 3.5, 4.5]
        let secondBooks =
            stride(from: 0, to: mine.count, by: 2)
            .map { index in
                ReaderBook(
                    book: mine[index].book, rating: ratings[index / 2 % ratings.count],
                    review: nil, hasSpoilers: false, finished: mine[index].finished)
            }
            + SampleLibrary.secondReaderBooks.map {
                ReaderBook(
                    book: $0, rating: 3.5, review: nil, hasSpoilers: false, finished: $0.finished)
            }
        snapshot = SocialSnapshot(
            owner: me, following: [other, second],
            activities: mine.map {
                FeedActivity(
                    id: $0.id, reader: other,
                    createdAt: ISO8601DateFormatter()
                        .string(from: Date(timeIntervalSince1970: 1_700_000_000 - Double($0.id))),
                    summary: "Finished reading",
                    book: $0.book, likes: 2, rating: $0.rating, review: $0.review,
                    hasSpoilers: $0.hasSpoilers)
            }, mine: mine, readerBooks: [other.id: theirs, second.id: secondBooks])
        status = "Sample social data. No accounts or AI requests are used."
        revision += 1
    }
}

/// Reads and writes each account's social snapshot file away from the UI actor, one at a time.
private actor SocialSnapshotCache {
    private let root: URL
    init(root: URL) { self.root = root }

    private func url(owner: Int) -> URL { root.appending(path: "\(owner).json") }

    private func snapshot(at url: URL) -> SocialSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SocialSnapshot.self, from: data)
    }

    /// Returns the saved snapshot of the account `owner`, or `nil` without a readable one.
    func load(owner: Int) -> SocialSnapshot? { snapshot(at: url(owner: owner)) }

    #if DEBUG && targetEnvironment(simulator)
        /// Returns the most recently saved snapshot of any account.
        func newest() -> SocialSnapshot? {
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return files.filter { $0.pathExtension == "json" }
                .max {
                    let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    return (lhs?.contentModificationDate ?? .distantPast)
                        < (rhs?.contentModificationDate ?? .distantPast)
                }
                .flatMap(snapshot(at:))
        }
    #endif

    func save(_ snapshot: SocialSnapshot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot)
            .write(to: url(owner: snapshot.owner.id), options: .atomic)
    }

    func remove(owner: Int) {
        try? FileManager.default.removeItem(at: url(owner: owner))
    }
}
