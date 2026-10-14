import XCTest
@testable import KataLogCore

final class DroneAnnotationsTests: XCTestCase {
    func testNotesProjectByLogAndControllerIdentityWithoutChangingRecordedMetadata() throws {
        var first = try fixture(); first.id = "first"
        var second = first; second.id = "second"
        var other = first; other.id = "other"; other.droneID = "another-controller"
        let note = PersonalNote(text: "Conclusion personnelle", createdAt: "2026-10-14T10:00:00Z", updatedAt: "2026-10-14T10:01:00Z")
        var state = DroneAnnotationState()
        state.logNotes[first.id] = note; state.droneNotes[first.annotationKey] = note
        var snapshot = FleetSnapshot.empty; snapshot.logs = [first, second, other]
        let projected = state.applying(to: snapshot)
        XCTAssertEqual(projected.logs[0].personalNote, note)
        XCTAssertEqual(projected.logs[0].droneNote, note)
        XCTAssertNil(projected.logs[1].personalNote); XCTAssertEqual(projected.logs[1].droneNote, note)
        XCTAssertNil(projected.logs[2].personalNote); XCTAssertNil(projected.logs[2].droneNote)
        XCTAssertEqual(projected.logs[0].metadata, first.metadata)
        state.logNotes = [:]; state.droneNotes = [:]
        XCTAssertNil(state.applying(to: projected.logs[0]).personalNote)
        XCTAssertNil(state.applying(to: projected.logs[0]).droneNote)
    }

    func testNoteValidationPreservesMultilineAndRejectsControlCharactersOrExcessiveLength() throws {
        XCTAssertEqual(try DroneAnnotationValidation.note(" A\r\nB\tC "), "A\nB\tC")
        XCTAssertNil(try DroneAnnotationValidation.note(" \n "))
        XCTAssertThrowsError(try DroneAnnotationValidation.note("A\u{0000}B"))
        XCTAssertThrowsError(try DroneAnnotationValidation.note(String(repeating: "x", count: 4001)))
        XCTAssertNoThrow(try DroneAnnotationValidation.note(String(repeating: "é", count: 4000)))
    }

    func testPrivateExportsRetainDatedNotesAndEscapeHTML() throws {
        var log = try fixture()
        let note = PersonalNote(text: "Essai <script>alert('x')</script>\nOK", createdAt: "2026-10-14T10:00:00Z", updatedAt: "2026-10-14T10:01:00Z")
        log.personalNote = note; log.droneNote = note
        var snapshot = FleetSnapshot.empty; snapshot.logs = [log]
        let restored = try AnalysisService.decode(ReportRenderer.json(snapshot))
        XCTAssertEqual(restored.logs[0].personalNote, note); XCTAssertEqual(restored.logs[0].droneNote, note)
        let html = ReportRenderer.html(snapshot)
        XCTAssertTrue(html.contains("Note personnelle du log")); XCTAssertTrue(html.contains("Note personnelle du drone"))
        XCTAssertTrue(html.contains("2026-10-14T10:01:00Z"))
        XCTAssertTrue(html.contains("&lt;script&gt;")); XCTAssertFalse(html.contains("<script>alert('x')</script>"))
    }

    func testIdentityRequiresVerifiedGCSMetadataAndNeverGuessesUUIDEncoding() throws {
        var log = try fixture()
        XCTAssertEqual(log.annotationKey, "ulog:source-uuid")
        log.metadata["gcsUUID"] = "1234567890abcdef1234abcd"
        XCTAssertEqual(log.annotationKey, "gcs:1234567890ABCDEF1234ABCD")
        log.metadata["gcsUUID"] = "invalid"
        XCTAssertEqual(log.annotationKey, "ulog:source-uuid")
    }

    func testSameNumberNeverMergesControllerHistoriesAndPreservesRawNames() throws {
        var first = try fixture(); first.id = "a"
        var second = first; second.id = "b"; second.droneID = "other-controller"
        var state = DroneAnnotationState()
        state.stockNumbers = [first.annotationKey: "00042", second.annotationKey: "00042"]
        var snapshot = FleetSnapshot.empty; snapshot.logs = [first, second]
        let result = state.applying(to: snapshot)
        XCTAssertEqual(result.drones.count, 2)
        XCTAssertEqual(Set(result.logs.map(\.droneID)).count, 2)
        XCTAssertEqual(result.logs.first?.droneName, "Nom source")
        XCTAssertEqual(result.drones.map(\.name), ["Drone 00042", "Drone 00042"])
        XCTAssertEqual(result.alertGroups.first?.occurrences.first?.droneName, "Drone 00042")
    }

    func testClassificationSurvivesChangedAutomaticFamilyAndCanReset() throws {
        var log = try fixture()
        let original = log.messages[0]
        var state = DroneAnnotationState()
        state.familyOverrides[original.classificationKey] = "Contrôle avant vol"
        log.messages[0].family = "Nouvelle règle"
        log.messages[0].groupKey = "Nouvelle règle|ERROR|Unknown source"
        let result = state.applying(to: log)
        XCTAssertEqual(result.messages[0].family, "Contrôle avant vol")
        XCTAssertEqual(result.messages[0].sourceFamily, "Nouvelle règle")
        XCTAssertEqual(result.messages[0].text, original.text)
        XCTAssertEqual(result.messages[0].level, original.level)
        state.familyOverrides = [:]
        XCTAssertEqual(state.applying(to: result).messages[0].family, "Nouvelle règle")
        XCTAssertNil(state.applying(to: result).messages[0].sourceFamily)
    }

