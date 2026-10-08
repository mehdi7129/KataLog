import Foundation
import SQLite3

public struct GCSQueueHistoryPage: Sendable {
    public let transfers: [GCSTransfer]
    public let nextCursor: Int64?
}

/// Local collection storage, separate from the analysis database. All values use bound parameters.
public final class GCSQueueRepository: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    private var encoded: [String: Data] = [:]
    private let readOnly: Bool
    private let encoder: JSONEncoder
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let pendingStates = states(in: .pending)
    private static let activeStates = states(in: .active)
    private static let successfulStates = states(in: .successful)
    private static let failedStates = states(in: .failed)
    private static let stoppedStates = states(in: .stopped)
    private static let retainedStates = states(in: .pending, .active)
    private static let retryableStates = states(in: .failed, .stopped)

    /// Only closed enum constants become SQL syntax; persisted/user values are
    /// still bound parameters. Swift predicates and SQL use the same categories.
    private static func states(in categories: GCSTransferState.Category...) -> String {
        GCSTransferState.allCases.filter { categories.contains($0.category) }
            .map { "'\($0.rawValue)'" }.joined(separator: ",")
    }

    public init(url: URL, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw AnalysisError.engine("Impossible d’ouvrir la file de collecte SQLite.")
        }
        do {
            sqlite3_busy_timeout(database, 5_000)
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw AnalysisError.engine("Le format de la file de collecte est plus récent que cette app.") }
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                try execute("CREATE TABLE IF NOT EXISTS transfers (position INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, batch_id TEXT, uuid TEXT NOT NULL, remote_path TEXT NOT NULL, destination TEXT NOT NULL, size INTEGER NOT NULL, completed_bytes INTEGER NOT NULL, remote_busy_until REAL, updated_at REAL NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE INDEX IF NOT EXISTS transfers_state_position ON transfers(state, position)")
                try execute("CREATE INDEX IF NOT EXISTS transfers_batch_position ON transfers(batch_id, position)")
                try execute("CREATE INDEX IF NOT EXISTS transfers_source ON transfers(uuid,remote_path,size,destination)")
                try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS batch_cache (batch_id TEXT NOT NULL, identity TEXT NOT NULL, PRIMARY KEY(batch_id, identity))")
                try execute("PRAGMA user_version=1")
            } else if version != 1 {
                throw AnalysisError.engine("La file SQLite ne possède pas un schéma reconnu.")
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { if let database { sqlite3_close(database) } }

    public var hasMigratedLegacy: Bool {
        get throws { lock.lock(); defer { lock.unlock() }; return try scalar("SELECT COUNT(*) FROM metadata WHERE key='legacy_migrated'") == 1 }
    }

    /// The legacy JSON stays untouched; this marker and all rows commit together.
    public func migrateLegacy(_ transfers: [GCSTransfer]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly else { throw AnalysisError.engine("La file de collecte est ouverte en lecture seule.") }
        guard try scalar("SELECT COUNT(*) FROM metadata WHERE key='legacy_migrated'") == 0 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            _ = try saveTransfers(transfers)
            try execute("INSERT INTO metadata(key,value) VALUES('legacy_migrated','1')")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); encoded = [:]; throw error }
    }

    @discardableResult
    public func saveTransfers(_ transfers: [GCSTransfer]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly else { throw AnalysisError.engine("La file de collecte est ouverte en lecture seule.") }
        let ownsTransaction = sqlite3_get_autocommit(database) != 0
        if ownsTransaction { try execute("BEGIN IMMEDIATE") }
        var writes = 0
        do { for transfer in transfers {
            let payload = try encoder.encode(transfer)
            if encoded[transfer.id] == payload { continue }
            let statement = try prepare("INSERT INTO transfers(id,state,batch_id,uuid,remote_path,destination,size,completed_bytes,remote_busy_until,updated_at,payload) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,batch_id=excluded.batch_id,uuid=excluded.uuid,remote_path=excluded.remote_path,destination=excluded.destination,size=excluded.size,completed_bytes=excluded.completed_bytes,remote_busy_until=excluded.remote_busy_until,updated_at=excluded.updated_at,payload=excluded.payload")
            defer { sqlite3_finalize(statement) }
            bind(transfer.id, at: 1, to: statement); bind(transfer.state, at: 2, to: statement)
            bind(transfer.batchID, at: 3, to: statement)
            bind(transfer.droneUUID, at: 4, to: statement); bind(transfer.remotePath, at: 5, to: statement); bind(transfer.destination, at: 6, to: statement)
            sqlite3_bind_int64(statement, 7, max(0, transfer.size)); sqlite3_bind_int64(statement, 8, min(max(0, transfer.size), max(0, transfer.completedBytes)))
            if let until = transfer.remoteBusyUntil { sqlite3_bind_double(statement, 9, until.timeIntervalSince1970) }
            else { sqlite3_bind_null(statement, 9) }
            sqlite3_bind_double(statement, 10, Date().timeIntervalSince1970)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 11, $0.baseAddress, Int32($0.count), transient) }
            try step(statement); encoded[transfer.id] = payload; writes += 1
        }; if ownsTransaction { try execute("COMMIT") }
        } catch { if ownsTransaction { try? execute("ROLLBACK") }; encoded = [:]; throw error }
        return writes
    }

    /// Count the complete history without decoding the bounded UI page. Jobs
    /// created since the latest persistence pass are included exactly once.
    public func transferCount(overlay: [GCSTransfer] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*) FROM transfers")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AnalysisError.engine("Le nombre de transferts n’a pas pu être lu.") }
        var count = Int(sqlite3_column_int64(statement, 0))
        let identifiers = Array(Set(overlay.map(\.id)))
        for offset in stride(from: 0, to: identifiers.count, by: 500) {
            let batch = Array(identifiers[offset..<min(offset + 500, identifiers.count)])
            let existing = try prepare("SELECT COUNT(*) FROM transfers WHERE id IN (" + Array(repeating: "?", count: batch.count).joined(separator: ",") + ")")
            defer { sqlite3_finalize(existing) }
            for (index, id) in batch.enumerated() { bind(id, at: Int32(index + 1), to: existing) }
            guard sqlite3_step(existing) == SQLITE_ROW else { throw AnalysisError.engine("Le nombre de transferts récents n’a pas pu être lu.") }
            count += batch.count - Int(sqlite3_column_int64(existing, 0))
        }
        return count
    }

    public func retainedTransfers(terminalLimit: Int = 200) throws -> [GCSTransfer] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM transfers WHERE state IN (\(Self.retainedStates)) OR remote_busy_until > ? OR id IN (SELECT id FROM transfers WHERE state NOT IN (\(Self.retainedStates)) ORDER BY position DESC LIMIT ?) ORDER BY position")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(max(0, min(terminalLimit, 1_000))))
        return try rows(statement)
    }

    public func retryableTransfers(authorizedUUIDs: Set<String>? = nil) throws -> [GCSTransfer] {
        lock.lock(); defer { lock.unlock() }
        if authorizedUUIDs?.isEmpty == true { return [] }
        let ids = authorizedUUIDs?.sorted()
        let filter = ids.map { " AND uuid IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
        let statement = try prepare("SELECT payload FROM transfers WHERE state IN (\(Self.retryableStates))" + filter + " ORDER BY position")
        defer { sqlite3_finalize(statement) }
        for (index, id) in (ids ?? []).enumerated() { bind(id, at: Int32(index + 1), to: statement) }
        return try rows(statement)
    }

    public func retryableCount(authorizedUUIDs: Set<String>) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !authorizedUUIDs.isEmpty else { return 0 }
        let ids = authorizedUUIDs.sorted()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let statement = try prepare("SELECT COUNT(*) FROM transfers WHERE state IN (\(Self.retryableStates)) AND uuid IN (\(placeholders))")
        defer { sqlite3_finalize(statement) }
        for (index, id) in ids.enumerated() { bind(id, at: Int32(index + 1), to: statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AnalysisError.engine("Impossible de compter les fichiers à relancer.") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func historyPage(before cursor: Int64? = nil, limit: Int = 100) throws -> GCSQueueHistoryPage {
        lock.lock(); defer { lock.unlock() }
        let bounded = max(1, min(limit, 200))
        let statement = try prepare("SELECT position,payload FROM transfers WHERE (? IS NULL OR position < ?) ORDER BY position DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        if let cursor { sqlite3_bind_int64(statement, 1, cursor); sqlite3_bind_int64(statement, 2, cursor) }
        else { sqlite3_bind_null(statement, 1); sqlite3_bind_null(statement, 2) }
        sqlite3_bind_int(statement, 3, Int32(bounded + 1))
        var items: [GCSTransfer] = []; var positions: [Int64] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            positions.append(sqlite3_column_int64(statement, 0))
            items.append(try decode(statement, column: 1))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw AnalysisError.engine("Lecture de l’historique de collecte interrompue.") }
        let hasMore = items.count > bounded
        return GCSQueueHistoryPage(transfers: Array(items.prefix(bounded)), nextCursor: hasMore ? positions[bounded - 1] : nil)
    }

    public func transfer(id: String) throws -> GCSTransfer? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM transfers WHERE id=?")
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw AnalysisError.engine("Entrée de collecte illisible.") }
        return try decode(statement, column: 0)
    }

    public func matchingTransfer(uuid: String, path: String, size: Int64, destination: String) throws -> GCSTransfer? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM transfers WHERE uuid=? AND remote_path=? AND size=? AND destination=? ORDER BY position DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }; bind(uuid, at: 1, to: statement); bind(path, at: 2, to: statement)
        sqlite3_bind_int64(statement, 3, size); bind(destination, at: 4, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw AnalysisError.engine("Entrée de collecte illisible.") }
        return try decode(statement, column: 0)
    }

    public func batchProgress(id: String, overlay: [GCSTransfer] = []) throws -> GCSBatchProgress {
        lock.lock(); defer { lock.unlock() }
        // Terminal successes and queued work need no JSON parsing. For partial work,
        // SQLite reads the existing phase fields without materializing the history in Swift.
        // This keeps the v1 schema/settings and read-only backup compatibility intact.
        let statement = try prepare("""
            SELECT COUNT(*),COALESCE(SUM(state IN (\(Self.successfulStates))),0),
                   COALESCE(SUM(state IN (\(Self.failedStates))),0),
                   COALESCE(SUM(state IN (\(Self.activeStates))),0),
                   COALESCE(SUM(state IN (\(Self.pendingStates))),0),COALESCE(SUM(state IN (\(Self.stoppedStates))),0),
                   COALESCE(SUM(CAST(size AS REAL)),0),COALESCE(SUM(CAST(completed_bytes AS REAL)),0),
                   COALESCE(SUM(CAST(size AS REAL) * (
                       CASE WHEN state IN (\(Self.successfulStates)) THEN 1.0
                            WHEN state IN (\(Self.pendingStates)) OR size <= 0 THEN 0.0
                            ELSE MIN(0.99, MAX(0.0,
                                CASE json_extract(CAST(payload AS TEXT),'$.phase')
                                WHEN '\(GCSTransferPhase.drone.rawValue)' THEN 0.5 *
                                    CASE WHEN json_extract(CAST(payload AS TEXT),'$.phaseTotal') > 0
                                         THEN MIN(1.0, MAX(0.0, COALESCE(
                                             CAST(json_extract(CAST(payload AS TEXT),'$.phaseBytes') AS REAL) /
                                             CAST(json_extract(CAST(payload AS TEXT),'$.phaseTotal') AS REAL),0.0)))
                                         ELSE 0.0 END
                                WHEN '\(GCSTransferPhase.http.rawValue)' THEN 0.5 + 0.5 * MIN(1.0,MAX(0.0,CAST(completed_bytes AS REAL)/size))
                                ELSE MIN(1.0,MAX(0.0,CAST(completed_bytes AS REAL)/size)) END)) END
                   )),0)
            FROM transfers WHERE batch_id=?
            """)
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AnalysisError.engine("Impossible de lire la progression de collecte.") }
        var values = (0...8).map { sqlite3_column_double(statement, Int32($0)) }
        let latest = overlay.reduce(into: [String: GCSTransfer]()) { $0[$1.id] = $1 }
        for current in latest.values {
            if let previous = try transfer(id: current.id), previous.batchID == id {
                add(previous, direction: -1, values: &values)
            }
            if current.batchID == id { add(current, direction: 1, values: &values) }
        }
        return GCSBatchProgress(totalCount: Int(GCSProgressMath.boundedInteger(values[0])), completedCount: Int(GCSProgressMath.boundedInteger(values[1])),
                                failedCount: Int(GCSProgressMath.boundedInteger(values[2])), activeCount: Int(GCSProgressMath.boundedInteger(values[3])),
                                pendingCount: Int(GCSProgressMath.boundedInteger(values[4])), stoppedCount: Int(GCSProgressMath.boundedInteger(values[5])),
                                totalBytes: GCSProgressMath.boundedInteger(values[6]), completedBytes: GCSProgressMath.boundedInteger(values[7]),
                                completedWorkBytes: values[8], totalWorkBytes: values[6])
    }

    public func recordCachedFiles(batchID: String, identities: Set<String>) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly else { throw AnalysisError.engine("La file de collecte est ouverte en lecture seule.") }
        try execute("BEGIN IMMEDIATE")
        do {
            for identity in identities {
                let statement = try prepare("INSERT OR IGNORE INTO batch_cache(batch_id,identity) VALUES(?,?)")
                bind(batchID, at: 1, to: statement); bind(identity, at: 2, to: statement)
                do { try step(statement) } catch { sqlite3_finalize(statement); throw error }
                sqlite3_finalize(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        let statement = try prepare("SELECT COUNT(*) FROM batch_cache WHERE batch_id=?")
        defer { sqlite3_finalize(statement) }; bind(batchID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AnalysisError.engine("Impossible de compter le cache de collecte.") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func forgetPayloads(except ids: Set<String>) { lock.lock(); defer { lock.unlock() }; encoded = encoded.filter { ids.contains($0.key) } }

    /// Deleting a client also releases destinations in persisted jobs beyond the visible page.
    public func removeClientAttribution(_ clientID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly else { throw AnalysisError.engine("La file de collecte est ouverte en lecture seule.") }
        let statement = try prepare("UPDATE transfers SET payload=CAST(json_remove(payload,'$.clientID') AS BLOB) WHERE json_extract(payload,'$.clientID')=?")
        defer { sqlite3_finalize(statement) }
        bind(clientID, at: 1, to: statement)
        try step(statement); encoded = [:]
    }

    private func add(_ item: GCSTransfer, direction: Double, values: inout [Double]) {
        let p = GCSBatchProgress(transfers: [item])
        let delta = [Double(p.totalCount), Double(p.completedCount), Double(p.failedCount), Double(p.activeCount), Double(p.pendingCount), Double(p.stoppedCount),
                     Double(max(0, item.size)), Double(min(max(0, item.size), max(0, item.completedBytes))), Double(max(0, item.size)) * item.workFraction]
        for index in values.indices { values[index] += direction * delta[index] }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AnalysisError.engine("Requête de file SQLite invalide.") }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw AnalysisError.engine("Impossible d’enregistrer la file SQLite.") }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AnalysisError.engine("État de la file SQLite illisible.") }
        return sqlite3_column_int64(statement, 0)
    }
    private func bind(_ text: String?, at index: Int32, to statement: OpaquePointer) {
        if let text { sqlite3_bind_text(statement, index, text, -1, transient) }
        else { sqlite3_bind_null(statement, index) }
    }
    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AnalysisError.engine("Écriture de la file SQLite refusée.") }
    }
    private func decode(_ statement: OpaquePointer, column: Int32) throws -> GCSTransfer {
        let size = sqlite3_column_bytes(statement, column)
        guard size > 0, size <= 1024 * 1024, let bytes = sqlite3_column_blob(statement, column) else { throw AnalysisError.engine("Entrée de file SQLite invalide.") }
        let data = Data(bytes: bytes, count: Int(size))
        let item = try JSONDecoder().decode(GCSTransfer.self, from: data)
        encoded[item.id] = data
        return item
    }
    private func rows(_ statement: OpaquePointer) throws -> [GCSTransfer] {
        var result: [GCSTransfer] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { result.append(try decode(statement, column: 0)); status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw AnalysisError.engine("Lecture de la file SQLite interrompue.") }
        return result
    }
}
