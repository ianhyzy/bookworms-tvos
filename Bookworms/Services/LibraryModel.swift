import CoreText
import Foundation
import Observation
import UIKit

/// The work performed after Hardcover authorizes this Apple TV.
enum HardcoverConnectionPhase: Equatable {
    case validatingAccount
    case downloadingLibrary
    case savingLibrary

    var title: String {
        switch self {
        case .validatingAccount: "Connecting to Hardcover"
        case .downloadingLibrary: "Downloading your library"
        case .savingLibrary: "Saving your library"
        }
    }

    var detail: String {
        switch self {
        case .validatingAccount: "Checking your account…"
        case .downloadingLibrary: "Gathering your books and reading history…"
        case .savingLibrary: "Keeping your books available on this Apple TV…"
        }
    }
}

@MainActor @Observable
final class LibraryModel {
    private(set) var books: [Book] = [] {
        didSet { if books != oldValue { presentationRevision += 1 } }
    }
    @ObservationIgnored private var allBooks: [Book] = [] {
        didSet {
            let years = YearInReview.all(from: allBooks)
            if years != readingYears { readingYears = years }
            let offersOwned =
                BookPresentation.offersCWA && allBooks.contains { $0.isOwned == true }
            if offersOwned != offersOwnedBooks { offersOwnedBooks = offersOwned }
            refreshSeriesSources()
            refreshOnThisDay()
        }
    }
    /// Each book that shares a series design, by ID, mapped to the book whose design it draws
    /// with (`SeriesDesigns.sources`); a source maps to itself. Prepared with the library, never
    /// on focus or remote input.
    private(set) var seriesSources: [Int: Book] = [:]
    /// The series look each book draws as its design, by ID, in place of its companion design
    /// (`spineDesigns`). Prepared with `seriesSources`.
    private(set) var lookDesigns: [Int: SpineDesignV1] = [:]
    /// Who made the designs the library's books draw, for **Settings → Spines**. Prepared with
    /// `seriesSources`.
    private(set) var designMakers = SpineDesignMakers()

    /// What Book Wall draws `books` with, by book ID.
    ///
    /// A book whose look group (`SeriesDesigns.lookKey(of:link:)`, with `links`) has a series
    /// look in `looks` draws the look as its design (`looks` in the result), unless its link
    /// keeps its own look. Every other book draws its companion design from `designs`, if any,
    /// and `sources` gives the books that draw another book's design instead:
    /// `SeriesDesigns.sources` over the books of groups without a look, judging each book's
    /// design by the face Book Wall draws it in (`BookWallLocalSpine.typography(for:design:)`).
    /// That face is its companion design's, with a blocked face already replaced by its upright
    /// stand-in, or its genre face, so a design saved in Impact or Pacifico leads its series, as
    /// on the iPhone. Whether a look's or source's face can letter each book is checked later,
    /// once, where a spine is prepared.
    nonisolated static func seriesDrawing(
        of books: [Book], designs: [Int: SpineDesignV1] = [:], links: [Int: SeriesLinkV1] = [:],
        looks: [SeriesLookKey: SeriesLookV1] = [:]
    ) -> (sources: [Int: Book], looks: [Int: SpineDesignV1]) {
        var drawn: [Int: SpineDesignV1] = [:]
        var ranked: [Int: Book] = [:]
        for book in books {
            let link = links[book.id]
            if link?.ownLook == true { continue }
            if let key = SeriesDesigns.lookKey(of: book, link: link), let look = looks[key] {
                drawn[book.id] = look.design(for: book)
            } else if ranked[book.id] == nil {
                ranked[book.id] = book
            }
        }
        let fonts = ranked.mapValues { book in
            let typography = BookWallLocalSpine.typography(for: book, design: designs[book.id])
            return typography.fontName ?? typography.typeface
        }
        let sources =
            SeriesDesigns.sources(
                books: Array(ranked.values), fonts: fonts, links: links
            )
            .compactMapValues { ranked[$0] }
        return (sources, drawn)
    }

    private func refreshSeriesSources() {
        let drawing =
            BookPresentation.showsCompanionSpines
            ? Self.seriesDrawing(
                of: allBooks, designs: spineDesigns, links: seriesLinks, looks: seriesLooks)
            : Self.seriesDrawing(of: allBooks, links: seriesLinks)
        if drawing.sources != seriesSources { seriesSources = drawing.sources }
        if drawing.looks != lookDesigns { lookDesigns = drawing.looks }
        let makers = SpineDesignMakers(
            books: allBooks, designs: BookPresentation.showsCompanionSpines ? spineDesigns : [:],
            sources: drawing.sources, looks: drawing.looks)
        if makers != designMakers { designMakers = makers }
    }

    /// Series from the active Hardcover snapshot, by series ID. Prepared with the library.
    private(set) var seriesByID: [Int: SeriesInfo] = [:]

    /// Covers of every series book, for the browsing artwork tier, which skips covers the library
    /// tier already has. Owned books use their library cover. Series of books on My Shelf come
    /// first. Prepared with the library.
    private(set) var browsingCoverURLs: [URL] = []

    /// `book`'s series for its details: the series its label names, which its link chooses, else
    /// its shortest series, and every series it belongs to, with their books when synced. `nil`
    /// for a book without a named series.
    func series(for book: Book) -> ShownSeries? {
        guard let shown = SeriesDesigns.shownSeries(of: book, link: seriesLinks[book.id]) else {
            return nil
        }
        var seen = Set<Int>()
        var all = (book.seriesMemberships ?? []).filter { seen.insert($0.seriesID).inserted }
        if !seen.contains(shown.seriesID) { all.insert(shown, at: 0) }
        return ShownSeries(
            membership: shown, all: all,
            infos: Dictionary(
                uniqueKeysWithValues: all.compactMap { series in
                    seriesByID[series.seriesID].map { (series.seriesID, $0) }
                }))
    }

    /// Whether picking a series in `book`'s details can save it: always in the sample library,
    /// which keeps picks in memory, and otherwise for a book of the active Hardcover account
    /// with iCloud storage on.
    func canPickSeries(for book: Book) -> Bool {
        isSample
            || (iCloudEnabled && hardcoverEnabled && activeHardcoverAccountID != nil
                && book.isHardcoverBook)
    }

