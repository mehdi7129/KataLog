import Foundation

public enum GCSIdentity {
    public static func isValid(_ uuid: String) -> Bool {
        uuid.count == 24 && uuid.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
            && uuid.contains(where: { $0 != "0" }) && uuid.uppercased().contains(where: { $0 != "F" })
    }
}

public struct GCSDrone: Decodable, Identifiable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public let battery: Double?
    public let rssi: Int?
    public let firmware: String
    public let armed: Bool?
    public let timeUsec: Double?
    public var lastSeen: Date
    public var isOnline: Bool { Date().timeIntervalSince(lastSeen) < 10 }

    enum CodingKeys: String, CodingKey {
        case uuid, battery = "battery_status", rssi = "rssi_wifi", arming = "arming_state"
        case major = "fw_major", minor = "fw_minor", patch = "fw_patch"
        case timeUsec = "time_usec"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid).uppercased()
        guard GCSIdentity.isValid(uuid) else { throw DecodingError.dataCorruptedError(forKey: .uuid, in: c, debugDescription: "UUID GCS invalide") }
        let rawBattery = try c.decodeIfPresent(Double.self, forKey: .battery)
        battery = rawBattery.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        let signal = try c.decodeIfPresent(Double.self, forKey: .rssi)
        rssi = signal.flatMap { $0.isFinite && (-150...0).contains($0) ? Int($0) : nil }
        if let state = try c.decodeIfPresent(Double.self, forKey: .arming) {
            armed = state == 2 ? true : (state == 1 ? false : nil)
        } else { armed = nil }
        timeUsec = try c.decodeIfPresent(Double.self, forKey: .timeUsec).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let rawParts = [try c.decodeIfPresent(Double.self, forKey: .major), try c.decodeIfPresent(Double.self, forKey: .minor), try c.decodeIfPresent(Double.self, forKey: .patch)]
        let parts = rawParts.map { $0.flatMap { $0.isFinite && (0...65_535).contains($0) && $0.rounded() == $0 ? Int($0) : nil } }
        firmware = parts.allSatisfy { $0 != nil } ? parts.compactMap { $0 }.map(String.init).joined(separator: ".") : "Non communiqué"
        lastSeen = Date()
    }
}

public struct GCSLogFile: Decodable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public var isDownloaded: Bool = false
    public var filename: String { (path as NSString).lastPathComponent }
    public var dateFolder: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    public var localPath: String?
    public var sha256: String?
    enum CodingKeys: String, CodingKey { case path, size, isDownloaded, localPath, sha256 }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        size = try c.decode(Int64.self, forKey: .size)
        isDownloaded = try c.decodeIfPresent(Bool.self, forKey: .isDownloaded) ?? false
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
    }
    public init(path: String, size: Int64, isDownloaded: Bool = false) {
        self.path = path; self.size = size; self.isDownloaded = isDownloaded
    }
}

/// Known values are used for behavior, while persisted transfers keep their raw
/// strings so an unknown legacy/future value is never rewritten or rejected.
enum GCSTransferState: String, CaseIterable, Sendable {
    case queued, retrying, downloading, importing, downloaded, complete, failed, interrupted, stopped

    enum Category: Sendable { case pending, active, successful, failed, stopped }
    var category: Category {
        switch self {
        case .queued, .retrying: .pending
        case .downloading, .importing: .active
        case .downloaded, .complete: .successful
        case .failed, .interrupted: .failed
        case .stopped: .stopped
        }
    }
}

enum GCSTransferPhase: String, CaseIterable, Sendable {
    case drone, http, verification, verified, importing = "import"

    var acceptsDroneProgress: Bool {
        switch self {
        case .drone: true
        case .http, .verification, .verified, .importing: false
        }
    }
}

