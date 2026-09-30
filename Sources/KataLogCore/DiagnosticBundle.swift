import Foundation
import CryptoKit
import Darwin

public struct DiagnosticGCSText: Sendable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case mosquitto, reactor, python, node, metadata, other
    }
    public let source: Source
    public let text: String
    public init(source: Source, text: String) { self.source = source; self.text = text }
}

/// Default service diagnostics do not retain free text. Merely replacing IPs
/// and UUIDs cannot guarantee removal of a hostname, person or mission name.
/// This projection retains only recognized operational categories, levels,
/// timestamps and HTTP status codes. Original text requires a separate opt-in.
public enum DiagnosticTextRedactor {
    public static func sanitize(_ text: String, source: DiagnosticGCSText.Source) -> String {
        if source == .metadata { return sanitizedMetadata(text) }
        let lines = text.split(whereSeparator: \.isNewline)
        var result = ["Diagnostic GCS : \(source.rawValue)",
                      "Messages libres retirés. Les catégories ci-dessous sont des indices de fonctionnement, pas des causes confirmées."]
        var omitted = 0
        for line in lines.prefix(20_000) {
            let raw = String(line.prefix(16_384))
            let lower = raw.lowercased()
            var categories: [String] = []
            let rules: [(String, String)] = [
                (#"\b(mqtt|mosquitto)\b"#, "MQTT"), (#"\b(ftp|download|transfer)\b"#, "transfert"),
                (#"\b(timeout|timed out)\b"#, "délai dépassé"), (#"\b(disconnect|disconnected|disconnecting)\b"#, "déconnexion"),
                (#"\b(connect|connected|connecting|connection)\b"#, "connexion"), (#"\b(retry|retrying|retries)\b"#, "nouvelle tentative"),
                (#"\b(traceback|exception|crash|segfault|panic)\b"#, "erreur de service"),
                (#"\b(permission|unauthorized|forbidden)\b"#, "accès refusé"), (#"\b(started|starting|startup)\b"#, "démarrage"),
                (#"\b(stopped|stopping|shutdown)\b"#, "arrêt"), (#"\b(error|failed|failure)\b"#, "échec"),
                (#"\b(warning|warn)\b"#, "avertissement")
            ]
            for (pattern, category) in rules where lower.range(of: pattern, options: .regularExpression) != nil {
                categories.append(category)
            }
            guard !categories.isEmpty else { omitted += 1; continue }
            let timestamp = match(#"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})?\b"#, raw) ??
                match(#"^(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s{1,2}\d{1,2}\s\d{2}:\d{2}:\d{2}\b"#, raw) ?? "horodatage non disponible"
            let level = match(#"\b(?:EMERGENCY|ALERT|CRITICAL|ERROR|WARNING|WARN|NOTICE|INFO|DEBUG)\b"#, raw.uppercased())
            let status = match(#"(?i)\bHTTP(?:/\d(?:\.\d)?)?\s+(?:status\s*[:=]?\s*)?[1-5]\d{2}\b"#, raw)
                .flatMap { match(#"[1-5]\d{2}$"#, $0) }
            result.append(([timestamp, level, categories.joined(separator: ", "), status.map { "HTTP \($0)" }].compactMap { $0 }).joined(separator: " · "))
        }
        omitted += max(0, lines.count - 20_000)
        result.append("\(omitted) lignes sans catégorie reconnue retirées.")
        return result.joined(separator: "\n") + "\n"
    }

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func sanitizedMetadata(_ text: String) -> String {
        var values: [String: Any] = ["privateFreeTextRemoved": true]
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            if let version = object["gcsVersion"] as? String,
               version.range(of: #"^v?\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil {
                values["gcsVersion"] = version
            }
            if let temperature = object["temperature"] as? NSNumber,
               String(cString: temperature.objCType) != "c", temperature.doubleValue.isFinite,
               (-40...150).contains(temperature.doubleValue) { values["temperature"] = temperature.doubleValue }
            for key in ["frontSha", "nodeSha"] {
                if let sha = object[key] as? String {
                    let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.range(of: #"^(?:[A-Fa-f0-9]{40}|[A-Fa-f0-9]{64})$"#, options: .regularExpression) != nil {
                        values[key] = trimmed.lowercased()
                    }
                }
            }
        }
        return (try? String(decoding: JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)) ?? "{\"privateFreeTextRemoved\":true}"
    }
}

public struct DiagnosticBundlePreview: Sendable {
    public let fileNames: [String]
    public let eventCount: Int
    public let gcsSourceCount: Int
    public let privateDataIncluded: Bool
    public let summary: String
}

public struct DiagnosticBundleResult: Sendable {
    public let url: URL
    public let fileCount: Int
    public let eventCount: Int
    public let privateDataIncluded: Bool
}

public enum DiagnosticBundle {
    public enum BundleError: Error, LocalizedError {
        case invalidDestination, invalidAttachment, oversized, archiveFailed
        public var errorDescription: String? {
            switch self {
            case .invalidDestination: "Choisissez un fichier ZIP dans un dossier local accessible."
            case .invalidAttachment: "Une pièce jointe est inaccessible ou son format n’est pas accepté."
            case .oversized: "Les pièces du diagnostic dépassent la limite autorisée. Réduisez la sélection de logs."
            case .archiveFailed: "L’archive du diagnostic n’a pas pu être créée. Aucun export incomplet n’a été conservé."
            }
        }
    }

    private static let maximumGCSBytes = 8 * 1024 * 1024
    private static let maximumULogBytes = 256 * 1024 * 1024
    private static let maximumTotalULogBytes = 1024 * 1024 * 1024

    public static func preview(report: DiagnosticReport, journal: DiagnosticJournalSnapshot,
                               gcs: [DiagnosticGCSText] = [], includePrivateGCS: Bool = false,
                               privateULogs: [URL] = []) throws -> DiagnosticBundlePreview {
        _ = try sanitizedReport(report).data()
        _ = try checkedULogs(privateULogs)
        try validateGCS(gcs)
        let names = fileNames(gcs: gcs, privateULogs: privateULogs)
        let privateIncluded = (includePrivateGCS && !gcs.isEmpty) || !privateULogs.isEmpty
        return DiagnosticBundlePreview(fileNames: names, eventCount: journal.events.count,
                                       gcsSourceCount: gcs.count, privateDataIncluded: privateIncluded,
                                       summary: summary(journal: journal, gcs: gcs, includePrivateGCS: includePrivateGCS,
                                                        privateULogCount: privateULogs.count))
    }

    /// No upload is performed. The ZIP is staged next to its destination and
    /// replaces it atomically only after every piece has been written. The two
    /// private attachment opt-ins are independent: choosing ULogs never enables
    /// original GCS text. Attachments use generated names, never source paths.
    public static func export(to destination: URL, report: DiagnosticReport,
                              journal: DiagnosticJournalSnapshot, gcs: [DiagnosticGCSText] = [],
                              includePrivateGCS: Bool = false, privateULogs: [URL] = []) async throws -> DiagnosticBundleResult {
        let processControl = ProcessLifetime()
        let task = Task.detached(priority: .utility) {
            defer { processControl.cleanup() }
            try Task.checkCancellation()
            return try exportSynchronously(to: destination, report: report, journal: journal, gcs: gcs,
                                           includePrivateGCS: includePrivateGCS, privateULogs: privateULogs,
                                           processControl: processControl)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel(); processControl.cancel()
        }
    }

    private struct FileManifest: Codable { let name: String; let sizeBytes: Int64; let sha256: String }
    private struct Manifest: Codable {
        let version: Int
        let generatedAt: Date
        let eventCount: Int
        let corruptedJournalLines: Int
        let droppedJournalEvents: Int
        let gcsCurrentBootOnly: Bool
        let gcsRawTextIncluded: Bool
        let privateULogCount: Int
        let privateDataIncluded: Bool
        let clockAlignment: String
        let files: [FileManifest]
    }

    private static func exportSynchronously(to destination: URL, report: DiagnosticReport,
                                            journal: DiagnosticJournalSnapshot, gcs: [DiagnosticGCSText],
                                            includePrivateGCS: Bool, privateULogs: [URL],
                                            processControl: ProcessLifetime) throws -> DiagnosticBundleResult {
        let preview = try preview(report: report, journal: journal, gcs: gcs,
                                  includePrivateGCS: includePrivateGCS, privateULogs: privateULogs)
        let destination = destination.standardizedFileURL
        guard destination.isFileURL, destination.pathExtension.lowercased() == "zip" else { throw BundleError.invalidDestination }
        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey])
        guard parentValues.isDirectory == true else { throw BundleError.invalidDestination }
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BundleError.invalidDestination }
        }
        let identifier = UUID().uuidString
        let stage = parent.appendingPathComponent(".katalog-diagnostic-\(identifier)", isDirectory: true)
        let archive = parent.appendingPathComponent(".katalog-diagnostic-\(identifier).zip")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage); try? FileManager.default.removeItem(at: archive) }

        var entries: [FileManifest] = []
        func write(_ data: Data, name: String) throws {
            try Task.checkCancellation()
            guard safeName(name) else { throw BundleError.invalidAttachment }
            let file = stage.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            entries.append(FileManifest(name: name, sizeBytes: Int64(data.count), sha256: sha256(data)))
        }
        var snapshotReport = sanitizedReport(report)
        snapshotReport.privateDataIncluded = preview.privateDataIncluded
        try write(snapshotReport.data(), name: "snapshot.json")
        let journalData = try journal.jsonLines()
        guard journalData.count <= 72 * 1024 * 1024 else { throw BundleError.oversized }
        try write(journalData, name: "events.jsonl")
        try write(Data(preview.summary.utf8), name: "LISEZ-MOI.txt")
        for service in gcs {
            let text = includePrivateGCS ? service.text : DiagnosticTextRedactor.sanitize(service.text, source: service.source)
            try write(Data(text.utf8), name: "gcs/\(service.source.rawValue).log")
        }
        let checked = try checkedULogs(privateULogs)
        var totalCopiedULogBytes: Int64 = 0
        for (index, source) in checked.enumerated() {
            try Task.checkCancellation()
            let name = String(format: "ulog/%04d.ulg", index + 1)
            let target = stage.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let input = try FileHandle(forReadingFrom: source)
            let output = FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
            guard output else { try? input.close(); throw BundleError.archiveFailed }
            let writer = try FileHandle(forWritingTo: target)
            var digest = SHA256(), count: Int64 = 0
            do {
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    count += Int64(data.count)
                    totalCopiedULogBytes += Int64(data.count)
                    guard count <= Int64(maximumULogBytes), totalCopiedULogBytes <= Int64(maximumTotalULogBytes) else { throw BundleError.oversized }
                    digest.update(data: data); try writer.write(contentsOf: data)
                }
                try input.close(); try writer.close()
            } catch { try? input.close(); try? writer.close(); throw error }
            entries.append(FileManifest(name: name, sizeBytes: count, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        let manifest = Manifest(version: 1, generatedAt: journal.generatedAt, eventCount: journal.events.count,
                                corruptedJournalLines: journal.corruptedLineCount, droppedJournalEvents: journal.droppedEventCount,
                                gcsCurrentBootOnly: true, gcsRawTextIncluded: includePrivateGCS && !gcs.isEmpty,
                                privateULogCount: privateULogs.count, privateDataIncluded: preview.privateDataIncluded,
                                clockAlignment: "Horloges non synchronisées automatiquement. Temps ULog relatifs au démarrage; journal GCS du démarrage courant.", files: entries)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(manifest), name: "manifest.json")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", stage.path, archive.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try processControl.run(process)
        ProcessLifetime.wait(for: process); try processControl.finish()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: archive.path) else { throw BundleError.archiveFailed }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        try Task.checkCancellation()
        guard Darwin.rename(archive.path, destination.path) == 0 else { throw BundleError.archiveFailed }
        return DiagnosticBundleResult(url: destination, fileCount: entries.count,
                                      eventCount: journal.events.count, privateDataIncluded: preview.privateDataIncluded)
    }

    private static func validateGCS(_ gcs: [DiagnosticGCSText]) throws {
        guard gcs.count <= DiagnosticGCSText.Source.allCases.count,
              Set(gcs.map(\.source)).count == gcs.count,
              gcs.reduce(0, { $0 + $1.text.utf8.count }) <= maximumGCSBytes else { throw BundleError.oversized }
    }
    private static func checkedULogs(_ files: [URL]) throws -> [URL] {
        guard files.count <= 100 else { throw BundleError.oversized }
        var total = 0, checked: [URL] = [], identities = Set<String>()
        for file in files {
            guard file.isFileURL, file.pathExtension.lowercased() == "ulg" else { throw BundleError.invalidAttachment }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BundleError.invalidAttachment }
            let size = values.fileSize ?? 0
            guard size <= maximumULogBytes else { throw BundleError.oversized }
            total += size
            guard total <= maximumTotalULogBytes else { throw BundleError.oversized }
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard identities.insert(resolved.path).inserted else { throw BundleError.invalidAttachment }
            checked.append(resolved)
        }
        return checked
    }
    private static func fileNames(gcs: [DiagnosticGCSText], privateULogs: [URL]) -> [String] {
        ["snapshot.json", "events.jsonl", "LISEZ-MOI.txt", "manifest.json"] +
        gcs.map { "gcs/\($0.source.rawValue).log" } + privateULogs.indices.map { String(format: "ulog/%04d.ulg", $0 + 1) }
    }
    private static func safeName(_ name: String) -> Bool {
        !name.hasPrefix("/") && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func sanitizedReport(_ report: DiagnosticReport) -> DiagnosticReport {
        func version(_ value: String) -> String {
            value.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,4}(?:-(?:dev|preview|beta|rc)\d{0,3})?$"#, options: .regularExpression) == nil ? "unknown" : value
        }
        let build = report.appBuild.range(of: #"^\d{1,10}$"#, options: .regularExpression) == nil ? "unknown" : report.appBuild
        var safe = DiagnosticReport(appVersion: version(report.appVersion), appBuild: build,
                                    operations: report.operations, counts: report.counts.mapValues { max(0, $0) },
                                    countScope: report.countScope, runtimeBundled: report.runtimeBundled)
        safe.parserVersion = version(report.parserVersion)
        safe.osVersion = version(report.osVersion)
        safe.architecture = ["arm64", "x86_64", "other"].contains(report.architecture) ? report.architecture : "other"
        if let date = ISO8601DateFormatter().date(from: report.generatedAt) {
            safe.generatedAt = ISO8601DateFormatter().string(from: date)
        }
        return safe
    }
    private static func summary(journal: DiagnosticJournalSnapshot, gcs: [DiagnosticGCSText],
                                includePrivateGCS: Bool, privateULogCount: Int) -> String {
        """
        DIAGNOSTIC KATALOG

        \(journal.events.count) événements de fonctionnement de KataLog.
        \(journal.corruptedLineCount) lignes du journal illisibles ignorées ; \(journal.droppedEventCount) événements non enregistrés pendant cette session.
        \(gcs.count) services GCS joints. \(includePrivateGCS && !gcs.isEmpty ? "Messages GCS originaux inclus : données privées possibles." : "Messages GCS libres retirés : seules les catégories reconnues sont conservées.")
        \(privateULogCount) fichiers ULog joints sur sélection explicite. Les fichiers ULog peuvent contenir identité, position et données de vol.

        CONTENU
        snapshot.json : état et compteurs au moment de la capture.
        events.jsonl : chronologie structurée avec codes d’erreur stables.
        manifest.json : liste des pièces, tailles et empreintes SHA256.
        gcs/ : diagnostic des services, lorsqu’il est disponible.
        ulog/ : fichiers choisis explicitement, avec des noms générés.

        INTERPRÉTATION
        Une erreur de transfert, de réseau ou d’analyse n’est pas nécessairement une panne du drone.
        Les identifiants de corrélation du journal sont anonymisés pour chaque lancement de KataLog.
        Les durées du journal sont monotoniques depuis le lancement. Les dates UTC proviennent de l’horloge du Mac.
        Les horloges Mac, GCS et ULog ne sont pas alignées automatiquement. Une proximité temporelle ne prouve pas une cause.
        Le journal GCS récupéré concerne généralement le démarrage courant : capturez-le avant un redémarrage.
        Aucun fichier n’a été envoyé automatiquement. Vérifiez les pièces avant de partager cette archive.

        DERNIERS ÉVÉNEMENTS
        \(journal.events.suffix(100).map(\.previewLine).joined(separator: "\n"))

        """
    }
}
