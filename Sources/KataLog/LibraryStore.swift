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
    @Published private(set) var isExporting = false
    @Published private(set) var isReadOnly = false
    @Published private(set) var isMaintainingLibrary = false
    @Published private(set) var isStartupBlocked = false
    private(set) var recoveredAtStartup = false
    private var startupRecoveryTask: Task<Void, Never>?
    @Published private(set) var historyPage: LibraryLogPage?
    @Published private(set) var currentHistoryCursor: String?
    @Published private(set) var groupPage: LibraryGroupPage?
    @Published private(set) var dronePage: LibraryDronePage?
    @Published private(set) var mapPage: LibraryMapPage?
    @Published private(set) var occurrencePage: LibraryMessagePage?
    @Published private(set) var isQuerying = false
    @Published private(set) var isCancellingQuery = false
    @Published private(set) var queryWasCancelled = false
    @Published private(set) var queryError: String?
    @Published private(set) var catalogue: LibraryCataloguePage?
    @Published private(set) var catalogueError: String?
    private var queryTask: Task<Void, Never>?
    @Published private(set) var queryToken = UUID()
    private var viewSubscription: AnyCancellable?
    var hasExternalActivity: () -> Bool = { false }
    var willMaintainLibrary: () throws -> Void = {}
    var willRestoreLibrary: () throws -> Void = {}
    var didRestoreLibrary: () throws -> Void = {}
    private var writerLease: LibraryWriterLease?
    let storageDirectory: URL
    let diagnostics: DiagnosticJournal
    lazy var diagnosticStore = DiagnosticStore(journal: diagnostics, canWrite: { [weak self] in
        guard let self else { return false }
        return !isReadOnly && !isImporting && !isExporting && !isMaintainingLibrary && !hasExternalActivity()
    })
    private var diagnosticStopRecorded = false
    private var exportTask: Task<Void, Error>?
    @Published private(set) var lastReportExport: ReportExportResult?
    @Published private(set) var reportProgress: ImportProgress?
    @Published private(set) var selectedFlight: FlightLog?
    @Published var activeDetailLoads = 0
    @Published private(set) var isLoadingFlight = false
    @Published private(set) var flightError: String?
    private var flightTask: Task<Void, Never>?
    private var flightToken = UUID()
    private var analysisRefreshTask: Task<Void, Never>?
    var needsAnalysisRefresh: Bool {
        if let count = historyPage?.totals.libraryStaleAnalysisLogs { return count > 0 }
        if let count = historyPage?.totals.staleAnalysisLogs { return count > 0 }
        return snapshot.validLogs.contains { $0.metadata["parserVersion"] != AnalysisService.parserVersion }
    }
    let databaseURL: URL
    let annotations: DroneAnnotationStore
    let views: LibraryViewStore
    lazy var clients = ClientStore(library: self)
    @Published private(set) var mapProximity: GeographicProximity?
    var resetCollectionState: () throws -> Void = {}
    var clientDidDelete: (String) async throws -> Void = { _ in }
    var clientProfilesDidLoad: (Set<String>) async throws -> Void = { _ in }
    private var annotationSubscription: AnyCancellable?
    private let engineOverride: URL?
    private let snapshotURL: URL
    private let progressURL: URL
    private var importTask: Task<FleetSnapshot, Error>?
    private var progressTask: Task<Void, Never>?
    private var loadToken = UUID()
    private var reloadTask: Task<Void, Never>?
    private(set) var usesPagedNavigation = false
    var historySortOverride: String?
    private var indexPrepared = false
    private lazy var navigationCache = LibraryNavigationCache(directory: storageDirectory)
    private var activeQueryKey: Data?
    private var displayedQueryKeys: [String: Data] = [:]
    @Published private(set) var historyResultsCurrent = false
    @Published private(set) var groupResultsCurrent = false
    @Published private(set) var droneResultsCurrent = false
    @Published private(set) var occurrenceResultsCurrent = false

    func invalidateNavigationCache() { navigationCache.invalidate() }

    init(storageDirectory: URL? = nil, engine: URL? = nil, pagedNavigation: Bool = false) {
        usesPagedNavigation = pagedNavigation
        engineOverride = engine
        let base = AppPreviewConfiguration().libraryDirectory(storageDirectory: storageDirectory)
        self.storageDirectory = base
        var writable = false
        do {
            let lease = try LibraryWriterLease(directory: base)
            writerLease = lease; writable = lease.isWritable
        } catch { errorMessage = error.localizedDescription }
        if !AppPreviewConfiguration().reviewBuild, storageDirectory == nil && ProcessInfo.processInfo.environment["KATALOG_LIBRARY_DIR"] == nil,
           NSRunningApplication.runningApplications(withBundleIdentifier: "com.mehdiguiard.katalog")
            .contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            writable = false
        }
        // Check under the acquired lease: a previous writer may have left its
        // recovery journal just before releasing the library.
        let pendingRestore = LibraryStorageService.hasPendingRestore(in: base)
        isStartupBlocked = pendingRestore
        isReadOnly = !writable
        diagnostics = DiagnosticJournal(directory: base.appendingPathComponent("Diagnostics", isDirectory: true), configuration: .init(persistent: writable))
        if !pendingRestore { diagnostics.record(.appStarted) }
        if !writable { statusMessage = "Bibliothèque en lecture seule. Fermez l’autre instance de KataLog puis relancez l’app pour modifier ou collecter." }
        annotations = DroneAnnotationStore(url: base.appendingPathComponent("annotations.json"), canWrite: writable)
        views = LibraryViewStore(url: base.appendingPathComponent("views.json"), canWrite: writable)
        databaseURL = base.appendingPathComponent("library.sqlite")
        snapshotURL = base.appendingPathComponent("library.json")
        progressURL = base.appendingPathComponent("progress.json")
        annotations.canMutate = { [weak self] in self?.isMaintainingLibrary == false && self?.isStartupBlocked == false }
        views.canMutate = { [weak self] in self?.isMaintainingLibrary == false && self?.isStartupBlocked == false }
        annotationSubscription = annotations.$state.dropFirst().sink { [weak self] state in
            guard let self else { return }
            self.snapshot = state.applying(to: self.snapshot)
            if let selected = self.selectedFlight { self.selectedFlight = state.applying(to: selected, relatedLogs: self.snapshot.logs) }
            if self.historyPage != nil || self.usesPagedNavigation {
                Task { @MainActor [weak self] in self?.loadHistory() }
            }
        }
        viewSubscription = views.$state
            .removeDuplicates { $0.activeScope == $1.activeScope && $0.maskedMessageKeys == $1.maskedMessageKeys && $0.historySort == $1.historySort }
            .dropFirst().sink { [weak self] _ in
            guard let self, self.historyPage != nil || self.usesPagedNavigation else { return }
            // @Published sends before assignment. Query on the next actor turn
            // so it captures the newly selected scope and sort order.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mapPage = nil; self.dronePage = nil; self.catalogue = nil
                self.loadHistory()
            }
        }
        if isStartupBlocked { recoverStartup() } else { reload() }
    }

    /// No query, migration or collector write may interpret a partial swap as
    /// an empty library. The existing writer lease is inherited by the helper.
    private func recoverStartup() {
        guard !isReadOnly else {
            errorMessage = "Une restauration interrompue doit être récupérée par l’instance qui détient la bibliothèque. Fermez les autres instances puis relancez KataLog."
            return
        }
        guard let engine = availableEngineURL else {
            isReadOnly = true
            errorMessage = "La restauration interrompue ne peut pas être récupérée : moteur d’analyse absent. La bibliothèque reste bloquée ; relancez KataLog après réparation."
            return
        }
        isMaintainingLibrary = true
        statusMessage = "Récupération de la restauration interrompue…"
        startupRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { isMaintainingLibrary = false; startupRecoveryTask = nil }
            do {
                let result = try await LibraryStorageService.recoverRestore(library: storageDirectory, engine: engine)
                guard result["restoreVersion"]?.countValue == 1, result["recovered"] == .bool(true),
                      !LibraryStorageService.hasPendingRestore(in: storageDirectory) else {
                    throw AnalysisError.engine("La récupération n’a pas confirmé un état complet.")
                }
                annotations.reload(); views.reload()
                try didRestoreLibrary()
                recoveredAtStartup = true; isStartupBlocked = false
                diagnostics.record(.appStarted)
                statusMessage = "Bibliothèque récupérée après une restauration interrompue. Les fichiers de récupération sont conservés."
                isMaintainingLibrary = false
                clients.reload(); reload()
            } catch {
                isReadOnly = true; statusMessage = nil
                errorMessage = "La restauration interrompue n’a pas pu être récupérée : \(error.localizedDescription) La bibliothèque reste bloquée ; ses fichiers sont conservés. Relancez KataLog après réparation."
            }
        }
    }

    func reload() {
        guard !isStartupBlocked, !isMaintainingLibrary, !isImporting else { return }
        invalidateNavigationCache()
        if usesPagedNavigation { loadHistory(); return }
        let token = UUID(); loadToken = token
        let url = snapshotURL
        let database = databaseURL, engine = engineURL
        let hasDatabase = FileManager.default.fileExists(atPath: database.path)
        guard hasDatabase || FileManager.default.fileExists(atPath: url.path) else { return }
        isLoading = true
        reloadTask?.cancel()
        reloadTask = Task {
            defer { if loadToken == token { isLoading = false } }
            do {
                let result: FleetSnapshot
                if hasDatabase, let engine {
                    result = try await AnalysisService.snapshot(database: database, engine: engine, readOnly: true)
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
        guard !isReadOnly, !isMaintainingLibrary, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Importer les logs PX4"
        panel.message = "Choisissez une carte SD ou le dossier contenant plusieurs drones. Les fichiers source sont lus sans modification."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyser"
        if panel.runModal() == .OK, let url = panel.url { importFolder(url) }
    }

    func importFolder(_ folder: URL, archiveDestination: URL? = nil, clientID: String? = nil) {
        guard !isReadOnly, !isMaintainingLibrary, !isImporting else { return }
        let destination = clientID ?? views.state.activeScope.clientID ?? ""
        Task { _ = try? await importCollectedFolder(folder, archiveDestination: archiveDestination, clientID: destination) }
    }

    /// Used by the collection queue; completion means the snapshot has been committed.
    func importCollectedFolder(_ folder: URL, expectedLogID: String? = nil, archiveDestination: URL? = nil, clientID: String? = nil) async throws -> FleetSnapshot {
        guard !isReadOnly, !isMaintainingLibrary else { throw AnalysisError.engine("La bibliothèque est occupée ou en lecture seule.") }
        while isImporting || isQuerying || isLoading || activeDetailLoads > 0 { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        guard !isReadOnly, !isMaintainingLibrary else { throw AnalysisError.engine("La bibliothèque est occupée ou en lecture seule.") }
        guard let engine = engineURL else {
            let message = "Le moteur ULog est absent du bundle de l’app."
            errorMessage = message; throw AnalysisError.unavailable(message)
        }
        loadToken = UUID(); isLoading = false
        isImporting = true; errorMessage = nil; statusMessage = nil; progress = nil
        let diagnosticOperation = UUID().uuidString
        diagnostics.record(.importStarted, correlation: diagnosticOperation)
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
            defer { self.invalidateNavigationCache(); self.isImporting = false; self.progressTask?.cancel(); self.progressTask = nil; self.importTask = nil }
            do {
                let result: FleetSnapshot
                if self.usesPagedNavigation {
                    let scanned = try await AnalysisService.scanPaged(folder: folder, database: database, output: output, progress: progressFile, engine: engine, archiveDestination: archiveDestination, clientID: clientID)
                    var request = LibraryQueryRequest(annotations: self.annotations.state)
                    request.scope.includeMasked = true
                    if let expectedLogID { request.scope.logIDs = [expectedLogID] }
                    var page = try await LibraryQueryService.page(LibraryLogPage.self, request: request, database: database, engine: engine, readOnly: true).snapshot
                    page.importStats = scanned.importStats; page.archiveResult = scanned.archiveResult; result = page
                } else {
                    result = try await AnalysisService.scan(folder: folder, database: database, output: output, progress: progressFile, engine: engine, archiveDestination: archiveDestination, clientID: clientID)
                }
                self.annotations.reconcileIdentities(in: result.logs)
                let annotated = self.annotations.state.applying(to: result)
                if !self.usesPagedNavigation { self.snapshot = annotated }
                let stats = result.importStats
                self.statusMessage = "\(stats.discovered) fichiers trouvés · \(stats.imported) nouveaux · \(stats.unchanged) inchangés · \(stats.duplicates) copies identiques · \(stats.failed) erreurs."
                if archiveDestination != nil {
                    self.statusMessage = (self.statusMessage ?? "") + " Archives : \(stats.archiveCompleted ?? 0) copies vérifiées (\(stats.archiveReused ?? 0) réutilisées) · \(stats.archiveFailed ?? 0) erreurs · \(stats.archiveSkipped ?? 0) ignorées."
                    if (stats.archiveFailed ?? 0) > 0 {
                        self.errorMessage = "\(stats.archiveFailed ?? 0) copies d’archive ont échoué : ces fichiers n’ont pas été analysés. Les analyses déjà présentes et les originaux sont conservés. Vérifiez l’espace disponible et l’accès au dossier d’archive avant de recommencer."
                    }
                }
                self.diagnostics.record(.importCompleted, code: stats.failed > 0 ? .analysisFailed : .none, correlation: diagnosticOperation, metrics: [.items: Int64(stats.discovered), .completedItems: Int64(stats.imported + stats.unchanged + stats.duplicates)])
                if self.usesPagedNavigation { Task { self.loadHistory() } }
                return annotated
            } catch is CancellationError {
                self.diagnostics.record(.importFailed, code: .cancelled, correlation: diagnosticOperation)
                self.statusMessage = "Import annulé. Les logs déjà traités sont conservés ; un nouvel import reprendra la lecture."
                Task { self.reload() }
                throw CancellationError()
            } catch { self.diagnostics.record(.importFailed, code: .analysisFailed, correlation: diagnosticOperation); self.errorMessage = error.localizedDescription; throw error }
        }
        importTask = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func loadFlight(_ log: FlightLog) {
        guard !isStartupBlocked else { return }
        flightTask?.cancel()
        let token = UUID(); flightToken = token
        selectedFlight = annotations.state.applying(to: log, relatedLogs: snapshot.logs); isLoadingFlight = true; flightError = nil
        guard let engine = engineURL else { isLoadingFlight = false; flightError = "Moteur d’analyse absent."; return }
        let database = databaseURL
        flightTask = Task { [weak self] in
            do {
                let detailed = try await AnalysisService.detail(logID: log.id, database: database, engine: engine,
                                                                readOnly: self?.isReadOnly == true || self?.isImporting == true || self?.isMaintainingLibrary == true)
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
        guard !isReadOnly, !isMaintainingLibrary, !isImporting, !isQuerying, !isLoading, activeDetailLoads == 0,
              analysisRefreshTask == nil, let engine = engineURL else { return }
        isImporting = true; errorMessage = nil; progress = nil
        try? FileManager.default.removeItem(at: progressURL)
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let data = try? Data(contentsOf: progressURL), let value = try? JSONDecoder().decode(ImportProgress.self, from: data) { progress = value }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        analysisRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.analysisRefreshTask = nil; self.isImporting = false; self.progressTask?.cancel(); self.progressTask = nil; self.reload() }
            do {
                let data = try await AnalysisService.run(["refresh-analysis", "--database", self.databaseURL.path,
                    "--progress", self.progressURL.path], engine: engine)
                let result = try JSONDecoder().decode(JSONValue.self, from: data)
                self.statusMessage = "\(result["reanalyzed"]?.countValue ?? 0) analyses actualisées · \(result["unavailable"]?.countValue ?? 0) sources absentes · \(result["failed"]?.countValue ?? 0) erreurs. Les anciennes analyses sans source sont conservées."
            } catch is CancellationError { self.statusMessage = "Actualisation arrêtée. Les analyses déjà traitées sont conservées." }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    func cancelImport() { analysisRefreshTask?.cancel(); importTask?.cancel() }
    /// Keep mutations disabled until the owned helper has actually stopped.
    /// Invalidating the token also prevents a late response from publishing.
    func cancelQuery() async {
        guard isQuerying, !isCancellingQuery, let task = queryTask else { return }
        isCancellingQuery = true
        let token = UUID(); queryToken = token
        task.cancel()
        await task.value
        guard queryToken == token else { return }
        queryTask = nil; isQuerying = false; isCancellingQuery = false
        queryWasCancelled = true; queryError = nil
    }
    func prepareForTermination() {
        FlightWindowCoordinator.shared.closeAll(library: self)
        diagnosticStore.prepareForTermination()
        if !diagnosticStopRecorded { diagnostics.record(.appStopped); diagnostics.flush(); diagnosticStopRecorded = true }
        cancelImport(); exportTask?.cancel(); queryTask?.cancel(); flightTask?.cancel(); reloadTask?.cancel()
        startupRecoveryTask?.cancel()
        clients.cancelRead()
        progressTask?.cancel(); queryToken = UUID(); flightToken = UUID(); loadToken = UUID()
        isQuerying = false; isCancellingQuery = false; isLoading = false; isLoadingFlight = false
    }
    var hasActiveWork: Bool { hasExternalActivity() || activeDetailLoads > 0 || isImporting || isExporting || isMaintainingLibrary || isQuerying || isLoading || isLoadingFlight || diagnosticStore.isLoading || diagnosticStore.isFetchingGCS || diagnosticStore.isExporting }

    func revealSource(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { errorMessage = "Le fichier source n’est plus présent : \(path)"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func exportHTML() { export(html: true) }
    func exportJSON() { export(html: false) }

    private func export(html: Bool) {
        guard !isExporting else { statusMessage = "Un export est déjà en cours."; return }
        guard !snapshot.logs.isEmpty else { errorMessage = "Importez un dossier avant de générer un rapport."; return }
        let panel = NSSavePanel()
        if usesPagedNavigation && html {
            panel.title = "Exporter toute la bibliothèque"
            panel.message = "Le rapport HTML est un dossier avec index.html, les données complètes et un manifeste de vérification."
            panel.nameFieldStringValue = "KataLog-rapport"
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                Task { do { _ = try await exportReport(to: url, mode: .full, options: .init(format: .html)) }
                    catch { errorMessage = "Échec de l’export : \(error.localizedDescription)" } }
            }
            return
        }
        panel.allowedContentTypes = [html ? .html : .json]
        panel.nameFieldStringValue = "KataLog-rapport.\(html ? "html" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await export(to: url, html: html)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError { statusMessage = "Export annulé. Le fichier précédent est conservé." }
            catch { errorMessage = "Échec de l’export : \(error.localizedDescription)" }
        }
    }

    /// A single export captures one immutable annotated revision. The final file
    /// is only replaced after rendering and a final cancellation check.
    func export(to url: URL, html: Bool, selection: FleetSnapshot? = nil) async throws {
        guard !isStartupBlocked else { throw AnalysisError.engine(errorMessage ?? "La restauration de la bibliothèque est en cours.") }
        if usesPagedNavigation && selection == nil {
            _ = try await exportReport(to: url, mode: .full, options: .init(format: html ? .html : .json))
            return
        }
        guard !isExporting else { throw AnalysisError.engine("Un export est déjà en cours.") }
        isExporting = true; errorMessage = nil; statusMessage = "Préparation du rapport…"
        let diagnosticOperation = UUID().uuidString
        diagnostics.record(.exportStarted, correlation: diagnosticOperation)
        var diagnosticCompleted = false
        var diagnosticFailure: DiagnosticEvent.Code = .exportFailed
        defer { diagnostics.record(diagnosticCompleted ? .exportCompleted : .exportFailed, code: diagnosticCompleted ? .none : diagnosticFailure, correlation: diagnosticOperation) }
        defer { isExporting = false; exportTask = nil }
        let captured = selection ?? snapshot
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if html {
                let contents = ReportRenderer.cancellableHTML(captured,
                    manifest: .describing(captured, mode: selection == nil ? .full : .flight), isCancelled: { Task.isCancelled })
                try Task.checkCancellation()
                guard contents.utf8.count <= 10 * 1024 * 1024 else {
                    throw AnalysisError.engine("Ce relevé dépasse 10 Mio en HTML. Exportez le JSON intégral ou utilisez le rapport de bibliothèque avec données jointes.")
                }
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } else {
                let contents = try ReportRenderer.json(captured)
                try Task.checkCancellation()
                try contents.write(to: url, options: .atomic)
            }
        }
        exportTask = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { if error is CancellationError { diagnosticFailure = .cancelled }; throw error }
        diagnosticCompleted = true
        statusMessage = "Rapport exporté : \(url.lastPathComponent)"
    }

    func cancelExport() { statusMessage = "Annulation du rapport…"; exportTask?.cancel() }

    func enablePagedNavigation() {
        usesPagedNavigation = true
        reloadTask?.cancel(); loadToken = UUID(); isLoading = false
        snapshot = .empty
        loadHistory()
    }

    func loadCatalogue() async {
        guard let engine = engineURL, FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        catalogueError = nil
        do {
            var request = LibraryQueryRequest(kind: "catalogue", scope: views.state.activeScope, annotations: annotations.state)
            var result = try await LibraryQueryService.page(LibraryCataloguePage.self, request: request, database: databaseURL, engine: engine, readOnly: true)
            while let cursor = result.nextCursor {
                try Task.checkCancellation()
                guard result.families.count + result.levels.count < 8192 else {
                    throw AnalysisError.engine("Le catalogue dépasse 8 192 valeurs. Affinez les classifications avant de modifier le filtre.")
                }
                request.cursor = cursor
                let next = try await LibraryQueryService.page(LibraryCataloguePage.self, request: request, database: databaseURL, engine: engine, readOnly: true)
                guard next.revision == result.revision, next.scopeHash == result.scopeHash else {
                    throw AnalysisError.engine("Le catalogue a changé pendant sa lecture. Rechargez le filtre.")
                }
                result.families += next.families; result.levels += next.levels; result.nextCursor = next.nextCursor
                guard result.families.count + result.levels.count <= 8192 else {
                    throw AnalysisError.engine("Le catalogue dépasse la limite de 8 192 valeurs.")
                }
            }
            try Task.checkCancellation()
            catalogue = result
        } catch is CancellationError {} catch { catalogueError = error.localizedDescription }
    }

    func importEventDictionary(_ file: URL) async throws -> EventDictionaryImport {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        let result = try await performMaintenance {
            try await EventDictionaryService.importFile(file, database: databaseURL, engine: engine)
        }
        statusMessage = "Dictionnaire vérifié · \(result.matchingCachedLogs) fiches compatibles. La traduction est recalculée à l’ouverture si la source est disponible."
        if let selectedFlight { loadFlight(selectedFlight) }
        return result
    }

    func validIndexedLogIDs(_ ids: [String]) async throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: databaseURL.path), let engine = engineURL else { return [] }
        struct Request: Encodable { var logIDs: [String]; var parserVersion: String }
        struct Status: Decodable { var id: String; var status: String; var parserVersion: String? }
        struct Response: Decodable { var indexVersion: Int; var logs: [Status] }
        let requested = Array(Set(ids)).sorted()
        var valid: Set<String> = []
        for offset in stride(from: 0, to: requested.count, by: 1000) {
            try Task.checkCancellation()
            let batch = Array(requested[offset..<min(offset + 1000, requested.count)])
            let data = try await AnalysisService.run(["indexed-status", "--database", databaseURL.path], engine: engine,
                                                      request: JSONEncoder().encode(Request(logIDs: batch, parserVersion: AnalysisService.parserVersion)))
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard result.indexVersion == 1 else { throw AnalysisError.engine("État d’index incompatible.") }
            valid.formUnion(result.logs.filter { $0.status != "error" && $0.parserVersion == AnalysisService.parserVersion }.map(\.id))
        }
        return valid
    }

    func exportReport(to destination: URL, mode: ReportScopeManifest.Mode, options: ReportExportOptions) async throws -> ReportExportResult {
        var scope = mode == .full ? SelectionScope() : views.state.activeScope
        if mode == .full { scope.includeMasked = true; scope.clientID = views.state.activeScope.clientID }
        let query = LibraryQueryRequest(scope: scope, annotations: annotations.state, maskedMessageKeys: views.state.maskedMessageKeys)
        let request = ReportExportRequest(query: query, mode: mode,
            scopeDescription: clients.scopeLabel(for: scope.clientID) + " · " + (mode == .full ? "Tous les logs · messages masqués inclus" : scope.description),
            viewRevision: views.state.revision, options: options)
        return try await exportReport(to: destination, reviewedRequest: request)
    }

    /// Review fixes the scope, annotations and options. If the source revision
    /// changed meanwhile, no report is published and the user refreshes review.
    func exportReport(to destination: URL, reviewedRequest request: ReportExportRequest,
                      expectedRevision: Int? = nil) async throws -> ReportExportResult {
        guard !isExporting else { throw AnalysisError.engine("Un export est déjà en cours.") }
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard request.viewRevision == views.state.revision,
              try encoder.encode(request.query.annotations) == encoder.encode(annotations.state),
              request.query.maskedMessageKeys == views.state.maskedMessageKeys else {
            throw AnalysisError.engine("Les réglages ont changé depuis la prévisualisation. Actualisez-la avant de générer le rapport.")
        }
        isExporting = true; lastReportExport = nil; errorMessage = nil
        let diagnosticOperation = UUID().uuidString
        diagnostics.record(.exportStarted, correlation: diagnosticOperation)
        var diagnosticCompleted = false
        var diagnosticFailure: DiagnosticEvent.Code = .exportFailed
        defer { diagnostics.record(diagnosticCompleted ? .exportCompleted : .exportFailed, code: diagnosticCompleted ? .none : diagnosticFailure, correlation: diagnosticOperation) }
        reportProgress = nil
        var reportProgressTask: Task<Void, Never>?
        defer { isExporting = false; exportTask = nil; reportProgressTask?.cancel() }
        let captureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let reportProgressURL = captureDirectory.appendingPathComponent("progress.json")
        let task = Task<Void, Error> { [self] in
            self.statusMessage = "Capture d’une révision cohérente…"
            let capture = try await self.performMaintenance(allowOwnedExport: true) {
                try await ReportExportService.capture(database: self.databaseURL, directory: captureDirectory, request: request, engine: engine)
            }
            try Task.checkCancellation()
            if let expectedRevision, capture.manifest.revision != expectedRevision {
                throw AnalysisError.engine("La bibliothèque a changé depuis la prévisualisation. Actualisez-la avant de générer le rapport.")
            }
            self.statusMessage = "Génération du rapport · \(capture.manifest.totalLogs) logs · \(capture.manifest.totalMessages) messages…"
            reportProgressTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let data = try? Data(contentsOf: reportProgressURL), let value = try? JSONDecoder().decode(ImportProgress.self, from: data) { self?.reportProgress = value }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
            let result = try await ReportExportService.export(capture: capture, destination: destination, engine: engine, progress: reportProgressURL)
            if let data = try? Data(contentsOf: reportProgressURL) { self.reportProgress = try? JSONDecoder().decode(ImportProgress.self, from: data) }
            self.lastReportExport = result
        }
        exportTask = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { if error is CancellationError { diagnosticFailure = .cancelled }; throw error }
        guard let result = lastReportExport else { throw AnalysisError.engine("Le rapport n’a pas été publié.") }
        diagnosticCompleted = true
        statusMessage = "Rapport publié · \(result.logCount) logs · \(result.messageCount) messages · révision \(result.revision)."
        return result
    }

    /// Each cached response belongs to its full request and an unchanged local
    /// database/WAL. Switching tabs restores results synchronously when possible.
    private func applyNavigationPage(_ page: LibraryNavigationCache.Page, request: LibraryQueryRequest) {
        let key = LibraryNavigationCache.key(request)
        switch page {
        case let .history(logs, groups):
            historyPage = logs; groupPage = groups; currentHistoryCursor = request.cursor
            occurrencePage = nil; occurrenceResultsCurrent = false
            if usesPagedNavigation { snapshot = logs.snapshot }
            historyResultsCurrent = true; groupResultsCurrent = true
            displayedQueryKeys["logs"] = key
            var groupRequest = request; groupRequest.kind = "groups"; groupRequest.cursor = nil
            displayedQueryKeys["groups"] = LibraryNavigationCache.key(groupRequest)
        case let .map(value): mapPage = value
        case let .drones(value): dronePage = value; droneResultsCurrent = true
        case let .groups(value): groupPage = value; groupResultsCurrent = true
        case let .messages(value): occurrencePage = value; occurrenceResultsCurrent = true
        }
        displayedQueryKeys[request.kind] = key
        queryError = nil; queryWasCancelled = false
    }

    private typealias NavigationResult = (page: LibraryNavigationCache.Page, stamp: LibraryNavigationCache.Stamp)

    private func readNavigationPage(request: LibraryQueryRequest, usingCache: Bool,
                                    operation: @escaping @MainActor () async throws -> NavigationResult) {
        // Clients remain usable even when a heavier navigation query fails.
        // Warm navigation retries failed reads without restarting successful ones.
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            clients.reloadIfNeeded(refresh: !usingCache && request.kind == "logs")
        }
        let key = LibraryNavigationCache.key(request)
        if isQuerying, activeQueryKey == key { return }
        if queryTask == nil, usingCache, let page = navigationCache.value(for: key, includeFleet: request.kind == "drones") {
            applyNavigationPage(page, request: request)
            return
        }
        let current = displayedQueryKeys[request.kind] == key
        switch request.kind {
        case "logs":
            historyResultsCurrent = current
            var groupRequest = request; groupRequest.kind = "groups"; groupRequest.cursor = nil
            groupResultsCurrent = displayedQueryKeys["groups"] == LibraryNavigationCache.key(groupRequest)
        case "groups": groupResultsCurrent = current
        case "drones": droneResultsCurrent = current
        case "messages": occurrenceResultsCurrent = current
        case "map-overview": if !current { mapPage = nil }
        default: break
        }
        let previous = queryTask
        previous?.cancel()
        let token = UUID(); queryToken = token; activeQueryKey = key
        isQuerying = true; queryWasCancelled = false; queryError = nil
        queryTask = Task { [weak self] in
            // A cached destination cannot release the activity lock while a
            // superseded helper is still shutting down.
            await previous?.value
            guard let self, !Task.isCancelled, queryToken == token else { return }
            defer {
                if queryToken == token { isQuerying = false; queryTask = nil; activeQueryKey = nil }
            }
            do {
                if !isReadOnly && !indexPrepared, let engine = engineURL {
                    _ = try await performMaintenance(allowOwnedQuery: true) {
                        try await AnalysisService.run(["ensure-index", "--database", databaseURL.path], engine: engine)
                    }
                    indexPrepared = true
                    clients.reloadIfNeeded(refresh: true)
                }
                try Task.checkCancellation()
                if usingCache, let cached = navigationCache.value(for: key, includeFleet: request.kind == "drones") {
                    applyNavigationPage(cached, request: request)
                    return
                }
                let result = try await operation()
                guard !Task.isCancelled, queryToken == token else { return }
                navigationCache.insert(result.page, for: key, readStamp: result.stamp)
                applyNavigationPage(result.page, request: request)
            } catch {
                guard !Task.isCancelled, queryToken == token else { return }
                queryError = error.localizedDescription
            }
        }
    }

    private func navigationRequest(kind: String, cursor: String? = nil) -> LibraryQueryRequest {
        var request = LibraryQueryRequest(kind: kind, scope: views.state.activeScope, annotations: annotations.state,
                                          maskedMessageKeys: views.state.maskedMessageKeys)
        request.cursor = cursor
        request.sortOrder = views.state.historySort ?? "recent"
        return request
    }

    func loadHistory(cursor: String? = nil, usingCache: Bool = false) {
        guard !isImporting, !isMaintainingLibrary, !isCancellingQuery, let engine = engineURL else { return }
        guard FileManager.default.fileExists(atPath: databaseURL.path) || (!isReadOnly && usesPagedNavigation) else { return }
        var request = navigationRequest(kind: "logs", cursor: cursor)
        request.sortOrder = historySortOverride ?? views.state.historySort ?? "recent"
        let database = databaseURL
        readNavigationPage(request: request, usingCache: usingCache) { [self] in
            let stamp = navigationCache.stamp()
            let page = try await LibraryQueryService.page(LibraryLogPage.self, request: request, database: database, engine: engine, readOnly: true)
            var groupsRequest = request; groupsRequest.kind = "groups"; groupsRequest.cursor = nil
            let groups = try await LibraryQueryService.page(LibraryGroupPage.self, request: groupsRequest, database: database, engine: engine, readOnly: true)
            guard page.revision == groups.revision else { throw AnalysisError.engine("La bibliothèque a changé pendant la lecture. Rechargez la sélection.") }
            return (.history(page, groups), stamp)
        }
    }

    func loadOccurrences(groupID: String, cursor: String? = nil, usingCache: Bool = false) {
        guard !isImporting, !isMaintainingLibrary, !isCancellingQuery, let engine = engineURL else { return }
        var request = navigationRequest(kind: "messages", cursor: cursor)
        request.groupID = groupID
        let database = databaseURL
        readNavigationPage(request: request, usingCache: usingCache) { [self] in
            let stamp = navigationCache.stamp()
            let result = try await LibraryQueryService.page(LibraryMessagePage.self, request: request, database: database, engine: engine, readOnly: true)
            return (.messages(result), stamp)
        }
    }

    func loadAuxiliary(kind: String, cursor: String? = nil, search: String? = nil, usingCache: Bool = false) {
        guard !isImporting, !isMaintainingLibrary, !isCancellingQuery, ["drones", "map", "groups"].contains(kind),
              let engine = engineURL, FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        var request = navigationRequest(kind: kind == "map" ? "map-overview" : kind, cursor: cursor)
        request.registrySearch = search
        if kind == "map" { request.proximity = mapProximity; request.sortOrder = "recent"; request.limit = 5000 }
        let database = databaseURL
        readNavigationPage(request: request, usingCache: usingCache) { [self] in
            let stamp = navigationCache.stamp(includeFleet: kind == "drones")
            if kind == "drones" {
                let result = try await LibraryQueryService.page(LibraryDronePage.self, request: request, database: database, engine: engine, readOnly: true)
                return (.drones(result), stamp)
            } else if kind == "map" {
                var current = request
                var result: LibraryMapPage
                var mapStamp = stamp
                if request.proximity != nil, !isReadOnly, activeDetailLoads == 0, !hasExternalActivity() {
                    result = try await performMaintenance(allowOwnedQuery: true) {
                        try await LibraryQueryService.page(LibraryMapPage.self, request: current, database: database, engine: engine, readOnly: false)
                    }
                    mapStamp = navigationCache.stamp()
                } else {
                    result = try await LibraryQueryService.page(LibraryMapPage.self, request: current, database: database, engine: engine, readOnly: true)
                }
                // The optional preparation above may have retained exact GPS
                // caches. Pagination itself remains a read-only operation.
                var seen = Set<String>()
                while let cursor = result.nextCursor {
                    try Task.checkCancellation()
                    guard seen.insert(cursor).inserted else { throw AnalysisError.engine("La pagination de la carte n’a pas progressé. Rechargez la sélection.") }
                    current.cursor = cursor
                    let next = try await LibraryQueryService.page(LibraryMapPage.self, request: current, database: database, engine: engine, readOnly: true)
                    guard next.revision == result.revision, next.scopeHash == result.scopeHash else {
                        throw AnalysisError.engine("La bibliothèque a changé pendant la lecture de la carte. Rechargez la sélection.")
                    }
                    result.markers += next.markers; result.nextCursor = next.nextCursor
                }
                return (.map(result), mapStamp)
            } else {
                let result = try await LibraryQueryService.page(LibraryGroupPage.self, request: request, database: database, engine: engine, readOnly: true)
                return (.groups(result), stamp)
            }
        }
    }

    func openMapFlight(logID: String) {
        guard !isLoadingFlight, !isMaintainingLibrary, let engine = engineURL else { return }
        var request = navigationRequest(kind: "logs")
        request.scope.logIDs = [logID]; request.limit = 1
        let database = databaseURL, token = UUID(); flightToken = token
        isLoadingFlight = true; flightError = nil
        flightTask = Task { [weak self] in
            do {
                let result = try await LibraryQueryService.page(LibraryLogPage.self, request: request, database: database, engine: engine, readOnly: true)
                guard !Task.isCancelled, let self, flightToken == token else { return }
                guard let log = result.snapshot.logs.first else { throw AnalysisError.engine("Ce log ne fait plus partie de la sélection.") }
                isLoadingFlight = false; flightTask = nil
                openFlightWindow(log)
            } catch {
                guard !Task.isCancelled, let self, flightToken == token else { return }
                flightError = error.localizedDescription; errorMessage = error.localizedDescription
                isLoadingFlight = false; flightTask = nil
            }
        }
    }

    /// Library-wide changes run under the stable writer lease with imports,
    /// collection persistence and annotation edits quiescent.
    func performMaintenance<T: Sendable>(allowOwnedExport: Bool = false, allowOwnedQuery: Bool = false, _ operation: () async throws -> T) async throws -> T {
        guard !isReadOnly, !isMaintainingLibrary, !isImporting, (!isExporting || allowOwnedExport),
              !isLoading, (!isQuerying || allowOwnedQuery), !isLoadingFlight, activeDetailLoads == 0, !hasExternalActivity() else {
            throw AnalysisError.engine("Terminez ou arrêtez les opérations en cours avant de modifier ou sauvegarder la bibliothèque.")
        }
        try willMaintainLibrary()
        isMaintainingLibrary = true
        defer { isMaintainingLibrary = false; invalidateNavigationCache() }
        await clients.cancelReadAndWait()
        try Task.checkCancellation()
        return try await operation()
    }

    func backup(to destination: URL, includeULog: Bool) async throws -> LibraryBackupResult {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        return try await performMaintenance {
            statusMessage = "Sauvegarde et vérification…"
            let result = try await LibraryStorageService.backup(library: storageDirectory, destination: destination, includeULog: includeULog, engine: engine)
            statusMessage = "Sauvegarde vérifiée · \(result.logCount) logs · \(result.archivedLogCount) fichiers ULog · \(result.missingSourceCount) sources absentes."
            return result
        }
    }

    func restore(from archive: URL) async throws -> JSONValue {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        var postRestoreIssue: String?
        let result = try await performMaintenance {
            statusMessage = "Restauration vérifiée…"
            FlightWindowCoordinator.shared.closeAll(library: self)
            try willRestoreLibrary()
            do {
                let result = try await LibraryStorageService.restore(archive: archive, library: storageDirectory, engine: engine)
                annotations.reload(); views.reload()
                indexPrepared = false
                closeFlight()
                do { try didRestoreLibrary() }
                catch { postRestoreIssue = error.localizedDescription }
                return result
            } catch {
                try? didRestoreLibrary()
                throw error
            }
        }
        clients.reload(); reload()
        statusMessage = "Bibliothèque restaurée. L’ancien état est conservé dans le dossier de récupération. Les collectes actives sont interrompues."
        if let postRestoreIssue { errorMessage = "La bibliothèque a été restaurée, mais la collecte ne peut pas être rouverte : \(postRestoreIssue). Elle reste bloquée ; relancez l’app ou restaurez sa configuration." }
        return result
    }

    func openFlightWindow(_ log: FlightLog) {
        guard !isStartupBlocked else { return }
        FlightWindowCoordinator.shared.open(log: log, library: self)
    }

    func loadMap(proximity: GeographicProximity? = nil) {
        guard !isImporting, !isMaintainingLibrary, !isCancellingQuery else { return }
        mapProximity = proximity
        loadAuxiliary(kind: "map")
    }

    func clearLibrary() async throws { try await resetLibrary(allSettings: false) }
    func resetApplication() async throws { try await resetLibrary(allSettings: true) }

    private func resetLibrary(allSettings: Bool) async throws {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        guard !diagnosticStore.isExporting, !diagnosticStore.isFetchingGCS, !diagnosticStore.isLoading else {
            throw AnalysisError.engine("Terminez ou arrêtez le diagnostic avant de réinitialiser la bibliothèque.")
        }
        try await performMaintenance {
            FlightWindowCoordinator.shared.closeAll(library: self)
            closeFlight()
            let data = try await AnalysisService.run(["reset-library", "--database", databaseURL.path,
                "--library", storageDirectory.path] + (allSettings ? ["--all-settings"] : []), engine: engine)
            struct Result: Decodable { var originalsDeleted: Bool }
            guard try JSONDecoder().decode(Result.self, from: data).originalsDeleted == false else {
                throw AnalysisError.engine("Le moteur n’a pas confirmé la conservation des fichiers originaux.")
            }
            if allSettings {
                try resetCollectionState()
                try Self.removeConfigurationFiles(in: storageDirectory,
                    names: ["views.json", "annotations.json", "import-options.json"])
                annotations.reload(); views.reload()
                diagnosticStore.dismiss()
                try diagnostics.clear()
            }
            // Clearing indices must never revive a legacy JSON snapshot.
            try Self.removeConfigurationFiles(in: storageDirectory, names: ["library.json", "progress.json"])
            displayedQueryKeys.removeAll()
            historyResultsCurrent = false; groupResultsCurrent = false; droneResultsCurrent = false; occurrenceResultsCurrent = false
            snapshot = .empty; historyPage = nil; groupPage = nil; dronePage = nil; mapPage = nil
            occurrencePage = nil; catalogue = nil; progress = nil; mapProximity = nil
            currentHistoryCursor = nil; lastReportExport = nil; indexPrepared = false
        }
        if !allSettings {
            // Keep preferences and selected client, but drop filters tied to deleted logs.
            var scope = SelectionScope(); scope.clientID = views.state.activeScope.clientID
            try views.chooseScope(scope)
        }
        clients.reload(); reload()
        statusMessage = allSettings ? "KataLog réinitialisé. Vos fichiers .ulg sont conservés." : "Bibliothèque vidée. Clients, identifications, réglages et fichiers .ulg conservés."
    }

    /// Only known regular configuration files can be removed. Never recurse into a directory.
    static func removeConfigurationFiles(in directory: URL, names: [String]) throws {
        for name in names {
            guard !name.contains("/"), !name.lowercased().hasSuffix(".ulg") else {
                throw AnalysisError.engine("Nom de configuration inattendu.")
            }
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else {
                throw AnalysisError.engine("Un dossier occupe l’emplacement d’un réglage. Il a été conservé.")
            }
            try FileManager.default.removeItem(at: file)
        }
    }

    var engineURL: URL? {
        isStartupBlocked ? nil : availableEngineURL
    }

    private var availableEngineURL: URL? {
        if let engineOverride { return engineOverride }
        if let url = Bundle.main.url(forResource: "analyzer", withExtension: "py") { return url }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "analyzer", withExtension: "py", subdirectory: "Resources") { return url }
        #endif
        return nil
    }
}
