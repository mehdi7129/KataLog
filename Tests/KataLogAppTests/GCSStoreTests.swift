import XCTest
import Combine
import Darwin
import AppKit
import SwiftUI
import KataLogCore
@testable import KataLog

@MainActor
final class GCSStoreTests: XCTestCase {
    let first = "0102030405060708090A0B0C"
    let second = "1112131415161718191A1B1C"

    private func planningStore(identities: [String]) throws -> (GCSStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-enqueue-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "synthetic-gcs.local"; state.allowedUUIDs = Set(identities)
        state.autoImport = false; state.reconnect = false
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-settings.json"))
        return (GCSStore(storageDirectory: root), root)
    }

    func testQueuePlannerKeepsOneJobPerSourceAcrossFiveHundredIdentities() async throws {
        let identities = (1...500).map { String(format: "%024llX", UInt64($0)) }
        let (store, root) = try planningStore(identities: identities)
        let candidates = (0..<100).map { GCSLogFile(path: "/fs/microsd/log/2026-01-01/\($0).ulg", size: 1_024) }
        var timings: [Double] = [], gaps: [Double] = []
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime; gaps.append(now - previous); previous = now
            }
        }
        defer { heartbeat.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        for uuid in identities {
            let before = ProcessInfo.processInfo.systemUptime
            let added = try await store.enqueue(candidates, uuid: uuid, host: "synthetic-gcs.local", destination: root.path)
            timings.append(ProcessInfo.processInfo.systemUptime - before)
            XCTAssertEqual(added, 100)
        }
        let constructionSeconds = ProcessInfo.processInfo.systemUptime - start
        heartbeat.cancel(); await heartbeat.value
        XCTAssertEqual(store.queue.count, 50_000)
        XCTAssertEqual(Set(store.queue.map(\.id)).count, 50_000)
        XCTAssertEqual(Set(store.queue.map { "\($0.droneUUID)|\($0.remotePath)|\($0.size)|\($0.destination)" }).count, 50_000)
        for uuid in identities.suffix(10) {
            let added = try await store.enqueue(candidates + candidates, uuid: uuid, host: "synthetic-gcs.local", destination: root.path)
            XCTAssertEqual(added, 0, "Repeated inventories must not add duplicate pending jobs.")
        }
        XCTAssertEqual(store.queue.count, 50_000)
        XCTAssertLessThan(gaps.max() ?? 0, 0.5, "Preparing jobs must continue to yield the UI actor.")
        let retainedIDs = Set(store.queue.map(\.id))
        // Measure persistence independently from actor preparation. The repository
        // is thread-safe; this bulk proof does not claim that every UI write path
        // has been moved off the actor or that a physical fleet was exercised.
        let transfers = store.queue, database = root.appendingPathComponent("proof-queue.sqlite")
        let persisted = try await Task.detached {
            let before = ProcessInfo.processInfo.systemUptime
            let repository = try GCSQueueRepository(url: database)
            try repository.migrateLegacy([])
            let writes = try repository.saveTransfers(transfers)
            let unchangedWrites = try repository.saveTransfers(transfers)
            return (writes, unchangedWrites, ProcessInfo.processInfo.systemUptime - before, try repository.retainedTransfers())
        }.value
        XCTAssertEqual(persisted.0, 50_000)
        XCTAssertEqual(persisted.1, 0)
        XCTAssertEqual(Set(persisted.3.map(\.id)), retainedIDs)
        let bytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber).int64Value
        let settingsBytes = try Data(contentsOf: root.appendingPathComponent("gcs-settings.json")).count
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        if let artifacts = ProcessInfo.processInfo.environment["KATALOG_GCS_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: artifacts); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sorted = timings.sorted()
            let proof: [String: Any] = ["identities": 500, "jobs": 50_000, "logsPerIdentity": 100,
                "constructionSeconds": constructionSeconds, "enqueueP50Ms": sorted[sorted.count / 2] * 1_000,
                "enqueueP95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)] * 1_000,
                "maximumActorHeartbeatGapMs": (gaps.max() ?? 0) * 1_000,
                "bulkRepositorySeconds": persisted.2, "firstRepositoryWrites": persisted.0,
                "unchangedRepositoryWrites": persisted.1, "databaseBytes": bytes,
                "settingsBytes": settingsBytes, "runnerPeakRSSBytes": usage.ru_maxrss,
                "physicalFleetQualified": false, "networkRequests": 0,
                "scope": "Immutable enqueue preparation plus live actor commit; standalone bulk repository write, not a live GCS or overall startup benchmark."]
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("gcs-enqueue-500x100.json"))
        }
    }

    func testQueuePlannerCancellationAndStaleDestinationCannotPublishJobs() async throws {
        let (store, root) = try planningStore(identities: [first])
        let candidates = (0..<1_000).map { GCSLogFile(path: "/fs/microsd/log/2026-01-01/\($0).ulg", size: 64) }
        let cancelled = Task { try await store.enqueue(candidates, uuid: first, host: "synthetic-gcs.local", destination: root.path) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled preparation must not publish jobs.") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertTrue(store.queue.isEmpty)
        let stale = Task { try await store.enqueue(candidates, uuid: first, host: "synthetic-gcs.local", destination: root.path) }
        store.host = "replacement-gcs.local"
        do { _ = try await stale.value; XCTFail("A stale GCS inventory must not publish jobs for a changed endpoint.") } catch { XCTAssertTrue(error.localizedDescription.contains("collecte a changé")) }
        XCTAssertTrue(store.queue.isEmpty)
    }

    func waitUntil(timeout: Double = 12, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(predicate(), "Timed out waiting for collection state")
    }

    func testAttachWithoutEndpointNeverStartsDiscoveryOrShowsConnectionError() async throws {
        // Check both a fresh install and a saved blank endpoint with reconnect enabled.
        for restored in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-empty-endpoint-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("collector.py")
            try "import pathlib\n(pathlib.Path(__file__).parent/'started').write_text('unexpected')\n".write(to: script, atomically: true, encoding: .utf8)
            if restored {
                var state = GCSCollectionState(downloadDirectory: root.path)
                state.host = "  \n"; state.reconnect = true
                try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-collection.json"))
            }
            let store = GCSStore(storageDirectory: root, collector: script)
            store.attach(library: LibraryStore(storageDirectory: root.appendingPathComponent("library")))
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(store.isConnecting)
            XCTAssertFalse(store.isConnected)
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        }
    }

    func testAttachWithSavedEndpointPreservesAutoReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-saved-endpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("collector.py")
        // The fixture emits events only; it never opens a network connection.
        try #"""
