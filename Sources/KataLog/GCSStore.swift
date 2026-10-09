import AppKit
import Combine
import Foundation
import KataLogCore

private struct GCSTransferSource: Hashable, Sendable {
    let uuid: String
    let path: String
    let size: Int64
    let destination: String
    init(_ item: GCSTransfer) { uuid = item.droneUUID; path = item.remotePath; size = item.size; destination = item.destination }
    init(uuid: String, file: GCSLogFile, destination: String) { self.uuid = uuid; path = file.path; size = file.size; self.destination = destination }
    var cacheIdentity: String { "\(uuid):\(path.utf8.count):\(path):\(size):\(destination)" }
}

@MainActor
final class GCSStore: ObservableObject {
    @Published private(set) var collectionClientID: String?
    var collectionClientName: String { library?.clients.scopeLabel(for: collectionClientID ?? "") ?? "Sans client" }
    @Published var host: String { didSet { if terminationRequested { host = oldValue } } }
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isBusy = false
    @Published var isQueuePaused = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var drones: [GCSDrone] = []
    @Published private(set) var allowedUUIDs: Set<String> { didSet { refreshQueueCounts() } }
    @Published private(set) var selectedUUID: String?
    @Published private(set) var files: [GCSLogFile] = []
    @Published var selectedFileIDs: Set<String> = []
    @Published private(set) var queue: [GCSTransfer] { didSet { queueRevision &+= 1 } }
    @Published private(set) var downloadDirectory: URL
    @Published var autoImport: Bool {
        didSet {
            guard !isApplyingRestoredState else { return }
            if isReadOnly || isMaintenanceBlocked || terminationRequested {
                isApplyingRestoredState = true; autoImport = oldValue; isApplyingRestoredState = false
                _ = permitMutation(); return
            }
            persist()
        }
    }
    private var isApplyingRestoredState = false
    private var configurationDirty = false
    private var knownAnalysisHashes: Set<String> = []
    private let stateURL: URL
    private let legacyStateURL: URL
    private let queueDatabaseURL: URL
    private var queueRepository: GCSQueueRepository?
    private var repositoryWritable = false
    private lazy var storageIO = GCSStorageIO(database: queueDatabaseURL, settings: stateURL)
    private var attachmentTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var persistAgain = false
    private var persistenceError: Error?
    private var configurationRevision: UInt64 = 0
    private var countsTask: Task<Void, Never>?
    private var countsAgain = false
    private var storageGeneration: UInt64 = 0
    @Published private var isStorageTransitioning = false
    private var terminationRequested = false
    private var controlRevision: UInt64 = 0
    private var deferredFleetObservations: [String: GCSDrone] = [:]
    var hasPendingPersistence: Bool { persistenceTask != nil }
    private var hasCompleteInMemoryQueue = true
    private var queueRevision: UInt64 = 0
    private struct CountsSelection: Equatable, Sendable {
        let batchID: String
        let authorizedUUIDs: Set<String>
    }
    private struct CountsSnapshot {
        let selection: CountsSelection
        let queueRevision: UInt64
        let progress: GCSBatchProgress
        let retryable: Int
        let total: Int
    }
    @Published private var countsSnapshot: CountsSnapshot?
    @Published private(set) var countsError: String?
    private var countsSelection: CountsSelection { CountsSelection(batchID: currentBatchID, authorizedUUIDs: allowedUUIDs) }
    private var selectedCounts: CountsSnapshot? { countsSnapshot?.selection == countsSelection ? countsSnapshot : nil }
    var hasQueueCounts: Bool { selectedCounts != nil }
    var countsAreCurrent: Bool { selectedCounts?.queueRevision == queueRevision && countsError == nil }
    var countsReadMessage: String? {
        guard !countsAreCurrent else { return nil }
        if countsError != nil {
            return hasQueueCounts ? "Totaux indisponibles · derniers comptes vérifiés affichés." : "Totaux indisponibles · la file complète ne peut pas être lue."
        }
        return "Actualisation des totaux de collecte…"
    }

    private var queueStorageIssue: String?
    private var dirtyTransferIDs: Set<String> = []
    private var queueSourceIndex: [GCSTransferSource: Int] = [:]
    private var queueIDIndex: [String: Int] = [:]
    private var legacyTransfers: [GCSTransfer] = []
    private let initialDestination: URL?
    private let collectorOverride: URL?
    private let snapshotOverride: (() -> FleetSnapshot)?
    private let importOverride: ((URL, String?) async throws -> FleetSnapshot)?
    private let directoryIssueOverride: (@Sendable (URL) -> String?)?
    private weak var library: LibraryStore?
    private var discoveryTask: Task<Void, Never>?
    private var inventoryTask: Task<Void, Never>?
    private var transferTasks: [String: Task<Void, Never>] = [:]
    private var analysisTask: Task<Void, Never>?
    private var activeAnalysisID: String?
    // Reserve capacity for both verified files and downloads already in flight.
    // This bounds the analysis backlog without keeping a network slot during parsing.
    let maxBufferedImports = 4
    var activeAnalysisCount: Int { analysisTask == nil ? 0 : 1 }
    var bufferedAnalysisCount: Int { queue.lazy.filter { $0.state == "importing" }.count }
    @Published private(set) var isScanningFleet = false
    @Published private(set) var inventoryErrors: [String] = []
    @Published private(set) var expectedInventoryUUIDs: Set<String> = []
    @Published private(set) var completedInventoryUUIDs: Set<String> = []
    private var inventoryFailures: [String: String] = [:]
    @Published private(set) var cachedFileCount = 0
    @Published private(set) var destinationPreviewFileCount: Int?
    private var currentBatchID: String
    private var inventoryBusyUntil: [String: Date] = [:]
    private lazy var fleetObservations = makeFleetObservationStore()
    @Published private(set) var fleetObservationRevision = 0
    private var activeInventoryUUID: String?
    let maxConcurrentDownloads = GCSQueuePolicy.maxConcurrentDownloads
    var activeTransferCount: Int { transferTasks.count }
    var retryableCount: Int { selectedCounts?.retryable ?? 0 }
    var isStopping: Bool { queue.contains { (transferTasks[$0.id] != nil || activeAnalysisID == $0.id) && $0.state == "stopped" } }
    var diagnosticJobCount: Int? { countsAreCurrent ? selectedCounts?.total : nil }
    var batchProgress: GCSBatchProgress { selectedCounts?.progress ?? GCSBatchProgress(transfers: []) }

