import AppKit
import Combine
import Foundation
import KataLogCore
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published var snapshot: FleetSnapshot = .empty
    @Published var isImporting = false
    @Published var isLoading = false
    @Published var progress: ImportProgress?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var selectedFlight: FlightLog?
    @Published private(set) var isLoadingFlight = false
    @Published private(set) var flightError: String?
    private var flightTask: Task<Void, Never>?
    private var flightToken = UUID()
    private var analysisRefreshTask: Task<Void, Never>?
    var needsAnalysisRefresh: Bool {
        snapshot.validLogs.contains { $0.metadata["parserVersion"] != AnalysisService.parserVersion }
    }
    let databaseURL: URL
    let annotations: DroneAnnotationStore
    private var annotationSubscription: AnyCancellable?
    private let engineOverride: URL?
    private let snapshotURL: URL
    private let progressURL: URL
    private var importTask: Task<FleetSnapshot, Error>?
    private var progressTask: Task<Void, Never>?
    private var loadToken = UUID()

    init(storageDirectory: URL? = nil, engine: URL? = nil) {
        engineOverride = engine
        let base: URL
        if let storageDirectory { base = storageDirectory }
        else if let override = ProcessInfo.processInfo.environment["KATALOG_LIBRARY_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KataLog", isDirectory: true)
        }
        annotations = DroneAnnotationStore(url: base.appendingPathComponent("annotations.json"))
        databaseURL = base.appendingPathComponent("library.sqlite")
        snapshotURL = base.appendingPathComponent("library.json")
        progressURL = base.appendingPathComponent("progress.json")
        annotationSubscription = annotations.$state.dropFirst().sink { [weak self] state in
            guard let self else { return }
            self.snapshot = state.applying(to: self.snapshot)
            if let selected = self.selectedFlight { self.selectedFlight = state.applying(to: selected, relatedLogs: self.snapshot.logs) }
        }
        reload()
    }

    func reload() {
        guard !isImporting else { return }
        let token = UUID(); loadToken = token
        let url = snapshotURL
        let database = databaseURL, engine = engineURL
        let hasDatabase = FileManager.default.fileExists(atPath: database.path)
        guard hasDatabase || FileManager.default.fileExists(atPath: url.path) else { return }
        isLoading = true
        Task {
            defer { if loadToken == token { isLoading = false } }
            do {
                let result: FleetSnapshot
                if hasDatabase, let engine {
                    result = try await AnalysisService.snapshot(database: database, engine: engine)
                } else {
                    result = try await Task.detached { try AnalysisService.decode(Data(contentsOf: url)) }.value
                }
                if loadToken == token {
                    annotations.reconcileIdentities(in: result.logs)
                    snapshot = annotations.state.applying(to: result)
                }
            } catch {
                if loadToken == token { errorMessage = "La bibliothèque ne peut pas être lue : \(error.localizedDescription)" }
            }
        }
    }

    func chooseFolder() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Importer les logs PX4"
        panel.message = "Choisissez une carte SD ou le dossier contenant plusieurs drones. Les fichiers source sont lus sans modification."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyser"
        if panel.runModal() == .OK, let url = panel.url { importFolder(url) }
    }

    func importFolder(_ folder: URL) {
        guard !isImporting else { return }
        Task { _ = try? await importCollectedFolder(folder) }
    }

    /// Used by the collection queue; completion means the snapshot has been committed.
    func importCollectedFolder(_ folder: URL) async throws -> FleetSnapshot {
        while isImporting { try await Task.sleep(for: .milliseconds(200)) }
        try Task.checkCancellation()
        guard let engine = engineURL else {
            let message = "Le moteur ULog est absent du bundle de l’app."
            errorMessage = message; throw AnalysisError.unavailable(message)
        }
        loadToken = UUID(); isLoading = false
        isImporting = true; errorMessage = nil; statusMessage = nil; progress = nil
        try? FileManager.default.removeItem(at: progressURL)
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let data = try? Data(contentsOf: self.progressURL), let value = try? JSONDecoder().decode(ImportProgress.self, from: data) { self.progress = value }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        let database = databaseURL, output = snapshotURL, progressFile = progressURL
        let task = Task<FleetSnapshot, Error> { [self] in
            defer { self.isImporting = false; self.progressTask?.cancel(); self.progressTask = nil; self.importTask = nil }
            do {
                let result = try await AnalysisService.scan(folder: folder, database: database, output: output, progress: progressFile, engine: engine)
                self.annotations.reconcileIdentities(in: result.logs)
                self.snapshot = self.annotations.state.applying(to: result)
                let stats = result.importStats
                self.statusMessage = "\(stats.discovered) fichiers trouvés · \(stats.imported) nouveaux · \(stats.unchanged) inchangés · \(stats.duplicates) copies identiques · \(stats.failed) erreurs."
                return self.snapshot
            } catch is CancellationError {
                self.statusMessage = "Import annulé. Les logs déjà traités sont conservés ; un nouvel import reprendra la lecture."
                Task { self.reload() }
                throw CancellationError()
            } catch { self.errorMessage = error.localizedDescription; throw error }
        }
        importTask = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func loadFlight(_ log: FlightLog) {
        flightTask?.cancel()
        let token = UUID(); flightToken = token
        selectedFlight = annotations.state.applying(to: log, relatedLogs: snapshot.logs); isLoadingFlight = true; flightError = nil
        guard let engine = engineURL else { isLoadingFlight = false; flightError = "Moteur d’analyse absent."; return }
        let database = databaseURL
        flightTask = Task { [weak self] in
            do {
                let detailed = try await AnalysisService.detail(logID: log.id, database: database, engine: engine)
                guard !Task.isCancelled, let self, self.flightToken == token else { return }
                self.selectedFlight = self.annotations.state.applying(to: detailed, relatedLogs: self.snapshot.logs); self.isLoadingFlight = false; self.flightTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.flightToken == token else { return }
                self.flightError = error.localizedDescription; self.isLoadingFlight = false; self.flightTask = nil
            }
        }
    }

    func closeFlight() {
        flightToken = UUID(); flightTask?.cancel(); flightTask = nil
        selectedFlight = nil; isLoadingFlight = false; flightError = nil
    }

    func refreshAnalysis() {
        guard !isImporting, analysisRefreshTask == nil else { return }
        let paths = Set(snapshot.validLogs.filter { $0.metadata["parserVersion"] != AnalysisService.parserVersion }
            .flatMap(\.sourcePaths).filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }).sorted { $0.path < $1.path }
        guard !paths.isEmpty else { errorMessage = "Les sources ULog sont absentes. Réimportez leurs copies pour actualiser les analyses."; return }
        analysisRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.analysisRefreshTask = nil }
            do {
                for folder in paths {
                    try Task.checkCancellation()
                    _ = try await self.importCollectedFolder(folder)
                }
                self.statusMessage = "Analyses locales actualisées · aucun téléchargement demandé."
            } catch is CancellationError {} catch { self.errorMessage = error.localizedDescription }
        }
    }

    func cancelImport() { analysisRefreshTask?.cancel(); importTask?.cancel() }

    func revealSource(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { errorMessage = "Le fichier source n’est plus présent : \(path)"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func exportHTML() { export(html: true) }
    func exportJSON() { export(html: false) }

    private func export(html: Bool) {
        guard !snapshot.logs.isEmpty else { errorMessage = "Importez un dossier avant de générer un rapport."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [html ? .html : .json]
        panel.nameFieldStringValue = "KataLog-rapport.\(html ? "html" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = self.snapshot
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if html { try ReportRenderer.html(snapshot).write(to: url, atomically: true, encoding: .utf8) }
                    else { try ReportRenderer.json(snapshot).write(to: url, options: .atomic) }
                }.value
                statusMessage = "Rapport exporté : \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { errorMessage = "Échec de l’export : \(error.localizedDescription)" }
        }
    }

    private var engineURL: URL? {
        if let engineOverride { return engineOverride }
        if let url = Bundle.main.url(forResource: "analyzer", withExtension: "py") { return url }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "analyzer", withExtension: "py", subdirectory: "Resources") { return url }
        #endif
        return nil
    }
}
