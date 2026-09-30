import XCTest
@testable import KataLogCore

final class LibraryUXTests: XCTestCase {
    private func log(_ id: String = "fixture") -> FlightLog {
        FlightLog(id: id, droneID: "controller-demo", droneName: "Drone demo", date: "2026-01-01",
            dateSource: "fixture", sourcePaths: [], fileName: id + ".ulg", sizeBytes: 1,
            durationSeconds: 120, flightSeconds: nil, status: "ok", issues: [],
            metadata: ["parserVersion": AnalysisService.parserVersion], topics: [], messages: [],
            metrics: [], coverage: [], failsafeObserved: false)
    }
    private func message(_ id: String, level: String, family: String = "Navigation") -> LogMessage {
        LogMessage(id: id, timestampSeconds: 1, level: level, text: "Observed " + id,
            family: family, groupKey: id, title: "Translated title " + id, alertFlag: nil)
    }
    private func snapshot(_ logs: [FlightLog]) -> FleetSnapshot {
        FleetSnapshot(schemaVersion: 1, generatedAt: "", sourceFolders: [], importStats: .empty, logs: logs)
    }

    func testFlightDurationDistinguishesUnknownGroundAndUnreadableLogs() {
        var flying = log("flight"); flying.flightSeconds = 30
        var ground = log("ground"); ground.flightSeconds = 0
        var unreadable = log("bad"); unreadable.status = "error"; unreadable.flightSeconds = 90
        var invalid = log("invalid"); invalid.flightSeconds = -.infinity
        var negative = log("negative"); negative.flightSeconds = -1
        let fleet = snapshot([log(), flying, ground, unreadable, invalid, negative])
        XCTAssertEqual(fleet.totalFlightSeconds, 30)
        XCTAssertEqual(fleet.flightLogCount, 2)
        XCTAssertEqual(fleet.totalDurationSeconds, 600, "Recorded time includes ground time.")
        XCTAssertNil(snapshot([log()]).totalFlightSeconds)
        XCTAssertEqual(snapshot([ground]).totalFlightSeconds, 0)
        XCTAssertEqual(LibraryHelp.flightCoverage(measured: 2, total: 6), "Calculé sur 2 / 6 logs")
    }

    func testProvisionalIdentitiesStaySeparateAfterAnonymization() {
        var known = log("known"); known.droneID = "controller-known"
        var duplicate = known; duplicate.id = "duplicate"
        var provisional = log("temporary"); provisional.droneID = "card:demo-card"
        var anonymous = provisional; anonymous.id = "anonymous"; anonymous.droneID = "drone-0001"; anonymous.identityProvisional = true
        XCTAssertEqual(snapshot([known, duplicate, provisional]).scannedDroneCount, 1)
        XCTAssertEqual(snapshot([known, duplicate, provisional]).provisionalDroneCount, 1)
        XCTAssertTrue(anonymous.isProvisionalIdentity)
        XCTAssertEqual(snapshot([anonymous]).scannedDroneCount, 0)
    }

    func testRawPX4SeverityIsPreservedWithoutTranslationAndIndependentOfQuality() {
        var recording = log(); recording.status = "partial"
        recording.events = [PX4Event(id: "event", eventID: .integer(42), timeSeconds: 1,
            level: "INFO", message: nil, argumentsHex: "", definitionSource: nil,
            internalLevelName: "ERROR", externalLevelName: "CRITICAL", translationStatus: "missing")]
        let signal = recording.assessment
        XCTAssertEqual(signal.state, "critical")
        XCTAssertEqual(signal.level, "CRITICAL")
        XCTAssertEqual(signal.primaryText, "Événement PX4 42")
        XCTAssertEqual(signal.untranslatedEventCount, 1)
        XCTAssertEqual(recording.analysisQualityLabel, "Lecture partielle")
    }

    func testFailsafeAloneDoesNotInventCriticalFirmwareLevel() {
        var recording = log(); recording.failsafeObserved = true
        XCTAssertEqual(recording.assessment.state, "warning")
        XCTAssertNil(recording.assessment.level)
        XCTAssertEqual(recording.assessment.occurrenceCount, 1)
        recording.messages = [LogMessage(id: "failsafe", timestampSeconds: 1, level: "ERROR",
            text: "Failsafe activated", family: "Safety", groupKey: "failsafe", title: "Failsafe", alertFlag: nil)]
        XCTAssertEqual(recording.assessment.state, "error")
        XCTAssertEqual(recording.assessment.occurrenceCount, 1)
        XCTAssertEqual(recording.assessment.primaryText, "Failsafe activated")
    }

    func testNoneRequiresSufficientSignalCoverage() {
        var recording = log()
        XCTAssertEqual(recording.assessment.state, "none")
        recording.metadata = [:]
        XCTAssertEqual(recording.assessment.state, "unknown")
        recording.events = []
        XCTAssertEqual(recording.assessment.state, "none")
        recording.status = "partial"
        XCTAssertEqual(recording.assessment.state, "unknown")
        recording.messages = [message("critical", level: "CRITICAL")]
        XCTAssertEqual(recording.assessment.state, "critical", "Partial reading cannot erase a confirmed signal.")
        recording.status = "ok"; recording.messages = []; recording.summaryMessageCount = 10
        XCTAssertEqual(recording.assessment.state, "unknown", "An unloaded message page cannot establish absence.")
    }

    func testFilteredAndMaskedSelectionsDoNotReuseUnrelatedBadges() throws {
        var recording = log()
        let warning = message("warning", level: "WARNING")
        let critical = message("critical", level: "CRITICAL", family: "Safety")
        recording.messages = [critical, warning]
        recording.signalAssessment = .init(state: "critical", level: "CRITICAL", primaryText: critical.text, occurrenceCount: 2)
        var scope = SelectionScope(); scope.families = ["Navigation"]
        let selected = try XCTUnwrap(scope.applying(to: snapshot([recording])).logs.first)
        XCTAssertEqual(selected.assessment.state, "warning")
        XCTAssertEqual(selected.assessment.primaryText, warning.text)
        let masked = try XCTUnwrap(SelectionScope().applying(to: snapshot([recording]), maskedMessageKeys: [critical.classificationKey]).logs.first)
        XCTAssertEqual(masked.assessment.state, "warning")
        XCTAssertEqual(SelectionScope().applying(to: snapshot([recording])).logs.first?.assessment.state, "critical")
    }

    func testLegacyModelsDecodeWithoutNewFields() throws {
        let value = log()
        let encoded = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(FlightLog.self, from: encoded)
        XCTAssertNil(restored.signalAssessment); XCTAssertNil(restored.identityProvisional)
        let data = Data(#"{"logs":1,"validLogs":1,"messages":0,"alertLogs":0,"failsafeLogs":0,"recordedSeconds":120,"droneCount":1,"familyLogCounts":{},"groupCount":0}"#.utf8)
        let totals = try JSONDecoder().decode(LibraryTotals.self, from: data)
        XCTAssertNil(totals.measuredFlightSeconds)
        XCTAssertEqual(totals.scannedDrones, 1)
    }

    func testSourceMutationsInheritOnlyTheirLibraryWriterLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try LibraryWriterLease(directory: root)
        defer { withExtendedLifetime(lease) {} }
        let database = root.appendingPathComponent("library.sqlite")
        for command in ["retire-source", "restore-source"] {
            let input = try XCTUnwrap(LibraryWriterLease.inheritedInput(for: [command, "--database", database.path]))
            try input.close()
            XCTAssertNil(try LibraryWriterLease.inheritedInput(for: [command, "--database", root.appendingPathComponent("other/library.sqlite").path]))
        }
    }
}
