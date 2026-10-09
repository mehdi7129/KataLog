import Foundation
import KataLogCore

/// One ordered owner for collection writes and reads. The queue never runs on
/// MainActor; callers publish immutable results only after checking their scope.
final class GCSStorageIO: @unchecked Sendable {
    private let executor = DispatchQueue(label: "KataLog.GCSStorage", qos: .utility)
    private var repository: GCSQueueRepository?
    private var writable = false
    private let database: URL
    private let settings: URL

    init(database: URL, settings: URL) { self.database = database; self.settings = settings }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            executor.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    struct Write: Sendable {
        var state: GCSCollectionState
        var transfers: [GCSTransfer]
        var legacy: [GCSTransfer]
        var initialDestination: URL?
        var retain: Bool
        var fleet: GCSFleetObservationState?
        var registering: Bool
    }
    struct Saved: Sendable {
        var repository: GCSQueueRepository
        var retained: [GCSTransfer]?
        var counts: Result<GCSQueueCounts, Error>
    }
    func save(_ request: Write) async throws -> Saved {
        try await perform { [self] in
            if !writable {
                if let destination = request.initialDestination,
                   destination.path == request.state.downloadDirectory,
                   !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                }
                try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
                let opened = try GCSQueueRepository(url: database)
                try opened.migrateLegacy(request.legacy)
                repository = opened; writable = true
            }
            guard let repository else { throw AnalysisError.unavailable("La file de collecte ne peut pas être ouverte.") }
            _ = try repository.saveTransfers(request.transfers)
            let fleetURL = settings.deletingLastPathComponent().appendingPathComponent("fleet.json")
            if request.fleet != nil { _ = try GCSFleetObservationStore.read(file: fleetURL) }
            let previousFleet = request.registering && FileManager.default.fileExists(atPath: fleetURL.path)
                ? try Data(contentsOf: fleetURL) : nil
            if let fleet = request.fleet {
                // The registry may have changed since the cold snapshot was read.
                // Never replace an unreadable/future version with cached state.
                try Self.writeFleet(fleet, to: fleetURL)
            }
            do { try JSONEncoder().encode(request.state).write(to: settings, options: .atomic) }
            catch {
                if request.registering {
                    if let previousFleet { try previousFleet.write(to: fleetURL, options: .atomic) }
                    else { try FileManager.default.removeItem(at: fleetURL) }
                }
                throw error
            }
            let counts = Result { try repository.counts(batchID: request.state.currentBatchID ?? "", authorizedUUIDs: request.state.allowedUUIDs) }
            let retained = request.retain ? try repository.retainedTransfers() : nil
            if let retained { repository.forgetPayloads(except: Set(retained.map(\.id))) }
            return Saved(repository: repository, retained: retained, counts: counts)
        }
    }
    func close() async throws {
        try await perform { [self] in repository = nil; writable = false }
    }
    private static func writeFleet(_ state: GCSFleetObservationState, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= 4 * 1024 * 1024 else { throw AnalysisError.engine("Le registre des observations dépasse 4 Mio.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
