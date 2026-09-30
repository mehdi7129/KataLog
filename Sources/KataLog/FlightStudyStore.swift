import Combine
import Foundation
import KataLogCore

@MainActor
final class FlightStudyStore: ObservableObject {
    typealias Extractor = @MainActor (String, TelemetryRequest) async throws -> TelemetryResponse
    @Published private(set) var response: TelemetryResponse?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var preferenceWarning: String?
    @Published private(set) var isExporting = false
    @Published var selectedTime: Double?
    private var token = UUID()
    private var task: Task<Void, Never>?
    private var cache: [(key: String, value: TelemetryResponse)] = []
    private weak var library: LibraryStore?
    private let extractor: Extractor?
    private var savedRequest: (@MainActor (String) -> TelemetryRequest?)?
    private var saveRequest: (@MainActor (String, TelemetryRequest) throws -> Void)?
    private var requests: [String: TelemetryRequest] = [:]
    private var currentLogID: String?
    private var pendingKey: String?
    private var exportTask: Task<Void, Error>?
    init(library: LibraryStore) { self.library = library; extractor = nil }
    /// The injected reader permits an anonymous preview and deterministic tests without opening a library.
    init(initialResponse: TelemetryResponse? = nil,
         savedRequest: (@MainActor (String) -> TelemetryRequest?)? = nil,
         saveRequest: (@MainActor (String, TelemetryRequest) throws -> Void)? = nil,
         extractor: @escaping Extractor) {
        self.extractor = extractor; response = initialResponse; currentLogID = initialResponse?.logID
        self.savedRequest = savedRequest; self.saveRequest = saveRequest
    }
    private func preferenceKey(_ logID: String) -> String { AnalysisService.parserVersion + ":" + logID }
    func lastRequest(logID: String) -> TelemetryRequest? {
        let key = preferenceKey(logID)
        let request = requests[key] ?? savedRequest?(key) ?? library?.views.state.studyPreferences?[key]
        guard let request else { return nil }
        guard valid(request) else {
            preferenceWarning = "Préférence d’analyse incompatible : la vue utilise une sélection disponible."; return nil
        }
        return request
    }
    private func valid(_ request: TelemetryRequest) -> Bool {
        request.seriesVersion == 1 && (2...2048).contains(request.budget) && (0...255).contains(request.instance)
        && (request.timeFrom?.isFinite ?? true) && (request.timeTo?.isFinite ?? true)
        && (request.timeFrom == nil || request.timeTo == nil || request.timeFrom! <= request.timeTo!)
        && (request.recipe.map { ["battery", "gnss", "ekf"].contains($0) }
            ?? (request.topic?.isEmpty == false && request.field?.isEmpty == false))
    }
    private func remember(_ request: TelemetryRequest, logID: String) {
        let key = preferenceKey(logID)
        let previous = savedRequest?(key) ?? library?.views.state.studyPreferences?[key]
        requests[key] = request
        guard previous != request else { return }
        do {
            if let saveRequest { try saveRequest(key, request) }
            else if let library { try library.views.setStudy(request, for: key) }
            preferenceWarning = nil
        } catch { preferenceWarning = "Mesures consultables ; préférence non enregistrée : \(error.localizedDescription)" }
    }
    func load(logID: String, request: TelemetryRequest) {
        let key = AnalysisService.parserVersion + ":" + logID + ":" + request.fingerprint
        if isLoading && pendingKey == key { return }
        task?.cancel(); task = nil; token = UUID(); let expected = token
        if currentLogID != logID { selectedTime = nil; currentLogID = logID }
        isLoading = false; pendingKey = nil; errorMessage = nil; response = nil
        guard valid(request) else { errorMessage = "Fenêtre, recette, instance ou budget de courbes invalide."; return }
        if let selectedTime, (request.timeFrom.map { selectedTime < $0 } ?? false) || (request.timeTo.map { selectedTime > $0 } ?? false) {
            self.selectedTime = nil
        }
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let cached = cache.remove(at: index); cache.append(cached)
            remember(request, logID: logID)
            response = cached.value; return
        }
        let reader: Extractor
        if let extractor { reader = extractor }
        else if let library, let engine = library.engineURL {
            let database = library.databaseURL
            reader = { id, query in
                try await TelemetryService.extract(logID: id, request: query, database: database, engine: engine)
            }
        } else { errorMessage = "Moteur d’analyse absent."; return }
        remember(request, logID: logID)
        isLoading = true; pendingKey = key; errorMessage = nil; response = nil
        task = Task { [weak self] in
            do {
                let result = try await reader(logID, request)
                guard !Task.isCancelled, let self, token == expected else { return }
                cache.append((key, result)); if cache.count > 12 { cache.removeFirst(cache.count - 12) }
                response = result; isLoading = false; pendingKey = nil; task = nil
            } catch {
                guard !Task.isCancelled, let self, token == expected else { return }
                errorMessage = error.localizedDescription; isLoading = false; pendingKey = nil; task = nil
            }
        }
    }
    func cancel() { task?.cancel(); task = nil; token = UUID(); isLoading = false; pendingKey = nil }
    func reset() { cancel(); response = nil; selectedTime = nil; errorMessage = nil; preferenceWarning = nil; currentLogID = nil }
    func export(log: FlightLog, to destination: URL, html: Bool) async throws {
        guard !isExporting, !isLoading, let response, response.logID == log.id else {
            throw AnalysisError.engine("Attendez la lecture du relevé avant de l’exporter.")
        }
        guard destination.isFileURL else { throw AnalysisError.engine("Choisissez un fichier local pour le relevé.") }
        let snapshot = try TelemetryReport.snapshot(log: log, response: response, request: lastRequest(logID: log.id))
        isExporting = true
        defer { isExporting = false; exportTask = nil }
        let export: Task<Void, Error>
        if let library {
            export = Task { try await library.export(to: destination, html: html, selection: snapshot) }
        } else {
            // The anonymous preview has no library. It keeps the same rendering and atomic publication contract.
            export = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                if html {
                    let content = ReportRenderer.cancellableHTML(snapshot,
                        manifest: .describing(snapshot, mode: .flight, scopeDescription: "Relevé des séries affichées d’un log"),
                        isCancelled: { Task.isCancelled })
                    try Task.checkCancellation()
                    guard content.utf8.count <= 10 * 1024 * 1024 else {
                        throw AnalysisError.engine("Ce relevé HTML dépasse 10 Mio. Exportez le JSON intégral ; aucun point n’a été supprimé.")
                    }
                    try content.write(to: destination, atomically: true, encoding: .utf8)
                } else {
                    let data = try ReportRenderer.json(snapshot); try Task.checkCancellation()
                    try data.write(to: destination, options: .atomic)
                }
            }
        }
        exportTask = export
        try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
    }
    func cancelExport() { exportTask?.cancel() }
}
