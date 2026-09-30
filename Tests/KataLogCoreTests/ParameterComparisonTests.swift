import XCTest
@testable import KataLogCore

final class ParameterComparisonTests: XCTestCase {
    private func log() -> FlightLog {
        FlightLog(id: "sha", droneID: "synthetic", droneName: "Demo", date: "", dateSource: "unknown", sourcePaths: [], fileName: "demo.ulg", sizeBytes: 1, durationSeconds: 1, flightSeconds: nil, status: "ok", issues: [], metadata: [:], topics: [], messages: [], metrics: [], coverage: [], failsafeObserved: false)
    }
    private func entry(_ name: String, _ type: String, _ value: JSONValue) -> JSONValue {
        .object(["name": .string(name), "type": .string(type), "value": value])
    }
    private func details(_ initial: [JSONValue], changes: [JSONValue] = []) -> JSONValue {
        .object(["schemaVersion": 1, "initial": .array(initial), "changes": .array(changes)])
    }
    func testTypedFinalValuesAbsentNamesAndFirmwareRemainDistinct() {
        var old = log(), new = log()
        old.metadata["firmware"] = "synthetic-v1"; new.metadata["firmware"] = "synthetic-v2"
        old.parameterDetails = details([entry("EXACT", "int", .unsigned(UInt64.max)), entry("CHANGE", "float", 1), entry("ABSENT", "int", 4)])
        new.parameterDetails = details([entry("EXACT", "int", .unsigned(UInt64.max)), entry("CHANGE", "float", 1), entry("NEW", "int", 3)], changes: [entry("CHANGE", "float", 2)])
        let comparison = ParameterComparison.compare(previous: old, current: new)
        XCTAssertTrue(comparison.comparable); XCTAssertTrue(comparison.firmwareDiffers)
        XCTAssertEqual(comparison.differences.map(\.name), ["ABSENT", "CHANGE", "NEW"])
        XCTAssertEqual(comparison.differences.map(\.change), [.absent, .value, .added])
        new.parameterDetails = details([entry("EXACT", "float", .unsigned(UInt64.max))])
        XCTAssertEqual(ParameterComparison.compare(previous: old, current: new).differences.first { $0.name == "EXACT" }?.change, .type)
    }
    func testMissingExtractionAndDifferentControllerAreNotParameterRemoval() {
        var old = log(), new = log()
        old.parameterDetails = details([entry("A", "int", 1)])
        let missing = ParameterComparison.compare(previous: old, current: new)
        XCTAssertFalse(missing.comparable); XCTAssertTrue(missing.differences.isEmpty)
        new.parameterDetails = details([]); new.droneID = "other"
        XCTAssertFalse(ParameterComparison.compare(previous: old, current: new).comparable)
    }
}
