import Foundation

public struct GNSSCoverage: Sendable {
    public let instance: Int
    public let fixedPercent: Double
    public let observedSeconds: Double?
    public let provenance: String
}

extension FlightLog {
    /// Choose one explicitly labelled receiver. Never combine independent fixes.
    public var primaryGNSSCoverage: GNSSCoverage? {
        metrics.compactMap { metric -> GNSSCoverage? in
            guard metric.key == "gps.rtk_fixed" || metric.key.hasPrefix("gps.rtk_fixed."),
                  metric.value.isFinite, (0...100).contains(metric.value) else { return nil }
            let suffix = String(metric.key.dropFirst("gps.rtk_fixed".count))
            guard let instance = suffix.isEmpty ? 0 : Int(suffix.dropFirst()) else { return nil }
            let observed = metrics.first { $0.key == "gps.observed_seconds" + suffix }?.value
            return GNSSCoverage(instance: instance, fixedPercent: metric.value,
                                observedSeconds: observed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                                provenance: metric.detail)
        }.sorted {
            if $0.observedSeconds != $1.observedSeconds { return ($0.observedSeconds ?? -1) > ($1.observedSeconds ?? -1) }
            return $0.instance < $1.instance
        }.first
    }
}
