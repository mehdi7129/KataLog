import Foundation
import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class GCSInventoryRetryClock {
    var now = Date()
    func advance() { now = now.addingTimeInterval(60) }
}

extension GCSStoreTests {
    func inventoryRetryFixture(mode: String = "normal", singleDrone: Bool = false,
                               failures: [String: String] = [:]) throws -> (GCSStore, URL, GCSInventoryRetryClock) {
        let (_, root) = try fixture(mode: mode, configure: false, stateBuilder: { root in
            var state = GCSCollectionState(downloadDirectory: root.path)
            state.host = "localhost"; state.autoImport = false
            state.collectionClientID = "CAPTURED-INVENTORY"
            state.allowedUUIDs = singleDrone ? [self.first] : [self.first, self.second]
            return state
        })
        let script = root.appendingPathComponent("collector.py")
        var source = try String(contentsOf: script, encoding: .utf8)
        if singleDrone {
            source = source.replacingOccurrences(of: "if cmd=='discover':", with: "ids=ids[:1]\nif cmd=='discover':")
        }
        source = source.replacingOccurrences(of: "        emit('drones',drones=", with:
            "        emit('connection',connected=not(root/'network-offline').exists())\n        emit('drones',drones=")
        source = source.replacingOccurrences(of: "if cmd=='inventory':", with: """
        if cmd=='inventory':
            counter=root/(u+'.inventories')
            attempt=int(counter.read_text())+1 if counter.exists() else 1
            counter.write_text(str(attempt))
            while (root/('inventory-hold-'+u)).exists(): time.sleep(.01)
            failure=root/('inventory-failure-'+u)
            if failure.exists():
                emit('error',message='synthetic inventory unavailable',retryable=failure.read_text()!='permanent')
                sys.exit(1)
        """)
        try source.write(to: script, atomically: true, encoding: .utf8)
        for (uuid, kind) in failures {
            try kind.write(to: root.appendingPathComponent("inventory-failure-\(uuid)"), atomically: true, encoding: .utf8)
        }
        let clock = GCSInventoryRetryClock()
        let store = GCSStore(storageDirectory: root, collector: script, inventoryRetryClock: { clock.now })
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        store.connect()
        return (store, root, clock)
    }

    func inventoryAttempts(_ uuid: String, in root: URL) -> Int {
        (try? String(contentsOf: root.appendingPathComponent("\(uuid).inventories"), encoding: .utf8)).flatMap(Int.init) ?? 0
    }

