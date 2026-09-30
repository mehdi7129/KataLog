import Combine
import Foundation
import KataLogCore

@MainActor
final class DroneAnnotationStore: ObservableObject {
    @Published private(set) var state = DroneAnnotationState()
    @Published private(set) var errorMessage: String?
    private let url: URL
    private var loadFailed = false
    private let canWrite: Bool
    var canMutate: () -> Bool = { true }
    private var persisted: Data?

    init(url: URL, canWrite: Bool = true) {
        self.url = url
        self.canWrite = canWrite
        reload()
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            persisted = nil; state = .init(); loadFailed = false; errorMessage = nil; return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(DroneAnnotationState.self, from: data)
            guard decoded.schemaVersion == 1 else { throw DroneAnnotationError.invalid("Version d’annotations non prise en charge.") }
            for (key, value) in decoded.stockNumbers {
                guard DroneAnnotationValidation.isValidKey(key), try DroneAnnotationValidation.stockNumber(value) == value else { throw DroneAnnotationError.invalid("Identité ou numéro enregistré invalide.") }
            }
            for (key, value) in decoded.familyOverrides {
                guard !key.isEmpty, try DroneAnnotationValidation.family(value) == value else { throw DroneAnnotationError.invalid("Classement enregistré invalide.") }
            }
            state = decoded
            persisted = data; loadFailed = false; errorMessage = nil
        } catch {
            loadFailed = true
            errorMessage = "Annotations illisibles : \(error.localizedDescription) Le fichier est conservé : \(url.path)"
        }
    }

    func displayName(forGCSUUID uuid: String) -> String {
        state.stockNumbers["gcs:" + uuid.uppercased()].map { "Drone " + $0 } ?? shortIdentity(uuid)
    }
    func setStockNumber(_ value: String?, forKey key: String, replacingLegacyKey: String? = nil) throws {
        do {
            guard DroneAnnotationValidation.isValidKey(key) else { throw DroneAnnotationError.invalid("Identité contrôleur invalide.") }
            var next = state
            next.stockNumbers[key] = try DroneAnnotationValidation.stockNumber(value)
            if let legacy = replacingLegacyKey, legacy != key { next.stockNumbers.removeValue(forKey: legacy) }
            try save(next)
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    func setFamily(_ value: String?, for message: LogMessage) throws {
        do {
            var next = state
            next.familyOverrides.removeValue(forKey: message.groupKey)
            next.familyOverrides[message.classificationKey] = try DroneAnnotationValidation.family(value)
            try save(next)
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    func reconcileIdentities(in logs: [FlightLog]) {
        guard canWrite, canMutate() else { return }
        var next = state
        let rejected = Set(logs.filter { $0.metadata["gcsIdentityStatus"] == "rejected" }.map(\.droneID))
        for (raw, uuids) in DroneAnnotationState.observedGCSLinks(in: logs) where uuids.count == 1 && !rejected.contains(raw) {
            guard let uuid = uuids.first, let legacy = next.stockNumbers["ulog:" + raw] else { continue }
            let canonical = "gcs:" + uuid
            if next.stockNumbers[canonical] == nil || next.stockNumbers[canonical] == legacy {
                next.stockNumbers[canonical] = legacy
                next.stockNumbers.removeValue(forKey: "ulog:" + raw)
            }
        }
        guard next.stockNumbers != state.stockNumbers else { return }
        do { try save(next) } catch { errorMessage = "Migration des numéros non enregistrée : \(error.localizedDescription)" }
    }
    private func save(_ next: DroneAnnotationState) throws {
        guard canWrite, canMutate() else { throw DroneAnnotationError.invalid("La bibliothèque est occupée ou en lecture seule ; attendez la fin de l’opération ou fermez l’autre instance.") }
        guard !loadFailed else { throw DroneAnnotationError.invalid("Le fichier d’annotations illisible est conservé. Corrigez-le avant d’enregistrer de nouvelles annotations.") }
        guard (try? Data(contentsOf: url)) == persisted else { throw DroneAnnotationError.invalid("Les annotations ont changé dans un autre processus. Rechargez-les avant de modifier.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try data.write(to: url, options: .atomic)
        persisted = data; errorMessage = nil; state = next
    }
    private func shortIdentity(_ value: String) -> String { value.count > 18 ? "\(value.prefix(8))…\(value.suffix(6))" : value }
}
