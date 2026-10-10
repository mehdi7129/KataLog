import Foundation
import XCTest
import KataLogCore
@testable import KataLog

extension GCSStoreTests {
    func testManualDownloadCollectsOnlyRequestedLogAndKeepsOtherSelection() async throws {
        let (store, root) = try fixture(mode: "normal", stateBuilder: { root in
            var state = GCSCollectionState(downloadDirectory: root.path)
            state.collectionClientID = "CAPTURED-CLIENT"
            return state
        })
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        let requested = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        let untouched = try XCTUnwrap(store.files.first { $0.filename == "b.ulg" })
        store.toggleFile(untouched)
        XCTAssertTrue(store.canDownloadFile(requested))
        store.downloadFile(requested)
        store.downloadFile(requested) // A repeated click during admission cannot duplicate the job.
        try await waitUntil { !store.isBusy && store.queue.count == 1 && store.queue.allSatisfy(\.isSuccessful) }
        let job = try XCTUnwrap(store.queue.first)
        XCTAssertEqual(job.droneUUID, first)
        XCTAssertEqual(job.remotePath, requested.path)
        XCTAssertEqual(job.clientID, "CAPTURED-CLIENT")
        XCTAssertEqual(job.manualPriority, true)
        XCTAssertEqual(store.selectedFileIDs, [untouched.id])
        let downloaded = try XCTUnwrap(store.files.first { $0.id == requested.id })
        XCTAssertTrue(downloaded.isDownloaded)
        XCTAssertNotNil(downloaded.localPath)
        XCTAssertNotNil(downloaded.sha256)
        XCTAssertFalse(store.canDownloadFile(downloaded))
        XCTAssertTrue(store.canDownloadFile(untouched))
        let trace = try manualTransferTrace(root)
        XCTAssertEqual(trace.count, 1)
        XCTAssertEqual(trace.first?["path"] as? String, requested.path)
        try await store.waitForPersistence()
        let saved = GCSStore(storageDirectory: root)
        XCTAssertEqual(saved.queue.first?.manualPriority, true)
        XCTAssertEqual(saved.queue.first?.clientID, "CAPTURED-CLIENT")
    }

