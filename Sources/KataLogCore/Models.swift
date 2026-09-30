import Foundation

public struct FleetSnapshot: Codable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: String
    public var sourceFolders: [String]
    public var importStats: ImportStats
    public var logs: [FlightLog]
    public var archiveResult: JSONValue? = nil
    public static let empty = FleetSnapshot(schemaVersion: 1, generatedAt: "", sourceFolders: [], importStats: .empty, logs: [])
    public var validLogs: [FlightLog] { logs.filter { $0.status != "error" } }
    public var totalDurationSeconds: Double { validLogs.reduce(0) { $0 + $1.durationSeconds } }
    public var alertLogCount: Int { validLogs.filter(\.hasAlerts).count }
    public var failsafeLogCount: Int { validLogs.filter { $0.failsafeObserved && ($0.selectionIncludesFailsafe ?? true) }.count }
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
    public var archiveRequested: Int? = nil
    public var archiveCompleted: Int? = nil
    public var archiveReused: Int? = nil
    public var archiveFailed: Int? = nil
    public var archiveSkipped: Int? = nil
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
    public var flightObservedSeconds: Double? = nil
    public var flightCoverageSeconds: Double? = nil
    public var flightCoverageFraction: Double? = nil
    public var sourceAvailability: [SourceAvailability]? = nil
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
    public var eventDictionary: JSONValue? = nil
    public var eventCoverage: [JSONValue]? = nil
    public var metadataDetails: JSONValue? = nil
    public var telemetryCatalogue: [TelemetryField]? = nil
    public var parameterDetails: JSONValue? = nil
    public var dropouts: [JSONValue]? = nil
    public var batteryDetails: JSONValue? = nil
    public var gnssDetails: JSONValue? = nil
    public var analysisRevision: JSONValue? = nil
    public var summaryMessageCount: Int? = nil
    public var summaryAlertMessageCount: Int? = nil
    public var summaryHasAlerts: Bool? = nil
    public var selectionIncludesFailsafe: Bool? = nil
    public var hasAlerts: Bool { (summaryHasAlerts ?? messages.contains(where: \.isAlert)) || (failsafeObserved && (selectionIncludesFailsafe ?? true)) }
}

public struct SourceAvailability: Codable, Identifiable, Sendable {
    public var path: String
    public var state: String
    public var checkedAt: String
    public var detail: String?
    public var id: String { path }
    public var label: String {
        switch state {
        case "present": "Source vérifiée"
        case "missing": "Source absente"
        case "offline": "Volume hors ligne"
        case "inaccessible": "Source inaccessible"
        case "modified": "Contenu modifié"
        default: "Disponibilité non vérifiée"
        }
    }
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
    public var isMasked: Bool? = nil
    public var source: String? = nil
    public var tag: Int? = nil
    public var rawTimestamp: JSONValue? = nil
    public var rawLogLevel: JSONValue? = nil
    public var sourceIndex: Int? = nil
    enum CodingKeys: String, CodingKey {
        case id, timestampSeconds, level, text, family, sourceFamily, groupKey, title, position, isMasked, source, tag, rawTimestamp, rawLogLevel, sourceIndex
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
    public var topic: String? = nil
    public var field: String? = nil
    public var instance: Int? = nil
    public var type: String? = nil
    public var rawUnit: String? = nil
    public var unitSource: String? = nil
    public var unitStatus: String? = nil
    public var scale: Double? = nil
    public var sourceConversion: String? = nil
    public var interpolation: String? = nil
    public var strategy: String? = nil
    public var pointBudget: Int? = nil
    public var gapSeconds: Double? = nil
    public var windowFrom: Double? = nil
    public var windowTo: Double? = nil
    public var windowSampleCount: Int? = nil
    public var validSampleCount: Int? = nil
    public var rejectedSampleCount: Int? = nil
    public var outsideWindowSampleCount: Int? = nil
    public var displayedPointCount: Int? = nil
    public var segmentCount: Int? = nil
    public var displayedSegmentCount: Int? = nil
    public var omittedSegmentCount: Int? = nil
    public var omittedSegmentSampleCount: Int? = nil
    public var omittedTransitionCount: Int? = nil
    public var omittedExtremaCount: Int? = nil
    public var timeReversalCount: Int? = nil
    public var longGapCount: Int? = nil
    public var nonfiniteValueCount: Int? = nil
    public var invalidTimestampCount: Int? = nil
    public var precisionRejectedCount: Int? = nil
    public var sentinelRejectedCount: Int? = nil
    public var completeWindow: Bool? = nil
    public var coverage: JSONValue? = nil
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
    public var eventID: JSONValue
    public var timeSeconds: Double?
    public var level: String
    public var message: String?
    public var argumentsHex: String
    public var definitionSource: String?
    public var topic: String? = nil
    public var instance: Int? = nil
    public var sourceIndex: Int? = nil
    public var rawTimestamp: JSONValue? = nil
    public var sequence: Int? = nil
    public var logLevels: Int? = nil
    public var internalLevel: Int? = nil
    public var externalLevel: Int? = nil
    public var internalLevelName: String? = nil
    public var externalLevelName: String? = nil
    public var translationStatus: String? = nil
    public var description: String? = nil
    public var argumentValues: [JSONValue]? = nil
    public var rawArguments: JSONValue? = nil
    public var invalidReason: String? = nil
    public var eventName: String? = nil
    public var group: String? = nil
    public var namespace: String? = nil
    public var reference: String? = nil
}

public struct TelemetryField: Codable, Identifiable, Sendable {
    public var key: String
    public var topic: String
    public var instance: Int
    public var field: String
    public var type: String
    public var sampleCount: Int
    public var numeric: Bool
    public var extractable: Bool
    public var rawUnit: String
    public var unit: String
    public var scale: Double
    public var unitSource: String?
    public var unitStatus: String
    public var sentinelPolicy: String?
    public var interpolation: String
    public var id: String { key }
}

public struct TelemetryRecipe: Codable, Sendable {
    public var schemaVersion: Int
    public var recipe: String
    public var instance: Int
    public var series: [TelemetrySeries]
    public var missingFields: [String]
    public var pointBudget: Int
    public var displayedPointCount: Int
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
