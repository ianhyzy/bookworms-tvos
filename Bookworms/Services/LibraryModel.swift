import Foundation
import Observation
import UIKit

@MainActor @Observable
final class LibraryModel {
    private(set) var books: [Book] = [] {
        didSet { if books != oldValue { presentationRevision += 1 } }
    }
    @ObservationIgnored private var allBooks: [Book] = []
    @ObservationIgnored private let dependencies: LibraryDependencies
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored private var cloudRevision = 0
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

    func savedSpineStyle(for book: Book) -> SpineStyle? {
        guard let record = aiRecords[book.id],
            BookPresentation.usesSpine(
                hasSavedKey: savedAIKeyAvailable, hasDesign: true,
                fontAvailable: UIFont(name: record.style.fontName, size: 23) != nil)
        else { return nil }
        return styles[book.id] ?? record.style
    }

    /// Reads the active Hardcover credential only at an explicit synchronization boundary.
    func hardcoverTokenForSync() -> String? {
        guard hardcoverEnabled, hardcoverConnected, !isSample else { return nil }
        return dependencies.readCredential("hardcover-token")
    }

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
    private(set) var hardcoverConnected = false
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
    func isBookReadByUser(_ id: Int) -> Bool {
        guard hardcoverConnected || isSample else { return false }
        guard let book = allBooks.first(where: { $0.id == id }) else { return false }
        return book.isRead == true || book.finished != nil
    }
    private var snapshotURL: URL { dependencies.legacySnapshotURL }
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var lastManualRefresh: Date?

    init(dependencies: LibraryDependencies = LibraryDependencies()) {
        self.dependencies = dependencies
        let defaults = dependencies.defaults
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
        // Off by default until the production CloudKit schema is deployed for testers.
        iCloudEnabled = defaults.object(forKey: "iCloudEnabled") as? Bool ?? false
        sourceErrors = defaults.dictionary(forKey: "sourceErrors") as? [String: String] ?? [:]
    }

    private func sourceConfigurationChanged() {
        sourceRevision += 1
        invalidateCloudSync()
        rebuildLibrary()
        if hasStarted { queueCloudSync() }
    }

