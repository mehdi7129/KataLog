import Combine
import Foundation
import KataLogCore

private actor USBProcessExit {
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    func finish() { finished = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// A physical USB connection has one owner. Jobs retain the hardware identity,
/// never the reusable serial port. The helper revalidates identity per job.
@MainActor
final class USBCollectionStore: ObservableObject {
    @Published private(set) var ports: [USBSerialPort] = []
    @Published var port = ""
    @Published var baud = 115200
    @Published private(set) var device: USBLogDevice?
    @Published private(set) var logs: [USBLogEntry] = []
    @Published var selection: Set<Int> = []
    @Published private(set) var queue: [USBLogTransfer] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isReadingInventory = false
    @Published private(set) var isPaused = false
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private let stateURL: URL
    private let collectorOverride: URL?
    private weak var library: LibraryStore?
    private var destination: (() -> URL?)?
    private var autoImport: (() -> Bool)?
    private var clientID: (() -> String)?
    private var admissionBlocked: () -> Bool = { false }
    private var storageError: String?
    private var inventoryPort: String?
    private var inventoryBaud: Int?

    var mutationsBlocked: Bool { library?.isReadOnly == true || library?.isMaintainingLibrary == true || library?.isStartupBlocked == true || admissionBlocked() || storageError != nil }
    var hasCurrentInventory: Bool { device != nil && inventoryPort == port && inventoryBaud == baud }
    var canAdd: Bool { !mutationsBlocked && hasCurrentInventory && !selection.isEmpty && !isReadingInventory }
    var pendingCount: Int { queue.filter { $0.state == "queued" }.count }

    init(stateDirectory: URL, collector: URL? = nil) {
        stateURL = stateDirectory.appendingPathComponent("usb-collection.json")
        collectorOverride = collector
        do { try load() } catch { storageError = error.localizedDescription; errorMessage = storageError }
    }

    func attach(library: LibraryStore, destination: @escaping () -> URL?, autoImport: @escaping () -> Bool,
                clientID: @escaping () -> String = { "" }, admissionBlocked: @escaping () -> Bool = { false }) {
        self.library = library; self.destination = destination; self.autoImport = autoImport
        self.clientID = clientID; self.admissionBlocked = admissionBlocked
    }

    private var script: URL? {
        if let collectorOverride { return collectorOverride }
        if let url = Bundle.main.url(forResource: "usb_collect", withExtension: "py") { return url }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "usb_collect", withExtension: "py", subdirectory: "Resources")
        #else
        return nil
        #endif
    }

    private func consume(_ arguments: [String], receive: (GCSCollectorEvent) throws -> Void) async throws {
        guard let script else { throw AnalysisError.unavailable("Le collecteur USB est absent du moteur.") }
        let exit = USBProcessExit()
        do {
            for try await event in GCSProcessService.events(script: script, arguments: arguments,
                writerLibrary: library?.storageDirectory, onProcessExit: { Task { await exit.finish() } }) {
                try Task.checkCancellation()
                if event.event == "error" { throw AnalysisError.engine(event.message ?? "Échec de la collecte USB.") }
                try receive(event)
            }
            await exit.wait()
            try Task.checkCancellation()
        } catch {
            // Cancellation of AsyncStream can return before SIGTERM has closed
            // the descriptor. Keep the UI/maintenance gate until actual exit.
            await exit.wait()
            throw error
        }
    }

    func refreshPorts() {
        guard !isBusy, !mutationsBlocked else { return }
        isBusy = true; isReadingInventory = true; errorMessage = nil
        task = Task {
            defer { task = nil; isBusy = false; isReadingInventory = false }
            do {
                var found: [USBSerialPort]?
                try await consume(["ports"]) { event in if event.event == "ports" { found = event.ports } }
                guard let found else { throw AnalysisError.engine("Liste des ports USB absente.") }
                ports = found
                if !ports.contains(where: { $0.path == port }) { port = ports.first?.path ?? ""; invalidateInventory() }
                message = ports.isEmpty ? "Aucun port serial détecté. Branchez le drone puis actualisez." : "Sélectionnez le port du drone, puis lisez ses logs."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func invalidateInventory() { device = nil; logs = []; selection = []; inventoryPort = nil; inventoryBaud = nil }

    func readInventory() {
        guard !isBusy, !mutationsBlocked, !port.isEmpty else { return }
        let selectedPort = port, selectedBaud = baud
        invalidateInventory(); isBusy = true; isReadingInventory = true; errorMessage = nil; message = "Identification du drone USB et lecture des logs…"
        task = Task {
            defer { task = nil; isBusy = false; isReadingInventory = false }
            do {
                var foundDevice: USBLogDevice?, foundLogs: [USBLogEntry]?
                try await consume(["inventory", "--device", selectedPort, "--baud", String(selectedBaud)]) { event in
                    if event.event == "usb_inventory" { foundDevice = event.device; foundLogs = event.logs }
                }
                guard let foundDevice, let foundLogs,
                      !foundDevice.identity.isEmpty, foundLogs.count <= 100_000,
                      Set(foundLogs.map(\.id)).count == foundLogs.count,
                      foundLogs.allSatisfy({ (0...65535).contains($0.id) && $0.size >= 0 && $0.timeUTC >= 0 }) else {
                    throw AnalysisError.engine("Inventaire USB incomplet ou invalide.")
                }
                device = foundDevice; logs = foundLogs; inventoryPort = selectedPort; inventoryBaud = selectedBaud
                message = "\(foundLogs.count) logs · appareil identifié. Ajoutez les fichiers souhaités à la file."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func enqueueSelected() {
        guard canAdd, let device, let folder = destination?() else { return }
        var added = 0
        for log in logs where selection.contains(log.id) {
            if queue.contains(where: { $0.device.identity == device.identity && $0.log == log && $0.destination == folder.path }) { continue }
            queue.append(USBLogTransfer(device: device, log: log, destination: folder.path, clientID: clientID?() ?? "")); added += 1
        }
        selection = []
        guard persist() else { return }
        message = "\(added) logs ajoutés à la file USB."
        runQueue()
    }

    func pause() { isPaused = true; message = "Pause après le fichier en cours. Vous pouvez préparer les sélections suivantes." }

    func resume() {
        guard !isBusy, !mutationsBlocked, hasCurrentInventory, let device else { return }
        for index in queue.indices where queue[index].device.identity == device.identity && ["failed", "interrupted"].contains(queue[index].state) {
            queue[index].state = "queued"; queue[index].error = nil
        }
        isPaused = false
        guard persist() else { return }
        runQueue()
    }

    func stop() {
        isPaused = true
        task?.cancel()
        message = "Arrêt demandé. Les demandes restent dans la file ; la reprise sera explicite."
    }

    func waitUntilIdle() async { await task?.value }

    func removeClientAttribution(_ id: String) throws {
        guard !isBusy else { throw AnalysisError.engine("Arrêtez la collecte USB avant de supprimer ce client.") }
        for index in queue.indices where queue[index].clientID == id { queue[index].clientID = "" }
        if !queue.isEmpty { try save() }
    }

    func reconcileClientAttributions(validIDs: Set<String>) throws {
        guard !isBusy else { throw AnalysisError.engine("Attendez la fin de la collecte USB avant de recharger les clients.") }
        for index in queue.indices {
            if let id = queue[index].clientID, !id.isEmpty, !validIDs.contains(id) { queue[index].clientID = "" }
        }
        if !queue.isEmpty { try save() }
    }

    private func runQueue() {
        guard !isBusy, !isPaused, !mutationsBlocked, hasCurrentInventory, let device else { return }
        guard let index = queue.firstIndex(where: { $0.device.identity == device.identity && $0.state == "queued" }) else {
            if queue.contains(where: { $0.state == "queued" && $0.device.identity != device.identity }) {
                isPaused = true
                message = "Cet appareil est terminé. Branchez le suivant, lisez ses logs puis reprenez sa file."
            }
            return
        }
        let job = queue[index], selectedPort = port, selectedBaud = baud
        queue[index].state = "downloading"; queue[index].bytes = 0; queue[index].error = nil
        guard persist() else { queue[index].state = "interrupted"; return }
        isBusy = true
        task = Task {
            defer { task = nil; isBusy = false; if persist() { runQueue() } }
            do {
                var received = false
                let args = ["download", "--device", selectedPort, "--baud", String(selectedBaud),
                            "--identity", job.device.identity, "--log-id", String(job.log.id),
                            "--time-utc", String(job.log.timeUTC), "--size", String(job.log.size), "--destination", job.destination]
                try await consume(args) { event in
                    if event.event == "progress" { queue[index].bytes = min(job.log.size, max(queue[index].bytes, event.bytes ?? 0)) }
                    if event.event == "downloaded" {
                        guard event.bytes == job.log.size, let path = event.localPath, let hash = event.sha256,
                              hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
                              URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: job.destination).standardizedFileURL.path + "/") else {
                            throw AnalysisError.engine("Confirmation USB incomplète.")
                        }
                        received = true; queue[index].localPath = path; queue[index].sha256 = hash; queue[index].bytes = job.log.size
                    }
                }
                guard received else { throw AnalysisError.engine("Aucun fichier USB complet reçu.") }
                queue[index].state = "downloaded"
                guard persist() else { return }
                if autoImport?() == true, let path = queue[index].localPath, let hash = queue[index].sha256 {
                    guard let library else { throw AnalysisError.unavailable("Ouvrez la bibliothèque pour analyser ce log.") }
                    queue[index].state = "importing"
                    let result = try await library.importCollectedFolder(URL(fileURLWithPath: path), expectedLogID: hash, clientID: job.clientID ?? "")
                    try Task.checkCancellation()
                    guard let log = result.logs.first(where: { $0.id == hash }), log.status != "error",
                          log.metadata["parserVersion"] == AnalysisService.parserVersion else {
                        throw AnalysisError.engine("Copie USB conservée, mais analyse ULog en échec.")
                    }
                    queue[index].state = "complete"
                }
                message = "\(job.log.filename) récupéré et vérifié."
            } catch {
                queue[index].state = Task.isCancelled ? "interrupted" : "failed"
                queue[index].error = error.localizedDescription; errorMessage = error.localizedDescription
                // Explicit retry after unplug/identity errors. Do not spend other
                // queued requests on a port which may now belong to another boat.
                isPaused = true
            }
        }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { queue = []; return }
        let data = try Data(contentsOf: stateURL)
        let saved = try JSONDecoder().decode(USBCollectionState.self, from: data)
        guard saved.schemaVersion == 1, Set(saved.queue.map(\.id)).count == saved.queue.count else { throw AnalysisError.engine("File USB incompatible ou endommagée.") }
        queue = saved.queue
        for index in queue.indices where queue[index].isActive { queue[index].state = "interrupted" }
        isPaused = true
    }

    private func save(duringMaintenance: Bool = false) throws {
        if let storageError { throw AnalysisError.engine(storageError) }
        // Admission closes before the owning library asks us to drain. Saving
        // an already admitted, now idle queue must remain possible under that
        // gate; read-only, startup and damaged storage never permit a write.
        guard library?.isReadOnly != true, library?.isStartupBlocked != true,
              duringMaintenance || !mutationsBlocked else {
            throw AnalysisError.engine("Bibliothèque occupée ou en lecture seule.")
        }
        var saved = USBCollectionState(); saved.queue = queue
        // The library owns this directory. Never recreate a disconnected root.
        try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
    }

    @discardableResult private func persist() -> Bool {
        do { try save(); return true }
        catch { errorMessage = "File USB non enregistrée : \(error.localizedDescription)"; isPaused = true; return false }
    }

    func flushForMaintenance() throws {
        guard !isBusy else { throw AnalysisError.engine("Arrêtez la collecte USB avant cette opération.") }
        if !queue.isEmpty || FileManager.default.fileExists(atPath: stateURL.path) { try save(duringMaintenance: true) }
    }

    func reloadAfterRestore() throws {
        guard !isBusy else { throw AnalysisError.engine("La collecte USB est encore active.") }
        invalidateInventory(); storageError = nil; isPaused = true
        do { try load() } catch { storageError = error.localizedDescription; errorMessage = storageError; throw error }
    }
}
