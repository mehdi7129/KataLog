import Foundation

public struct LibraryQueryRequest: Codable, Sendable {
    public var queryVersion = 1
    public var kind: String
    public var scope: SelectionScope
    public var limit = 200
    public var cursor: String? = nil
    public var annotations: DroneAnnotationState
    public var maskedMessageKeys: [String]
    public var groupID: String? = nil
    public var includeMessages = false
    public var registrySearch: String? = nil
    public var sortOrder = "recent"
    public var eventLevelSource = "internal"
    public var eventLevels: [String] = []
    public var eventSearch = ""
    public init(kind: String = "logs", scope: SelectionScope = .init(), annotations: DroneAnnotationState = .init(), maskedMessageKeys: [String] = []) {
        self.kind = kind; self.scope = scope; self.annotations = annotations; self.maskedMessageKeys = maskedMessageKeys
    }
}

public struct LibraryTotals: Codable, Sendable {
    public var logs: Int
    public var validLogs: Int
    public var messages: Int
    public var alertLogs: Int
    public var failsafeLogs: Int
    public var recordedSeconds: Double
    public var droneCount: Int
    public var familyLogCounts: [String: Int]
    public var groupCount: Int
    public var staleAnalysisLogs: Int? = nil
    public var libraryStaleAnalysisLogs: Int? = nil
    public var scannedDroneCount: Int? = nil
    public var provisionalDroneCount: Int? = nil
    public var flightSeconds: Double? = nil
    public var flightLogCount: Int? = nil
}

public struct LibraryDrone: Codable, Identifiable, Sendable {
    public var id: String
    public var droneID: String
    public var name: String
    public var stockNumber: String?
    public var gcsUUID: String?
    public var logCount: Int
    public var lastDate: String
    public var recordedSeconds: Double
    public var alertLogCount: Int
    public var sourceStatus: String
    public var lastGCSDate: String? = nil
    public var lastGCSSource: String? = nil
    public var sourceCheckedAt: String? = nil
    public var displayName: String { stockNumber.map { "Drone " + $0 } ?? name }
}

public protocol LibraryPageContract { var queryVersion: Int { get } }

public struct LibraryCataloguePage: Codable, Sendable, LibraryPageContract {
    public var queryVersion: Int
    public var revision: Int
    public var scopeHash: String
    public var families: [String]
    public var levels: [String]
    public var total: Int
    public var nextCursor: String?
}

public struct LibraryEventCoverage: Codable, Sendable {
    public var selectedLogs: Int
    public var cachedLogs: Int
    public var unavailableLogs: Int
    public var legacyCacheLogs: Int
    public var invalidCacheLogs: Int
    public var eventLogs: Int
    public var translatedLogs: Int
    public var previousParserLogs: Int
}

public struct LibraryEventOccurrence: Codable, Identifiable, Sendable {
    public var logID: String
    public var droneID: String
    public var droneName: String
    public var date: String
    public var sourcePaths: [String]
    public var event: PX4Event
    public var id: String { logID + ":" + event.id }
}

public struct LibraryEventPage: Codable, Sendable, LibraryPageContract {
    public var queryVersion: Int
    public var revision: Int
    public var scopeHash: String
    public var occurrences: [LibraryEventOccurrence]
    public var coverage: LibraryEventCoverage
    public var total: Int
    public var nextCursor: String?
}

public struct LibraryDronePage: Codable, Sendable, LibraryPageContract {
    public var queryVersion: Int
    public var revision: Int
    public var scopeHash: String
    public var drones: [LibraryDrone]
    public var total: Int
    public var nextCursor: String?
    public var registryObservationRevision: String? = nil
}

public struct LibraryLogPage: Codable, Sendable, LibraryPageContract {
    public var queryVersion: Int
    public var revision: Int
    public var scopeHash: String
    public var snapshot: FleetSnapshot
    public var totals: LibraryTotals
    public var nextCursor: String?
}

public struct LibraryGroup: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var family: String
    public var level: String
    public var priority: Int
    public var messageCount: Int
    public var logCount: Int
    public var droneCount: Int
    public var firstDate: String
    public var lastDate: String
    public var classKeys: [String]? = nil
    public var classKeyCount: Int? = nil
    public var classKeysComplete: Bool? = nil
}

public struct LibraryGroupPage: Codable, Sendable, LibraryPageContract {
    public var queryVersion: Int
    public var revision: Int
    public var scopeHash: String
    public var groups: [LibraryGroup]
    public var total: Int
    public var nextCursor: String?
}

public struct LibraryOccurrence: Codable, Identifiable, Sendable {
    public var logID: String
    public var droneID: String
    public var droneName: String
    public var date: String
    public var sourcePaths: [String]
    public var message: LogMessage
    public var id: String { logID + ":" + message.id }
}

public struct LibraryMessagePage: Codable, Sendable, LibraryPageContract {
    public var queryVersion: Int
    public var revision: Int
    public var scopeHash: String
    public var occurrences: [LibraryOccurrence]
    public var total: Int
    public var nextCursor: String?
}

public enum LibraryQueryService {
    public static func page<T: Decodable & Sendable>(_ type: T.Type, request: LibraryQueryRequest, database: URL, engine: URL, readOnly: Bool = false) async throws -> T {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var command = ["query", "--database", database.path]
        if readOnly { command.append("--read-only") }
        let data = try await AnalysisService.run(command, engine: engine, request: encoder.encode(request))
        let page = try JSONDecoder().decode(type, from: data)
        if let contract = page as? any LibraryPageContract, contract.queryVersion != 1 { throw AnalysisError.schema(contract.queryVersion) }
        return page
    }
}
