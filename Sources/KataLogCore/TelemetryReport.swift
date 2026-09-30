import Foundation

/// A study exports the displayed series and their provenance, never a replacement for the original ULog.
public enum TelemetryReport {
    public static func snapshot(log: FlightLog, response: TelemetryResponse, request: TelemetryRequest?) throws -> FleetSnapshot {
        guard response.seriesVersion == 1, response.logID == log.id, response.series.count <= 4,
              response.displayedPointCount == response.series.reduce(0, { $0 + $1.points.count }),
              (2...2048).contains(response.pointBudget), response.displayedPointCount <= response.pointBudget else {
            throw AnalysisError.engine("Le relevé ne correspond pas à ce log ou dépasse le budget de points.")
        }
        var result = FleetSnapshot.empty
        result.generatedAt = ISO8601DateFormatter().string(from: Date())
        result.sourceFolders = Array(Set(log.sourcePaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })).sorted()
        var detailed = log; detailed.telemetry = response.series
        detailed.metadata["telemetryPresentation"] = "Relevé des points affichés, potentiellement réduit ; les échantillons originaux restent dans le fichier ULog."
        detailed.metadata["telemetrySeriesVersion"] = String(response.seriesVersion)
        detailed.metadata["telemetryParserVersion"] = AnalysisService.parserVersion
        let requestValue = try request.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .null
        let provenance = JSONValue.object([
            "schemaVersion": 1, "parserVersion": .string(AnalysisService.parserVersion),
            "seriesVersion": .integer(Int64(response.seriesVersion)), "request": requestValue,
            "pointBudget": .integer(Int64(response.pointBudget)),
            "displayedPointCount": .integer(Int64(response.displayedPointCount)),
            "missingFields": .array(response.missingFields.map(JSONValue.string)),
            "originalULogIncluded": .bool(false), "presentation": .string("displayed-series"),
            "series": .array(response.series.map { curve in
                .object(["key": .string(curve.key), "source": .string(curve.source),
                         "instance": curve.instance.map { .integer(Int64($0)) } ?? .null,
                         "displayedPointCount": .integer(Int64(curve.points.count)),
                         "originalSampleCount": .integer(Int64(curve.originalSampleCount)),
                         "completeWindow": curve.completeWindow.map(JSONValue.bool) ?? .null])
            })
        ])
        if let value = detailed.metadataDetails, case .object(var details) = value {
            details["telemetryReport"] = provenance; detailed.metadataDetails = .object(details)
        } else if let previous = detailed.metadataDetails {
            detailed.metadataDetails = .object(["sourceMetadata": previous, "telemetryReport": provenance])
        } else { detailed.metadataDetails = .object(["telemetryReport": provenance]) }
        result.logs = [detailed]
        return result
    }

    /// Offline SVG: each recorded segment has its own path, and discrete values step at the sample time.
    static func svg(_ series: TelemetrySeries) -> String {
        let points = series.points.filter { $0.timeSeconds.isFinite && $0.value.isFinite }
        guard let t0 = points.map(\.timeSeconds).min(), let t1 = points.map(\.timeSeconds).max(),
              let v0 = points.map(\.value).min(), let v1 = points.map(\.value).max() else {
            return "<p class=\"muted\">Aucun point valide affichable dans ce relevé.</p>"
        }
        func h(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        func n(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let spanT = t1 - t0, spanV = v1 - v0
        guard spanT.isFinite, spanV.isFinite else { return "<p class=\"muted\">Amplitude hors plage du dessin ; les valeurs restent dans le tableau.</p>" }
        func x(_ value: Double) -> Double { spanT == 0 ? 360 : 60 + 610 * ((value - t0) / spanT) }
        func y(_ value: Double) -> Double { spanV == 0 ? 120 : 200 - 160 * ((value - v0) / spanV) }
        var body = "<svg viewBox=\"0 0 710 255\" role=\"img\" aria-label=\"\(h(series.label)) : points affichés, segments séparés\" style=\"width:100%;height:auto\"><title>\(h(series.label)) · \(h(series.unit))</title><path d=\"M60 35V200H680\" fill=\"none\" stroke=\"var(--line)\"/>"
        let segments = Dictionary(grouping: points, by: \.segment)
        for segment in segments.keys.sorted() {
            guard let samples = segments[segment], let first = samples.first else { continue }
            var path = "M\(n(x(first.timeSeconds))) \(n(y(first.value)))"
            for point in samples.dropFirst() {
                path += series.interpolation == "step" ? "H\(n(x(point.timeSeconds)))V\(n(y(point.value)))" : "L\(n(x(point.timeSeconds))) \(n(y(point.value)))"
            }
            if samples.count > 1 { body += "<path data-telemetry-segment=\"\(segment)\" d=\"\(path)\" fill=\"none\" stroke=\"var(--accent)\" stroke-width=\"1.7\"/>" }
            for point in samples {
                body += "<circle cx=\"\(n(x(point.timeSeconds)))\" cy=\"\(n(y(point.value)))\" r=\"2.2\" fill=\"var(--accent)\"><title>t = \(n(point.timeSeconds)) s · \(n(point.value)) \(h(series.unit)) · segment \(segment)</title></circle>"
            }
        }
        for (px, py, text, anchor) in [(60.0, 222.0, n(t0) + " s", "start"), (670.0, 222.0, n(t1) + " s", "end"), (52.0, 202.0, n(v0), "end"), (52.0, 42.0, n(v1), "end")] {
            body += "<text x=\"\(n(px))\" y=\"\(n(py))\" fill=\"var(--muted)\" font-size=\"10\" text-anchor=\"\(anchor)\">\(h(text))</text>"
        }
        return body + "</svg><p class=\"muted\">Échelle adaptée aux points affichés ; aucun seuil de panne. Survoler un point affiche sa valeur enregistrée. Le tableau ci-dessous contient les mêmes échantillons.</p>"
    }
}