    func testInventoryRetryBudgetCountsEachRequestOnceForThreeAndTenAttempts() async throws {
        for limit in [3, 10] {
            let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "retry"])
            store.setRetryLimit(limit)
            try await waitUntil { store.canCollectAll }
            await store.collectAll()
            try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 && self.inventoryAttempts(self.first, in: root) == 1 }
            for attempt in 2...limit {
                clock.advance()
                try await waitUntil {
                    !store.isBusy && self.inventoryAttempts(self.first, in: root) == attempt &&
                        store.pendingInventoryRetryCount == (attempt == limit ? 0 : 1)
                }
            }
            XCTAssertEqual(inventoryAttempts(first, in: root), limit)
            XCTAssertTrue(store.queue.isEmpty)
            XCTAssertTrue(store.hasIncompleteInventory)
            XCTAssertTrue(store.inventoryErrors.first?.contains("\(limit) tentatives") == true)
            XCTAssertFalse(store.preventsIdleSystemSleep, "An exhausted finite budget must release the idle-sleep assertion.")
            clock.advance()
            let heartbeat = store.drones.first?.timeUsec
            try await waitUntil { store.drones.first?.timeUsec != heartbeat }
            XCTAssertEqual(inventoryAttempts(first, in: root), limit, "Telemetry must not restart an exhausted inventory budget.")
        }
    }

    func testUnlimitedInventoryRetriesContinueBeyondTenAttemptsThenCollect() async throws {
        let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "retry"])
        XCTAssertEqual(store.retryLimit, 0)
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 }
        for attempt in 2...11 {
            clock.advance()
            try await waitUntil {
                !store.isBusy && store.pendingInventoryRetryCount == 1 && self.inventoryAttempts(self.first, in: root) == attempt
            }
        }
        XCTAssertTrue(store.preventsIdleSystemSleep)
        try FileManager.default.removeItem(at: root.appendingPathComponent("inventory-failure-\(first)"))
        clock.advance()
        try await waitUntil {
            !store.isBusy && store.pendingInventoryRetryCount == 0 && store.queue.count == 2 && store.queue.allSatisfy(\.isSuccessful)
        }
        XCTAssertEqual(inventoryAttempts(first, in: root), 12)
        XCTAssertFalse(store.hasIncompleteInventory)
        XCTAssertFalse(store.preventsIdleSystemSleep)
        await store.waitForQueueCounts()
        XCTAssertEqual(store.collectionFraction, 1)
    }

    func testLoweredInventoryBudgetAllowsCurrentReadToFinishButPreventsAnotherAttempt() async throws {
        let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "retry"])
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 }
        let hold = root.appendingPathComponent("inventory-hold-\(first)")
        try Data().write(to: hold)
        clock.advance()
        try await waitUntil { store.isRetryingInventory && self.inventoryAttempts(self.first, in: root) == 2 }
        store.setRetryLimit(2)
        XCTAssertTrue(store.isRetryingInventory)
        try FileManager.default.removeItem(at: hold)
        try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 0 }
        XCTAssertEqual(inventoryAttempts(first, in: root), 2)
        XCTAssertTrue(store.inventoryErrors.first?.contains("2 tentatives") == true)
        XCTAssertFalse(store.preventsIdleSystemSleep)
        clock.advance()
        let heartbeat = store.drones.first?.timeUsec
        try await waitUntil { store.drones.first?.timeUsec != heartbeat }
        XCTAssertEqual(inventoryAttempts(first, in: root), 2)
    }

    func testInventoryClientCleanupClearsDeferredAttributionWithoutResurrectingCapturedClient() async throws {
        for deleting in [true, false] {
            let (store, root, clock) = try inventoryRetryFixture(singleDrone: true, failures: [first: "retry"])
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let library = LibraryStore(storageDirectory: root.appendingPathComponent("library"),
                                       engine: project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"))
            defer { library.prepareForTermination() }
            let client = try await library.clients.create(name: "Deferred inventory client")
            store.attach(library: library)
            try await waitUntil {
                !library.isLoading && !library.isQuerying && !library.isMaintainingLibrary &&
                    !library.clients.isLoading && store.canCollectAll
            }
            store.chooseCollectionClient(client.id)
            await store.collectAll()
            try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 }

            // An active read owns a captured copy. The established maintenance
            // gate must reject cleanup until that read has returned.
            let hold = root.appendingPathComponent("inventory-hold-\(first)")
            try Data().write(to: hold)
            clock.advance()
            try await waitUntil { store.isRetryingInventory && self.inventoryAttempts(self.first, in: root) == 2 }
            do {
                if deleting { try await library.clientDidDelete(client.id) }
                else { try await library.clientProfilesDidLoad([]) }
                XCTFail("Client cleanup must not cross an active inventory read.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Arrêtez la collecte"))
            }
            XCTAssertEqual(store.collectionClientID, client.id)
            try FileManager.default.removeItem(at: hold)
            try await waitUntil { !store.isBusy && store.pendingInventoryRetryCount == 1 }
            if deleting { try await library.clientDidDelete(client.id) }
            else { try await library.clientProfilesDidLoad([]) }
            XCTAssertEqual(store.collectionClientID, "")

            // Another failed retry must preserve the cleanup in its new request.
            clock.advance()
            try await waitUntil { !store.isBusy && self.inventoryAttempts(self.first, in: root) == 3 }
            XCTAssertEqual(store.pendingInventoryRetryCount, 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent("inventory-failure-\(first)"))
            clock.advance()
            try await waitUntil {
                !store.isBusy && store.pendingInventoryRetryCount == 0 && store.queue.count == 2 && store.queue.allSatisfy(\.isSuccessful)
            }
            XCTAssertTrue(store.queue.allSatisfy { ($0.clientID ?? "").isEmpty })
            try await store.waitForPersistence()
            let persisted = try GCSQueueRepository(url: root.appendingPathComponent("gcs-queue.sqlite"), readOnly: true)
            XCTAssertTrue(try persisted.retainedTransfers().allSatisfy { ($0.clientID ?? "").isEmpty })
            try await store.finishTermination()
        }
    }

    func testInventoryRetryDoesNotInterruptOtherDroneDownloadOrClaimCompleteCoverage() async throws {
        let (store, root, clock) = try inventoryRetryFixture(mode: "phases-gated", failures: [second: "retry"])
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil {
            store.activeTransferCount == 1 && store.queue.first?.phase == "drone" && store.pendingInventoryRetryCount == 1
        }
        let activeID = try XCTUnwrap(store.queue.first(where: \.isActive)?.id)
        clock.advance()
        try await waitUntil { !store.isRetryingInventory && self.inventoryAttempts(self.second, in: root) == 2 }
        XCTAssertEqual(store.activeTransferCount, 1)
        XCTAssertTrue(store.queue.contains { $0.id == activeID && $0.isActive })
        for phase in ["drone", "http", "complete"] {
            try Data().write(to: root.appendingPathComponent("\(phase)-\(first)"))
        }
        try await waitUntil { !store.isBusy && store.queue.count == 2 && store.queue.allSatisfy(\.isSuccessful) }
        await store.waitForQueueCounts()
        XCTAssertEqual(store.batchProgress.completedCount, 2)
        XCTAssertLessThan(store.collectionFraction, 1, "Completed files from one drone cannot establish complete fleet coverage.")
        XCTAssertTrue(store.preventsIdleSystemSleep)
        XCTAssertEqual(store.pendingInventoryRetryCount, 1)
        XCTAssertFalse(store.batchStatusMessage.contains("terminée"))
        // The established restart contract remains explicit. Only the incomplete
        // coverage is durable; reopening must not silently issue new requests.
        try await store.waitForPersistence()
        let restored = GCSStore(storageDirectory: root)
        XCTAssertTrue(restored.hasIncompleteInventory)
        XCTAssertEqual(restored.pendingInventoryRetryCount, 0)
        XCTAssertFalse(restored.preventsIdleSystemSleep)
    }
}