import json,pathlib,sys,time
(pathlib.Path(__file__).parent/'started').write_text(json.dumps(sys.argv))
print(json.dumps(dict(event='connection',connected=True)),flush=True)
time.sleep(30)
"""#.write(to: script, atomically: true, encoding: .utf8)
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "localhost"; state.reconnect = true; state.allowedUUIDs = [first]
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-collection.json"))
        let store = GCSStore(storageDirectory: root, collector: script)
        defer { store.disconnect(); try? FileManager.default.removeItem(at: root) }
        store.attach(library: LibraryStore(storageDirectory: root.appendingPathComponent("library")))
        try await waitUntil(timeout: 3) { store.isConnected }
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("started")))
        XCTAssertEqual(arguments.dropFirst(), ["discover", "--host", "localhost", "--port", "1999"])
        let persisted = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-collection.json")))
        XCTAssertEqual(persisted.host, "localhost")
        XCTAssertTrue(persisted.reconnect)
        XCTAssertEqual(persisted.allowedUUIDs, [first])
    }

    func fixture(mode: String, snapshot: (() -> FleetSnapshot)? = nil,
                 importer: ((URL) async throws -> FleetSnapshot)? = nil,
                 initialState: GCSCollectionState? = nil, configure: Bool = true,
                 stateBuilder: ((URL) -> GCSCollectionState)? = nil) throws -> (GCSStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("collector.py")
        try #"""
import json,sys,time,pathlib,hashlib,os
root=pathlib.Path(__file__).parent
mode=(root/'mode').read_text()
cmd=sys.argv[1]
def arg(name): return sys.argv[sys.argv.index(name)+1]
def emit(event,**kw): print(json.dumps(dict(event=event,**kw)),flush=True)
ids=['0102030405060708090A0B0C','1112131415161718191A1B1C']
if cmd=='discover':
    emit('connection',connected=True)
    while True:
        visible=ids[1:] if mode=='offline' else (ids+[ids[0]] if mode=='duplicate' else ids)
        if mode=='invalid-uuid': visible=['not-a-drone-uuid']
        emit('drones',drones=[dict(uuid=u,time_usec=time.time()*1e6,arming_state=2 if mode=='armed' and u==ids[0] else 1) for u in visible]);time.sleep(.15)
u=arg('--uuid')
paths=['/fs/microsd/log/2026-09-01/a.ulg','/fs/microsd/log/2026-09-01/b.ulg']
if cmd=='inventory':
    if mode=='inventory-error' and u==ids[1]:
        emit('error',message='simulated missing inventory',retryable=False);sys.exit(1)
    files=[]
    for p in paths:
        local=root/(u+pathlib.Path(p).name+'.cache')
        item=dict(path=p,size=64,isDownloaded=local.exists())
        if local.exists(): item.update(localPath=str(local),sha256=hashlib.sha256(local.read_bytes()).hexdigest())
        files.append(item)
    if mode=='empty-inventory': files=[]
    if mode.startswith('paged'):
        emit('inventory_started',uuid=u,inventoryID='fixture',totalFiles=len(files))
        emit('inventory_page',uuid=u,inventoryID='fixture',pageIndex=1 if mode=='paged-invalid' else 0,files=files[:1])
        emit('inventory_page',uuid=u,inventoryID='fixture',pageIndex=1,files=files[1:])
        if mode!='paged-incomplete': emit('inventory_finished',uuid=u,inventoryID='fixture',totalFiles=len(files),pageCount=2)
    else: emit('inventory',uuid=u,files=files)
