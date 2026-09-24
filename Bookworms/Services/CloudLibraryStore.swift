import CloudKit
import Foundation

struct CloudLibraryArchive: Codable, Sendable {
    var version = 1
    var sources: [SourceSnapshot] = []
    var designs: [Int: AIStyleRecord] = [:]

    func merging(_ other: Self) -> Self {
        var merged = self
        for source in other.sources {
            if let index = merged.sources.firstIndex(where: {
                $0.source == source.source && $0.accountID == source.accountID
            }) {
                if source.syncedAt > merged.sources[index].syncedAt {
                    merged.sources[index] = source
                }
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

/// Keeps CloudKit transport separate so local tests can exercise conflicts without an iCloud account.
protocol CloudLibraryDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func record(for id: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws
}

private struct AppleCloudLibraryDatabase: CloudLibraryDatabase {
    private var container: CKContainer { CKContainer(identifier: "iCloud.gay.ian.Bookworms") }
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

    func sync(_ local: CloudLibraryArchive) async throws -> CloudLibraryArchive {
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
        case .available: break
        case .noAccount: throw CloudStorageError.unavailable
        case .restricted: throw CloudStorageError.restricted
        default: throw CloudStorageError.temporarilyUnavailable
        }
        // Conditional saves merge a concurrent device's edits instead of replacing its archive.
        for _ in 0..<3 {
            let record: CKRecord
            do { record = try await database.record(for: recordID) } catch let error as CKError
                where error.code == .unknownItem
            {
                record = CKRecord(recordType: "LibraryArchive", recordID: recordID)
            }
            let remote: CloudLibraryArchive
            if let asset = record["archive"] as? CKAsset {
                guard let url = asset.fileURL else { throw CloudStorageError.incomplete }
                remote = try JSONDecoder()
                    .decode(CloudLibraryArchive.self, from: Data(contentsOf: url))
                guard remote.version == 1 else { throw CloudStorageError.newerVersion }
            } else {
                guard record.modificationDate == nil else { throw CloudStorageError.incomplete }
                remote = CloudLibraryArchive()
            }
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
}

enum CloudStorageError: LocalizedError {
    case unavailable, restricted, temporarilyUnavailable, incomplete, newerVersion, conflict,
        simulator
    var errorDescription: String? {
        switch self {
        case .restricted:
            "iCloud access is restricted on this Apple TV. Check account restrictions in Settings."
        case .temporarilyUnavailable:
            "iCloud account status is temporarily unavailable. Try syncing again later."
        case .incomplete:
            "The iCloud archive could not be read or saved completely. Try again later."
        case .simulator:
            "iCloud sync requires a signed Apple TV build. The simulator uses local storage."
        case .unavailable:
            "Sign in to iCloud on Apple TV to save your library and designs. Local data is still available."
        case .newerVersion:
            "Update the app to read this iCloud library. Your cloud data is unchanged."
        case .conflict:
            "Another device updated the library. iCloud sync will retry when the app becomes active."
        }
    }
}
