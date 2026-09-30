import XCTest
@testable import KataLogCore

final class TimelineSelectionTests: XCTestCase {
    func testGapsAndOutsideRangeHaveNoInventedPosition() {
        let track = FlightTrack(source: "GNSS0", originalPointCount: 4, rejectedPointCount: 0,
                                points: [point(0, 0), point(1, 0), point(20, 1), point(21, 1)])
        XCTAssertEqual(TimelineSelection.position(at: 0.6, track: track)?.point.timeSeconds, 1)
        XCTAssertEqual(TimelineSelection.position(at: 0.6, track: track)?.timeDifference ?? -1, 0.4, accuracy: 0.001)
        XCTAssertNil(TimelineSelection.position(at: 10, track: track))
        XCTAssertNil(TimelineSelection.position(at: -0.1, track: track))
        XCTAssertNil(TimelineSelection.position(at: 21.1, track: track))
    }
    func testInvalidCoordinateAndSparseSeriesStayUnknown() {
        var invalid = point(1, 0); invalid.latitude = 999
        let track = FlightTrack(source: "gps", originalPointCount: 3, rejectedPointCount: 1,
                                points: [point(0, 0), invalid, point(8, 0)])
        XCTAssertNil(TimelineSelection.position(at: 4, track: track))
        XCTAssertNil(TimelineSelection.position(at: .nan, track: track))
    }
    private func point(_ time: Double, _ segment: Int) -> TrackPoint {
        TrackPoint(timeSeconds: time, latitude: 48, longitude: 2, altitudeMeters: nil, segment: segment)
    }
}
