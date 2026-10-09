import Foundation
import XCTest
import KataLogCore
@testable import KataLog

extension GCSStoreTests {
    func testInventoryOnlyWaitKeepsMacAwakeAndCanBePausedAndResumed() async throws {
        let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "retry"])
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 }
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertTrue(store.preventsIdleSystemSleep, "An inventory-only wait must keep an unattended collection alive.")
        XCTAssertTrue(store.canStopCollection)
        XCTAssertFalse(store.canCollectAll, "Starting a second batch must not replace the pending inventory context.")
        XCTAssertNotNil(store.inventoryRetryMessage)

        store.pauseQueue()
        XCTAssertTrue(store.isQueuePaused)
        XCTAssertFalse(store.preventsIdleSystemSleep)
        XCTAssertTrue(store.canStopCollection, "A paused inventory must remain stoppable even without queued files.")
        XCTAssertTrue(store.batchStatusMessage.contains("pause"))
        clock.advance()
        try await waitForInventoryDiscoveryCycles(store)
        XCTAssertEqual(inventoryAttempts(first, in: root), 1, "Telemetry and elapsed backoff must not bypass pause.")

        try FileManager.default.removeItem(at: root.appendingPathComponent("inventory-failure-\(first)"))
        store.resumeQueue()
        XCTAssertFalse(store.isQueuePaused)
        XCTAssertTrue(store.preventsIdleSystemSleep)
        try await waitUntil {
            !store.isBusy && store.pendingInventoryRetryCount == 0 && store.queue.count == 2 && store.queue.allSatisfy(\.isSuccessful)
        }
        XCTAssertEqual(inventoryAttempts(first, in: root), 2)
        XCTAssertFalse(store.preventsIdleSystemSleep)
    }

    func testInventoryReconnectKeepsCapturedClientAndDestination() async throws {
        let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "retry"])
        try await waitUntil { store.canCollectAll }
        let originalDestination = store.downloadDirectory
        await store.collectAll()
        try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 }
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.collectionClientID, "CAPTURED-INVENTORY")
        store.chooseCollectionClient("")
        XCTAssertEqual(store.collectionClientID, "", "A later client selection applies to future requests, not the pending collection.")

        let replacement = root.appendingPathComponent("replacement-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        do {
            try await store.setDownloadDirectory(replacement)
            XCTFail("A pending inventory must prevent changing its destination before the collection is stopped.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Arrêtez la collecte"))
        }
        XCTAssertEqual(store.downloadDirectory, originalDestination)

        let offline = root.appendingPathComponent("network-offline")
        try Data().write(to: offline)
        try await waitUntil { !store.isConnected }
        try FileManager.default.removeItem(at: root.appendingPathComponent("inventory-failure-\(first)"))
        clock.advance()
        try await waitForInventoryDiscoveryCycles(store)
        XCTAssertEqual(inventoryAttempts(first, in: root), 1, "An elapsed retry must still wait for the GCS connection.")
        XCTAssertEqual(store.pendingInventoryRetryCount, 1)
        XCTAssertTrue(store.batchStatusMessage.contains("Attente du réseau"))
        XCTAssertTrue(store.preventsIdleSystemSleep)

        try FileManager.default.removeItem(at: offline)
        try await waitUntil {
            store.isConnected && !store.isBusy && store.pendingInventoryRetryCount == 0 &&
                store.queue.count == 2 && store.queue.allSatisfy(\.isSuccessful)
        }
        XCTAssertEqual(inventoryAttempts(first, in: root), 2)
        XCTAssertEqual(Set(store.queue.compactMap(\.clientID)), ["CAPTURED-INVENTORY"])
        XCTAssertEqual(Set(store.queue.map(\.destination)), [originalDestination.path])
        XCTAssertEqual(Set(store.queue.map(\.host)), ["localhost"])
        XCTAssertFalse(store.hasIncompleteInventory)
        await store.waitForQueueCounts()
        XCTAssertEqual(store.collectionFraction, 1)
        XCTAssertFalse(store.preventsIdleSystemSleep)
    }

    func testStopDiscardsPendingInventoryBeforeNetworkRecovery() async throws {
        let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "retry"])
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 }
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertTrue(store.canStopCollection)
        let offline = root.appendingPathComponent("network-offline")
        try Data().write(to: offline)
        try await waitUntil { !store.isConnected }

        store.stopCollection()
        XCTAssertTrue(store.isQueuePaused)
        XCTAssertEqual(store.pendingInventoryRetryCount, 0)
        XCTAssertFalse(store.canStopCollection)
        XCTAssertFalse(store.preventsIdleSystemSleep)
        clock.advance()
        try FileManager.default.removeItem(at: root.appendingPathComponent("inventory-failure-\(first)"))
        try FileManager.default.removeItem(at: offline)
        try await waitUntil { store.isConnected }
        try await waitForInventoryDiscoveryCycles(store)
        XCTAssertEqual(inventoryAttempts(first, in: root), 1, "A stopped inventory must not restart when the network returns.")
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertTrue(store.hasIncompleteInventory)
        XCTAssertFalse(store.batchStatusMessage.contains("terminée"))
        XCTAssertTrue(store.canCollectAll, "Only a new explicit collection may request the missing inventory again.")
    }

    func testPermanentInventoryErrorNeverEntersAutomaticRetryLoop() async throws {
        let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "permanent"])
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil { !store.isBusy && store.inventoryErrors.count == 1 }
        XCTAssertEqual(inventoryAttempts(first, in: root), 1)
        XCTAssertEqual(store.pendingInventoryRetryCount, 0)
        XCTAssertNil(store.inventoryRetryMessage)
        XCTAssertFalse(store.preventsIdleSystemSleep)
        XCTAssertFalse(store.canStopCollection)
        XCTAssertTrue(store.hasIncompleteInventory)

        try FileManager.default.removeItem(at: root.appendingPathComponent("inventory-failure-\(first)"))
        clock.advance()
        try await waitForInventoryDiscoveryCycles(store)
        XCTAssertEqual(inventoryAttempts(first, in: root), 1, "A permanent failure requires an explicit retry even after the cause disappears.")
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertTrue(store.canCollectAll)
        await store.waitForQueueCounts()
        XCTAssertLessThan(store.collectionFraction, 1)
        XCTAssertTrue(store.batchStatusMessage.contains("incomplet"))
    }

    private func waitForInventoryDiscoveryCycles(_ store: GCSStore) async throws {
        for _ in 0..<3 {
            let previous = store.drones.first?.timeUsec
            try await waitUntil { store.drones.first?.timeUsec != previous }
        }
    }
}
