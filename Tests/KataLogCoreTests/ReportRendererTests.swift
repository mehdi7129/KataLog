import Foundation
import XCTest
@testable import KataLogCore

final class ReportRendererTests: XCTestCase {
    func testStandaloneReportHasInlineDataAndNoExternalRuntimeDependency() throws {
        let html = ReportRenderer.html(snapshot([log("one", messages: [message("m")])]))
        let payload = try payload(in: html)
        XCTAssertNotNil(payload["logs"])
        XCTAssertTrue(html.lowercased().contains("<!doctype html>"))
        XCTAssertTrue(html.contains("lang=\"fr\"") || html.contains("lang='fr'"))
        for pattern in [#"<script\b[^>]*\bsrc\s*="#,
                        #"<link\b[^>]*\brel\s*=\s*["']stylesheet["'][^>]*\bhref\s*=\s*["']https?:"#,
                        #"@import\s+(?:url\()?\s*["']?https?:"#] {
            XCTAssertNil(html.range(of: pattern, options: [.regularExpression, .caseInsensitive]), pattern)
        }
    }

    func testScriptPayloadCannotBeClosedBySourceTextAndRestoresOriginalStrings() throws {
        let attack = "</script><img src=x onerror=alert(1)><script>alert('x')</script>&\"'\u{2028}\u{2029}"
        let unsafe = message("unsafe", text: attack, family: "Famille <atelier>&")
        var flight = log("sha-unsafe", messages: [unsafe])
        flight.droneName = "Drone <source>&"
        flight.sourcePaths = ["/card/<source>&.ulg"]
        flight.metadata["note"] = attack
        let html = ReportRenderer.html(snapshot([flight]))
        let raw = try rawPayload(in: html)
        XCTAssertFalse(raw.contains("<"), "The raw-text script element must escape HTML delimiters before insertion.")
        XCTAssertFalse(raw.contains("&"), "HTML-significant source content must be encoded consistently.")
        XCTAssertFalse(html.contains("<img src=x onerror=alert(1)>"))
        XCTAssertFalse(html.contains("<script>alert('x')</script>"))
        let data = try payload(in: html)
        let strings = allStrings(in: data)
        XCTAssertTrue(strings.contains(attack), "Escaping must preserve the original message after JSON decoding.")
        XCTAssertTrue(strings.contains("Famille <atelier>&"))
        XCTAssertTrue(strings.contains("Drone <source>&"))
        XCTAssertTrue(html.contains("/card/&lt;source&gt;&amp;.ulg"))
    }

    func testEmbeddedDataRetainsAllMessagesAndDistinctIdentitiesWithMatchingDisplayNumbers() throws {
        var first = log("sha-one", messages: [
            message("repeat-1"), message("repeat-2"),
            message("info", level: "INFO", text: "Boot complete", family: "Système", alert: false)
        ])
        first.stockNumber = "00042"
        var second = log("sha-two", droneID: "controller-two", messages: [])
        second.stockNumber = "00042"
        let original = snapshot([first, second])
        let html = ReportRenderer.html(original)
        let data = try payload(in: html)
        let logs = try XCTUnwrap(data["logs"] as? [[String: Any]])
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(Set(logs.compactMap { $0["droneID"] as? String }), ["controller-one", "controller-two"])
        let exportedFirst = try XCTUnwrap(logs.first { $0["id"] as? String == "sha-one" })
        let messages = try XCTUnwrap(exportedFirst["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3, "Repeated messages and INFO remain available behind report filters.")
        XCTAssertEqual(Set(messages.compactMap { $0["id"] as? String }), ["repeat-1", "repeat-2", "info"])
        XCTAssertEqual(messages.first { $0["id"] as? String == "info" }?["isAlert"] as? Bool, false)
        XCTAssertTrue(html.contains("Drone 00042"))
        XCTAssertFalse(html.contains("Drone Drone"))
        let json = try AnalysisService.decode(ReportRenderer.json(original))
        XCTAssertEqual(json.logs[0].messages.count, 3)
        XCTAssertEqual(json.logs[0].stockNumber, "00042")
        XCTAssertEqual(json.logs[0].droneName, "Nom source")
        XCTAssertEqual(json.drones.count, 2)
    }

    func testEmptySnapshotIsAValidStandaloneReport() throws {
        let html = ReportRenderer.html(.empty)
        let data = try payload(in: html)
        XCTAssertEqual((data["logs"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(try rawPayload(in: html).contains("NaN"))
        XCTAssertFalse(try rawPayload(in: html).contains("Infinity"))
        XCTAssertTrue(html.contains("kataLOG") || html.contains("KataLog"))
    }

    func testReportPeriodExcludesUnknownAndImpossibleDates() {
        var unknown = log("unknown", messages: [])
        unknown.date = "Date inconnue"
        var impossible = log("impossible", messages: [])
        impossible.date = "2026-02-30T12:00:00Z"
        let valid = log("valid", messages: [])
        let html = ReportRenderer.html(snapshot([unknown, impossible, valid]))
        XCTAssertTrue(html.contains("<p>2026-09-29</p>"))
        XCTAssertFalse(html.contains("2026-02-30 →"))
        XCTAssertTrue(ReportRenderer.html(snapshot([unknown, impossible])).contains("Période non renseignée"))
    }

    private func rawPayload(in html: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"<script\b[^>]*\bid\s*=\s*["']report-data["'][^>]*>([\s\S]*?)</script\s*>"#, options: .caseInsensitive)
        let match = try XCTUnwrap(expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), "A report-data JSON script is required for offline interactivity.")
        let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
        return String(html[range])
    }

    private func payload(in html: String) throws -> [String: Any] {
        let data = Data(try rawPayload(in: html).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func allStrings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(allStrings) }
        if let object = value as? [String: Any] { return object.values.flatMap(allStrings) }
        return []
    }

    private func message(_ id: String, level: String = "ERROR", text: String = "[wifi_broadcom] Wifi link lost", family: String = "Communication", alert: Bool = true) -> LogMessage {
        LogMessage(id: id, timestampSeconds: -0.25, level: level, text: text, family: family,
                   groupKey: "\(level)|\(text)", title: text, alertFlag: alert)
    }

    private func log(_ id: String, droneID: String = "controller-one", messages: [LogMessage]) -> FlightLog {
        FlightLog(id: id, droneID: droneID, droneName: "Nom source", date: "2026-09-29T12:00:00Z", dateSource: "GPS UTC", sourcePaths: ["/card/\(id).ulg"], fileName: "\(id).ulg", sizeBytes: 100,
                  durationSeconds: 60, flightSeconds: nil, status: "ok", issues: [], metadata: ["firmware": "custom"], topics: ["event"], messages: messages, metrics: [], coverage: ["Événements non décodés"], failsafeObserved: false)
    }

    private func snapshot(_ logs: [FlightLog]) -> FleetSnapshot {
        FleetSnapshot(schemaVersion: 1, generatedAt: "2026-09-29T12:00:00Z", sourceFolders: ["/card"], importStats: .empty, logs: logs)
    }
}
