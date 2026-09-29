import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class GCSStoreTests: XCTestCase {
    let first = "0102030405060708090A0B0C"
    let second = "1112131415161718191A1B1C"

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
                 importer: ((URL) async throws -> FleetSnapshot)? = nil) throws -> (GCSStore, URL) {
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
        emit('drones',drones=[dict(uuid=u,time_usec=time.time()*1e6) for u in ids]);time.sleep(.15)
u=arg('--uuid')
paths=['/fs/microsd/log/2026-09-01/a.ulg','/fs/microsd/log/2026-09-01/b.ulg']
if cmd=='inventory':
    files=[]
    for p in paths:
        local=root/(u+pathlib.Path(p).name+'.cache')
        item=dict(path=p,size=64,isDownloaded=local.exists())
        if local.exists(): item.update(localPath=str(local),sha256=hashlib.sha256(local.read_bytes()).hexdigest())
        files.append(item)
    emit('inventory',uuid=u,files=files)
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
    emit('progress',uuid=u,path=p,bytes=16,total=64)
    time.sleep(2 if mode=='stop' else .6)
    emit('transfer_finished',uuid=u,path=p)
    if mode=='retry' and u==ids[0] and p==paths[0] and attempt==1:
        emit('error',message='simulated transient timeout',retryable=True);sys.exit(1)
    if mode=='permanent':
        emit('error',message='simulated invalid destination',retryable=False);sys.exit(1)
    local.write_bytes(key.encode().ljust(64,b'x'))
    emit('downloaded',uuid=u,path=p,bytes=64,localPath=str(local),sha256=hashlib.sha256(local.read_bytes()).hexdigest())
"""#.write(to: script, atomically: true, encoding: .utf8)
        let store = GCSStore(storageDirectory: root, collector: script, snapshot: snapshot, importer: importer)
        store.autoImport = false; store.host = "localhost"
        store.setAllowed(uuid: first, allowed: true); store.setAllowed(uuid: second, allowed: true)
        store.connect()
        return (store, root)
    }

    func testCollectAllRunsTwoDronesRetriesAndSkipsVerifiedCache() async throws {
        let (store, root) = try fixture(mode: "retry")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        store.collectAll()
        try await waitUntil { store.activeTransferCount == 2 }
        XCTAssertEqual(Set(store.queue.filter(\.isActive).map(\.droneUUID)).count, 2)
        try await waitUntil { store.queue.count == 4 && store.queue.allSatisfy(\.isSuccessful) && !store.isBusy }
        XCTAssertEqual(store.queue.first { $0.droneUUID == first && $0.filename == "a.ulg" }?.attemptCount, 2)
        XCTAssertEqual(store.batchProgress.completedCount, 4)
        XCTAssertEqual(store.batchProgress.fraction, 1)
        let attempts = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertEqual(attempts.split(separator: "\n").count, 5)
        store.collectAll()
        try await waitUntil { !store.isBusy && store.cachedFileCount == 4 }
        XCTAssertEqual(store.batchProgress.totalCount, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8), attempts)
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
        let (previous, root) = try fixture(mode: "normal")
        previous.disconnect()
        let missing = root.appendingPathComponent("volume-disconnected/logs")
        var job = GCSTransfer(droneUUID: first, remotePath: "/fs/microsd/log/2026-09-01/a.ulg", size: 64,
                              host: "localhost", destination: missing.path)
        job.state = "interrupted"
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "localhost"; state.allowedUUIDs = [first]; state.autoImport = false; state.queue = [job]
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-collection.json"))
        let store = GCSStore(storageDirectory: root, collector: root.appendingPathComponent("collector.py"))
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
        let (previous, root) = try fixture(mode: "normal")
        previous.disconnect()
        var known = GCSTransfer(droneUUID: first, remotePath: "/fs/microsd/log/2026-09-01/a.ulg", size: 64,
                                host: "192.0.2.10", destination: root.path)
        known.state = "interrupted"
        var unknown = GCSTransfer(droneUUID: second, remotePath: known.remotePath, size: 64,
                                  host: "192.0.2.10", destination: root.path)
        unknown.state = "interrupted"
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "198.51.100.10"; state.allowedUUIDs = [first]
        state.autoImport = false; state.queue = [known, unknown]
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-collection.json"))
        let store = GCSStore(storageDirectory: root, collector: root.appendingPathComponent("collector.py"))
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
        let (store, root) = try fixture(mode: "normal", snapshot: { library }, importer: { folder in
            imports += 1
            XCTAssertEqual((folder.path as NSString).standardizingPath,
                           importRoot.map { ($0.path as NSString).standardizingPath })
            // The analyzer consumes a folder; all four cached sources become current.
            library.logs = try files.map { try self.log(hash: XCTUnwrap($0.sha256), parserVersion: AnalysisService.parserVersion) }
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
        XCTAssertGreaterThan(imports, 0)
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

    private func log(hash: String, status: String = "ok", parserVersion: String) throws -> FlightLog {
        let object: [String: Any] = ["id": hash, "droneID": first, "droneName": "Test", "date": "2026-09-01",
            "dateSource": "test", "sourcePaths": [], "fileName": "a.ulg", "sizeBytes": 64,
            "durationSeconds": 1, "status": status, "issues": [], "metadata": ["parserVersion": parserVersion],
            "topics": [], "messages": [], "metrics": [], "coverage": [], "failsafeObserved": false]
        return try JSONDecoder().decode(FlightLog.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
