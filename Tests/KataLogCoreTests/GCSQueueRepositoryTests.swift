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
        XCTAssertThrowsError(try reopened.saveTransfers([item]))
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