    /// Makes `seriesID` the series `book`'s details name and its spine's look follows, saved as
    /// the book's `SeriesLinkV1` as the iPhone and Mac save it: picking the book's shortest
    /// series deletes the link, and the link keeps its own-look choice. The pick shows at once.
    /// Saves run in the order of the picks; a failed save restores the earlier choice unless a
    /// later pick replaced it. The sample library keeps picks in memory.
    func pickSeries(_ seriesID: Int, for book: Book) {
        guard canPickSeries(for: book) else { return }
        let accountID = isSample ? "" : activeHardcoverAccountID ?? ""
        let old = seriesLinks[book.id]
        let chosen = SeriesLinkV1(
            accountID: accountID, bookID: book.id,
            linkedSeriesID: seriesID == SeriesDesigns.styleSeries(of: book, link: nil)?.id
                ? nil : seriesID,
            ownLook: old?.ownLook == true, chosenAt: dependencies.now())
        let link = chosen.linkedSeriesID == nil && !chosen.ownLook ? nil : chosen
        guard link?.linkedSeriesID != old?.linkedSeriesID || old?.standsAlone == true else {
            return
        }
        setPickedLink(link, for: book.id)
        guard !isSample else { return }
        let previous = seriesLinkSave
        seriesLinkSave = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await dependencies.saveSeriesLink(link, accountID, book.id)
            } catch {
                // Turning iCloud storage off or changing accounts clears the links; keep them clear.
                guard iCloudEnabled, activeHardcoverAccountID == accountID,
                    seriesLinks[book.id] == link
                else { return }
                setPickedLink(old, for: book.id)
            }
        }
    }

    private func setPickedLink(_ link: SeriesLinkV1?, for bookID: Int) {
        seriesLinks[bookID] = link
        pickedLinks[bookID] = (link, dependencies.now())
        refreshSeriesSources()
    }

    /// Books finished on today's date in earlier years, for ambient mode. Prepared when the
    /// library changes and when the app becomes active, so a new day is picked up.
    private(set) var onThisDay: [Book] = []
    /// The year `onThisDay` was chosen in, for "N years ago" labels.
    private(set) var onThisDayYear = Calendar.current.component(.year, from: .now)
    /// Year in Review statistics for every year with a finished book, most recent first.
    /// Prepared when the library changes, so the view only reads them.
    private(set) var readingYears: [YearInReview] = []
    /// Whether **Owned Books** can show anything: CWA, the only source that marks books owned,
    /// is offered, and the library has an owned book. Prepared with the library.
    private(set) var offersOwnedBooks = false
    /// The collections **Settings → Shelf** offers.
    var shelfCollections: [ShelfCollection] {
        ShelfCollection.allCases.filter { $0 != .owned || offersOwnedBooks }
    }
    /// The shelf choices in effect. A saved **Owned Books** shows the default collection while
    /// Owned Books isn't offered, and returns when it is.
    var activeShelfPreferences: ShelfPreferences {
        var preferences = shelfPreferences
        if !shelfCollections.contains(preferences.collection) {
            preferences.collection = ShelfPreferences().collection
        }
        return preferences
    }
    private(set) var hasLoadedLibrarySnapshot = false
    /// The connected Hardcover account's permanent profile link, for the profile code in ambient
    /// mode. `nil` without a connected, enabled account.
    var hardcoverProfileURL: URL? {
        guard hardcoverEnabled, hardcoverConnected, !isSample,
            let id = activeHardcoverAccountID.flatMap(Int.init), id > 0
        else { return nil }
        return HardcoverLink.user(id)
    }
    /// Limits My Shelf to one author or genre until cleared. Not saved.
    var shelfFilter: ShelfFilter? {
        didSet { if shelfFilter != oldValue { updateShelf() } }
    }
    @ObservationIgnored private let dependencies: LibraryDependencies
    @ObservationIgnored private let persistence: LibraryPersistence
    @ObservationIgnored private let hardcoverSession: HardcoverSession
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored private var sourceSaveRevision = 0
    @ObservationIgnored private var styleSaveRevision = 0
    @ObservationIgnored private var topShelfRevision = 0
    @ObservationIgnored private var topShelfTask: Task<Void, Never>?
    @ObservationIgnored private var cloudRevision = 0
    @ObservationIgnored private var activeHardcoverAccountID: String?
    @ObservationIgnored private var spineDesignTask: Task<Void, Never>?
    @ObservationIgnored private var spineDesignTaskIdentity:
        (
            accountID: String, syncedAt: Date, requestID: UUID
        )?
    private var schedule: SourceSyncSchedule { SourceSyncSchedule(defaults: dependencies.defaults) }
    var bookCount: Int {
        didSet {
            let bounded = Self.clampedBookCount(bookCount)
            if bookCount != bounded { bookCount = bounded }
            dependencies.defaults.set(bounded, forKey: "bookCount")
            updateShelf()
        }
    }
    static func clampedBookCount(_ value: Int) -> Int { min(BookLimit.maximum, max(1, value)) }
    var aiConfiguration: AIConfiguration {
        didSet {
            if aiConfiguration.credentialAccount != oldValue.credentialAccount {
                credentials.reload(aiConfiguration.credentialAccount)
            }
        }
    }
    let credentials: CredentialAvailability
    private(set) var isGenerating = false
    private(set) var generationStatus: String?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var automaticGenerationTask: Task<Void, Never>?
    @ObservationIgnored private var automaticGenerationPaused = false
    @ObservationIgnored private var aiRecords: [Int: AIStyleRecord] = [:]
    @ObservationIgnored private var fontTask: Task<Void, Never>?
    private var progressURL: URL {
        dependencies.diagnosticsDirectory.appending(path: "ai-progress.json")
    }
    private(set) var fontRevision = 0
    /// Validated companion designs for the active Hardcover snapshot, keyed by book ID.
    private(set) var spineDesigns: [Int: SpineDesignV1] = [:] {
        didSet { if spineDesigns != oldValue { refreshSeriesSources() } }
    }
    /// Validated companion cover choices for the active Hardcover snapshot, keyed by book ID.
    /// `rebuildLibrary` applies them to displayed books.
    @ObservationIgnored private var coverChoices: [Int: CoverChoiceV1] = [:]
    /// Validated companion series links for the active Hardcover snapshot, keyed by book ID.
    /// Look groups read them when the library is rebuilt (`refreshSeriesSources`), and details
    /// observe them through `series(for:)`, so a pick shows at once.
    private var seriesLinks: [Int: SeriesLinkV1] = [:]
    /// This session's series picks (`pickSeries(_:for:)`), each with its time, so a CloudKit read
    /// that started before a pick's save doesn't undo it. A read keeps a pick unless it returns a
    /// link chosen later.
    @ObservationIgnored private var pickedLinks: [Int: (link: SeriesLinkV1?, at: Date)] = [:]
    /// The latest series-link save, which the next one waits for.
    @ObservationIgnored private var seriesLinkSave: Task<Void, Never>?
    /// Validated series looks of the active Hardcover snapshot's look groups.
    @ObservationIgnored private var seriesLooks: [SeriesLookKey: SeriesLookV1] = [:]
    private(set) var presentationRevision = 0
    private(set) var artworkRevision = 0
    private(set) var savedAIKeyAvailable = false
    private(set) var coverRatios: [Int: Double] = [:]
    @ObservationIgnored private var ambientActive = false

    func recordCoverRatio(_ ratio: Double, for id: Int) {
        guard ratio.isFinite, ratio > 0, abs((coverRatios[id] ?? 0) - ratio) > 0.01 else { return }
        coverRatios[id] = ratio
        presentationRevision += 1
    }

    /// The style a saved spine draws `book` with: its series source's, when the source has a
    /// usable saved style (`SeriesDesigns`), otherwise its own.
    func savedSpineStyle(for book: Book) -> SpineStyle? {
        if let source = seriesSources[book.id], source.id != book.id,
            let style = ownSavedSpineStyle(for: source),
            SeriesDesigns.isUsableSource(style.fontName)
        {
            return style
        }
        return ownSavedSpineStyle(for: book)
    }

    private func ownSavedSpineStyle(for book: Book) -> SpineStyle? {
        let font = aiRecords[book.id].flatMap { UIFont(name: $0.style.fontName, size: 23) }
        guard let record = aiRecords[book.id],
            BookPresentation.usesSpine(
                hasSavedKey: savedAIKeyAvailable, hasDesign: true, fontAvailable: font != nil)
        else { return nil }
        var style = styles[book.id] ?? record.style
        // A registered face with the italic trait or a slant never renders, whatever its name.
        if let font,
            !SpineFontPolicy.isUpright(CTFontCreateWithName(font.fontName as CFString, 23, nil))
        {
            style.fontName = SpineFontPolicy.uprightFallback
        }
        return style
    }

    /// Reads the active Hardcover credential only at an explicit synchronization boundary,
    /// renewing it first when it's due (`HardcoverSession`). A request that Hardcover rejects
    /// renews with `renewHardcoverToken(rejected:)`.
    func hardcoverTokenForSync() async -> String? {
        guard hardcoverEnabled, hardcoverConnected, !isSample else { return nil }
        #if DEBUG && targetEnvironment(simulator)
            // Matches `saveHardcoverCredential`: an unsigned simulator may keep the authorized
            // bootstrap token only in this process, so social sync uses it too.
            if dependencies.allowLaunchOverrides,
                let token = ProcessInfo.processInfo.environment["HARDCOVER_BOOTSTRAP_TOKEN"]
            {
                return hardcoverSession.storedAccessToken() ?? token
            }
        #endif
        let token = await hardcoverSession.accessToken()
        // A disconnect during the renewal wins.
        return hardcoverConnected ? token : nil
    }

    /// Replaces an access token that Hardcover rejected during social sync or a reviews request,
    /// sharing any renewal in progress. Shows **Reconnect Hardcover** and rethrows the rejection
    /// when the login can't be renewed.
    func renewHardcoverToken(rejected token: String) async throws -> String {
        do {
            if let renewed = try await hardcoverSession.renew(rejected: token), renewed != token {
                return renewed
            }
        } catch HardcoverError.invalidToken {}
        if hardcoverConnected { hardcoverSessionExpired = true }
        throw HardcoverError.invalidToken
    }

    /// The Hardcover account of the active snapshot. Social sync keys its cache on it, so a
    /// renewed token keeps the cached social data.
    var hardcoverAccountID: String? { activeHardcoverAccountID }

    func reloadCredentialAvailability() {
        credentials.reload("cwa-password")
        credentials.reload(aiConfiguration.credentialAccount)
        reloadSavedAIAvailability()
    }

    func reloadSavedAIAvailability() {
        let configuration = dependencies.defaults.data(forKey: "aiConfiguration")
            .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
        if let configuration { credentials.reload(configuration.credentialAccount) }
        let available =
            configuration.map {
                (try? $0.validatedURL()) != nil && credentials.contains($0.credentialAccount)
            } ?? false
        if savedAIKeyAvailable != available {
            savedAIKeyAvailable = available
            presentationRevision += 1
        }
    }

    func removeAIKey() {
        guard let data = dependencies.defaults.data(forKey: "aiConfiguration"),
            let saved = try? JSONDecoder().decode(AIConfiguration.self, from: data)
        else { return }
        cancelGeneration()
        dependencies.removeCredential(saved.credentialAccount)
        reloadSavedAIAvailability()
        generationStatus = "API key removed. Saved designs are retained; books use covers."
    }

    func setAmbientActive(_ active: Bool) {
        ambientActive = active
        if active {
            automaticGenerationTask?.cancel()
            if isGenerating { cancelGeneration() }
        }
    }

    func restoreFonts(for books: [Book]) {
        restoreVisibleFonts(additionalBooks: books)
    }
    private(set) var styles: [Int: SpineStyle] = [:]
    private(set) var isLoading = false
    private(set) var hardcoverConnectionPhase: HardcoverConnectionPhase?
    private(set) var hasCompletedWelcome: Bool

    /// Offer setup only after startup has checked local snapshots and the saved account.
    var shouldOfferWelcome: Bool {
        hasLoadedLibrarySnapshot && !hasCompletedWelcome && !hardcoverConnected && !hasCWAPassword
            && !isSample
            && sourceSnapshots.isEmpty && allBooks.isEmpty
    }

    func completeWelcome() {
        hasCompletedWelcome = true
        dependencies.defaults.set(true, forKey: "hasCompletedWelcome")
        if cloudSyncSuppressedForWelcome {
            cloudSyncSuppressedForWelcome = false
            queueCloudSync()
        }
    }

    /// Removes the local Hardcover login and library before startup for a fresh sign-in check.
    /// Other provider accounts, artwork, saved designs, and display preferences are retained.
    func resetHardcoverSetup() async throws {
        guard !hasStarted else { throw SetupResetError.alreadyStarted }
        hardcoverSession.remove()
        guard dependencies.readCredential(HardcoverSession.accessAccount) == nil,
            dependencies.readCredential(HardcoverSession.refreshAccount) == nil
        else {
            throw SetupResetError.credentialRemovalFailed
        }
        sourceSaveRevision &+= 1
        sourceSnapshots = try await persistence.resetHardcoverSnapshot(
            legacyURL: snapshotURL, revision: sourceSaveRevision)
        let defaults = dependencies.defaults
        for key in [
            "activeHardcoverAccountID", "hasCompletedWelcome", "syncAttempt.hardcover",
            "syncSuccess.hardcover",
        ] {
            defaults.removeObject(forKey: key)
        }
        activeHardcoverAccountID = nil
        hasCompletedWelcome = false
        hardcoverConnected = false
        hardcoverSessionExpired = false
        sourceErrors[LibrarySource.hardcover.rawValue] = nil
        // Remote snapshots must not restore the account while its first-run flow is open.
        cloudSyncSuppressedForWelcome = true
        hardcoverEnabled = true
    }

    private enum SetupResetError: LocalizedError {
        case alreadyStarted
        case credentialRemovalFailed

        var errorDescription: String? {
            switch self {
            case .alreadyStarted: "Restart Bookworms before resetting Hardcover setup."
            case .credentialRemovalFailed: "The saved Hardcover login could not be removed."
            }
        }
    }

    private(set) var hardcoverConnected = false
    /// Whether Hardcover rejected the saved login during the latest sync. The credential stays
    /// saved; Settings offers a new link code instead of showing the account as connected.
    private(set) var hardcoverSessionExpired = false
    private(set) var connectionRevision = 0
    var isConnected: Bool {
        !isSample && ((hardcoverEnabled && hardcoverConnected) || (cwaEnabled && hasCWAPassword))
    }
    var hardcoverEnabled: Bool {
        didSet {
            dependencies.defaults.set(hardcoverEnabled, forKey: "hardcoverEnabled")
            sourceConfigurationChanged()
        }
    }
    var cwaEnabled: Bool {
        didSet {
            dependencies.defaults.set(cwaEnabled, forKey: "cwaEnabled")
            sourceConfigurationChanged()
        }
    }
    var cwaConfiguration: CWAConfiguration {
        didSet {
            guard cwaConfiguration != oldValue else { return }
            sourceConfigurationChanged()
        }
    }
    var hasCWAPassword: Bool { credentials.contains("cwa-password") }
    var shelfPreferences: ShelfPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(shelfPreferences) {
                dependencies.defaults.set(data, forKey: "shelfPreferences")
            }
            updateShelf()
        }
    }
    var iCloudEnabled: Bool {
        didSet {
            dependencies.defaults.set(iCloudEnabled, forKey: "iCloudEnabled")
            invalidateCloudSync()
            if iCloudEnabled {
                queueCloudSync()
            } else {
                // Companion designs, covers, and series looks apply only with iCloud storage
                // on. The on-disk caches stay, so turning iCloud back on restores them.
                spineDesigns = [:]
                seriesLinks = [:]
                pickedLinks = [:]
                seriesLooks = [:]
                refreshSeriesSources()
                if !coverChoices.isEmpty {
                    coverChoices = [:]
                    rebuildLibrary()
                }
                cloudStatus = "iCloud storage is off. Existing cloud data is retained."
            }
        }
    }
    private(set) var cloudStatus = "Waiting for iCloud…" { didSet { writeSyncDiagnostics() } }
    private(set) var sourceErrors: [String: String] {
        didSet { dependencies.defaults.set(sourceErrors, forKey: "sourceErrors") }
    }
    @ObservationIgnored private var sourceSnapshots: [SourceSnapshot] = []
    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    @ObservationIgnored private var cloudPending = false
    @ObservationIgnored private var cloudBacked = false
    private(set) var isSample = false
    private(set) var syncedAt: Date?
    var message: String?
    private(set) var hardcoverDeviceAuth: HardcoverDeviceAuth?
    private(set) var hardcoverDeviceAuthLoading = false
    var hardcoverDeviceAuthMessage: String?
    @ObservationIgnored private var hardcoverPollingTask: Task<Void, Never>?
    var requestedBookID: Int?
    func book(withID id: Int) -> Book? { allBooks.first { $0.id == id } }
    /// The review for `year`, or the most recent year's when `year` is `nil` or has no books.
    func yearInReview(_ year: Int?) -> YearInReview? {
        readingYears.first { $0.year == year } ?? readingYears.first
    }
    func isBookReadByUser(_ id: Int) -> Bool {
        guard hardcoverConnected || isSample else { return false }
        guard let book = allBooks.first(where: { $0.id == id }) else { return false }
        return book.isRead == true || book.finished != nil
    }
    private var snapshotURL: URL { dependencies.legacySnapshotURL }
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var cloudSyncSuppressedForWelcome = false
    @ObservationIgnored private var lastManualRefresh: Date?

    init(dependencies: LibraryDependencies = LibraryDependencies()) {
        self.dependencies = dependencies
        hardcoverSession = HardcoverSession(dependencies: dependencies)
        persistence = LibraryPersistence(
            sourceStore: dependencies.sourceStore,
            styleCacheURL: dependencies.styleStore.cacheURL,
            writeTopShelf: dependencies.writeTopShelf)
        let defaults = dependencies.defaults
        hasCompletedWelcome = defaults.bool(forKey: "hasCompletedWelcome")
        credentials = CredentialAvailability(read: dependencies.readCredential)
        bookCount = Self.clampedBookCount(
            defaults.object(forKey: "bookCount") as? Int ?? BookLimit.maximum)
        aiConfiguration =
            defaults.data(forKey: "aiConfiguration")
            .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
            ?? AIConfiguration()
        hardcoverEnabled = defaults.object(forKey: "hardcoverEnabled") as? Bool ?? true
        cwaEnabled = defaults.bool(forKey: "cwaEnabled")
        cwaConfiguration =
            defaults.data(forKey: "cwaConfiguration")
            .flatMap { try? JSONDecoder().decode(CWAConfiguration.self, from: $0) }
            ?? CWAConfiguration()
        shelfPreferences =
            defaults.data(forKey: "shelfPreferences")
            .flatMap { try? JSONDecoder().decode(ShelfPreferences.self, from: $0) }
            ?? ShelfPreferences()
        // Opt-in: the published privacy policy describes iCloud storage as off by default.
        iCloudEnabled = defaults.object(forKey: "iCloudEnabled") as? Bool ?? false
        activeHardcoverAccountID = defaults.string(forKey: "activeHardcoverAccountID")
        sourceErrors = defaults.dictionary(forKey: "sourceErrors") as? [String: String] ?? [:]
    }

    private func sourceConfigurationChanged() {
        sourceRevision += 1
        invalidateCloudSync()
        rebuildLibrary()
        if hasStarted {
            if !hardcoverEnabled { queueSpineCachePrune() }
            queueCloudSync()
        }
    }

    private func invalidateCloudSync() {
        cloudRevision += 1
        cloudTask?.cancel()
        cloudTask = nil
        cloudPending = false
        spineDesignTask?.cancel()
        spineDesignTask = nil
        spineDesignTaskIdentity = nil
    }

    func start() async {
        guard !hasStarted, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        if dependencies.allowLaunchOverrides,
            ProcessInfo.processInfo.arguments.contains("--reset-hardcover-setup")
        {
            do {
                try await resetHardcoverSetup()
            } catch {
                message = readable(error)
            }
        }
        hasStarted = true
        if dependencies.allowLaunchOverrides,
            ProcessInfo.processInfo.arguments.contains("--sample-library")
        {
            showSample()
            hasLoadedLibrarySnapshot = true
            return
        }
        aiRecords = dependencies.styleStore.load()
        reloadCredentialAvailability()
        #if DEBUG
            if dependencies.allowLaunchOverrides,
                let key = ProcessInfo.processInfo.environment["GEMINI_BOOTSTRAP_TOKEN"]
            {
                aiConfiguration = AIConfiguration()
                _ = saveAI(key: key)
                bookCount = BookLimit.maximum
            }
        #endif
        if let data = try? Data(contentsOf: snapshotURL),
            let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
        {
            allBooks = snapshot.books
            books = Array(allBooks.prefix(bookCount))
            syncedAt = snapshot.syncedAt
            restoreSavedStyles(books)
            publishTopShelf()
        }
        sourceSnapshots = dependencies.sourceStore.load()
        if sourceSnapshots.isEmpty, !allBooks.isEmpty, let syncedAt {
            sourceSnapshots = [
                SourceSnapshot(
                    source: .hardcover, accountID: "hardcover", books: allBooks, syncedAt: syncedAt)
            ]
            _ = try? await saveSources()
        }
        seedSchedule()
        if let savedToken = hardcoverSession.storedAccessToken() {
            hardcoverConnected = (try? HardcoverToken(savedToken)) != nil
            if !hardcoverConnected {
                message = HardcoverError.invalidToken.localizedDescription
            }
        }
        rebuildLibrary()
        hasLoadedLibrarySnapshot = true
        if !hardcoverEnabled { queueSpineCachePrune() }
        if cloudSyncSuppressedForWelcome, !shouldOfferWelcome {
            // A retained provider can skip setup, so no welcome completion will release this gate.
            cloudSyncSuppressedForWelcome = false
        }
        if iCloudEnabled {
            if cloudSyncSuppressedForWelcome {
                cloudStatus = "iCloud storage waits until setup finishes."
            } else {
                queueSpineDesignRefresh()
                // A due refresh below waits for this read, so it starts at once.
                queueCloudSync(delay: .zero)
            }
        } else {
            cloudStatus = "iCloud storage is off."
        }
        #if DEBUG
            if dependencies.allowLaunchOverrides,
                let token = ProcessInfo.processInfo.environment["HARDCOVER_BOOTSTRAP_TOKEN"]
            {
                _ = await connect(token)
            }
            if dependencies.allowLaunchOverrides,
                let server = ProcessInfo.processInfo.environment["CWA_BOOTSTRAP_SERVER"],
                let username = ProcessInfo.processInfo.environment["CWA_BOOTSTRAP_USERNAME"],
                let password = ProcessInfo.processInfo.environment["CWA_BOOTSTRAP_PASSWORD"]
            {
                _ = await connectCWA(
                    CWAConfiguration(server: server, username: username), password: password)
            }
        #endif
        if isConnected { await refresh() }
        #if DEBUG
            if dependencies.allowLaunchOverrides,
                ProcessInfo.processInfo.arguments.contains("--regenerate-spines")
            {
                regenerateSpines()
            } else if dependencies.allowLaunchOverrides,
                ProcessInfo.processInfo.arguments.contains("--regenerate-missing-spines")
            {
                regenerateSpines(onlyMissing: true)
            }
        #endif
    }

    static func needsRefresh(syncedAt: Date?, now: Date = Date()) -> Bool {
        guard let syncedAt else { return true }
        return now.timeIntervalSince(syncedAt) >= 86400
    }

    private func restoreVisibleFonts(additionalBooks: [Book] = []) {
        fontTask?.cancel()
        guard BookPresentation.showsGeneratedSpines else { return }
        let ids = Set((books + additionalBooks).map(\.id))
        let records = ids.compactMap { aiRecords[$0] }
        fontTask = Task { [weak self] in
            for record in records {
                guard !Task.isCancelled else { return }
                guard
                    let font = try? await GoogleFontLibrary.shared.restore(
                        record.font, weight: record.weight)
                else { continue }
                guard !Task.isCancelled, let self else { return }
                // A completed download must not replace a newer generated choice.
                guard aiRecords[record.bookID]?.generatedAt == record.generatedAt else { continue }
                // A blocked family, such as Bangers, restores as its upright stand-in. Only the
                // in-memory record changes here; `GoogleFontLibrary.restore` maps the family on
                // every restore, so a stored record in the blocked family restores the same way.
                var updated = record
                updated.font = font
                updated.style.fontName = font.postScriptName
                aiRecords[record.bookID] = updated
                styles[record.bookID] = updated.style
                fontRevision += 1
            }
        }
    }

    func startHardcoverDeviceAuth() {
        hardcoverPollingTask?.cancel()
        hardcoverPollingTask = nil
        hardcoverDeviceAuth = nil
        hardcoverDeviceAuthLoading = true
        hardcoverDeviceAuthMessage = nil

        hardcoverPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let auth = try await dependencies.requestHardcoverDeviceAuth()
                guard !Task.isCancelled else { return }
                self.hardcoverDeviceAuth = auth
                self.hardcoverDeviceAuthLoading = false
                self.hardcoverDeviceAuthMessage = "Waiting for authorization…"

                var interval = Duration.seconds(auth.interval > 0 ? auth.interval : 5)
                while !Task.isCancelled {
                    try await dependencies.sleep(interval)
                    guard !Task.isCancelled else { break }

                    do {
                        let pollResult = try await dependencies.pollHardcoverDeviceToken(
                            auth.deviceCode)
                        guard !Task.isCancelled else { break }
                        switch pollResult {
                        case .pending:
                            continue
                        case .slowDown:
                            interval += .seconds(5)
                            continue
                        case .expired:
                            self.hardcoverDeviceAuthMessage =
                                "The code has expired. Requesting a new code…"
                            self.startHardcoverDeviceAuth()
                            return
                        case .accessDenied:
                            self.hardcoverDeviceAuthMessage = "Hardcover authorization was denied."
                            self.hardcoverDeviceAuth = nil
                            return
                        case .success(let tokens):
                            guard !self.isLoading else {
                                // Approval consumes the code; show a retry instead of a stopped waiter.
                                self.hardcoverDeviceAuth = nil
                                self.hardcoverDeviceAuthMessage =
                                    "A library sync is finishing. Request a new link code to connect."
                                return
                            }
                            self.hardcoverDeviceAuth = nil
                            self.hardcoverDeviceAuthMessage = nil
                            self.isLoading = true
                            defer { self.isLoading = false }
                            _ = await self.connectValidatedToken(
                                tokens, revision: self.sourceRevision)
                            return
                        }
                    } catch {
                        guard !Task.isCancelled else { break }
                        self.hardcoverDeviceAuthMessage = self.readable(error)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.hardcoverDeviceAuthLoading = false
                self.hardcoverDeviceAuthMessage = self.readable(error)
            }
        }
    }

    func cancelHardcoverDeviceAuth() {
        hardcoverPollingTask?.cancel()
        hardcoverPollingTask = nil
        hardcoverDeviceAuthLoading = false
        hardcoverDeviceAuth = nil
        hardcoverDeviceAuthMessage = nil
    }

    /// Connects with a token that has no refresh token, such as a personal access token.
    func connect(_ rawToken: String) async -> Bool {
        guard !isLoading else { return false }
        let token: String
        do { token = try HardcoverToken(rawToken).value } catch {
            message = readable(error)
            return false
        }
        isLoading = true
        let revision = sourceRevision
        defer { isLoading = false }
        return await connectValidatedToken(HardcoverTokens(accessToken: token), revision: revision)
    }

    private func connectValidatedToken(_ tokens: HardcoverTokens, revision: Int) async -> Bool {
        hardcoverConnectionPhase = .validatingAccount
        message = nil
        defer { hardcoverConnectionPhase = nil }
        let token = tokens.accessToken
        do {
            let accountID = try await dependencies.validateHardcover(token)
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            let hasSnapshot =
                activeHardcoverAccountID == accountID
                && sourceSnapshots.contains {
                    $0.source == .hardcover && $0.accountID == accountID
                }
            let accountChanged = activeHardcoverAccountID != accountID
            // Credential rotation must remain available between scheduled library syncs.
            if hasSnapshot
                && !schedule
                    .isDue(
                        .hardcover, now: dependencies.now(),
                        hasSnapshot: hasSnapshot)
            {
                try saveHardcoverCredential(tokens)
                hardcoverConnected = true
                setActiveHardcoverAccountID(accountID)
                hardcoverSessionExpired = false
                connectionRevision += 1
                isSample = false
                hardcoverEnabled = true
                sourceErrors[LibrarySource.hardcover.rawValue] = nil
                message =
                    "Hardcover token verified. Library sync keeps its daily schedule."
                return true
            }
            try schedule
                .begin(
                    .hardcover, now: dependencies.now(), manual: accountChanged,
                    hasSnapshot: hasSnapshot)
            hardcoverConnectionPhase = .downloadingLibrary
            // The validated account's own newest snapshot keeps its covers; the active account
            // may be another one.
            let previous =
                sourceSnapshots.filter {
                    $0.source == .hardcover && $0.accountID == accountID
                }
                .max { $0.syncedAt < $1.syncedAt }
            let result = try await dependencies.fetchHardcover(token, previous)
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            guard result.accountID == accountID else { throw HardcoverError.invalidToken }
            try saveHardcoverCredential(tokens)
            hardcoverConnected = true
            hardcoverSessionExpired = false
            connectionRevision += 1
            hardcoverEnabled = true
            hardcoverConnectionPhase = .savingLibrary
            await install(
                result.books, source: .hardcover, accountID: accountID, series: result.series)
            return true
        } catch {
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            message = readable(error)
            sourceErrors[LibrarySource.hardcover.rawValue] = readable(error)
            return false
        }
    }

    private func saveHardcoverCredential(_ tokens: HardcoverTokens) throws {
        #if DEBUG && targetEnvironment(simulator)
            if dependencies.allowLaunchOverrides,
                ProcessInfo.processInfo.environment["HARDCOVER_BOOTSTRAP_TOKEN"] != nil
            {
                // An unsigned simulator can lack Keychain access. The authorized bootstrap
                // token remains in this process only; the source snapshot is saved separately.
                try? hardcoverSession.save(tokens)
                return
            }
        #endif
        try hardcoverSession.save(tokens)
    }

    func refresh(manual: Bool = false) async {
        guard !PerformanceDiagnostics.isolates("background") else { return }
        guard !isLoading, !isGenerating else { return }
        if manual {
            guard lastManualRefresh.map({ dependencies.now().timeIntervalSince($0) >= 10 }) ?? true
            else {
                return
            }
            lastManualRefresh = dependencies.now()
        }
        isLoading = true
        defer {
            isLoading = false
            artworkRevision += 1
            queueAutomaticGeneration()
        }
        let revision = sourceRevision
        // Another device may have saved a fresh snapshot of the same account, so a due automatic
        // check reads iCloud first. Each source's gate is checked again afterward, and only the
        // sources still due are fetched. A source without a saved credential can't fetch, so it
        // doesn't hold `isLoading` through the read; the cached flags avoid a Keychain read.
        let pullsCloud =
            !manual && iCloudEnabled && !cloudSyncSuppressedForWelcome
            && ((hardcoverEnabled && hardcoverConnected && isDue(.hardcover))
                || (cwaEnabled && hasCWAPassword && isDue(.cwa)))
        if pullsCloud {
            if cloudTask == nil { queueCloudSync(delay: .zero) }
            await waitForCloudSync(atMost: .seconds(10))
            guard revision == sourceRevision, !Task.isCancelled else { return }
        }
        var failures: [String] = []
        if hardcoverEnabled, manual || isDue(.hardcover),
            let savedToken = hardcoverSession.storedAccessToken()
        {
            do {
                try schedule
                    .begin(
                        .hardcover, now: dependencies.now(), manual: manual,
                        hasSnapshot: hasActiveSnapshot(.hardcover))
                let token = await hardcoverSession.renewedIfExpiring(savedToken)
                let result: HardcoverLibrary
                do {
                    result = try await dependencies.fetchHardcover(token, activeHardcoverSnapshot())
                } catch HardcoverError.invalidToken {
                    // Hardcover can reject a token before its stated expiry. Renew it once.
                    guard let renewed = try await hardcoverSession.renew(rejected: token),
                        renewed != token
                    else { throw HardcoverError.invalidToken }
                    result = try await dependencies.fetchHardcover(
                        renewed, activeHardcoverSnapshot())
                }
                guard revision == sourceRevision, !Task.isCancelled else { return }
                await install(
                    result.books, source: .hardcover, accountID: result.accountID,
                    series: result.series)
            } catch {
                guard revision == sourceRevision, !Task.isCancelled else { return }
                sourceErrors[LibrarySource.hardcover.rawValue] = readable(error)
                failures.append("Hardcover: " + readable(error))
                switch error as? HardcoverError {
                case .invalidToken, .personalAccessTokenRequired: hardcoverSessionExpired = true
                default: break
                }
            }
        }
        if cwaEnabled, manual || isDue(.cwa),
            let password = dependencies.readCredential("cwa-password")
        {
            do {
                try schedule
                    .begin(
                        .cwa, now: dependencies.now(), manual: manual,
                        hasSnapshot: hasActiveSnapshot(.cwa))
                let configuration = cwaConfiguration
                let result = try await dependencies.fetchCWA(configuration, password)
                // A response belongs to the configuration captured before suspension.
                guard revision == sourceRevision, !Task.isCancelled else { return }
                await install(result, source: .cwa, accountID: configuration.identity)
            } catch {
                guard revision == sourceRevision, !Task.isCancelled else { return }
                sourceErrors[LibrarySource.cwa.rawValue] = readable(error)
                failures.append("CWA: " + readable(error))
            }
        }
        if !failures.isEmpty {
            message = failures.joined(separator: "\n")
        }
        // Each refresh reads iCloud once, which also retries an upload that failed. An installed
        // snapshot queues its own upload.
        if !pullsCloud { queueCloudSync() }
    }

    /// Whether `source` has a snapshot of its active account. Without one, the daily gate ignores
    /// the last success.
    private func hasActiveSnapshot(_ source: LibrarySource) -> Bool {
        switch source {
        case .hardcover:
            activeHardcoverSnapshot() != nil && activeHardcoverAccountID != nil
        case .cwa:
            sourceSnapshots.contains {
                $0.source == .cwa && $0.accountID == cwaConfiguration.identity
            }
        }
    }

    /// Whether an automatic check of `source` is due.
    private func isDue(_ source: LibrarySource) -> Bool {
        schedule.isDue(source, now: dependencies.now(), hasSnapshot: hasActiveSnapshot(source))
    }

    func connectCWA(_ configuration: CWAConfiguration, password: String) async -> Bool {
        guard !isLoading, !isGenerating else { return false }
        isLoading = true
        let revision = sourceRevision
        defer { isLoading = false }
        do {
            _ = try configuration.baseURL()
            guard !configuration.username.isEmpty, !configuration.username.contains(":"),
                !password.isEmpty
            else { throw SourceError.invalidCredentials }
            if sourceSnapshots.contains(where: { $0.source == .cwa }) {
                try schedule.begin(.cwa, now: dependencies.now())
            } else {
                // A failed first connection has no library to sync; allow corrected login details.
                schedule.seed(.cwa, date: dependencies.now())
            }
            let result = try await dependencies.fetchCWA(configuration, password)
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            try dependencies.saveCredential(password, "cwa-password")
            credentials.reload("cwa-password")
            cwaConfiguration = configuration
            dependencies.defaults.set(
                try JSONEncoder().encode(configuration), forKey: "cwaConfiguration")
            cwaEnabled = true
            await install(result, source: .cwa, accountID: configuration.identity)
            return true
        } catch {
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            message = readable(error)
            sourceErrors[LibrarySource.cwa.rawValue] = readable(error)
            writeSyncDiagnostics()
            return false
        }
    }

    /// The source's sync error or next scheduled check, or `nil` when a check is already due.
    func sourceStatus(_ source: LibrarySource, dateFormat: AppDateFormat = .monthName) -> String? {
        if let error = sourceErrors[source.rawValue] { return error }
        guard let last = schedule.lastAttempt(source) else { return "Not synced yet" }
        let successful =
            source == .hardcover
            ? activeHardcoverSnapshot()?.syncedAt
            : sourceSnapshots.first { $0.source == source }?.syncedAt
        let next = successful.map { $0.addingTimeInterval(86400) } ?? last.addingTimeInterval(300)
        return next > dependencies.now()
            ? "Next check: " + dateFormat.string(from: next) + " · "
                + next.formatted(date: .omitted, time: .shortened)
            : nil
    }

    func refreshOnThisDay() {
        var date = Date.now
        #if DEBUG && targetEnvironment(simulator)
            if let argument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix("--on-this-day-date=")
            }),
                let override = ISO8601DateFormatter()
                    .date(
                        from: argument.dropFirst("--on-this-day-date=".count) + "T12:00:00Z")
            {
                date = override
            }
        #endif
        let books = Book.finishedOnThisDay(allBooks, date: date, calendar: .current)
        let year = Calendar.current.component(.year, from: date)
        if year != onThisDayYear { onThisDayYear = year }
        if books != onThisDay { onThisDay = books }
    }

    func becameActive() async {
        refreshOnThisDay()
        guard hasStarted, !isSample else { return }
        await refresh()
        queueSpineDesignRefresh()
    }

    func showSample() {
        guard !isLoading else { return }
        cancelShelfWork()
        allBooks = SampleLibrary.books
        seriesByID = Dictionary(uniqueKeysWithValues: SampleLibrary.allSeries.map { ($0.id, $0) })
        #if DEBUG
            if dependencies.allowLaunchOverrides,
                ProcessInfo.processInfo.arguments.contains("--sample-pages")
            {
                allBooks = (0..<24)
                    .map { index in
                        let book = SampleLibrary.books[index % SampleLibrary.books.count]
                        return Book(
                            id: index + 1, title: book.title, author: book.author,
                            description: book.description, pages: book.pages,
                            finished: book.finished)
                    }
            }
        #endif
        books = Array(allBooks.prefix(bookCount))
        styles = [:]
        isSample = true
        completeWelcome()
        message = nil
        publishTopShelf()
    }

    func disconnect() {
        guard !isLoading else { return }
        cancelShelfWork()
        hardcoverSession.remove()
        hardcoverConnected = false
        hardcoverSessionExpired = false
        hardcoverEnabled = false
        isSample = false
        message = nil
        rebuildLibrary()
    }

    private func cancelShelfWork() {
        analysisTask?.cancel()
        fontTask?.cancel()
        generationTask?.cancel()
        automaticGenerationTask?.cancel()
        cancelHardcoverDeviceAuth()
    }

    /// The book's saved style, or its series source's when that source has a usable one
    /// (`SeriesDesigns`).
    func style(for book: Book) -> SpineStyle {
        if let source = seriesSources[book.id], source.id != book.id, let style = styles[source.id],
            SeriesDesigns.isUsableSource(style.fontName)
        {
            return style
        }
        return styles[book.id] ?? .fallback(for: book)
    }

    private func install(
        _ result: [Book], source: LibrarySource, accountID: String, series: [SeriesInfo]? = nil
    ) async {
        sourceErrors[source.rawValue] = nil
        if source == .hardcover {
            setActiveHardcoverAccountID(accountID)
            hardcoverSessionExpired = false
        }
        let previousSeries = sourceSnapshots.last {
            $0.source == source && $0.accountID == accountID
        }?
        .series
        let snapshot = SourceSnapshot(
            source: source, accountID: accountID, books: result, syncedAt: dependencies.now(),
            series: series ?? previousSeries)
        // A complete Hardcover sync replaces snapshots from older builds and accounts.
        sourceSnapshots.removeAll {
            $0.source == source && (source == .hardcover || $0.accountID == accountID)
        }
        sourceSnapshots.append(snapshot)
        schedule.seed(source, date: snapshot.syncedAt)
        isSample = false
        message = nil
        rebuildLibrary()
        queueCloudSync()
        let snapshots = sourceSnapshots
        sourceSaveRevision &+= 1
        let saveRevision = sourceSaveRevision
        do {
            try await persistence.saveSources(snapshots, revision: saveRevision)
        } catch {
            if saveRevision == sourceSaveRevision {
                message = "Books loaded, but the offline library could not be saved."
            }
        }
    }

    private func saveSources() async throws -> Int {
        sourceSaveRevision &+= 1
        let revision = sourceSaveRevision
        try await persistence.saveSources(sourceSnapshots, revision: revision)
        return revision
    }

    private func setActiveHardcoverAccountID(_ id: String) {
        guard !id.isEmpty else { return }
        activeHardcoverAccountID = id
        dependencies.defaults.set(id, forKey: "activeHardcoverAccountID")
    }

    /// Seeds each source's sync schedule from the snapshot its active account uses. Seeding from
    /// every snapshot let an older one of another account, such as the legacy `"hardcover"`
    /// placeholder that merges never remove, set the last success and make the source look due
    /// again five minutes after each attempt.
    private func seedSchedule() {
        if let snapshot = activeHardcoverSnapshot() {
            schedule.seed(.hardcover, date: snapshot.syncedAt)
        }
        if let snapshot = sourceSnapshots.first(where: {
            $0.source == .cwa && $0.accountID == cwaConfiguration.identity
        }) {
            schedule.seed(.cwa, date: snapshot.syncedAt)
        }
    }

    private func activeHardcoverSnapshot() -> SourceSnapshot? {
        let snapshots = sourceSnapshots.filter { $0.source == .hardcover }
        if let activeHardcoverAccountID {
            return snapshots.filter { $0.accountID == activeHardcoverAccountID }
                .max { $0.syncedAt < $1.syncedAt }
        }
        // Preserve existing cached covers before a legacy account can be verified. A newly
        // restored device without a credential uses its newest snapshot.
        return snapshots.filter { !hardcoverConnected || $0.accountID == "hardcover" }
            .max { $0.syncedAt < $1.syncedAt }
    }

    private func rebuildLibrary() {
        let measurement = PerformanceDiagnostics.begin("RebuildLibrary")
        defer { measurement.end() }
        guard !isSample else { return }
        let hardcover = hardcoverEnabled ? activeHardcoverSnapshot() : nil
        // Merge one active Hardcover snapshot so an older copy cannot supply stale covers.
        let enabled =
            [hardcover].compactMap(\.self)
            + sourceSnapshots.filter {
                $0.source == .cwa && cwaEnabled && $0.accountID == cwaConfiguration.identity
            }
        // Assigned once: each assignment prepares series designs again, with `seriesLinks`.
        var merged = LibraryMerge.books(from: enabled)
        if BookPresentation.showsCompanionCovers, let accountID = hardcover?.accountID,
            !coverChoices.isEmpty
        {
            for index in merged.indices where merged[index].isHardcoverBook {
                if let choice = coverChoices[merged[index].id], choice.accountID == accountID {
                    merged[index].chosenCoverURL = choice.coverURL
                }
            }
        }
        allBooks = merged
        seriesByID = Dictionary(
            (hardcover?.series ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        updateBrowsingCovers()
        syncedAt = enabled.map(\.syncedAt).max()
        styles = aiRecords.mapValues(\.style)
        updateShelf()
    }

    private func updateShelf() {
        let measurement = PerformanceDiagnostics.begin("UpdateShelf")
        defer { measurement.end() }
        let source = shelfFilter.map { filter in allBooks.filter(filter.matches) } ?? allBooks
        books =
            isSample
            ? Array(source.prefix(bookCount))
            : activeShelfPreferences.select(source, limit: bookCount)
        if !isSample {
            restoreSavedStyles(books)
            restoreVisibleFonts()
            queueAutomaticGeneration()
        }
        publishTopShelf()
        updateBrowsingCovers()
    }

    private func updateBrowsingCovers() {
        let owned = Dictionary(
            allBooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shelfSeries = books.compactMap {
            SeriesDesigns.styleSeries(of: $0, link: seriesLinks[$0.id])?.id
        }
        let order = shelfSeries + seriesByID.keys.sorted().filter { !shelfSeries.contains($0) }
        var seen = Set<URL>()
        let urls = order.compactMap { seriesByID[$0] }.flatMap(\.books)
            .compactMap { entry in
                owned[entry.id].map(\.preferredCoverURL) ?? entry.coverURL
            }
            .filter { seen.insert($0).inserted }
        if urls != browsingCoverURLs { browsingCoverURLs = urls }
    }

    private func writeSyncDiagnostics() {
        #if DEBUG
            let report: [String: Any] = [
                "cloudStatus": cloudStatus, "cloudBacked": cloudBacked,
                "iCloudEnabled": iCloudEnabled,
                "sources": sourceSnapshots.map {
                    ["source": $0.source.rawValue, "books": $0.books.count] as [String: Any]
                },
                "designs": aiRecords.count, "visibleBooks": books.count,
                "sourceErrors": sourceErrors,
                "updatedAt": dependencies.now().timeIntervalSince1970,
            ]
            let url = dependencies.diagnosticsDirectory.appending(path: "sync-status.json")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
                .write(to: url, options: .atomic)
        #endif
    }

    func cloudAccountChanged() {
        cloudBacked = false
        iCloudEnabled = false
        if !hardcoverConnected {
            activeHardcoverAccountID = nil
            dependencies.defaults.removeObject(forKey: "activeHardcoverAccountID")
            rebuildLibrary()
        }
        cloudStatus =
            "Your iCloud account changed. Turn iCloud Storage on to sync this library with the current account."
    }

    /// Queues a cloud sync, which uploads local snapshots and merges the archive's newer ones.
    /// `delay` batches the changes that follow one another; a sync already queued keeps its own.
    func queueCloudSync(delay: Duration = .seconds(2)) {
        guard !PerformanceDiagnostics.isolates("background") else { return }
        guard hasStarted, iCloudEnabled, !isSample, !cloudSyncSuppressedForWelcome else { return }
        cloudPending = true
        guard cloudTask == nil else { return }
        let revision = cloudRevision
        cloudTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == cloudRevision { cloudTask = nil } }
            if delay > .zero {
                do { try await dependencies.sleep(delay) } catch { return }
            }
            while cloudPending && iCloudEnabled && revision == cloudRevision && !Task.isCancelled {
                cloudPending = false
                cloudStatus = "Syncing with iCloud…"
                do {
                    let archive = CloudLibraryArchive(sources: sourceSnapshots, designs: aiRecords)
                    let remote = try await dependencies.syncCloud(archive)
                    // Disabling storage or changing accounts invalidates even uncancellable replies.
                    guard iCloudEnabled, revision == cloudRevision, !Task.isCancelled else {
                        return
                    }
                    // A restored Apple TV without a credential shows the account that another
                    // device listed for the companion, when the archive contains it. Read it
                    // before merging so a snapshot installed during this read is kept.
                    let restoredWorklist: SpineWorklistV1?
                    if hardcoverConnected {
                        restoredWorklist = nil
                    } else {
                        restoredWorklist = try? await dependencies.readSpineWorklist()
                    }
                    guard iCloudEnabled, revision == cloudRevision, !Task.isCancelled else {
                        return
                    }
                    let merged = remote.merging(
                        CloudLibraryArchive(sources: sourceSnapshots, designs: aiRecords))
                    sourceSnapshots = merged.sources
                    aiRecords = merged.designs
                    if let worklist = restoredWorklist,
                        sourceSnapshots.contains(where: {
                            $0.source == .hardcover && $0.accountID == worklist.accountID
                        })
                    {
                        setActiveHardcoverAccountID(worklist.accountID)
                    }
                    cloudBacked = true
                    do {
                        let savedSourceRevision = try await saveSources()
                        guard iCloudEnabled, revision == cloudRevision, !Task.isCancelled else {
                            return
                        }
                        // A source installed during the save wrote newer snapshots; sync again
                        // so they upload and the status settles.
                        guard savedSourceRevision == sourceSaveRevision else {
                            cloudPending = true
                            continue
                        }
                        styleSaveRevision &+= 1
                        let styleRevision = styleSaveRevision
                        if let data = try await persistence.saveStyleCache(
                            aiRecords, revision: styleRevision)
                        {
                            guard iCloudEnabled, revision == cloudRevision,
                                styleRevision == styleSaveRevision, !Task.isCancelled
                            else { return }
                            try dependencies.styleStore.savePreferences(data, cloudBacked: true)
                        }
                    } catch {
                        cloudStatus =
                            "iCloud synced, but the local copy could not be saved. "
                            + UserFacingError.message(error)
                        rebuildLibrary()
                        return
                    }
                    guard iCloudEnabled, revision == cloudRevision, !Task.isCancelled else {
                        return
                    }
                    seedSchedule()
                    rebuildLibrary()
                    // Publish from the archive this sync uploaded, because the iPhone and Mac
                    // companion requires the worklist's sync date to match that archive's
                    // snapshot to within a millisecond. A snapshot installed since then sets
                    // `cloudPending`, so the next loop iteration uploads it and republishes, even
                    // after a failed publish.
                    if let accountID = activeHardcoverAccountID,
                        let snapshot = remote.sources.first(where: {
                            $0.source == .hardcover && $0.accountID == accountID
                        })
                    {
                        // Only a connected, enabled, unexpired credential lists work, and that
                        // credential's authenticated validate or fetch set the active account
                        // ID, so no Hardcover request is needed here. An explicit local disable
                        // clears the list. A credential-free restore can adopt an account but
                        // never lists work, so it cannot reactivate a worklist that another
                        // Apple TV cleared.
                        let listsWork =
                            hardcoverConnected && hardcoverEnabled && !hardcoverSessionExpired
                        if listsWork || !hardcoverEnabled {
                            let worklist = SpineWorklistV1(
                                accountID: accountID, syncedAt: snapshot.syncedAt,
                                bookIDs: listsWork ? snapshot.books.map(\.id) : [])
                            do {
                                try await dependencies.publishSpineWorklist(worklist)
                                guard iCloudEnabled, revision == cloudRevision, !Task.isCancelled
                                else { return }
                            } catch {
                                guard revision == cloudRevision, !Task.isCancelled else { return }
                                cloudStatus =
                                    "Library saved to iCloud, but the spine worklist could not sync. "
                                    + UserFacingError.message(error)
                                if cloudPending { continue }
                                return
                            }
                        }
                    }
                    queueSpineDesignRefresh()
                    cloudStatus =
                        "Saved to iCloud. Updated "
                        + dependencies.now().formatted(date: .omitted, time: .shortened)
                } catch {
                    guard revision == cloudRevision, !Task.isCancelled else { return }
                    cloudStatus =
                        "iCloud could not sync. Local data is retained. "
                        + UserFacingError.message(error)
                    return
                }
            }
        }
    }

    /// Reads companion designs, cover choices, series links, and series looks for the active
    /// Hardcover snapshot into their local caches, then creates missing series looks
    /// (`createMissingSeriesLooks`) when CloudKit answered for every design and link. Looks
    /// sampled from covers also wait for a complete cover-choice read. One task runs per account
    /// and sync date; a newer selection cancels an older one.
    private func queueSpineDesignRefresh() {
        guard !PerformanceDiagnostics.isolates("background") else { return }
        guard iCloudEnabled, hardcoverEnabled, let accountID = activeHardcoverAccountID,
            let snapshot = activeHardcoverSnapshot(), snapshot.accountID == accountID
        else { return }
        if let identity = spineDesignTaskIdentity, spineDesignTask != nil,
            identity.accountID == accountID, identity.syncedAt == snapshot.syncedAt
        {
            return
        }
        spineDesignTask?.cancel()
        if spineDesigns.values.contains(where: { $0.accountID != accountID }) {
            spineDesigns = [:]
        }
        if seriesLinks.values.contains(where: { $0.accountID != accountID })
            || seriesLooks.values.contains(where: { $0.accountID != accountID })
        {
            seriesLinks = [:]
            pickedLinks = [:]
            seriesLooks = [:]
            refreshSeriesSources()
        }
        let requestID = UUID()
        spineDesignTaskIdentity = (accountID, snapshot.syncedAt, requestID)
        spineDesignTask = Task { [weak self] in
            guard let self else { return }
            let books = snapshot.books
            let designs = try? await dependencies.fetchSpineDesigns(accountID, books)
            let choices = try? await dependencies.fetchCoverChoices(accountID, books)
            let links = try? await dependencies.fetchSeriesLinks(accountID, books)
            let keys = Set(
                books.compactMap {
                    SeriesDesigns.lookKey(of: $0, link: (links?.values ?? seriesLinks)[$0.id])
                })
            let looks = try? await dependencies.fetchSeriesLooks(accountID, keys.sorted())
            guard spineDesignTaskIdentity?.requestID == requestID else { return }
            // A failed or cancelled read keeps the records already shown.
            if let designs, designs.values != spineDesigns { spineDesigns = designs.values }
            var rebuild = false
            if let choices, choices.values != coverChoices {
                coverChoices = choices.values
                rebuild = true
            }
            if var values = links?.values {
                for (id, pick) in pickedLinks where (values[id]?.chosenAt ?? .distantPast) < pick.at
                {
                    values[id] = pick.link
                }
                if values != seriesLinks {
                    seriesLinks = values
                    rebuild = true
                }
            }
            if let looks, looks != seriesLooks {
                seriesLooks = looks
                if !rebuild { refreshSeriesSources() }
            }
            if rebuild { rebuildLibrary() }
            // A design or link missing from a partial read could decide a look for good.
            if designs?.isComplete == true, links?.isComplete == true {
                await createMissingSeriesLooks(
                    of: books, accountID: accountID,
                    samplesCovers: choices?.isComplete == true, requestID: requestID)
            }
            guard spineDesignTaskIdentity?.requestID == requestID else { return }
            spineDesignTask = nil
            spineDesignTaskIdentity = nil
        }
    }

    /// Saves a series look for each look group of `books` that has none, so other devices draw
    /// the group alike. Saving never replaces a look another device saved first; that look is
    /// kept instead. Books whose link keeps their own look don't count toward a group.
    ///
    /// A group with a usable companion design copies the design that
    /// `SeriesDesigns.lookDesign(of:designs:)` picks. When `samplesCovers` is set, because
    /// CloudKit answered for every cover choice, a group of two or more books without one takes
    /// Book Wall's cover-sampled look of its best-ranked book, whose cover must already be
    /// cached. Each save is tried on its own; a failed one leaves its group without a look until
    /// the next read.
    private func createMissingSeriesLooks(
        of books: [Book], accountID: String, samplesCovers: Bool, requestID: UUID
    ) async {
        var groups: [SeriesLookKey: [Book]] = [:]
        for book in books where seriesLinks[book.id]?.ownLook != true {
            if let key = SeriesDesigns.lookKey(of: book, link: seriesLinks[book.id]),
                seriesLooks[key] == nil
            {
                groups[key, default: []].append(book)
            }
        }
        guard !groups.isEmpty else { return }
        let shown = Dictionary(
            allBooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rasterizer = BookWallRasterizer()
        var created: [SeriesLookKey: SeriesLookV1] = [:]
        for (key, members) in groups.sorted(by: { $0.key < $1.key }) {
            var look: SeriesLookV1?
            if let design = SeriesDesigns.lookDesign(of: members, designs: spineDesigns) {
                look = SeriesLookV1(key: key, design: design, createdAt: dependencies.now())
            } else if samplesCovers, members.count >= 2,
                let lead = members.min(by: {
                    SeriesDesigns.ranksBefore($0, $1, links: seriesLinks)
                })
            {
                // The displayed book carries the reader's chosen cover, which Book Wall samples.
                let book = shown[lead.id] ?? lead
                guard
                    let cover = try? await ArtworkStore.shared.detailImage(
                        for: book, maximumPixelSize: 400, allowsNetwork: false)
                else { continue }
                let style = await rasterizer.style(for: book, cover: cover, design: nil)
                look = SeriesLookV1(
                    key: key, localStyle: style, book: book, accountID: accountID,
                    createdAt: dependencies.now())
            }
            guard spineDesignTaskIdentity?.requestID == requestID else { return }
            guard let look, look.isValid(accountID: accountID, key: key) else { continue }
            guard let saved = try? await dependencies.createSeriesLook(look) else { continue }
            created[key] = saved
        }
        guard spineDesignTaskIdentity?.requestID == requestID, !created.isEmpty else { return }
        seriesLooks.merge(created) { current, _ in current }
        refreshSeriesSources()
    }

    /// Clears the companion design, cover-choice, series-link, and series-look caches once
    /// Hardcover is disabled or disconnected.
    private func queueSpineCachePrune() {
        guard !PerformanceDiagnostics.isolates("background") else { return }
        spineDesignTask?.cancel()
        spineDesigns = [:]
        coverChoices = [:]
        seriesLinks = [:]
        pickedLinks = [:]
        seriesLooks = [:]
        refreshSeriesSources()
        let requestID = UUID()
        spineDesignTaskIdentity = ("", .distantPast, requestID)
        spineDesignTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await dependencies.fetchSpineDesigns("", [])
            _ = try? await dependencies.fetchCoverChoices("", [])
            _ = try? await dependencies.fetchSeriesLinks("", [])
            _ = try? await dependencies.fetchSeriesLooks("", [])
            guard spineDesignTaskIdentity?.requestID == requestID else { return }
            spineDesignTask = nil
            spineDesignTaskIdentity = nil
        }
    }

    /// Waits for the currently queued cloud operation without scheduling another upload.
    func waitForCloudSync() async {
        await cloudTask?.value
    }

    /// Waits for the currently queued cloud operation for at most `limit`. A sync that takes
    /// longer keeps running; only the wait ends.
    private func waitForCloudSync(atMost limit: Duration) async {
        guard let task = cloudTask else { return }
        let (ended, end) = AsyncStream.makeStream(of: Void.self)
        let sleep = dependencies.sleep
        let timer = Task {
            try? await sleep(limit)
            end.finish()
        }
        Task {
            await task.value
            end.finish()
        }
        for await _ in ended {}
        timer.cancel()
    }

    /// Waits for the current companion record read and series-look creation.
    func waitForCompanionRecords() async {
        await spineDesignTask?.value
    }

    /// Waits for the queued series-link saves (`pickSeries(_:for:)`).
    func waitForSeriesLinkSaves() async {
        await seriesLinkSave?.value
    }

    /// Waits for queued Top Shelf renders and publications.
    func waitForTopShelf() async {
        await topShelfTask?.value
    }

    private func publishTopShelf() {
        let cached = Dictionary(
            dependencies.readTopShelf().map { ($0.id, $0.imageURL) },
            uniquingKeysWith: { first, _ in first })
        let style = shelfPreferences.progressStyle
        // Top Shelf mirrors the unfiltered shelf.
        let shelf =
            shelfFilter == nil || isSample
            ? books : activeShelfPreferences.select(allBooks, limit: bookCount)
        let items: [TopShelfBook] =
            isSample
            ? []
            : shelf.prefix(10)
                .compactMap { book in
                    guard book.isHardcoverBook,
                        let url = book.preferredCoverURL ?? cached[book.id],
                        url.scheme == "https"
                    else { return nil }
                    return TopShelfBook(
                        id: book.id, title: book.title, imageURL: url,
                        progress: book.isReading == true ? book.progress ?? 0 : nil,
                        showsNativeProgress: style == .horizontal ? true : nil)
                }
        topShelfRevision &+= 1
        let revision = topShelfRevision
        let persistence = persistence
        topShelfTask = Task.detached(priority: .utility) {
            await persistence.beginTopShelf(revision: revision)
            let items =
                style == .vertical
                ? await TopShelfPoster.render(items, artwork: .shared) : items
            await persistence.publishTopShelf(items, revision: revision)
        }
    }

    private func restoreSavedStyles(_ books: [Book]) {
        // Retain paid choices; books without a saved design are rendered as covers.
        for book in books { if let record = aiRecords[book.id] { styles[book.id] = record.style } }
        presentationRevision += 1
    }

    var hasAIKey: Bool { credentials.contains(aiConfiguration.credentialAccount) }

    @discardableResult func saveAI(key: String) -> Bool {
        do {
            _ = try aiConfiguration.validatedURL()
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard !trimmed.contains(where: \.isWhitespace) else { throw AIError.invalidKey }
                try dependencies.saveCredential(trimmed, aiConfiguration.credentialAccount)
            }
            dependencies.defaults.set(
                try JSONEncoder().encode(aiConfiguration), forKey: "aiConfiguration")
            reloadSavedAIAvailability()
            generationStatus = "Provider settings saved."
            queueAutomaticGeneration()
            return true
        } catch {
            generationStatus = UserFacingError.message(error)
            return false
        }
    }

    private func queueAutomaticGeneration() {
        automaticGenerationTask?.cancel()
        guard BookPresentation.spineGenerationEnabled else { return }
        guard !isSample, !automaticGenerationPaused, !ambientActive, hasStarted else { return }
        let sleep = dependencies.sleep
        automaticGenerationTask = Task { [weak self] in
            do { try await sleep(.seconds(1)) } catch { return }
            guard let self else { return }
            // Wait for the cloud restoration attempt before checking for missing designs.
            if let cloudTask { await cloudTask.value }
            guard !Task.isCancelled, !isLoading, !isGenerating, !isSample, !ambientActive else {
                return
            }
            regenerateSpines(onlyMissing: true, automatically: true)
        }
    }

    func regenerateSpines(onlyMissing: Bool = false, automatically: Bool = false) {
        guard BookPresentation.spineGenerationEnabled else {
            cancelGeneration()
            generationStatus = "Spine generation is disabled."
            return
        }
        guard !PerformanceDiagnostics.enabled else { return }
        guard !isGenerating, !isSample, !books.isEmpty, !ambientActive else { return }
        let configuration: AIConfiguration
        if automatically {
            guard !automaticGenerationPaused,
                let data = dependencies.defaults.data(forKey: "aiConfiguration"),
                let saved = try? JSONDecoder().decode(AIConfiguration.self, from: data),
                (try? saved.validatedURL()) != nil
            else { return }
            configuration = saved
        } else {
            guard saveAI(key: "") else { return }
            automaticGenerationPaused = false
            configuration = aiConfiguration
        }
        guard let key = dependencies.readCredential(configuration.credentialAccount) else {
            generationStatus = AIError.missingKey.localizedDescription
            return
        }
        let selected =
            automatically
            ? AutomaticSpineGeneration().candidates(in: books, savedIDs: Set(aiRecords.keys))
            : (onlyMissing ? books.filter { aiRecords[$0.id] == nil } : books)
        guard !selected.isEmpty else {
            if !automatically { generationStatus = "All selected spines are saved." }
            return
        }
        AutomaticSpineGeneration().recordAttempt(selected)
        analysisTask?.cancel()
        fontTask?.cancel()
        isGenerating = true
        generationStatus = "Matching covers and fonts…"
        generationTask = Task { [weak self] in
            guard let self else { return }
            let generator = AIStyleGenerator()
            var completed = 0
            var failures: [String] = []
            defer {
                isGenerating = false
                queueAutomaticGeneration()
                writeProgress(
                    completed: completed, total: selected.count, failures: failures, running: false)
            }
            writeProgress(completed: 0, total: selected.count, failures: [], running: true)
            for book in selected {
                guard !Task.isCancelled else {
                    generationStatus = "Generation stopped. Saved spines are ready to use."
                    return
                }
                generationStatus =
                    "Matching \(completed + failures.count + 1) of \(selected.count): \(book.title)"
                do {
                    if !cloudBacked || !iCloudEnabled {
                        try dependencies.styleStore.checkGenerationCapacity()
                    }
                    guard let url = book.detailCoverURL ?? book.coverURL else {
                        throw AIError.missingCover
                    }
                    let cover = try await ArtworkStore.shared.data(for: url)
                    let record = try await generator.generate(
                        book: book, cover: cover, configuration: configuration, key: key)
                    try Task.checkCancellation()
                    var updated = aiRecords
                    updated[book.id] = record
                    if cloudBacked && iCloudEnabled {
                        let saved = try await dependencies.syncCloud(
                            CloudLibraryArchive(sources: sourceSnapshots, designs: updated))
                        updated = saved.designs
                    }
                    try dependencies.styleStore.save(
                        updated, cloudBacked: cloudBacked && iCloudEnabled)
                    aiRecords = updated
                    styles[book.id] = record.style
                    presentationRevision += 1
                    completed += 1
                    queueCloudSync()
                } catch {
                    if Task.isCancelled {
                        generationStatus = "Generation stopped. Saved spines are ready to use."
                        return
                    }
                    let detail = UserFacingError.message(error)
                    failures.append("\(book.title): \(detail)")
                }
                writeProgress(
                    completed: completed, total: selected.count, failures: failures, running: true)
            }
            generationStatus =
                failures.isEmpty
                ? "Updated all \(completed) spines."
                : "Updated \(completed) spines. \(failures.count) could not be updated. \(failures.first ?? "")"
        }
    }

    func cancelGeneration() {
        automaticGenerationPaused = true
        automaticGenerationTask?.cancel()
        generationTask?.cancel()
    }

    private func writeProgress(completed: Int, total: Int, failures: [String], running: Bool) {
        let report: [String: Any] = [
            "completed": completed, "total": total, "failures": failures,
            "running": running, "bookLimit": bookCount,
            "updatedAt": dependencies.now().timeIntervalSince1970,
        ]
        try? FileManager.default.createDirectory(
            at: progressURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: progressURL, options: .atomic)
    }

    private func readable(_ error: Error) -> String {
        UserFacingError.message(error)
    }
}
