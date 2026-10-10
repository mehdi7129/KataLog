import Foundation
import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class GCSDownloadSettingsTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-download-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testOldSettingsDefaultToTwoDronesAndUnlimitedNetworkRetries() throws {
        let root = try root()
        let settings = GCSCollectionState(downloadDirectory: root.path)
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("gcs-settings.json"))
        let store = GCSStore(storageDirectory: root)
        XCTAssertEqual(store.maxConcurrentDownloads, 2)
        XCTAssertEqual(store.retryLimit, 0)
    }

    func testDownloadPreferencesPersistAndRestoreWithoutResumingTransfers() async throws {
        let root = try root()
        let store = GCSStore(storageDirectory: root)
        store.setConcurrentDownloads(4)
        store.setRetryLimit(10)
        try await store.waitForPersistence()
        let saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: root.appendingPathComponent("gcs-settings.json")))
        XCTAssertEqual(saved.concurrentDownloads, 4)
        XCTAssertEqual(saved.retryLimit, 10)
        let restored = GCSStore(storageDirectory: root)
        XCTAssertEqual(restored.maxConcurrentDownloads, 4)
        XCTAssertEqual(restored.retryLimit, 10)
        XCTAssertEqual(restored.activeTransferCount, 0)
        restored.setRetryLimit(0)
        try await restored.waitForPersistence()
        let unlimited = GCSStore(storageDirectory: root)
        XCTAssertEqual(unlimited.retryLimit, 0)
    }

    func testMalformedLimitsAreBoundedAndTerminationBlocksPreferenceChanges() throws {
        let root = try root()
        var settings = GCSCollectionState(downloadDirectory: root.path)
        settings.concurrentDownloads = 100; settings.retryLimit = -2
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("gcs-settings.json"))
        let store = GCSStore(storageDirectory: root)
        XCTAssertEqual(store.maxConcurrentDownloads, 4)
        XCTAssertEqual(store.retryLimit, 0)
        store.stopForTermination()
        store.setConcurrentDownloads(1)
        store.setRetryLimit(3)
        XCTAssertEqual(store.maxConcurrentDownloads, 4)
        XCTAssertEqual(store.retryLimit, 0)
    }
}

extension GCSStoreTests {
    func testMalformedDownloadResponseFailsOnceAndReleasesSleepAssertionWithUnlimitedRetries() async throws {
        let (store, root) = try fixture(mode: "normal")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        let script = root.appendingPathComponent("collector.py")
        let source = try String(contentsOf: script, encoding: .utf8).replacingOccurrences(
            of: "    if mode=='permanent':",
            with: "    print('{invalid-json', flush=True);sys.exit(0)\n    if mode=='permanent':"
        )
        try source.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.retryLimit, 0)
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil { !store.isBusy && store.queue.count == 4 && store.queue.allSatisfy { $0.state == "failed" } }
        XCTAssertTrue(store.queue.allSatisfy { $0.attemptCount == 1 && $0.nextRetryAt == nil })
        XCTAssertFalse(store.preventsIdleSystemSleep, "A permanent helper failure must not keep the Mac awake for another retry.")
        let attempts = try String(contentsOf: root.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        XCTAssertEqual(attempts.split(separator: "\n").count, 4, "Each malformed response must end its file's automatic attempts.")
    }

    func testConfiguredConcurrencyAdmitsThreeDifferentDronesAndDrainsBeforeDecreasing() async throws {
        let (store, root) = try fixture(mode: "phases-gated")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        let third = "2122232425262728292A2B2C"
        let script = root.appendingPathComponent("collector.py")
        var source = try String(contentsOf: script, encoding: .utf8)
        source = source.replacingOccurrences(of: "if cmd=='discover':", with: "ids.append('\(third)')\nif cmd=='discover':")
        try source.write(to: script, atomically: true, encoding: .utf8)
        store.setConcurrentDownloads(3)
        try await waitUntil { store.canCollectAll && store.collectableDrones.count == 3 }
        await store.collectAll()
        try await waitUntil { store.activeTransferCount == 3 && store.queue.filter { $0.phase == "drone" }.count == 3 }
        let active = store.queue.filter(\.isActive)
        XCTAssertEqual(Set(active.map(\.droneUUID)), [first, second, third])
        XCTAssertEqual(store.queue.count, 6)
        store.setConcurrentDownloads(1)
        XCTAssertEqual(store.activeTransferCount, 3, "Reducing concurrency must not cancel files already transferring.")
        for uuid in [first, second] {
            for phase in ["drone", "http", "complete"] {
                try Data().write(to: root.appendingPathComponent("\(phase)-\(uuid)"))
            }
        }
        try await waitUntil { store.activeTransferCount == 1 && store.queue.filter(\.isSuccessful).count == 2 }
        XCTAssertEqual(store.queue.filter(\.isPending).count, 3, "New workers must wait until the current limit permits them.")
        for phase in ["drone", "http", "complete"] {
            try Data().write(to: root.appendingPathComponent("\(phase)-\(third)"))
        }
        try await waitUntil { !store.isBusy && store.queue.count == 6 && store.queue.allSatisfy(\.isSuccessful) }
    }

    func testReducingRetryLimitCancelsAnAlreadyExhaustedScheduledRetry() async throws {
        let (store, root) = try fixture(mode: "retry")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil { store.queue.contains { $0.state == "retrying" && $0.attemptCount == 1 } }
        let retry = try XCTUnwrap(store.queue.first { $0.state == "retrying" })
        store.setRetryLimit(1)
        let stoppedRetry = try XCTUnwrap(store.queue.first { $0.id == retry.id })
        XCTAssertEqual(stoppedRetry.state, "failed")
        XCTAssertNil(stoppedRetry.nextRetryAt)
        XCTAssertEqual(stoppedRetry.attemptCount, 1)
        try await waitUntil { !store.isBusy && store.queue.count == 4 && store.queue.allSatisfy { $0.isSuccessful || $0.state == "failed" } }
        XCTAssertEqual(store.queue.first { $0.id == retry.id }?.attemptCount, 1)
    }
}
