import Foundation
import SQLite3
import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class GCSCountStateTests: XCTestCase {
    private let uuid = "0102030405060708090A0B0C"
    private func fixture(count: Int = 500, state: String = "failed") throws -> (GCSStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-counts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var settings = GCSCollectionState(downloadDirectory: root.path)
        settings.allowedUUIDs = [uuid]; settings.currentBatchID = "fixture-batch"
        settings.host = "synthetic-gcs.local"; settings.autoImport = false; settings.reconnect = false; settings.queueStorageVersion = 1
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("gcs-settings.json"))
        let repository = try GCSQueueRepository(url: root.appendingPathComponent("gcs-queue.sqlite"))
        try repository.migrateLegacy([])
        let jobs = (0..<count).map { index in
            var item = GCSTransfer(droneUUID: uuid, remotePath: "/fixture/\(index).ulg", size: 100,
                                   host: "synthetic-gcs.local", destination: root.path)
            item.state = state; item.batchID = "fixture-batch"
            return item
        }
        _ = try repository.saveTransfers(jobs)
        let store = GCSStore(storageDirectory: root)
        try store.flushPersistedStateForMaintenance()
        return (store, root)
    }
    private func sql(_ sql: String, root: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("gcs-queue.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AnalysisError.engine(String(cString: sqlite3_errmsg(database)))
        }
    }
    func testUnavailableRepositoryKeepsFullCountsAndRetryRecoversWholeHistory() throws {
        let (store, root) = try fixture()
        XCTAssertEqual(store.queue.count, 200)
        XCTAssertEqual(store.retryableCount, 500)
        XCTAssertEqual(store.batchProgress.totalCount, 500)
        try sql("ALTER TABLE transfers RENAME TO unavailable_transfers", root: root)
        store.retryFailed()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.retryableCount, 500, "The retained 200 rows are not the full history.")
        XCTAssertEqual(store.batchProgress.totalCount, 500)
        XCTAssertFalse(store.batchStatusMessage.contains("terminée"))
        XCTAssertNotNil(store.countsError)
        XCTAssertFalse(store.countsAreCurrent)
        XCTAssertNil(store.diagnosticJobCount)
        try sql("ALTER TABLE unavailable_transfers RENAME TO transfers", root: root)
        store.retryFailed()
        XCTAssertEqual(store.queue.filter(\.isPending).count, 500)
        XCTAssertEqual(store.retryableCount, 0)
        XCTAssertEqual(store.batchProgress.totalCount, 500)
        XCTAssertEqual(store.batchProgress.pendingCount, 500)
        XCTAssertTrue(store.countsAreCurrent)
        XCTAssertNil(store.countsError)
        XCTAssertEqual(store.diagnosticJobCount, 500)
    }
    func testUnavailableReadCannotReuseCompleteProgressAfterNewOverlay() async throws {
        let (store, root) = try fixture(count: 1, state: "complete")
        XCTAssertEqual(store.collectionFraction, 1)
        try sql("ALTER TABLE transfers RENAME TO unavailable_transfers", root: root)
        let added = try await store.enqueue([GCSLogFile(path: "/fixture/0.ulg", size: 100)], uuid: uuid,
                                            host: "synthetic-gcs.local", destination: root.path)
        XCTAssertEqual(added, 1)
        XCTAssertFalse(store.countsAreCurrent, "A new overlay invalidates completion immediately, before refresh.")
        XCTAssertLessThan(store.collectionFraction, 1)
        store.refreshQueueCounts()
        XCTAssertEqual(store.queue.first?.state, "queued")
        XCTAssertEqual(store.batchProgress.completedCount, 1, "Keep the explicit last snapshot, labelled unavailable.")
        XCTAssertFalse(store.countsAreCurrent)
        XCTAssertNotNil(store.countsReadMessage)
        XCTAssertLessThan(store.collectionFraction, 1)
        XCTAssertFalse(store.batchStatusMessage.contains("terminée"))
        try sql("ALTER TABLE unavailable_transfers RENAME TO transfers", root: root)
        store.refreshQueueCounts()
        XCTAssertTrue(store.countsAreCurrent)
        XCTAssertEqual(store.batchProgress.completedCount, 0)
        XCTAssertEqual(store.batchProgress.pendingCount, 1)
        XCTAssertEqual(store.diagnosticJobCount, 1)
    }

    func testUnavailableReadDoesNotReuseAnotherAuthorizedFleetSnapshot() throws {
        let (store, root) = try fixture()
        try sql("ALTER TABLE transfers RENAME TO unavailable_transfers", root: root)
        store.setAllowed(uuid: uuid, allowed: false)
        XCTAssertTrue(store.allowedUUIDs.isEmpty)
        XCTAssertFalse(store.hasQueueCounts, "A snapshot for the previous fleet cannot describe the new selection.")
        XCTAssertFalse(store.countsAreCurrent)
        XCTAssertNotNil(store.countsReadMessage)
        try sql("ALTER TABLE unavailable_transfers RENAME TO transfers", root: root)
        store.refreshQueueCounts()
        XCTAssertTrue(store.countsAreCurrent)
        XCTAssertEqual(store.retryableCount, 0)
        XCTAssertEqual(store.batchProgress.totalCount, 500)
    }

    func testBatchChangeAndRestoreDoNotReuseOldCounts() throws {
        let (store, root) = try fixture(count: 500, state: "complete")
        let destination = root.appendingPathComponent("new-destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try store.setDownloadDirectory(destination)
        XCTAssertTrue(store.countsAreCurrent)
        XCTAssertEqual(store.batchProgress.totalCount, 0)
        XCTAssertEqual(store.collectionFraction, 0)
        try sql("ALTER TABLE transfers RENAME TO unavailable_transfers", root: root)
        store.refreshQueueCounts()
        XCTAssertEqual(store.batchProgress.totalCount, 0, "Old batch totals must not reappear when the new batch cannot be read.")
        XCTAssertFalse(store.countsAreCurrent)
        XCTAssertThrowsError(try store.reloadPersistedStateAfterRestore())
        XCTAssertFalse(store.hasQueueCounts, "Even the same batch ID cannot reuse a snapshot from before a failed restore.")
        XCTAssertNotNil(store.countsError)
    }

    func testRestoredCountsRefreshAfterMaintenanceGateReleases() async throws {
        let (store, root) = try fixture()
        let library = LibraryStore(storageDirectory: root)
        store.attach(library: library)
        defer { store.stopForTermination(); library.prepareForTermination() }
        XCTAssertTrue(store.countsAreCurrent)
        try await library.performMaintenance {
            try store.preparePersistedStorageForRestore()
            try store.reloadPersistedStateAfterRestore()
            XCTAssertFalse(store.countsAreCurrent)
            XCTAssertFalse(store.hasQueueCounts, "Restoration must discard the previous snapshot even when its selection is unchanged.")
            XCTAssertNil(store.diagnosticJobCount)
        }
        let deadline = Date().addingTimeInterval(3)
        while !store.countsAreCurrent, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.countsAreCurrent, "The existing refresh timer must resume full reads after maintenance.")
        XCTAssertEqual(store.retryableCount, 500)
        XCTAssertEqual(store.batchProgress.totalCount, 500)
        XCTAssertEqual(store.diagnosticJobCount, 500)
    }

}
