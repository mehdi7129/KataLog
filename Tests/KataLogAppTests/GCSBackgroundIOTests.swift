import Foundation
import SQLite3
import Combine
import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class GCSBackgroundIOTests: XCTestCase {
    func testDestinationGetterUsesSnapshotWhileNewChoiceChecksOffMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-destination-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("slow-volume")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        let entered = expectation(description: "Destination metadata read has started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = GCSStore(storageDirectory: root, directoryIssue: { url in
            if url.standardizedFileURL.path == candidate.standardizedFileURL.path {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return nil
        })
        try await store.flushPersistedStateForMaintenance()
        let original = store.downloadDirectory
        let change = Task { try await store.setDownloadDirectory(candidate) }
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<100 { XCTAssertNil(store.downloadDirectoryIssue) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.downloadDirectory, original, "An unverified destination must not be published.")
        release.signal()
        try await change.value
        XCTAssertEqual(store.downloadDirectory.standardizedFileURL.path, candidate.standardizedFileURL.path)
        XCTAssertNil(store.downloadDirectoryIssue)
        try await store.finishTermination()
    }

    func testLargeQueueStopPersistsWithoutBlockingMainActorAndReopensStopped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-gcs-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "0102030405060708090A0B0C"
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "synthetic-gcs.local"; state.allowedUUIDs = [uuid]
        state.autoImport = false; state.reconnect = false; state.currentBatchID = "large-io"
        state.queue = (0..<50_000).map { index in
            var item = GCSTransfer(droneUUID: uuid, remotePath: "/fixture/\(index).ulg", size: 1024,
                                   host: state.host, destination: root.path)
            item.batchID = "large-io"
            return item
        }
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-collection.json"))
        let store = GCSStore(storageDirectory: root)
        await store.retryFailed() // Requeue jobs recovered as interrupted; no collector is connected.
        var gaps: [Double] = []
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                gaps.append(now - previous); previous = now
            }
        }
        defer { heartbeat.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        let started = ProcessInfo.processInfo.systemUptime
        store.stopCollection()
        try await store.flushPersistedStateForMaintenance()
        try await Task.sleep(for: .milliseconds(10))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        heartbeat.cancel(); await heartbeat.value
        let maximumGap = gaps.max() ?? 0
        print("GCS_REAL_PERSISTENCE jobs=50000 seconds=\(elapsed) heartbeatMaxMs=\(maximumGap * 1000)")
        XCTAssertLessThan(maximumGap, 0.5, "Real queue persistence must leave the UI actor responsive.")
        let repository = try GCSQueueRepository(url: root.appendingPathComponent("gcs-queue.sqlite"), readOnly: true)
        XCTAssertEqual(try repository.transferCount(), 50_000)
        XCTAssertEqual(try repository.retryableCount(authorizedUUIDs: [uuid]), 50_000)
        XCTAssertTrue(try repository.retainedTransfers().allSatisfy { $0.state == "stopped" })
        let reopened = GCSStore(storageDirectory: root)
        XCTAssertTrue(reopened.isQueuePaused)
        XCTAssertEqual(reopened.batchProgress.stoppedCount, 50_000)
    }
    func testQueuedWritesKeepLatestSettingsWhileSQLiteIsLocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-io-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GCSStore(storageDirectory: root)
        try await store.flushPersistedStateForMaintenance()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("gcs-queue.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        store.autoImport = false
        let started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(100))
        store.host = "latest.synthetic.local"; store.autoImport = true; store.pauseQueue()
        try await Task.sleep(for: .milliseconds(150))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertLessThan(elapsed, 2, "A SQLite writer lock must not delay UI input until the 5 s busy timeout.")
        try await store.waitForPersistence()
        let saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertEqual(saved.host, "latest.synthetic.local")
        XCTAssertTrue(saved.autoImport); XCTAssertEqual(saved.queuePaused, true)
        try await store.finishTermination()
    }

    func testShutdownRefusesFailedSaveAndCanRetryAfterStorageRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-io-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GCSStore(storageDirectory: root)
        try await store.flushPersistedStateForMaintenance()
        let settings = root.appendingPathComponent("gcs-settings.json")
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        store.host = "durable.synthetic.local"; store.pauseQueue()
        do { try await store.finishTermination(); XCTFail("Shutdown must not confirm an unpersisted state.") } catch { }
        XCTAssertTrue(store.isQueuePaused)
        store.cancelTermination()
        let uuid = "0102030405060708090A0B0C"
        store.setAllowed(uuid: uuid, allowed: true)
        XCTAssertTrue(store.allowedUUIDs.contains(uuid), "Cancelling quit must restore normal commands while preserving the save error.")
        try FileManager.default.removeItem(at: settings)
        try await store.finishTermination()
        let saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: settings))
        XCTAssertEqual(saved.host, "durable.synthetic.local"); XCTAssertEqual(saved.queuePaused, true)
    }

}


