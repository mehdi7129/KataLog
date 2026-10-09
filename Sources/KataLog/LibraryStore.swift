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
    var hasExternalActivity: () -> Bool = { false }
    var willMaintainLibrary: () async throws -> Void = {}
    var willRestoreLibrary: () async throws -> Void = {}
    var didRestoreLibrary: () async throws -> Void = {}
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
    @Published private var legacyIsLoadingFlight = false
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
    var resetCollectionState: () async throws -> Void = {}
    var validateCollectionReset: () async throws -> Void = {}
    private(set) var resetGeneration = 0
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
    private var viewSubscription: AnyCancellable?
    private var indexPrepared = false
    private var navigationPreparation: Task<Void, Error>?
    private struct WeakNavigation { weak var value: LibraryNavigationStore? }
    private var navigationReferences: [WeakNavigation] = []
    private lazy var defaultNavigation = LibraryNavigationStore(library: self, isDefault: true)
    private var navigationSessions: [LibraryNavigationStore] { navigationReferences.compactMap(\.value) }

    func makeNavigationSession() -> LibraryNavigationStore { LibraryNavigationStore(library: self) }
    func registerNavigation(_ session: LibraryNavigationStore) {
        navigationReferences.removeAll { $0.value == nil }
        navigationReferences.append(WeakNavigation(value: session))
    }
    func hasOtherNavigationWork(than owner: LibraryNavigationStore?) -> Bool {
        navigationSessions.contains { $0 !== owner && $0.hasActiveWork }
    }
    func invalidateNavigationCache() { navigationSessions.forEach { $0.invalidateCache() } }
    func resetNavigationSessions() { navigationSessions.forEach { $0.reset() } }
    private func reloadNavigationSessions() {
        defaultNavigation.loadHistory()
        navigationSessions.filter { $0 !== defaultNavigation }.forEach { $0.reload() }
    }
    var isPreparingNavigation: Bool { navigationPreparation != nil }
    func cancelNavigationPreparation(ifLastReader owner: LibraryNavigationStore) {
        guard !navigationSessions.contains(where: { $0 !== owner && $0.isQuerying && !$0.isCancellingQuery }) else { return }
        navigationPreparation?.cancel()
    }


    /// Every reader awaits the same index writer before issuing its own read.
    func prepareNavigationIndex() async throws {
        if let navigationPreparation { try await navigationPreparation.value; return }
        guard !isReadOnly, !indexPrepared, let engine = engineURL else { return }
        let task = Task { [self] in
            _ = try await performMaintenance(allowOwnedQuery: true) {
                try await AnalysisService.run(["ensure-index", "--database", databaseURL.path], engine: engine)
            }
            indexPrepared = true; clients.reloadIfNeeded(refresh: true)
        }
        navigationPreparation = task
        defer { navigationPreparation = nil }
        try await task.value
    }


    var historyPage: LibraryLogPage? { defaultNavigation.historyPage }
    var currentHistoryCursor: String? { defaultNavigation.currentHistoryCursor }
    var groupPage: LibraryGroupPage? { defaultNavigation.groupPage }
    var dronePage: LibraryDronePage? { defaultNavigation.dronePage }
    var mapPage: LibraryMapPage? { defaultNavigation.mapPage }
    var occurrencePage: LibraryMessagePage? { defaultNavigation.occurrencePage }
    var isCancellingQuery: Bool { defaultNavigation.isCancellingQuery }
    var queryWasCancelled: Bool { defaultNavigation.queryWasCancelled }
    var queryError: String? { defaultNavigation.queryError }
    var queryToken: UUID { defaultNavigation.queryToken }
    var catalogue: LibraryCataloguePage? { defaultNavigation.catalogue }
    var catalogueError: String? { defaultNavigation.catalogueError }
    var mapProximity: GeographicProximity? { defaultNavigation.mapProximity }
    var historyResultsCurrent: Bool { defaultNavigation.historyResultsCurrent }
    var groupResultsCurrent: Bool { defaultNavigation.groupResultsCurrent }
    var droneResultsCurrent: Bool { defaultNavigation.droneResultsCurrent }
    var occurrenceResultsCurrent: Bool { defaultNavigation.occurrenceResultsCurrent }
    var isQuerying: Bool { navigationSessions.contains { $0.hasActiveQuery } }
    var isLoadingFlight: Bool { legacyIsLoadingFlight || navigationSessions.contains { $0.isLoadingFlight } }
    var historySortOverride: String? {
        get { defaultNavigation.historySortOverride }
        set { defaultNavigation.historySortOverride = newValue }
    }
    func loadHistory(cursor: String? = nil, usingCache: Bool = false) { defaultNavigation.loadHistory(cursor: cursor, usingCache: usingCache) }
    func loadOccurrences(groupID: String, cursor: String? = nil, usingCache: Bool = false) { defaultNavigation.loadOccurrences(groupID: groupID, cursor: cursor, usingCache: usingCache) }
    func loadAuxiliary(kind: String, cursor: String? = nil, search: String? = nil, usingCache: Bool = false) { defaultNavigation.loadAuxiliary(kind: kind, cursor: cursor, search: search, usingCache: usingCache) }
    func loadMap(proximity: GeographicProximity? = nil) { defaultNavigation.loadMap(proximity: proximity) }
    func loadCatalogue() async { await defaultNavigation.loadCatalogue() }
    func cancelQuery() async { await defaultNavigation.cancelQuery() }
    func openMapFlight(logID: String) { defaultNavigation.openMapFlight(logID: logID) }
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
                Task { @MainActor [weak self] in self?.reloadNavigationSessions() }
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
                self.reloadNavigationSessions()
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
                try await didRestoreLibrary()
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
        if usesPagedNavigation { reloadNavigationSessions(); return }
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
                if self.usesPagedNavigation { Task { self.reloadNavigationSessions() } }
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
        selectedFlight = annotations.state.applying(to: log, relatedLogs: snapshot.logs); legacyIsLoadingFlight = true; flightError = nil
        guard let engine = engineURL else { legacyIsLoadingFlight = false; flightError = "Moteur d’analyse absent."; return }
        let database = databaseURL
        flightTask = Task { [weak self] in
            do {
                let detailed = try await AnalysisService.detail(logID: log.id, database: database, engine: engine,
                                                                readOnly: self?.isReadOnly == true || self?.isImporting == true || self?.isMaintainingLibrary == true)
                guard !Task.isCancelled, let self, self.flightToken == token else { return }
                self.selectedFlight = self.annotations.state.applying(to: detailed, relatedLogs: self.snapshot.logs); self.legacyIsLoadingFlight = false; self.flightTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.flightToken == token else { return }
                self.flightError = error.localizedDescription; self.legacyIsLoadingFlight = false; self.flightTask = nil
            }
        }
    }

    func closeFlight() {
        flightToken = UUID(); flightTask?.cancel(); flightTask = nil
        selectedFlight = nil; legacyIsLoadingFlight = false; flightError = nil
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
    func prepareForTermination() {
        FlightWindowCoordinator.shared.closeAll(library: self)
        diagnosticStore.prepareForTermination()
        if !diagnosticStopRecorded { diagnostics.record(.appStopped); diagnostics.flush(); diagnosticStopRecorded = true }
        cancelImport(); exportTask?.cancel(); flightTask?.cancel(); reloadTask?.cancel()
        navigationSessions.forEach { $0.prepareForTermination() }; navigationPreparation?.cancel()
        startupRecoveryTask?.cancel()
        clients.cancelRead()
        progressTask?.cancel(); flightToken = UUID(); loadToken = UUID()
        isLoading = false; legacyIsLoadingFlight = false
    }
    var hasActiveWork: Bool { hasExternalActivity() || activeDetailLoads > 0 || isImporting || isExporting || isMaintainingLibrary || navigationSessions.contains { $0.hasActiveWork } || isLoading || isLoadingFlight || diagnosticStore.isLoading || diagnosticStore.isFetchingGCS || diagnosticStore.isExporting }

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

    /// Library-wide changes run under the stable writer lease with imports,
    /// collection persistence and annotation edits quiescent.
    func performMaintenance<T: Sendable>(allowOwnedExport: Bool = false, allowOwnedQuery: Bool = false, navigationOwner: LibraryNavigationStore? = nil, _ operation: () async throws -> T) async throws -> T {
        guard !isReadOnly, !isMaintainingLibrary, !isImporting, (!isExporting || allowOwnedExport),
              !isLoading, (!hasOtherNavigationWork(than: navigationOwner) || allowOwnedQuery), !isLoadingFlight, activeDetailLoads == 0, !hasExternalActivity() else {
            throw AnalysisError.engine("Terminez ou arrêtez les opérations en cours avant de modifier ou sauvegarder la bibliothèque.")
        }
        isMaintainingLibrary = true
        defer { isMaintainingLibrary = false; invalidateNavigationCache() }
        try await willMaintainLibrary()
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
            try await willRestoreLibrary()
            do {
                let result = try await LibraryStorageService.restore(archive: archive, library: storageDirectory, engine: engine)
                annotations.reload(); views.reload()
                indexPrepared = false
                closeFlight()
                do { try await didRestoreLibrary() }
                catch { postRestoreIssue = error.localizedDescription }
                return result
            } catch {
                try? await didRestoreLibrary()
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

    func clearLibrary() async throws { try await resetLibrary(allSettings: false) }
    func resetApplication() async throws { try await resetLibrary(allSettings: true) }

    private func resetLibrary(allSettings: Bool) async throws {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        guard !diagnosticStore.isExporting, !diagnosticStore.isFetchingGCS, !diagnosticStore.isLoading else {
            throw AnalysisError.engine("Terminez ou arrêtez le diagnostic avant de réinitialiser la bibliothèque.")
        }
        let settings = ["views.json", "annotations.json", "import-options.json"]
        let indices = ["library.json", "progress.json"]
        var cleanupIssues: [String] = []
        try await performMaintenance {
            try Self.validateConfigurationFiles(in: storageDirectory, names: indices + (allSettings ? settings : []))
            if allSettings { try await validateCollectionReset() }
            FlightWindowCoordinator.shared.closeAll(library: self)
            closeFlight()
            let data = try await AnalysisService.run(["reset-library", "--database", databaseURL.path,
                "--library", storageDirectory.path] + (allSettings ? ["--all-settings"] : []), engine: engine)
            struct Result: Decodable { var originalsDeleted: Bool }
            guard try JSONDecoder().decode(Result.self, from: data).originalsDeleted == false else {
                throw AnalysisError.engine("Le moteur n’a pas confirmé la conservation des fichiers originaux.")
            }
            resetGeneration += 1
            if allSettings {
                clients.clearAfterApplicationReset()
                do { try await resetCollectionState() }
                catch { cleanupIssues.append("Collecte : \(error.localizedDescription)") }
                do { try Self.removeConfigurationFiles(in: storageDirectory, names: settings) }
                catch { cleanupIssues.append("Réglages : \(error.localizedDescription)") }
                annotations.reload(); views.reload()
                diagnosticStore.dismiss()
                do { try diagnostics.clear() }
                catch { cleanupIssues.append("Diagnostic : \(error.localizedDescription)") }
            }
            // Clearing indices must never revive a legacy JSON snapshot.
            do { try Self.removeConfigurationFiles(in: storageDirectory, names: indices) }
            catch { cleanupIssues.append("Anciens index : \(error.localizedDescription)") }
            resetNavigationSessions()
            snapshot = .empty; progress = nil
            lastReportExport = nil; indexPrepared = false
        }
        if !allSettings {
            // Keep preferences and selected client, but drop filters tied to deleted logs.
            do { try views.clearLogFiltersAfterReset() }
            catch { cleanupIssues.append("Filtre affiché : \(error.localizedDescription)") }
        }
        clients.reload(); reload()
        statusMessage = allSettings ? "KataLog réinitialisé. Vos fichiers .ulg sont conservés." : "Bibliothèque vidée. Clients, identifications, réglages et fichiers .ulg conservés."
        if !cleanupIssues.isEmpty {
            let message = (statusMessage ?? "") + " Nettoyage incomplet : " + cleanupIssues.joined(separator: " ")
            errorMessage = message
            throw AnalysisError.engine(message)
        }
        errorMessage = nil
    }

    /// Only known regular configuration files can be removed. Never recurse into a directory.
    nonisolated static func removeConfigurationFiles(in directory: URL, names: [String]) throws {
        for name in names {
            try validateConfigurationFiles(in: directory, names: [name])
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    /// Refuse known obstacles before a database mutation; cleanup validates again.
    nonisolated static func validateConfigurationFiles(in directory: URL, names: [String]) throws {
        for name in names {
            guard !name.contains("/"), !name.lowercased().hasSuffix(".ulg") else {
                throw AnalysisError.engine("Nom de configuration inattendu.")
            }
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else {
                throw AnalysisError.engine("Un dossier occupe l’emplacement du réglage \(name). Il a été conservé.")
            }
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
