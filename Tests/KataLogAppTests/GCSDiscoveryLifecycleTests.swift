import Foundation
import XCTest
import KataLogCore
@testable import KataLog

extension GCSStoreTests {
    func testImmediateReconnectWaitsForOldDiscoveryAndCoalescesClicks() async throws {
        let (store, discovery) = try controlledDiscoveryStore()
        try await waitUntil { store.isConnected && discovery.pendingReads == [0] }

        // No suspension: the old task cannot run its cancellation defer between clicks.
        store.disconnect()
        store.host = "replacement.local"
        store.connect()
        store.connect()
        XCTAssertTrue(store.isConnecting, "A queued connection must remain visible and cancellable.")
        XCTAssertEqual(discovery.hosts, ["localhost"], "The previous reader still owns discovery.")

        discovery.release(0)
        try await waitUntil { store.isConnected && discovery.pendingReads == [1] }
        XCTAssertEqual(discovery.hosts, ["localhost", "replacement.local"], "Repeated clicks must start only one replacement.")
    }

    func testFinishTerminationWaitsForCancelledDiscoveryRead() async throws {
        let (store, discovery) = try controlledDiscoveryStore()
        try await waitUntil { store.isConnected && discovery.pendingReads == [0] }
        try await store.waitForPersistence()
        let returnedBeforeRelease = expectation(description: "Termination must wait for discovery cleanup")
        returnedBeforeRelease.isInverted = true
        var released = false
        let finish = Task {
            try await store.finishTermination()
            if !released { returnedBeforeRelease.fulfill() }
        }
        // The simulated reader deliberately ignores cancellation until explicitly released.
        // This checks the lifetime barrier, without relying on a Python signal grace period.
        await fulfillment(of: [returnedBeforeRelease], timeout: 0.3)
        released = true
        discovery.release(0)
        try await finish.value
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertEqual(discovery.hosts, ["localhost"])
    }

    func testSecondDisconnectCancelsQueuedDiscoveryReconnect() async throws {
        try await assertQueuedDiscoveryReconnectCancelled { $0.disconnect() }
    }

    func testStopCollectionCancelsQueuedDiscoveryReconnect() async throws {
        try await assertQueuedDiscoveryReconnectCancelled { $0.stopCollection() }
    }

    func testHostChangeBackToOriginalStillCancelsQueuedDiscoveryReconnect() async throws {
        try await assertQueuedDiscoveryReconnectCancelled {
            $0.host = "another.local"
            $0.host = "localhost"
        }
    }

    func testCancelledTerminationDoesNotReviveQueuedDiscoveryReconnect() async throws {
        try await assertQueuedDiscoveryReconnectCancelled {
            $0.stopForTermination()
            $0.cancelTermination()
        }
    }

    func testRestoreDrainsDiscoveryAndRejectsReconnectDuringDrain() async throws {
        let (store, discovery) = try controlledDiscoveryStore()
        try await waitUntil { store.isConnected && discovery.pendingReads == [0] }
        store.disconnect(); store.connect()
        let restore = Task { try await store.preparePersistedStorageForRestore() }
        try await waitUntil { store.isMaintenanceBlocked }
        store.connect()
        discovery.release(0)
        try await restore.value
        XCTAssertEqual(discovery.hosts, ["localhost"])
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isMaintenanceBlocked)
    }

    func testResetDrainsDiscoveryAndRejectsReconnectDuringDrain() async throws {
        let (store, discovery) = try controlledDiscoveryStore()
        try await waitUntil { store.isConnected && discovery.pendingReads == [0] }
        store.disconnect(); store.connect()
        let reset = Task { try await store.resetForApplication() }
        try await waitUntil { store.isMaintenanceBlocked }
        store.connect()
        discovery.release(0)
        try await reset.value
        XCTAssertEqual(discovery.hosts, ["localhost"])
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isMaintenanceBlocked)
    }

    private func assertQueuedDiscoveryReconnectCancelled(_ cancel: (GCSStore) -> Void) async throws {
        let (store, discovery) = try controlledDiscoveryStore()
        try await waitUntil { store.isConnected && discovery.pendingReads == [0] }
        store.disconnect(); store.connect()
        XCTAssertTrue(store.isConnecting)
        cancel(store)
        discovery.release(0)
        // Unlike finishTermination, this join does not itself invalidate the intent.
        await store.waitForDiscoveryTermination()
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertEqual(discovery.hosts, ["localhost"])
        store.connect()
        try await waitUntil { store.isConnected && discovery.pendingReads == [1] }
        XCTAssertEqual(discovery.hosts, ["localhost", "localhost"], "A later explicit connection must remain possible.")
    }

    private func controlledDiscoveryStore() throws -> (GCSStore, ControlledGCSDiscovery) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let discovery = try ControlledGCSDiscovery()
        let store = GCSStore(storageDirectory: root, discoveryEvents: { _, host in discovery.events(host: host) })
        addTeardownBlock { @MainActor in
            store.stopForTermination()
            discovery.releaseAll()
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        store.host = "localhost"
        store.connect()
        return (store, discovery)
    }
}

/// A suspended read remains owned until the test releases it, even after cancellation.
@MainActor
private final class ControlledGCSDiscovery {
    private let connected: GCSCollectorEvent
    private var reads: [Int] = []
    private var continuations: [Int: CheckedContinuation<GCSCollectorEvent?, Never>] = [:]
    private(set) var hosts: [String] = []
    var pendingReads: Set<Int> { Set(continuations.keys) }

    init() throws {
        connected = try JSONDecoder().decode(GCSCollectorEvent.self, from: Data(#"{"event":"connection","connected":true}"#.utf8))
    }

    func events(host: String) -> AsyncThrowingStream<GCSCollectorEvent, Error> {
        let index = hosts.count
        hosts.append(host); reads.append(0)
        return AsyncThrowingStream(unfolding: { await self.next(index) })
    }

    private func next(_ index: Int) async -> GCSCollectorEvent? {
        guard !Task.isCancelled else { return nil }
        reads[index] += 1
        if reads[index] == 1 { return connected }
        return await withCheckedContinuation { continuations[index] = $0 }
    }

    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume(returning: nil) }
    func releaseAll() { for index in Array(continuations.keys) { release(index) } }
}
