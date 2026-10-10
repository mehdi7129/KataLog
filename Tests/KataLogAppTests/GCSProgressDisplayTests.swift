import Foundation
import SQLite3
import XCTest
import KataLogCore
@testable import KataLog

extension GCSStoreTests {
    func testHTTPResumeFallbackResetsReceivedBytesAndMeasuresOnlyNewTraffic() async throws {
        let (store, root) = try fixture(mode: "phases-gated")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        let script = root.appendingPathComponent("collector.py")
        let original = try String(contentsOf: script, encoding: .utf8)
        let httpStart = """
            emit('phase',uuid=u,path=p,bytes=0,total=64,phase='http')
            emit('progress',uuid=u,path=p,bytes=8,total=64,phase='http')
        """
        XCTAssertTrue(original.contains(httpStart), "The synthetic collector must expose its HTTP entry point.")
        let resumedHTTP = """
            emit('phase',uuid=u,path=p,bytes=48,total=64,phase='http')
            wait_phase('fallback',u)
            # A server returning HTTP 200 to Range restarts this representation.
            emit('phase',uuid=u,path=p,bytes=0,total=64,phase='http')
            wait_phase('copied',u)
            time.sleep(.1)
            emit('progress',uuid=u,path=p,bytes=8,total=64,phase='http')
        """
        try original.replacingOccurrences(of: httpStart, with: resumedHTTP)
            .write(to: script, atomically: true, encoding: .utf8)
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        let requested = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        store.downloadFile(requested)
        try Data().write(to: root.appendingPathComponent("drone-\(first)"))
        try Data().write(to: root.appendingPathComponent("http-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phase == "http" && store.transfer(for: requested)?.phaseBytes == 48 }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.transfer(for: requested)?.completedBytes, 48)
        XCTAssertEqual(store.batchProgress.completedBytes, 48)
        XCTAssertEqual(store.batchProgress.completedCount, 0, "A validated partial offset is not a verified complete file.")
        XCTAssertNil(store.transferRateText, "The existing 48 bytes must not become a burst of new network traffic.")

        try Data().write(to: root.appendingPathComponent("fallback-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phase == "http" && store.transfer(for: requested)?.phaseBytes == 0 }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.transfer(for: requested)?.completedBytes, 0)
        XCTAssertEqual(store.batchProgress.completedBytes, 0, "HTTP 200 starts a fresh copy; the discarded offset cannot remain in the received-byte count.")
        XCTAssertNil(store.transferRateText)

        try Data().write(to: root.appendingPathComponent("copied-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phaseBytes == 8 && store.transferRateText != nil }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.transfer(for: requested)?.completedBytes, 8)
        XCTAssertEqual(store.batchProgress.completedBytes, 8)
        XCTAssertEqual(store.transfer(for: requested)?.phaseProgress, 0.125)
        let rate = try XCTUnwrap(store.transferRateText)
        XCTAssertTrue(rate.hasPrefix("GCS → Mac"))
        XCTAssertFalse(rate.contains("Drone → GCS"))
        let zeroRate = "GCS → Mac · \(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))/s"
        XCTAssertNotEqual(rate, zeroRate, "A fresh chunk below the old offset must still produce a positive HTTP rate.")

        try Data().write(to: root.appendingPathComponent("complete-\(first)"))
        try await waitUntil { !store.isBusy && store.queue.count == 1 && store.queue.allSatisfy(\.isSuccessful) }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.batchProgress.completedCount, 1)
        XCTAssertEqual(store.batchProgress.completedBytes, 64)
        XCTAssertEqual(store.collectionFraction, 1)
        XCTAssertNil(store.transferRateText, "A completed worker cannot keep publishing an old transfer speed.")
    }

    func testHTTPStagingReplacementClearsOldBytesAndRateBeforeRequestingDroneAgain() async throws {
        let (store, root) = try fixture(mode: "phases-gated")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        let script = root.appendingPathComponent("collector.py")
        let original = try String(contentsOf: script, encoding: .utf8)
        let httpStart = """
            emit('phase',uuid=u,path=p,bytes=0,total=64,phase='http')
            emit('progress',uuid=u,path=p,bytes=8,total=64,phase='http')
        """
        XCTAssertTrue(original.contains(httpStart))
        let replacedStaging = """
            emit('phase',uuid=u,path=p,bytes=48,total=64,phase='http')
            time.sleep(.1)
            emit('progress',uuid=u,path=p,bytes=56,total=64,phase='http')
            wait_phase('restage',u)
            # A changed staging representation requires another drone transfer.
            emit('transfer_started',uuid=u,path=p,timeoutSeconds=300)
            wait_phase('restagedrone',u)
            emit('progress',uuid=u,path=p,bytes=16,total=64,phase='drone')
            wait_phase('freshhttp',u)
            emit('transfer_finished',uuid=u,path=p)
            emit('phase',uuid=u,path=p,bytes=0,total=64,phase='http')
            emit('progress',uuid=u,path=p,bytes=8,total=64,phase='http')
        """
        try original.replacingOccurrences(of: httpStart, with: replacedStaging)
            .write(to: script, atomically: true, encoding: .utf8)
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        let requested = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        store.downloadFile(requested)
        try Data().write(to: root.appendingPathComponent("drone-\(first)"))
        try Data().write(to: root.appendingPathComponent("http-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phaseBytes == 56 && store.transferRateText != nil }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.batchProgress.completedBytes, 56)
        XCTAssertTrue(try XCTUnwrap(store.transferRateText).contains("GCS → Mac"))

        try Data().write(to: root.appendingPathComponent("restage-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phase == "drone" && store.transfer(for: requested)?.phaseBytes == 0 }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.transfer(for: requested)?.completedBytes, 0)
        XCTAssertEqual(store.batchProgress.completedBytes, 0, "Discarding the staging copy must discard its Mac-byte baseline too.")
        XCTAssertNil(store.transferRateText, "A new drone transfer cannot retain the previous HTTP speed.")
        try Data().write(to: root.appendingPathComponent("restagedrone-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phaseBytes == 16 }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.transfer(for: requested)?.phase, "drone")
        XCTAssertEqual(store.transfer(for: requested)?.phaseProgress, 0.25)
        XCTAssertEqual(store.batchProgress.completedBytes, 0, "New drone traffic is not data received on this Mac.")
        XCTAssertFalse(store.transferRateText?.contains("GCS → Mac") ?? false)

        try Data().write(to: root.appendingPathComponent("freshhttp-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phase == "http" && store.transfer(for: requested)?.completedBytes == 8 }
        try Data().write(to: root.appendingPathComponent("complete-\(first)"))
        try await waitUntil { !store.isBusy && store.queue.count == 1 && store.queue.allSatisfy(\.isSuccessful) }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.batchProgress.completedCount, 1)
        XCTAssertEqual(store.batchProgress.completedBytes, 64)
        XCTAssertNil(store.transferRateText)
    }

    func testLiveTransferKeepsProgressAndStatusWhileCountsWaitForPersistence() async throws {
        let (store, root) = try fixture(mode: "phases-gated")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        let requested = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        store.downloadFile(requested)
        try Data().write(to: root.appendingPathComponent("drone-\(first)"))
        try await waitUntil { store.transfer(for: requested)?.phase == "drone" && store.transfer(for: requested)?.phaseBytes == 64 }
        try await store.waitForPersistence()
        await store.waitForQueueCounts()
        let visibleFraction = store.collectionFraction
        let visibleStatus = store.batchStatusMessage
        XCTAssertGreaterThan(visibleFraction, 0)
        XCTAssertLessThan(visibleFraction, 1)
        XCTAssertTrue(store.countsAreCurrent)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("gcs-queue.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        // The real transfer_finished event saves before its HTTP events. Holding
        // this writer transaction delays that save and the ordered count read,
        // while the collector continues to report actual transport progress.
        try Data().write(to: root.appendingPathComponent("http-\(first)"))
        try await waitUntil(timeout: 2) {
            store.transfer(for: requested)?.phase == "http" &&
                store.transfer(for: requested)?.phaseBytes == 8 && !store.countsAreCurrent
        }
        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.hasDisplayableProgress)
        XCTAssertNil(store.countsReadMessage)
        XCTAssertEqual(store.collectionFraction, visibleFraction, "Refreshing the same batch must not flash an empty bar.")
        XCTAssertEqual(store.batchStatusMessage, visibleStatus, "A count refresh must not replace the active-transfer status.")
        XCTAssertEqual(store.transfer(for: requested)?.completedBytes, 8, "The collector must continue updating while persistence waits.")

        XCTAssertEqual(sqlite3_exec(database, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await store.waitForPersistence()
        await store.waitForQueueCounts()
        XCTAssertTrue(store.countsAreCurrent)
        XCTAssertGreaterThan(store.collectionFraction, visibleFraction)
        XCTAssertEqual(store.batchProgress.completedBytes, 8)
        try Data().write(to: root.appendingPathComponent("complete-\(first)"))
        try await waitUntil { !store.isBusy && store.queue.count == 1 && store.queue.allSatisfy(\.isSuccessful) }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.collectionFraction, 1)
    }
}
