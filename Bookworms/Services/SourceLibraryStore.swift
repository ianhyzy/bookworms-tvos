import Foundation

struct SourceLibraryStore {
    let url: URL
    init(url: URL = URL.cachesDirectory.appending(path: "Bookworms/sources.json")) {
        self.url = url
    }
    func load() -> [SourceSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SourceSnapshot].self, from: data)) ?? []
    }
    func save(_ snapshots: [SourceSnapshot]) throws {
        let measurement = PerformanceDiagnostics.begin("SourcePersistence")
        defer { measurement.end() }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshots).write(to: url, options: .atomic)
    }
}

@MainActor
struct SourceSyncSchedule {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func lastAttempt(_ source: LibrarySource) -> Date? {
        defaults.object(forKey: "syncAttempt.\(source.rawValue)") as? Date
    }
    func isDue(_ source: LibrarySource, now: Date = Date(), hasSnapshot: Bool = true) -> Bool {
        RefreshPolicy.isDue(
            lastAttempt: lastAttempt(source),
            lastSuccess: defaults.object(forKey: "syncSuccess.\(source.rawValue)") as? Date,
            hasSnapshot: hasSnapshot, manual: false, now: now)
    }
    func begin(
        _ source: LibrarySource, now: Date = Date(), manual: Bool = false,
        hasSnapshot: Bool = true
    ) throws {
        guard manual || isDue(source, now: now, hasSnapshot: hasSnapshot) else {
            throw SourceError.dailyLimit
        }
        defaults.set(now, forKey: "syncAttempt.\(source.rawValue)")
    }
    func seed(_ source: LibrarySource, date: Date) {
        defaults.set(date, forKey: "syncSuccess.\(source.rawValue)")
        if lastAttempt(source).map({ $0 < date }) ?? true {
            defaults.set(date, forKey: "syncAttempt.\(source.rawValue)")
        }
    }
}

/// Successful snapshots last a day; failures back off briefly without blocking cache recovery.
enum RefreshPolicy {
    static func isDue(
        lastAttempt: Date?, lastSuccess: Date?, hasSnapshot: Bool,
        manual: Bool, now: Date
    ) -> Bool {
        if manual { return true }
        if hasSnapshot, let lastSuccess, now.timeIntervalSince(lastSuccess) < 86400 {
            return false
        }
        // A purged successful snapshot can be rebuilt immediately. Failed attempts wait five minutes.
        if let lastAttempt, lastSuccess == nil || lastAttempt > lastSuccess! {
            return now.timeIntervalSince(lastAttempt) >= 300
        }
        return true
    }
}