else:
    p=arg('--remote');key=u+pathlib.Path(p).name
    local=root/(key+'.cache')
    if local.exists():
        emit('downloaded',uuid=u,path=p,bytes=64,localPath=str(local),sha256=hashlib.sha256(local.read_bytes()).hexdigest(),cached=True)
        sys.exit(0)
    count=root/(key+'.attempt');attempt=int(count.read_text())+1 if count.exists() else 1;count.write_text(str(attempt))
    fd=os.open(root/'trace.jsonl',os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
    os.write(fd,(json.dumps(dict(uuid=u,path=p,attempt=attempt,time=time.time(),host=arg('--host'),destination=arg('--destination')))+'\n').encode());os.close(fd)
    emit('transfer_started',uuid=u,path=p,timeoutSeconds=300)
    emit('progress',uuid=u,path=p,bytes=64 if mode=='phases' else 16,total=64,phase='drone')
    time.sleep(2 if mode=='stop' else .6)
    emit('transfer_finished',uuid=u,path=p)
    emit('phase',uuid=u,path=p,bytes=0,total=64,phase='http')
    emit('progress',uuid=u,path=p,bytes=8,total=64,phase='http')
    if mode=='phases': time.sleep(1.5)
    if mode=='retry' and u==ids[0] and p==paths[0] and attempt==1:
        emit('error',message='simulated transient timeout',retryable=True);sys.exit(1)
    if mode=='permanent':
        emit('error',message='simulated invalid destination',retryable=False);sys.exit(1)
    local.write_bytes(key.encode().ljust(64,b'x'))
    emit('progress',uuid=u,path=p,bytes=64,total=64,phase='http')
    emit('phase',uuid=u,path=p,bytes=64,total=64,phase='verification')
    emit('downloaded',uuid=u,path=p,bytes=64,localPath=str(local),sha256=hashlib.sha256(local.read_bytes()).hexdigest())
"""#.write(to: script, atomically: true, encoding: .utf8)
        if var initialState = initialState ?? stateBuilder?(root) {
            initialState.downloadDirectory = root.path
            try JSONEncoder().encode(initialState).write(to: root.appendingPathComponent("gcs-collection.json"))
        }
        let store = GCSStore(storageDirectory: root, collector: script, snapshot: snapshot, importer: importer)
        if configure {
            store.autoImport = false; store.host = "localhost"
            store.setAllowed(uuid: first, allowed: true); store.setAllowed(uuid: second, allowed: true)
            store.connect()
        }
        return (store, root)
    }

    func testBulkCollectionRegistersAllNewDronesAndSurvivesRestartWithoutDuplicates() async throws {
        let (store, root) = try fixture(mode: "normal", configure: false)
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        store.autoImport = false; store.host = "localhost"; store.connect()
        try await waitUntil { store.canCollectAll }
        XCTAssertTrue(store.allowedUUIDs.isEmpty, "Discovery alone must not register a device.")
        XCTAssertEqual(store.newCollectableDroneCount, 2)
        store.collectAll()
        XCTAssertEqual(store.allowedUUIDs, [first, second], "Admission must be committed synchronously before collecting.")
        let settings = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertEqual(settings.allowedUUIDs, [first, second])
        let registered = try JSONDecoder().decode(GCSFleetObservationState.self, from: Data(contentsOf: root.appendingPathComponent("fleet.json")))
        XCTAssertEqual(Set(registered.drones.map(\.uuid)), [first, second])
        XCTAssertTrue(registered.drones.allSatisfy { $0.authorized && $0.lastSeenSource == "gcs-telemetry" && $0.lastSeenAtUTC != nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("annotations.json").path), "No stock number is invented.")
        try await waitUntil { !store.isBusy && store.batchProgress.completedCount == 4 }
        let requests = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertEqual(requests.split(separator: "\n").count, 4)
        store.collectAll()
        try await waitUntil { !store.isBusy && store.cachedFileCount == 4 }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8), requests)
        XCTAssertEqual(store.newCollectableDroneCount, 0)
        let reloaded = GCSStore(storageDirectory: root)
        XCTAssertEqual(reloaded.allowedUUIDs, [first, second])
        XCTAssertEqual(reloaded.queue.count, 4)
        let fleet = GCSFleetObservationStore(file: root.appendingPathComponent("fleet.json"), canMutate: { true })
        XCTAssertEqual(fleet.state.drones.count, 2)
    }

    func testConnectedCollectionFitsMinimumContentWidthBeforeAndAfterEnrollment() async throws {
        let (store, root) = try fixture(mode: "empty-inventory", configure: false)
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(storageDirectory: root)
        store.autoImport = false; store.host = "localhost"; store.connect()
        try await waitUntil { store.canCollectAll }
        _ = NSApplication.shared
        for registered in [false, true] {
            if registered {
                store.collectAll()
                try await waitUntil { !store.isBusy && store.completedInventoryUUIDs.count == 2 }
            }
            for scheme in [ColorScheme.dark, .light] {
                let content = ScrollView {
                    GCSCollectionView(store: store, library: library, dark: scheme == .dark).padding(20)
                }
                .environment(\.colorScheme, scheme).preferredColorScheme(scheme)
                .background(Color(nsColor: .windowBackgroundColor))
                let controller = NSHostingController(rootView: content)
                let view = controller.view
                view.frame = NSRect(x: 0, y: 0, width: 660, height: 1_800)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.isReleasedWhenClosed = false; window.contentViewController = controller
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                view.layoutSubtreeIfNeeded()
                let fitting = controller.sizeThatFits(in: CGSize(width: 660, height: 1_800))
                XCTAssertLessThanOrEqual(fitting.width, 660.5, "The connected collection must fit the workspace's minimum content width.")
                if let output = ProcessInfo.processInfo.environment["KATALOG_UI_ARTIFACTS"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("gcs-connected-\(registered ? "registered" : "new")-\(scheme).png"))
                }
            }
        }
    }

    func testBulkCollectionCombinesRegisteredAndNewDronesEvenWithNoLogs() async throws {
        let (store, root) = try fixture(mode: "empty-inventory", configure: false)
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        store.autoImport = false; store.host = "localhost"; store.setAllowed(uuid: first, allowed: true); store.connect()
        try await waitUntil { store.canCollectAll }
        XCTAssertEqual(store.newCollectableDroneCount, 1)
        store.collectAll()
        try await waitUntil { !store.isBusy && store.completedInventoryUUIDs.count == 2 }
        XCTAssertEqual(store.allowedUUIDs, [first, second])
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertFalse(store.hasIncompleteInventory)
        XCTAssertEqual(store.batchStatusMessage, "Aucun log disponible · inventaire terminé sur 2 drones.")
        let fleet = GCSFleetObservationStore(file: root.appendingPathComponent("fleet.json"), canMutate: { true })
        XCTAssertEqual(Set(fleet.state.drones.filter(\.authorized).map(\.uuid)), [first, second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
    }

    func testBulkAdmissionExcludesArmedAndUnseenDevicesAndDeduplicatesTelemetry() async throws {
        for mode in ["armed", "offline", "duplicate"] {
            let (store, root) = try fixture(mode: mode, configure: false)
            defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
            store.autoImport = false; store.host = "localhost"; store.connect()
            try await waitUntil { store.canCollectAll }
            let expected: Set<String> = mode == "duplicate" ? [first, second] : [second]
            store.collectAll()
            XCTAssertEqual(store.allowedUUIDs, expected)
            try await waitUntil { !store.isBusy && store.batchProgress.completedCount == expected.count * 2 }
            XCTAssertEqual(Set(store.queue.map(\.droneUUID)), expected)
            XCTAssertEqual(store.queue.count, expected.count * 2)
            XCTAssertEqual(store.expectedInventoryUUIDs, expected)
        }
    }

    func testBulkAdmissionRefusesInvalidDiscoveryUUIDs() async throws {
        let (store, root) = try fixture(mode: "invalid-uuid", configure: false)
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        store.autoImport = false; store.host = "localhost"; store.connect()
        try await waitUntil { store.errorMessage != nil }
        store.collectAll()
        XCTAssertFalse(store.canCollectAll)
        XCTAssertTrue(store.allowedUUIDs.isEmpty)
        XCTAssertTrue(store.queue.isEmpty)
    }

    func testBulkAdmissionDoesNotDownloadWhenSettingsCannotBeSaved() async throws {
        let (store, root) = try fixture(mode: "normal", configure: false)
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        store.autoImport = false; store.host = "localhost"; store.connect()
        try await waitUntil { store.canCollectAll }
        let settings = root.appendingPathComponent("gcs-settings.json")
        let original = try Data(contentsOf: settings)
        try FileManager.default.moveItem(at: settings, to: root.appendingPathComponent("saved-settings.json"))
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        store.collectAll()
        XCTAssertTrue(store.errorMessage?.contains("Collecte non démarrée") == true)
        XCTAssertTrue(store.allowedUUIDs.isEmpty)
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fleet.json").path), "Failed settings must roll back the new fleet registration.")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("saved-settings.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
    }

    func testBulkAdmissionPreservesUnreadableRegistryAndRefusesToStart() async throws {
        let (store, root) = try fixture(mode: "normal", configure: false)
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fleet.json")
        let future = Data(#"{"schemaVersion":2,"revision":0,"drones":[]}"#.utf8)
        try future.write(to: file)
        store.autoImport = false; store.host = "localhost"; store.connect()
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        XCTAssertTrue(store.errorMessage?.contains("Collecte non démarrée") == true)
        XCTAssertTrue(store.allowedUUIDs.isEmpty)
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(try Data(contentsOf: file), future)
        let saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertTrue(saved.allowedUUIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
    }

    func testCollectAllRunsTwoDronesRetriesAndSkipsVerifiedCache() async throws {
        let (store, root) = try fixture(mode: "retry")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        var observedFailures: [String: GCSTransfer] = [:]
        // Capture errors when they are published, before a later retry clears
        // them. Timeout-only snapshots cannot diagnose an earlier attempt.
        let failures = store.$queue.sink { transfers in
            for transfer in transfers {
                guard let error = transfer.error else { continue }
                observedFailures["\(transfer.id):\(transfer.attemptCount):\(error)"] = transfer
            }
        }
        defer { failures.cancel() }
        func recordFailureState(_ phase: String) {
            do {
                let queue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.queue))
                let failures = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(observedFailures.values)))
                let freeBytes = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
                let proof: [String: Any] = ["phase": phase, "queue": queue, "observedFailures": failures,
                    "connected": store.isConnected, "busy": store.isBusy,
                    "status": store.statusMessage ?? "", "error": store.errorMessage ?? "",
                    "freeBytes": freeBytes?.int64Value ?? -1,
                    "trace": (try? String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8)) ?? ""]
                let data = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
                print("GCS retry failure state: " + String(decoding: data, as: UTF8.self))
                if let artifacts = ProcessInfo.processInfo.environment["KATALOG_GCS_ARTIFACTS"] {
                    let directory = URL(fileURLWithPath: artifacts)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent("retry-\(root.lastPathComponent)-\(phase).json"))
                }
            } catch { print("GCS retry failure diagnostics unavailable: \(error.localizedDescription)") }
        }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { store.activeTransferCount == 2 }
        XCTAssertEqual(Set(store.queue.filter(\.isActive).map(\.droneUUID)).count, 2)
        try await waitUntil { store.queue.count == 4 && store.queue.allSatisfy(\.isSuccessful) && !store.isBusy }
        if store.queue.count != 4 || !store.queue.allSatisfy(\.isSuccessful) || store.isBusy { recordFailureState("copy") }
        XCTAssertEqual(store.queue.first { $0.droneUUID == first && $0.filename == "a.ulg" }?.attemptCount, 2)
        XCTAssertEqual(store.batchProgress.completedCount, 4)
        XCTAssertEqual(store.batchProgress.fraction, 1)
        let attempts = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertEqual(attempts.split(separator: "\n").count, 5)
        store.collectAll()
        try await waitUntil { !store.isBusy && store.cachedFileCount == 4 }
        if store.isBusy || store.cachedFileCount != 4 { recordFailureState("cache") }
        XCTAssertEqual(store.batchProgress.totalCount, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8), attempts)
    }

    func testFTPCompletionDoesNotFinishMacProgressDuringSlowHTTP() async throws {
        let (store, root) = try fixture(mode: "phases")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { store.queue.filter { $0.phase == "http" && $0.phaseBytes == 8 }.count == 2 }
        XCTAssertEqual(store.activeTransferCount, 2)
        XCTAssertEqual(store.batchProgress.completedCount, 0)
        XCTAssertLessThan(store.batchProgress.fraction, 1)
        XCTAssertEqual(store.queue.filter(\.isActive).map(\.completedBytes), [8, 8])
        XCTAssertFalse(store.batchStatusMessage.contains("terminée"))
        try await waitUntil { !store.isBusy && store.queue.allSatisfy(\.isSuccessful) }
        XCTAssertEqual(store.batchProgress.completedCount, 4)
        XCTAssertEqual(store.batchProgress.fraction, 1)
        XCTAssertTrue(store.batchStatusMessage.contains("Collecte terminée"))
    }

    func testPagedInventoriesCollectBothDronesAndKeepSettingsSmall() async throws {
        let (store, root) = try fixture(mode: "paged")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { !store.isBusy && store.batchProgress.completedCount == 4 }
        XCTAssertFalse(store.hasIncompleteInventory)
        let settings = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertTrue(settings.queue.isEmpty)
        XCTAssertEqual(settings.queueStorageVersion, 1)
        let restored = GCSStore(storageDirectory: root)
        XCTAssertEqual(restored.batchProgress.completedCount, 4)
        XCTAssertEqual(restored.queue.count, 4)
    }

    func testInvalidAndIncompletePagesCannotBecomeSuccessfulInventories() async throws {
        for mode in ["paged-invalid", "paged-incomplete"] {
            let (store, root) = try fixture(mode: mode)
            defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
            try await waitUntil { store.canCollectAll }
            store.collectAll()
            try await waitUntil { !store.isBusy && store.inventoryErrors.count == 2 }
            XCTAssertTrue(store.queue.isEmpty)
            XCTAssertTrue(store.completedInventoryUUIDs.isEmpty)
            XCTAssertTrue(store.batchStatusMessage.hasPrefix("Collecte partielle"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
        }
    }

    func testLegacyMigrationPreservesJSONAndAllJobsWhileSettingsStaySmall() async throws {
        var legacy = GCSCollectionState(downloadDirectory: "/private/tmp")
        legacy.autoImport = false
        var job = GCSTransfer(droneUUID: first, remotePath: "/fs/microsd/log/2026-09-01/a.ulg", size: 64, host: "localhost", destination: "/private/tmp")
        job.state = "complete"; job.completedBytes = 64
        legacy.queue = [job]
        let (store, root) = try fixture(mode: "normal", initialState: legacy)
        defer { store.disconnect(); try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent("gcs-collection.json"))
        try await waitUntil { store.isConnected }
        XCTAssertEqual(store.batchProgress.completedCount, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("gcs-collection.json")), original)
        let settings = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertTrue(settings.queue.isEmpty)
        XCTAssertEqual(settings.queueStorageVersion, 1)
        XCTAssertEqual(GCSStore(storageDirectory: root).queue.first?.id, job.id)
    }

    func testReadOnlyLibraryNeverStartsCollectionOrWritesGCSState() async throws {
        var initial = GCSCollectionState(downloadDirectory: "/private/tmp")
        initial.host = "localhost"; initial.allowedUUIDs = [first]; initial.autoImport = false
        let (store, root) = try fixture(mode: "normal", initialState: initial, configure: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = LibraryStore(storageDirectory: root)
        let reader = LibraryStore(storageDirectory: root)
        XCTAssertFalse(writer.isReadOnly)
        XCTAssertTrue(reader.isReadOnly)
        let original = try Data(contentsOf: root.appendingPathComponent("gcs-collection.json"))
        store.attach(library: reader)
        store.connect(); store.collectAll(); store.retryFailed()
        store.setAllowed(uuid: second, allowed: true)
        store.autoImport = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.allowedUUIDs.contains(second))
        XCTAssertFalse(store.autoImport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gcs-queue.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gcs-settings.json").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("gcs-collection.json")), original)
        withExtendedLifetime(writer) {}
    }

    func testMissingSQLiteAfterMigrationBlocksCollectionAndPreservesSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-missing-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = GCSCollectionState(downloadDirectory: root.path)
        settings.queueStorageVersion = 1; settings.host = "localhost"
        let original = try JSONEncoder().encode(settings)
        try original.write(to: root.appendingPathComponent("gcs-settings.json"))
        let store = GCSStore(storageDirectory: root)
        store.setAllowed(uuid: first, allowed: true)
        XCTAssertTrue(store.allowedUUIDs.isEmpty)
        XCTAssertTrue(store.errorMessage?.contains("SQLite") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gcs-queue.sqlite").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("gcs-settings.json")), original)
    }

    func testMaintenanceFlushPersistsCurrentSettingsBeforeSnapshotWithoutStartingDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-gcs-maintenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(storageDirectory: root.appendingPathComponent("library"))
        let store = GCSStore(storageDirectory: root)
        store.attach(library: library)
        store.host = "saved-for-backup.local"
        try library.willMaintainLibrary()
        let saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertEqual(saved.host, "saved-for-backup.local")
        XCTAssertTrue(saved.queue.isEmpty)
        XCTAssertEqual(saved.queueStorageVersion, 1)
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(library.hasExternalActivity())
    }

    func testRestoreReopensQueueAndSettingsWithoutAutoReconnectionOrPendingRestart() async throws {
        let (store, root) = try fixture(mode: "normal")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.isConnected }
        try store.preparePersistedStorageForRestore()
        let destination = root.appendingPathComponent("restored-destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var active = GCSTransfer(droneUUID: first, remotePath: "/fs/microsd/log/restore/a.ulg", size: 64,
                                 host: "restored.local", destination: destination.path)
        active.state = "downloading"; active.batchID = "restored-batch"; active.completedBytes = 16
        active.remoteBusyUntil = Date().addingTimeInterval(90)
        var pending = GCSTransfer(droneUUID: first, remotePath: "/fs/microsd/log/restore/b.ulg", size: 64,
                                  host: "restored.local", destination: destination.path)
        pending.batchID = "restored-batch"
        do {
            let repository = try GCSQueueRepository(url: root.appendingPathComponent("gcs-queue.sqlite"))
            try repository.saveTransfers([active, pending])
        }
        var settings = GCSCollectionState(downloadDirectory: destination.path)
        settings.host = "restored.local"; settings.reconnect = true; settings.autoImport = false
        settings.queueStorageVersion = 1; settings.allowedUUIDs = [first]; settings.currentBatchID = "restored-batch"
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("gcs-settings.json"))
        try store.reloadPersistedStateAfterRestore()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.host, "restored.local")
        XCTAssertEqual(store.downloadDirectory.path, destination.path)
        XCTAssertEqual(store.queue.count, 2)
        XCTAssertTrue(store.queue.allSatisfy { $0.state == "interrupted" })
        XCTAssertNotNil(store.queue.first { $0.id == active.id }?.remoteBusyUntil)
        XCTAssertTrue(store.isQueuePaused)
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertEqual(store.activeTransferCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
        let persisted = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertFalse(persisted.reconnect)
        XCTAssertTrue(persisted.queuePaused == true)
    }

    func testFailedRestoreStateNeverAuthorizesTheOldQueueOrOverwritesRestoredFiles() async throws {
        for mode in ["malformed-settings", "missing-queue", "future-version"] {
            let (store, root) = try fixture(mode: "normal", configure: false, stateBuilder: { root in
                var state = GCSCollectionState(downloadDirectory: root.path)
                state.host = "old.local"; state.allowedUUIDs = [self.first]; state.autoImport = false
                state.queue = [GCSTransfer(droneUUID: self.first, remotePath: "/fs/microsd/log/old/a.ulg", size: 64,
                                           host: "old.local", destination: root.path)]
                return state
            })
            defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(store.queue.count, 1)
            let settingsURL = root.appendingPathComponent("gcs-settings.json")
            var state = GCSCollectionState(downloadDirectory: root.path)
            state.host = "restored.local"; state.autoImport = false
            if mode == "missing-queue" { state.queueStorageVersion = 1 }
            if mode == "future-version" { state.schemaVersion = 99 }
            let contents = mode == "malformed-settings" ? Data("{broken".utf8) : try JSONEncoder().encode(state)
            try contents.write(to: settingsURL)
            XCTAssertThrowsError(try store.reloadPersistedStateAfterRestore())
            XCTAssertTrue(store.queue.isEmpty)
            XCTAssertTrue(store.isQueuePaused)
            XCTAssertTrue(store.errorMessage?.contains("restaurée ne peut pas être lue") == true)
            store.resumeQueue(); store.retryFailed(); store.connect(); store.collectAll()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(store.isQueuePaused)
            XCTAssertFalse(store.isConnected); XCTAssertFalse(store.isConnecting)
            XCTAssertEqual(store.activeTransferCount, 0)
            XCTAssertEqual(try Data(contentsOf: settingsURL), contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gcs-queue.sqlite").path))
        }
    }

    func testFailedInventoryNeverClaimsUpToDateEvenWhenOtherDroneIsCached() async throws {
        let (store, root) = try fixture(mode: "normal")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { !store.isBusy && store.queue.count == 4 && store.queue.allSatisfy(\.isSuccessful) }
        try "inventory-error".write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        store.collectAll()
        try await waitUntil { !store.isBusy && store.inventoryErrors.count == 1 }
        XCTAssertEqual(store.batchProgress.totalCount, 0)
        XCTAssertEqual(store.cachedFileCount, 2)
        XCTAssertTrue(store.hasIncompleteInventory)
        XCTAssertEqual(store.completedInventoryUUIDs, [first])
        XCTAssertTrue(store.batchStatusMessage.hasPrefix("Collecte partielle"))
        let restored = GCSStore(storageDirectory: root)
        XCTAssertEqual(restored.inventoryErrors.count, 1)
        XCTAssertTrue(restored.hasIncompleteInventory)
        XCTAssertTrue(restored.batchStatusMessage.hasPrefix("Collecte partielle"))
        try "normal".write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        store.collectAll()
        try await waitUntil { !store.isBusy && !store.hasIncompleteInventory && store.cachedFileCount == 4 }
        XCTAssertTrue(store.batchStatusMessage.hasPrefix("À jour"))
    }

    func testFailedInventoryKeepsSuccessfulCopiesPartialUntilMissingDroneIsRead() async throws {
        let (store, root) = try fixture(mode: "inventory-error")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { !store.isBusy && store.queue.count == 2 && store.queue.allSatisfy(\.isSuccessful) }
        XCTAssertEqual(store.batchProgress.completedCount, 2)
        XCTAssertEqual(store.expectedInventoryUUIDs.count, 2)
        XCTAssertEqual(store.completedInventoryUUIDs.count, 1)
        XCTAssertTrue(store.batchStatusMessage.hasPrefix("Collecte partielle"))
    }

    func testOfflinePendingJobDoesNotBlockNewVisibleDroneOrLoseOriginalWork() async throws {
        var state = GCSCollectionState(downloadDirectory: "/private/tmp")
        state.allowedUUIDs = [first, second]; state.autoImport = false
        var waiting = GCSTransfer(droneUUID: first, remotePath: "/fs/microsd/log/2026-09-01/offline.ulg", size: 64,
                                  host: "localhost", destination: "/private/tmp")
        waiting.state = "interrupted"
        state.queue = [waiting]; state.expectedInventoryUUIDs = [first]; state.completedInventoryUUIDs = [first]
        let (store, root) = try fixture(mode: "offline", initialState: state)
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.retryFailed()
        XCTAssertTrue(store.queue.first?.isPending == true)
        XCTAssertTrue(store.canCollectAll)
        store.collectAll()
        try await waitUntil { !store.isBusy && store.queue.filter(\.isSuccessful).count == 2 }
        XCTAssertEqual(store.queue.first?.id, waiting.id)
        XCTAssertTrue(store.queue.first?.isPending == true)
        XCTAssertEqual(store.queue.first?.attemptCount, 0)
        let before = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertEqual(before.split(separator: "\n").count, 2)
        store.collectAll()
        try await waitUntil { !store.isBusy && store.cachedFileCount >= 2 }
        XCTAssertEqual(store.cachedFileCount, 2, "Repeated inventories in one pending batch must not double-count cached files.")
        XCTAssertEqual(store.queue.count, 3)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8), before)
    }

    func testStopCancelsActiveAndQueuedWorkAndPersistsWithoutAutoRestart() async throws {
        let (store, root) = try fixture(mode: "stop")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { store.queue.filter { $0.remoteBusyUntil != nil }.count == 2 }
        store.stopCollection()
        store.retryFailed() // Same MainActor turn: cancelled workers have not drained yet.
        XCTAssertTrue(store.queue.allSatisfy { $0.state == "stopped" })
        try await waitUntil(timeout: 3) { !store.isBusy }
        XCTAssertEqual(store.activeTransferCount, 0)
        XCTAssertEqual(store.batchProgress.stoppedCount, 4)
        XCTAssertTrue(store.isQueuePaused)
        let restored = GCSStore(storageDirectory: root)
        XCTAssertTrue(restored.queue.allSatisfy { $0.state == "stopped" })
        XCTAssertTrue(restored.isQueuePaused)
        XCTAssertEqual(restored.queue.filter { ($0.remoteBusyUntil ?? .distantPast) > Date() }.count, 2)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testPermanentErrorIsNotAutomaticallyRetried() async throws {
        let (store, root) = try fixture(mode: "permanent")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { store.queue.count == 4 && store.queue.allSatisfy { $0.state == "failed" } && !store.isBusy }
        XCTAssertTrue(store.queue.allSatisfy { $0.attemptCount == 1 })
        XCTAssertEqual(store.batchProgress.failedCount, 4)
    }

    func testCustomDirectoryPersistsAndIsTheOnlyDestinationPassedToCollector() async throws {
        let (store, root) = try fixture(mode: "normal")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("Dossier choisi", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: false)
        try store.setDownloadDirectory(custom)
        let restored = GCSStore(storageDirectory: root)
        XCTAssertEqual(restored.downloadDirectory.path, custom.path)
        XCTAssertNil(restored.downloadDirectoryIssue)
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { !store.isBusy && store.queue.count == 4 && store.queue.allSatisfy(\.isSuccessful) }
        XCTAssertTrue(store.queue.allSatisfy { $0.destination == custom.path })
        let lines = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        for line in lines {
            let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(trace["destination"] as? String, custom.path)
        }
        try FileManager.default.removeItem(at: custom)
        let unavailable = GCSStore(storageDirectory: root)
        XCTAssertEqual(unavailable.downloadDirectory.path, custom.path)
        XCTAssertNotNil(unavailable.downloadDirectoryIssue)
        unavailable.collectAll()
        XCTAssertTrue(unavailable.queue.allSatisfy(\.isSuccessful))
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path), "A missing saved directory must never be recreated.")
        XCTAssertTrue(unavailable.errorMessage?.contains(custom.path) == true)
    }

    func testMissingLegacyJobDirectoryFailsBeforeCollectorAndKeepsOriginalDestination() async throws {
        let (store, root) = try fixture(mode: "normal", configure: false, stateBuilder: { root in
            var job = GCSTransfer(droneUUID: self.first, remotePath: "/fs/microsd/log/2026-09-01/a.ulg", size: 64,
                                  host: "localhost", destination: root.appendingPathComponent("volume-disconnected/logs").path)
            job.state = "interrupted"
            var state = GCSCollectionState(downloadDirectory: root.path)
            state.host = "localhost"; state.allowedUUIDs = [self.first]; state.autoImport = false; state.queue = [job]
            return state
        })
        let missing = root.appendingPathComponent("volume-disconnected/logs")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        store.connect()
        try await waitUntil { store.canCollectAll }
        store.retryFailed()
        try await waitUntil { store.queue.first?.state == "failed" }
        XCTAssertEqual(store.queue[0].destination, missing.path)
        XCTAssertEqual(store.queue[0].attemptCount, 0)
        XCTAssertTrue(store.queue[0].error?.contains(missing.path) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testDirectoryAccessFailureRejectsNewChoiceWithoutReplacingSavedChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-directory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected = root.appendingPathComponent("denied", isDirectory: true)
        let store = GCSStore(storageDirectory: root, directoryIssue: { url in
            url.path == rejected.path ? "Accès refusé : \(url.path)" : nil
        })
        let previous = store.downloadDirectory
        XCTAssertThrowsError(try store.setDownloadDirectory(rejected))
        XCTAssertEqual(store.downloadDirectory, previous)
        let restored = GCSStore(storageDirectory: root)
        XCTAssertEqual(restored.downloadDirectory.path, previous.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }

    func testRetryRetargetsLegacyQueueToVisibleAuthorizedDroneOnNewHost() async throws {
        let (store, root) = try fixture(mode: "normal", configure: false, stateBuilder: { root in
        var known = GCSTransfer(droneUUID: self.first, remotePath: "/fs/microsd/log/2026-09-01/a.ulg", size: 64,
                                host: "192.0.2.10", destination: root.path)
        known.state = "interrupted"
        var unknown = GCSTransfer(droneUUID: self.second, remotePath: known.remotePath, size: 64,
                                  host: "192.0.2.10", destination: root.path)
        unknown.state = "interrupted"
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "198.51.100.10"; state.allowedUUIDs = [self.first]
        state.autoImport = false; state.queue = [known, unknown]
        return state
        })
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        store.connect()
        try await waitUntil { store.canCollectAll }
        store.retryFailed()
        try await waitUntil { store.queue.first?.isSuccessful == true && !store.isBusy }
        XCTAssertEqual(store.queue[0].host, "198.51.100.10")
        XCTAssertEqual(store.queue[0].originalHost, "192.0.2.10")
        XCTAssertEqual(store.queue[1].host, "192.0.2.10")
        XCTAssertEqual(store.queue[1].state, "interrupted")
        let traces = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(traces.count, 1)
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(traces[0].utf8)) as? [String: Any])
        XCTAssertEqual(trace["host"] as? String, "198.51.100.10")
        XCTAssertEqual(trace["uuid"] as? String, first)
        let restored = GCSStore(storageDirectory: root)
        XCTAssertEqual(restored.queue[0].originalHost, "192.0.2.10")
    }

    func testCollectAllAnalyzesMissingFailedAndOldParserCachesWithoutFTP() async throws {
        var library = FleetSnapshot.empty
        var imports = 0
        var importRoot: URL?
        var files: [GCSTransfer] = []
        let (store, root) = try fixture(mode: "normal", snapshot: { library }, importer: { collectedFile in
            imports += 1
            XCTAssertEqual((collectedFile.deletingLastPathComponent().path as NSString).standardizingPath,
                           importRoot.map { ($0.path as NSString).standardizingPath })
            let job = try XCTUnwrap(files.first { $0.localPath == collectedFile.path })
            XCTAssertTrue(FileManager.default.fileExists(atPath: collectedFile.path))
            // Each import consumes the completed file only; valid siblings stay untouched.
            let hash = try XCTUnwrap(job.sha256)
            library.logs.removeAll { $0.id == hash }
            library.logs.append(try self.log(hash: hash, parserVersion: AnalysisService.parserVersion))
            return library
        })
        importRoot = root
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll() // Initially autoImport=false: populate only the durable download cache.
        try await waitUntil { store.queue.count == 4 && store.queue.allSatisfy(\.isSuccessful) && !store.isBusy }
        files = store.queue
        let before = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        library.logs = [
            try log(hash: XCTUnwrap(files[0].sha256), parserVersion: AnalysisService.parserVersion),
            try log(hash: XCTUnwrap(files[1].sha256), status: "error", parserVersion: AnalysisService.parserVersion),
            try log(hash: XCTUnwrap(files[2].sha256), parserVersion: "1.0.0")
        ] // files[3] has never been imported.
        store.autoImport = true
        store.collectAll()
        try await waitUntil { !store.isBusy && store.batchProgress.completedCount == 3 }
        XCTAssertEqual(store.cachedFileCount, 4)
        XCTAssertEqual(store.batchProgress.totalCount, 3)
        XCTAssertEqual(imports, 3)
        XCTAssertEqual(library.logs.count, 4)
        XCTAssertTrue(library.logs.allSatisfy { $0.status == "ok" && $0.metadata["parserVersion"] == AnalysisService.parserVersion })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8), before,
                       "Cached logs must be verified/imported locally without new FTP requests.")
        let importCount = imports
        store.collectAll()
        try await waitUntil { !store.isBusy && store.cachedFileCount == 4 }
        XCTAssertEqual(store.batchProgress.totalCount, 0)
        XCTAssertEqual(imports, importCount)
    }

    func testStaleParserReturnedByImportCannotBecomeCompleteOrTriggerFTPAgain() async throws {
        var downloaded: [GCSTransfer] = []
        let (store, root) = try fixture(mode: "normal", importer: { file in
            let job = try XCTUnwrap(downloaded.first { $0.localPath == file.path })
            var snapshot = FleetSnapshot.empty
            snapshot.logs = [try self.log(hash: XCTUnwrap(job.sha256), parserVersion: "1.0.0")]
            return snapshot
        })
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { store.queue.count == 4 && store.queue.allSatisfy(\.isSuccessful) && !store.isBusy }
        downloaded = store.queue
        let before = try Data(contentsOf: root.appendingPathComponent("trace.jsonl"))
        store.autoImport = true; store.collectAll()
        try await waitUntil { !store.isBusy && store.batchProgress.failedCount == 4 }
        XCTAssertTrue(store.queue.allSatisfy { $0.state == "failed" && $0.attemptCount == 1 && $0.localPath != nil })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("trace.jsonl")), before)
    }

    private func log(hash: String, status: String = "ok", parserVersion: String) throws -> FlightLog {
        let object: [String: Any] = ["id": hash, "droneID": first, "droneName": "Test", "date": "2026-09-01",
            "dateSource": "test", "sourcePaths": [], "fileName": "a.ulg", "sizeBytes": 64,
            "durationSeconds": 1, "status": status, "issues": [], "metadata": ["parserVersion": parserVersion],
            "topics": [], "messages": [], "metrics": [], "coverage": [], "failsafeObserved": false]
        return try JSONDecoder().decode(FlightLog.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
