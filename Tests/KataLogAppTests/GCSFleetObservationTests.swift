import Foundation
import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class GCSFleetObservationTests: XCTestCase {
    private let uuid = "1112131415161718191A1B1C"
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-observation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("fleet.json")
    }
    private func drone() throws -> GCSDrone {
        var drone = try JSONDecoder().decode(GCSDrone.self, from: Data("{\"uuid\":\"\(uuid)\",\"time_usec\":123}".utf8))
        drone.lastSeen = Date(timeIntervalSince1970: 1_893_456_000)
        return drone
    }
    func testAuthorizationHasNoInventedDateAndReloadDoesNotRefreshReceiptTime() throws {
        let file = try file(), store = GCSFleetObservationStore(file: file, canMutate: { true })
        store.record([], authorized: [uuid])
        XCTAssertNil(store.state.drones.first?.lastSeenAtUTC)
        store.record([try drone()], authorized: [uuid])
        let captured = try Data(contentsOf: file)
        let revision = store.state.revision
        let reloaded = GCSFleetObservationStore(file: file, canMutate: { true })
        XCTAssertEqual(reloaded.state.drones.first?.lastSeenAtUTC, "2030-01-01T00:00:00.000Z")
        reloaded.record([try drone()], authorized: [uuid])
        XCTAssertEqual(reloaded.state.revision, revision)
        XCTAssertEqual(try Data(contentsOf: file), captured)
    }
    func testUnauthorizedTelemetryIsNotRegisteredAndWithdrawalKeepsHistory() throws {
        let file = try file(), store = GCSFleetObservationStore(file: file, canMutate: { true })
        store.record([try drone()], authorized: [])
        XCTAssertTrue(store.state.drones.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        store.record([try drone()], authorized: [uuid])
        let date = store.state.drones.first?.lastSeenAtUTC
        store.record([], authorized: [])
        XCTAssertEqual(store.state.drones.first?.authorized, false)
        XCTAssertEqual(store.state.drones.first?.lastSeenAtUTC, date)
    }
    func testMaintenanceDefersWritesAndFutureRegistryIsPreserved() throws {
        let file = try file()
        var allowed = false
        let store = GCSFleetObservationStore(file: file, canMutate: { allowed })
        store.record([try drone()], authorized: [uuid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        allowed = true; store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let future = Data(#"{"schemaVersion":2,"revision":0,"drones":[]}"#.utf8)
        try future.write(to: file)
        let incompatible = GCSFleetObservationStore(file: file, canMutate: { true })
        XCTAssertNotNil(incompatible.errorMessage)
        incompatible.record([try drone()], authorized: [uuid])
        XCTAssertEqual(try Data(contentsOf: file), future)
    }
    func testInvalidObservationDateIsPreservedWithoutBeingRewritten() throws {
        let file = try file()
        let invalid = GCSFleetObservationState(schemaVersion: 1, revision: 4,
            drones: [.init(uuid: uuid, authorized: true, lastSeenAtUTC: "invalid-date", lastSeenSource: "gcs-telemetry")])
        let original = try JSONEncoder().encode(invalid)
        try original.write(to: file)
        let store = GCSFleetObservationStore(file: file, canMutate: { true })
        XCTAssertNotNil(store.errorMessage)
        store.record([try drone()], authorized: [uuid])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testRegistryLabelsMatchBackendSourceStatesAndFractionalDates() throws {
        XCTAssertEqual(RegistryObservationFormat.sourceDescription("present-at-check"), "accessibles")
        XCTAssertEqual(RegistryObservationFormat.sourceDescription("modified-at-check"), "contenu modifié")
        XCTAssertEqual(RegistryObservationFormat.sourceDescription("inaccessible-at-check"), "illisibles")
        XCTAssertEqual(RegistryObservationFormat.sourceDescription("unknown"), "état indéterminé")
        XCTAssertEqual(try XCTUnwrap(RegistryObservationFormat.date("2030-01-01T00:00:00.000Z")),
                       try XCTUnwrap(RegistryObservationFormat.date("2030-01-01T00:00:00Z")))
    }

    func testFailedRegistrationRestoresExistingRegistryBytesAndRevision() throws {
        let file = try file(), store = GCSFleetObservationStore(file: file, canMutate: { true })
        store.record([try drone()], authorized: [uuid])
        let original = try Data(contentsOf: file), revision = store.state.revision
        let another = "0102030405060708090A0B0C"
        XCTAssertThrowsError(try store.register([], authorized: [uuid, another]) {
            throw AnalysisError.unavailable("Settings write refused for this test")
        })
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(store.state.revision, revision)
        XCTAssertEqual(store.state.drones.map(\.uuid), [uuid])
        try store.register([], authorized: [uuid, another]) {}
        XCTAssertEqual(Set(store.state.drones.map(\.uuid)), [uuid, another])
        XCTAssertNil(store.errorMessage)
    }
}
