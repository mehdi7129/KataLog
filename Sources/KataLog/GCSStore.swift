import AppKit
import Combine
import Foundation
import KataLogCore

@MainActor
final class GCSStore: ObservableObject {
    @Published var host: String
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isBusy = false
    @Published var isQueuePaused = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var drones: [GCSDrone] = []
    @Published private(set) var allowedUUIDs: Set<String>
    @Published private(set) var selectedUUID: String?
    @Published private(set) var files: [GCSLogFile] = []
    @Published var selectedFileIDs: Set<String> = []
    @Published private(set) var queue: [GCSTransfer]
    @Published private(set) var downloadDirectory: URL
    @Published var autoImport: Bool { didSet { persist() } }
    private let stateURL: URL
    private let collectorOverride: URL?
    private let snapshotOverride: (() -> FleetSnapshot)?
    private let importOverride: ((URL) async throws -> FleetSnapshot)?
    private let directoryIssueOverride: ((URL) -> String?)?
    private weak var library: LibraryStore?
    private var discoveryTask: Task<Void, Never>?
    private var inventoryTask: Task<Void, Never>?
    private var transferTasks: [String: Task<Void, Never>] = [:]
    @Published private(set) var isScanningFleet = false
    @Published private(set) var inventoryErrors: [String] = []
    @Published private(set) var cachedFileCount = 0
    private var currentBatchID: String
    private var inventoryBusyUntil: [String: Date] = [:]
    private var activeInventoryUUID: String?
    let maxConcurrentDownloads = GCSQueuePolicy.maxConcurrentDownloads
    var activeTransferCount: Int { transferTasks.count }
    var isStopping: Bool { queue.contains { transferTasks[$0.id] != nil && $0.state == "stopped" } }
    var batchProgress: GCSBatchProgress { GCSBatchProgress(transfers: queue.filter { $0.batchID == currentBatchID }) }
    var canCollectAll: Bool { downloadDirectoryIssue == nil && isConnected && !isBusy && !queue.contains(where: \.isPending) && drones.contains { allowedUUIDs.contains($0.uuid) && $0.isOnline && $0.armed != true } }
    var downloadDirectoryIssue: String? { directoryIssue(downloadDirectory) }
    var canStopCollection: Bool { isBusy || queue.contains(where: \.isPending) }
    private func updateBusy() { isBusy = inventoryTask != nil || !transferTasks.isEmpty }
    private func isRemoteBusy(_ uuid: String) -> Bool {
        (inventoryBusyUntil[uuid] ?? .distantPast) > Date() || queue.contains { $0.droneUUID == uuid && ($0.remoteBusyUntil ?? .distantPast) > Date() }
    }
    private var refreshTask: Task<Void, Never>?
    private var termination: AnyCancellable?
    private var reconnect: Bool
    private var connectedHost: String?
    private var lastSave = Date.distantPast

