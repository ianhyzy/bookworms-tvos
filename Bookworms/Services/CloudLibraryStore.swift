import CloudKit
import Foundation

extension CKContainer {
    /// The app's CloudKit container.
    static var bookworms: CKContainer { CKContainer(identifier: "iCloud.gay.ian.Bookworms") }
}

struct CloudLibraryArchive: Codable, Sendable {
    var version = 1
    var sources: [SourceSnapshot] = []
    var designs: [Int: AIStyleRecord] = [:]
    /// Each Hardcover account that the reader merged into another, keyed by the old account ID,
    /// as the iPhone and Mac write it. Entries are never removed. `nil` when empty, so an archive
    /// without merges encodes as before.
    var merges: [String: String]? = nil

    /// The archive with `other`'s newer snapshots and designs, and the union of both sides'
    /// merges. `self` is the stored side, whose merge entry wins a conflict.
    func merging(_ other: Self) -> Self {
        var merged = self
        let merges = (self.merges ?? [:]).merging(other.merges ?? [:]) { stored, _ in stored }
        merged.merges = merges.isEmpty ? nil : merges
        for source in other.sources {
            if let index = merged.sources.firstIndex(where: {
                $0.source == source.source && $0.accountID == source.accountID
            }) {
                let stored = merged.sources[index]
                merged.sources[index] =
                    source.syncedAt > stored.syncedAt
                    ? source.keeping(stored) : stored.keeping(source)
            } else {
                merged.sources.append(source)
            }
        }
        for (id, design) in other.designs {
            if merged.designs[id].map({ $0.generatedAt < design.generatedAt }) ?? true {
                merged.designs[id] = design
            }
        }
        merged.sources.sort {
            ($0.source.rawValue + $0.accountID) < ($1.source.rawValue + $1.accountID)
        }
        return merged
    }
}

/// A Hardcover account with Bookworms data in iCloud.
struct CloudAccount: Equatable, Sendable, Identifiable {
    let id: String
    let username: String?
    /// Book IDs from the account's newest snapshot, plus the worklist's when it names the account.
    let bookIDs: Set<Int>
    /// The newest snapshot's sync date, or the worklist's.
    let syncedAt: Date
    var name: String { username.map { "@\($0)" } ?? "account \(id)" }
}

/// What the Hardcover account check (`CloudLibraryArchive.check`) allows before a sync.
enum CloudAccountCheck: Equatable, Sendable {
    /// iCloud may be used for `accountID` (nil: no library in iCloud yet).
    case clear(accountID: String?)
    /// iCloud holds data from these accounts, which aren't merged into the signed-in one.
    case otherAccounts([CloudAccount])
    /// A device without a Hardcover sign-in found these libraries and no choice among them.
    case chooseLibrary([CloudAccount])
}

/// The one-account rules, which the iPhone and Mac app share: a device signed in to a
/// Hardcover account uses iCloud only while every other real account's data in it has been
/// merged into that account, and a device without a sign-in shows one library.
extension CloudLibraryArchive {
    /// Whether `accountID` is `target`, or reaches it by following `merges` (old account to the
    /// account it merged into). A loop that never reaches `target` doesn't count.
    static func absorbs(_ accountID: String, _ merges: [String: String], into target: String)
        -> Bool
    {
        var current = accountID
        var seen = Set<String>()
        while current != target {
            guard seen.insert(current).inserted, let next = merges[current] else { return false }
            current = next
        }
        return true
    }

    /// The real Hardcover accounts with a snapshot in `snapshots` that aren't merged into
    /// another, or, when merges leave none, as in a loop, every real account with a snapshot.
    /// The legacy `"hardcover"` placeholder is never a library.
    static func libraryIDs(of snapshots: [SourceSnapshot], merges: [String: String]) -> Set<String>
    {
        let real = Set(
            snapshots.filter { $0.source == .hardcover && $0.accountID != "hardcover" }
                .map(\.accountID))
        let libraries = real.filter { merges[$0] == nil }
        return libraries.isEmpty ? real : libraries
    }

