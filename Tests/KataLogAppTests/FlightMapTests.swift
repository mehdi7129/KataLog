import XCTest
import MapKit
@testable import KataLog
@testable import KataLogCore

final class FlightMapTests: XCTestCase {
    func testTracksKeepRecordingGapsAsSeparatePolylines() throws {
        let log = try fixture(id: "gap", points: [
            point(time: 2, segment: 0), point(time: 0, segment: 0),
            point(time: 22, segment: 1), point(time: 20, segment: 1)
        ])
        let segments = FlightMapGeometry.segments([log])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].points.map(\.timeSeconds), [0, 2])
        XCTAssertEqual(segments[1].points.map(\.timeSeconds), [20, 22])
        XCTAssertNil(FlightMapGeometry.point(at: 10, in: try XCTUnwrap(log.track).points), "A cursor in a recording gap must not invent a GPS position.")
    }

    func testCursorUsesAnExistingSampleAndNeverInterpolates() throws {
        let points = [point(time: 0, latitude: 45), point(time: 10, latitude: 46)]
        let early = try XCTUnwrap(FlightMapGeometry.point(at: 3, in: points))
        let late = try XCTUnwrap(FlightMapGeometry.point(at: 8, in: points))
        XCTAssertEqual(early.timeSeconds, 0)
        XCTAssertEqual(early.latitude, 45)
        XCTAssertEqual(late.timeSeconds, 10)
        XCTAssertEqual(late.latitude, 46)
        XCTAssertNil(FlightMapGeometry.point(at: -1, in: points))
        XCTAssertNil(FlightMapGeometry.point(at: 11, in: points))
    }

    func testIsolatedPositionsRemainVisibleWithoutCreatingATrajectory() throws {
        let points = [point(time: 1, segment: 0), point(time: 40, segment: 1)]
        let log = try fixture(id: "isolated", points: points)
        let segments = FlightMapGeometry.segments([log])
        XCTAssertTrue(FlightMapGeometry.hasTrack(log))
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { $0.points.count == 1 }, "Single-point segments are displayed as points, not joined by a polyline.")
        XCTAssertNotNil(FlightMapGeometry.point(at: 1, in: points))
        XCTAssertNotNil(FlightMapGeometry.point(at: 40, in: points))
        XCTAssertNil(FlightMapGeometry.point(at: 20, in: points))
        let bounds = try XCTUnwrap(FlightMapGeometry.bounds([points[0]]))
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testInvalidCoordinatesCannotCreateMapContentOrBounds() throws {
        var invalidLongitude = point(time: 1)
        invalidLongitude.longitude = 181
        let invalid = [point(time: 0, latitude: .nan), point(time: .infinity), point(time: 2, latitude: 91), invalidLongitude]
        let log = try fixture(id: "invalid", points: invalid)
        XCTAssertFalse(FlightMapGeometry.hasTrack(log))
        XCTAssertTrue(FlightMapGeometry.segments([log]).isEmpty)
        XCTAssertNil(FlightMapGeometry.bounds(invalid))
        XCTAssertNil(FlightMapGeometry.point(at: 1, in: invalid))
    }

    func testFleetMapBoundsItsWorkToEightyRecentGeolocatedLogs() throws {
        var logs = try (0..<84).map { index in
            try fixture(id: String(format: "%03d", index), date: String(format: "2026-09-29T%02d:%02d:00Z", index / 60, index % 60), points: [point(time: 0)])
        }
        let unlocated = try fixture(id: "unlocated", date: "2026-09-30T00:00:00Z", points: [])
        logs.insert(unlocated, at: 0)
        let displayed = FlightMapGeometry.displayedLogs(logs)
        XCTAssertEqual(displayed.count, 80)
        XCTAssertEqual(displayed.first?.id, "083")
        XCTAssertEqual(displayed.last?.id, "004")
        XCTAssertFalse(displayed.contains { $0.id == "unlocated" })
        XCTAssertEqual(FlightMapGeometry.displayedLogs(logs, limit: 1).map(\.id), ["083"])
        XCTAssertTrue(FlightMapGeometry.displayedLogs(logs, limit: 0).isEmpty)
    }

    private func point(time: Double, latitude: Double = 45, segment: Int = 0) -> TrackPoint {
        TrackPoint(timeSeconds: time, latitude: latitude, longitude: 4, altitudeMeters: 10, segment: segment)
    }

    private func fixture(id: String, date: String = "2026-09-29T00:00:00Z", points: [TrackPoint]) throws -> FlightLog {
        let fields: [String: Any] = [
            "id": id, "droneID": "synthetic-controller", "droneName": "Fixture", "date": date, "dateSource": "gps",
            "sourcePaths": [], "fileName": "\(id).ulg", "sizeBytes": 1, "durationSeconds": 60,
            "status": "ok", "issues": [], "metadata": ["parserVersion": "1.1.0"], "topics": [],
            "messages": [], "metrics": [], "coverage": [], "failsafeObserved": false
        ]
        var log = try JSONDecoder().decode(FlightLog.self, from: JSONSerialization.data(withJSONObject: fields))
        log.track = FlightTrack(source: "synthetic", originalPointCount: points.count, rejectedPointCount: 0, points: points)
        return log
    }
}
