import Foundation
import XCTest
import KataLogCore
@testable import KataLog

extension GCSStoreTests {
    func testCollectionActivityCoversInventoryTransferAndPendingRetryUntilPausedOrStopped() async throws {
        let (store, root) = try fixture(mode: "retry")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        XCTAssertFalse(store.preventsIdleSystemSleep, "Discovery alone must not keep the Mac awake.")
        await store.selectDrone(first)
        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.preventsIdleSystemSleep)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        XCTAssertFalse(store.preventsIdleSystemSleep, "A completed inventory with no requested download must release its activity.")
        let log = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        store.downloadFile(log)
        XCTAssertTrue(store.preventsIdleSystemSleep)
        try await waitUntil {
            !store.isBusy && store.queue.count == 1 && store.queue.first?.state == "retrying"
        }
        XCTAssertEqual(store.queue.first?.attemptCount, 1)
        XCTAssertEqual(store.activeTransferCount, 0)
        XCTAssertTrue(store.preventsIdleSystemSleep, "The Mac must remain awake while an automatic retry waits for its deadline.")
        store.pauseQueue()
        XCTAssertFalse(store.preventsIdleSystemSleep)
        XCTAssertEqual(store.queue.first?.state, "retrying", "Pause must retain the pending work.")
        store.resumeQueue()
        XCTAssertTrue(store.preventsIdleSystemSleep)
        store.stopCollection()
        XCTAssertEqual(store.queue.first?.state, "stopped")
        try await waitUntil { !store.isBusy && store.queue.first?.state == "stopped" }
        XCTAssertFalse(store.preventsIdleSystemSleep)
    }

    func testCollectionActivityDrainsActiveTransferOnPauseAndReleasesAfterCompletion() async throws {
        let (store, root) = try fixture(mode: "phases-gated")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        store.downloadFile(try XCTUnwrap(store.files.first))
        try await waitUntil { store.activeTransferCount == 1 && store.queue.first?.phase == "drone" }
        store.pauseQueue()
        XCTAssertTrue(store.isQueuePaused)
        XCTAssertTrue(store.preventsIdleSystemSleep, "Pause lets the current file finish, so it must retain the activity until then.")
        for phase in ["drone", "http", "complete"] {
            try Data().write(to: root.appendingPathComponent("\(phase)-\(first)"))
        }
        try await waitUntil { !store.isBusy && store.queue.count == 1 && store.queue.allSatisfy(\.isSuccessful) }
        XCTAssertFalse(store.preventsIdleSystemSleep)
        store.resumeQueue()
        XCTAssertFalse(store.preventsIdleSystemSleep, "Resuming an empty pending queue must not prevent sleep.")
    }

    func testCollectionActivityReleasesImmediatelyWhenTerminationCancelsActiveWork() async throws {
        let (store, root) = try fixture(mode: "phases-gated")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        store.downloadFile(try XCTUnwrap(store.files.first))
        try await waitUntil { store.activeTransferCount == 1 && store.queue.first?.phase == "drone" }
        XCTAssertTrue(store.preventsIdleSystemSleep)
        store.stopForTermination()
        XCTAssertFalse(store.preventsIdleSystemSleep, "The application must release its assertion without waiting for worker cleanup.")
        try await store.finishTermination()
        XCTAssertFalse(store.preventsIdleSystemSleep)
        store.cancelTermination()
        XCTAssertFalse(store.preventsIdleSystemSleep, "Cancelling quit must not silently restart interrupted collection activity.")
    }
}