    /// Checks the archive and `worklist` for another Hardcover account's data.
    ///
    /// Signed in, any real account that isn't absorbed into `signedInAccountID` is another
    /// account. Without a sign-in, one library is clear, and two or more need a choice unless
    /// `chosenAccountID` is one of them.
    func check(worklist: SpineWorklistV1?, signedInAccountID: String?, chosenAccountID: String?)
        -> CloudAccountCheck
    {
        let merges = self.merges ?? [:]
        let snapshots = sources.filter { $0.source == .hardcover && $0.accountID != "hardcover" }
        func account(_ id: String) -> CloudAccount {
            let own = snapshots.filter { $0.accountID == id }
            let newest = own.max { $0.syncedAt < $1.syncedAt }
            let listed = worklist?.accountID == id ? worklist : nil
            return CloudAccount(
                id: id,
                username: own.filter { $0.username != nil }.max { $0.syncedAt < $1.syncedAt }?
                    .username,
                bookIDs: Set(newest?.books.map(\.id) ?? []).union(listed?.bookIDs ?? []),
                syncedAt: newest?.syncedAt ?? listed?.syncedAt ?? .distantPast)
        }
        if let signedInAccountID {
            var ids = Set(snapshots.map(\.accountID))
            if let worklist, worklist.accountID != "hardcover" { ids.insert(worklist.accountID) }
            let others = ids.filter { !Self.absorbs($0, merges, into: signedInAccountID) }
            return others.isEmpty
                ? .clear(accountID: signedInAccountID)
                : .otherAccounts(others.sorted().map(account))
        }
        let libraries = Self.libraryIDs(of: snapshots, merges: merges)
        guard libraries.count > 1 else { return .clear(accountID: libraries.first) }
        if let chosenAccountID, libraries.contains(chosenAccountID) {
            return .clear(accountID: chosenAccountID)
        }
        return .chooseLibrary(libraries.sorted().map(account))
    }
}

