import XCTest
@testable import KataLogCore

final class AlertCatalogueTests: XCTestCase {
    func testCommandRoleAndUnknownResultAreVisibleWithoutOpeningTechnicalDetails() {
        for command in [21, 176, 246, 310, 400, 512, 45000, 45008] {
            for flag in [0, 1] {
                let explanation = AlertKnowledge.explanation(forText: "[mavlink] command number \(command) is ok \(flag)")
                XCTAssertNotEqual(explanation.id, "unknown")
                XCTAssertTrue(explanation.meaning.contains("ne confirme ni succès ni échec"))
                XCTAssertFalse(explanation.isDocumented)
            }
        }
        let show = AlertKnowledge.explanation(forText: "[mavlink] command number 45008 is ok 1")
        XCTAssertTrue(show.meaning.contains("démarrage, pause ou reprise"))
        let color = AlertKnowledge.explanation(forText: "[mavlink] command number 45000 is ok 1")
        XCTAssertTrue(color.meaning.contains("couleur des LED"))
    }

    func testObservedMessagesReceiveSpecificExplanationsAcrossSubsystems() {
        let cases = [
            "[ekf2] GPS emergency yaw reset": "gps-emergency-yaw-reset",
            "[vehicle_imu] Gyro 1 clipping, not safe to fly!": "gyro-clipping",
            "[health_and_arming_checks] Preflight Fail: Motor failure detected": "motor-failure-detected",
            "[wifi_broadcom] wapi_scan_stat() failed: -11, sleeptries: 22": "wifi-scan-status-failed",
            "[dance] GPS speed violation: 2.31 m/s": "dance-speed-gps",
            "[dance] Local speed violation: 10.15 m/s": "dance-speed-local",
            "[mavlink] command number 246 is ok 1": "mavlink-command-246",
            "[mavlink] command number 45008 is ok 1": "mavlink-command-45008",
            "[rgbled_pwm] Temperature OK, enabling LED": "led-temperature-recovered",
            "[xbee_radio] XBee link recovered": "xbee-link-recovered",
            "[batt_smbus] Failed to read temperature data": "battery-temperature-read",
            "[boat_pos_control] Reset loiter position": "boat-loiter-reset",
            "[uavcan:110:] Torqeedo: err:48 charging temp error": "torqeedo-charge-temperature",
            "[uavcan:112:] Torqeedo: err:50": "torqeedo-unmapped-error"
        ]
        for (text, id) in cases {
            let explanation = AlertKnowledge.explanation(forText: text + "\t\n")
            XCTAssertEqual(explanation.id, id, text)
            XCTAssertEqual(explanation.catalogueVersion, 3)
            XCTAssertFalse(explanation.meaning.isEmpty)
            XCTAssertFalse(explanation.checks.isEmpty)
            XCTAssertFalse(explanation.limits.isEmpty)
        }
    }

    func testMatchingDoesNotDiagnoseSimilarNegatedOrForeignMessages() {
        let messages = [
            "[ekf2] GPS emergency yaw reset: false",
            "Not [ekf2] GPS emergency yaw reset",
            "[other_module] GPS emergency yaw reset",
            "GPS emergency yaw reset",
            "[vehicle_imu] Gyro banana clipping, not safe to fly!",
            "[dance] Local speed violation: nan m/s",
            "[dance] Local speed violation: 3.5 km/h",
            "[dance] No GPS speed violation: 3.5 m/s",
            "[logger] [logger] write failed",
            "[logger] [logger] no log file created",
            "[logger] Opened full log file: false",
            "[mavlink] command number 246 is ok 10",
            "[uavcan:112:] Torqeedo: err:51"
        ]
        for text in messages {
            let explanation = AlertKnowledge.explanation(forText: text)
            XCTAssertEqual(explanation.id, "unknown", text)
            XCTAssertFalse(explanation.isDocumented, text)
        }
    }

    func testFallbackDistinguishesModuleContextFromARealDefinition() {
        let context = AlertKnowledge.explanation(forText: "[ekf2] Future estimator message")
        XCTAssertEqual(context.id, "unknown")
        XCTAssertEqual(context.confidence, .context)
        XCTAssertNil(context.referenceFirmware)
        XCTAssertFalse(context.isDocumented)
        let raw = AlertKnowledge.explanation(forText: "New unknown fault")
        XCTAssertEqual(raw.confidence, .raw)
        XCTAssertNil(raw.referenceFirmware)
        XCTAssertFalse(raw.meaning.isEmpty)
        XCTAssertFalse(raw.title.contains("non disponible"))
    }

