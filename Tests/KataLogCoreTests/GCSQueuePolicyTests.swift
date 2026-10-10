import Foundation
import XCTest
@testable import KataLogCore

final class GCSQueuePolicyTests: XCTestCase {
    private let droneA = "0102030405060708090A0B0C"
    private let droneB = "1112131415161718191A1B1C"
    private let droneC = "2122232425262728292A2B2C"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStartsTwoDistinctDronesAndKeepsSameDroneFilesSerial() {
        let a1 = job(droneA, index: 1)
        let a2 = job(droneA, index: 2)
        let b1 = job(droneB)
        let c1 = job(droneC)
        let queue = [a1, a2, b1, c1]

        let first = GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now)
        XCTAssertEqual(first, [a1.id, b1.id], "Two slots must use different drones, even when the first drone has several queued files.")

        let whileAIsActive = GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [a1.id], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now)
        XCTAssertEqual(whileAIsActive, [b1.id])
        XCTAssertFalse(whileAIsActive.contains(a2.id))

        let allSlotsOccupied = GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [a1.id, b1.id], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now)
        XCTAssertTrue(allSlotsOccupied.isEmpty)
    }

    func testCompletedWorkerStillOccupiesItsSlotUntilTaskHasActuallyFinished() {
        let finishingA = job(droneA, state: "complete", bytes: 100)
        let nextA = job(droneA, index: 2)
        let nextB = job(droneB)
        let nextC = job(droneC)
        let selected = GCSQueuePolicy.nextJobs(queue: [finishingA, nextA, nextB, nextC], activeIDs: [finishingA.id], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now)
        XCTAssertEqual(selected, [nextB.id], "Updating a row to complete must not release concurrency before the worker exits.")
    }

    func testRemoteBusyDroneRemainsBlockedAfterLocalStopUntilDeadline() {
        var stoppedA = job(droneA, state: "stopped")
        stoppedA.remoteBusyUntil = now.addingTimeInterval(30)
        let nextA = job(droneA, index: 2)
        let nextB = job(droneB)
        let nextC = job(droneC)
        let queue = [stoppedA, nextA, nextB, nextC]

        let beforeDeadline = GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now.addingTimeInterval(29.9))
        XCTAssertEqual(beforeDeadline, [nextB.id, nextC.id], "A stopped local process may leave a remote FTP transaction busy; other drones can continue.")

        let atDeadline = GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now.addingTimeInterval(30))
        XCTAssertEqual(atDeadline, [nextA.id, nextB.id])
    }

    func testRemoteBusyDeadlineAndActiveWorkerBothHaveToClear() {
        var finishingA = job(droneA, state: "stopped")
        finishingA.remoteBusyUntil = now.addingTimeInterval(5)
        let nextA = job(droneA, index: 2)
        let queue = [finishingA, nextA]

        XCTAssertTrue(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [finishingA.id], availableUUIDs: [droneA], host: "gcs.local", now: now.addingTimeInterval(6)).isEmpty)
        XCTAssertTrue(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA], host: "gcs.local", now: now.addingTimeInterval(4)).isEmpty)
        XCTAssertEqual(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA], host: "gcs.local", now: now.addingTimeInterval(6)), [nextA.id])
    }

    func testRetryBudgetAllowsOnlyThreeAttemptsWithIncreasingBackoff() throws {
        XCTAssertEqual(GCSQueuePolicy.maxAttempts, 3)
        XCTAssertEqual(try XCTUnwrap(GCSQueuePolicy.retryDate(attempt: 1, limit: 3, now: now)).timeIntervalSince(now), 5)
        XCTAssertEqual(try XCTUnwrap(GCSQueuePolicy.retryDate(attempt: 2, limit: 3, now: now)).timeIntervalSince(now), 15)
        XCTAssertNil(GCSQueuePolicy.retryDate(attempt: 3, limit: 3, now: now))
        XCTAssertNil(GCSQueuePolicy.retryDate(attempt: 4, limit: 3, now: now))
    }

    func testUnlimitedRetriesSurviveTwentyFiveDisconnectsWithBoundedBackoff() throws {
        for attempt in 1...25 {
            let retry = try XCTUnwrap(GCSQueuePolicy.retryDate(attempt: attempt, now: now))
            XCTAssertGreaterThanOrEqual(retry.timeIntervalSince(now), 5)
            XCTAssertLessThanOrEqual(retry.timeIntervalSince(now), 60)
        }
        XCTAssertNotNil(GCSQueuePolicy.retryDate(attempt: 9, limit: 10, now: now))
        XCTAssertNil(GCSQueuePolicy.retryDate(attempt: 10, limit: 10, now: now))
    }

    func testConcurrencyCanIncreaseAndDecreaseWithoutOverlappingTheSameDrone() {
        let a = job(droneA), a2 = job(droneA, index: 2), b = job(droneB), c = job(droneC)
        let queue = [a, a2, b, c]
        XCTAssertEqual(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", limit: 3, now: now), [a.id, b.id, c.id])
        XCTAssertEqual(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", limit: 1, now: now), [a.id])
        XCTAssertTrue(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [a.id, b.id], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", limit: 1, now: now).isEmpty)
    }

    func testManualPriorityIsStableAndRespectsActiveDroneAndRetryDeadlines() {
        let a = job(droneA), b = job(droneB)
        var chosen = job(droneA, index: 2)
        chosen.manualPriority = true
        var later = job(droneC)
        later.manualPriority = true; later.nextRetryAt = now.addingTimeInterval(5)
        let queue = [a, b, chosen, later]
        XCTAssertEqual(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now), [chosen.id, b.id])
        XCTAssertEqual(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [a.id], availableUUIDs: [droneA, droneB, droneC], host: "gcs.local", now: now), [b.id])
        XCTAssertEqual(queue.map(\.id), [a.id, b.id, chosen.id, later.id], "Never reorder entries held by active workers.")
    }

    func testScheduledRetryWaitsForItsDateWithoutBlockingAnotherDrone() {
        var retryA = job(droneA, state: "retrying")
        retryA.attemptCount = 1
        retryA.nextRetryAt = now.addingTimeInterval(5)
        let nextB = job(droneB)
        let queue = [retryA, nextB]

        XCTAssertEqual(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB], host: "gcs.local", now: now), [nextB.id])
        XCTAssertEqual(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA, droneB], host: "gcs.local", now: now.addingTimeInterval(5)), [retryA.id, nextB.id])
    }

    func testOnlyAvailableDronesOnTheConnectedGCSCanStart() {
        let oldHost = job(droneA, host: "other-gcs.local")
        let offline = job(droneB)
        let eligible = job(droneC)
        let selected = GCSQueuePolicy.nextJobs(queue: [oldHost, offline, eligible], activeIDs: [], availableUUIDs: [droneA, droneC], host: "gcs.local", now: now)
        XCTAssertEqual(selected, [eligible.id])
        XCTAssertTrue(GCSQueuePolicy.nextJobs(queue: [eligible], activeIDs: [], availableUUIDs: [], host: "gcs.local", now: now).isEmpty)
    }

    func testFailedStoppedAndInterruptedFilesRequireExplicitRetry() {
        let terminalStates = ["failed", "stopped", "interrupted", "complete", "downloaded", "importing", "downloading"]
        let queue = terminalStates.enumerated().map { job(droneA, index: $0.offset, state: $0.element) }
        XCTAssertTrue(GCSQueuePolicy.nextJobs(queue: queue, activeIDs: [], availableUUIDs: [droneA], host: "gcs.local", now: now).isEmpty)
    }

    func testBatchProgressRetainsFailedAndStoppedWorkInTheDenominator() {
        let queue = [
            job(droneA, index: 1, state: "complete", bytes: 100),
            job(droneA, index: 2, state: "downloaded", bytes: 100),
            job(droneA, index: 3, state: "failed", bytes: 20),
            job(droneA, index: 4, state: "stopped", bytes: 40),
            job(droneB, index: 1, state: "retrying"),
            job(droneB, index: 2, state: "downloading", bytes: 30),
            job(droneB, index: 3, state: "importing", bytes: 100),
            job(droneB, index: 4, state: "interrupted", bytes: 10)
        ]
        let progress = GCSBatchProgress(transfers: queue)
        XCTAssertEqual(progress.totalCount, 8)
        XCTAssertEqual(progress.totalBytes, 800)
        XCTAssertEqual(progress.completedBytes, 400)
        XCTAssertEqual(progress.fraction, 399.0 / 800.0, accuracy: 0.000001)
        XCTAssertEqual(progress.completedCount, 2)
        XCTAssertEqual(progress.failedCount, 2)
        XCTAssertEqual(progress.stoppedCount, 1)
        XCTAssertEqual(progress.activeCount, 2)
        XCTAssertEqual(progress.pendingCount, 1)
    }

    func testTransportAtOneHundredPercentDoesNotClaimImportCompletion() {
        let progress = GCSBatchProgress(transfers: [job(droneA, state: "importing", bytes: 100)])
        XCTAssertEqual(progress.fraction, 0.99)
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertEqual(progress.activeCount, 1)
        XCTAssertEqual(progress.totalCount, 1)
    }

    func testEmptyBatchAndInvalidByteCountsHaveBoundedProgress() {
        let empty = GCSBatchProgress(transfers: [])
        XCTAssertEqual(empty.fraction, 0)
        XCTAssertEqual(empty.totalCount, 0)
        XCTAssertEqual(empty.completedBytes, 0)

        let progress = GCSBatchProgress(transfers: [
            job(droneA, state: "downloading", bytes: 150),
            job(droneB, state: "downloading", bytes: -20),
            job(droneC, size: -10, bytes: 20)
        ])
        XCTAssertEqual(progress.totalBytes, 200)
        XCTAssertEqual(progress.completedBytes, 100)
        XCTAssertEqual(progress.fraction, 0.495)
    }

    private func job(_ uuid: String, index: Int = 0, state: String = "queued", size: Int64 = 100, bytes: Int64 = 0, host: String = "gcs.local") -> GCSTransfer {
        var value = GCSTransfer(droneUUID: uuid, remotePath: "/fs/microsd/log/2026-09-29/\(index).ulg", size: size, host: host, destination: "/tmp/katalog-tests")
        value.state = state
        value.completedBytes = bytes
        return value
    }
}
