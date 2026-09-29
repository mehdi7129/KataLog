import Foundation

/// Local annotations never replace controller identities or the raw ULog name.
public struct DroneAnnotationState: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var stockNumbers: [String: String] = [:]
    public var familyOverrides: [String: String] = [:]
    public init() {}

    public static func observedGCSLinks(in logs: [FlightLog]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for log in logs {
            if log.metadata["gcsIdentityStatus"] != "rejected", let uuid = log.metadata["gcsUUID"], GCSIdentity.isValid(uuid) {
                result[log.droneID, default: []].insert(uuid.uppercased())
            }
        }
        return result
    }
    public func applying(to snapshot: FleetSnapshot) -> FleetSnapshot {
        var result = snapshot
        let links = Self.observedGCSLinks(in: snapshot.logs)
        result.logs = snapshot.logs.map { project($0, links: links) }
        return result
    }
    public func familyOverride(for message: LogMessage) -> String? {
        familyOverrides[message.classificationKey] ?? familyOverrides[message.groupKey]
    }
    public func applying(to log: FlightLog, relatedLogs: [FlightLog] = []) -> FlightLog {
        project(log, links: Self.observedGCSLinks(in: relatedLogs + [log]))
    }
    private func project(_ log: FlightLog, links: [String: Set<String>]) -> FlightLog {
        var result = log
        result.annotationGCSUUID = nil
        result.annotationWarning = nil
        let observed = links[log.droneID] ?? []
        let canPropagate = log.metadata["gcsIdentityStatus"] != "rejected"
        if !canPropagate { result.annotationWarning = "Identité GCS rejetée dans ce log : aucune liaison déduite des autres enregistrements." }
        else if observed.count == 1 { result.annotationGCSUUID = observed.first }
        else if observed.count > 1 {
            result.annotationWarning = "Plusieurs identités GCS sont observées pour ce contrôleur ULog. Les logs sans preuve directe restent séparés."
        }
        let canonical = stockNumbers[result.annotationKey]
        let legacy = stockNumbers["ulog:" + log.droneID]
        result.stockNumber = canonical ?? (canPropagate && observed.count == 1 ? legacy : nil)
        if canPropagate && observed.count == 1, let canonical, let legacy, canonical != legacy {
            result.annotationWarning = "Numéros locaux en conflit : GCS \(canonical), ULog \(legacy). Le numéro GCS est affiché ; les deux annotations sont conservées jusqu’à modification."
        }
        result.messages = log.messages.map { message in
            var annotated = message
            let original = message.sourceFamily ?? message.family
            let override = familyOverride(for: message)
            annotated.sourceFamily = override == nil ? nil : original
            annotated.family = override ?? original
            return annotated
        }
        return result
    }

}

public enum DroneAnnotationValidation {
    public static func stockNumber(_ value: String?) throws -> String? {
        try normalized(value, maximum: 32, label: "Le numéro")
    }
    public static func family(_ value: String?) throws -> String? {
        try normalized(value, maximum: 48, label: "La famille")
    }
    public static func isValidKey(_ key: String) -> Bool {
        if key.hasPrefix("gcs:") { let uuid = String(key.dropFirst(4)); return GCSIdentity.isValid(uuid) && uuid == uuid.uppercased() }
        return key.hasPrefix("ulog:") && key.count > 5 && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func normalized(_ value: String?, maximum: Int, label: String) throws -> String? {
        guard let value else { return nil }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DroneAnnotationError.invalid("\(label) ne doit pas contenir de retour à la ligne ni de caractère de contrôle.")
        }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= maximum else { throw DroneAnnotationError.invalid("\(label) est limité à \(maximum) caractères.") }
        return result.isEmpty ? nil : result
    }
}

public enum DroneAnnotationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}