    func testManualPriorityUsesBulkInventoryWithoutInterruptingActiveDownloads() async throws {
        let (store, root) = try fixture(mode: "phases-gated", stateBuilder: { root in
            var state = GCSCollectionState(downloadDirectory: root.path)
            state.collectionClientID = "BULK-CLIENT"
            return state
        })
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try instrumentManualInventory(root, addThirdLog: true)
        try await waitUntil { store.canCollectAll }
        await store.collectAll()
        try await waitUntil {
            store.queue.count == 6 && store.activeTransferCount == 2 &&
                store.queue.filter { $0.phase == "drone" }.count == 2
        }
        let initialOrder = store.queue.map(\.id)
        let activeIDs = Set(store.queue.filter(\.isActive).map(\.id))
        XCTAssertEqual(try manualInventoryTrace(root).count, 2)
        XCTAssertTrue(store.canSelectDrone(uuid: first))
        await store.selectDrone(first)
        XCTAssertEqual(store.files.count, 3)
        XCTAssertFalse(store.canRefreshInventory)
        store.refreshInventory()
        XCTAssertEqual(try manualInventoryTrace(root).count, 2, "Browsing during transfer must reuse the complete bulk inventory.")
        let requested = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        let original = try XCTUnwrap(store.transfer(for: requested))
        XCTAssertTrue(original.isPending)
        XCTAssertTrue(store.canDownloadFile(requested))
        store.downloadFile(requested)
        try await waitUntil { store.transfer(for: requested)?.manualPriority == true }
        XCTAssertEqual(store.queue.map(\.id), initialOrder, "Promotion cannot move elements held by active workers.")
        XCTAssertEqual(Set(store.queue.filter(\.isActive).map(\.id)), activeIDs)
        let promoted = try XCTUnwrap(store.transfer(for: requested))
        XCTAssertEqual(promoted.id, original.id)
        XCTAssertEqual(promoted.clientID, "BULK-CLIENT")
        XCTAssertEqual(promoted.attemptCount, original.attemptCount)
        XCTAssertEqual(promoted.remoteBusyUntil, original.remoteBusyUntil)
        XCTAssertFalse(store.canDownloadFile(requested), "An already prioritised job must not accept a redundant click.")
        store.downloadFile(requested)
        XCTAssertEqual(store.queue.count, 6)
        for phase in ["drone", "http", "complete"] {
            try Data().write(to: root.appendingPathComponent("\(phase)-\(first)"), options: .atomic)
        }
        try await waitUntil { store.queue.filter { $0.droneUUID == self.first && $0.isSuccessful }.count == 3 }
        let firstRequests = try manualTransferTrace(root).filter { $0["uuid"] as? String == first }
        XCTAssertEqual(firstRequests.compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } },
                       ["c.ulg", "a.ulg", "b.ulg"])
        XCTAssertEqual(Set(store.queue.filter { $0.droneUUID == second && $0.isActive }.map(\.id)),
                       activeIDs.intersection(Set(store.queue.filter { $0.droneUUID == second }.map(\.id))))
        for phase in ["drone", "http", "complete"] {
            try Data().write(to: root.appendingPathComponent("\(phase)-\(second)"), options: .atomic)
        }
        try await waitUntil { !store.isBusy && store.queue.count == 6 && store.queue.allSatisfy(\.isSuccessful) }
        await store.selectDrone(second)
        XCTAssertTrue(store.files.allSatisfy(\.isDownloaded), "Completion must update an inventory even while another drone is selected.")
        XCTAssertEqual(try manualInventoryTrace(root).count, 2)
    }

    func testManualPromotionPreservesCapturedClientRetryAndSource() async throws {
        let (store, root) = try fixture(mode: "normal")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { store.canCollectAll }
        store.pauseQueue()
        let file = GCSLogFile(path: "/fs/microsd/log/2026-09-01/manual.ulg", size: 64)
        _ = try await store.enqueue([file], uuid: first, host: "localhost", destination: store.downloadDirectory.path, clientID: "ORIGINAL")
        let original = try XCTUnwrap(store.queue.first)
        let promotedCount = try await store.enqueue([file, file], uuid: first, host: "localhost", destination: store.downloadDirectory.path,
                                                    clientID: "CHANGED", manualPriority: true)
        XCTAssertEqual(promotedCount, 1)
        XCTAssertEqual(store.queue.count, 1)
        let promoted = try XCTUnwrap(store.queue.first)
        XCTAssertEqual(promoted.id, original.id)
        XCTAssertEqual(promoted.clientID, "ORIGINAL")
        XCTAssertEqual(promoted.destination, original.destination)
        XCTAssertEqual(promoted.remoteBusyUntil, original.remoteBusyUntil)
        XCTAssertEqual(promoted.manualPriority, true)
    }

    func testManualDownloadRevalidatesDestinationBeforeQueueAdmission() async throws {
        let (store, root) = try fixture(mode: "normal")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        let destination = root.appendingPathComponent("removable-destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try await waitUntil { store.canCollectAll }
        try await store.setDownloadDirectory(destination)
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        let requested = try XCTUnwrap(store.files.first)
        XCTAssertTrue(store.canDownloadFile(requested))
        try FileManager.default.removeItem(at: destination)
        store.downloadFile(requested)
        try await waitUntil { !store.isBusy && store.errorMessage != nil }
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("trace.jsonl").path))
    }

    func testManualInventoryCacheIsNotReusedAfterDisconnect() async throws {
        let (store, root) = try fixture(mode: "normal")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        try instrumentManualInventory(root)
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        await store.selectDrone(first)
        XCTAssertEqual(try manualInventoryTrace(root).count, 1)
        store.disconnect()
        // The discovery process releases its task asynchronously after cancellation.
        try await store.finishTermination()
        store.cancelTermination()
        store.connect()
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        XCTAssertEqual(try manualInventoryTrace(root).count, 2)
    }

    func testManualSelectionChangeDuringRefreshDoesNotPublishOtherDroneFiles() async throws {
        let (store, root) = try fixture(mode: "normal")
        addTeardownBlock { @MainActor in
            try await store.finishTermination()
            try? FileManager.default.removeItem(at: root)
        }
        let script = root.appendingPathComponent("collector.py")
        var source = try String(contentsOf: script, encoding: .utf8)
        source = source.replacingOccurrences(of: "if cmd=='inventory':", with: """
        paths=[p.replace('/2026-09-01/','/'+u+'/') for p in paths]
        if cmd=='inventory':
            if (root/'hold-inventory').exists():
                (root/'inventory-held').write_text(u)
                while (root/'hold-inventory').exists(): time.sleep(.01)
        """)
        try source.write(to: script, atomically: true, encoding: .utf8)
        try await waitUntil { store.canSelectDrone(uuid: self.first) }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        await store.selectDrone(second)
        try await waitUntil { !store.isBusy && store.files.allSatisfy { $0.dateFolder == self.second } }
        let expectedFiles = store.files.map(\.id)
        await store.selectDrone(first)
        XCTAssertTrue(store.files.allSatisfy { $0.dateFolder == first })
        try Data().write(to: root.appendingPathComponent("hold-inventory"))
        store.refreshInventory()
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-held").path) }
        XCTAssertTrue(store.isReadingInventory)
        await store.selectDrone(second)
        XCTAssertFalse(store.isReadingInventory)
        let selected = try XCTUnwrap(store.files.first)
        store.toggleFile(selected)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-inventory"))
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.selectedUUID, second)
        XCTAssertEqual(store.files.map(\.id), expectedFiles)
        XCTAssertEqual(store.selectedFileIDs, [selected.id])
    }

    private func instrumentManualInventory(_ root: URL, addThirdLog: Bool = false) throws {
        let script = root.appendingPathComponent("collector.py")
        var source = try String(contentsOf: script, encoding: .utf8)
        source = source.replacingOccurrences(of: "if cmd=='inventory':", with: """
        if cmd=='inventory':
            with (root/'inventory-trace.jsonl').open('a') as trace: trace.write(json.dumps(dict(uuid=u))+'\\n')
        """)
        if addThirdLog {
            source = source.replacingOccurrences(of: "if mode=='pipeline-benchmark': paths=", with:
                "paths.append('/fs/microsd/log/2026-09-01/c.ulg')\nif mode=='pipeline-benchmark': paths=")
        }
        try source.write(to: script, atomically: true, encoding: .utf8)
    }

    private func manualTransferTrace(_ root: URL) throws -> [[String: Any]] {
        try manualTrace(root.appendingPathComponent("trace.jsonl"))
    }

    private func manualInventoryTrace(_ root: URL) throws -> [[String: Any]] {
        try manualTrace(root.appendingPathComponent("inventory-trace.jsonl"))
    }

    private func manualTrace(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
