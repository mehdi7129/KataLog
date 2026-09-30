import XCTest
@testable import KataLogCore

final class LibraryContractsTests: XCTestCase {
    func testNormalizedSearchMatchesSpacesAndDiacritics() {
        XCTAssertEqual(SelectionScope.normalizedSearch("  RÉSUMÉ\tprêt "), "resume pret")
        XCTAssertEqual(SelectionScope.normalizedSearch("Straße"), "strasse")
    }
    func testSourceCalendarDaysAreValidatedWithoutInventingTimezone() throws {
        XCTAssertEqual(SelectionScope.calendarDay("2024-02-29T12:00:00"), "2024-02-29")
        XCTAssertNil(SelectionScope.calendarDay("2026-02-29"))
        XCTAssertNil(SelectionScope.calendarDay("2026-13-03"))
        XCTAssertNil(SelectionScope.calendarDay("unknown"))
        let legacy = Data(#"{"search":"batterie"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SelectionScope.self, from: legacy).search, "batterie")
    }
    func testDiagnosticUsesOnlySafeStructuredKeys() throws {
        let report = DiagnosticReport(appVersion: "0.6.0", appBuild: "8", operations: ["import": true, "private-endpoint": true],
                                      counts: ["logs": 1, "private-controller": 2], runtimeBundled: true)
        let text = try XCTUnwrap(String(data: report.data(), encoding: .utf8))
        XCTAssertFalse(text.contains("private-endpoint"))
        XCTAssertFalse(text.contains("private-controller"))
        XCTAssertTrue(text.contains("privateDataIncluded"))
        XCTAssertEqual(report.operations, ["import": true])
        XCTAssertEqual(report.countScope, ["logs": .unavailable], "An unqualified caller cannot silently imply a global count.")
    }
    func testDiagnosticQualifiesEachCountAndRejectsPrivateScopeKeys() throws {
        let report = DiagnosticReport(appVersion: "0.6.0", appBuild: "8", operations: [:],
            counts: ["logs": 27, "messages": 27, "identities": 1, "jobs": 3, "private-id": 9],
            countScope: ["logs": .activeSelection, "messages": .activeSelection, "identities": .activeSelection,
                         "jobs": .application, "private-id": .library, "private-path": .library], runtimeBundled: true)
        XCTAssertEqual(report.countScope["logs"], .activeSelection)
        XCTAssertEqual(report.countScope["jobs"], .application)
        XCTAssertNil(report.countScope["private-id"])
        XCTAssertNil(report.countScope["private-path"])
        let data = try report.data(), text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("private-id")); XCTAssertFalse(text.contains("private-path"))
        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: data)
        XCTAssertEqual(decoded.countScope, report.countScope)
    }
    func testJSONUnknownValuesPreserve64BitIntegers() throws {
        let data = Data(#"{"serial":18446744073709551615,"signed":-9223372036854775808,"mixed":[true,null,1.5]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let fields) = value else { return XCTFail("object") }
        XCTAssertEqual(fields["serial"], .unsigned(.max))
        XCTAssertEqual(fields["signed"], .integer(.min))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }
    func testWriterLeasePreventsSecondWriterAndReleasesOnExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first: LibraryWriterLease? = try LibraryWriterLease(directory: root)
        XCTAssertTrue(first!.isWritable)
        let second = try LibraryWriterLease(directory: root)
        XCTAssertFalse(second.isWritable)
        first = nil
        let third = try LibraryWriterLease(directory: root)
        XCTAssertTrue(third.isWritable)
    }
    func testScopeExcludesMaskedAndDoesNotInventFailsafeText() throws {
        var log = fixture()
        log.failsafeObserved = true
        let snapshot = FleetSnapshot(schemaVersion: 1, generatedAt: "", sourceFolders: [], importStats: .empty, logs: [log])
        var scope = SelectionScope()
        let masked = Set(log.messages.map(\.classificationKey))
        XCTAssertEqual(scope.applying(to: snapshot, maskedMessageKeys: masked).logs.count, 1)
        XCTAssertEqual(scope.applying(to: snapshot, maskedMessageKeys: masked).alertLogCount, 1)
        scope.families = ["Navigation"]
        XCTAssertTrue(scope.applying(to: snapshot, maskedMessageKeys: masked).logs.isEmpty)
        scope.includeMasked = true
        XCTAssertEqual(scope.applying(to: snapshot, maskedMessageKeys: masked).logs.first?.messages.count, 1)
        XCTAssertEqual(scope.applying(to: snapshot, maskedMessageKeys: masked).failsafeLogCount, 0)
    }
    func testGNSSCoverageUsesLargestActualReceiverCoverage() {
        var log = fixture()
        log.metrics = [
            LogMetric(key: "gps.rtk_fixed", label: "", value: 100, unit: "%", detail: ""),
            LogMetric(key: "gps.observed_seconds", label: "", value: 2, unit: "s", detail: ""),
            LogMetric(key: "gps.rtk_fixed.1", label: "", value: 30, unit: "%", detail: ""), // gitleaks:allow -- synthetic telemetry field name
            LogMetric(key: "gps.observed_seconds.1", label: "", value: 20, unit: "s", detail: "")] // gitleaks:allow -- synthetic telemetry field name
        XCTAssertEqual(log.primaryGNSSCoverage?.instance, 1)
        XCTAssertEqual(log.primaryGNSSCoverage?.fixedPercent, 30)
    }
    private func fixture() -> FlightLog {
        FlightLog(id: "a", droneID: "anonymous", droneName: "Demo", date: "2026-01-01", dateSource: "path", sourcePaths: [], fileName: "demo.ulg", sizeBytes: 1, durationSeconds: 5, flightSeconds: nil, status: "ok", issues: [], metadata: [:], topics: [], messages: [LogMessage(id: "m", timestampSeconds: 1, level: "WARNING", text: "GPS error", family: "Navigation", groupKey: "gps", title: "GPS error", alertFlag: true)], metrics: [], coverage: [], failsafeObserved: false)
    }
}
