import XCTest
@testable import KataLogCore

final class GCSTransferRatesTests: XCTestCase {
    func testAggregatesWorkersWithoutMixingTransportsOrCachedOffsets() throws {
        var rates = GCSTransferRates()
        rates.record(id: "a", phase: "http", bytes: 1_000_000, now: 10)
        XCTAssertNil(rates.bytesPerSecond(phase: "http", now: 10), "A resumed offset is not a transfer rate.")
        rates.record(id: "a", phase: "http", bytes: 1_000_200, now: 12)
        rates.record(id: "b", phase: "http", bytes: 0, now: 10)
        rates.record(id: "b", phase: "http", bytes: 400, now: 12)
        rates.record(id: "c", phase: "drone", bytes: 0, now: 10)
        rates.record(id: "c", phase: "drone", bytes: 2_000, now: 12)
        XCTAssertEqual(try XCTUnwrap(rates.bytesPerSecond(phase: "http", now: 12)), 300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rates.bytesPerSecond(phase: "drone", now: 12)), 1_000, accuracy: 0.001)
        rates.remove(id: "b")
        XCTAssertEqual(try XCTUnwrap(rates.bytesPerSecond(phase: "http", now: 12)), 100, accuracy: 0.001)
    }

    func testCounterResetPhaseChangeAndStaleMeasurementsCannotShowOldSpeed() {
        var rates = GCSTransferRates()
        rates.record(id: "a", phase: "drone", bytes: 0, now: 0)
        rates.record(id: "a", phase: "drone", bytes: 2_000, now: 2)
        XCTAssertNil(rates.bytesPerSecond(phase: "drone", now: 8))
        rates.record(id: "a", phase: "http", bytes: 800, now: 9)
        XCTAssertNil(rates.bytesPerSecond(phase: "drone", now: 9))
        XCTAssertNil(rates.bytesPerSecond(phase: "http", now: 9))
        rates.record(id: "a", phase: "http", bytes: 1_000, now: 10)
        XCTAssertEqual(rates.bytesPerSecond(phase: "http", now: 10), 200)
        rates.record(id: "a", phase: "http", bytes: 0, now: 11)
        XCTAssertNil(rates.bytesPerSecond(phase: "http", now: 11))
        rates.record(id: "a", phase: "verification", bytes: 1_000, now: 12)
        XCTAssertNil(rates.bytesPerSecond(phase: "http", now: 12))
    }

    func testIdleTimeLowersMeasuredRateAndOldBurstLeavesRollingWindow() {
        var rates = GCSTransferRates()
        rates.record(id: "a", phase: "http", bytes: 0, now: 0)
        rates.record(id: "a", phase: "http", bytes: 1_000, now: 1)
        XCTAssertEqual(rates.bytesPerSecond(phase: "http", now: 2), 500)
        for time in 2...6 { rates.record(id: "a", phase: "http", bytes: 1_000, now: Double(time)) }
        XCTAssertEqual(rates.bytesPerSecond(phase: "http", now: 6), 0)
    }
}
