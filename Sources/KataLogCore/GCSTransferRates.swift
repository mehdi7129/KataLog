import Foundation

/// Short rolling measurements per worker and transport. Cached bytes and phase
/// changes are baselines, never bytes counted as newly transferred.
public struct GCSTransferRates: Sendable {
    private struct Sample: Sendable { let time: TimeInterval; let bytes: Int64 }
    private struct Measurement: Sendable { let phase: String; var samples: [Sample] }
    private var measurements: [String: Measurement] = [:]
    public init() {}

    public mutating func remove(id: String) { measurements[id] = nil }

    public mutating func record(id: String, phase: String?, bytes: Int64, now: TimeInterval) {
        guard let phase, ["drone", "http"].contains(phase), bytes >= 0, now.isFinite else {
            measurements[id] = nil; return
        }
        let sample = Sample(time: now, bytes: bytes)
        guard var measurement = measurements[id], measurement.phase == phase,
              let last = measurement.samples.last, now > last.time, bytes >= last.bytes else {
            measurements[id] = Measurement(phase: phase, samples: [sample]); return
        }
        measurement.samples.append(sample)
        // Keep one point before the three-second window for a stable baseline.
        while measurement.samples.count > 2, measurement.samples[1].time < now - 3 {
            measurement.samples.removeFirst()
        }
        measurements[id] = measurement
    }

    public func bytesPerSecond(phase: String, now: TimeInterval) -> Double? {
        var total = 0.0, hasMeasurement = false
        for measurement in measurements.values where measurement.phase == phase {
            guard measurement.samples.count > 1,
                  let first = measurement.samples.first, let last = measurement.samples.last,
                  now >= last.time, now - last.time <= 5, now > first.time else { continue }
            total += Double(last.bytes - first.bytes) / (now - first.time)
            hasMeasurement = true
        }
        return hasMeasurement ? total : nil
    }
}
