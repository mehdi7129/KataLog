import Foundation

/// Personal context belongs to the local library, never to the ULog source.
public struct PersonalNote: Codable, Equatable, Sendable {
    public var text: String
    public var createdAt: String
    public var updatedAt: String
    public init(text: String, createdAt: String, updatedAt: String) {
        self.text = text; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Local annotations never replace controller identities or the raw ULog name.
public struct DroneAnnotationState: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var stockNumbers: [String: String] = [:]
    public var familyOverrides: [String: String] = [:]
    public var logNotes: [String: PersonalNote] = [:]
    public var droneNotes: [String: PersonalNote] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, stockNumbers, familyOverrides, logNotes, droneNotes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        stockNumbers = try values.decodeIfPresent([String: String].self, forKey: .stockNumbers) ?? [:]
        familyOverrides = try values.decodeIfPresent([String: String].self, forKey: .familyOverrides) ?? [:]
        logNotes = try values.decodeIfPresent([String: PersonalNote].self, forKey: .logNotes) ?? [:]
        droneNotes = try values.decodeIfPresent([String: PersonalNote].self, forKey: .droneNotes) ?? [:]
    }

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
        result.personalNote = logNotes[log.id]
        result.droneNote = droneNotes[result.annotationKey] ?? (canPropagate && observed.count == 1 ? droneNotes["ulog:" + log.droneID] : nil)
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
    public static let maximumNoteLength = 4_000
    public static func note(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let result = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw DroneAnnotationError.invalid("La note contient un caractère de contrôle invalide.")
        }
        guard result.count <= maximumNoteLength, result.utf8.count <= 64 * 1024 else { throw DroneAnnotationError.invalid("La note est limitée à \(maximumNoteLength) caractères.") }
        return result.isEmpty ? nil : result
    }
    public static func isValidLogKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 256 && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    public static func validate(_ value: PersonalNote) throws {
        let formatter = ISO8601DateFormatter()
        guard try note(value.text) == value.text,
              let created = formatter.date(from: value.createdAt), let updated = formatter.date(from: value.updatedAt), updated >= created else {
            throw DroneAnnotationError.invalid("Texte ou dates de note invalides.")
        }
    }
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
