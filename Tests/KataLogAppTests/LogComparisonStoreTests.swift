import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class LogComparisonStoreTests: XCTestCase {
    private func log(_ id: String, controller: String = "synthetic-controller", value: Int = 1) throws -> FlightLog {
        let fields: [String: Any] = ["id": id, "droneID": controller, "droneName": "Demo",
            "date": "2026-01-01", "dateSource": "gps", "sourcePaths": [], "fileName": id + ".ulg",
            "sizeBytes": 0, "durationSeconds": 60, "status": "ok", "issues": [], "metadata": ["firmware": "test-\(value)"],
            "topics": [], "messages": [], "metrics": [], "coverage": [], "failsafeObserved": false,
            "parameterDetails": ["schemaVersion": 1, "initial": [["name": "DEMO", "type": "int", "value": value]], "changes": []]]
        return try JSONDecoder().decode(FlightLog.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func settle(_ store: LogComparisonStore) async throws {
        let deadline = Date().addingTimeInterval(2)
        while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isLoading)
    }
    func testTwoDetailsAreComparedAndDirectionCanBeReversed() async throws {
        var reads: [String] = []
        let store = LogComparisonStore { [self] id in reads.append(id); return try log(id, value: id == "a" ? 1 : 2) }
        store.load(logIDs: ["a", "b"]); try await settle(store)
        XCTAssertEqual(reads, ["a", "b"])
        XCTAssertNil(store.error); XCTAssertTrue(store.comparison?.comparable == true)
        XCTAssertTrue(store.comparison?.firmwareDiffers == true)
        XCTAssertEqual(store.comparison?.differences.first?.before?.description, "1")
        store.swap()
        XCTAssertEqual(store.first?.id, "b")
        XCTAssertEqual(store.comparison?.differences.first?.before?.description, "2")
        XCTAssertEqual(reads.count, 2, "Swapping the displayed direction must not reparse logs.")
    }
    func testUnknownAndDistinctControllersCannotBeComparedDespiteMatchingNames() throws {
        let first = try log("a")
        XCTAssertThrowsError(try LogComparisonStore.validate(first: first, second: log("b", controller: "other")))
        for key in ["", "unknown:example", "card:example"] {
            XCTAssertThrowsError(try LogComparisonStore.validate(first: log("a", controller: key), second: log("b", controller: key)))
        }
        var second = try log("b"); second.identityProvisional = true
        XCTAssertThrowsError(try LogComparisonStore.validate(first: first, second: second))
    }
    func testMissingTypedExtractionIsExplainedWithoutInventingParameterRemoval() async throws {
        let store = LogComparisonStore { [self] id in
            var value = try log(id); if id == "b" { value.parameterDetails = nil }; return value
        }
        store.load(logIDs: ["a", "b"]); try await settle(store)
        XCTAssertNil(store.error); XCTAssertFalse(store.comparison?.comparable ?? true)
        XCTAssertTrue(store.comparison?.differences.isEmpty == true)
        XCTAssertTrue(store.comparison?.explanation.contains("non extraits") == true)
    }
    func testInvalidSelectionDoesNotReadAndMismatchedReplyCannotPublish() async throws {
        var reads = 0
        let store = LogComparisonStore { [self] _ in reads += 1; return try log("wrong") }
        for ids in [[], ["a"], ["a", "a"], ["a", "b", "c"]] {
            store.load(logIDs: ids); XCTAssertNotNil(store.error)
        }
        XCTAssertEqual(reads, 0)
        store.load(logIDs: ["a", "b"]); try await settle(store)
        XCTAssertNotNil(store.error); XCTAssertNil(store.comparison)
    }
    func testCancellationSuppressesLateReplyAndSkipsSecondRead() async throws {
        var pending: CheckedContinuation<FlightLog, Error>?
        var reads: [String] = []
        let store = LogComparisonStore { id in
            reads.append(id)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        store.load(logIDs: ["a", "b"])
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        store.cancel(); pending?.resume(returning: try log("a"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(reads, ["a"]); XCTAssertNil(store.comparison); XCTAssertFalse(store.isLoading)
    }
    func testRetryReplacesFailureAndStaleResponse() async throws {
        var pending: CheckedContinuation<FlightLog, Error>?
        var calls = 0
        let store = LogComparisonStore { [self] id in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return try log(id)
        }
        store.load(logIDs: ["old-a", "old-b"])
        for _ in 0..<100 where pending == nil { await Task.yield() }
        store.load(logIDs: ["new-a", "new-b"]); try await settle(store)
        pending?.resume(returning: try log("old-a"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.first?.id, "new-a"); XCTAssertEqual(store.second?.id, "new-b")
        XCTAssertNil(store.error)
    }
    func testFailedReadRemainsAnErrorUntilExplicitRetrySucceeds() async throws {
        var failed = false
        let store = LogComparisonStore { [self] id in
            if id == "b", !failed { failed = true; throw AnalysisError.engine("Source synthétique indisponible") }
            return try log(id)
        }
        store.load(logIDs: ["a", "b"]); try await settle(store)
        XCTAssertNotNil(store.error); XCTAssertNil(store.comparison)
        store.load(logIDs: ["a", "b"]); try await settle(store)
        XCTAssertNil(store.error); XCTAssertNotNil(store.comparison)
    }
}