public struct GCSTransfer: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public let droneUUID: String
    public let remotePath: String
    public let size: Int64
    public var host: String
    /// First endpoint used before an explicit connection change; history stays intact.
    public var originalHost: String?
    public let destination: String
    public var completedBytes: Int64 = 0
    public var state: String = GCSTransferState.queued.rawValue
    public var error: String?
    public var localPath: String?
    public var sha256: String?
    // Optional backing fields preserve decoding of v0.2 queues.
    public var batchID: String?
    /// Import destination captured when enqueued; nil legacy jobs remain unassigned.
    public var clientID: String?
    /// Explicit requests precede bulk jobs without moving active array entries.
    public var manualPriority: Bool?
    public var attempts: Int?
    public var nextRetryAt: Date?
    public var remoteBusyUntil: Date?
    /// Phase bytes describe one transport; completedBytes only counts the copy received on this Mac.
    public var phase: String?
    public var phaseBytes: Int64?
    public var phaseTotal: Int64?
    public var attemptCount: Int { get { attempts ?? 0 } set { attempts = newValue } }
    var stateCategory: GCSTransferState.Category? { GCSTransferState(rawValue: state)?.category }
    var knownPhase: GCSTransferPhase? { phase.flatMap(GCSTransferPhase.init(rawValue:)) }
    public var isPending: Bool { stateCategory == .pending }
    public var isActive: Bool { stateCategory == .active }
    public var isSuccessful: Bool { stateCategory == .successful }
    public var isRetryable: Bool { stateCategory == .failed || stateCategory == .stopped }
    public var progress: Double { size > 0 ? min(1, max(0, Double(completedBytes) / Double(size))) : 0 }
    /// Overall collection work, distinct from the bytes received on this Mac.
    /// Drone → GCS and GCS → Mac each contribute half; 100% requires success.
    public var workFraction: Double {
        if isSuccessful { return 1 }
        guard !isPending, size > 0 else { return 0 }
        let fraction: Double
        switch knownPhase {
        case .drone: fraction = 0.5 * (phaseProgress ?? 0)
        case .http: fraction = 0.5 + 0.5 * progress
        default: fraction = progress // Queues/collectors predating transport phases.
        }
        return min(0.99, max(0, fraction))
    }
    public var phaseProgress: Double? {
        guard let total = phaseTotal, total > 0, let bytes = phaseBytes else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }
    public mutating func receiveProgress(phase incomingPhase: String?, bytes: Int64, total: Int64?) {
        // Legacy collectors reported a single transport. New collectors always identify it.
        let incoming = GCSTransferPhase(rawValue: incomingPhase ?? GCSTransferPhase.http.rawValue)
        guard incoming == .drone || incoming == .http else { return }
        // A delayed drone event cannot rewind an HTTP/verification phase.
        if incoming == .drone, knownPhase?.acceptsDroneProgress == false { return }
        if phase != incomingPhase { phaseBytes = 0 }
        // Keep legacy, unphased collectors on their original 0–100% scale.
        phase = incomingPhase
        phaseTotal = max(0, total ?? size)
        phaseBytes = min(phaseTotal ?? size, max(phaseBytes ?? 0, max(0, bytes)))
        if incoming == .http { completedBytes = min(max(0, size), max(completedBytes, max(0, bytes))) }
    }
    public var filename: String { (remotePath as NSString).lastPathComponent }
    public init(droneUUID: String, remotePath: String, size: Int64, host: String, destination: String) {
        self.droneUUID = droneUUID; self.remotePath = remotePath; self.size = size
        self.host = host; self.destination = destination
    }
    public mutating func recoverAfterRelaunch() {
        if isPending || isActive {
            state = GCSTransferState.interrupted.rawValue
            error = "Collecte interrompue. Réessayez pour vérifier le fichier local et reprendre la file."
        }
    }
    public mutating func retargetPending(to host: String) {
        guard isPending, self.host != host else { return }
        if originalHost == nil { originalHost = self.host }
        self.host = host
    }
}

public struct GCSCollectorEvent: Decodable, Sendable {
    public let event: String
    public let connected: Bool?
    public let drones: [GCSDrone]?
    public let uuid: String?
    public let files: [GCSLogFile]?
    public let path: String?
    public let bytes: Int64?
    public let total: Int64?
    public let localPath: String?
    public let sha256: String?
    public let message: String?
    public let cached: Bool?
    public let retryable: Bool?
    public let timeoutSeconds: Double?
    public let phase: String?
    public let inventoryID: String?
    public let pageIndex: Int?
    public let totalFiles: Int?
    public let completedFiles: Int?
    public let pageCount: Int?
}

public struct GCSCollectionState: Codable, Sendable {
    public var collectionClientID: String?
    public var concurrentDownloads: Int?
    /// Zero means retry transient network failures until stopped by the user.
    public var retryLimit: Int?

    public var schemaVersion = 1
    public var host = ""
    public var allowedUUIDs: Set<String> = []
    public var downloadDirectory: String
    public var autoImport = true
    public var reconnect = false
    public var queue: [GCSTransfer] = []
    public var currentBatchID: String?
    public var cachedFileCount: Int?
    /// Available files in the selected drone's destination preview, before scheduling a collection.
    public var destinationPreviewFileCount: Int?
    public var queuePaused: Bool?
    public var inventoryBusyUntil: [String: Date]?
    public var expectedInventoryUUIDs: Set<String>?
    public var completedInventoryUUIDs: Set<String>?
    public var inventoryFailures: [String: String]?
    public var cachedFileIdentities: Set<String>?
    public var queueStorageVersion: Int?
    public init(downloadDirectory: String) { self.downloadDirectory = downloadDirectory }
}

