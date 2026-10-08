import Foundation
import SQLite3
import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class ClientReconciliationTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private struct Fixture { let library: LibraryStore; let source: URL; let client: ClientProfile; let other: ClientProfile; let logID: String }
    private struct CleanupFailure: LocalizedError { var errorDescription: String? { "synthetic collection cleanup failure" } }

    private func settle(_ library: LibraryStore) async throws {
        try await Task.sleep(for: .milliseconds(20))
        let deadline = Date().addingTimeInterval(15)
        while library.isLoading || library.isQuerying || library.isMaintainingLibrary || library.clients.isLoading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(library.isLoading || library.isQuerying || library.isMaintainingLibrary || library.clients.isLoading)
    }
    private func fixture(paged: Bool) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-client-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ulg")
        let process = Process(); process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["KATALOG_TEST_PYTHON"]))
        process.arguments = ["-B", "-c", "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from fixture_ulog import synthetic_ulog;Path(sys.argv[2]).write_bytes(synthetic_ulog(samples=3))", project.appendingPathComponent("Tests").path, source.path]
        try process.run(); ProcessLifetime.wait(for: process); XCTAssertEqual(process.terminationStatus, 0)
        let library = LibraryStore(storageDirectory: root.appendingPathComponent("Library"), engine: project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"), pagedNavigation: paged)
        try await settle(library)
        let client = try await library.clients.create(name: "Deleted client")
        let other = try await library.clients.create(name: "Retained client")
        let imported = try await library.importCollectedFolder(source, clientID: client.id)
        try await settle(library)
        try library.views.chooseClient(client.id)
        library.loadHistory(); try await settle(library)
        return Fixture(library: library, source: source, client: client, other: other, logID: try XCTUnwrap(imported.logs.first?.id))
    }

    func testCommittedDeletionReconcilesProfilesScopeAndLogsDespiteCollectionFailure() async throws {
        for paged in [false, true] {
            let value = try await fixture(paged: paged), library = value.library
            defer { library.prepareForTermination() }
            let original = try Data(contentsOf: value.source)
            library.clientDidDelete = { _ in throw CleanupFailure() }
            do { try await library.clients.remove(id: value.client.id); XCTFail("Expected partial cleanup failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains("supprimé"), error.localizedDescription) }
            try await settle(library)
            XCTAssertEqual(library.clients.profiles.map(\.id), [value.other.id])
            XCTAssertEqual(library.views.state.activeScope.clientID, "")
            XCTAssertEqual(library.snapshot.logs.map(\.id), [value.logID])
            XCTAssertNil(library.snapshot.logs.first?.clientID)
            XCTAssertEqual(try Data(contentsOf: value.source), original)
        }
    }

    private func seedQueue(_ value: Fixture) throws -> (String, String) {
        let root = value.library.storageDirectory
        var first = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/log/first.ulg", size: 100, host: "fixture.invalid", destination: root.path)
        first.clientID = value.client.id; first.state = "stopped"
        var second = GCSTransfer(droneUUID: first.droneUUID, remotePath: "/log/second.ulg", size: 100, host: "fixture.invalid", destination: root.path)
        second.clientID = value.other.id; second.state = "stopped"
        let repository = try GCSQueueRepository(url: root.appendingPathComponent("gcs-queue.sqlite"))
        try repository.migrateLegacy([first, second])
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.collectionClientID = value.client.id; state.reconnect = false; state.autoImport = false
        state.queueStorageVersion = 1; state.queuePaused = true
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-settings.json"))
        return (first.id, second.id)
    }

    func testReloadRetriesCleanupWithoutRepeatingDeletionOrReassigningOtherJobs() async throws {
        let value = try await fixture(paged: true), library = value.library
        let ids = try seedQueue(value), gcs = GCSStore(storageDirectory: library.storageDirectory)
        defer { gcs.stopForTermination(); library.prepareForTermination() }
        gcs.attach(library: library); try await settle(library)
        let reconcile = library.clientProfilesDidLoad
        var unavailable = true
        library.clientProfilesDidLoad = { valid in if unavailable { throw CleanupFailure() }; try await reconcile(valid) }
        library.clientDidDelete = { _ in throw CleanupFailure() }
        do { try await library.clients.remove(id: value.client.id); XCTFail("Expected cleanup failure") } catch {}
        try await settle(library)
        library.clients.reload(); try await settle(library)
        XCTAssertTrue(library.clients.errorMessage?.contains("Nettoyage") == true)
        XCTAssertEqual(gcs.queue.first { $0.id == ids.0 }?.clientID, value.client.id)
        unavailable = false
        library.clients.reload(); try await settle(library)
        XCTAssertNil(library.clients.errorMessage)
        XCTAssertNil(gcs.queue.first { $0.id == ids.0 }?.clientID)
        XCTAssertEqual(gcs.queue.first { $0.id == ids.1 }?.clientID, value.other.id)
        XCTAssertEqual(gcs.collectionClientID, "")
        let stored = try GCSQueueRepository(url: library.storageDirectory.appendingPathComponent("gcs-queue.sqlite"), readOnly: true)
        XCTAssertNil(try stored.transfer(id: ids.0)?.clientID)
        XCTAssertEqual(try stored.transfer(id: ids.1)?.clientID, value.other.id)
        library.clients.reload(); try await settle(library)
        XCTAssertNil(library.clients.errorMessage)
        XCTAssertEqual(library.snapshot.logs.map(\.id), [value.logID])
        XCTAssertNil(library.snapshot.logs.first?.clientID)
        // Restoring a queue invalidates the successful-ID cache even if the
        // current client list is unchanged.
        try gcs.preparePersistedStorageForRestore()
        var restored = try XCTUnwrap(gcs.queue.first { $0.id == ids.0 }); restored.clientID = value.client.id
        let writable = try GCSQueueRepository(url: library.storageDirectory.appendingPathComponent("gcs-queue.sqlite"))
        try writable.saveTransfers([restored])
        try gcs.reloadPersistedStateAfterRestore()
        XCTAssertEqual(gcs.queue.first { $0.id == ids.0 }?.clientID, value.client.id)
        library.clients.reload(); try await settle(library)
        XCTAssertNil(gcs.queue.first { $0.id == ids.0 }?.clientID)
        XCTAssertNil(try stored.transfer(id: ids.0)?.clientID)
    }

    func testLateAttachmentAndRestartRepairOrphanQueueAttributions() async throws {
        for restart in [false, true] {
            var value: Fixture? = try await fixture(paged: false)
            let ids = try seedQueue(try XCTUnwrap(value))
            let root = try XCTUnwrap(value).library.storageDirectory
            let removed = try XCTUnwrap(value).client.id, kept = try XCTUnwrap(value).other.id
            try await value!.library.clients.remove(id: removed)
            try await settle(value!.library)
            let library: LibraryStore
            if restart {
                weak var previous = value?.library
                value!.library.prepareForTermination(); value = nil
                let deadline = Date().addingTimeInterval(5)
                while previous != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertNil(previous, "The old writer must release its lease before restart.")
                library = LibraryStore(storageDirectory: root, engine: project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"))
                try await settle(library)
            } else { library = try XCTUnwrap(value).library }
            let gcs = GCSStore(storageDirectory: root)
            defer { gcs.stopForTermination(); library.prepareForTermination() }
            gcs.attach(library: library); try await settle(library)
            XCTAssertFalse(library.isReadOnly)
            XCTAssertNil(library.clients.errorMessage)
            XCTAssertNil(gcs.queue.first { $0.id == ids.0 }?.clientID)
            XCTAssertEqual(gcs.queue.first { $0.id == ids.1 }?.clientID, kept)
            XCTAssertEqual(gcs.collectionClientID, "")
        }
    }

    func testReaderNeverCleansWriterCollection() async throws {
        let value = try await fixture(paged: false), writer = value.library
        let ids = try seedQueue(value)
        defer { writer.prepareForTermination() }
        try await writer.clients.remove(id: value.client.id); try await settle(writer)
        let root = writer.storageDirectory, settings = try Data(contentsOf: root.appendingPathComponent("gcs-settings.json"))
        let reader = LibraryStore(storageDirectory: root, engine: project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"))
        let gcs = GCSStore(storageDirectory: root)
        defer { gcs.stopForTermination(); reader.prepareForTermination() }
        gcs.attach(library: reader); try await settle(reader)
        XCTAssertTrue(reader.isReadOnly)
        XCTAssertEqual(gcs.queue.first { $0.id == ids.0 }?.clientID, value.client.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("gcs-settings.json")), settings)
        let stored = try GCSQueueRepository(url: root.appendingPathComponent("gcs-queue.sqlite"), readOnly: true)
        XCTAssertEqual(try stored.transfer(id: ids.0)?.clientID, value.client.id)
    }

    func testCleanupWaitsForActiveCollectionAndCanRetryAfterItStops() async throws {
        let value = try await fixture(paged: false), library = value.library
        let ids = try seedQueue(value), root = library.storageDirectory
        let script = root.appendingPathComponent("synthetic-collector.py")
        try """
        import json,sys,time
        if sys.argv[1]=='discover':
            print(json.dumps({'event':'connection','connected':True}),flush=True)
            while True:
                print(json.dumps({'event':'drones','drones':[{'uuid':'0102030405060708090A0B0C','time_usec':time.time()*1e6,'arming_state':1}]}),flush=True)
                time.sleep(.1)
        else: time.sleep(30)
        """.write(to: script, atomically: true, encoding: .utf8)
        let gcs = GCSStore(storageDirectory: root, collector: script)
        defer { gcs.stopForTermination(); library.prepareForTermination() }
        gcs.attach(library: library); try await settle(library)
        let reconcile = library.clientProfilesDidLoad
        library.clientProfilesDidLoad = { _ in throw CleanupFailure() }
        library.clientDidDelete = { _ in throw CleanupFailure() }
        do { try await library.clients.remove(id: value.client.id) } catch {}
        try await settle(library)
        gcs.host = "synthetic.invalid"; gcs.connect()
        let deadline = Date().addingTimeInterval(5)
        while gcs.drones.isEmpty || !gcs.isConnected, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(gcs.drones.isEmpty); XCTAssertTrue(gcs.isConnected)
        gcs.selectDrone("0102030405060708090A0B0C")
        XCTAssertTrue(gcs.isBusy)
        do { try await reconcile([value.other.id]); XCTFail("Active collection must block cleanup") } catch {}
        XCTAssertEqual(gcs.queue.first { $0.id == ids.0 }?.clientID, value.client.id)
        gcs.stopCollection(); gcs.disconnect()
        let stopped = Date().addingTimeInterval(5)
        while gcs.isBusy, Date() < stopped { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(gcs.isBusy)
        try await reconcile([value.other.id])
        XCTAssertNil(gcs.queue.first { $0.id == ids.0 }?.clientID)
    }

    func testReconciliationIsVisibleToTerminationWhileQueueWriteWaits() async throws {
        let value = try await fixture(paged: false), library = value.library
        _ = try seedQueue(value)
        let gcs = GCSStore(storageDirectory: library.storageDirectory)
        defer { gcs.stopForTermination(); library.prepareForTermination() }
        gcs.attach(library: library); try await settle(library)
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.storageDirectory.appendingPathComponent("gcs-queue.sqlite").path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let operation = Task { try await library.clientProfilesDidLoad([value.other.id]) }
        let deadline = Date().addingTimeInterval(2)
        while !library.hasExternalActivity(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(library.hasExternalActivity())
        XCTAssertTrue(library.hasActiveWork)
        XCTAssertFalse(gcs.isBusy)
        operation.cancel()
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await operation.value
        XCTAssertFalse(library.hasExternalActivity())
        XCTAssertFalse(library.hasActiveWork)
    }

    func testReloadDoesNotCreateQueueWhenPersistedCollectionIsBlocked() async throws {
        for unreadableSettings in [false, true] {
            let value = try await fixture(paged: false), library = value.library, root = library.storageDirectory
            var settings = GCSCollectionState(downloadDirectory: root.path)
            settings.queueStorageVersion = 1; settings.reconnect = false
            let original = unreadableSettings ? Data("invalid settings".utf8) : try JSONEncoder().encode(settings)
            let settingsURL = root.appendingPathComponent("gcs-settings.json")
            try original.write(to: settingsURL)
            let gcs = GCSStore(storageDirectory: root)
            defer { gcs.stopForTermination(); library.prepareForTermination() }
            gcs.attach(library: library); try await settle(library)
            XCTAssertNotNil(library.clients.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gcs-queue.sqlite").path))
            XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        }
    }

    func testScopeWriteFailureStillClearsDeletedClientInMemoryAndReloadsLogs() async throws {
        for paged in [false, true] {
            let value = try await fixture(paged: paged), library = value.library
            defer { library.prepareForTermination() }
            let unexpected = library.storageDirectory.appendingPathComponent("views.json")
            let originalViews = try Data(contentsOf: unexpected)
            try FileManager.default.removeItem(at: unexpected)
            try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: true)
            let preserved = unexpected.appendingPathComponent("preserved.ulg")
            try Data("preserved".utf8).write(to: preserved)
            do { try await library.clients.remove(id: value.client.id); XCTFail("Expected scope persistence error") }
            catch { XCTAssertTrue(error.localizedDescription.contains("supprimé")) }
            try await settle(library)
            XCTAssertEqual(library.clients.profiles.map(\.id), [value.other.id])
            XCTAssertEqual(library.views.state.activeScope.clientID, "")
            XCTAssertNotNil(library.views.errorMessage)
            XCTAssertEqual(library.snapshot.logs.map(\.id), [value.logID])
            XCTAssertNil(library.snapshot.logs.first?.clientID)
            XCTAssertEqual(try Data(contentsOf: preserved), Data("preserved".utf8))
            // Once the external obstacle is repaired, the existing retry also
            // persists the scope already reconciled in memory.
            try FileManager.default.moveItem(at: unexpected, to: unexpected.appendingPathExtension("preserved"))
            try originalViews.write(to: unexpected)
            library.clients.reload(); try await settle(library)
            let saved = try JSONDecoder().decode(LibraryViewState.self, from: Data(contentsOf: unexpected))
            XCTAssertEqual(saved.activeScope.clientID, "")
            XCTAssertNil(library.views.errorMessage)
        }
    }
}
