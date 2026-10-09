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
    @Published var isExporting = false
    @Published private(set) var isReadOnly = false
    @Published var isMaintainingLibrary = false
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
        return commandCapabilities.canWriteDiagnosticSettings
    })
    private var diagnosticStopRecorded = false
    var exportTask: Task<Void, Error>?
    @Published var lastReportExport: ReportExportResult?
    @Published var reportProgress: ImportProgress?
    @Published private(set) var selectedFlight: FlightLog?
    @Published var activeDetailLoads = 0
    @Published private var legacyIsLoadingFlight = false
    @Published private(set) var flightError: String?
    private var flightTask: Task<Void, Never>?
    private var flightToken = UUID()
    var analysisRefreshTask: Task<Void, Never>?
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
    var resetGeneration = 0
    var clientDidDelete: (String) async throws -> Void = { _ in }
    var clientProfilesDidLoad: (Set<String>) async throws -> Void = { _ in }
    private var annotationSubscription: AnyCancellable?
    private let engineOverride: URL?
    let snapshotURL: URL
    let progressURL: URL
    var importTask: Task<FleetSnapshot, Error>?
    var progressTask: Task<Void, Never>?
    var loadToken = UUID()
    private var reloadTask: Task<Void, Never>?
    private(set) var usesPagedNavigation = false
    private var viewSubscription: AnyCancellable?
    var indexPrepared = false
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
    func reloadNavigationSessions() {
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
    var hasActiveWork: Bool { hasExternalActivity() || commandCapabilities.hasActiveWork || diagnosticStore.isLoading || diagnosticStore.isFetchingGCS || diagnosticStore.isExporting }

    func revealSource(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { errorMessage = "Le fichier source n’est plus présent : \(path)"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

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

    func openFlightWindow(_ log: FlightLog) {
        guard !isStartupBlocked else { return }
        FlightWindowCoordinator.shared.open(log: log, library: self)
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
