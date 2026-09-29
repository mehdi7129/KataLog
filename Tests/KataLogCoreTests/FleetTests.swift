import XCTest
@testable import KataLogCore

final class FleetTests: XCTestCase {
    private func message(_ id: String, level: String = "ERROR", text: String = "Battery error", group: String = "battery", alert: Bool? = nil) -> LogMessage {
        LogMessage(id: id, timestampSeconds: -0.25, level: level, text: text, family: "Batterie", groupKey: group, title: text, alertFlag: alert)
    }
    private func log(_ id: String, drone: String = "A", messages: [LogMessage], status: String = "ok") -> FlightLog {
        FlightLog(id: id, droneID: drone, droneName: "Drone " + drone, date: "2026-01-18T12:00:00Z", dateSource: "GPS UTC", sourcePaths: ["/card/<source>.ulg"], fileName: id + ".ulg", sizeBytes: 100,
            durationSeconds: 60, flightSeconds: nil, status: status, issues: [], metadata: ["firmware": "custom"], topics: ["event"], messages: messages, metrics: [], coverage: ["Événements non décodés"], failsafeObserved: false)
    }
    private func snapshot(_ logs: [FlightLog]) -> FleetSnapshot {
        FleetSnapshot(schemaVersion: 1, generatedAt: "2026-09-29T12:00:00Z", sourceFolders: ["/card"], importStats: .empty, logs: logs)
    }

    func testRepeatedMessagesDoNotInflateLogOrDroneCounts() {
        let data = snapshot([
            log("1", messages: [message("a"), message("b")]),
            log("2", messages: [message("a")]),
            log("3", drone: "B", messages: [message("a")])
        ])
        XCTAssertEqual(data.alertGroups.count, 1)
        XCTAssertEqual(data.alertGroups[0].messageCount, 4)
        XCTAssertEqual(data.alertGroups[0].logCount, 3)
        XCTAssertEqual(data.alertGroups[0].droneIDs.count, 2)
        XCTAssertEqual(Set(data.alertGroups[0].occurrences.map(\.id)).count, 4)
        XCTAssertEqual(data.drones.count, 2)
        XCTAssertEqual(data.totalDurationSeconds, 180)
    }

    func testInformationIsPreservedWithoutBeingCountedAsAnAlert() throws {
        let data = snapshot([log("1", messages: [
            message("info", level: "INFO", text: "Boot completed", group: "boot", alert: false),
            message("alarm", level: "INFO", text: "[ALARM] COMMUNICATION_FENCING started", group: "alarm", alert: true)
        ])])
        let decoded = try AnalysisService.decode(ReportRenderer.json(data))
        XCTAssertEqual(decoded.logs[0].messages.count, 2)
        XCTAssertEqual(decoded.alertGroups.count, 2)
        XCTAssertEqual(decoded.alertGroups.filter(\.isAlert).count, 1)
        XCTAssertEqual(decoded.alertLogCount, 1)
        XCTAssertEqual(decoded.logs[0].messages[0].timestampSeconds, -0.25)
        XCTAssertNil(decoded.logs[0].flightSeconds)
    }

    func testErrorsDoNotAddRecordedDuration() {
        let data = snapshot([log("broken", messages: [], status: "error"), log("readable", messages: [])])
        XCTAssertEqual(data.logs.count, 2)
        XCTAssertEqual(data.validLogs.count, 1)
        XCTAssertEqual(data.totalDurationSeconds, 60)
        XCTAssertEqual(data.alertLogCount, 0)
    }

    func testReportEscapesUntrustedLogTextAndIncludesInfoAndCoverage() {
        let html = ReportRenderer.html(snapshot([log("1", messages: [
            message("1", level: "INFO", text: "<script>alert('x')</script>&", alert: false)
        ])]))
        XCTAssertFalse(html.contains("<script>alert('x')</script>"), "Source text must not become executable report code.")
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;&amp;"))
        XCTAssertTrue(html.contains("/card/&lt;source&gt;.ulg"))
        XCTAssertTrue(html.contains("INFO"))
        XCTAssertTrue(html.contains("Événements non décodés"))
        XCTAssertTrue(html.contains("non calculable"))
    }

    func testFutureSchemaIsRejected() throws {
        var data = FleetSnapshot.empty
        data.schemaVersion = 2
        XCTAssertThrowsError(try AnalysisService.decode(ReportRenderer.json(data))) { error in
            guard case AnalysisError.schema(2) = error else { return XCTFail("Wrong error: \(error)") }
        }
    }
}