    private func invalidateCloudSync() {
        cloudRevision += 1
        cloudTask?.cancel()
        cloudTask = nil
        cloudPending = false
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if dependencies.allowLaunchOverrides,
            ProcessInfo.processInfo.arguments.contains("--sample-library")
        {
            showSample()
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
            try? dependencies.sourceStore.save(sourceSnapshots)
        }
        for snapshot in sourceSnapshots {
            schedule.seed(snapshot.source, date: snapshot.syncedAt)
        }
        if let savedToken = dependencies.readCredential("hardcover-token") {
            hardcoverConnected = (try? HardcoverToken(savedToken)) != nil
            if !hardcoverConnected {
                message = HardcoverError.invalidToken.localizedDescription
            }
        }
        rebuildLibrary()
        if iCloudEnabled { queueCloudSync() } else { cloudStatus = "iCloud storage is off." }
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
                        case .success(let token):
                            self.hardcoverDeviceAuth = nil
                            self.hardcoverDeviceAuthMessage = nil
                            _ = await self.connectValidatedToken(
                                token, revision: self.sourceRevision)
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

    func connectWithCode(_ rawCode: String) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        let revision = sourceRevision
        defer { isLoading = false }
        let token: String
        do {
            token = try await dependencies.exchangeHardcoverCode(rawCode)
        } catch {
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            message = readable(error)
            sourceErrors[LibrarySource.hardcover.rawValue] = readable(error)
            return false
        }
        return await connectValidatedToken(token, revision: revision)
    }

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
        return await connectValidatedToken(token, revision: revision)
    }

    private func connectValidatedToken(_ token: String, revision: Int) async -> Bool {
        do {
            // Credential rotation must remain available between scheduled library syncs.
            if !schedule
                .isDue(
                    .hardcover, now: dependencies.now(),
                    hasSnapshot: sourceSnapshots.contains { $0.source == .hardcover })
            {
                try await dependencies.validateHardcover(token)
                guard revision == sourceRevision, !Task.isCancelled else { return false }
                try dependencies.saveCredential(token, "hardcover-token")
                hardcoverConnected = true
                connectionRevision += 1
                isSample = false
                hardcoverEnabled = true
                sourceErrors[LibrarySource.hardcover.rawValue] = nil
                message =
                    "Hardcover token verified and saved. Library sync keeps its daily schedule."
                return true
            }
            try schedule
                .begin(
                    .hardcover, now: dependencies.now(),
                    hasSnapshot: sourceSnapshots.contains { $0.source == .hardcover })
            let result = try await dependencies.fetchHardcover(token)
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            try dependencies.saveCredential(token, "hardcover-token")
            hardcoverConnected = true
            connectionRevision += 1
            hardcoverEnabled = true
            install(result, source: .hardcover, accountID: "hardcover")
            return true
        } catch {
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            message = readable(error)
            sourceErrors[LibrarySource.hardcover.rawValue] = readable(error)
            return false
        }
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
        var failures: [String] = []
        var checked = false
        if hardcoverEnabled,
            manual
                || schedule
                    .isDue(
                        .hardcover, now: dependencies.now(),
                        hasSnapshot: sourceSnapshots.contains { $0.source == .hardcover }),
            let token = dependencies.readCredential("hardcover-token")
        {
            checked = true
            do {
                try schedule
                    .begin(
                        .hardcover, now: dependencies.now(), manual: manual,
                        hasSnapshot: sourceSnapshots.contains { $0.source == .hardcover })
                let result = try await dependencies.fetchHardcover(token)
                guard revision == sourceRevision, !Task.isCancelled else { return }
                install(result, source: .hardcover, accountID: "hardcover")
            } catch {
                guard revision == sourceRevision, !Task.isCancelled else { return }
                sourceErrors[LibrarySource.hardcover.rawValue] = readable(error)
                failures.append("Hardcover: " + readable(error))
            }
        }
        if cwaEnabled,
            manual
                || schedule
                    .isDue(
                        .cwa, now: dependencies.now(),
                        hasSnapshot: sourceSnapshots.contains {
                            $0.source == .cwa && $0.accountID == cwaConfiguration.identity
                        }),
            let password = dependencies.readCredential("cwa-password")
        {
            checked = true
            do {
                try schedule
                    .begin(
                        .cwa, now: dependencies.now(), manual: manual,
                        hasSnapshot: sourceSnapshots.contains {
                            $0.source == .cwa && $0.accountID == cwaConfiguration.identity
                        })
                let configuration = cwaConfiguration
                let result = try await dependencies.fetchCWA(configuration, password)
                // A response belongs to the configuration captured before suspension.
                guard revision == sourceRevision, !Task.isCancelled else { return }
                install(result, source: .cwa, accountID: configuration.identity)
            } catch {
                guard revision == sourceRevision, !Task.isCancelled else { return }
                sourceErrors[LibrarySource.cwa.rawValue] = readable(error)
                failures.append("CWA: " + readable(error))
            }
        }
        if !failures.isEmpty {
            message = failures.joined(separator: "\n")
        } else if !checked {
            message =
                "No sources were synced. Automatic checks run once a day; use Sync now in Settings → Sources to check sooner."
        }
        queueCloudSync()
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
            install(result, source: .cwa, accountID: configuration.identity)
            return true
        } catch {
            guard revision == sourceRevision, !Task.isCancelled else { return false }
            message = readable(error)
            sourceErrors[LibrarySource.cwa.rawValue] = readable(error)
            writeSyncDiagnostics()
            return false
        }
    }

    func sourceStatus(_ source: LibrarySource, dateFormat: AppDateFormat = .monthName) -> String {
        if let error = sourceErrors[source.rawValue] { return error }
        guard let last = schedule.lastAttempt(source) else { return "Not synced yet" }
        let successful = sourceSnapshots.first { $0.source == source }?.syncedAt
        let next = successful.map { $0.addingTimeInterval(86400) } ?? last.addingTimeInterval(300)
        return next > dependencies.now()
            ? "Next check: " + dateFormat.string(from: next) + " · "
                + next.formatted(date: .omitted, time: .shortened)
            : "Ready to sync"
    }

    func becameActive() async {
        guard hasStarted, !isSample else { return }
        await refresh()
    }

    func showSample() {
        guard !isLoading else { return }
        cancelShelfWork()
        allBooks = SampleLibrary.books
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
        message = nil
        publishTopShelf()
    }

    func disconnect() {
        guard !isLoading else { return }
        cancelShelfWork()
        dependencies.removeCredential("hardcover-token")
        hardcoverConnected = false
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

    func style(for book: Book) -> SpineStyle { styles[book.id] ?? .fallback(for: book) }

    private func install(_ result: [Book], source: LibrarySource, accountID: String) {
        sourceErrors[source.rawValue] = nil
        let snapshot = SourceSnapshot(
            source: source, accountID: accountID, books: result, syncedAt: dependencies.now())
        sourceSnapshots.removeAll { $0.source == source && $0.accountID == accountID }
        sourceSnapshots.append(snapshot)
        schedule.seed(source, date: snapshot.syncedAt)
        isSample = false
        message = nil
        do { try dependencies.sourceStore.save(sourceSnapshots) } catch {
            message = "Books loaded, but the offline library could not be saved."
        }
        rebuildLibrary()
        queueCloudSync()
    }

    private func rebuildLibrary() {
        let measurement = PerformanceDiagnostics.begin("RebuildLibrary")
        defer { measurement.end() }
        guard !isSample else { return }
        let enabled = sourceSnapshots.filter {
            ($0.source == .hardcover && hardcoverEnabled)
                || ($0.source == .cwa && cwaEnabled && $0.accountID == cwaConfiguration.identity)
        }
        allBooks = LibraryMerge.books(from: enabled)
        syncedAt = enabled.map(\.syncedAt).max()
        styles = aiRecords.mapValues(\.style)
        updateShelf()
    }

    private func updateShelf() {
        let measurement = PerformanceDiagnostics.begin("UpdateShelf")
        defer { measurement.end() }
        books =
            isSample
            ? Array(allBooks.prefix(bookCount))
            : shelfPreferences.select(allBooks, limit: bookCount)
        if !isSample {
            restoreSavedStyles(books)
            restoreVisibleFonts()
            queueAutomaticGeneration()
        }
        publishTopShelf()
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
        cloudStatus =
            "Your iCloud account changed. Turn iCloud Storage on to sync this library with the current account."
    }

    func queueCloudSync() {
        guard !PerformanceDiagnostics.isolates("background") else { return }
        guard hasStarted, iCloudEnabled, !isSample else { return }
        cloudPending = true
        guard cloudTask == nil else { return }
        let revision = cloudRevision
        cloudTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == cloudRevision { cloudTask = nil } }
            do { try await dependencies.sleep(.seconds(2)) } catch { return }
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
                    let merged = remote.merging(
                        CloudLibraryArchive(sources: sourceSnapshots, designs: aiRecords))
                    sourceSnapshots = merged.sources
                    aiRecords = merged.designs
                    cloudBacked = true
                    do {
                        try dependencies.sourceStore.save(sourceSnapshots)
                        try dependencies.styleStore.save(aiRecords, cloudBacked: true)
                    } catch {
                        cloudStatus =
                            "iCloud synced, but the local copy could not be saved. "
                            + UserFacingError.message(error)
                        rebuildLibrary()
                        return
                    }
                    for snapshot in sourceSnapshots {
                        schedule.seed(snapshot.source, date: snapshot.syncedAt)
                    }
                    rebuildLibrary()
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

    /// Waits for the currently queued cloud operation without scheduling another upload.
    func waitForCloudSync() async {
        await cloudTask?.value
    }

    private func publishTopShelf() {
        let cached = Dictionary(
            dependencies.readTopShelf().map { ($0.id, $0.imageURL) },
            uniquingKeysWith: { first, _ in first })
        let items: [TopShelfBook] =
            isSample
            ? []
            : books.prefix(10)
                .compactMap { book in
                    guard book.isHardcoverBook,
                        let url = book.detailCoverURL ?? book.coverURL ?? cached[book.id],
                        url.scheme == "https"
                    else { return nil }
                    return TopShelfBook(id: book.id, title: book.title, imageURL: url)
                }
        try? dependencies.writeTopShelf(items)
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
