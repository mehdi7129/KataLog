import Combine
import Foundation
import KataLogCore

/// Reviews a local, immutable capture before exporting it. Opening this store
/// never queries the GCS, imports sources, or starts a collection.
@MainActor
final class DiagnosticStore: ObservableObject {
    typealias ServiceLoader = @Sendable (String) async throws -> GCSServiceDiagnosticsResult
    typealias Exporter = @Sendable (URL, DiagnosticReport, DiagnosticJournalSnapshot, [DiagnosticGCSText], Bool, [URL]) async throws -> DiagnosticBundleResult

    @Published private(set) var snapshot: DiagnosticJournalSnapshot?
    @Published private(set) var snapshotJSON = ""
    @Published private(set) var preview: DiagnosticBundlePreview?
    @Published private(set) var isLoading = false
    @Published private(set) var isClearingJournal = false
    @Published private(set) var isFetchingGCS = false
    @Published private(set) var isExporting = false
    @Published private(set) var isCancellingExport = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var serviceMessage: String?
    @Published private(set) var exportMessage: String?
    @Published private(set) var serviceCapturedAt: Date?
    @Published private(set) var serviceFiles: [DiagnosticGCSText] = []
    @Published private(set) var selectedULogs: [URL] = []
    @Published var includePrivateGCS = false { didSet { rebuildPreview() } }
    @Published var includeULogs = false { didSet { rebuildPreview() } }

    private let journal: DiagnosticJournal
    private let serviceLoader: ServiceLoader
    private let exporter: Exporter
    private let canWrite: @MainActor @Sendable () -> Bool
    private var report: DiagnosticReport?
    private var readTask: Task<Void, Never>?
    private var serviceTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var readToken = UUID()
    private var serviceToken = UUID()
    private var serviceHost: String?

    init(journal: DiagnosticJournal, canWrite: @escaping @MainActor @Sendable () -> Bool = { true },
         serviceLoader: @escaping ServiceLoader = { host in
             try await GCSServiceDiagnostics.fetch(endpoint: GCSServiceDiagnostics.endpoint(host: host))
         },
         exporter: @escaping Exporter = { url, report, journal, gcs, includePrivateGCS, ulogs in
             try await DiagnosticBundle.export(to: url, report: report, journal: journal, gcs: gcs,
                 includePrivateGCS: includePrivateGCS, privateULogs: ulogs)
         }) {
        self.journal = journal; self.canWrite = canWrite; self.serviceLoader = serviceLoader; self.exporter = exporter
    }

    var eventCount: Int { snapshot?.events.count ?? 0 }
    var canExport: Bool { preview != nil && !isLoading && !isFetchingGCS && !isExporting }
    var privateULogs: [URL] { includeULogs ? selectedULogs : [] }
    var privateDataRequested: Bool { (includePrivateGCS && !serviceFiles.isEmpty) || !privateULogs.isEmpty }
    var recentEvents: [DiagnosticEvent] { Array((snapshot?.events ?? []).suffix(100).reversed()) }
    var journalStorageExplanation: String {
        guard journal.configuration.persistent else {
            return "Le journal de cette instance est conservé en mémoire uniquement. Les diagnostics enregistrés par une autre instance ne sont pas modifiés."
        }
        let maximum = Int64(journal.configuration.maximumFileBytes * (journal.configuration.maximumArchives + 1))
        let days = Int(journal.configuration.maximumAge / 86_400)
        return "Le journal est conservé au plus \(days) jours et occupe au plus "
            + ByteCountFormatter.string(fromByteCount: maximum, countStyle: .file)
            + ". Les événements anciens sont remplacés automatiquement. Les ULogs et les analyses sont conservés."
    }

    func load(report: DiagnosticReport) {
        guard !isExporting else { return }
        readTask?.cancel(); readToken = UUID(); let expected = readToken
        self.report = report; snapshot = nil; preview = nil; errorMessage = nil; exportMessage = nil; isLoading = true
        do { snapshotJSON = String(decoding: try report.data(), as: UTF8.self) }
        catch { errorMessage = error.localizedDescription; isLoading = false; return }
        let journal = self.journal
        readTask = Task { [weak self] in
            do {
                let capture = try await Task.detached(priority: .utility) { try journal.snapshot() }.value
                try Task.checkCancellation()
                guard let self, readToken == expected else { return }
                snapshot = capture; isLoading = false; readTask = nil; rebuildPreview()
            } catch {
                guard let self, readToken == expected, !Task.isCancelled else { return }
                errorMessage = "Le journal local n’a pas pu être lu. " + error.localizedDescription
                isLoading = false; readTask = nil
            }
        }
    }

