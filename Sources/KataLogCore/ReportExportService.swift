import CryptoKit
import Darwin
import Foundation

public struct ReportExportOptions: Codable, Sendable {
    public enum Format: String, Codable, Sendable { case html, json }
    public var format: Format
    public var excludePaths: Bool
    public var excludeIdentity: Bool
    public var excludeCoordinates: Bool
    public var includeCachedDetails: Bool
    public init(format: Format = .html, excludePaths: Bool = false, excludeIdentity: Bool = false,
                excludeCoordinates: Bool = false, includeCachedDetails: Bool = false) {
        self.format = format; self.excludePaths = excludePaths; self.excludeIdentity = excludeIdentity
        self.excludeCoordinates = excludeCoordinates; self.includeCachedDetails = includeCachedDetails
    }
    public var isShared: Bool { excludePaths || excludeIdentity || excludeCoordinates }
}

public struct ReportExportRequest: Codable, Sendable {
    public var reportVersion = 1
    public var query: LibraryQueryRequest
    public var mode: ReportScopeManifest.Mode
    public var scopeDescription: String
    public var viewRevision: Int
    public var options: ReportExportOptions
    public init(query: LibraryQueryRequest, mode: ReportScopeManifest.Mode = .full,
                scopeDescription: String = "Toute la bibliothèque", viewRevision: Int = 0,
                options: ReportExportOptions = .init()) {
        self.query = query; self.mode = mode; self.scopeDescription = scopeDescription
        self.viewRevision = viewRevision; self.options = options
    }
}

public struct ReportCaptureManifest: Codable, Sendable {
    public var reportVersion: Int
    public var revision: Int
    public var scopeHash: String
    public var captureID: String
    public var capturedAt: String
    public var contextSHA256: String
    public var databaseSHA256: String
    public var totalLogs: Int
    public var totalMessages: Int
}

public struct ReportCapture: Sendable {
    public let directory: URL
    public let manifest: ReportCaptureManifest
    public let request: ReportExportRequest
}

public struct ReportExportFile: Codable, Sendable {
    public var name: String
    public var sizeBytes: Int64
    public var sha256: String
}

public struct ReportExportResult: Sendable {
    public let destination: URL
    public let entryPoint: URL
    public let revision: Int
    public let logCount: Int
    public let messageCount: Int
    public let renderMode: String
    public let rawDataIncluded: Bool
}

private struct PreparedReport: Decodable, Sendable {
    var reportVersion: Int
    var revision: Int
    var scopeHash: String?
    var renderMode: String
    var logCount: Int
    var messageCount: Int
    var rawDataIncluded: Bool
    var files: [ReportExportFile]
    var manifest: JSONValue
}

private struct ReportSummary: Decodable, Sendable {
    var schemaVersion: Int
    var generatedAt: String
    var scopeDescription: String
    var totalLogs: Int
    var totalMessages: Int
    var validLogs: Int
    var recordedSeconds: Double
    var alertLogs: Int
    var failsafeLogs: Int
    var familyLogCounts: [String: Int]
    var droneCount: Int
    var scannedDroneCount: Int?
    var provisionalDroneCount: Int?
    var flightSeconds: Double?
    var flightLogCount: Int?
    var rawDataIncluded: Bool
    var detailedCachedLogCount: Int
}

private final class ReportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw CancellationError() } }
}

/// Publication uses a sibling staging directory. The live library is read only
/// during capture; generation and cancellation cannot publish a partial report.
public enum ReportExportService {
    public static let inlineJSONBudget = 8 * 1024 * 1024
    public static let htmlBudget = 10 * 1024 * 1024

    public static func capture(database: URL, directory: URL, request: ReportExportRequest,
                               engine: URL) async throws -> ReportCapture {
        try await capture(database: database, directory: directory, request: request, engine: engine,
                          runtimeConfiguration: .current)
    }

    static func capture(database: URL, directory: URL, request: ReportExportRequest, engine: URL,
                        runtimeConfiguration: EngineRuntimeResolver.Configuration) async throws -> ReportCapture {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw AnalysisError.engine("Le dossier temporaire du rapport existe déjà.")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try await AnalysisService.run(["capture-report", "--database", database.path, "--capture", directory.path],
                                                engine: engine, request: encoder.encode(request), outputLimit: 1024 * 1024,
                                                runtimeConfiguration: runtimeConfiguration)
        let manifest = try JSONDecoder().decode(ReportCaptureManifest.self, from: data)
        guard manifest.reportVersion == 1, manifest.totalLogs >= 0, manifest.totalMessages >= 0 else {
            throw AnalysisError.engine("La capture du rapport est invalide.")
        }
        try Task.checkCancellation()
        completed = true
        return ReportCapture(directory: directory, manifest: manifest, request: request)
    }