    // Called by model updates, never by SwiftUI getters. A failed read preserves
    // only the last explicit snapshot for this batch and authorized fleet.
    private func loadInitialCounts() {
        // Background maintenance may own the repository lock. Its final save or
        // the existing timer refreshes counts after the gate is released.
        guard !isMaintenanceBlocked else { return }
        do {
            if let queueStorageIssue { throw AnalysisError.unavailable(queueStorageIssue) }
            let progress: GCSBatchProgress, retryable: Int, total: Int
            if let queueRepository {
                let counts = try queueRepository.counts(batchID: currentBatchID, authorizedUUIDs: allowedUUIDs, overlay: dirtyTransfers)
                progress = counts.progress; retryable = counts.retryable; total = counts.total
            } else {
                guard hasCompleteInMemoryQueue else { throw AnalysisError.unavailable("La file complète ne peut pas être lue.") }
                progress = GCSBatchProgress(transfers: queue.filter { $0.batchID == currentBatchID })
                retryable = queue.filter { ["failed", "interrupted", "stopped"].contains($0.state) && allowedUUIDs.contains($0.droneUUID) }.count
                total = queue.count
            }
            countsSnapshot = CountsSnapshot(selection: countsSelection, queueRevision: queueRevision,
                                            progress: progress, retryable: retryable, total: total)
            countsError = nil
        } catch { countsError = error.localizedDescription }
    }
    func refreshQueueCounts() {
        guard !isMaintenanceBlocked else { return }
        countsAgain = true
        guard countsTask == nil else { return }
        countsTask = Task { [weak self] in
            guard let self else { return }
            defer { countsTask = nil }
            while countsAgain && !isMaintenanceBlocked {
                countsAgain = false
                let selection = countsSelection, revision = queueRevision, generation = storageGeneration
                let repository = queueRepository, overlay = dirtyTransfers
                let all = repository == nil ? queue : []
                let complete = hasCompleteInMemoryQueue, issue = queueStorageIssue
                do {
                    let result = try await storageIO.perform {
                        if let issue { throw AnalysisError.unavailable(issue) }
                        if let repository { return try repository.counts(batchID: selection.batchID, authorizedUUIDs: selection.authorizedUUIDs, overlay: overlay) }
                        guard complete else { throw AnalysisError.unavailable("La file complète ne peut pas être lue.") }
                        return GCSQueueCounts(progress: GCSBatchProgress(transfers: all.filter { $0.batchID == selection.batchID }),
                            retryable: all.filter { ["failed", "interrupted", "stopped"].contains($0.state) && selection.authorizedUUIDs.contains($0.droneUUID) }.count,
                            total: all.count)
                    }
                    guard generation == storageGeneration, !isMaintenanceBlocked else { continue }
                    if selection == countsSelection && revision == queueRevision {
                        countsSnapshot = CountsSnapshot(selection: selection, queueRevision: revision,
                            progress: result.progress, retryable: result.retryable, total: result.total)
                        countsError = nil
                    } else { countsAgain = true }
                } catch {
                    guard generation == storageGeneration, selection == countsSelection else { continue }
                    countsError = error.localizedDescription
                }
            }
        }
    }
    func waitForQueueCounts() async {
        refreshQueueCounts()
        await countsTask?.value
    }
    var collectionFraction: Double { overallFraction(for: batchProgress) }
    func overallFraction(for progress: GCSBatchProgress) -> Double {
        guard countsAreCurrent else { return 0 }
        if progress.totalCount > 0 { return progress.fraction }
        let allPreviewFilesPresent = destinationPreviewFileCount.map { $0 > 0 && cachedFileCount == $0 } ?? true
        return cachedFileCount > 0 && allPreviewFilesPresent && !isScanningFleet && !hasIncompleteInventory ? 1 : 0
    }
    var isReadOnly: Bool { library?.isReadOnly == true }
    var isMaintenanceBlocked: Bool { isReconcilingClients || isStorageTransitioning || startupStorageDeferred || library?.isStartupBlocked == true || library?.isMaintainingLibrary == true }
    /// Discovery is limited to the connected GCS. Explicit bulk collection also
    /// registers its new UUIDs; assigning a stock number is a separate operation.
    var collectableDrones: [GCSDrone] { drones.filter { GCSIdentity.isValid($0.uuid) && $0.isOnline && $0.armed != true } }
    var newCollectableDroneCount: Int { collectableDrones.filter { !allowedUUIDs.contains($0.uuid) }.count }
    var canCollectAll: Bool { !isReadOnly && !isMaintenanceBlocked && queueStorageIssue == nil && downloadDirectoryIssue == nil && isConnected && !isBusy && !collectableDrones.isEmpty }
    var hasIncompleteInventory: Bool { !expectedInventoryUUIDs.isSubset(of: completedInventoryUUIDs) || !inventoryFailures.isEmpty }
    var inventoryCoverageLabel: String { "\(completedInventoryUUIDs.intersection(expectedInventoryUUIDs).count) / \(expectedInventoryUUIDs.count) drones recensés" }
    var batchStatusMessage: String {
        if let countsReadMessage { return countsReadMessage }
        let progress = batchProgress
        if isScanningFleet { return "Lecture des inventaires de la flotte · \(inventoryCoverageLabel)" }
        if isBusy && progress.totalCount == 0 && selectedUUID != nil && files.isEmpty {
            return "Lecture de l’inventaire du drone sélectionné…"
        }
        if hasIncompleteInventory {
            if isQueuePaused && progress.activeCount == 0 { return "Collecte arrêtée · inventaire incomplet · \(inventoryCoverageLabel)" }
            if progress.activeCount > 0 || progress.pendingCount > 0 { return "Collecte en cours · inventaire incomplet · \(inventoryCoverageLabel)" }
            return "Collecte partielle · inventaire incomplet · \(inventoryCoverageLabel)"
        }
        if progress.totalCount == 0, let available = destinationPreviewFileCount, available > 0 {
            let missing = max(0, available - cachedFileCount)
            let scope = completedInventoryUUIDs.sorted().first.map {
                library?.annotations.displayName(forGCSUUID: $0) ?? "Drone \($0.prefix(8))…"
            } ?? "Inventaire vérifié"
            return missing > 0
                ? "\(scope) · \(missing) log\(missing == 1 ? "" : "s") à collecter dans ce dossier · \(cachedFileCount) déjà présent\(cachedFileCount == 1 ? "" : "s")."
                : "\(scope) à jour · \(cachedFileCount) log\(cachedFileCount == 1 ? "" : "s") déjà présent\(cachedFileCount == 1 ? "" : "s") et vérifié\(cachedFileCount == 1 ? "" : "s")."
        }
        if progress.totalCount == 0 && cachedFileCount > 0 { return "À jour · \(cachedFileCount) logs déjà présents et vérifiés." }
        if progress.totalCount == 0 && !expectedInventoryUUIDs.isEmpty { return "Aucun log disponible · inventaire terminé sur \(expectedInventoryUUIDs.count) drone\(expectedInventoryUUIDs.count == 1 ? "" : "s")." }
        if progress.totalCount == 0 { return "Collectez toute la flotte connectée ou sélectionnez les logs d’un drone." }
        if progress.stoppedCount > 0 && progress.activeCount == 0 && progress.pendingCount == 0 { return "Collecte arrêtée · les fichiers déjà vérifiés sont conservés." }
        if progress.completedCount == progress.totalCount { return "Collecte terminée · tous les fichiers ont été vérifiés." }
        if isQueuePaused { return progress.activeCount == 0 ? "Collecte en pause" : "Pause demandée · les fichiers en cours se terminent" }
        if activeTransferCount == 0 && bufferedAnalysisCount > 0 {
            return "Analyse des fichiers collectés · \(bufferedAnalysisCount) restant\(bufferedAnalysisCount == 1 ? "" : "s")"
        }
        if progress.activeCount > 0 { return "Collecte en cours · jusqu’à \(maxConcurrentDownloads) drones simultanément" }
        if queue.contains(where: { $0.state == "retrying" }) { return "Nouvel essai automatique programmé pour les transferts interrompus." }
        if progress.pendingCount > 0 { return "En attente d’un drone disponible ou de la fin du transfert GCS précédent." }
        if progress.stoppedCount > 0 { return "Collecte arrêtée · les fichiers déjà vérifiés sont conservés." }
        if progress.failedCount > 0 { return "Collecte terminée avec des erreurs · relancez les fichiers concernés." }
        return "Les fichiers téléchargés sont conservés sur ce Mac."
    }
    private struct DestinationSnapshot {
        let url: URL
        let issue: String?
    }
    @Published private var destinationSnapshot: DestinationSnapshot?
    private var destinationCheckTask: Task<Void, Never>?
    var downloadDirectoryIssue: String? {
        guard let snapshot = destinationSnapshot, snapshot.url == downloadDirectory else {
            return "Vérification du dossier de collecte…"
        }
        return snapshot.issue
    }
    var canStopCollection: Bool { isBusy || queue.contains(where: \.isPending) }
    private func updateBusy() { isBusy = inventoryTask != nil || !transferTasks.isEmpty || analysisTask != nil || bufferedAnalysisCount > 0 }
    private func isRemoteBusy(_ uuid: String) -> Bool {
        (inventoryBusyUntil[uuid] ?? .distantPast) > Date() || queue.contains { $0.droneUUID == uuid && ($0.remoteBusyUntil ?? .distantPast) > Date() }
    }
    private var refreshTask: Task<Void, Never>?
    private var termination: AnyCancellable?
    private var reconnect: Bool
    private var pendingAttachmentReconnect = false
    private var connectedHost: String?
    private var lastSave = Date.distantPast
    private var startupStorageDeferred = false
    private var isReconcilingClients = false
    private var reconciledClientIDs: Set<String>?

