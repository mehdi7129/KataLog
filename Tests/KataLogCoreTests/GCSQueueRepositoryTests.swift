import Foundation
import SQLite3
import XCTest
@testable import KataLogCore

final class GCSQueueRepositoryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func job(_ index: Int, state: String = "complete", batch: String = "batch") -> GCSTransfer {
        var item = GCSTransfer(droneUUID: String(format: "%024X", index % 500 + 1),
                               remotePath: "/fs/microsd/log/session/\(index).ulg", size: 100,
                               host: "gcs.local", destination: "/private/tmp/collection")
        item.id = "transfer-\(index)"; item.state = state; item.batchID = batch
        item.completedBytes = state == "complete" ? 100 : 0
        return item
    }

    func testUpsertsOnlyChangedTransfersAndPersistsPhaseAcrossReopening() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.sqlite")
        let repository = try GCSQueueRepository(url: url)
        var item = job(1, state: "downloading")
        XCTAssertEqual(try repository.saveTransfers([item]), 1)
        XCTAssertEqual(try repository.saveTransfers([item]), 0)
        item.receiveProgress(phase: "http", bytes: 30, total: 100)
        XCTAssertEqual(try repository.saveTransfers([item]), 1)
        let reopened = try GCSQueueRepository(url: url, readOnly: true)
        XCTAssertEqual(try reopened.transfer(id: item.id)?.phase, "http")
        XCTAssertEqual(try reopened.transfer(id: item.id)?.completedBytes, 30)
        XCTAssertEqual(try reopened.batchProgress(id: "batch").fraction, 0.65)
        XCTAssertThrowsError(try reopened.saveTransfers([item]))
    }

    func testDiagnosticCountsCompleteHistoryAndUnsavedJobsBeyondUIWindow() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.sqlite")
        let repository = try GCSQueueRepository(url: url)
        let stored = (0..<700).map { job($0) }
        try repository.saveTransfers(stored)
        XCTAssertEqual(try repository.retainedTransfers().count, 200)
        XCTAssertEqual(try repository.transferCount(), 700)
        let new = job(701, state: "queued")
        XCTAssertEqual(try repository.transferCount(overlay: [stored[0], new, new]), 701)
        try repository.saveTransfers([new])
        let reopened = try GCSQueueRepository(url: url, readOnly: true)
        XCTAssertEqual(try reopened.transferCount(overlay: [new]), 701)
    }

    func testPersistedAndLiveOverlayWorkMatchAcrossDroneHTTPVerificationAndCompletion() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.sqlite")
        let repository = try GCSQueueRepository(url: url)
        var small = job(1, state: "downloading")
        var large = GCSTransfer(droneUUID: job(2).droneUUID, remotePath: "/large.ulg", size: 900,
                               host: "gcs.local", destination: "/tmp")
        large.batchID = "batch"; large.state = "downloading"
        small.receiveProgress(phase: "drone", bytes: 50, total: 100)
        large.receiveProgress(phase: "drone", bytes: 450, total: 900)
        try repository.saveTransfers([small, large])
        assertProgressEqual(try repository.batchProgress(id: "batch"), GCSBatchProgress(transfers: [small, large]))
        small.receiveProgress(phase: "http", bytes: 30, total: 100)
        large.receiveProgress(phase: "http", bytes: 450, total: 900)
        let live = try repository.batchProgress(id: "batch", overlay: [small, large, large])
        assertProgressEqual(live, GCSBatchProgress(transfers: [small, large]))
        XCTAssertEqual(live.fraction, 0.74, accuracy: 0.000001)
        XCTAssertEqual(live.completedBytes, 480)
        try repository.saveTransfers([small, large])
        let reopened = try GCSQueueRepository(url: url, readOnly: true)
        assertProgressEqual(try reopened.batchProgress(id: "batch"), live)
        for itemIndex in 0..<2 {
            if itemIndex == 0 {
                small.completedBytes = small.size; small.phase = "verification"; small.state = "importing"
            } else {
                large.completedBytes = large.size; large.phase = "import"; large.state = "importing"
            }
        }
        XCTAssertEqual(try repository.batchProgress(id: "batch", overlay: [small, large]).fraction, 0.99)
        small.state = "complete"; large.state = "downloaded"
        try repository.saveTransfers([small, large])
        XCTAssertEqual(try reopened.batchProgress(id: "batch").fraction, 1)
    }

    func testStopRetryLegacyAndMalformedCountersAgreeWithInMemoryProgress() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GCSQueueRepository(url: root.appendingPathComponent("queue.sqlite"))
        var legacy = job(1, state: "downloading"); legacy.completedBytes = 25
        var stopped = job(2, state: "stopped"); stopped.receiveProgress(phase: "http", bytes: 100, total: 100)
        var retry = job(3, state: "retrying"); retry.receiveProgress(phase: "http", bytes: 80, total: 100)
        var malformed = job(4, state: "downloading")
        malformed.phase = "drone"; malformed.phaseBytes = -1; malformed.phaseTotal = 0
        let items = [legacy, stopped, retry, malformed]
        try repository.saveTransfers(items)
        assertProgressEqual(try repository.batchProgress(id: "batch"), GCSBatchProgress(transfers: items))
        XCTAssertEqual(try repository.batchProgress(id: "batch").fraction, 0.31)
        stopped.state = "queued"
        let updated = [legacy, stopped, retry, malformed]
        assertProgressEqual(try repository.batchProgress(id: "batch", overlay: [stopped]), GCSBatchProgress(transfers: updated))
        try repository.saveTransfers([stopped])
        assertProgressEqual(try repository.batchProgress(id: "batch"), GCSBatchProgress(transfers: updated))

        var hugeA = GCSTransfer(droneUUID: job(5).droneUUID, remotePath: "/huge-a.ulg", size: Int64.max, host: "gcs.local", destination: "/tmp")
        hugeA.batchID = "huge"; hugeA.state = "downloading"
        hugeA.phase = "drone"; hugeA.phaseBytes = Int64.max; hugeA.phaseTotal = Int64.max
        var hugeB = GCSTransfer(droneUUID: job(6).droneUUID, remotePath: "/huge-b.ulg", size: Int64.max, host: "gcs.local", destination: "/tmp")
        hugeB.batchID = "huge"; hugeB.state = "downloading"
        hugeB.phase = "drone"; hugeB.phaseBytes = Int64.max; hugeB.phaseTotal = Int64.max
        try repository.saveTransfers([hugeA, hugeB])
        assertProgressEqual(try repository.batchProgress(id: "huge"), GCSBatchProgress(transfers: [hugeA, hugeB]))
    }

    func testEveryStateAndPhaseKeepsItsCategoriesAndProgressInSQLiteAndJSON() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.sqlite")
        let repository = try GCSQueueRepository(url: url)
        let states = [
            ("queued", "pending"), ("retrying", "pending"),
            ("downloading", "active"), ("importing", "active"),
            ("downloaded", "success"), ("complete", "success"),
            ("failed", "failed"), ("interrupted", "failed"), ("stopped", "stopped"),
            ("future' OR 1=1;--", "unknown"), ("", "unknown")
        ]
        let phases: [(String?, Double)] = [
            (nil, 0.4), ("drone", 0.15), ("http", 0.7), ("verification", 0.4),
            ("verified", 0.4), ("import", 0.4), ("future-phase", 0.4), ("", 0.4)
        ]
        XCTAssertEqual(Set(GCSTransferState.allCases.map(\.rawValue)), Set(states.filter { $0.1 != "unknown" }.map(\.0)))
        XCTAssertEqual(Set(GCSTransferPhase.allCases.map(\.rawValue)), ["drone", "http", "verification", "verified", "import"])
        var items: [GCSTransfer] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (state, category) in states {
            for (phase, partialWork) in phases {
                var item = job(items.count, state: state, batch: "case-\(items.count)")
                item.phase = phase; item.phaseBytes = 30; item.phaseTotal = 100; item.completedBytes = 40
                let memory = GCSBatchProgress(transfers: [item])
                XCTAssertEqual(item.isPending, category == "pending")
                XCTAssertEqual(item.isActive, category == "active")
                XCTAssertEqual(item.isSuccessful, category == "success")
                XCTAssertEqual(memory.completedCount, category == "success" ? 1 : 0)
                XCTAssertEqual(memory.failedCount, category == "failed" ? 1 : 0)
                XCTAssertEqual(memory.stoppedCount, category == "stopped" ? 1 : 0)
                let expectedWork = category == "success" ? 1 : (category == "pending" ? 0 : partialWork)
                XCTAssertEqual(memory.fraction, expectedWork, accuracy: 0.000001)
                items.append(item)
            }
        }
        try repository.saveTransfers(items)
        let reopened = try GCSQueueRepository(url: url, readOnly: true)
        for item in items {
            assertProgressEqual(try reopened.batchProgress(id: try XCTUnwrap(item.batchID)), GCSBatchProgress(transfers: [item]))
            let restored = try XCTUnwrap(reopened.transfer(id: item.id))
            XCTAssertEqual(try encoder.encode(restored), try encoder.encode(item), "Raw states/phases, including unknown values, must round-trip without normalization.")
        }
        let retryable = items.filter { ["failed", "interrupted", "stopped"].contains($0.state) }
        XCTAssertEqual(try reopened.retryableTransfers().map(\.id), retryable.map(\.id))
        XCTAssertEqual(try reopened.retryableCount(authorizedUUIDs: Set(items.map(\.droneUUID))), retryable.count)
        XCTAssertEqual(try reopened.retainedTransfers(terminalLimit: 0).map(\.id), items.filter { $0.isPending || $0.isActive }.map(\.id))
    }

    func testUnknownLegacyStringsAndMissingPhasePreserveExactJSONFields() throws {
        for phase in [nil, "future-transport"] as [String?] {
            var fields: [String: Any] = [
                "id": "legacy", "droneUUID": "0102030405060708090A0B0C", "remotePath": "/legacy.ulg",
                "size": 100, "host": "gcs.local", "destination": "/tmp/collection",
                "completedBytes": 40, "state": "future-state"
            ]
            if let phase { fields["phase"] = phase }
            var item = try JSONDecoder().decode(GCSTransfer.self, from: JSONSerialization.data(withJSONObject: fields))
            item.recoverAfterRelaunch()
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? NSDictionary)
            XCTAssertEqual(encoded, fields as NSDictionary)
            XCTAssertEqual(item.workFraction, 0.4)
        }
    }

    func testSuccessfulAndQueuedHistoryAggregateDoesNotReadTheirPayloadsOrMigrateSchema() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.sqlite")
        let repository = try GCSQueueRepository(url: url)
        let items = (0..<1_000).map { job($0, state: $0 < 800 ? "complete" : "queued") }
        try repository.saveTransfers(items)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        // A payload read/JSON decode would fail: this proves the fast CASE branches
        // use indexed scalar data for the large, fully processed history.
        XCTAssertEqual(sqlite3_exec(database, "UPDATE transfers SET payload=X'000102'", nil, nil, nil), SQLITE_OK)
        let progress = try repository.batchProgress(id: "batch")
        XCTAssertEqual(progress.fraction, 0.8)
        XCTAssertEqual(progress.totalCount, 1_000)
        XCTAssertEqual(progress.completedCount, 800)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
    }

    private func assertProgressEqual(_ actual: GCSBatchProgress, _ expected: GCSBatchProgress,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.fraction, expected.fraction, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.completedWorkBytes, expected.completedWorkBytes, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.totalBytes, expected.totalBytes, file: file, line: line)
        XCTAssertEqual(actual.completedBytes, expected.completedBytes, file: file, line: line)
        XCTAssertEqual(actual.completedCount, expected.completedCount, file: file, line: line)
        XCTAssertEqual(actual.totalCount, expected.totalCount, file: file, line: line)
        XCTAssertEqual(actual.failedCount, expected.failedCount, file: file, line: line)
        XCTAssertEqual(actual.stoppedCount, expected.stoppedCount, file: file, line: line)
        XCTAssertEqual(actual.pendingCount, expected.pendingCount, file: file, line: line)
        XCTAssertEqual(actual.activeCount, expected.activeCount, file: file, line: line)
    }

    func testFiveHundredDroneHistoryIsPagedButActiveJobsAndRemoteBusyGuardsAreRetained() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GCSQueueRepository(url: root.appendingPathComponent("queue.sqlite"))
        var items = (0..<1_500).map { job($0) }
        for index in 0..<300 { items[index].state = "queued"; items[index].completedBytes = 0 }
        items[300].state = "stopped"; items[300].remoteBusyUntil = Date().addingTimeInterval(600)
        items[301].state = "failed"
        XCTAssertEqual(try repository.saveTransfers(items), 1_500)
        let retained = try repository.retainedTransfers(terminalLimit: 20)
        XCTAssertEqual(retained.count, 321)
        XCTAssertEqual(retained.filter(\.isPending).count, 300)
        XCTAssertTrue(retained.contains { $0.id == items[300].id })
        XCTAssertEqual(try repository.retryableTransfers().count, 2)
        XCTAssertEqual(try repository.retryableCount(authorizedUUIDs: [items[301].droneUUID]), 1)
        XCTAssertEqual(try repository.retryableTransfers(authorizedUUIDs: []).count, 0)
        var cursor: Int64?; var collected: [String] = []
        repeat {
            let page = try repository.historyPage(before: cursor, limit: 137)
            XCTAssertLessThanOrEqual(page.transfers.count, 137)
            collected += page.transfers.map(\.id); cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(collected.count, items.count)
        XCTAssertEqual(Set(collected).count, items.count)
        XCTAssertEqual(collected.first, items.last?.id)
        let progress = try repository.batchProgress(id: "batch")
        XCTAssertEqual(progress.totalCount, 1_500)
        XCTAssertEqual(progress.pendingCount, 300)
        XCTAssertEqual(progress.failedCount, 1)
        XCTAssertEqual(progress.stoppedCount, 1)
        XCTAssertEqual(progress.completedCount, 1_198)
        var dirty = items[0]; dirty.receiveProgress(phase: "http", bytes: 40, total: 100)
        XCTAssertEqual(try repository.batchProgress(id: "batch", overlay: [dirty]).completedBytes, progress.completedBytes + 40)
    }

    func testLegacyMigrationIsAtomicIdempotentAndIndexedSourceLookupUsesBoundParameters() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GCSQueueRepository(url: root.appendingPathComponent("queue.sqlite"))
        let item = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/fs/microsd/log/quote' OR 1=1;--.ulg", size: 100,
                               host: "gcs.local", destination: "/private/tmp/collection")
        XCTAssertFalse(try repository.hasMigratedLegacy)
        try repository.migrateLegacy([item])
        XCTAssertTrue(try repository.hasMigratedLegacy)
        try repository.migrateLegacy([job(2)])
        XCTAssertEqual(try repository.historyPage().transfers.map(\.id), [item.id])
        XCTAssertEqual(try repository.matchingTransfer(uuid: item.droneUUID, path: item.remotePath, size: item.size, destination: item.destination)?.id, item.id)
        XCTAssertNil(try repository.matchingTransfer(uuid: item.droneUUID, path: "' OR 1=1;--", size: item.size, destination: item.destination))
        XCTAssertEqual(try repository.recordCachedFiles(batchID: "batch", identities: ["one", "two"]), 2)
        XCTAssertEqual(try repository.recordCachedFiles(batchID: "batch", identities: ["two", "three"]), 3)
        XCTAssertEqual(try repository.recordCachedFiles(batchID: "next", identities: ["two"]), 1)
    }

    func testFutureDatabaseSchemaIsRejectedWithoutChangingItsVersion() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try GCSQueueRepository(url: url))
        XCTAssertThrowsError(try GCSQueueRepository(url: url, readOnly: true))
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 999)
        sqlite3_finalize(statement); sqlite3_close(db)
    }
}
