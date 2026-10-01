import Foundation
import CryptoKit

/// Only structured, allowlisted values are written. A controller identifier,
/// file path or server address passed as correlation is hashed with a secret
/// that exists only for this launch. No original identifier is persisted.
public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case appStarted, appStopped, gcsConnecting, gcsConnected, gcsDisconnected
        case inventoryStarted, inventoryCompleted, collectionStarted, transferStarted
        case transferProgress, transferRetrying, transferCompleted, collectionPaused
        case collectionStopped, collectionCompleted, destinationChanged, importStarted
        case importCompleted, importFailed, cacheHit, exportStarted, exportCompleted
        case exportFailed, gcsDiagnosticsStarted, gcsDiagnosticsCompleted, gcsDiagnosticsFailed, journalCleared

        public var title: String {
            switch self {
            case .appStarted: "Application démarrée"
            case .appStopped: "Application fermée"
            case .gcsConnecting: "Connexion à la GCS"
            case .gcsConnected: "GCS connectée"
            case .gcsDisconnected: "GCS déconnectée"
            case .inventoryStarted: "Lecture des logs disponibles"
            case .inventoryCompleted: "Inventaire terminé"
            case .collectionStarted: "Collecte démarrée"
            case .transferStarted: "Transfert démarré"
            case .transferProgress: "Transfert en cours"
            case .transferRetrying: "Nouvelle tentative de transfert"
            case .transferCompleted: "Transfert terminé"
            case .collectionPaused: "Collecte en pause"
            case .collectionStopped: "Collecte arrêtée"
            case .collectionCompleted: "Collecte terminée"
            case .destinationChanged: "Dossier de collecte changé"
            case .importStarted: "Analyse des logs démarrée"
            case .importCompleted: "Analyse des logs terminée"
            case .importFailed: "Analyse des logs interrompue"
            case .cacheHit: "Log déjà présent"
            case .exportStarted: "Export démarré"
            case .exportCompleted: "Export terminé"
            case .exportFailed: "Export interrompu"
            case .gcsDiagnosticsStarted: "Lecture du diagnostic GCS"
            case .gcsDiagnosticsCompleted: "Diagnostic GCS récupéré"
            case .gcsDiagnosticsFailed: "Diagnostic GCS indisponible"
            case .journalCleared: "Journal effacé"
            }
        }

        public var explanation: String {
            switch self {
            case .transferProgress: "La progression concerne le transfert des fichiers. Elle ne décrit pas une panne du drone."
            case .gcsDiagnosticsStarted, .gcsDiagnosticsCompleted, .gcsDiagnosticsFailed:
                "Le diagnostic de la GCS complète les logs de vol avec les événements de ses services. Les horloges peuvent différer."
            case .importStarted, .importCompleted, .importFailed:
                "KataLog lit les fichiers ULog pour calculer les statistiques et les alertes."
            case .destinationChanged: "Le dossier choisi détermine les fichiers considérés comme déjà collectés."
            case .cacheHit: "Le fichier est déjà disponible dans le dossier choisi : son transfert est évité."
            default: "Événement de fonctionnement de KataLog. Il ne constitue pas à lui seul une panne du drone."
            }
        }
    }

    public enum Code: String, Codable, Sendable {
        case none, cancelled, disconnected, timeout, connectionUnavailable, transferFailed
        case verificationFailed, analysisFailed, storageUnavailable, permissionDenied, invalidData
        case exportFailed, gcsDiagnosticsUnavailable, internalFailure

        public var title: String {
            switch self {
            case .none: "Information"
            case .cancelled: "Opération arrêtée"
            case .disconnected: "Connexion interrompue"
            case .timeout: "Délai dépassé"
            case .connectionUnavailable: "Connexion indisponible"
            case .transferFailed: "Échec du transfert"
            case .verificationFailed: "Fichier non validé"
            case .analysisFailed: "Échec de l’analyse"
            case .storageUnavailable: "Stockage indisponible"
            case .permissionDenied: "Accès refusé"
            case .invalidData: "Données invalides"
            case .exportFailed: "Échec de l’export"
            case .gcsDiagnosticsUnavailable: "Diagnostic GCS indisponible"
            case .internalFailure: "Erreur de fonctionnement"
            }
        }
        public var explanation: String {
            switch self {
            case .none: "Aucune erreur n’est associée à cet événement."
            case .cancelled: "L’opération a été interrompue. Les fichiers déjà terminés restent conservés."
            case .disconnected, .connectionUnavailable: "Vérifiez que la GCS et le drone sont disponibles, puis réessayez."
            case .timeout: "La réponse attendue n’est pas arrivée à temps. Une nouvelle tentative peut suffire."
            case .transferFailed: "Le fichier n’a pas été entièrement reçu. Ce problème de transfert ne prouve pas une panne en vol."
            case .verificationFailed: "Le fichier reçu ne satisfait pas les contrôles attendus. Il ne doit pas être considéré comme terminé."
            case .analysisFailed, .invalidData: "Le fichier n’a pas pu être lu complètement. Vérifiez sa qualité et la version du parser."
            case .storageUnavailable, .permissionDenied: "Vérifiez l’espace disponible et l’autorisation d’accès au dossier choisi."
            case .exportFailed: "Le rapport n’a pas pu être enregistré. Vérifiez le dossier de destination."
            case .gcsDiagnosticsUnavailable: "Ce firmware ne propose peut-être pas l’export des services, ou la GCS ne répond pas."
            case .internalFailure: "Une opération de KataLog a échoué. Le diagnostic structuré permet de retrouver son contexte."
            }
        }
    }

    public enum Metric: String, Codable, Sendable {
        case bytes, totalBytes, items, completedItems, retryAttempt, httpStatus, durationMs
    }
    public enum Phase: String, Codable, Sendable { case drone, http, verification, analysis }

    public let timestamp: Date
    public let elapsedMilliseconds: Int64
    public let sessionID: String
    public let kind: Kind
    public let code: Code
    public let phase: Phase?
    public let correlationID: String?
    public let metrics: [Metric: Int64]

    public var title: String {
        if kind == .transferCompleted, code != .none {
            return code == .cancelled ? "Transfert arrêté" : "Échec du transfert"
        }
        return kind.title
    }
    public var previewLine: String {
        "\(ISO8601DateFormatter().string(from: timestamp)) · \(title)" + (code == .none ? "" : " · \(code.title)")
    }
    var isSafeForExport: Bool {
        elapsedMilliseconds >= 0 && UUID(uuidString: sessionID) != nil &&
        (correlationID == nil || correlationID!.range(of: "^p-[a-f0-9]{24}$", options: .regularExpression) != nil) &&
        metrics.values.allSatisfy { $0 >= 0 } && timestamp <= Date().addingTimeInterval(300)
    }
}

