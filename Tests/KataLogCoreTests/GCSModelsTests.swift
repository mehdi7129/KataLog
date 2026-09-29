import XCTest
@testable import KataLogCore

final class GCSModelsTests: XCTestCase {
    func testOnlyFullUnicastIdentitiesAreAccepted() {
        XCTAssertTrue(GCSIdentity.isValid("0102030405060708090A0B0C"))
        for invalid in ["", "0", String(repeating: "0", count: 24), String(repeating: "F", count: 24), "../123", "0102030405060708090A0B0Cx"] {
            XCTAssertFalse(GCSIdentity.isValid(invalid))
        }
    }

    func testMissingArmingIsNotPresentedAsDisarmedAndStaleDeviceExpires() throws {
        let data = Data(#"{"event":"drones","drones":[{"uuid":"0102030405060708090A0B0C","time_usec":123,"battery_status":0.98,"rssi_wifi":-43,"fw_major":4,"fw_minor":1,"fw_patch":5}]}"#.utf8)
        let event = try JSONDecoder().decode(GCSCollectorEvent.self, from: data)
        var drone = try XCTUnwrap(event.drones?.first)
        XCTAssertNil(drone.armed)
        XCTAssertEqual(drone.battery, 0.98)
        XCTAssertEqual(drone.firmware, "4.1.5")
        XCTAssertTrue(drone.isOnline)
        drone.lastSeen = Date().addingTimeInterval(-11)
        XCTAssertFalse(drone.isOnline)
    }

    func testInterruptedQueueCannotSilentlyResumeOnLaunch() throws {
        var item = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/fs/microsd/log/2026-09-01/log.ulg", size: 100, host: "localhost", destination: "/tmp/logs")
        item.state = "downloading"; item.completedBytes = 50
        var state = GCSCollectionState(downloadDirectory: "/tmp/logs")
        XCTAssertEqual(state.host, "", "A new install must ask for its own GCS endpoint")
        state.allowedUUIDs = [item.droneUUID]; state.queue = [item]
        var restored = try JSONDecoder().decode(GCSCollectionState.self, from: JSONEncoder().encode(state))
        restored.queue[0].recoverAfterRelaunch()
        XCTAssertEqual(restored.queue[0].state, "interrupted")
        XCTAssertEqual(restored.queue[0].progress, 0.5)
        XCTAssertEqual(restored.allowedUUIDs, state.allowedUUIDs)
        XCTAssertEqual(restored.queue[0].host, "localhost")
        XCTAssertEqual(restored.queue[0].destination, "/tmp/logs")
    }

    func testLegacyQueueDecodesWithoutBatchRetryAndPauseFields() throws {
        let legacy = Data(#"""
        {
          "schemaVersion": 1,
          "host": "192.0.2.10",
          "allowedUUIDs": ["0102030405060708090A0B0C"],
          "downloadDirectory": "/tmp/old-katalog-logs",
          "autoImport": true,
          "reconnect": false,
          "queue": [{
            "id": "legacy-transfer",
            "droneUUID": "0102030405060708090A0B0C",
            "remotePath": "/fs/microsd/log/2026-09-01/log.ulg",
            "size": 500,
            "host": "192.0.2.10",
            "destination": "/tmp/old-katalog-logs",
            "completedBytes": 250,
            "state": "downloading"
          }]
        }
        """#.utf8)
        var state = try JSONDecoder().decode(GCSCollectionState.self, from: legacy)
        let item = try XCTUnwrap(state.queue.first)
        XCTAssertEqual(item.id, "legacy-transfer")
        XCTAssertEqual(item.remotePath, "/fs/microsd/log/2026-09-01/log.ulg")
        XCTAssertEqual(item.completedBytes, 250)
        XCTAssertEqual(item.progress, 0.5)
        XCTAssertNil(item.batchID)
        XCTAssertNil(item.attempts)
        XCTAssertEqual(item.attemptCount, 0)
        XCTAssertNil(item.nextRetryAt)
        XCTAssertNil(item.remoteBusyUntil)
        XCTAssertNil(item.originalHost)
        XCTAssertNil(state.currentBatchID)
        XCTAssertNil(state.cachedFileCount)
        XCTAssertNil(state.queuePaused)
        XCTAssertNil(state.inventoryBusyUntil)

        state.queue[0].recoverAfterRelaunch()
        state.queue[0].attemptCount = 1
        state.currentBatchID = "new-batch"
        state.queuePaused = true
        let roundTrip = try JSONDecoder().decode(GCSCollectionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(roundTrip.queue[0].state, "interrupted")
        XCTAssertEqual(roundTrip.queue[0].id, item.id)
        XCTAssertEqual(roundTrip.queue[0].attemptCount, 1)
        XCTAssertEqual(roundTrip.queue[0].completedBytes, 250)
        XCTAssertEqual(roundTrip.currentBatchID, "new-batch")
        XCTAssertEqual(roundTrip.queuePaused, true)
        XCTAssertEqual(roundTrip.allowedUUIDs, state.allowedUUIDs)
    }

    func testRelaunchConvertsScheduledRetryToManualInterruption() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var item = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/fs/microsd/log/2026-09-01/log.ulg", size: 100, host: "gcs.local", destination: "/tmp/logs")
        item.state = "retrying"
        item.attemptCount = 2
        item.completedBytes = 40
        item.nextRetryAt = now.addingTimeInterval(15)
        item.remoteBusyUntil = now.addingTimeInterval(90)
        item.batchID = "retained-batch"
        var restored = try JSONDecoder().decode(GCSTransfer.self, from: JSONEncoder().encode(item))
        restored.recoverAfterRelaunch()

        XCTAssertEqual(restored.state, "interrupted")
        XCTAssertFalse(restored.isPending)
        XCTAssertEqual(restored.attemptCount, 2)
        XCTAssertEqual(restored.completedBytes, 40)
        XCTAssertEqual(restored.remoteBusyUntil, item.remoteBusyUntil)
        XCTAssertEqual(restored.batchID, "retained-batch")
        XCTAssertNotNil(restored.error)
        XCTAssertTrue(GCSQueuePolicy.nextJobs(queue: [restored], activeIDs: [], availableUUIDs: [item.droneUUID], host: "gcs.local", now: now.addingTimeInterval(120)).isEmpty)
    }

    func testRelaunchPreservesTerminalStopsAndSuccessfulFiles() {
        for status in ["stopped", "downloaded", "complete", "failed"] {
            var item = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/fs/microsd/log/log.ulg", size: 100, host: "gcs.local", destination: "/tmp/logs")
            item.state = status
            item.error = status == "failed" ? "Source indisponible" : nil
            let previousError = item.error
            item.recoverAfterRelaunch()
            XCTAssertEqual(item.state, status)
            XCTAssertEqual(item.error, previousError)
            XCTAssertFalse(item.isPending)
        }
    }

    func testLegacyInventoryOmitsOptionalCacheMetadata() throws {
        let data = Data(#"{"path":"/fs/microsd/log/log.ulg","size":42}"#.utf8)
        let file = try JSONDecoder().decode(GCSLogFile.self, from: data)
        XCTAssertEqual(file.size, 42)
        XCTAssertFalse(file.isDownloaded)
        XCTAssertNil(file.localPath)
        XCTAssertNil(file.sha256)
    }

    func testRetargetPreservesFirstEndpointAndNeverRewritesCompletedHistory() throws {
        var transfer = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/fs/microsd/log/a.ulg",
                                   size: 64, host: "192.0.2.10", destination: "/tmp/logs")
        transfer.retargetPending(to: "198.51.100.10")
        XCTAssertEqual(transfer.host, "198.51.100.10")
        XCTAssertEqual(transfer.originalHost, "192.0.2.10")
        transfer.retargetPending(to: "gcs.local")
        XCTAssertEqual(transfer.originalHost, "192.0.2.10")
        transfer.state = "complete"
        transfer.retargetPending(to: "another-gcs.local")
        XCTAssertEqual(transfer.host, "gcs.local")
        let restored = try JSONDecoder().decode(GCSTransfer.self, from: JSONEncoder().encode(transfer))
        XCTAssertEqual(restored.originalHost, "192.0.2.10")
    }
}
