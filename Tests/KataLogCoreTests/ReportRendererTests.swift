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

    func testTypedRecordedDetailsRemainVisibleAndHostileTextEscaped() throws {
        var flight = log("typed", messages: [])
        flight.batteryDetails = .object(["serial": .string("demo-pack-serial"), "unknown": .null])
        flight.parameterDetails = .object(["value": .unsigned(UInt64.max), "name": .string("<img src=x onerror=alert(1)>")])
        flight.dropouts = [.object(["durationMilliseconds": 5, "timing": .string("last_data_timestamp")])]
        let html = ReportRenderer.html(snapshot([flight]))
        XCTAssertTrue(html.contains("Batteries par instance"))
        XCTAssertTrue(html.contains("18446744073709551615"))
        XCTAssertTrue(html.contains("Interruptions de journalisation"))
        XCTAssertFalse(html.contains("<img src=x onerror=alert(1)>"))
        let decoded = try AnalysisService.decode(ReportRenderer.json(snapshot([flight])))
        XCTAssertEqual(decoded.logs.first?.parameterDetails?["value"], .unsigned(UInt64.max))
        XCTAssertEqual(decoded.logs.first?.batteryDetails?["unknown"], .null)
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

    func testDetailedReportIncludesParametersChangesAndTopicInstancesWithEscapedValues() throws {
        var flight = log("detail", messages: [])
        flight.parameters = ["PARAM_<unsafe>": "éè <value>&"]
        flight.parameterChanges = [ParameterChange(timeSeconds: 1.25, name: "PARAM_<unsafe>", value: "new <value>")]
        flight.topicDetails = [TopicDetail(name: "sensor_gps", instance: 1, sampleCount: 4, fields: ["eph", "fix_type"], fieldUnits: ["eph": "m"])]
        let manifest = ReportScopeManifest.describing(snapshot([flight]), mode: .flight)
        let html = ReportRenderer.html(snapshot([flight]), manifest: manifest)
        XCTAssertTrue(html.contains("Paramètres initiaux · 1"))
        XCTAssertTrue(html.contains("Changements de paramètres · 1"))
        XCTAssertTrue(html.contains("PARAM_&lt;unsafe&gt;"))
        XCTAssertFalse(html.contains("PARAM_<unsafe>"))
        XCTAssertTrue(html.contains("new &lt;value&gt;"))
        XCTAssertTrue(html.contains("sensor_gps"))
        XCTAssertTrue(html.contains("eph · m"))
        XCTAssertTrue(html.contains("fix_type · unité non renseignée"))
        XCTAssertEqual(manifest.completeness, .partial)
        XCTAssertTrue(manifest.availableSections.contains("parameters"))
        XCTAssertTrue(manifest.unavailableSections.contains("telemetry"))
    }

    func testScopeManifestIsVersionedAndSafelyEmbeddedWithoutChangingSnapshotJSON() throws {
        let snapshot = snapshot([log("manifest", messages: [message("m")])])
        var manifest = ReportScopeManifest.describing(snapshot, mode: .selection,
                                                     scopeDescription: "Batterie </script><img src=x> éè", revision: "revision-7", includesMaskedMessages: false)
        manifest.generatedAt = "2030-02-01T12:00:00Z"
        let html = ReportRenderer.html(snapshot, manifest: manifest)
        let payload = try payload(in: html)
        let exported = try XCTUnwrap(payload["manifest"] as? [String: Any])
        XCTAssertEqual(exported["schemaVersion"] as? Int, 1)
        XCTAssertEqual(exported["mode"] as? String, "selection")
        XCTAssertEqual(exported["scopeDescription"] as? String, manifest.scopeDescription)
        XCTAssertEqual(exported["revision"] as? String, "revision-7")
        XCTAssertEqual(exported["includesMaskedMessages"] as? Bool, false)
        XCTAssertTrue(html.contains("Tout le périmètre exporté"))
        XCTAssertFalse(html.contains("Toute la bibliothèque"))
        XCTAssertTrue(html.contains("Exporté le 2030-02-01T12:00:00Z"))
        XCTAssertFalse(html.contains("<img src=x>"))
        XCTAssertTrue(html.contains("Les messages masqués sont exclus"))
        XCTAssertEqual(try AnalysisService.decode(ReportRenderer.json(snapshot)).schemaVersion, 1)
    }

    func testMeasuredHTMLBudgetDoesNotSilentlyDiscardAnyRecord() throws {
        let input = snapshot([log("one", messages: [message("m1"), message("m2")])])
        let document = ReportRenderer.document(input, byteBudget: 1)
        XCTAssertTrue(document.exceedsBudget)
        XCTAssertEqual(document.byteCount, document.html.utf8.count)
        XCTAssertEqual(document.byteBudget, 1)
        let logs = try XCTUnwrap(try payload(in: document.html)["logs"] as? [[String: Any]])
        XCTAssertEqual((logs.first?["messages"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(document.html.contains("métadonnées"))
    }

    func testFailsafeOnlyLogIsCountedWithoutCreatingATextualFamilyOrMessage() {
        var flight = log("failsafe", messages: [])
        flight.failsafeObserved = true
        let html = ReportRenderer.html(snapshot([flight]))
        XCTAssertTrue(html.contains("0 messages d’alerte · 1 log avec failsafe"))
        XCTAssertTrue(html.contains("PROFIL DES ALERTES TEXTUELLES"))
        XCTAssertFalse(html.contains("class=\"family-row\""))
        XCTAssertFalse(html.contains("class=\"message-row\""))
    }

    func testMalformedRawEventIDAndNullTimestampRemainSafeAndPreserved() throws {
        var flight = log("event-malformed", messages: [])
        flight.events = [PX4Event(id: "event:0:0", eventID: .string("raw </script><img src=x> éè"),
                                 timeSeconds: nil, level: "UNKNOWN", message: nil,
                                 argumentsHex: "00ff", definitionSource: nil,
                                 rawTimestamp: .object(["encoding": .string("nonfinite"), "value": .string("nan")]),
                                 translationStatus: "invalid")]
        let html = ReportRenderer.html(snapshot([flight]))
        XCTAssertTrue(html.contains("<td>—</td>"))
        XCTAssertTrue(html.contains("raw &lt;/script&gt;&lt;img src=x&gt; éè"))
        XCTAssertFalse(html.contains("<img src=x>"))
        let decoded = try AnalysisService.decode(ReportRenderer.json(snapshot([flight])))
        XCTAssertEqual(decoded.logs[0].events?[0].eventID, flight.events?[0].eventID)
        XCTAssertNil(decoded.logs[0].events?[0].timeSeconds)
    }

    func testLazyTableFallbackUsesValidFlowWrappersAndPreservesTimeAndManualFamily() throws {
        var source = message("manual")
        source.sourceFamily = "Détectée <capteur>"
        let html = ReportRenderer.html(snapshot([log("lazy", messages: [source])]))
        XCTAssertTrue(html.contains("<noscript class=\"message-fallback\"><div class=\"table-wrap\"><table"))
        XCTAssertTrue(html.contains("<noscript class=\"occurrence-fallback\"><div class=\"table-wrap\"><table"))
        XCTAssertFalse(html.contains("<tbody><noscript"))
        XCTAssertTrue(html.contains("lazy-message-table"))
        let records = try XCTUnwrap(try payload(in: html)["logs"] as? [[String: Any]])
        let messages = try XCTUnwrap(records.first?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["timeSeconds"] as? Double, -0.25)
        XCTAssertEqual(messages.first?["sourceFamily"] as? String, source.sourceFamily)
        XCTAssertTrue(html.contains("Détectée &lt;capteur&gt;"))
    }

    func testDurationsAndProvisionalIdentitiesHaveIndependentValuesAndAccessibleHelp() throws {
        var measured = log("flight", messages: [])
        measured.flightSeconds = 20
        var provisional = log("provisional", droneID: "card:source", messages: [])
        provisional.flightSeconds = 0
        let unavailable = log("unavailable", messages: [])
        var failed = log("failed", droneID: "unknown:source", messages: [])
        failed.status = "error"; failed.flightSeconds = 400
        let html = ReportRenderer.html(snapshot([measured, provisional, unavailable, failed]))
        XCTAssertTrue(html.contains("Drones scannés"))
        XCTAssertTrue(html.contains("id=\"stat-drones\">1</strong>"))
        XCTAssertTrue(html.contains("id=\"stat-provisional\">2 identités provisoires"))
        XCTAssertTrue(html.contains("Calculé sur 2 / 4 logs"))
        XCTAssertTrue(html.contains("Temps de vol cumulé"))
        XCTAssertTrue(html.contains("aria-label=\"Aide : Durée enregistrée\""))
        XCTAssertTrue(html.contains("<details class=\"report-help\"><summary title="))
        XCTAssertTrue(html.contains(".detail-pagination, .report-help { display: none !important; }"))
        let logs = try XCTUnwrap(try payload(in: html)["logs"] as? [[String: Any]])
        XCTAssertTrue(logs.first { $0["id"] as? String == "unavailable" }?["flightSeconds"] is NSNull)
        XCTAssertEqual(logs.first { $0["id"] as? String == "provisional" }?["flightSeconds"] as? Double, 0)
        XCTAssertEqual(logs.first { $0["id"] as? String == "provisional" }?["identityProvisional"] as? Bool, true)
        XCTAssertTrue(ReportRenderer.html(snapshot([unavailable])).contains("id=\"stat-flight\">Non disponible"))
    }

    func testBadgeIsDistinctFromReadingQualityAndJSONRetainsSameAssessment() throws {
        var partial = log("partial", messages: [message("warning", level: "WARNING")])
        partial.status = "partial"
        partial.events = [PX4Event(id: "raw", eventID: .integer(42), timeSeconds: nil,
            level: "INFO", message: nil, argumentsHex: "00ff", definitionSource: nil,
            internalLevelName: "WARNING", externalLevelName: "CRITICAL", translationStatus: "untranslated")]
        let html = ReportRenderer.html(snapshot([partial]))
        XCTAssertTrue(html.contains("class=\"log-assessment red\""))
        XCTAssertTrue(html.contains("Signal critique</span>"))
        XCTAssertTrue(html.contains("Lecture partielle</span>"))
        XCTAssertTrue(html.contains("Événement PX4 42"))
        let decoded = try AnalysisService.decode(ReportRenderer.json(snapshot([partial])))
        XCTAssertEqual(decoded.logs[0].signalAssessment, partial.assessment)
        XCTAssertEqual(decoded.logs[0].signalAssessment?.untranslatedEventCount, 1)
        let old = log("old", messages: [])
        XCTAssertTrue(ReportRenderer.html(snapshot([old])).contains("Niveau indéterminé</span>"))
        XCTAssertFalse(ReportRenderer.html(snapshot([old])).contains("Aucune alerte détectée</span>"))
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