public struct DiagnosticJournalSnapshot: Sendable {
    public let events: [DiagnosticEvent]
    public let corruptedLineCount: Int
    public let droppedEventCount: Int
    public let generatedAt: Date

    public init(events: [DiagnosticEvent], corruptedLineCount: Int = 0, droppedEventCount: Int = 0, generatedAt: Date = Date()) {
        self.events = events.filter(\.isSafeForExport)
        self.corruptedLineCount = max(0, corruptedLineCount)
        self.droppedEventCount = max(0, droppedEventCount)
        self.generatedAt = generatedAt
    }

    public func jsonLines() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        var result = Data()
        for event in events {
            try Task.checkCancellation()
            result.append(try encoder.encode(event)); result.append(0x0A)
            guard result.count <= 72 * 1024 * 1024 else { throw DiagnosticBundle.BundleError.oversized }
        }
        return result
    }
}

/// Serial file work is performed outside the caller's thread. Snapshot and
/// clear are explicit synchronization points and should be called off the UI
/// thread when used with a large journal. Memory-only mode supports previews.
public final class DiagnosticJournal: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maximumFileBytes: Int
        public var maximumArchives: Int
        public var maximumAge: TimeInterval
        public var persistent: Bool
        public init(maximumFileBytes: Int = 512 * 1024, maximumArchives: Int = 3,
                    maximumAge: TimeInterval = 14 * 24 * 3600, persistent: Bool = true) {
            self.maximumFileBytes = min(4 * 1024 * 1024, max(1024, maximumFileBytes))
            self.maximumArchives = min(16, max(0, maximumArchives))
            self.maximumAge = min(90 * 24 * 3600, max(1, maximumAge))
            self.persistent = persistent
        }
    }
    public enum JournalError: Error, LocalizedError {
        case unsafeLocation, unavailable
        public var errorDescription: String? { "Le journal local n’est pas disponible. Vérifiez l’accès au dossier de la bibliothèque." }
    }

    public let configuration: Configuration
    private let directory: URL
    private let queue = DispatchQueue(label: "com.katalog.diagnostic-journal", qos: .utility)
    private let sessionID = UUID().uuidString.lowercased()
    private let salt = UUID().uuidString + UUID().uuidString
    private let started = DispatchTime.now().uptimeNanoseconds
    private var memory: [DiagnosticEvent] = []
    private var dropped = 0
    private var directoryReady = false
    private var lastAgeCleanup: Date = .distantPast

    public init(directory: URL, configuration: Configuration = .init()) {
        self.directory = directory.standardizedFileURL
        self.configuration = Configuration(maximumFileBytes: configuration.maximumFileBytes,
                                           maximumArchives: configuration.maximumArchives,
                                           maximumAge: configuration.maximumAge, persistent: configuration.persistent)
    }

    public func record(_ kind: DiagnosticEvent.Kind, code: DiagnosticEvent.Code = .none,
                       phase: DiagnosticEvent.Phase? = nil, correlation: String? = nil,
                       metrics: [DiagnosticEvent.Metric: Int64] = [:]) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let correlationID = correlation.map { raw in
            "p-" + SHA256.hash(data: Data((salt + raw).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        }
        let event = DiagnosticEvent(timestamp: Date(), elapsedMilliseconds: Int64(clamping: elapsed), sessionID: sessionID,
                                    kind: kind, code: code, phase: phase, correlationID: correlationID,
                                    metrics: metrics.mapValues { max(0, $0) })
        queue.async { [self] in
            do {
                if configuration.persistent { try appendLocked(event) }
                else {
                    memory.append(event)
                    let maximum = max(1, configuration.maximumFileBytes * (configuration.maximumArchives + 1) / 512)
                    if memory.count > maximum { memory.removeFirst(memory.count - maximum) }
                    memory.removeAll { $0.timestamp < Date().addingTimeInterval(-configuration.maximumAge) }
                }
            } catch { dropped += 1 }
        }
    }

    public func snapshot() throws -> DiagnosticJournalSnapshot {
        try queue.sync {
            if !configuration.persistent {
                memory.removeAll { $0.timestamp < Date().addingTimeInterval(-configuration.maximumAge) }
                return DiagnosticJournalSnapshot(events: memory, droppedEventCount: dropped)
            }
            try prepareDirectoryLocked()
            try cleanAgeLocked(force: true)
            var events: [DiagnosticEvent] = [], corrupt = 0
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for index in (0...configuration.maximumArchives).reversed() {
                let file = fileURL(index)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                try validateFileLocked(file)
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count <= configuration.maximumFileBytes else { throw JournalError.unavailable }
                for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard line.count <= 4096, let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line)), valid(event) else {
                        corrupt += 1; continue
                    }
                    if event.timestamp >= Date().addingTimeInterval(-configuration.maximumAge) { events.append(event) }
                }
            }
            return DiagnosticJournalSnapshot(events: events, corruptedLineCount: corrupt, droppedEventCount: dropped)
        }
    }

    /// Waits for already queued records before the application terminates.
    /// Records never make the application crash when storage is unavailable.
    public func flush() { queue.sync {} }

    /// Clears only KataLog's fixed journal filenames. No source logs or other
    /// files in this directory are removed.
    public func clear() throws {
        try queue.sync {
            if configuration.persistent {
                try prepareDirectoryLocked()
                for index in 0...16 {
                    let file = fileURL(index)
                    if FileManager.default.fileExists(atPath: file.path) {
                        try validateFileLocked(file, checkSize: false)
                        try FileManager.default.removeItem(at: file)
                    }
                }
            }
            memory.removeAll(); dropped = 0
        }
    }

    private func fileURL(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl")
    }
    private func prepareDirectoryLocked() throws {
        guard configuration.persistent else { return }
        if !directoryReady {
            guard directory.isFileURL else { throw JournalError.unsafeLocation }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw JournalError.unsafeLocation }
            directoryReady = true
        }
    }
    private func validateFileLocked(_ url: URL, checkSize: Bool = true) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (!checkSize || (values.fileSize ?? 0) <= configuration.maximumFileBytes) else { throw JournalError.unsafeLocation }
    }
    private func appendLocked(_ event: DiagnosticEvent) throws {
        try prepareDirectoryLocked(); try cleanAgeLocked(force: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(event); data.append(0x0A)
        guard data.count <= min(4096, configuration.maximumFileBytes) else { dropped += 1; return }
        let current = fileURL(0)
        var needsNewline = false
        if FileManager.default.fileExists(atPath: current.path) {
            try validateFileLocked(current)
            let size = try current.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > 0 {
                let reader = try FileHandle(forReadingFrom: current)
                try reader.seek(toOffset: UInt64(size - 1))
                needsNewline = try reader.read(upToCount: 1)?.first != 0x0A
                try reader.close()
            }
            if size + data.count + (needsNewline ? 1 : 0) > configuration.maximumFileBytes {
                try rotateLocked(); needsNewline = false
            }
        }
        if !FileManager.default.fileExists(atPath: current.path) {
            guard FileManager.default.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw JournalError.unavailable
            }
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if needsNewline { try handle.write(contentsOf: Data([0x0A])) }
        try handle.write(contentsOf: data)
    }
    private func rotateLocked() throws {
        let manager = FileManager.default
        let last = fileURL(configuration.maximumArchives)
        if manager.fileExists(atPath: last.path) { try validateFileLocked(last); try manager.removeItem(at: last) }
        if configuration.maximumArchives > 0 {
            for index in (0..<configuration.maximumArchives).reversed() {
                let source = fileURL(index)
                if manager.fileExists(atPath: source.path) {
                    try validateFileLocked(source)
                    try manager.moveItem(at: source, to: fileURL(index + 1))
                }
            }
        }
    }
    private func cleanAgeLocked(force: Bool) throws {
        let now = Date()
        guard force || now.timeIntervalSince(lastAgeCleanup) >= 3600 else { return }
        lastAgeCleanup = now
        let cutoff = now.addingTimeInterval(-configuration.maximumAge)
        for index in 0...16 {
            let file = fileURL(index)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try validateFileLocked(file)
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now
            if modified < cutoff || index > configuration.maximumArchives {
                try FileManager.default.removeItem(at: file)
            } else {
                // A quiet old event must not live forever because newer events
                // continue touching this same file.
                let data = try Data(contentsOf: file)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var kept = Data(), removed = false
                for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    if let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line)), event.timestamp < cutoff {
                        removed = true; continue
                    }
                    kept.append(contentsOf: line); kept.append(0x0A)
                }
                if removed {
                    if kept.isEmpty { try FileManager.default.removeItem(at: file) }
                    else {
                        try kept.write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }
                }
            }
        }
    }
    private func valid(_ event: DiagnosticEvent) -> Bool {
        event.isSafeForExport
    }
}
