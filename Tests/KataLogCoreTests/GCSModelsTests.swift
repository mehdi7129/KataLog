import XCTest
@testable import KataLogCore

final class GCSModelsTests: XCTestCase {
    func testGlobalProgressAdvancesAcrossBothTransportPhasesWithoutCountingDroneBytesAsMacBytes() throws {
        var item = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/fs/microsd/log/log.ulg", size: 64,
                               host: "localhost", destination: "/private/tmp")
        item.state = "downloading"
        item.receiveProgress(phase: "drone", bytes: 32, total: 64)
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.25)
        item.receiveProgress(phase: "drone", bytes: 64, total: 64)
        XCTAssertEqual(item.phaseProgress, 1)
        XCTAssertEqual(item.completedBytes, 0)
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.5)
        item.receiveProgress(phase: "http", bytes: 8, total: 64)
        XCTAssertEqual(item.phaseProgress, 0.125)
        XCTAssertEqual(item.completedBytes, 8)
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.5625)
        item.receiveProgress(phase: "drone", bytes: 60, total: 64)
        XCTAssertEqual(item.phase, "http", "A delayed first-leg event must not rewind the batch.")
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.5625)
        let restored = try JSONDecoder().decode(GCSTransfer.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.phase, "http")
        XCTAssertEqual(restored.phaseBytes, 8)
        XCTAssertEqual(restored.phaseTotal, 64)
        XCTAssertEqual(GCSBatchProgress(transfers: [restored]).fraction, 0.5625)
    }

    func testWorkIsWeightedByFileSizeAcrossDifferentDrones() {
        var small = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/small.ulg", size: 100, host: "localhost", destination: "/tmp")
        var large = GCSTransfer(droneUUID: "1112131415161718191A1B1C", remotePath: "/large.ulg", size: 900, host: "localhost", destination: "/tmp")
        small.state = "downloading"; large.state = "downloading"
        small.receiveProgress(phase: "drone", bytes: 50, total: 100)
        large.receiveProgress(phase: "http", bytes: 450, total: 900)
        let progress = GCSBatchProgress(transfers: [small, large])
        XCTAssertEqual(progress.totalBytes, 1_000)
        XCTAssertEqual(progress.completedBytes, 450)
        XCTAssertEqual(progress.completedWorkBytes, 700)
        XCTAssertEqual(progress.fraction, 0.7, accuracy: 0.000001)
    }

    func testLegacySingleTransportProgressKeepsItsOriginalScale() {
        var item = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/legacy.ulg", size: 100, host: "localhost", destination: "/tmp")
        item.state = "downloading"
        item.receiveProgress(phase: nil, bytes: 30, total: 100)
        XCTAssertNil(item.phase)
        XCTAssertEqual(item.completedBytes, 30)
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.3)
        item.receiveProgress(phase: nil, bytes: 100, total: 100)
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.99)
        item.state = "downloaded"
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 1)
    }

    func testVerificationFailureStopAndRetryCannotClaimCompletedCollection() {
        var item = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/log.ulg", size: 100, host: "localhost", destination: "/tmp")
        item.state = "downloading"
        item.receiveProgress(phase: "http", bytes: 100, total: 100)
        for state in ["downloading", "importing", "failed", "stopped", "interrupted"] {
            item.state = state
            XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.99)
            XCTAssertEqual(GCSBatchProgress(transfers: [item]).completedBytes, 100)
        }
        for state in ["queued", "retrying"] {
            item.state = state
            XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0)
        }
        item.state = "downloading"; item.completedBytes = 0; item.phase = nil
        item.phaseBytes = nil; item.phaseTotal = nil
        item.receiveProgress(phase: "drone", bytes: 40, total: 100)
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 0.2)
        item.state = "complete"
        XCTAssertEqual(GCSBatchProgress(transfers: [item]).fraction, 1)
    }

    func testZeroAndMalformedSizesAndPhaseCountersStayBounded() {
        var zero = GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/zero.ulg", size: 0, host: "localhost", destination: "/tmp")
        XCTAssertEqual(GCSBatchProgress(transfers: [zero]).fraction, 0)
        zero.state = "complete"
        XCTAssertEqual(GCSBatchProgress(transfers: [zero]).fraction, 1)
        XCTAssertEqual(GCSBatchProgress(transfers: [zero]).completedBytes, 0)
        var huge = GCSTransfer(droneUUID: zero.droneUUID, remotePath: "/huge.ulg", size: Int64.max, host: "localhost", destination: "/tmp")
        huge.state = "downloading"; huge.phase = "drone"
        huge.phaseBytes = Int64.max; huge.phaseTotal = Int64.max
        let overflow = GCSBatchProgress(transfers: [huge, huge])
        XCTAssertEqual(overflow.totalBytes, Int64.max)
        XCTAssertEqual(overflow.completedBytes, 0)
        XCTAssertEqual(overflow.fraction, 0.5)
        huge.phaseBytes = -10; huge.phaseTotal = 0
        XCTAssertEqual(GCSBatchProgress(transfers: [huge]).fraction, 0)
        huge.receiveProgress(phase: "drone", bytes: Int64.max, total: -1)
        XCTAssertEqual(huge.phaseBytes, 0)
        XCTAssertEqual(GCSBatchProgress(transfers: [huge]).fraction, 0)
    }

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

    func testFractionalGCSStatusDoesNotDropDroneAndUnknownFieldsStayUnknown() throws {
        let data = Data(#"{"event":"drones","drones":[{"uuid":"0102030405060708090A0B0C","arming_state":1.5,"fw_major":3.5,"fw_minor":7,"fw_patch":2,"time_usec":-1},{"uuid":"1112131415161718191A1B1C","arming_state":1.0,"fw_major":3.0,"fw_minor":7.0,"fw_patch":2.0}]}"#.utf8)
        let drones = try XCTUnwrap(JSONDecoder().decode(GCSCollectorEvent.self, from: data).drones)
        XCTAssertEqual(drones.count, 2)
        XCTAssertNil(drones[0].armed)
        XCTAssertNil(drones[0].timeUsec)
        XCTAssertEqual(drones[0].firmware, "Non communiqué")
        XCTAssertEqual(drones[1].armed, false)
        XCTAssertEqual(drones[1].firmware, "3.7.2")
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