    func testLegacyGroupKeysRemainReadableAndWhitespaceIsOnlyNormalization() throws {
        let log = try fixture(); var other = log.messages[0]
        var state = DroneAnnotationState(); state.familyOverrides[other.groupKey] = "Ancienne annotation"
        XCTAssertEqual(state.applying(to: log).messages[0].family, "Ancienne annotation")
        other.text = "Unknown  \nsource"
        XCTAssertEqual(other.classificationKey, log.messages[0].classificationKey)
        other.text = "Unknown source 2"
        XCTAssertNotEqual(other.classificationKey, log.messages[0].classificationKey)
        other.text = log.messages[0].text; other.level = "WARNING"
        XCTAssertNotEqual(other.classificationKey, log.messages[0].classificationKey)
    }

    func testRetroactiveExportContainsAnnotationsAndOriginalProvenance() throws {
        let log = try fixture(); var snapshot = FleetSnapshot.empty; snapshot.logs = [log]
        var state = DroneAnnotationState()
        state.stockNumbers[log.annotationKey] = "42"
        state.familyOverrides[log.messages[0].classificationKey] = "Électronique"
        let exported = try ReportRenderer.json(state.applying(to: snapshot))
        let restored = try AnalysisService.decode(exported)
        XCTAssertEqual(restored.logs[0].stockNumber, "42")
        XCTAssertEqual(restored.logs[0].droneName, "Nom source")
        XCTAssertEqual(restored.logs[0].droneID, "source-uuid")
        XCTAssertEqual(restored.logs[0].messages[0].sourceFamily, "Inconnue")
        XCTAssertEqual(restored.logs[0].messages[0].family, "Électronique")
    }

    func testValidationPreservesLeadingZerosAndRejectsControlsOrOversize() throws {
        XCTAssertEqual(try DroneAnnotationValidation.stockNumber(" 00042 "), "00042")
        XCTAssertNil(try DroneAnnotationValidation.stockNumber("   "))
        XCTAssertThrowsError(try DroneAnnotationValidation.stockNumber("42\n"))
        XCTAssertThrowsError(try DroneAnnotationValidation.stockNumber(String(repeating: "x", count: 33)))
        XCTAssertThrowsError(try DroneAnnotationValidation.family(String(repeating: "é", count: 49)))
        XCTAssertEqual(try DroneAnnotationValidation.family("Toutes"), "Toutes", "A family must not collide with the UI's all-families selection.")
        XCTAssertThrowsError(try DroneAnnotationValidation.family("IMU\u{0000}"))
        XCTAssertFalse(DroneAnnotationValidation.isValidKey("gcs:ffffffffffffffffffffffff"))
    }

    func testUniqueObservedLinkAppliesToUnprovenLogButNeverToRejectedOrAmbiguousLog() throws {
        var proven = try fixture(); proven.id = "proven"
        proven.metadata = ["gcsUUID": "100000000000000000000001", "gcsIdentityStatus": "verified"]
        var missing = try fixture(); missing.id = "missing"; missing.metadata["gcsIdentityStatus"] = "unavailable"
        var rejected = missing; rejected.id = "rejected"; rejected.metadata["gcsIdentityStatus"] = "rejected"
        var state = DroneAnnotationState(); state.stockNumbers["gcs:100000000000000000000001"] = "42"
        var snapshot = FleetSnapshot.empty; snapshot.logs = [proven, missing, rejected]
        let result = state.applying(to: snapshot)
        XCTAssertEqual(result.logs[1].stockNumber, "42")
        XCTAssertEqual(result.logs[1].annotationKey, proven.annotationKey)
        XCTAssertNil(result.logs[1].metadata["gcsUUID"], "Derived linkage must not invent source metadata.")
        XCTAssertNil(result.logs[2].stockNumber)
        XCTAssertEqual(result.logs[2].annotationKey, "ulog:source-uuid")
        var second = proven; second.id = "other-proof"; second.metadata["gcsUUID"] = "100000000000000000000002"
        snapshot.logs = result.logs + [second]
        let ambiguous = state.applying(to: snapshot)
        XCTAssertNil(ambiguous.logs[1].stockNumber)
        XCTAssertNil(ambiguous.logs[1].annotationGCSUUID, "Previously derived evidence must be cleared before recalculation.")
        XCTAssertNotNil(ambiguous.logs[1].annotationWarning)
        XCTAssertEqual(ambiguous.logs[0].stockNumber, "42", "Direct verified metadata remains authoritative.")
    }

    func testConflictingLegacyNumberIsVisibleAndCanonicalWins() throws {
        var log = try fixture(); log.metadata["gcsUUID"] = "100000000000000000000001"
        var state = DroneAnnotationState()
        state.stockNumbers = ["ulog:source-uuid": "007", "gcs:100000000000000000000001": "009"]
        let result = state.applying(to: log)
        XCTAssertEqual(result.stockNumber, "009")
        XCTAssertNotNil(result.annotationWarning)
        XCTAssertEqual(state.stockNumbers["ulog:source-uuid"], "007")
    }

    private func fixture() throws -> FlightLog {
        try JSONDecoder().decode(FlightLog.self, from: Data(#"{"id":"log","droneID":"source-uuid","droneName":"Nom source","date":"2026-09-29","dateSource":"path","sourcePaths":[],"fileName":"flight.ulg","sizeBytes":16,"durationSeconds":10,"status":"ok","issues":[],"metadata":{},"topics":[],"messages":[{"id":"m","timestampSeconds":1,"level":"ERROR","text":"Unknown source","family":"Inconnue","groupKey":"Inconnue|ERROR|Unknown source","title":"Unknown source"}],"metrics":[],"coverage":[],"failsafeObserved":false}"#.utf8))
    }
}
