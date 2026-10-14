import XCTest
import KataLogCore
@testable import KataLog

final class GCSStorageAdmissionTests: XCTestCase {
    private func job(size: Int64 = 1_000, destination: String = "/synthetic/collection") -> GCSTransfer {
        GCSTransfer(droneUUID: "0102030405060708090A0B0C", remotePath: "/fs/microsd/log/test.ulg",
                    size: size, host: "gcs.local", destination: destination)
    }

    func testReservationCountsFTPAtFullSizeAndOnlyRemainingHTTPBytes() {
        let current = job()
        var ftp = job(), http = job(), verified = job()
        ftp.phase = "drone"; ftp.phaseBytes = ftp.size
        http.phase = "http"; http.completedBytes = 300
        verified.phase = "verified"; verified.completedBytes = verified.size
        let elsewhere = job(size: 100_000, destination: "/other/collection")
        XCTAssertEqual(GCSStore.reservedDownloadBytes(for: current,
            active: [current, ftp, http, verified]), 1_700)
        XCTAssertEqual(GCSStore.reservedDownloadBytes(for: current, active: [elsewhere]), 100_000,
                       "Another directory may share the destination volume, including retried old jobs.")
        XCTAssertEqual(GCSStore.reservedDownloadBytes(for: current, active: [current, verified]), 0)
    }

    func testReservationClampsMalformedCountsAndCannotOverflow() {
        let current = job()
        var negativeProgress = job(), excessiveProgress = job()
        negativeProgress.completedBytes = -1
        excessiveProgress.completedBytes = 2_000
        XCTAssertEqual(GCSStore.reservedDownloadBytes(for: current,
            active: [negativeProgress, excessiveProgress, job(size: -1)]), 1_000)
        XCTAssertEqual(GCSStore.reservedDownloadBytes(for: current,
            active: [job(size: Int64.max), job(size: Int64.max)]), Int64.max)
    }
}