/// Progress covers one collection, including failed/stopped work in the denominator.
/// Virtual work and actual Mac bytes are separate; only successful files reach 100%.
public struct GCSBatchProgress: Sendable {
    public let fraction: Double
    public let completedCount: Int
    public let totalCount: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    /// Size-weighted collection work; these are not downloaded bytes.
    public let completedWorkBytes: Double
    public let failedCount: Int
    public let activeCount: Int
    public let pendingCount: Int
    public let stoppedCount: Int
    public init(totalCount: Int, completedCount: Int, failedCount: Int, activeCount: Int, pendingCount: Int, stoppedCount: Int, totalBytes: Int64, completedBytes: Int64,
                completedWorkBytes: Double? = nil, totalWorkBytes: Double? = nil) {
        self.totalCount = max(0, totalCount); self.completedCount = max(0, completedCount)
        self.failedCount = max(0, failedCount); self.activeCount = max(0, activeCount)
        self.pendingCount = max(0, pendingCount); self.stoppedCount = max(0, stoppedCount)
        self.totalBytes = max(0, totalBytes); self.completedBytes = min(self.totalBytes, max(0, completedBytes))
        let workTotal = GCSProgressMath.boundedWork(totalWorkBytes ?? Double(self.totalBytes))
        self.completedWorkBytes = min(workTotal, GCSProgressMath.boundedWork(completedWorkBytes ?? Double(self.completedBytes)))
        if self.totalCount == 0 { fraction = 0 }
        else if self.completedCount == self.totalCount { fraction = 1 }
        else { fraction = workTotal > 0 ? min(0.99, self.completedWorkBytes / workTotal) : 0 }
    }
    public init(transfers: [GCSTransfer]) {
        let workTotal = transfers.reduce(0.0) { $0 + Double(max(0, $1.size)) }
        let macBytes = transfers.reduce(0.0) { $0 + Double(min(max(0, $1.size), max(0, $1.completedBytes))) }
        let completedWork = transfers.reduce(0.0) { $0 + Double(max(0, $1.size)) * $1.workFraction }
        self.init(totalCount: transfers.count,
                  completedCount: transfers.filter(\.isSuccessful).count,
                  failedCount: transfers.filter { $0.stateCategory == .failed }.count,
                  activeCount: transfers.filter(\.isActive).count,
                  pendingCount: transfers.filter(\.isPending).count,
                  stoppedCount: transfers.filter { $0.stateCategory == .stopped }.count,
                  totalBytes: GCSProgressMath.boundedInteger(workTotal), completedBytes: GCSProgressMath.boundedInteger(macBytes),
                  completedWorkBytes: completedWork, totalWorkBytes: workTotal)
    }
}

enum GCSProgressMath {
    static func boundedWork(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    static func boundedInteger(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(Int64.max) ? Int64.max : Int64(value)
    }
}

/// Pure scheduling rules shared by UI orchestration and regression tests.
public enum GCSQueuePolicy {
    public static let maxAttempts = 3
    public static let maxConcurrentDownloads = 2
    public static let concurrentDownloadRange = 1...4
    public static func retryDate(attempt: Int, limit: Int = 0, now: Date = Date()) -> Date? {
        guard limit <= 0 || attempt < limit else { return nil }
        // Bounded backoff keeps overnight retries useful without flooding the GCS.
        let delay: TimeInterval = attempt <= 1 ? 5 : attempt == 2 ? 15 : attempt == 3 ? 30 : 60
        return now.addingTimeInterval(delay)
    }
    public static func nextJobs(queue: [GCSTransfer], activeIDs: Set<String>, availableUUIDs: Set<String>,
                                host: String, limit: Int = maxConcurrentDownloads, now: Date = Date()) -> [String] {
        var occupied = Set(queue.filter { activeIDs.contains($0.id) || ($0.remoteBusyUntil ?? .distantPast) > now }.map(\.droneUUID))
        var slots = max(0, min(concurrentDownloadRange.upperBound, max(concurrentDownloadRange.lowerBound, limit)) - activeIDs.count)
        var result: [String] = []
        for priority in [true, false] {
            for job in queue where (job.manualPriority == true) == priority && job.isPending && job.host == host && availableUUIDs.contains(job.droneUUID) {
                guard slots > 0 else { return result }
                guard !occupied.contains(job.droneUUID), (job.nextRetryAt ?? .distantPast) <= now else { continue }
                occupied.insert(job.droneUUID); slots -= 1; result.append(job.id)
            }
        }
        return result
    }
}