    /// HTML destinations are folders; JSON destinations are a single JSON file.
    /// Caller releases its maintenance gate after capture(), before this call.
    public static func export(capture: ReportCapture, destination: URL, engine: URL, progress: URL? = nil) async throws -> ReportExportResult {
        try await export(capture: capture, destination: destination, engine: engine, progress: progress, runtimeConfiguration: .current)
    }

    static func export(capture: ReportCapture, destination: URL, engine: URL, progress: URL? = nil,
                       runtimeConfiguration: EngineRuntimeResolver.Configuration) async throws -> ReportExportResult {
        let cancellation = ReportCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".katalog-report-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            var command = ["export-captured", "--capture", capture.directory.path, "--destination", staging.path]
            if let progress { command += ["--progress", progress.path] }
            let response = try await AnalysisService.run(command, engine: engine, outputLimit: 1024 * 1024,
                                                        runtimeConfiguration: runtimeConfiguration)
            let prepared = try JSONDecoder().decode(PreparedReport.self, from: response)
            guard prepared.reportVersion == 1, prepared.revision == capture.manifest.revision,
                  prepared.logCount == capture.manifest.totalLogs, prepared.messageCount == capture.manifest.totalMessages else {
                throw AnalysisError.engine("Le rapport ne correspond pas à la révision capturée.")
            }
            try cancellation.check(); try Task.checkCancellation()
            let format = capture.request.options.format
            if format == .json {
                let full = staging.appendingPathComponent("rapport.json")
                try verify(prepared.files, root: staging, cancellation: cancellation)
                try cancellation.check(); try Task.checkCancellation()
                try atomicPublishFile(full, to: destination)
                writeProgress(progress, capture: capture, current: "Rapport JSON publié")
                return .init(destination: destination, entryPoint: destination, revision: prepared.revision,
                             logCount: prepared.logCount, messageCount: prepared.messageCount,
                             renderMode: "json-stream", rawDataIncluded: prepared.rawDataIncluded)
            }
            let task = Task.detached(priority: .userInitiated) {
                try render(prepared: prepared, capture: capture, staging: staging, cancellation: cancellation)
            }
            let renderMode = try await withTaskCancellationHandler { try await task.value } onCancel: {
                cancellation.cancel(); task.cancel()
            }
            try verify(prepared.files, root: staging, cancellation: cancellation)
            writeProgress(progress, capture: capture, current: "Pièces vérifiées · publication du rapport…")
            try cancellation.check(); try Task.checkCancellation()
            try atomicPublishFolder(staging, to: destination)
            writeProgress(progress, capture: capture, current: "Rapport publié")
            return .init(destination: destination, entryPoint: destination.appendingPathComponent("index.html"),
                         revision: prepared.revision, logCount: prepared.logCount, messageCount: prepared.messageCount,
                         renderMode: renderMode, rawDataIncluded: prepared.rawDataIncluded)
        } onCancel: { cancellation.cancel() }
    }

    private static func render(prepared: PreparedReport, capture: ReportCapture, staging: URL,
                               cancellation: ReportCancellation) throws -> String {
        try cancellation.check()
        let full = staging.appendingPathComponent("rapport.json")
        let summaryData = try boundedRead(staging.appendingPathComponent("summary.json"), budget: inlineJSONBudget)
        let summary = try JSONDecoder().decode(ReportSummary.self, from: summaryData)
        var html: String?
        var mode = "summary-with-attachments"
        let size = try full.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        // The size gate applies before decoding. The work gate prevents a dense
        // but short-text file from creating an excessive native HTML DOM.
        if prepared.renderMode == "interactive", size <= inlineJSONBudget,
           prepared.logCount + prepared.messageCount <= 5_000 {
            let snapshot = try AnalysisService.decode(boundedRead(full, budget: inlineJSONBudget))
            try cancellation.check()
            let detailedItems = snapshot.logs.reduce(0) { sum, log in
                sum + (log.parameters?.count ?? 0) + (log.events?.count ?? 0) +
                (log.topicDetails?.reduce(0) { $0 + $1.fields.count } ?? 0) +
                (log.telemetry?.reduce(0) { $0 + $1.points.count } ?? 0)
            }
            if detailedItems <= 5_000 {
                var manifest = ReportScopeManifest.describing(snapshot, mode: capture.request.mode,
                    scopeDescription: summary.scopeDescription, revision: String(prepared.revision),
                    includesMaskedMessages: capture.request.query.scope.includeMasked)
                if !prepared.rawDataIncluded {
                    manifest.availableSections = ["messages"]
                    manifest.unavailableSections = ["rawText", "metadata", "identity", "coordinates", "sources", "parameterDetails", "batteryDetails", "gnssDetails", "dropouts"]
                    manifest.completeness = .summary
                }
                let candidate = ReportRenderer.cancellableHTML(snapshot, manifest: manifest, isCancelled: { cancellation.isCancelled })
                try cancellation.check()
                if candidate.utf8.count <= htmlBudget {
                    html = candidate; mode = "interactive"
                }
            }
        }
        if html == nil { html = try summaryHTML(summary, prepared: prepared, cancellation: cancellation) }
        if mode == "interactive", let document = html {
            let pieces = "<section class=\"panel\" id=\"report-attachments\"><p class=\"eyebrow\">PIÈCES DU RAPPORT</p><h2>Données intégrales et manifeste</h2><p><a href=\"rapport.json\" download>JSON intégral de la sélection</a> · <a href=\"manifest.json\" download>Manifeste versionné et SHA256</a></p><p class=\"muted\">\(summary.rawDataIncluded ? "Données brutes incluses." : "Synthèse anonymisée · textes et métadonnées brutes retirés de toutes les pièces.")</p></section>"
            html = document.replacingOccurrences(of: "</main>", with: pieces + "</main>")
            if html!.utf8.count > htmlBudget {
                html = try summaryHTML(summary, prepared: prepared, cancellation: cancellation)
                mode = "summary-with-attachments"
            }
        }
        try cancellation.check()
        guard let html, html.utf8.count <= htmlBudget else {
            throw AnalysisError.engine("La synthèse dépasse le budget HTML ; exportez les données en JSON.")
        }
        try Data(html.utf8).write(to: staging.appendingPathComponent("index.html"), options: .atomic)
        var manifest = prepared.manifest
        if case .object(var value) = manifest {
            value["renderMode"] = .string(mode)
            value["interactiveWorkBudget"] = .integer(5_000)
            value["htmlBudget"] = .integer(Int64(htmlBudget))
            let file = try fileEntry(staging.appendingPathComponent("index.html"), cancellation: cancellation)
            if case .array(var files) = value["files"] {
                files.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(file)))
                value["files"] = .array(files)
            }
            manifest = .object(value)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        return mode
    }

    private static func boundedRead(_ path: URL, budget: Int) throws -> Data {
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= budget else { throw AnalysisError.engine("Le fichier dépasse le budget du rapport interactif.") }
        return try Data(contentsOf: path)
    }

    private static func writeProgress(_ path: URL?, capture: ReportCapture, current: String) {
        guard let path else { return }
        let progress = ImportProgress(completed: capture.manifest.totalLogs, total: capture.manifest.totalLogs, current: current)
        // Optional UI progress must never report a failed export after its
        // complete destination has already been published successfully.
        try? JSONEncoder().encode(progress).write(to: path, options: .atomic)
    }

    private static func fileEntry(_ url: URL, cancellation: ReportCancellation) throws -> ReportExportFile {
        let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
        var digest = SHA256(), size: Int64 = 0
        while let chunk = try stream.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try cancellation.check(); digest.update(data: chunk); size += Int64(chunk.count)
        }
        return .init(name: url.lastPathComponent, sizeBytes: size,
                     sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func verify(_ files: [ReportExportFile], root: URL, cancellation: ReportCancellation) throws {
        for file in files {
            guard ["rapport.json", "summary.json"].contains(file.name) else { throw AnalysisError.engine("Pièce du rapport invalide.") }
            let actual = try fileEntry(root.appendingPathComponent(file.name), cancellation: cancellation)
            guard actual.sizeBytes == file.sizeBytes, actual.sha256 == file.sha256 else {
                throw AnalysisError.engine("Une pièce du rapport a changé avant publication.")
            }
        }
    }

    static func atomicPublishFile(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func atomicPublishFolder(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            let marker = destination.appendingPathComponent("manifest.json")
            let isLink = try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            let metadata = (try? Data(contentsOf: marker)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard !isLink, metadata?["producer"] as? String == "KataLog", metadata?["schemaVersion"] as? Int == 1 else {
                throw AnalysisError.engine("Le dossier de destination existe et n’est pas un rapport KataLog.")
            }
            // Both folders are on the same volume: swap has no interval with a
            // missing or partially replaced destination. The old folder is then
            // left at staging and removed by the caller's defer.
            guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, 0x00000002) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            guard Darwin.rename(source.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private static func summaryHTML(_ summary: ReportSummary, prepared: PreparedReport,
                                    cancellation: ReportCancellation) throws -> String {
        func h(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func help(_ label: String, _ text: String) -> String {
            "<details class=\"report-help\"><summary title=\"\(h(text))\" aria-label=\"Aide : \(h(label))\">ⓘ</summary><p>\(h(text))</p></details>"
        }
        func statLabel(_ label: String, _ text: String) -> String {
            "<div class=\"stat-label\"><span title=\"\(h(text))\">\(h(label))</span>\(help(label, text))</div>"
        }
        let flight = summary.flightSeconds.flatMap { $0.isFinite && $0 >= 0 && (summary.flightLogCount ?? 0) > 0 ? $0 : nil }
        let flightValue = flight.map { String(format: "%.2f", $0 / 60) + "<em> min</em>" } ?? "Non disponible"
        let scanned = summary.scannedDroneCount.map(String.init) ?? "Non disponible"
        let provisional = summary.provisionalDroneCount.map { "\($0) identités provisoires" } ?? "Répartition des identités non disponible"
        let flightCoverage = summary.flightLogCount.map { "Calculé sur \($0) / \(summary.totalLogs) logs" } ?? "Couverture non disponible"
        let families = summary.familyLogCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var rows = ""
        for (name, count) in families.prefix(200) {
            try cancellation.check()
            let percent = Double(count) / Double(max(summary.validLogs, 1)) * 100
            rows += "<div class=\"family-row\"><span>\(h(name))</span><span class=\"bar-track\"><span class=\"bar-fill\" style=\"width:\(percent)%\"></span></span><strong>\(count)</strong></div>"
        }
        let familyNote = families.count > 200 ? "200 familles affichées sur \(families.count). Toutes les familles et occurrences sont conservées dans le JSON joint." : "Une famille compte une seule fois par log. Les états failsafe sont comptés séparément."
        let privacy = summary.rawDataIncluded ? "Données brutes incluses dans le JSON intégral." : "Synthèse anonymisée · textes et métadonnées brutes retirés de toutes les pièces."
        let files = prepared.files.map { "<li><a href=\"\(h($0.name))\" download>\(h($0.name))</a> · \($0.sizeBytes) octets · SHA256 <code>\(h($0.sha256))</code></li>" }.joined()
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>KataLog · Synthèse du rapport</title><style>\(ReportStyle.css)</style></head><body><main class="report-shell">
        <section class="hero"><div><p class="eyebrow">KATALOG · RAPPORT CAPTURÉ</p><h1>Les traces de votre flotte.</h1><p class="lede">\(h(summary.scopeDescription))</p></div><div class="meta"><span class="pill">Révision \(prepared.revision)</span><p>\(h(summary.generatedAt))</p></div></section>
        <p class="notice">Le rapport dépasse le budget du document interactif. Cette synthèse est accompagnée des données JSON intégrales de la sélection. Aucun log ni message sélectionné n’a été supprimé pour respecter le budget.</p>
        <p class="muted">\(privacy) Les fichiers ULog originaux restent inchangés. Une alerte n’est pas une panne confirmée.</p>
        <section class="stats"><div class="stat">\(statLabel("Drones scannés", LibraryHelp.drones))<strong>\(scanned)</strong><small>\(provisional)</small></div><div class="stat">\(statLabel("Fichiers ULog", LibraryHelp.analysisQuality))<strong>\(summary.totalLogs)</strong><small>\(summary.validLogs) lisibles</small></div><div class="stat"><span>Messages sélectionnés</span><strong>\(summary.totalMessages)</strong></div><div class="stat">\(statLabel("Durée enregistrée", LibraryHelp.recordedDuration))<strong>\(String(format: "%.2f", summary.recordedSeconds / 60))<em> min</em></strong><small>Inclut les périodes au sol</small></div><div class="stat">\(statLabel("Temps de vol cumulé", LibraryHelp.flightDuration))<strong>\(flightValue)</strong><small>\(flightCoverage)</small></div></section>
        <section class="panel"><p class="eyebrow">PROFIL DES ALERTES TEXTUELLES</p><div class="heading-with-help"><h2 title="\(h(LibraryHelp.profile))">Les familles présentes</h2>\(help("Profil des alertes", LibraryHelp.profile))</div><div class="family-bars">\(rows.isEmpty ? "<p>Aucun message d’alerte textuel affiché. La couverture de chaque log reste dans le JSON joint.</p>" : rows)</div><p class="muted">\(familyNote)</p><p>\(summary.alertLogs) logs avec alertes · \(summary.failsafeLogs) logs avec failsafe dans le périmètre.</p></section>
        <section class="panel" style="margin-top:20px"><p class="eyebrow">DONNÉES ET TRAÇABILITÉ</p><div class="heading-with-help"><h2>Les pièces du rapport</h2>\(help("Sources et pièces du rapport", LibraryHelp.provenance))</div><ul class="coverage-list">\(files)<li><a href="manifest.json" download>Manifeste versionné et empreintes SHA256</a></li></ul><p>\(summary.detailedCachedLogCount) logs possèdent des détails déjà présents dans le cache au moment de la capture. Les sources n’ont pas été ouvertes pour enrichir ce rapport.</p><p class="muted">\(h(LibraryHelp.provenance))</p><p class="muted">Le document fonctionne hors ligne, en mode clair ou sombre et à l’impression. Les chiffres décrivent la sélection capturée.</p></section></main></body></html>
        """
    }
}