    init(storageDirectory: URL? = nil, collector: URL? = nil,
         snapshot: (() -> FleetSnapshot)? = nil,
         importer: ((URL, String?) async throws -> FleetSnapshot)? = nil,
         directoryIssue: (@Sendable (URL) -> String?)? = nil,
         previewConfiguration: AppPreviewConfiguration = AppPreviewConfiguration(),
         applicationSupportDirectory: URL? = nil) {
        collectorOverride = collector
        snapshotOverride = snapshot
        importOverride = importer
        directoryIssueOverride = directoryIssue
        let base = previewConfiguration.libraryDirectory(storageDirectory: storageDirectory,
                                                        applicationSupportDirectory: applicationSupportDirectory)
        startupStorageDeferred = LibraryStorageService.hasPendingRestore(in: base)
        stateURL = base.appendingPathComponent("gcs-settings.json")
        legacyStateURL = base.appendingPathComponent("gcs-collection.json")
        queueDatabaseURL = base.appendingPathComponent("gcs-queue.sqlite")
        let inputStateURL = FileManager.default.fileExists(atPath: stateURL.path) ? stateURL : legacyStateURL
        initialDestination = FileManager.default.fileExists(atPath: inputStateURL.path) ? nil : base.appendingPathComponent("Collected Logs")
        var state = GCSCollectionState(downloadDirectory: base.appendingPathComponent("Collected Logs").path)
        var loadError: String?
        if !startupStorageDeferred, FileManager.default.fileExists(atPath: inputStateURL.path) {
            do {
                let saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: inputStateURL))
                guard saved.schemaVersion == 1 else { throw AnalysisError.schema(saved.schemaVersion) }
                if let queueVersion = saved.queueStorageVersion, queueVersion != 1 { throw AnalysisError.schema(queueVersion) }
                state = saved
            } catch {
                loadError = "La file enregistrée n’a pas pu être ouverte. Le fichier original est conservé ; restaurez une sauvegarde avant de collecter."
                queueStorageIssue = loadError
            }
        }
        host = state.host
        collectionClientID = state.collectionClientID
        allowedUUIDs = Set(state.allowedUUIDs.filter(GCSIdentity.isValid).map { $0.uppercased() })
        if !startupStorageDeferred, let saved = try? JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: legacyStateURL)) { legacyTransfers = saved.queue }
        if !startupStorageDeferred, FileManager.default.fileExists(atPath: queueDatabaseURL.path) {
            do {
                let repository = try GCSQueueRepository(url: queueDatabaseURL, readOnly: true)
                if try repository.hasMigratedLegacy { state.queue = try repository.retainedTransfers() }
                queueRepository = repository; hasCompleteInMemoryQueue = false
            } catch { loadError = error.localizedDescription; queueStorageIssue = loadError }
        } else if state.queueStorageVersion != nil {
            loadError = "La file SQLite enregistrée est absente. Restaurez une sauvegarde avant de relancer la collecte."
            queueStorageIssue = loadError
        }
        for i in state.queue.indices { state.queue[i].recoverAfterRelaunch() }
        currentBatchID = state.currentBatchID ?? UUID().uuidString
        for i in state.queue.indices where state.queue[i].batchID == nil { state.queue[i].batchID = currentBatchID }
        if queueRepository == nil || (try? queueRepository?.hasMigratedLegacy) == false { legacyTransfers = state.queue }
        queue = state.queue
        dirtyTransferIDs = Set(state.queue.filter { !$0.isSuccessful }.map(\.id))
        cachedFileCount = state.cachedFileCount ?? 0
        destinationPreviewFileCount = state.destinationPreviewFileCount
        expectedInventoryUUIDs = state.expectedInventoryUUIDs ?? []
        completedInventoryUUIDs = state.completedInventoryUUIDs ?? []
        inventoryFailures = state.inventoryFailures ?? [:]
        inventoryErrors = inventoryFailures.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))… : \($0.value)" }
        isQueuePaused = state.queuePaused ?? false
        inventoryBusyUntil = state.inventoryBusyUntil ?? [:]
        downloadDirectory = URL(fileURLWithPath: state.downloadDirectory, isDirectory: true)
        autoImport = state.autoImport; reconnect = state.reconnect
        errorMessage = loadError
        rebuildQueueIndexes()
        if !startupStorageDeferred {
            _ = fleetObservations
            destinationSnapshot = DestinationSnapshot(url: downloadDirectory,
                issue: directoryIssue.map { $0(downloadDirectory) } ?? Self.directoryIssue(downloadDirectory))
        }
        loadInitialCounts()
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.stopForTermination()
        }
    }

    func chooseCollectionClient(_ id: String) {
        guard permitMutation(), !isBusy else { return }
        guard id.isEmpty || library?.clients.profiles.contains(where: { $0.id == id }) == true else {
            errorMessage = "Ce client n’existe plus. Choisissez un destinataire."; return
        }
        collectionClientID = id; persist()
    }

    /// Called while the library owns its maintenance gate. No original is touched.
    func resetForApplication() async throws {
        guard !isBusy else { throw AnalysisError.engine("Arrêtez la collecte avant la réinitialisation.") }
        discoveryTask?.cancel(); discoveryTask = nil
        inventoryTask?.cancel(); inventoryTask = nil
        pendingAttachmentReconnect = false; reconnect = false; isQueuePaused = true; configurationDirty = true
        isConnected = false; isConnecting = false; connectedHost = nil
        try await validateResetForApplication()
        await persistenceTask?.value
        storageGeneration &+= 1
        await countsTask?.value
        try await storageIO.close()
        queueRepository = nil; repositoryWritable = false
        let directory = stateURL.deletingLastPathComponent(), names = Self.resetConfigurationNames
        try await storageIO.perform {
            try LibraryStore.removeConfigurationFiles(in: directory, names: names)
        }
        try await loadRestoredCollectionState()
        collectionClientID = nil; isQueuePaused = false
        errorMessage = nil; statusMessage = nil; configurationDirty = true
    }

    private static let resetConfigurationNames = ["gcs-settings.json", "gcs-collection.json",
        "gcs-queue.sqlite", "gcs-queue.sqlite-wal", "gcs-queue.sqlite-shm", "fleet.json"]

    private func validateResetForApplication() async throws {
        guard !isBusy else { throw AnalysisError.engine("Arrêtez la collecte avant la réinitialisation.") }
        let directory = stateURL.deletingLastPathComponent(), names = Self.resetConfigurationNames
        try await storageIO.perform { try LibraryStore.validateConfigurationFiles(in: directory, names: names) }
    }

    func attach(library: LibraryStore) {
        guard self.library == nil else { return }
        self.library = library
        library.hasExternalActivity = { [weak self] in self?.isBusy == true || self?.isReconcilingClients == true || self?.isStorageTransitioning == true }
        library.willMaintainLibrary = { [weak self] in try await self?.flushPersistedStateForMaintenance() }
        library.willRestoreLibrary = { [weak self] in try await self?.preparePersistedStorageForRestore() }
        library.didRestoreLibrary = { [weak self] in try await self?.reloadPersistedStateAfterRestore() }
        library.resetCollectionState = { [weak self] in try await self?.resetForApplication() }
        library.validateCollectionReset = { [weak self] in try await self?.validateResetForApplication() }
        library.clientDidDelete = { [weak self] id in try await self?.removeClientAttribution(id) }
        library.clientProfilesDidLoad = { [weak self] ids in try await self?.reconcileClientAttributions(validIDs: ids) }
        if !library.isStartupBlocked && (startupStorageDeferred || library.recoveredAtStartup) {
            startupStorageDeferred = true
            attachmentTask = Task { [weak self] in
                guard let self else { return }
                defer { attachmentTask = nil }
                do { try await reloadPersistedStateAfterRestore() }
                catch { errorMessage = error.localizedDescription }
            }
        }
        recordFleetObservations([])
        // A first launch can attach while the index is being prepared. Preserve
        // this pending initialization so the app-owned destination and queue are
        // created after maintenance instead of waiting for a manual connection.
        configurationDirty = true
        if !isReadOnly && !isMaintenanceBlocked { persist() }
        startRefreshLoop()
        pendingAttachmentReconnect = reconnect && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        reconnectAfterAttachmentIfReady()
        library.clients.reloadIfNeeded(refresh: true)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshQueueCounts()
                self.refreshDestination()
                self.objectWillChange.send() // Availability and retry countdown expire without new packets.
                if (!self.dirtyTransferIDs.isEmpty || self.configurationDirty || self.fleetObservations.pendingState != nil) && !self.isReadOnly && !self.isMaintenanceBlocked { self.persist() }
                self.fleetObservations.flush()
                self.reconnectAfterAttachmentIfReady()
                self.runQueue()
            }
        }
    }
    func cancelTermination() {
        terminationRequested = false
        if library != nil { startRefreshLoop() }
        refreshQueueCounts()
    }
    func waitForStorageLoad() async { await attachmentTask?.value }

    private func reconnectAfterAttachmentIfReady() {
        // Startup index preparation temporarily owns the maintenance gate.
        // Resume discovery once it releases; never resume a stopped transfer.
        guard pendingAttachmentReconnect, !isMaintenanceBlocked else { return }
        pendingAttachmentReconnect = false
        if reconnect { connect() }
    }

    private func removeClientAttribution(_ id: String) async throws {
        guard !isBusy else { throw AnalysisError.engine("Arrêtez la collecte avant de supprimer ce client.") }
        isReconcilingClients = true
        defer { isReconcilingClients = false }
        await persistenceTask?.value
        if let repository = queueRepository {
            try await storageIO.perform { try repository.removeClientAttribution(id) }
        }
        for index in queue.indices where queue[index].clientID == id {
            queue[index].clientID = nil; dirtyTransferIDs.insert(queue[index].id)
        }
        if collectionClientID == id { collectionClientID = ""; configurationDirty = true }
        try await saveState(duringMaintenance: true)
    }

    private func reconcileClientAttributions(validIDs: Set<String>) async throws {
        guard reconciledClientIDs != validIDs else { return }
        guard !isReadOnly, !isBusy, !isMaintenanceBlocked else {
            throw AnalysisError.engine("Arrêtez la collecte et attendez la fin de la maintenance avant de recharger les clients.")
        }
        if let queueStorageIssue { throw AnalysisError.engine(queueStorageIssue) }
        isReconcilingClients = true
        defer { isReconcilingClients = false }
        await persistenceTask?.value
        if !repositoryWritable { try await writeState(duringMaintenance: true) }
        if let repository = queueRepository {
            try await storageIO.perform { try repository.reconcileClientAttributions(validIDs: validIDs) }
        }
        for index in queue.indices {
            if let id = queue[index].clientID, !validIDs.contains(id) {
                queue[index].clientID = nil; dirtyTransferIDs.insert(queue[index].id)
            }
        }
        if let id = collectionClientID, !id.isEmpty, !validIDs.contains(id) {
            collectionClientID = ""; configurationDirty = true
        }
        // Keep the gate until cleanup is durably saved after all admitted writes.
        try await saveState(duringMaintenance: true)
        reconciledClientIDs = validIDs
    }

    /// The library raises its maintenance gate before awaiting this durable drain.
    func flushPersistedStateForMaintenance() async throws {
        guard !isBusy else { throw AnalysisError.unavailable("Arrêtez la collecte avant l’opération de stockage.") }
        let previousTransition = isStorageTransitioning
        isStorageTransitioning = true
        defer { if !previousTransition { finishStorageTransition() } }
        try await saveState(duringMaintenance: true)
        fleetObservations.flush()
        if let error = fleetObservations.errorMessage { throw AnalysisError.engine(error) }
    }

    /// Restore changes files beneath this store. Reopen handles without reconnecting or starting work.
    func preparePersistedStorageForRestore() async throws {
        guard !isBusy else { throw AnalysisError.unavailable("Arrêtez la collecte avant de restaurer la bibliothèque.") }
        discoveryTask?.cancel(); discoveryTask = nil
        isConnected = false; isConnecting = false; connectedHost = nil; reconnect = false
        await persistenceTask?.value
        storageGeneration &+= 1
        await countsTask?.value
        try await storageIO.close()
        queueRepository = nil; repositoryWritable = false
        countsSnapshot = nil; hasCompleteInMemoryQueue = false
        refreshQueueCounts()
    }

    /// Restore changes files beneath this store. Reopen handles without reconnecting or starting work.
    func reloadPersistedStateAfterRestore() async throws {
        guard !isReadOnly, !isBusy else { throw AnalysisError.unavailable("Arrêtez la collecte avant de restaurer la bibliothèque.") }
        try await preparePersistedStorageForRestore()
        queueStorageIssue = "La file de collecte restaurée n’a pas encore été vérifiée."
        queue = []; rebuildQueueIndexes(); legacyTransfers = []; dirtyTransferIDs = []; configurationDirty = false
        isQueuePaused = true
        defer { refreshQueueCounts() }
        do { try await loadRestoredCollectionState(); startupStorageDeferred = false }
        catch {
            queueRepository = nil; repositoryWritable = false
            queue = []; rebuildQueueIndexes(); legacyTransfers = []; dirtyTransferIDs = []; configurationDirty = false
            queueStorageIssue = "La file de collecte restaurée ne peut pas être lue : \(error.localizedDescription) Reconnectez après avoir restauré une sauvegarde valide ou corrigé les fichiers."
            errorMessage = queueStorageIssue
            throw error
        }
    }

    private func loadRestoredCollectionState() async throws {
        reconciledClientIDs = nil
        drones = []; selectedUUID = nil; files = []; selectedFileIDs = []; knownAnalysisHashes = []
        queueRepository = nil; repositoryWritable = false
        countsSnapshot = nil; hasCompleteInMemoryQueue = true
        let stateURL = stateURL, legacyStateURL = legacyStateURL, queueDatabaseURL = queueDatabaseURL
        let loaded = try await storageIO.perform { () -> (GCSCollectionState, GCSQueueRepository?, Result<GCSFleetObservationState, Error>) in
            let input = FileManager.default.fileExists(atPath: stateURL.path) ? stateURL : legacyStateURL
            var state = GCSCollectionState(downloadDirectory: stateURL.deletingLastPathComponent().appendingPathComponent("Collected Logs").path)
            if FileManager.default.fileExists(atPath: input.path) {
                state = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: input))
                guard state.schemaVersion == 1 else { throw AnalysisError.schema(state.schemaVersion) }
                if let version = state.queueStorageVersion, version != 1 { throw AnalysisError.schema(version) }
            }
            var repository: GCSQueueRepository?
            if FileManager.default.fileExists(atPath: queueDatabaseURL.path) {
                repository = try GCSQueueRepository(url: queueDatabaseURL, readOnly: true)
                if try repository?.hasMigratedLegacy == true { state.queue = try repository!.retainedTransfers() }
            } else if state.queueStorageVersion != nil {
                throw AnalysisError.unavailable("La sauvegarde restaurée ne contient pas la file SQLite attendue.")
            }
            let fleet = Result { try GCSFleetObservationStore.read(file: stateURL.deletingLastPathComponent().appendingPathComponent("fleet.json")) }
            return (state, repository, fleet)
        }
        try Task.checkCancellation()
        var state = loaded.0
        queueRepository = loaded.1; hasCompleteInMemoryQueue = loaded.1 == nil
        for index in state.queue.indices { state.queue[index].recoverAfterRelaunch() }
        currentBatchID = state.currentBatchID ?? UUID().uuidString
        for index in state.queue.indices where state.queue[index].batchID == nil { state.queue[index].batchID = currentBatchID }
        legacyTransfers = state.queue
        queue = state.queue; dirtyTransferIDs = Set(queue.map(\.id))
        rebuildQueueIndexes()
        host = state.host
        collectionClientID = state.collectionClientID
        allowedUUIDs = Set(state.allowedUUIDs.filter(GCSIdentity.isValid).map { $0.uppercased() })
        fleetObservations = makeFleetObservationStore(loaded: loaded.2)
        fleetObservationRevision = fleetObservations.state.revision
        downloadDirectory = URL(fileURLWithPath: state.downloadDirectory, isDirectory: true)
        destinationSnapshot = nil
        _ = try await destinationIssue(downloadDirectory)
        isApplyingRestoredState = true; autoImport = state.autoImport; isApplyingRestoredState = false
        cachedFileCount = state.cachedFileCount ?? 0
        destinationPreviewFileCount = state.destinationPreviewFileCount
        expectedInventoryUUIDs = state.expectedInventoryUUIDs ?? []; completedInventoryUUIDs = state.completedInventoryUUIDs ?? []
        inventoryFailures = state.inventoryFailures ?? [:]
        inventoryErrors = inventoryFailures.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))… : \($0.value)" }
        inventoryBusyUntil = state.inventoryBusyUntil ?? [:]
        queueStorageIssue = nil; isQueuePaused = true; configurationDirty = true; errorMessage = nil
        statusMessage = "Collecte restaurée et mise en pause. Reconnectez la GCS pour reprendre explicitement."
        if !isMaintenanceBlocked { try await saveState() }
    }

    private var script: URL? {
        if let collectorOverride { return collectorOverride }
        if let url = Bundle.main.url(forResource: "gcs_collect", withExtension: "py") { return url }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "gcs_collect", withExtension: "py", subdirectory: "Resources") { return url }
        #endif
        return nil
    }

    func connect() {
        guard permitMutation() else { return }
        pendingAttachmentReconnect = false
        guard discoveryTask == nil else { return }
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 253,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]%_").contains($0) }) else {
            errorMessage = "Saisissez l’adresse de la GCS, par exemple gcs.local, sans http:// ni chemin."; return
        }
        guard let script else { errorMessage = "Le collecteur GCS est absent de l’app."; return }
        host = value; connectedHost = value; isConnecting = true; errorMessage = nil
        reconnect = true; persist()
        library?.diagnostics.record(.gcsConnecting)
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false; self.isConnected = false; self.discoveryTask = nil }
            while !Task.isCancelled {
                do {
                    for try await event in GCSProcessService.events(script: script, arguments: ["discover", "--host", value, "--port", "1999"]) {
                        try Task.checkCancellation()
                        switch event.event {
                        case "connection":
                            let previouslyConnected = self.isConnected
                            self.isConnected = event.connected == true; self.isConnecting = !self.isConnected
                            if self.isConnected != previouslyConnected { self.library?.diagnostics.record(self.isConnected ? .gcsConnected : .gcsDisconnected, code: self.isConnected ? .none : .disconnected) }
                            if self.isConnected { self.statusMessage = "GCS connectée · surveillance des drones active"; self.errorMessage = nil }
                        case "drones":
                            let fresh = event.drones ?? []
                            var indexed = Dictionary(self.drones.map { ($0.uuid, $0) }, uniquingKeysWith: { _, b in b })
                            var observed: [GCSDrone] = []
                            for var drone in fresh {
                                if let old = indexed[drone.uuid], let stamp = drone.timeUsec, old.timeUsec == stamp {
                                    drone.lastSeen = old.lastSeen
                                }
                                indexed[drone.uuid] = drone
                                observed.append(drone)
                            }
                            self.drones = indexed.values.filter { self.allowedUUIDs.contains($0.uuid) || Date().timeIntervalSince($0.lastSeen) < 60 }
                                .sorted { $0.uuid < $1.uuid }
                            self.recordFleetObservations(observed)
                            self.runQueue()
                        case "transfer_end":
                            if let uuid = event.uuid, let path = event.path {
                                for i in self.queue.indices where self.queue[i].droneUUID == uuid && self.queue[i].remoteBusyUntil != nil && !self.queue[i].isActive {
                                    let job = self.queue[i]
                                    if path == job.remotePath || (path as NSString).lastPathComponent == "\(uuid)_\(job.filename)" {
                                        self.queue[i].remoteBusyUntil = nil
                                        self.dirtyTransferIDs.insert(self.queue[i].id)
                                        if self.queue[i].state == "retrying" {
                                            self.queue[i].nextRetryAt = min(self.queue[i].nextRetryAt ?? Date(), Date().addingTimeInterval(5))
                                        }
                                    }
                                }
                                self.persist(); self.runQueue()
                            }
                        case "error": self.errorMessage = event.message
                        default: break
                        }
                    }
                } catch is CancellationError { return }
                catch { if !Task.isCancelled { self.library?.diagnostics.record(.gcsDisconnected, code: .connectionUnavailable); self.errorMessage = "Connexion GCS perdue : \(error.localizedDescription)" } }
                if Task.isCancelled { return }
                self.isConnected = false; self.isConnecting = true
                for i in self.drones.indices { self.drones[i].lastSeen = .distantPast }
                self.statusMessage = "GCS indisponible · nouvelle tentative dans 5 secondes"
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func disconnect() {
        guard !isBusy else { pauseQueue(); return }
        pendingAttachmentReconnect = false
        reconnect = false; isQueuePaused = true
        if let uuid = activeInventoryUUID { inventoryBusyUntil[uuid] = Date().addingTimeInterval(21) }
        discoveryTask?.cancel(); inventoryTask?.cancel()
        isConnected = false; isConnecting = false; connectedHost = nil
        for i in drones.indices { drones[i].lastSeen = .distantPast }
        selectedUUID = nil; files = []; selectedFileIDs = []
        library?.diagnostics.record(.gcsDisconnected)
        statusMessage = "GCS déconnectée"; persist()
    }

    func setAllowed(uuid: String, allowed: Bool) {
        guard permitMutation() else { return }
        guard GCSIdentity.isValid(uuid) else { return }
        if allowed { allowedUUIDs.insert(uuid) }
        else {
            guard !queue.contains(where: { $0.droneUUID == uuid && $0.isActive }) else { return }
            allowedUUIDs.remove(uuid)
            for i in queue.indices where queue[i].droneUUID == uuid && queue[i].isPending {
                queue[i].state = "interrupted"; queue[i].error = "Drone retiré de la flotte."
                dirtyTransferIDs.insert(queue[i].id)
            }
            if selectedUUID == uuid { inventoryTask?.cancel(); selectedUUID = nil; files = []; selectedFileIDs = [] }
        }
        recordFleetObservations(drones)
        persist()
    }

    private func makeFleetObservationStore(loaded: Result<GCSFleetObservationState, Error>? = nil) -> GCSFleetObservationStore {
        GCSFleetObservationStore(file: stateURL.deletingLastPathComponent().appendingPathComponent("fleet.json"), automaticFlush: false, loaded: loaded, canMutate: { [weak self] in
            guard let self else { return false }
            return !self.isReadOnly && !self.isMaintenanceBlocked
        })
    }
    private func recordFleetObservations(_ observed: [GCSDrone]) {
        if isStorageTransitioning {
            for drone in observed { deferredFleetObservations[drone.uuid] = drone }
            return
        }
        fleetObservations.record(observed, authorized: allowedUUIDs)
        fleetObservationRevision = fleetObservations.state.revision
        if let error = fleetObservations.errorMessage { errorMessage = error }
    }

    private func finishStorageTransition() {
        guard isStorageTransitioning else { return }
        isStorageTransitioning = false
        let observed = Array(deferredFleetObservations.values)
        deferredFleetObservations.removeAll()
        if !observed.isEmpty { recordFleetObservations(observed) }
    }

    private func registerFleet(_ drones: [GCSDrone], authorized: Set<String>) async throws {
        let next = try fleetObservations.registrationState(drones, authorized: authorized)
        isStorageTransitioning = true
        defer { finishStorageTransition(); refreshQueueCounts() }
        try await saveState(authorizing: authorized, fleet: next, duringMaintenance: true)
        allowedUUIDs = authorized
    }

    func selectDrone(_ uuid: String) async {
        guard permitMutation(), !isBusy else { return }
        let control = controlRevision
        if !allowedUUIDs.contains(uuid) {
            guard let drone = collectableDrones.first(where: { $0.uuid == uuid }) else { return }
            let admitted = allowedUUIDs.union([uuid])
            do {
                try await registerFleet([drone], authorized: admitted)
                allowedUUIDs = admitted; fleetObservationRevision = fleetObservations.state.revision
            } catch { errorMessage = error.localizedDescription; return }
        }
        guard control == controlRevision, !terminationRequested else { persist(); return }
        selectedUUID = uuid; selectedFileIDs = []; files = []
        refreshInventory()
    }

    func refreshInventory(updateDestinationProgress: Bool = false) {
        guard permitMutation() else { return }
        guard let uuid = selectedUUID, canRead(uuid), !isBusy, inventoryTask == nil else { return }
        isBusy = true; errorMessage = nil; statusMessage = "Lecture de la carte SD…"
        let currentHost = connectedHost ?? host, destination = downloadDirectory.path
        inventoryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inventoryTask = nil; self.updateBusy(); self.runQueue() }
            do {
                self.files = try await self.readInventory(uuid: uuid, host: currentHost, destination: destination)
                self.selectedFileIDs = self.selectedFileIDs.intersection(Set(self.files.filter { !$0.isDownloaded }.map(\.id)))
                if updateDestinationProgress {
                    self.recordInventory(uuid: uuid)
                    self.destinationPreviewFileCount = self.files.count
                    let cached = Set(self.files.filter(\.isDownloaded).map {
                        GCSTransferSource(uuid: uuid, file: $0, destination: destination).cacheIdentity
                    })
                    try await self.prepareQueueStorage()
                    let repository = self.queueRepository, batch = self.currentBatchID
                    self.cachedFileCount = try await self.storageIO.perform { try repository?.recordCachedFiles(batchID: batch, identities: cached) ?? 0 }
                    self.persist()
                }
                self.statusMessage = "\(self.files.count) logs · \(self.files.filter(\.isDownloaded).count) déjà récupérés"
            } catch is CancellationError { self.statusMessage = "Lecture de la carte arrêtée" }
            catch {
                if updateDestinationProgress { self.recordInventory(uuid: uuid, error: error.localizedDescription); self.persist() }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func readInventory(uuid: String, host: String, destination: String) async throws -> [GCSLogFile] {
        library?.diagnostics.record(.inventoryStarted, correlation: currentBatchID + uuid)
        var inventorySucceeded = false
        defer { if !inventorySucceeded { library?.diagnostics.record(.inventoryCompleted, code: Task.isCancelled ? .cancelled : .connectionUnavailable, correlation: currentBatchID + uuid) } }
        guard let script else { throw AnalysisError.unavailable("Le collecteur GCS est absent de l’app.") }
        for attempt in 1...GCSQueuePolicy.maxAttempts {
            try Task.checkCancellation()
            // A cancelled download may still be finishing on the GCS. Never overlap FTP for that drone.
            while isRemoteBusy(uuid) {
                statusMessage = "Attente de la fin du transfert déjà lancé sur la GCS…"
                try await Task.sleep(for: .seconds(1))
            }
            try await requireDestination(URL(fileURLWithPath: destination, isDirectory: true))
            try Task.checkCancellation()
            var retryable = true
            activeInventoryUUID = uuid
            defer { activeInventoryUUID = nil }
            do {
                var result: [GCSLogFile]?
                var inventoryID: String?
                var expectedTotal: Int?
                var nextPage = 0
                var pages: [GCSLogFile] = []
                for try await event in GCSProcessService.events(script: script, arguments: ["inventory", "--host", host, "--port", "1999", "--uuid", uuid, "--destination", destination], writerLibrary: library?.storageDirectory) {
                    try Task.checkCancellation()
                    if event.event == "error" { retryable = event.retryable ?? true; throw AnalysisError.engine(event.message ?? "Impossible de lister les logs.") }
                    guard event.uuid == uuid else { continue }
                    switch event.event {
                    case "inventory":
                        guard inventoryID == nil, result == nil, let items = event.files,
                              items.count <= 100_000, Set(items.map(\.id)).count == items.count else {
                            retryable = false; throw AnalysisError.engine("Inventaire legacy invalide.")
                        }
                        result = items
                    case "inventory_progress":
                        if event.phase == "cache" {
                            statusMessage = "Vérification du cache · \(event.completedFiles ?? 0) / \(event.totalFiles ?? 0) logs"
                        }
                    case "inventory_started":
                        guard inventoryID == nil, result == nil, let token = event.inventoryID, let total = event.totalFiles,
                              !token.isEmpty, token.count <= 64, (0...100_000).contains(total) else {
                            retryable = false; throw AnalysisError.engine("Début d’inventaire invalide.")
                        }
                        inventoryID = token; expectedTotal = total
                    case "inventory_page":
                        guard result == nil, let token = inventoryID, event.inventoryID == token, event.pageIndex == nextPage,
                              let items = event.files, !items.isEmpty, items.count <= 256,
                              pages.count + items.count <= (expectedTotal ?? 0) else {
                            retryable = false; throw AnalysisError.engine("Page d’inventaire manquante ou invalide.")
                        }
                        pages.append(contentsOf: items); nextPage += 1
                    case "inventory_finished":
                        guard result == nil, inventoryID != nil, event.inventoryID == inventoryID,
                              event.pageCount == nextPage, event.totalFiles == expectedTotal,
                              pages.count == expectedTotal, Set(pages.map(\.id)).count == pages.count else {
                            retryable = false; throw AnalysisError.engine("L’inventaire paginé est incomplet.")
                        }
                        result = pages
                    default: break
                    }
                }
                guard let result else { retryable = inventoryID == nil; throw AnalysisError.engine("La GCS n’a renvoyé aucun inventaire complet.") }
                if autoImport, snapshotOverride == nil, let library, library.usesPagedNavigation {
                    let cachedIDs = result.filter(\.isDownloaded).compactMap(\.sha256)
                    knownAnalysisHashes.subtract(cachedIDs)
                    let valid = try await library.validIndexedLogIDs(cachedIDs)
                    try Task.checkCancellation()
                    knownAnalysisHashes.formUnion(valid)
                }
                inventorySucceeded = true
                library?.diagnostics.record(.inventoryCompleted, correlation: currentBatchID + uuid, metrics: [.items: Int64(result.count)])
                let cached = result.filter(\.isDownloaded).count
                if cached > 0 { library?.diagnostics.record(.cacheHit, correlation: currentBatchID + uuid, metrics: [.items: Int64(cached)]) }
                return result.sorted { $0.path > $1.path }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard retryable, let retry = GCSQueuePolicy.retryDate(attempt: attempt) else { throw error }
                statusMessage = "Inventaire : nouvelle tentative \(attempt + 1)/3…"
                try await Task.sleep(for: .seconds(max(0, retry.timeIntervalSinceNow)))
            }
        }
        throw AnalysisError.engine("Inventaire indisponible.")
    }

    func toggleFile(_ file: GCSLogFile) {
        guard !file.isDownloaded else { return }
        if selectedFileIDs.contains(file.id) { selectedFileIDs.remove(file.id) } else { selectedFileIDs.insert(file.id) }
    }
    func selectAllFiles(visibleIDs: Set<String>? = nil) {
        let pending = Set(files.filter { !$0.isDownloaded && (visibleIDs?.contains($0.id) ?? true) }.map(\.id))
        guard !pending.isEmpty else { return }
        if pending.isSubset(of: selectedFileIDs) { selectedFileIDs.subtract(pending) }
        else { selectedFileIDs.formUnion(pending) }
    }
    private func beginBatchIfNeeded(preserveInventories: Bool = false) {
        destinationPreviewFileCount = nil
        if !queue.contains(where: { $0.isPending || $0.isActive }) {
            currentBatchID = UUID().uuidString; cachedFileCount = 0
            if !preserveInventories {
                expectedInventoryUUIDs = []; completedInventoryUUIDs = []; inventoryFailures = [:]; inventoryErrors = []
            }
        }
    }
    private func recordInventory(uuid: String, error: String? = nil) {
        expectedInventoryUUIDs.insert(uuid)
        if let error {
            completedInventoryUUIDs.remove(uuid); inventoryFailures[uuid] = error
        } else {
            completedInventoryUUIDs.insert(uuid); inventoryFailures[uuid] = nil
        }
        inventoryErrors = inventoryFailures.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))… : \($0.value)" }
    }
    @discardableResult
    func enqueue(_ candidates: [GCSLogFile], uuid: String, host: String, destination: String, clientID: String? = nil) async throws -> Int {
        let batchID = currentBatchID, shouldImport = autoImport
        let snapshot = snapshotOverride?() ?? library?.snapshot ?? .empty
        var previousJobs: [GCSTransferSource: GCSTransfer] = [:]
        for (offset, file) in candidates.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation(); await Task.yield() }
            let key = GCSTransferSource(uuid: uuid, file: file, destination: destination)
            if let index = queueSourceIndex[key] { previousJobs[key] = queue[index] }
        }
        // Only immutable values cross the actor boundary. File hashing remains in
        // the collector helper; job creation and historical SQLite lookups do not
        // occupy the UI actor or rebuild an index for every drone inventory.
        let planner = Task.detached(priority: .utility) { [existing = previousJobs, repository = queueRepository, known = knownAnalysisHashes] in
            var jobs: [GCSTransfer] = []
            let analyzed = shouldImport ? known.union(snapshot.logs.lazy.filter {
                $0.status != "error" && $0.metadata["parserVersion"] == AnalysisService.parserVersion
            }.map(\.id)) : []
            for file in candidates where !file.isDownloaded || (shouldImport && !analyzed.contains(file.sha256 ?? "")) {
                try Task.checkCancellation()
                let key = GCSTransferSource(uuid: uuid, file: file, destination: destination)
                let previous: GCSTransfer?
                if let item = existing[key] {
                    if item.isPending || item.isActive { continue }
                    previous = item
                } else { previous = try repository?.matchingTransfer(uuid: uuid, path: file.path, size: file.size, destination: destination) }
                var job = GCSTransfer(droneUUID: uuid, remotePath: file.path, size: file.size, host: host, destination: destination)
                job.batchID = batchID; job.clientID = clientID
                if file.isDownloaded { job.localPath = file.localPath; job.sha256 = file.sha256 }
                if let previous { job.id = previous.id; job.remoteBusyUntil = previous.remoteBusyUntil }
                jobs.append(job)
            }
            return jobs
        }
        let jobs = try await withTaskCancellationHandler { try await planner.value } onCancel: { planner.cancel() }
        try Task.checkCancellation()
        guard currentBatchID == batchID, autoImport == shouldImport, allowedUUIDs.contains(uuid),
              downloadDirectory.path == destination, (connectedHost ?? self.host) == host else {
            throw AnalysisError.unavailable("La collecte a changé pendant la préparation. Relancez l’inventaire pour utiliser les réglages actuels.")
        }
        var updated = queue
        var added = 0
        for var job in jobs {
            let key = GCSTransferSource(job)
            if let index = queueSourceIndex[key] {
                // A cancellation, authorization change or another worker may have
                // changed the live job while the immutable plan was being built.
                if updated[index].isPending || updated[index].isActive || transferTasks[updated[index].id] != nil { continue }
                job.id = updated[index].id; job.remoteBusyUntil = updated[index].remoteBusyUntil
                updated[index] = job
            } else {
                queueSourceIndex[key] = updated.count; queueIDIndex[job.id] = updated.count
                updated.append(job)
            }
            dirtyTransferIDs.insert(job.id); added += 1
        }
        if added > 0 {
            queue = updated
            library?.diagnostics.record(.collectionStarted, correlation: currentBatchID, metrics: [.items: Int64(added)])
        }
        return added
    }
    func enqueueSelected() {
        guard permitMutation() else { return }
        guard let uuid = selectedUUID, canRead(uuid), !isBusy, !isScanningFleet, !isStopping else { return }
        beginBatchIfNeeded()
        recordInventory(uuid: uuid)
        let candidates = files.filter { selectedFileIDs.contains($0.id) }
        let currentHost = connectedHost ?? host, destination = downloadDirectory.path
        let clientID = collectionClientID ?? ""
        isBusy = true; statusMessage = "Préparation de la collecte…"
        inventoryTask = Task { [weak self] in
            guard let self else { return }
            defer { inventoryTask = nil; updateBusy(); persist(); runQueue() }
            do {
                try await requireDestination(URL(fileURLWithPath: destination, isDirectory: true))
                try Task.checkCancellation()
                let added = try await enqueue(candidates, uuid: uuid, host: currentHost, destination: destination, clientID: clientID)
                selectedFileIDs = []; isQueuePaused = false; statusMessage = "\(added) logs ajoutés à la collecte"
            } catch is CancellationError { statusMessage = "Préparation de la collecte arrêtée." }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func collectAll() async {
        guard permitMutation() else { return }
        let control = controlRevision
        guard await validateDestination(downloadDirectory), control == controlRevision, permitMutation(),
              canCollectAll, let currentHost = connectedHost else { return }
        let candidates = collectableDrones
        let fleet = Set(candidates.map(\.uuid)).sorted()
        let registered = allowedUUIDs.union(fleet)
        do {
            // Do not publish membership or schedule work until both settings and
            // registry have been saved. A failed admission leaves no queued jobs.
            try await registerFleet(candidates, authorized: registered)
            allowedUUIDs = registered
            fleetObservationRevision = fleetObservations.state.revision
        } catch {
            errorMessage = "Collecte non démarrée. \(error.localizedDescription)"
            return
        }
        guard control == controlRevision, !terminationRequested else { persist(); return }
        let destination = downloadDirectory.path
        let clientID = collectionClientID ?? ""
        beginBatchIfNeeded(); isQueuePaused = false; isBusy = true; isScanningFleet = true; errorMessage = nil
        expectedInventoryUUIDs.formUnion(fleet)
        // A new read invalidates the previous coverage for those devices until it succeeds.
        completedInventoryUUIDs.subtract(fleet)
        persist()
        inventoryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inventoryTask = nil; self.isScanningFleet = false; self.updateBusy(); self.persist(); self.runQueue() }
            for (offset, uuid) in fleet.enumerated() {
                if Task.isCancelled { return }
                self.statusMessage = "Inventaire de la flotte · drone \(offset + 1)/\(fleet.count)"
                do {
                    guard self.canRead(uuid) else { throw AnalysisError.engine(self.errorMessage ?? "Drone indisponible.") }
                    let items = try await self.readInventory(uuid: uuid, host: currentHost, destination: destination)
                    try Task.checkCancellation()
                    guard self.allowedUUIDs.contains(uuid) else { continue }
                    self.recordInventory(uuid: uuid)
                    let cached = Set(items.filter(\.isDownloaded).map { GCSTransferSource(uuid: uuid, file: $0, destination: destination).cacheIdentity })
                    try await self.prepareQueueStorage()
                    let repository = self.queueRepository, batch = self.currentBatchID
                    self.cachedFileCount = try await self.storageIO.perform { try repository?.recordCachedFiles(batchID: batch, identities: cached) ?? 0 }
                    try await self.enqueue(items, uuid: uuid, host: currentHost, destination: destination, clientID: clientID)
                    if self.selectedUUID == uuid { self.files = items; self.selectedFileIDs = [] }
                    self.persist()
                } catch {
                    if Task.isCancelled { return }
                    self.recordInventory(uuid: uuid, error: error.localizedDescription)
                    self.persist()
                }
            }
            self.statusMessage = "\(self.batchProgress.totalCount) logs à récupérer · \(self.cachedFileCount) déjà présents"
        }
    }

    func pauseQueue() {
        guard permitMutation() else { return }
        isQueuePaused = true
        library?.diagnostics.record(.collectionPaused, correlation: currentBatchID)
        statusMessage = activeTransferCount > 0 || bufferedAnalysisCount > 0 ? "Pause après les fichiers en cours." : "File en pause"
        persist()
    }
    func resumeQueue() { guard permitMutation() else { return }; isQueuePaused = false; library?.diagnostics.record(.collectionStarted, correlation: currentBatchID); persist(); runQueue() }
    func stopCollection() {
        controlRevision &+= 1
        library?.diagnostics.record(.collectionStopped, code: .cancelled, correlation: currentBatchID)
        isQueuePaused = true
        if let uuid = activeInventoryUUID { inventoryBusyUntil[uuid] = Date().addingTimeInterval(21) }
        inventoryTask?.cancel()
        for task in transferTasks.values { task.cancel() }
        analysisTask?.cancel()
        var updated = queue
        for i in updated.indices where updated[i].isPending || updated[i].isActive {
            updated[i].state = "stopped"; updated[i].nextRetryAt = nil
            updated[i].error = "Arrêt demandé. Le fichier pourra être relancé ; les fichiers déjà vérifiés sont conservés."
            dirtyTransferIDs.insert(updated[i].id)
        }
        queue = updated
        statusMessage = "Collecte arrêtée · les transferts déjà envoyés à la GCS peuvent finir côté drone."
        persist()
    }
    func retryFailed() async {
        defer { refreshQueueCounts() }
        guard permitMutation() else { return }
        guard !isBusy, !isScanningFleet else { return }
        // A save admitted before this command may replace the retained array.
        // Drain it before capturing the revision, so this harmless replacement
        // does not silently discard an explicit retry.
        await persistenceTask?.value
        guard permitMutation(), !isBusy, !isScanningFleet else { return }
        do {
            let existing = Set(queue.map(\.id)), revision = queueRevision, selection = countsSelection
            let repository = queueRepository, authorized = allowedUUIDs
            let stored = try await storageIO.perform { try repository?.retryableTransfers(authorizedUUIDs: authorized) ?? [] }
            guard permitMutation(), !isBusy, revision == queueRevision, selection == countsSelection else { return }
            queue.append(contentsOf: stored.filter { !existing.contains($0.id) && allowedUUIDs.contains($0.droneUUID) })
            rebuildQueueIndexes()
        } catch { errorMessage = error.localizedDescription; return }
        let candidates = queue.indices.filter { ["failed", "interrupted", "stopped"].contains(queue[$0].state) && allowedUUIDs.contains(queue[$0].droneUUID) }
        guard !candidates.isEmpty else { return }
        beginBatchIfNeeded(preserveInventories: true)
        var identities = Set(queue.filter { $0.isPending || $0.isActive }.map { GCSTransferSource($0) })
        var updated = queue
        for i in candidates {
            let key = GCSTransferSource(updated[i])
            guard identities.insert(key).inserted else { continue }
            updated[i].state = "queued"; updated[i].error = nil; updated[i].completedBytes = 0
            updated[i].attemptCount = 0; updated[i].nextRetryAt = nil; updated[i].batchID = currentBatchID
            updated[i].phase = nil; updated[i].phaseBytes = nil; updated[i].phaseTotal = nil
            dirtyTransferIDs.insert(updated[i].id)
        }
        queue = updated
        isQueuePaused = false; statusMessage = "Reprise de la collecte demandée"; persist(); runQueue()
    }

    private func canRead(_ uuid: String) -> Bool {
        guard isConnected, allowedUUIDs.contains(uuid), let drone = drones.first(where: { $0.uuid == uuid }), drone.isOnline else {
            errorMessage = "Connectez la GCS et sélectionnez un drone de votre flotte actuellement visible."; return false
        }
        guard drone.armed != true else { errorMessage = "Le drone est armé. La collecte attend qu’il soit désarmé."; return false }
        return true
    }
    private func runQueue() {
        runAnalysisQueue()
        guard !isReadOnly, !isMaintenanceBlocked, !terminationRequested, persistenceTask == nil, queueStorageIssue == nil, persistenceError == nil, inventoryTask == nil, !isQueuePaused, isConnected, let currentHost = connectedHost, let script else { return }
        let available = Set(drones.filter { allowedUUIDs.contains($0.uuid) && $0.isOnline && $0.armed != true && (inventoryBusyUntil[$0.uuid] ?? .distantPast) <= Date() }.map(\.uuid))
        var retargeted = false
        for index in queue.indices where queue[index].isPending && available.contains(queue[index].droneUUID) {
            if queue[index].host != currentHost {
                dirtyTransferIDs.insert(queue[index].id)
                queue[index].retargetPending(to: currentHost)
                retargeted = true
            }
        }
        let importCapacity = max(0, maxBufferedImports - bufferedAnalysisCount - transferTasks.count)
        let jobs = GCSQueuePolicy.nextJobs(queue: queue, activeIDs: Set(transferTasks.keys), availableUUIDs: available, host: currentHost).prefix(importCapacity)
        for id in jobs {
            guard let index = queueIDIndex[id] else { continue }
            queue[index].state = "downloading"; queue[index].error = nil
            queue[index].completedBytes = 0; queue[index].nextRetryAt = nil
            queue[index].phase = nil; queue[index].phaseBytes = nil; queue[index].phaseTotal = nil
            dirtyTransferIDs.insert(id)
            // Reserve synchronously before a task can yield or discovery schedules more work.
            transferTasks[id] = Task { [weak self] in await self?.download(id: id, script: script) }
        }
        updateBusy()
        if retargeted || !jobs.isEmpty { persist() }
    }
    private func download(id: String, script: URL) async {
        guard let index = queueIDIndex[id] else { return }
        let job = queue[index]
        let diagnosticCorrelation = (job.batchID ?? currentBatchID) + id
        var lastDiagnosticProgress = Date.distantPast
        defer { dirtyTransferIDs.insert(id); transferTasks[id] = nil; updateBusy(); persist(); runQueue() }
        var retryable = false
        var diagnosticFailure: DiagnosticEvent.Code = .storageUnavailable
        do {
            try Task.checkCancellation()
            try await requireDestination(URL(fileURLWithPath: job.destination, isDirectory: true))
            try Task.checkCancellation()
            queue[index].attemptCount += 1
            // A reserved job must be durable before its collector can start.
            try await saveState()
            try Task.checkCancellation()
            library?.diagnostics.record(.transferStarted, correlation: diagnosticCorrelation, metrics: [.totalBytes: job.size, .retryAttempt: Int64(queue[index].attemptCount)])
            retryable = true; diagnosticFailure = .transferFailed
            var downloaded = false
            let args = ["download", "--host", job.host, "--port", "1999", "--http-port", "8080", "--uuid", job.droneUUID,
                        "--remote", job.remotePath, "--size", String(job.size), "--destination", job.destination]
            for try await event in GCSProcessService.events(script: script, arguments: args, writerLibrary: library?.storageDirectory) {
                try Task.checkCancellation()
                if event.event == "error" { retryable = event.retryable ?? true; throw AnalysisError.engine(event.message ?? "Échec de la collecte.") }
                guard event.uuid == job.droneUUID, event.path == job.remotePath else { continue }
                dirtyTransferIDs.insert(id)
                switch event.event {
                case "transfer_started":
                    queue[index].phase = "drone"; queue[index].phaseBytes = 0; queue[index].phaseTotal = job.size
                    library?.diagnostics.record(.transferProgress, phase: .drone, correlation: diagnosticCorrelation, metrics: [.bytes: 0, .totalBytes: job.size])
                    queue[index].remoteBusyUntil = Date().addingTimeInterval(min(3600, max(300, event.timeoutSeconds ?? 300)) + 5)
                    persist()
                case "transfer_finished": queue[index].remoteBusyUntil = nil; persist()
                case "phase":
                    if let phase = event.phase, ["drone", "http", "verification"].contains(phase) {
                        queue[index].phase = phase; queue[index].phaseBytes = event.bytes; queue[index].phaseTotal = event.total
                        library?.diagnostics.record(.transferProgress, phase: DiagnosticEvent.Phase(rawValue: phase), correlation: diagnosticCorrelation, metrics: [.bytes: event.bytes ?? 0, .totalBytes: event.total ?? job.size])
                    }
                case "progress":
                    queue[index].receiveProgress(phase: event.phase, bytes: event.bytes ?? 0, total: event.total)
                    if Date().timeIntervalSince(lastDiagnosticProgress) >= 5 {
                        lastDiagnosticProgress = Date()
                        library?.diagnostics.record(.transferProgress, phase: DiagnosticEvent.Phase(rawValue: queue[index].phase ?? ""), correlation: diagnosticCorrelation, metrics: [.bytes: event.bytes ?? 0, .totalBytes: event.total ?? job.size])
                    }
                    if Date().timeIntervalSince(lastSave) > 1 { persist() }
                case "downloaded":
                    guard let local = event.localPath, let hash = event.sha256, event.bytes == job.size else { throw AnalysisError.engine("Réponse de téléchargement incomplète.") }
                    queue[index].localPath = local; queue[index].sha256 = hash
                    queue[index].completedBytes = job.size; downloaded = true
                    queue[index].phase = "verified"; queue[index].phaseBytes = job.size; queue[index].phaseTotal = job.size
                default: break
                }
                refreshQueueCounts()
            }
            try Task.checkCancellation()
            guard downloaded else { throw AnalysisError.engine("Aucun fichier complet reçu.") }
            // The collector has exited after verified publication. Persist the analysis
            // obligation before this worker releases its network/per-drone slot.
            retryable = false; diagnosticFailure = .storageUnavailable
            queue[index].state = autoImport ? "importing" : "downloaded"
            if autoImport { queue[index].phase = "import" }
            dirtyTransferIDs.insert(id)
            try await saveState()
            if !autoImport { await finishTransfer(job: job, analyzed: false) }
        } catch {
            if Task.isCancelled {
                library?.diagnostics.record(.transferCompleted, code: .cancelled, correlation: diagnosticCorrelation)
                if queue[index].state != "stopped" { queue[index].state = "interrupted"; queue[index].error = "Collecte interrompue. Relancez le fichier pour reprendre." }
            } else if retryable, let date = GCSQueuePolicy.retryDate(attempt: queue[index].attemptCount) {
                library?.diagnostics.record(.transferRetrying, code: .transferFailed, correlation: diagnosticCorrelation, metrics: [.retryAttempt: Int64(queue[index].attemptCount + 1)])
                queue[index].state = "retrying"
                queue[index].nextRetryAt = max(date, queue[index].remoteBusyUntil ?? .distantPast)
                queue[index].error = "\(error.localizedDescription) · nouvelle tentative \(queue[index].attemptCount + 1)/3"
            } else {
                library?.diagnostics.record(.transferCompleted, code: diagnosticFailure, correlation: diagnosticCorrelation)
                queue[index].state = "failed"; queue[index].error = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runAnalysisQueue() {
        // Pause drains files whose transfer already finished; stop marks them stopped
        // and cancels the one analyzer. Importing remains a durable unfinished state.
        guard !isReadOnly, !isMaintenanceBlocked, !terminationRequested, persistenceTask == nil, queueStorageIssue == nil, persistenceError == nil, analysisTask == nil,
              let job = queue.first(where: { $0.state == "importing" && transferTasks[$0.id] == nil }) else { return }
        activeAnalysisID = job.id
        analysisTask = Task { [weak self] in await self?.analyze(job: job) }
        updateBusy()
    }

    private func analyze(job: GCSTransfer) async {
        let id = job.id
        guard let index = queueIDIndex[id] else { analysisTask = nil; activeAnalysisID = nil; updateBusy(); return }
        let correlation = (job.batchID ?? currentBatchID) + id
        defer {
            dirtyTransferIDs.insert(id); analysisTask = nil; activeAnalysisID = nil
            updateBusy(); persist(); runQueue()
        }
        do {
            try Task.checkCancellation()
            guard let local = job.localPath else { throw AnalysisError.engine("Le fichier collecté est introuvable.") }
            let collectedFile = URL(fileURLWithPath: local)
            let result: FleetSnapshot
            if let importOverride { result = try await importOverride(collectedFile, job.clientID) }
            else if let library { result = try await library.importCollectedFolder(collectedFile, expectedLogID: job.sha256, clientID: job.clientID) }
            else { throw AnalysisError.unavailable("La bibliothèque doit être ouverte pour analyser le fichier collecté.") }
            try Task.checkCancellation()
            guard let log = result.logs.first(where: { $0.id == job.sha256 }), log.status != "error",
                  log.metadata["parserVersion"] == AnalysisService.parserVersion else {
                throw AnalysisError.engine("Le fichier a été téléchargé, mais sa lecture ULog a échoué. Voir la bibliothèque.")
            }
            queue[index].state = "complete"
            dirtyTransferIDs.insert(id)
            knownAnalysisHashes.insert(log.id)
            if log.status == "partial" { queue[index].error = "Analyse partielle : consultez la couverture du log." }
            await finishTransfer(job: job, analyzed: true)
        } catch {
            if Task.isCancelled {
                library?.diagnostics.record(.transferCompleted, code: .cancelled, correlation: correlation)
                if queue[index].state != "stopped" {
                    queue[index].state = "interrupted"; queue[index].error = "Collecte interrompue. Relancez le fichier pour reprendre."
                }
            } else {
                // Analysis failures retain the verified local file and never trigger
                // automatic FTP retries. Explicit retry rechecks the existing cache.
                queue[index].state = "failed"; queue[index].error = error.localizedDescription
                errorMessage = error.localizedDescription
                library?.diagnostics.record(.transferCompleted, code: .analysisFailed, correlation: correlation)
            }
        }
    }

    private func finishTransfer(job: GCSTransfer, analyzed: Bool) async {
        await waitForQueueCounts()
        library?.diagnostics.record(.transferCompleted, correlation: (job.batchID ?? currentBatchID) + job.id,
                                    metrics: [.bytes: job.size, .totalBytes: job.size])
        let completed = batchProgress
        if countsAreCurrent && completed.totalCount > 0 && completed.completedCount == completed.totalCount {
            library?.diagnostics.record(.collectionCompleted, correlation: currentBatchID, metrics: [.items: Int64(completed.totalCount)])
        }
        if selectedUUID == job.droneUUID, let index = files.firstIndex(where: { $0.path == job.remotePath }) { files[index].isDownloaded = true }
        statusMessage = analyzed ? "\(job.filename) récupéré et analysé" : "\(job.filename) récupéré"
    }

    func chooseDownloadDirectory() {
        guard permitMutation() else { return }
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "Choisir"; panel.title = "Dossier de collecte"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { try await setDownloadDirectory(url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
    func setDownloadDirectory(_ url: URL) async throws {
        guard permitMutation() else { throw AnalysisError.unavailable(errorMessage ?? "La bibliothèque est en lecture seule.") }
        guard !isBusy, !queue.contains(where: \.isPending) else {
            throw AnalysisError.unavailable("Arrêtez la collecte et les transferts en attente avant de changer de dossier.")
        }
        let destination = url.standardizedFileURL
        try await requireDestination(destination)
        guard permitMutation(), !isBusy, !queue.contains(where: \.isPending) else {
            throw AnalysisError.unavailable("La collecte ne permet plus de changer de dossier.")
        }
        guard destination.path != downloadDirectory.standardizedFileURL.path else { return }
        isStorageTransitioning = true
        defer { finishStorageTransition() }
        let previous = downloadDirectory, previousDestination = destinationSnapshot
        let previousBatch = currentBatchID, previousCachedCount = cachedFileCount
        let previousPreviewCount = destinationPreviewFileCount
        let previousExpected = expectedInventoryUUIDs, previousCompleted = completedInventoryUUIDs
        let previousFailures = inventoryFailures, previousErrors = inventoryErrors
        downloadDirectory = destination
        destinationSnapshot = DestinationSnapshot(url: destination, issue: nil)
        currentBatchID = UUID().uuidString; cachedFileCount = 0
        destinationPreviewFileCount = nil
        expectedInventoryUUIDs = []; completedInventoryUUIDs = []; inventoryFailures = [:]; inventoryErrors = []
        do { try await saveState(duringMaintenance: true) }
        catch {
            downloadDirectory = previous; destinationSnapshot = previousDestination; currentBatchID = previousBatch; cachedFileCount = previousCachedCount
            destinationPreviewFileCount = previousPreviewCount
            expectedInventoryUUIDs = previousExpected; completedInventoryUUIDs = previousCompleted
            inventoryFailures = previousFailures; inventoryErrors = previousErrors
            refreshQueueCounts()
            throw error
        }
        finishStorageTransition()
        library?.diagnostics.record(.destinationChanged)
        files = []; selectedFileIDs = []
        errorMessage = nil
        statusMessage = "Dossier de collecte enregistré. La progression est recalculée pour ce dossier ; les anciennes copies sont conservées."
        if let uuid = selectedUUID, isConnected,
           drones.contains(where: { $0.uuid == uuid && $0.isOnline && $0.armed != true }) {
            refreshInventory(updateDestinationProgress: true)
        }
    }
    func revealDownloads() {
        let destination = downloadDirectory
        Task { if await validateDestination(destination) { NSWorkspace.shared.open(destination) } }
    }
    private nonisolated static func directoryIssue(_ url: URL) -> String? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return "Le dossier de collecte doit être un dossier local : \(url.path)." }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            return "Dossier de collecte indisponible : \(url.path). Reconnectez le volume ou choisissez un dossier existant. Aucun autre dossier ne sera utilisé."
        }
        guard FileManager.default.isReadableFile(atPath: url.path), FileManager.default.isWritableFile(atPath: url.path),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return "Accès au dossier de collecte refusé : \(url.path). Vérifiez les autorisations de lecture et d’écriture."
        }
        return nil
    }
    private func destinationIssue(_ url: URL) async throws -> String? {
        let checker = directoryIssueOverride, generation = storageGeneration
        let issue = try await storageIO.perform {
            if let checker { return checker(url) }
            return Self.directoryIssue(url)
        }
        if generation == storageGeneration, url == downloadDirectory {
            destinationSnapshot = DestinationSnapshot(url: url, issue: issue)
        }
        return issue
    }
    private func refreshDestination() {
        guard !isMaintenanceBlocked, !terminationRequested, destinationCheckTask == nil else { return }
        let destination = downloadDirectory
        destinationCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { destinationCheckTask = nil }
            _ = try? await destinationIssue(destination)
        }
    }
    func waitForDestinationCheck() async { await destinationCheckTask?.value }
    private func requireDestination(_ url: URL) async throws {
        if let issue = try await destinationIssue(url) { throw AnalysisError.unavailable(issue) }
    }
    private func validateDestination(_ url: URL) async -> Bool {
        do { try await requireDestination(url); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    private func saveState(authorizing proposed: Set<String>? = nil,
                           fleet registration: GCSFleetObservationState? = nil,
                           duringMaintenance: Bool = false) async throws {
        await persistenceTask?.value
        try await writeState(authorizing: proposed, fleet: registration, duringMaintenance: duringMaintenance)
    }
    private func writeState(authorizing proposed: Set<String>? = nil,
                            fleet registration: GCSFleetObservationState? = nil,
                            duringMaintenance: Bool = false) async throws {
        guard !isReadOnly, (duringMaintenance || !isMaintenanceBlocked), queueStorageIssue == nil else {
            throw AnalysisError.unavailable(queueStorageIssue ?? "La bibliothèque ne permet pas l’enregistrement de la collecte.")
        }
        let dirty = dirtyTransfers, revision = queueRevision, configuration = configurationRevision
        let generation = storageGeneration
        var state = GCSCollectionState(downloadDirectory: downloadDirectory.path)
        state.collectionClientID = collectionClientID
        state.host = host; state.allowedUUIDs = proposed ?? allowedUUIDs; state.autoImport = autoImport
        state.reconnect = reconnect; state.queue = []; state.queueStorageVersion = 1
        state.currentBatchID = currentBatchID; state.cachedFileCount = cachedFileCount; state.queuePaused = isQueuePaused; state.inventoryBusyUntil = inventoryBusyUntil
        state.destinationPreviewFileCount = destinationPreviewFileCount
        state.expectedInventoryUUIDs = expectedInventoryUUIDs; state.completedInventoryUUIDs = completedInventoryUUIDs; state.inventoryFailures = inventoryFailures
        if proposed == nil { fleetObservations.record([], authorized: allowedUUIDs) }
        let fleet = registration ?? fleetObservations.pendingState
        let request = GCSStorageIO.Write(state: state, transfers: dirty, legacy: legacyTransfers,
            initialDestination: initialDestination, retain: proposed == nil && !isBusy,
            fleet: fleet, registering: registration != nil)
        do {
            let result = try await storageIO.save(request)
            guard generation == storageGeneration else { return }
            queueRepository = result.repository; repositoryWritable = true; hasCompleteInMemoryQueue = false
            legacyTransfers = []
            lastSave = Date(); persistenceError = nil
            if configuration == configurationRevision { configurationDirty = false }
            if revision == queueRevision {
                dirtyTransferIDs.subtract(dirty.map(\.id))
                if let retained = result.retained, !isBusy { queue = retained; rebuildQueueIndexes() }
                let selection = CountsSelection(batchID: state.currentBatchID ?? "", authorizedUUIDs: state.allowedUUIDs)
                if selection == countsSelection {
                    switch result.counts {
                    case .success(let counts):
                        countsSnapshot = CountsSnapshot(selection: selection, queueRevision: queueRevision,
                            progress: counts.progress, retryable: counts.retryable, total: counts.total)
                        countsError = nil
                    case .failure(let error): countsError = error.localizedDescription
                    }
                }
            }
            if let fleet { fleetObservations.didPersist(fleet) }
            fleetObservationRevision = fleetObservations.state.revision
            if downloadDirectoryIssue != nil { refreshDestination() }
        } catch {
            persistenceError = error; isQueuePaused = true
            throw error
        }
    }
    func waitForPersistence() async throws {
        await persistenceTask?.value
        if let persistenceError { throw persistenceError }
    }
    private var dirtyTransfers: [GCSTransfer] { dirtyTransferIDs.compactMap { queueIDIndex[$0] }.sorted().map { queue[$0] } }
    private func rebuildQueueIndexes() {
        queueSourceIndex = [:]; queueIDIndex = [:]
        for (index, item) in queue.enumerated() {
            queueIDIndex[item.id] = index
            let source = GCSTransferSource(item)
            if let previous = queueSourceIndex[source], queue[previous].isPending || queue[previous].isActive,
               !item.isPending && !item.isActive { continue }
            queueSourceIndex[source] = index
        }
    }
    private func prepareQueueStorage() async throws {
        if !repositoryWritable { try await saveState() }
    }
    private func permitMutation() -> Bool {
        if terminationRequested { errorMessage = "La collecte est arrêtée pour la fermeture de l’app."; return false }
        if isReadOnly { errorMessage = "Cette bibliothèque est ouverte par une autre instance. La collecte est en lecture seule."; return false }
        if isMaintenanceBlocked { errorMessage = "Attendez la fin de l’opération de stockage avant de relancer la collecte."; return false }
        if let queueStorageIssue { errorMessage = queueStorageIssue; return false }
        return true
    }
    private func persist() {
        configurationDirty = true; configurationRevision &+= 1
        guard !isReadOnly, !isMaintenanceBlocked, queueStorageIssue == nil else { return }
        persistAgain = true
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            defer { persistenceTask = nil; runQueue() }
            while persistAgain && !isMaintenanceBlocked {
                persistAgain = false
                do { try await writeState() }
                catch { errorMessage = "Impossible d’enregistrer la file de collecte : \(error.localizedDescription)"; break }
            }
            refreshQueueCounts()
        }
    }
    func finishTermination() async throws {
        stopForTermination()
        await attachmentTask?.value
        while isStorageTransitioning { try await Task.sleep(for: .milliseconds(10)) }
        // An unavailable/read-only library owns no writable collection state.
        guard !isReadOnly, !startupStorageDeferred, library?.isStartupBlocked != true, queueStorageIssue == nil else { return }
        let transfers = Array(transferTasks.values), inventory = inventoryTask, analysis = analysisTask
        await inventory?.value
        for task in transfers { await task.value }
        await analysis?.value
        try await saveState()
        try await waitForPersistence()
    }
    func stopForTermination() {
        guard !terminationRequested else { return }
        terminationRequested = true; controlRevision &+= 1
        pendingAttachmentReconnect = false
        isQueuePaused = true
        if let uuid = activeInventoryUUID { inventoryBusyUntil[uuid] = Date().addingTimeInterval(21) }
        discoveryTask?.cancel(); inventoryTask?.cancel(); refreshTask?.cancel(); attachmentTask?.cancel()
        for task in transferTasks.values { task.cancel() }
        analysisTask?.cancel()
        var updated = queue
        for i in updated.indices where updated[i].isPending || updated[i].isActive { updated[i].recoverAfterRelaunch(); dirtyTransferIDs.insert(updated[i].id) }
        queue = updated
        persist()
    }
}