    /// An explicit request only. This service endpoint does not communicate
    /// with flight controls or schedule drone-log transfers.
    func fetchGCS(host: String) {
        guard !isFetchingGCS, !isExporting else { return }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { serviceMessage = "Configurez l’adresse de votre GCS dans Collecte GCS, puis réessayez."; return }
        serviceToken = UUID(); let expected = serviceToken
        serviceHost = host; serviceFiles = []; serviceCapturedAt = nil
        isFetchingGCS = true; serviceMessage = nil; exportMessage = nil; rebuildPreview()
        journal.record(.gcsDiagnosticsStarted)
        let loader = serviceLoader
        serviceTask = Task { [weak self] in
            do {
                let capture = try await loader(host)
                try Task.checkCancellation()
                guard let self, serviceToken == expected else { return }
                serviceFiles = capture.files.compactMap(Self.serviceText)
                serviceCapturedAt = capture.fetchedAt
                serviceMessage = serviceFiles.isEmpty
                    ? "La GCS a répondu, mais aucun journal de service exploitable n’a été fourni."
                    : "Journaux récupérés. " + (capture.currentBootOnly ? "Ils couvrent le démarrage actuel de la GCS ; récupérez-les avant un reboot." : "Leur période dépend des fichiers fournis par la GCS.")
                isFetchingGCS = false; serviceTask = nil; rebuildPreview()
                journal.record(.gcsDiagnosticsCompleted, metrics: [.items: Int64(serviceFiles.count)])
                reloadJournalAfterService()
            } catch {
                guard let self, serviceToken == expected, !Task.isCancelled else { return }
                serviceMessage = error.localizedDescription
                isFetchingGCS = false; serviceTask = nil; rebuildPreview()
                journal.record(.gcsDiagnosticsFailed, code: Self.serviceErrorCode(error))
                reloadJournalAfterService()
            }
        }
    }

    func cancelGCS(refreshJournal: Bool = true) {
        let wasFetching = isFetchingGCS
        serviceToken = UUID(); serviceTask?.cancel(); serviceTask = nil; isFetchingGCS = false
        serviceMessage = "Récupération GCS annulée. Le diagnostic de KataLog reste disponible."; rebuildPreview()
        if wasFetching { journal.record(.gcsDiagnosticsFailed, code: .cancelled) }
        if wasFetching && refreshJournal { reloadJournalAfterService() }
    }

    func endpointChanged(to host: String) {
        guard let serviceHost, serviceHost != host.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        cancelGCS(); self.serviceHost = nil; serviceFiles = []; serviceCapturedAt = nil
        serviceMessage = "L’adresse GCS a changé. Récupérez ses journaux pour ce nouveau diagnostic."; rebuildPreview()
    }

    func selectULogs(_ urls: [URL]) {
        guard !isExporting else { return }
        // Files are reviewed by the core exporter too, including size and path
        // checks. The UI never silently selects the whole library.
        selectedULogs = Array(Set(urls)).sorted { $0.lastPathComponent < $1.lastPathComponent }
        exportMessage = nil; rebuildPreview()
    }