    func testConfidenceAndFirmwareAreAssignedPerDefinition() {
        let upstream = AlertKnowledge.explanation(forText: "[ekf2] GPS emergency yaw reset")
        XCTAssertEqual(upstream.confidence, .documented)
        XCTAssertTrue(upstream.referenceFirmware?.contains("v1.14") == true)
        XCTAssertFalse(upstream.sources.isEmpty)
        let vendor = AlertKnowledge.explanation(forText: "[wifi_broadcom] Wifi link lost")
        XCTAssertEqual(vendor.confidence, .interpretation)
        XCTAssertFalse(vendor.referenceFirmware?.contains("PX4 v1.14.0") == true)
        let unresolved = AlertKnowledge.explanation(forText: "[uavcan:110:] Torqeedo: err:54")
        XCTAssertEqual(unresolved.confidence, .unresolved)
        XCTAssertEqual(unresolved.confidence.summaryLabel, "Sens exact inconnu")
        let driverCode = AlertKnowledge.explanation(forText: "[batt_smbus] SMBus read error: -2")
        XCTAssertEqual(driverCode.id, "battery-smbus-read")
        XCTAssertEqual(driverCode.confidence, .interpretation)
        XCTAssertNotNil(driverCode.referenceFirmware)
    }

    func testCatalogueContainsNoDuplicateIDsAndEveryDefinitionHasLimits() {
        let entries = AlertCatalogueData.entries
        XCTAssertGreaterThan(entries.count, 250)
        XCTAssertEqual(Set(entries.map { $0.explanation.id }).count, entries.count)
        for entry in entries {
            XCTAssertFalse(entry.patterns.isEmpty, entry.explanation.id)
            XCTAssertFalse(entry.explanation.provenance.isEmpty, entry.explanation.id)
            XCTAssertFalse(entry.explanation.limits.isEmpty, entry.explanation.id)
            XCTAssertFalse(entry.explanation.checks.isEmpty, entry.explanation.id)
            XCTAssertLessThanOrEqual(entry.explanation.meaning.count, 320, entry.explanation.id)
            for source in entry.explanation.sources {
                XCTAssertEqual(source.url.scheme, "https", entry.explanation.id)
            }
        }
    }

    private func syntheticFixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/fixtures/synthetic/alert-catalogue.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSyntheticExamplesMatchUsingTheRuntimeRegexEngine() throws {
        let fixture = try syntheticFixture()
        let examples = try XCTUnwrap(fixture["examples"] as? [[String: Any]])
        for example in examples {
            let text = try XCTUnwrap(example["text"] as? String)
            let id = try XCTUnwrap(example["id"] as? String)
            let confidence = try XCTUnwrap(example["confidence"] as? String)
            let explanation = AlertKnowledge.explanation(forText: text)
            XCTAssertEqual(explanation.id, id, text)
            XCTAssertEqual(explanation.confidence.rawValue, confidence, text)
        }
        XCTAssertGreaterThanOrEqual(examples.count, 388)
    }

    func testSyntheticFixtureCoversEveryPatternAndKeepsFallbackSeparate() throws {
        let fixture = try syntheticFixture()
        let examples = try XCTUnwrap(fixture["examples"] as? [[String: Any]])
        let fixturePatterns = try examples.map { example -> String in
            let id = try XCTUnwrap(example["id"] as? String)
            let index = try XCTUnwrap(example["patternIndex"] as? Int)
            return "\(id):\(index)"
        }
        let cataloguePatterns = AlertCatalogueData.entries.flatMap { entry in
            entry.patterns.indices.map { "\(entry.explanation.id):\($0)" }
        }
        XCTAssertEqual(Set(fixturePatterns), Set(cataloguePatterns))
        XCTAssertEqual(fixturePatterns.count, cataloguePatterns.count)
        let fallbacks = try XCTUnwrap(fixture["fallbacks"] as? [[String: Any]])
        XCTAssertEqual(fallbacks.count, 3)
        for fallback in fallbacks {
            let text = try XCTUnwrap(fallback["text"] as? String)
            let confidence = try XCTUnwrap(fallback["confidence"] as? String)
            let explanation = AlertKnowledge.explanation(forText: text)
            XCTAssertEqual(explanation.id, "unknown", text)
            XCTAssertEqual(explanation.confidence.rawValue, confidence, text)
        }
    }

    // This gate is compiled only for an explicit local private-corpus audit.
    // Public CI and source/package snapshots run the synthetic tests above.
    #if KATALOG_PRIVATE_ALERT_CORPUS
    func testRealCorpusCoverageUsesSwiftMatchingAndKeepsContextSeparate() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["KATALOG_PRIVATE_ALERT_CORPUS"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        var total = 0, recognized = 0, alerts = 0, recognizedAlerts = 0, unresolved = 0
        for message in messages {
            let text = try XCTUnwrap(message["text"] as? String)
            let count = try XCTUnwrap(message["occurrences"] as? Int)
            let isAlert = try XCTUnwrap(message["is_alert"] as? Bool)
            let explanation = AlertKnowledge.explanation(forText: text)
            total += count
            if isAlert { alerts += count }
            if explanation.id != "unknown" {
                // A recognized but unresolved code must not be promoted to a definition.
                XCTAssertTrue([.documented, .interpretation, .unresolved].contains(explanation.confidence))
                recognized += count
                if isAlert { recognizedAlerts += count }
                if explanation.confidence == .unresolved { unresolved += count }
            }
        }
        XCTAssertEqual(total, 12_906)
        XCTAssertEqual(alerts, 5_500)
        XCTAssertEqual(recognized, 12_904)
        XCTAssertEqual(recognizedAlerts, 5_500)
        XCTAssertGreaterThan(unresolved, 0)
    }
    #endif
}
