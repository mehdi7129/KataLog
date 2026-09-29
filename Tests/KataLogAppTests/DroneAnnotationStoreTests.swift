import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class DroneAnnotationStoreTests: XCTestCase {
    func testNumbersAndFamiliesPersistAndCanBeReset() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.json")
        let first = DroneAnnotationStore(url: url)
        let key = "gcs:100000000000000000000001"
        let message = try fixture().logs[0].messages[0]
        try first.setStockNumber("00042", forKey: key)
        try first.setFamily("Batterie", for: message)
        let restored = DroneAnnotationStore(url: url)
        XCTAssertEqual(restored.state.stockNumbers[key], "00042")
        XCTAssertEqual(restored.state.familyOverride(for: message), "Batterie")
        try restored.setStockNumber(nil, forKey: key)
        try restored.setFamily(nil, for: message)
        let reset = DroneAnnotationStore(url: url)
        XCTAssertTrue(reset.state.stockNumbers.isEmpty)
        XCTAssertTrue(reset.state.familyOverrides.isEmpty)
    }

    func testFailedSaveKeepsPreviousStateAndReportsError() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.json")
        let store = DroneAnnotationStore(url: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.setStockNumber("42", forKey: "ulog:controller"))
        XCTAssertTrue(store.state.stockNumbers.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testUnreadableFileIsPreservedAndNeverSilentlyOverwritten() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.json")
        let invalid = Data("broken".utf8); try invalid.write(to: url)
        let store = DroneAnnotationStore(url: url)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.setStockNumber("42", forKey: "ulog:controller"))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testLibraryReprojectsExistingLogsAndExportsAfterEditAndReload() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try fixture()
        try ReportRenderer.json(raw).write(to: root.appendingPathComponent("library.json"))
        let library = LibraryStore(storageDirectory: root)
        try await awaitLoad(library)
        let message = raw.logs[0].messages[0]
        try library.annotations.setStockNumber("42", forKey: "ulog:controller")
        try library.annotations.setFamily("Nouvelle famille", for: message)
        XCTAssertEqual(library.snapshot.logs[0].displayName, "Drone 42")
        XCTAssertEqual(library.snapshot.logs[0].messages[0].family, "Nouvelle famille")
        let decoded = try AnalysisService.decode(ReportRenderer.json(library.snapshot))
        XCTAssertEqual(decoded.logs[0].stockNumber, "42")
        let reopened = LibraryStore(storageDirectory: root)
        try await awaitLoad(reopened)
        XCTAssertEqual(reopened.snapshot.logs[0].displayName, "Drone 42")
        XCTAssertEqual(reopened.snapshot.logs[0].messages[0].family, "Nouvelle famille")
        XCTAssertEqual(try AnalysisService.decode(Data(contentsOf: root.appendingPathComponent("library.json"))).logs[0].droneName, "Source")
    }

    func testNonconflictingLegacyNumberMigratesAtomicallyAndResetDoesNotResurrectIt() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.json")
        let store = DroneAnnotationStore(url: url)
        var log = try fixture().logs[0]; log.metadata["gcsUUID"] = "100000000000000000000001"
        try store.setStockNumber("007", forKey: "ulog:controller")
        store.reconcileIdentities(in: [log])
        XCTAssertNil(store.state.stockNumbers["ulog:controller"])
        XCTAssertEqual(store.state.stockNumbers[log.annotationKey], "007")
        let target = DroneIdentityTarget(log: store.state.applying(to: log))
        XCTAssertEqual(target.stockNumber, "007")
        try store.setStockNumber(nil, forKey: target.key, replacingLegacyKey: target.legacyKey)
        XCTAssertNil(DroneAnnotationStore(url: url).state.applying(to: log).stockNumber)
    }

    func testConflictingOrAmbiguousIdentitiesAreNotMigratedWithoutExplicitEdit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DroneAnnotationStore(url: root.appendingPathComponent("annotations.json"))
        var log = try fixture().logs[0]; log.metadata["gcsUUID"] = "100000000000000000000001"
        try store.setStockNumber("007", forKey: "ulog:controller")
        try store.setStockNumber("009", forKey: log.annotationKey)
        store.reconcileIdentities(in: [log])
        XCTAssertEqual(store.state.stockNumbers["ulog:controller"], "007")
        XCTAssertEqual(store.state.stockNumbers[log.annotationKey], "009")
        let target = DroneIdentityTarget(log: store.state.applying(to: log))
        XCTAssertNotNil(target.warning)
        try store.setStockNumber("010", forKey: target.key, replacingLegacyKey: target.legacyKey)
        XCTAssertNil(store.state.stockNumbers["ulog:controller"])
        XCTAssertEqual(store.state.stockNumbers[log.annotationKey], "010")
        try store.setStockNumber("007", forKey: "ulog:controller")
        var second = log; second.metadata["gcsUUID"] = "100000000000000000000002"
        store.reconcileIdentities(in: [log, second])
        XCTAssertEqual(store.state.stockNumbers["ulog:controller"], "007")
    }

    func testGCSEditorFactoryPreservesConflictAndResetCannotResurrectLegacyNumber() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DroneAnnotationStore(url: root.appendingPathComponent("annotations.json"))
        var snapshot = try fixture()
        let uuid = "100000000000000000000001"
        snapshot.logs[0].metadata["gcsUUID"] = uuid
        try store.setStockNumber("007", forKey: "ulog:controller")
        try store.setStockNumber("009", forKey: "gcs:" + uuid)
        let target = DroneIdentityTarget(gcsUUID: uuid, snapshot: snapshot, annotations: store.state)
        XCTAssertEqual(target.stockNumber, "009")
        XCTAssertEqual(target.legacyKey, "ulog:controller")
        XCTAssertNotNil(target.warning)
        try store.setStockNumber(nil, forKey: target.key, replacingLegacyKey: target.legacyKey)
        store.reconcileIdentities(in: snapshot.logs)
        XCTAssertTrue(store.state.stockNumbers.isEmpty)
        XCTAssertNil(DroneIdentityTarget(gcsUUID: uuid, snapshot: snapshot, annotations: store.state).stockNumber)
    }

    func testGCSEditorFactoryWorksWithoutAnyLog() throws {
        var state = DroneAnnotationState()
        let uuid = "100000000000000000000001"
        state.stockNumbers["gcs:" + uuid] = "00042"
        let target = DroneIdentityTarget(gcsUUID: uuid, snapshot: .empty, annotations: state)
        XCTAssertEqual(target.key, "gcs:" + uuid)
        XCTAssertEqual(target.stockNumber, "00042")
        XCTAssertNil(target.legacyKey)
        XCTAssertNil(target.warning)
    }

    private func awaitLoad(_ store: LibraryStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(store.errorMessage); XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.snapshot.logs.count, 1)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-annotations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func fixture() throws -> FleetSnapshot {
        try AnalysisService.decode(Data(#"{"schemaVersion":1,"generatedAt":"now","sourceFolders":[],"importStats":{"discovered":1,"imported":1,"unchanged":0,"duplicates":0,"failed":0},"logs":[{"id":"log","droneID":"controller","droneName":"Source","date":"2026-09-29","dateSource":"path","sourcePaths":[],"fileName":"flight.ulg","sizeBytes":16,"durationSeconds":10,"status":"ok","issues":[],"metadata":{},"topics":[],"messages":[{"id":"m","timestampSeconds":1,"level":"ERROR","text":"Unknown source","family":"Inconnue","groupKey":"Inconnue|ERROR|Unknown source","title":"Unknown source"}],"metrics":[],"coverage":[],"failsafeObserved":false}]}"#.utf8))
    }
}
