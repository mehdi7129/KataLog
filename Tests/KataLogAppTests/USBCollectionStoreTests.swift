import Darwin
import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class USBCollectionStoreTests: XCTestCase {
    private let first = "uid:0000000000000001"
    private let second = "uid:0000000000000002"

    private struct Fixture {
        let root: URL
        let store: USBCollectionStore
        // Keep the writer lease alive for every helper spawned by the store.
        let library: LibraryStore
    }

    private func fixture(mode: String = "normal", autoImport: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-usb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let collector = root.appendingPathComponent("usb_fixture.py")
        try #"""
import hashlib,json,os,pathlib,signal,sys,time
root=pathlib.Path(__file__).parent
mode=(root/'mode').read_text()
def arg(name): return sys.argv[sys.argv.index(name)+1]
def emit(event,**fields): print(json.dumps(dict(event=event,**fields)),flush=True)
if sys.argv[1]=='ports':
    emit('ports',ports=[dict(path='/dev/cu.synthetic-A',label='Synthetic A'),dict(path='/dev/cu.synthetic-B',label='Synthetic B')])
elif sys.argv[1]=='inventory':
    identity='uid:0000000000000001' if arg('--device').endswith('-A') else 'uid:0000000000000002'
    emit('usb_inventory',device=dict(identity=identity,systemID=1,componentID=1,label='Synthetic autopilot'),
         logs=[dict(id=7,timeUTC=1700000000,size=64),dict(id=8,timeUTC=1700000001,size=64)])
elif sys.argv[1]=='download':
    with (root/'downloads.jsonl').open('a') as trace: trace.write(json.dumps(sys.argv[1:])+'\n')
    if mode=='slow':
        def end(signum,frame):
            time.sleep(.25)
            (root/'closed').write_text('closed')
            raise SystemExit(0)
        signal.signal(signal.SIGTERM,end)
        (root/'active-pid').write_text(str(os.getpid()))
        emit('progress',bytes=1,total=64)
        time.sleep(30)
    emit('progress',bytes=64,total=64)
    if mode=='missing': raise SystemExit(0)
    target=pathlib.Path(arg('--destination'))/(arg('--identity').replace(':','-')+'-'+arg('--log-id')+'.ulg')
    target.write_bytes(b'ULog\x01\x12\x35'+bytes(57))
    emit('downloaded',bytes=63 if mode=='incomplete' else 64,localPath=str(target),sha256=hashlib.sha256(target.read_bytes()).hexdigest())
"""#.write(to: collector, atomically: true, encoding: .utf8)
        let engine = root.appendingPathComponent("failing_engine.py")
        try #"""
import pathlib,sys
(pathlib.Path(__file__).parent/'import-started').write_text('started')
print('Synthetic ULog parser failure',file=sys.stderr)
raise SystemExit(1)
"""#.write(to: engine, atomically: true, encoding: .utf8)
        let library = LibraryStore(storageDirectory: root, engine: engine)
        let store = USBCollectionStore(stateDirectory: root, collector: collector)
        store.attach(library: library, destination: { root }, autoImport: { autoImport })
        XCTAssertFalse(library.isReadOnly)
        return Fixture(root: root, store: store, library: library)
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "USBCollectionStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "USB fixture timed out"]) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func inventory(_ store: USBCollectionStore, port: String = "/dev/cu.synthetic-A") async throws {
        try await waitUntil { !store.mutationsBlocked }
        store.port = port
        store.readInventory()
        try await waitUntil { !store.isBusy }
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.hasCurrentInventory)
        XCTAssertEqual(store.logs.count, 2)
    }

    func testClientAttributionIsCapturedPerJobAndReconciledWithoutCurrentSelection() async throws {
        let f = try fixture()
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        var client = "CLIENT-A"
        f.store.attach(library: f.library, destination: { f.root }, autoImport: { false }, clientID: { client })
        f.store.pause()
        try await inventory(f.store)
        f.store.selection = [7]; f.store.enqueueSelected()
        client = "CLIENT-B"
        f.store.selection = [8]; f.store.enqueueSelected()
        XCTAssertEqual(f.store.queue.map(\.clientID), ["CLIENT-A", "CLIENT-B"])
        let saved = USBCollectionStore(stateDirectory: f.root)
        XCTAssertEqual(saved.queue.map(\.clientID), ["CLIENT-A", "CLIENT-B"])
        try f.store.removeClientAttribution("CLIENT-A")
        XCTAssertEqual(f.store.queue.map(\.clientID), ["", "CLIENT-B"])
        try f.store.reconcileClientAttributions(validIDs: [])
        XCTAssertEqual(f.store.queue.map(\.clientID), ["", ""])
    }

    func testGCSIntegrationBlocksMaintenanceAndDestinationUntilUSBCloses() async throws {
        let f = try fixture(mode: "slow")
        let gcs = GCSStore(storageDirectory: f.root)
        gcs.usb = f.store
        gcs.autoImport = false
        gcs.attach(library: f.library)
        addTeardownBlock { @MainActor in
            try await gcs.finishTermination()
            try? FileManager.default.removeItem(at: f.root)
        }
        try await waitUntil { !f.store.mutationsBlocked && gcs.downloadDirectoryIssue == nil }
        try await inventory(f.store)
        f.store.selection = [7]; f.store.enqueueSelected()
        try await waitUntil { f.store.isBusy && FileManager.default.fileExists(atPath: f.root.appendingPathComponent("active-pid").path) }
        XCTAssertTrue(gcs.isCollectionBusy)
        XCTAssertFalse(gcs.isBusy, "USB activity must not lock independent GCS browsing.")
        XCTAssertTrue(f.library.hasExternalActivity())
        try await waitUntil { gcs.preventsIdleSystemSleep }
        do { try await gcs.setDownloadDirectory(f.root); XCTFail("USB active destination must stay fixed.") }
        catch {}
        do { try await gcs.flushPersistedStateForMaintenance(); XCTFail("Maintenance must wait for USB closure.") }
        catch {}
        try await gcs.finishTermination()
        XCTAssertFalse(f.store.isBusy)
        XCTAssertFalse(gcs.preventsIdleSystemSleep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("closed").path))
        let persisted = USBCollectionStore(stateDirectory: f.root)
        let state = try JSONDecoder().decode(USBCollectionState.self,
            from: Data(contentsOf: f.root.appendingPathComponent("usb-collection.json")))
        XCTAssertEqual(state.queue.first?.state, "interrupted", "Termination must durably drain the final state after closing admission.")
        XCTAssertEqual(persisted.queue.first?.device.identity, first)
    }

    func testIdleQueueFlushesUnderMaintenanceAndClosedAdmissionWithoutAdmittingWork() async throws {
        let f = try fixture()
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        f.store.pause(); try await inventory(f.store)
        f.store.selection = [7]; f.store.enqueueSelected()
        var blocked = false
        f.store.attach(library: f.library, destination: { f.root }, autoImport: { false }, admissionBlocked: { blocked })
        f.library.isMaintainingLibrary = true
        defer { f.library.isMaintainingLibrary = false }
        XCTAssertTrue(f.store.mutationsBlocked)
        XCTAssertNoThrow(try f.store.flushForMaintenance())
        f.library.isMaintainingLibrary = false
        blocked = true
        XCTAssertTrue(f.store.mutationsBlocked)
        f.store.selection = [8]; f.store.enqueueSelected(); f.store.resume()
        XCTAssertEqual(f.store.queue.count, 1)
        XCTAssertFalse(f.store.isBusy)
        XCTAssertNoThrow(try f.store.flushForMaintenance())
        let persisted = USBCollectionStore(stateDirectory: f.root)
        XCTAssertEqual(persisted.queue.map(\.id), f.store.queue.map(\.id))
    }

    func testMaintenanceDrainCannotWriteThroughAReadOnlyLibraryLease() async throws {
        let f = try fixture()
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        f.store.pause(); try await inventory(f.store)
        f.store.selection = [7]; f.store.enqueueSelected()
        let path = f.root.appendingPathComponent("usb-collection.json")
        let original = try Data(contentsOf: path)
        let reader = LibraryStore(storageDirectory: f.root, engine: f.root.appendingPathComponent("failing_engine.py"))
        XCTAssertTrue(reader.isReadOnly)
        let readOnlyStore = USBCollectionStore(stateDirectory: f.root)
        readOnlyStore.attach(library: reader, destination: { f.root }, autoImport: { false }, admissionBlocked: { true })
        XCTAssertThrowsError(try readOnlyStore.flushForMaintenance())
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testLegacyQueueWithoutClientAttributionRemainsExplicitlyUnassigned() async throws {
        let f = try fixture()
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        f.store.pause(); try await inventory(f.store)
        f.store.selection = [7]; f.store.enqueueSelected()
        let path = f.root.appendingPathComponent("usb-collection.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var rows = try XCTUnwrap(object["queue"] as? [[String: Any]])
        rows[0].removeValue(forKey: "clientID"); object["queue"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
        let restored = USBCollectionStore(stateDirectory: f.root)
        XCTAssertNil(restored.queue.first?.clientID)
        XCTAssertTrue(restored.isPaused)
    }

    func testPausedSelectionsKeepDistinctHardwareIdentityAndResumeOnlyCurrentDevice() async throws {
        let f = try fixture()
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        f.store.pause()
        try await inventory(f.store)
        f.store.selection = [7]
        f.store.enqueueSelected()
        try await inventory(f.store, port: "/dev/cu.synthetic-B")
        f.store.selection = [7]
        f.store.enqueueSelected()
        // A duplicate selection cannot overwrite or duplicate the queued job.
        f.store.selection = [7]
        f.store.enqueueSelected()
        XCTAssertEqual(f.store.queue.count, 2)
        XCTAssertTrue(f.store.isPaused)
        XCTAssertEqual(f.store.queue.map(\.device.identity), [first, second])
        XCTAssertEqual(Set(f.store.queue.map(\.id)).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("downloads.jsonl").path))

        let restored = USBCollectionStore(stateDirectory: f.root)
        XCTAssertEqual(restored.queue.map(\.device.identity), [first, second])
        XCTAssertEqual(restored.queue.map(\.destination), [f.root.path, f.root.path])
        XCTAssertTrue(restored.isPaused)
        XCTAssertFalse(restored.hasCurrentInventory)

        f.store.resume()
        try await waitUntil { !f.store.isBusy && f.store.queue.last?.state == "downloaded" }
        XCTAssertEqual(f.store.queue.first?.state, "queued", "An unattached device must remain queued.")
        let lines = try String(contentsOf: f.root.appendingPathComponent("downloads.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let arguments = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(lines.first).utf8))
        let identityIndex = try XCTUnwrap(arguments.firstIndex(of: "--identity"))
        XCTAssertEqual(arguments[identityIndex + 1], second)
        let portIndex = try XCTUnwrap(arguments.firstIndex(of: "--device"))
        XCTAssertEqual(arguments[portIndex + 1], "/dev/cu.synthetic-B")
    }

    func testFinishingFirstDeviceOffersResumeForTheNextDevice() async throws {
        let f = try fixture()
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        f.store.pause()
        try await inventory(f.store)
        f.store.selection = [7]; f.store.enqueueSelected()
        try await inventory(f.store, port: "/dev/cu.synthetic-B")
        f.store.selection = [7]; f.store.enqueueSelected()

        try await inventory(f.store)
        f.store.resume()
        try await waitUntil { !f.store.isBusy && f.store.queue.first?.state == "downloaded" }
        XCTAssertEqual(f.store.queue.last?.state, "queued")
        XCTAssertTrue(f.store.isPaused, "Finishing A must offer Reprendre cet appareil for the next controller.")
        XCTAssertEqual(f.store.pendingCount, 1)

        try await inventory(f.store, port: "/dev/cu.synthetic-B")
        XCTAssertTrue(f.store.isPaused)
        XCTAssertFalse(f.store.isBusy, "Reading B must preserve the explicit resume step.")
        f.store.resume()
        try await waitUntil { !f.store.isBusy && f.store.queue.allSatisfy { $0.state == "downloaded" } }
        XCTAssertEqual(f.store.pendingCount, 0)
        let lines = try String(contentsOf: f.root.appendingPathComponent("downloads.jsonl"), encoding: .utf8).split(separator: "\n")
        let calls = try lines.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        XCTAssertEqual(calls.count, 2)
        let identities = try calls.map { arguments in
            arguments[try XCTUnwrap(arguments.firstIndex(of: "--identity")) + 1]
        }
        let ports = try calls.map { arguments in
            arguments[try XCTUnwrap(arguments.firstIndex(of: "--device")) + 1]
        }
        XCTAssertEqual(identities, [first, second])
        XCTAssertEqual(ports, ["/dev/cu.synthetic-A", "/dev/cu.synthetic-B"])
    }

    func testChangingPortOrBaudInvalidatesPermissionToEnqueueOldInventory() async throws {
        let f = try fixture()
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        f.store.pause()
        try await inventory(f.store)
        f.store.selection = [7]
        f.store.port = "/dev/cu.synthetic-B"
        XCTAssertFalse(f.store.canAdd)
        f.store.enqueueSelected()
        XCTAssertTrue(f.store.queue.isEmpty)
        f.store.port = "/dev/cu.synthetic-A"
        f.store.baud = 921600
        XCTAssertFalse(f.store.canAdd)
        f.store.enqueueSelected()
        XCTAssertTrue(f.store.queue.isEmpty)
    }

    func testStopKeepsBusyUntilCollectorHasClosedAndPreservesInterruptedJob() async throws {
        let f = try fixture(mode: "slow")
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        try await inventory(f.store)
        f.store.selection = [7]
        f.store.enqueueSelected()
        let pidFile = f.root.appendingPathComponent("active-pid")
        try await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        f.store.selection = [8]
        XCTAssertTrue(f.store.canAdd, "The current inventory can add another log while its first log downloads.")
        f.store.enqueueSelected()
        XCTAssertEqual(f.store.queue.map(\.log.id), [7, 8])
        XCTAssertEqual(f.store.queue.first?.state, "downloading")
        XCTAssertEqual(f.store.queue.last?.state, "queued")
        f.store.stop()
        XCTAssertTrue(f.store.isBusy, "The serial owner is still shutting down.")
        XCTAssertThrowsError(try f.store.flushForMaintenance())
        try await waitUntil(timeout: 3) { !f.store.isBusy }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("closed").path))
        XCTAssertEqual(kill(pid, 0), -1, "A new inventory must never overlap the previous helper process.")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(f.store.queue.first?.state, "interrupted")
        XCTAssertTrue(f.store.isPaused)
        let restored = USBCollectionStore(stateDirectory: f.root)
        XCTAssertEqual(restored.queue.first?.state, "interrupted")
        XCTAssertEqual(restored.queue.last?.state, "queued")
        XCTAssertEqual(restored.queue.first?.device.identity, first)
    }

    func testCorruptQueueIsReportedAndNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-usb-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("usb-collection.json"), original = Data("{truncated".utf8)
        try original.write(to: state)
        let store = USBCollectionStore(stateDirectory: root)
        XCTAssertTrue(store.mutationsBlocked)
        XCTAssertNotNil(store.errorMessage)
        store.resume(); store.refreshPorts(); store.enqueueSelected()
        XCTAssertThrowsError(try store.flushForMaintenance())
        XCTAssertEqual(try Data(contentsOf: state), original)
    }

    func testProgressWithoutVerifiedCompletionIsNeverImported() async throws {
        for mode in ["missing", "incomplete"] {
            let f = try fixture(mode: mode, autoImport: true)
            defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
            try await inventory(f.store)
            f.store.selection = [7]
            f.store.enqueueSelected()
            try await waitUntil { !f.store.isBusy && f.store.queue.first?.state == "failed" }
            XCTAssertTrue(f.store.isPaused)
            XCTAssertNil(f.store.queue.first?.sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("import-started").path))
        }
    }

    func testImportFailurePreservesVerifiedLocalCopyWithoutReportingSuccess() async throws {
        let f = try fixture(autoImport: true)
        defer { f.store.stop(); try? FileManager.default.removeItem(at: f.root) }
        try await inventory(f.store)
        f.store.selection = [7]
        f.store.enqueueSelected()
        try await waitUntil { !f.store.isBusy && f.store.queue.first?.state == "failed" }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("import-started").path))
        let transfer = try XCTUnwrap(f.store.queue.first)
        XCTAssertNotNil(transfer.sha256)
        XCTAssertEqual(transfer.bytes, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(transfer.localPath)))
        XCTAssertFalse(transfer.isSuccessful)
        XCTAssertTrue(f.store.isPaused)
    }
}
