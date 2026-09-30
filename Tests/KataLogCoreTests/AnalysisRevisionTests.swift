import Foundation
import XCTest
@testable import KataLogCore

final class AnalysisRevisionTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-revision-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("revision.py"), response = root.appendingPathComponent("response.json")
        try """
        import sys
        from pathlib import Path
        assert '--read-only' in sys.argv
        assert sys.argv[1] in ['analysis-revisions','detail']
        Path(sys.argv[sys.argv.index('--output')+1]).write_bytes(Path(__file__).with_name('response.json').read_bytes())
        """.write(to: engine, atomically: true, encoding: .utf8)
        return (root, engine, response)
    }
    func testHistoryPagesAreReadOnlyAndRejectFutureProtocol() async throws {
        let (root, engine, response) = try fixture()
        let sha = String(repeating: "a", count: 64)
        var payload: [String: Any] = ["revisionVersion": 1, "logID": "log", "total": 1, "nextOffset": NSNull(), "revisions": [["id": sha, "kind": "detail", "parserVersion": "1.3.0", "analysisSHA256": sha, "createdAt": "2030-01-01T00:00:00Z", "sizeBytes": 12, "current": false]]]
        try JSONSerialization.data(withJSONObject: payload).write(to: response)
        let page = try await AnalysisRevisionService.page(logID: "log", database: root.appendingPathComponent("fixture.sqlite"), engine: engine)
        XCTAssertEqual(page.revisions.first?.parserVersion, "1.3.0")
        XCTAssertEqual(page.revisions.first?.current, false)
        payload["revisionVersion"] = 2
        try JSONSerialization.data(withJSONObject: payload).write(to: response)
        do {
            _ = try await AnalysisRevisionService.page(logID: "log", database: root.appendingPathComponent("fixture.sqlite"), engine: engine)
            XCTFail("Future revision protocol must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incompatible")) }
    }
    func testHistoricalDetailPreservesCurrentLogAndChecksExactRevision() async throws {
        let (root, engine, response) = try fixture()
        let sha = String(repeating: "b", count: 64)
        var log = FlightLog(id: "log", droneID: "synthetic-controller", droneName: "Recorded name", date: "", dateSource: "unknown", sourcePaths: [], fileName: "demo.ulg", sizeBytes: 2, durationSeconds: 1, flightSeconds: nil, status: "ok", issues: [], metadata: [:], topics: [], messages: [], metrics: [], coverage: [], failsafeObserved: false)
        log.analysisRevision = .object(["schemaVersion": 1, "id": .string(sha), "current": .bool(false)])
        try JSONEncoder().encode(log).write(to: response)
        let detail = try await AnalysisRevisionService.detail(logID: "log", revisionID: sha, database: root.appendingPathComponent("fixture.sqlite"), engine: engine)
        XCTAssertEqual(detail.analysisRevision?["current"], .bool(false))
        XCTAssertTrue(detail.sourcePaths.isEmpty)
        do {
            _ = try await AnalysisRevisionService.detail(logID: "log", revisionID: String(repeating: "c", count: 64), database: root.appendingPathComponent("fixture.sqlite"), engine: engine)
            XCTFail("Wrong revision must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("révision demandée")) }
    }
}
