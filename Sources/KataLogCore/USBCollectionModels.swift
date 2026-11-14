import Foundation

public struct USBSerialPort: Codable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let label: String
}

public struct USBLogDevice: Codable, Equatable, Sendable {
    public let identity: String
    public let systemID: Int
    public let componentID: Int
    public let label: String
}

public struct USBLogEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let timeUTC: Int64
    public let size: Int64
    public var filename: String { "log-\(id)-\(timeUTC).ulg" }
}

public struct USBLogTransfer: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public let device: USBLogDevice
    public let log: USBLogEntry
    public let destination: String
    /// Captured at enqueue; absent legacy attribution means unassigned, never the current UI client.
    public var clientID: String?
    public var state = "queued"
    public var bytes: Int64 = 0
    public var localPath: String?
    public var sha256: String?
    public var error: String?
    public init(device: USBLogDevice, log: USBLogEntry, destination: String, clientID: String? = nil) {
        self.device = device; self.log = log; self.destination = destination; self.clientID = clientID
    }
    public var isActive: Bool { state == "downloading" || state == "importing" }
    public var isSuccessful: Bool { state == "complete" || state == "downloaded" }
    public var progress: Double { log.size > 0 ? min(1, max(0, Double(bytes) / Double(log.size))) : 0 }
}

public struct USBCollectionState: Codable, Sendable {
    public var schemaVersion = 1
    public var queue: [USBLogTransfer] = []
    public init() {}
}
