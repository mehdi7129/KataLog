import Foundation
import KataLogCore

struct GCSFleetObservation: Codable, Equatable, Sendable {
    var uuid: String
    var authorized: Bool
    var lastSeenAtUTC: String?
    var lastSeenSource: String?
}
struct GCSFleetObservationState: Codable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var drones: [GCSFleetObservation] = []
}

/// Persist measured receipt times only. Loading a registry does not create a
/// new observation and removing authorization retains the recorded history.
@MainActor
final class GCSFleetObservationStore {
    private(set) var state = GCSFleetObservationState()
    private(set) var errorMessage: String?
    private let file: URL
    private let canMutate: () -> Bool
    private var dirty = false
    private var writable = true
    init(file: URL, canMutate: @escaping () -> Bool) {
        self.file = file; self.canMutate = canMutate
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard (attributes.fileSize ?? Int.max) <= 4 * 1024 * 1024, attributes.isSymbolicLink != true else {
                throw AnalysisError.engine("Registre trop volumineux ou lien inattendu. Le fichier existant est conservé.")
            }
            let data = try Data(contentsOf: file)
            guard data.count <= 4 * 1024 * 1024 else { throw AnalysisError.engine("Le registre des observations dépasse 4 Mio.") }
            let loaded = try JSONDecoder().decode(GCSFleetObservationState.self, from: data)
            guard loaded.schemaVersion == 1, loaded.revision >= 0, loaded.drones.count <= 10_000,
                  Set(loaded.drones.map(\.uuid)).count == loaded.drones.count,
                  loaded.drones.allSatisfy({ GCSIdentity.isValid($0.uuid) && $0.uuid == $0.uuid.uppercased() && Self.validObservation($0) }) else {
                throw AnalysisError.engine("Registre des observations incompatible. Le fichier existant est conservé.")
            }
            state = loaded
        } catch { writable = false; errorMessage = "Les observations GCS ne peuvent pas être relues : \(error.localizedDescription)" }
    }
    private static func validObservation(_ entry: GCSFleetObservation) -> Bool {
        guard let stamp = entry.lastSeenAtUTC else { return entry.lastSeenSource == nil }
        guard stamp.utf8.count <= 64, entry.lastSeenSource == "gcs-telemetry" else { return false }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter(); whole.formatOptions = [.withInternetDateTime]
        return fractional.date(from: stamp) != nil || whole.date(from: stamp) != nil
    }
    func record(_ observed: [GCSDrone], authorized: Set<String>) {
        guard writable else { return }
        do {
            let next = try updatedState(observed, authorized: authorized)
            guard next.drones != state.drones else { flush(); return }
            state = next; dirty = true; flush()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Registration is explicit and must be durable before any inventory or
    /// download starts. Keep the previous registry if saving GCS settings fails.
    /// Settings remain the authority after a crash between the two atomic files;
    /// the next attachment reconciles the registry without starting a transfer.
    func register(_ observed: [GCSDrone], authorized: Set<String>, saveSettings: () throws -> Void) throws {
        guard writable, canMutate() else {
            throw AnalysisError.unavailable(errorMessage ?? "Le registre des drones ne peut pas être modifié pour le moment.")
        }
        let next = try updatedState(observed, authorized: authorized)
        let previous = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        do {
            try write(next)
            do { try saveSettings() }
            catch {
                // Only this operation's own write is rolled back, synchronously
                // on the main actor; no other observation can interleave here.
                if let previous { try previous.write(to: file, options: .atomic) }
                else { try FileManager.default.removeItem(at: file) }
                throw error
            }
            state = next; dirty = false; errorMessage = nil
        } catch {
            let message = "Les drones n’ont pas pu être enregistrés : \(error.localizedDescription)"
            errorMessage = message
            throw AnalysisError.engine(message)
        }
    }

    private func updatedState(_ observed: [GCSDrone], authorized: Set<String>) throws -> GCSFleetObservationState {
        var entries = Dictionary(uniqueKeysWithValues: state.drones.map { ($0.uuid, $0) })
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for drone in observed where authorized.contains(drone.uuid) && drone.lastSeen > .distantPast {
            var entry = entries[drone.uuid] ?? GCSFleetObservation(uuid: drone.uuid, authorized: true)
            entry.lastSeenAtUTC = formatter.string(from: drone.lastSeen)
            entry.lastSeenSource = "gcs-telemetry"; entries[drone.uuid] = entry
        }
        for uuid in authorized where GCSIdentity.isValid(uuid) {
            if entries[uuid] == nil { entries[uuid] = GCSFleetObservation(uuid: uuid, authorized: true) }
        }
        for uuid in entries.keys { entries[uuid]?.authorized = authorized.contains(uuid) }
        let next = entries.values.sorted { $0.uuid < $1.uuid }
        guard next != state.drones else { return state }
        guard next.count <= 10_000, state.revision < Int.max else { throw AnalysisError.engine("Le registre des observations dépasse son budget.") }
        var result = state; result.drones = next; result.revision += 1
        return result
    }
    private func write(_ state: GCSFleetObservationState) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= 4 * 1024 * 1024 else { throw AnalysisError.engine("Le registre des observations dépasse 4 Mio.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    func flush() {
        guard dirty, writable, canMutate() else { return }
        do {
            try write(state); dirty = false; errorMessage = nil
        } catch { errorMessage = "Les observations GCS ne peuvent pas être enregistrées : \(error.localizedDescription)" }
    }
}
