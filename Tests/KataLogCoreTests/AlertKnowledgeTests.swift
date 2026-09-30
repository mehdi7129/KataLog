import XCTest
@testable import KataLogCore

final class AlertKnowledgeTests: XCTestCase {
    func testObservedAlertsHaveSpecificExplanationsAndHonestProvenance() {
        let cases = [
            "[batt_smbus] SMBus read error: -1": "battery-smbus-read",
            "[wifi_broadcom] Wifi link lost": "wifi-link-lost",
            "[rgbled_pwm] Temperature too high, disabling LED": "led-temperature",
            "[health_and_arming_checks] Preflight Fail: Accel 0 inconsistent - check cal": "accelerometer-consistency"
        ]
        for (raw, id) in cases {
            let explanation = AlertKnowledge.explanation(forText: raw)
            XCTAssertEqual(explanation.id, id)
            XCTAssertFalse(explanation.checks.isEmpty)
            XCTAssertFalse(explanation.limits.isEmpty)
            XCTAssertTrue(explanation.sources.allSatisfy { $0.url.scheme == "https" && $0.url.host == "github.com" })
        }
        let imu = AlertKnowledge.explanation(forText: "[health_and_arming_checks] Preflight Fail: Accel 2 inconsistent - check cal")
        XCTAssertTrue(imu.limits.contains("80 %"))
        XCTAssertEqual(imu.sources.count, 1)
        XCTAssertTrue(AlertKnowledge.explanation(forText: "[wifi_broadcom] Wifi link lost").sources.isEmpty)
        XCTAssertEqual(imu.confidence, .documented)
        XCTAssertEqual(AlertKnowledge.explanation(forText: "[batt_smbus] SMBus read error: -1").confidence, .interpretation)
        XCTAssertFalse(AlertKnowledge.explanation(forText: "[wifi_broadcom] Wifi link lost").isDocumented)
        XCTAssertEqual(AlertKnowledge.explanation(forText: "inconnu").confidence, .raw)
    }

    func testPartialSimilarOrNegatedMessagesAreNotDiagnosed() {
        for raw in ["Wifi link lost", "[other_module] Wifi link lost", "[wifi_broadcom] Wifi link lost: false", "Not [batt_smbus] SMBus read error: -1", "[batt_smbus] SMBus read error: -2", "New unknown fault"] {
            XCTAssertEqual(AlertKnowledge.explanation(forText: raw).id, "unknown", raw)
        }
    }

    func testReportPreservesManualAndSourceIdentityAndClassification() throws {
        let message = LogMessage(id: "a", timestampSeconds: 1, level: "ERROR", text: "[wifi_broadcom] Wifi link lost", family: "Radio <atelier>", sourceFamily: "Communication", groupKey: "wifi", title: "Wifi link lost", alertFlag: true)
        var log = FlightLog(id: "sha", droneID: "hardware-original", droneName: "source <name>", date: "2026-09-29", dateSource: "path", sourcePaths: [], fileName: "flight.ulg", sizeBytes: 1, durationSeconds: 1, status: "ok", issues: [], metadata: ["gcsUUID": "1112131415161718191A1B1C"], topics: [], messages: [message, message], metrics: [], coverage: [], failsafeObserved: false)
        log.stockNumber = "00042"
        log.annotationWarning = "Conflit <identité> conservé"
        let snapshot = FleetSnapshot(schemaVersion: 1, generatedAt: "today", sourceFolders: [], importStats: .empty, logs: [log])
        let html = ReportRenderer.html(snapshot)
        XCTAssertTrue(html.contains("Drone 00042"))
        XCTAssertFalse(html.contains("Drone Drone"))
        XCTAssertTrue(html.contains("source &lt;name&gt;"))
        XCTAssertTrue(html.contains("Radio &lt;atelier&gt;"))
        XCTAssertTrue(html.contains("Famille détectée : Communication"))
        XCTAssertTrue(html.contains("gcs:1112131415161718191A1B1C"))
        XCTAssertTrue(html.contains("Conflit &lt;identité&gt; conservé"))
        XCTAssertEqual(html.components(separatedBy: "Le module Wi-Fi signale").count - 1, 1)
        let decoded = try AnalysisService.decode(ReportRenderer.json(snapshot))
        XCTAssertEqual(decoded.logs[0].stockNumber, "00042")
        XCTAssertEqual(decoded.logs[0].droneName, "source <name>")
        XCTAssertEqual(decoded.logs[0].messages[0].sourceFamily, "Communication")
    }
}
