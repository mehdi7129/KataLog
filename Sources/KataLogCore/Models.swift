import Foundation

public struct FleetSnapshot: Codable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: String
    public var sourceFolders: [String]
    public var importStats: ImportStats
    public var logs: [FlightLog]
    public static let empty = FleetSnapshot(schemaVersion: 1, generatedAt: "", sourceFolders: [], importStats: .empty, logs: [])
    public var validLogs: [FlightLog] { logs.filter { $0.status != "error" } }
    public var totalDurationSeconds: Double { validLogs.reduce(0) { $0 + $1.durationSeconds } }
    public var alertLogCount: Int { validLogs.filter { $0.messages.contains(where: \.isAlert) || $0.failsafeObserved }.count }
    public var failsafeLogCount: Int { validLogs.filter(\.failsafeObserved).count }
    public var alertGroups: [AlertGroup] {
        let occurrences = logs.flatMap { log in log.messages.map { MessageOccurrence(log: log, message: $0) } }
        return Dictionary(grouping: occurrences, by: { $0.message.groupKey }).map { key, values in
            AlertGroup(id: key, occurrences: values.sorted { ($0.date, $0.message.timestampSeconds, $0.id) < ($1.date, $1.message.timestampSeconds, $1.id) })
        }.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.logCount != b.logCount { return a.logCount > b.logCount }
            return a.id < b.id
        }
    }
    public var drones: [DroneSummary] {
        Dictionary(grouping: logs, by: \.droneID).map { id, logs in
            DroneSummary(id: id, name: logs.last?.displayName ?? id, logs: logs.sorted { $0.date < $1.date })
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

public struct ImportStats: Codable, Sendable {
    public var discovered: Int
    public var imported: Int
    public var unchanged: Int
    public var duplicates: Int
    public var failed: Int
    public var reanalyzed: Int? = nil
    public static let empty = ImportStats(discovered: 0, imported: 0, unchanged: 0, duplicates: 0, failed: 0)
}

public struct FlightLog: Codable, Identifiable, Sendable {
    public var id: String
    public var droneID: String
    public var droneName: String
    public var stockNumber: String? = nil
    /// Local linkage derived from unique observed metadata, never written into source metadata.
    public var annotationGCSUUID: String? = nil
    public var annotationWarning: String? = nil
    public var displayName: String { stockNumber.map { "Drone " + $0 } ?? droneName }
    public var annotationKey: String {
        if metadata["gcsIdentityStatus"] != "rejected", let uuid = metadata["gcsUUID"], GCSIdentity.isValid(uuid) { return "gcs:" + uuid.uppercased() }
        if metadata["gcsIdentityStatus"] != "rejected", let uuid = annotationGCSUUID, GCSIdentity.isValid(uuid) { return "gcs:" + uuid.uppercased() }
        return "ulog:" + droneID
    }
    public var date: String
    public var dateSource: String
    public var sourcePaths: [String]
    public var fileName: String
    public var sizeBytes: Int64
    public var durationSeconds: Double
    public var flightSeconds: Double?
    public var status: String
    public var issues: [String]
    public var metadata: [String: String]
    public var topics: [String]
    public var messages: [LogMessage]
    public var metrics: [LogMetric]
    public var coverage: [String]
    public var failsafeObserved: Bool
    public var track: FlightTrack? = nil
    public var telemetry: [TelemetrySeries]? = nil
    public var topicDetails: [TopicDetail]? = nil
    public var parameters: [String: String]? = nil
    public var parameterChanges: [ParameterChange]? = nil
    public var events: [PX4Event]? = nil
    public var hasAlerts: Bool { messages.contains(where: \.isAlert) || failsafeObserved }
}

public struct LogMessage: Codable, Identifiable, Sendable {
    public var id: String
    public var timestampSeconds: Double
    public var level: String
    public var text: String
    public var family: String
    public var sourceFamily: String? = nil
    public var groupKey: String
    public var title: String
    public var alertFlag: Bool?
    public var position: TrackPoint? = nil
    enum CodingKeys: String, CodingKey {
        case id, timestampSeconds, level, text, family, sourceFamily, groupKey, title, position
        case alertFlag = "isAlert"
    }
    /// Same whitespace normalization as the importer; independent of automatic family rules.
    public var classificationKey: String {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "text-v1:\(level.utf8.count):\(level)\(normalized)"
    }
    public var priority: Int { Self.rank(level) }
    public var isAlert: Bool { alertFlag ?? (priority >= 4 || text.uppercased().contains("[ALARM]") || text.lowercased().contains("failsafe activated")) }
    public static func rank(_ level: String) -> Int {
        switch level { case "EMERGENCY": 8; case "ALERT": 7; case "CRITICAL": 6; case "ERROR": 5; case "WARNING", "WARN": 4; case "NOTICE": 3; case "INFO": 2; case "DEBUG": 1; default: 0 }
    }
}

public struct FlightTrack: Codable, Sendable {
    public var source: String
    public var originalPointCount: Int
    public var rejectedPointCount: Int
    public var points: [TrackPoint]
}

public struct TrackPoint: Codable, Identifiable, Sendable {
    public var timeSeconds: Double
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double?
    public var segment: Int
    public var id: String { "\(segment):\(timeSeconds)" }
    public var hasValidCoordinate: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct TelemetrySeries: Codable, Identifiable, Sendable {
    public var key: String
    public var label: String
    public var unit: String
    public var source: String
    public var originalSampleCount: Int
    public var points: [TelemetryPoint]
    public var id: String { key }
}

public struct TelemetryPoint: Codable, Identifiable, Sendable {
    public var timeSeconds: Double
    public var value: Double
    public var segment: Int
    public var id: String { "\(segment):\(timeSeconds)" }
}

public struct TopicDetail: Codable, Identifiable, Sendable {
    public var name: String
    public var instance: Int
    public var sampleCount: Int
    public var fields: [String]
    public var fieldUnits: [String: String]? = nil
    public var id: String { "\(name):\(instance)" }
}

public struct ParameterChange: Codable, Identifiable, Sendable {
    public var timeSeconds: Double
    public var name: String
    public var value: String
    public var id: String { "\(timeSeconds):\(name):\(value)" }
}

public struct PX4Event: Codable, Identifiable, Sendable {
    public var id: String
    public var eventID: Int
    public var timeSeconds: Double
    public var level: String
    public var message: String?
    public var argumentsHex: String
    public var definitionSource: String?
}

public struct LogMetric: Codable, Identifiable, Sendable {
    public var key: String
    public var label: String
    public var value: Double
    public var unit: String
    public var detail: String
    public var id: String { key }
}

public struct ImportProgress: Codable, Sendable {
    public var completed: Int
    public var total: Int
    public var current: String
}

public struct MessageOccurrence: Identifiable, Sendable {
    public let logID: String
    public let droneID: String
    public let droneName: String
    public let date: String
    public let sourcePaths: [String]
    public let message: LogMessage
    public var id: String { logID + ":" + message.id }
    public init(log: FlightLog, message: LogMessage) {
        self.logID = log.id; self.droneID = log.droneID; self.droneName = log.displayName
        self.date = log.date; self.sourcePaths = log.sourcePaths; self.message = message
    }
}

public struct AlertGroup: Identifiable, Sendable {
    public let id: String
    public let occurrences: [MessageOccurrence]
    public init(id: String, occurrences: [MessageOccurrence]) { self.id = id; self.occurrences = occurrences }
    public var title: String { occurrences.first?.message.title ?? "Message" }
    public var family: String { occurrences.first?.message.family ?? "Autres" }
    public var level: String { occurrences.max { $0.message.priority < $1.message.priority }?.message.level ?? "INFO" }
    public var priority: Int { LogMessage.rank(level) }
    public var messageCount: Int { occurrences.count }
    public var logCount: Int { Set(occurrences.map(\.logID)).count }
    public var droneIDs: Set<String> { Set(occurrences.map(\.droneID)) }
    public var firstDate: String { occurrences.map(\.date).min() ?? "" }
    public var lastDate: String { occurrences.map(\.date).max() ?? "" }
    public var isAlert: Bool { occurrences.contains { $0.message.isAlert } }
}

public struct DroneSummary: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let logs: [FlightLog]
    public var totalDurationSeconds: Double { logs.reduce(0) { $0 + $1.durationSeconds } }
    public var alertLogCount: Int { logs.filter(\.hasAlerts).count }
}
