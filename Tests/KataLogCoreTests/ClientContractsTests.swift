import XCTest
@testable import KataLogCore

final class ClientContractsTests: XCTestCase {
    func testLegacyScopeRemainsGlobalAndClientChangesFingerprint() throws {
        let legacy = try JSONDecoder().decode(SelectionScope.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.clientID)
        XCTAssertTrue(legacy.isUnfiltered)
        var unassigned = legacy; unassigned.clientID = ""
        XCTAssertFalse(unassigned.isUnfiltered)
        XCTAssertNotEqual(legacy.fingerprint, unassigned.fingerprint)
        var client = legacy; client.clientID = "00000000-0000-0000-0000-000000000001"
        XCTAssertNotEqual(client.fingerprint, unassigned.fingerprint)
        XCTAssertEqual(try JSONDecoder().decode(SelectionScope.self, from: JSONEncoder().encode(client)), client)
    }

    func testClientScopeDoesNotChangeDroneIdentityOrIncludeOtherClients() {
        var a = log("a"); a.clientID = "alpha"; a.clientName = "Alpha"
        var b = log("b"); b.clientID = "beta"
        let unassigned = log("c")
        let snapshot = FleetSnapshot(schemaVersion: 1, generatedAt: "", sourceFolders: [], importStats: .empty, logs: [a, b, unassigned])
        var scope = SelectionScope(); scope.clientID = "alpha"
        XCTAssertEqual(scope.applying(to: snapshot).logs.map(\.id), ["a"])
        XCTAssertEqual(scope.applying(to: snapshot).logs[0].annotationKey, b.annotationKey)
        scope.clientID = ""
        XCTAssertEqual(scope.applying(to: snapshot).logs.map(\.id), ["c"])
        scope.clientID = nil
        XCTAssertEqual(scope.applying(to: snapshot).logs.count, 3)
    }

    func testGeographicRequestAndLegacyViewDecode() throws {
        var query = LibraryQueryRequest(kind: "map")
        query.proximity = GeographicProximity(latitude: 1, longitude: 2, radiusMeters: 5000)
        let decoded = try JSONDecoder().decode(LibraryQueryRequest.self, from: JSONEncoder().encode(query))
        XCTAssertEqual(decoded.proximity, query.proximity)
        var state = LibraryViewState()
        XCTAssertNil(state.advancedMode)
        state.advancedMode = true
        XCTAssertEqual(try JSONDecoder().decode(LibraryViewState.self, from: JSONEncoder().encode(state)).advancedMode, true)
        let old = Data(#"{"schemaVersion":1,"revision":0,"activeScope":{},"views":[],"maskedMessageKeys":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LibraryViewState.self, from: old).advancedMode)
    }

    private func log(_ id: String) -> FlightLog {
        FlightLog(id: id, droneID: "controller", droneName: "Synthetic", date: "", dateSource: "unknown", sourcePaths: [],
                  fileName: id + ".ulg", sizeBytes: 0, durationSeconds: 0, flightSeconds: nil, status: "ok", issues: [],
                  metadata: [:], topics: [], messages: [], metrics: [], coverage: [], failsafeObserved: false)
    }
}