extension SourceSnapshot {
    /// The snapshot with what a writer that predates a field leaves out filled in from `older`,
    /// a snapshot of the same account: its series, its username, and each book's `finishedDates` when the
    /// book's newest finish there is still `finished`. Otherwise such a book shows one read
    /// until the next Hardcover sync.
    fileprivate func keeping(_ older: SourceSnapshot) -> SourceSnapshot {
        var snapshot = self
        snapshot.series = series ?? older.series
        snapshot.username = username ?? older.username
        let reads = Dictionary(
            older.books.compactMap { book in book.finishedDates.map { (book.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        guard !reads.isEmpty else { return snapshot }
        snapshot.books = books.map { book in
            // An empty list counts as none, as `Book.finishes` reads it.
            guard book.finishedDates?.isEmpty ?? true, let kept = reads[book.id],
                kept.first == book.finished
            else { return book }
            var book = book
            book.finishedDates = kept
            return book
        }
        return snapshot
    }
}

/// Keeps CloudKit transport separate so local tests can exercise conflicts without an iCloud account.
protocol CloudLibraryDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func record(for id: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws
}

private struct AppleCloudLibraryDatabase: CloudLibraryDatabase {
    private var container: CKContainer { .bookworms }
    func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }
    func record(for id: CKRecord.ID) async throws -> CKRecord {
        try await container.privateCloudDatabase.record(for: id)
    }
    func save(_ record: CKRecord) async throws {
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let saved = result.saveResults[record.recordID] else {
            throw CloudStorageError.incomplete
        }
        _ = try saved.get()
    }
}

actor CloudLibraryStore {
    static let shared = CloudLibraryStore()
    private let recordID = CKRecord.ID(recordName: "library-v1")
    private let database: (any CloudLibraryDatabase)?

    init(database: (any CloudLibraryDatabase)? = nil) { self.database = database }

    /// The signed-in iCloud user's record name, or `nil` when it can't be read.
    func userRecordName() async -> String? {
        #if targetEnvironment(simulator)
            return nil
        #else
            return try? await CKContainer.bookworms.userRecordID().recordName
        #endif
    }

    /// Reads the stored archive without saving anything. `nil` when iCloud holds none.
    func read() async throws -> CloudLibraryArchive? {
        let database = try await availableDatabase()
        do {
            return try Self.archive(in: try await database.record(for: recordID))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func sync(_ local: CloudLibraryArchive) async throws -> CloudLibraryArchive {
        let database = try await availableDatabase()
        // Conditional saves merge a concurrent device's edits instead of replacing its archive.
        for _ in 0..<3 {
            let record: CKRecord
            do { record = try await database.record(for: recordID) } catch let error as CKError
                where error.code == .unknownItem
            {
                record = CKRecord(recordType: "LibraryArchive", recordID: recordID)
            }
            let remote = try Self.archive(in: record) ?? CloudLibraryArchive()
            let merged = remote.merging(local)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let payload = try encoder.encode(merged)
            if record["archive"] != nil, payload == (try encoder.encode(remote)) { return merged }
            let file = FileManager.default.temporaryDirectory.appending(
                path: "cloud-library-\(UUID().uuidString).json")
            try payload.write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            record["archive"] = CKAsset(fileURL: file)
            do {
                try await database.save(record)
                return merged
            } catch let error as CKError where error.code == .serverRecordChanged { continue }
        }
        throw CloudStorageError.conflict
    }

    private func availableDatabase() async throws -> any CloudLibraryDatabase {
        let database: any CloudLibraryDatabase
        if let supplied = self.database {
            database = supplied
        } else {
            #if targetEnvironment(simulator)
                // Unsigned simulator builds cannot initialize a CloudKit container safely.
                throw CloudStorageError.simulator
            #else
                database = AppleCloudLibraryDatabase()
            #endif
        }
        switch try await database.accountStatus() {
        case .available: return database
        case .noAccount: throw CloudStorageError.unavailable
        case .restricted: throw CloudStorageError.restricted
        default: throw CloudStorageError.temporarilyUnavailable
        }
    }

    /// The archive `record` holds, or `nil` for a new record that has none yet.
    private static func archive(in record: CKRecord) throws -> CloudLibraryArchive? {
        guard let asset = record["archive"] as? CKAsset else {
            guard record.modificationDate == nil else { throw CloudStorageError.incomplete }
            return nil
        }
        guard let url = asset.fileURL else { throw CloudStorageError.incomplete }
        let data = try Data(contentsOf: url)
        // A newer format may change the archive's shape, so its version is read alone first.
        struct Header: Decodable { let version: Int }
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else {
            throw CloudStorageError.newerVersion
        }
        return try JSONDecoder().decode(CloudLibraryArchive.self, from: data)
    }
}

enum CloudStorageError: LocalizedError {
    case unavailable, restricted, temporarilyUnavailable, incomplete, newerVersion, conflict,
        simulator, otherAccount
    var errorDescription: String? {
        switch self {
        case .otherAccount:
            "iCloud has data from another Hardcover account. Choose Merge or Keep iCloud off."
        case .restricted:
            "iCloud access is restricted on this Apple TV. Check account restrictions in Settings."
        case .temporarilyUnavailable:
            "iCloud account status is temporarily unavailable. Try syncing again later."
        case .incomplete:
            "The iCloud archive could not be read or saved completely. Try again later."
        case .simulator:
            "iCloud sync requires a signed Apple TV build. The simulator uses local storage."
        case .unavailable:
            "Sign in to iCloud in Apple TV Settings, then sync again."
        case .newerVersion:
            "Update the app to read this iCloud library. Your cloud data is unchanged."
        case .conflict:
            "Another device updated the library. iCloud sync will retry when the app becomes active."
        }
    }
}