extension GCSStoreTests {
    func testCollectRevalidatesVanishedDestinationBeforeLaunchingWork() async throws {
        let (store, root) = try fixture(mode: "normal")
        defer { store.stopForTermination(); try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("removable-volume")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try await store.setDownloadDirectory(destination)
        try await waitUntil { store.canCollectAll }
        try FileManager.default.removeItem(at: destination)
        XCTAssertNil(store.downloadDirectoryIssue, "Rendering uses the latest completed check, without touching the filesystem.")
        await store.collectAll()
        XCTAssertNotNil(store.downloadDirectoryIssue)
        XCTAssertTrue(store.errorMessage?.contains(destination.path) == true)
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await store.finishTermination()
    }

    func testStopDuringBlockedAdmissionDoesNotStartCollectorAfterWriteCompletes() async throws {
        let (store, root) = try fixture(mode: "normal", configure: false)
        defer { store.stopForTermination(); try? FileManager.default.removeItem(at: root) }
        store.host = "localhost"; store.autoImport = false; store.connect()
        try await waitUntil { store.canCollectAll }
        try await store.flushPersistedStateForMaintenance()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("gcs-queue.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let admission = Task { await store.collectAll() }
        try await Task.sleep(for: .milliseconds(350))
        store.stopCollection()
        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        await admission.value
        try await store.waitForPersistence()
        XCTAssertTrue(store.queue.isEmpty); XCTAssertTrue(store.isQueuePaused)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
        let fleet = try JSONDecoder().decode(GCSFleetObservationState.self, from: Data(contentsOf: root.appendingPathComponent("fleet.json")))
        XCTAssertEqual(Set(fleet.drones.filter(\.authorized).map(\.uuid)), store.allowedUUIDs)
        XCTAssertTrue(fleet.drones.allSatisfy { $0.lastSeenAtUTC != nil })
        store.disconnect()
        try await store.finishTermination()
    }

    func testRealProgressAndPersistenceAcrossLargeHistoryKeepMainActorResponsive() async throws {
        try await measureProgressAcrossLargeQueue(queued: false)
    }
    func testRealProgressAndPersistenceWithFiftyThousandPendingJobsKeepMainActorResponsive() async throws {
        try await measureProgressAcrossLargeQueue(queued: true)
    }
    private func measureProgressAcrossLargeQueue(queued: Bool) async throws {
        let offlineUUID = "2122232425262728292A2B2C"
        let (store, root) = try fixture(mode: "phases", configure: false, stateBuilder: { root in
            var state = GCSCollectionState(downloadDirectory: root.path)
            state.host = "localhost"; state.allowedUUIDs = [self.first, self.second, offlineUUID]
            state.autoImport = false; state.reconnect = false; state.currentBatchID = "history"
            state.queue = (0..<50_000).map { index in
                var item = GCSTransfer(droneUUID: queued ? offlineUUID : self.first, remotePath: "/history/\(index).ulg", size: 64,
                    host: "localhost", destination: root.path)
                item.batchID = "history"; item.state = queued ? "interrupted" : "downloaded"; item.completedBytes = queued ? 0 : 64
                return item
            }
            return state
        })
        defer { store.stopForTermination(); try? FileManager.default.removeItem(at: root) }
        try await store.flushPersistedStateForMaintenance()
        if queued {
            await store.retryFailed()
            try await store.waitForPersistence()
            XCTAssertEqual(store.queue.filter(\.isPending).count, 50_000)
        }
        let script = root.appendingPathComponent("collector.py")
        var source = try String(contentsOf: script, encoding: .utf8)
        source = source.replacingOccurrences(of: "    emit('transfer_started',uuid=u,path=p,timeoutSeconds=300)", with: """
            import sqlite3
            lock=sqlite3.connect(root/'gcs-queue.sqlite',timeout=10)
            lock.execute('BEGIN IMMEDIATE')
            emit('transfer_started',uuid=u,path=p,timeoutSeconds=300)
            time.sleep(1.2)
            lock.rollback();lock.close()
        """)
        try source.write(to: script, atomically: true, encoding: .utf8)
        var gaps: [Double] = [], sawDronePhase = false, sawHTTPPhase = false
        let observation = store.$queue.sink { items in
            sawDronePhase = sawDronePhase || items.suffix(4).contains { $0.phase == "drone" }
            sawHTTPPhase = sawHTTPPhase || items.suffix(4).contains { $0.phase == "http" }
        }
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                gaps.append(now - previous); previous = now
            }
        }
        defer { heartbeat.cancel(); observation.cancel() }
        let started = ProcessInfo.processInfo.systemUptime
        store.connect()
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil(timeout: 30) { store.batchProgress.completedCount == 4 && !store.isBusy }
        store.disconnect()
        try await store.flushPersistedStateForMaintenance()
        try await Task.sleep(for: .milliseconds(10))
        heartbeat.cancel(); await heartbeat.value
        let elapsed = ProcessInfo.processInfo.systemUptime - started, gap = gaps.max() ?? 0
        print("GCS_REAL_PROGRESS stored=50000 pending=\(queued ? 50000 : 0) jobs=4 sqliteLockSeconds=1.2 seconds=\(elapsed) heartbeatMaxMs=\(gap * 1000)")
        XCTAssertTrue(sawDronePhase); XCTAssertTrue(sawHTTPPhase)
        XCTAssertLessThan(gap, 0.5, "Real transfer progress and durable saves must not run SQLite on MainActor.")
        let repository = try GCSQueueRepository(url: root.appendingPathComponent("gcs-queue.sqlite"), readOnly: true)
        XCTAssertEqual(try repository.transferCount(), 50_004)
        let saved = GCSStore(storageDirectory: root)
        XCTAssertEqual(saved.batchProgress.completedCount, 4)
    }
}
