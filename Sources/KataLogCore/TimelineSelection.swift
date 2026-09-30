import Foundation

public struct ObservedPosition: Sendable {
    public let point: TrackPoint
    public let timeDifference: Double
    public let source: String
}

public enum TimelineSelection {
    /// Match an actual sample within one continuous segment. No interpolation,
    /// extrapolation, or line across a missing GPS interval is introduced.
    public static func position(at time: Double, track: FlightTrack?, tolerance: Double = 2) -> ObservedPosition? {
        guard time.isFinite, tolerance.isFinite, tolerance >= 0, let track else { return nil }
        let segments = Dictionary(grouping: track.points.filter { $0.hasValidCoordinate && $0.timeSeconds.isFinite }, by: \.segment)
        let matches = segments.values.compactMap { points -> TrackPoint? in
            guard let first = points.min(by: { $0.timeSeconds < $1.timeSeconds }),
                  let last = points.max(by: { $0.timeSeconds < $1.timeSeconds }),
                  time >= first.timeSeconds, time <= last.timeSeconds else { return nil }
            return points.min { abs($0.timeSeconds - time) < abs($1.timeSeconds - time) }
        }
        guard let nearest = matches.min(by: { abs($0.timeSeconds - time) < abs($1.timeSeconds - time) }),
              abs(nearest.timeSeconds - time) <= tolerance else { return nil }
        return ObservedPosition(point: nearest, timeDifference: abs(nearest.timeSeconds - time), source: track.source)
    }
}