    func export(to url: URL) {
        guard canExport, let report, let snapshot else { return }
        let gcs = serviceFiles, privateGCS = includePrivateGCS, ulogs = privateULogs, exporter = self.exporter
        isExporting = true; isCancellingExport = false; exportMessage = nil; errorMessage = nil
        journal.record(.exportStarted)
        exportTask = Task { [weak self] in
            do {
                let result = try await exporter(url, report, snapshot, gcs, privateGCS, ulogs)
                try Task.checkCancellation()
                guard let self else { return }
                exportMessage = "Diagnostic exporté · \(result.fileCount) fichiers. Aucun envoi automatique.";
                journal.record(.exportCompleted, metrics: [.items: Int64(result.fileCount)])
                finishExport()
            } catch is CancellationError {
                guard let self else { return }
                exportMessage = "Export annulé. Aucun diagnostic partiel n’a été publié."; finishExport()
                journal.record(.exportFailed, code: .cancelled)
            } catch {
                guard let self else { return }
                errorMessage = "Le diagnostic n’a pas pu être exporté. " + error.localizedDescription; finishExport()
                journal.record(.exportFailed, code: .exportFailed)
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        isCancellingExport = true; exportTask?.cancel()
    }

    func clearJournal() {
        guard !isLoading, !isFetchingGCS, !isExporting else { return }
        guard canWrite() else {
            errorMessage = "Le journal ne peut pas être effacé pendant une opération ou dans cette instance en lecture seule."; return
        }
        readToken = UUID(); let expected = readToken
        isLoading = true; isClearingJournal = true; preview = nil; errorMessage = nil; exportMessage = nil
        let journal = self.journal
        readTask = Task { [weak self] in
            do {
                let capture = try await Task.detached(priority: .utility) {
                    try journal.clear(); journal.record(.journalCleared); return try journal.snapshot()
                }.value
                try Task.checkCancellation()
                guard let self, readToken == expected else { return }
                snapshot = capture; isLoading = false; isClearingJournal = false; readTask = nil
                exportMessage = "Journal de KataLog effacé. Les ULogs, analyses et fichiers GCS restent conservés."; rebuildPreview()
            } catch {
                guard let self, readToken == expected, !Task.isCancelled else { return }
                errorMessage = "Le journal n’a pas pu être effacé. " + error.localizedDescription
                isLoading = false; isClearingJournal = false; readTask = nil
            }
        }
    }

    /// The application lifecycle waits while isExporting stays true, so the
    /// staged ZIP has time to be removed before termination completes.
    func prepareForTermination() {
        readToken = UUID(); readTask?.cancel(); readTask = nil; isLoading = false; isClearingJournal = false
        if isFetchingGCS { cancelGCS(refreshJournal: false) }
        cancelExport()
    }

    func dismiss() {
        readToken = UUID(); readTask?.cancel(); readTask = nil; isLoading = false; isClearingJournal = false
        if isFetchingGCS { cancelGCS(refreshJournal: false) }
        // Clear opt-ins and private attachments when this review ends. Export
        // must finish or be cancelled before the view allows dismissal.
        guard !isExporting else { return }
        includePrivateGCS = false; includeULogs = false; selectedULogs = []
        serviceFiles = []; serviceCapturedAt = nil; serviceHost = nil; serviceMessage = nil
        report = nil; snapshot = nil; snapshotJSON = ""; preview = nil; errorMessage = nil; exportMessage = nil
    }

    private func finishExport() { isExporting = false; isCancellingExport = false; exportTask = nil }

    private func reloadJournalAfterService() {
        guard let report, !isExporting else { return }
        load(report: report)
    }

    private func rebuildPreview() {
        guard let report, let snapshot else { preview = nil; return }
        do {
            preview = try DiagnosticBundle.preview(report: report, journal: snapshot, gcs: serviceFiles,
                includePrivateGCS: includePrivateGCS, privateULogs: privateULogs)
            errorMessage = nil
        } catch { preview = nil; errorMessage = error.localizedDescription }
    }

    private static func serviceText(_ file: GCSServiceDiagnosticFile) -> DiagnosticGCSText? {
        let source: DiagnosticGCSText.Source
        switch file.name.lowercased() {
        case "mosquitto.log": source = .mosquitto
        case "reactor.log": source = .reactor
        case "python.log": source = .python
        case "node.log": source = .node
        case "metadata.json": source = .metadata
        default: return nil
        }
        return DiagnosticGCSText(source: source, text: file.text)
    }

    private static func serviceErrorCode(_ error: Error) -> DiagnosticEvent.Code {
        switch error as? GCSServiceDiagnosticsError {
        case .timeout: .timeout
        case .offline: .connectionUnavailable
        default: .gcsDiagnosticsUnavailable
        }
    }
}