    init(storageDirectory: URL? = nil, collector: URL? = nil,
         snapshot: (() -> FleetSnapshot)? = nil,
         importer: ((URL) async throws -> FleetSnapshot)? = nil,
         directoryIssue: ((URL) -> String?)? = nil) {
        collectorOverride = collector
        snapshotOverride = snapshot
        importOverride = importer
        directoryIssueOverride = directoryIssue
        let base = storageDirectory ?? ProcessInfo.processInfo.environment["KATALOG_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KataLog")
        stateURL = base.appendingPathComponent("gcs-collection.json")
        var state = GCSCollectionState(downloadDirectory: base.appendingPathComponent("Collected Logs").path)
        var loadError: String?
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                let saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: stateURL))
                guard saved.schemaVersion == 1 else { throw AnalysisError.schema(saved.schemaVersion) }
                state = saved
            } catch {
                let backup = base.appendingPathComponent("gcs-collection-unreadable-\(UUID().uuidString).json")
                try? FileManager.default.copyItem(at: stateURL, to: backup)
                loadError = "La file enregistrée n’a pas pu être ouverte. Une copie a été conservée : \(backup.lastPathComponent)."
            }
        } else {
            // Only create the app-owned initial destination. A saved/custom
            // destination may be on a disconnected volume and must never be recreated.
            do { try FileManager.default.createDirectory(atPath: state.downloadDirectory, withIntermediateDirectories: true) }
            catch { loadError = "Impossible de préparer le dossier de collecte : \(error.localizedDescription)" }
        }
        host = state.host
        allowedUUIDs = Set(state.allowedUUIDs.filter(GCSIdentity.isValid).map { $0.uppercased() })
        for i in state.queue.indices { state.queue[i].recoverAfterRelaunch() }
        currentBatchID = state.currentBatchID ?? UUID().uuidString
        for i in state.queue.indices where state.queue[i].batchID == nil { state.queue[i].batchID = currentBatchID }
        queue = state.queue
        cachedFileCount = state.cachedFileCount ?? 0
        isQueuePaused = state.queuePaused ?? false
        inventoryBusyUntil = state.inventoryBusyUntil ?? [:]
        downloadDirectory = URL(fileURLWithPath: state.downloadDirectory, isDirectory: true)
        autoImport = state.autoImport; reconnect = state.reconnect
        errorMessage = loadError
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.stopForTermination()
        }
    }

    func attach(library: LibraryStore) {
        guard self.library == nil else { return }
        self.library = library
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.objectWillChange.send() // Availability and retry countdown expire without new packets.
                self.runQueue()
            }
        }
        if reconnect && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { connect() }
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
        guard discoveryTask == nil else { return }
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 253,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]%_").contains($0) }) else {
            errorMessage = "Saisissez l’adresse de la GCS, par exemple gcs.local, sans http:// ni chemin."; return
        }
        guard let script else { errorMessage = "Le collecteur GCS est absent de l’app."; return }
        host = value; connectedHost = value; isConnecting = true; errorMessage = nil
        reconnect = true; persist()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false; self.isConnected = false; self.discoveryTask = nil }
            while !Task.isCancelled {
                do {
                    for try await event in GCSProcessService.events(script: script, arguments: ["discover", "--host", value, "--port", "1999"]) {
                        try Task.checkCancellation()
                        switch event.event {
                        case "connection":
                            self.isConnected = event.connected == true; self.isConnecting = !self.isConnected
                            if self.isConnected { self.statusMessage = "GCS connectée · surveillance des drones active"; self.errorMessage = nil }
                        case "drones":
                            let fresh = event.drones ?? []
                            var indexed = Dictionary(self.drones.map { ($0.uuid, $0) }, uniquingKeysWith: { _, b in b })
                            for var drone in fresh {
                                if let old = indexed[drone.uuid], let stamp = drone.timeUsec, old.timeUsec == stamp {
                                    drone.lastSeen = old.lastSeen
                                }
                                indexed[drone.uuid] = drone
                            }
                            self.drones = indexed.values.filter { self.allowedUUIDs.contains($0.uuid) || Date().timeIntervalSince($0.lastSeen) < 60 }
                                .sorted { $0.uuid < $1.uuid }
                            self.runQueue()
                        case "transfer_end":
                            if let uuid = event.uuid, let path = event.path {
                                for i in self.queue.indices where self.queue[i].droneUUID == uuid && self.queue[i].remoteBusyUntil != nil && !self.queue[i].isActive {
                                    let job = self.queue[i]
                                    if path == job.remotePath || (path as NSString).lastPathComponent == "\(uuid)_\(job.filename)" {
                                        self.queue[i].remoteBusyUntil = nil
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
                catch { if !Task.isCancelled { self.errorMessage = "Connexion GCS perdue : \(error.localizedDescription)" } }
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
        reconnect = false; isQueuePaused = true
        if let uuid = activeInventoryUUID { inventoryBusyUntil[uuid] = Date().addingTimeInterval(21) }
        discoveryTask?.cancel(); inventoryTask?.cancel()
        isConnected = false; isConnecting = false; connectedHost = nil
        for i in drones.indices { drones[i].lastSeen = .distantPast }
        selectedUUID = nil; files = []; selectedFileIDs = []
        statusMessage = "GCS déconnectée"; persist()
    }

    func setAllowed(uuid: String, allowed: Bool) {
        guard GCSIdentity.isValid(uuid) else { return }
        if allowed { allowedUUIDs.insert(uuid) }
        else {
            guard !queue.contains(where: { $0.droneUUID == uuid && $0.isActive }) else { return }
            allowedUUIDs.remove(uuid)
            for i in queue.indices where queue[i].droneUUID == uuid && queue[i].isPending {
                queue[i].state = "interrupted"; queue[i].error = "Drone retiré de la flotte."
            }
            if selectedUUID == uuid { inventoryTask?.cancel(); selectedUUID = nil; files = []; selectedFileIDs = [] }
        }
        persist()
    }

    func selectDrone(_ uuid: String) {
        guard allowedUUIDs.contains(uuid), !isBusy else { return }
        selectedUUID = uuid; selectedFileIDs = []; files = []
        refreshInventory()
    }

    func refreshInventory() {
        guard validateDestination(downloadDirectory) else { return }
        guard let uuid = selectedUUID, canRead(uuid), !isBusy, inventoryTask == nil else { return }
        isBusy = true; errorMessage = nil; statusMessage = "Lecture de la carte SD…"
        let currentHost = connectedHost ?? host, destination = downloadDirectory.path
        inventoryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inventoryTask = nil; self.updateBusy(); self.runQueue() }
            do {
                self.files = try await self.readInventory(uuid: uuid, host: currentHost, destination: destination)
                self.selectedFileIDs = self.selectedFileIDs.intersection(Set(self.files.filter { !$0.isDownloaded }.map(\.id)))
                self.statusMessage = "\(self.files.count) logs · \(self.files.filter(\.isDownloaded).count) déjà récupérés"
            } catch is CancellationError { self.statusMessage = "Lecture de la carte arrêtée" }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    private func readInventory(uuid: String, host: String, destination: String) async throws -> [GCSLogFile] {
        guard let script else { throw AnalysisError.unavailable("Le collecteur GCS est absent de l’app.") }
        for attempt in 1...GCSQueuePolicy.maxAttempts {
            try Task.checkCancellation()
            // A cancelled download may still be finishing on the GCS. Never overlap FTP for that drone.
            while isRemoteBusy(uuid) {
                statusMessage = "Attente de la fin du transfert déjà lancé sur la GCS…"
                try await Task.sleep(for: .seconds(1))
            }
            try requireDestination(URL(fileURLWithPath: destination, isDirectory: true))
            var retryable = true
            activeInventoryUUID = uuid
            defer { activeInventoryUUID = nil }
            do {
                var result: [GCSLogFile]?
                for try await event in GCSProcessService.events(script: script, arguments: ["inventory", "--host", host, "--port", "1999", "--uuid", uuid, "--destination", destination]) {
                    try Task.checkCancellation()
                    if event.event == "error" { retryable = event.retryable ?? true; throw AnalysisError.engine(event.message ?? "Impossible de lister les logs.") }
                    if event.event == "inventory", event.uuid == uuid { result = event.files }
                }
                guard let result else { throw AnalysisError.engine("La GCS n’a renvoyé aucun inventaire.") }
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
    func selectAllFiles() {
        let pending = Set(files.filter { !$0.isDownloaded }.map(\.id))
        selectedFileIDs = selectedFileIDs == pending ? [] : pending
    }
    private func beginBatchIfNeeded() {
        if !queue.contains(where: { $0.isPending || $0.isActive }) {
            currentBatchID = UUID().uuidString; cachedFileCount = 0; inventoryErrors = []
        }
    }
    private var currentAnalysisHashes: Set<String> {
        let snapshot = snapshotOverride?() ?? library?.snapshot ?? .empty
        return Set(snapshot.logs.lazy.filter {
            $0.status != "error" && $0.metadata["parserVersion"] == AnalysisService.parserVersion
        }.map(\.id))
    }
    @discardableResult
    private func enqueue(_ candidates: [GCSLogFile], uuid: String, host: String, destination: String) -> Int {
        var added = 0
        let analyzed = autoImport ? currentAnalysisHashes : []
        for file in candidates where !file.isDownloaded || (autoImport && !analyzed.contains(file.sha256 ?? "")) {
            if queue.contains(where: { $0.droneUUID == uuid && $0.remotePath == file.path && $0.destination == destination && $0.size == file.size && ($0.isPending || $0.isActive) }) { continue }
            var job = GCSTransfer(droneUUID: uuid, remotePath: file.path, size: file.size, host: host, destination: destination)
            job.batchID = currentBatchID
            if file.isDownloaded { job.localPath = file.localPath; job.sha256 = file.sha256 }
            if let existing = queue.lastIndex(where: { $0.droneUUID == uuid && $0.remotePath == file.path && $0.destination == destination && $0.size == file.size && !$0.isActive && !$0.isPending && transferTasks[$0.id] == nil }) {
                job.id = queue[existing].id; job.remoteBusyUntil = queue[existing].remoteBusyUntil
                queue[existing] = job
            } else { queue.append(job) }
            added += 1
        }
        return added
    }
    func enqueueSelected() {
        guard validateDestination(downloadDirectory) else { return }
        guard let uuid = selectedUUID, canRead(uuid), !isScanningFleet, !isStopping else { return }
        beginBatchIfNeeded()
        let added = enqueue(files.filter { selectedFileIDs.contains($0.id) }, uuid: uuid, host: connectedHost ?? host, destination: downloadDirectory.path)
        selectedFileIDs = []; isQueuePaused = false; statusMessage = "\(added) logs ajoutés à la collecte"
        persist(); runQueue()
    }

    func collectAll() {
        guard validateDestination(downloadDirectory) else { return }
        guard canCollectAll, let currentHost = connectedHost else { return }
        let fleet = drones.filter { allowedUUIDs.contains($0.uuid) && $0.isOnline && $0.armed != true }.map(\.uuid)
        let destination = downloadDirectory.path
        beginBatchIfNeeded(); isQueuePaused = false; isBusy = true; isScanningFleet = true; errorMessage = nil
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
                    self.cachedFileCount += items.filter(\.isDownloaded).count
                    self.enqueue(items, uuid: uuid, host: currentHost, destination: destination)
                    if self.selectedUUID == uuid { self.files = items; self.selectedFileIDs = [] }
                    self.persist()
                } catch {
                    if Task.isCancelled { return }
                    self.inventoryErrors.append("\(uuid.prefix(8))… : \(error.localizedDescription)")
                }
            }
            self.statusMessage = "\(self.batchProgress.totalCount) logs à récupérer · \(self.cachedFileCount) déjà présents"
        }
    }

    func pauseQueue() {
        isQueuePaused = true
        statusMessage = activeTransferCount > 0 ? "Pause après les fichiers en cours." : "File en pause"
        persist()
    }
    func resumeQueue() { isQueuePaused = false; persist(); runQueue() }
    func stopCollection() {
        isQueuePaused = true
        if let uuid = activeInventoryUUID { inventoryBusyUntil[uuid] = Date().addingTimeInterval(21) }
        inventoryTask?.cancel()
        for task in transferTasks.values { task.cancel() }
        for i in queue.indices where queue[i].isPending || queue[i].isActive {
            queue[i].state = "stopped"; queue[i].nextRetryAt = nil
            queue[i].error = "Arrêt demandé. Le fichier pourra être relancé ; les fichiers déjà vérifiés sont conservés."
        }
        statusMessage = "Collecte arrêtée · les transferts déjà envoyés à la GCS peuvent finir côté drone."
        persist()
    }
    func retryFailed() {
        guard !isBusy, !isScanningFleet else { return }
        let candidates = queue.indices.filter { ["failed", "interrupted", "stopped"].contains(queue[$0].state) && allowedUUIDs.contains(queue[$0].droneUUID) }
        guard !candidates.isEmpty else { return }
        beginBatchIfNeeded()
        var identities = Set(queue.filter { $0.isPending || $0.isActive }.map { "\($0.droneUUID)|\($0.remotePath)|\($0.size)|\($0.destination)" })
        for i in candidates {
            let key = "\(queue[i].droneUUID)|\(queue[i].remotePath)|\(queue[i].size)|\(queue[i].destination)"
            guard identities.insert(key).inserted else { continue }
            queue[i].state = "queued"; queue[i].error = nil; queue[i].completedBytes = 0
            queue[i].attemptCount = 0; queue[i].nextRetryAt = nil; queue[i].batchID = currentBatchID
        }
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
        guard inventoryTask == nil, !isQueuePaused, isConnected, let currentHost = connectedHost, let script else { return }
        let available = Set(drones.filter { allowedUUIDs.contains($0.uuid) && $0.isOnline && $0.armed != true && (inventoryBusyUntil[$0.uuid] ?? .distantPast) <= Date() }.map(\.uuid))
        var retargeted = false
        for index in queue.indices where queue[index].isPending && available.contains(queue[index].droneUUID) {
            if let issue = directoryIssue(URL(fileURLWithPath: queue[index].destination, isDirectory: true)) {
                queue[index].state = "failed"; queue[index].nextRetryAt = nil
                queue[index].error = issue; errorMessage = issue; retargeted = true
            } else if queue[index].host != currentHost {
                queue[index].retargetPending(to: currentHost)
                retargeted = true
            }
        }
        let jobs = GCSQueuePolicy.nextJobs(queue: queue, activeIDs: Set(transferTasks.keys), availableUUIDs: available, host: currentHost)
        for id in jobs {
            guard let index = queue.firstIndex(where: { $0.id == id }) else { continue }
            queue[index].state = "downloading"; queue[index].error = nil
            queue[index].completedBytes = 0; queue[index].attemptCount += 1; queue[index].nextRetryAt = nil
            // Reserve synchronously before a task can yield or discovery schedules more work.
            transferTasks[id] = Task { [weak self] in await self?.download(id: id, script: script) }
        }
        updateBusy()
        if retargeted || !jobs.isEmpty { persist() }
    }
    private func download(id: String, script: URL) async {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let job = queue[index]
        defer { transferTasks[id] = nil; updateBusy(); persist(); runQueue() }
        var retryable = false
        do {
            try Task.checkCancellation()
            try requireDestination(URL(fileURLWithPath: job.destination, isDirectory: true))
            retryable = true
            var downloaded = false
            let args = ["download", "--host", job.host, "--port", "1999", "--http-port", "8080", "--uuid", job.droneUUID,
                        "--remote", job.remotePath, "--size", String(job.size), "--destination", job.destination]
            for try await event in GCSProcessService.events(script: script, arguments: args) {
                try Task.checkCancellation()
                if event.event == "error" { retryable = event.retryable ?? true; throw AnalysisError.engine(event.message ?? "Échec de la collecte.") }
                guard event.uuid == job.droneUUID, event.path == job.remotePath else { continue }
                switch event.event {
                case "transfer_started":
                    queue[index].remoteBusyUntil = Date().addingTimeInterval(min(3600, max(300, event.timeoutSeconds ?? 300)) + 5)
                    persist()
                case "transfer_finished": queue[index].remoteBusyUntil = nil; persist()
                case "progress":
                    queue[index].completedBytes = min(job.size, max(queue[index].completedBytes, event.bytes ?? 0))
                    if Date().timeIntervalSince(lastSave) > 1 { persist() }
                case "downloaded":
                    guard let local = event.localPath, let hash = event.sha256, event.bytes == job.size else { throw AnalysisError.engine("Réponse de téléchargement incomplète.") }
                    queue[index].localPath = local; queue[index].sha256 = hash
                    queue[index].completedBytes = job.size; downloaded = true
                default: break
                }
            }
            try Task.checkCancellation()
            guard downloaded else { throw AnalysisError.engine("Aucun fichier complet reçu.") }
            queue[index].state = "downloaded"; persist()
            // Import errors should not automatically retry a network download which already succeeded.
            retryable = false
            if autoImport, let local = queue[index].localPath {
                queue[index].state = "importing"; persist()
                let folder = URL(fileURLWithPath: local).deletingLastPathComponent()
                let result: FleetSnapshot
                if let importOverride { result = try await importOverride(folder) }
                else if let library { result = try await library.importCollectedFolder(folder) }
                else { throw AnalysisError.unavailable("La bibliothèque doit être ouverte pour analyser le fichier collecté.") }
                try Task.checkCancellation()
                guard let log = result.logs.first(where: { $0.id == queue[index].sha256 }), log.status != "error" else {
                    throw AnalysisError.engine("Le fichier a été téléchargé, mais sa lecture ULog a échoué. Voir la bibliothèque.")
                }
                queue[index].state = "complete"
                if log.status == "partial" { queue[index].error = "Analyse partielle : consultez la couverture du log." }
            }
            if selectedUUID == job.droneUUID, let f = files.firstIndex(where: { $0.path == job.remotePath }) { files[f].isDownloaded = true }
            statusMessage = autoImport ? "\(job.filename) récupéré et analysé" : "\(job.filename) récupéré"
        } catch {
            if Task.isCancelled {
                if queue[index].state != "stopped" { queue[index].state = "interrupted"; queue[index].error = "Collecte interrompue. Relancez le fichier pour reprendre." }
            } else if retryable, let date = GCSQueuePolicy.retryDate(attempt: queue[index].attemptCount) {
                queue[index].state = "retrying"
                queue[index].nextRetryAt = max(date, queue[index].remoteBusyUntil ?? .distantPast)
                queue[index].error = "\(error.localizedDescription) · nouvelle tentative \(queue[index].attemptCount + 1)/3"
            } else {
                queue[index].state = "failed"; queue[index].error = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseDownloadDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "Choisir"; panel.title = "Dossier de collecte"
        if panel.runModal() == .OK, let url = panel.url {
            do { try setDownloadDirectory(url) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func setDownloadDirectory(_ url: URL) throws {
        guard !isBusy else { throw AnalysisError.unavailable("Arrêtez la collecte en cours avant de changer de dossier.") }
        let destination = url.standardizedFileURL
        try requireDestination(destination)
        let previous = downloadDirectory
        downloadDirectory = destination
        do { try saveState() }
        catch { downloadDirectory = previous; throw error }
        errorMessage = nil
        statusMessage = "Dossier de collecte enregistré. Les fichiers déjà en file conservent leur destination."
    }
    func revealDownloads() {
        guard validateDestination(downloadDirectory) else { return }
        NSWorkspace.shared.open(downloadDirectory)
    }
    private func directoryIssue(_ url: URL) -> String? {
        if let directoryIssueOverride { return directoryIssueOverride(url) }
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
    private func requireDestination(_ url: URL) throws {
        if let issue = directoryIssue(url) { throw AnalysisError.unavailable(issue) }
    }
    private func validateDestination(_ url: URL) -> Bool {
        do { try requireDestination(url); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    private func saveState() throws {
        var state = GCSCollectionState(downloadDirectory: downloadDirectory.path)
        state.host = host; state.allowedUUIDs = allowedUUIDs; state.autoImport = autoImport
        state.reconnect = reconnect; state.queue = queue
        state.currentBatchID = currentBatchID; state.cachedFileCount = cachedFileCount; state.queuePaused = isQueuePaused; state.inventoryBusyUntil = inventoryBusyUntil
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic); lastSave = Date()
    }
    private func persist() {
        do { try saveState() }
        catch { errorMessage = "Impossible d’enregistrer la file de collecte : \(error.localizedDescription)" }
    }
    private func stopForTermination() {
        isQueuePaused = true
        if let uuid = activeInventoryUUID { inventoryBusyUntil[uuid] = Date().addingTimeInterval(21) }
        discoveryTask?.cancel(); inventoryTask?.cancel(); refreshTask?.cancel()
        for task in transferTasks.values { task.cancel() }
        for i in queue.indices { queue[i].recoverAfterRelaunch() }
        persist()
    }
}
