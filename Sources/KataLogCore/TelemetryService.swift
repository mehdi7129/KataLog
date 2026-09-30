import Foundation

public struct TelemetryRequest: Codable, Equatable, Sendable {
    public var seriesVersion = 1
    public var recipe: String? = nil
    public var topic: String? = nil
    public var field: String? = nil
    public var instance = 0
    public var timeFrom: Double? = nil
    public var timeTo: Double? = nil
    public var budget = 2048
    public init(recipe: String = "battery", instance: Int = 0) {
        self.recipe = recipe; self.instance = instance
    }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "invalid"
    }
}

public struct TelemetryResponse: Codable, Sendable {
    public var seriesVersion: Int
    public var logID: String
    public var series: [TelemetrySeries]
    public var missingFields: [String]
    public var pointBudget: Int
    public var displayedPointCount: Int
}

public enum TelemetryService {
    public static func extract(logID: String, request: TelemetryRequest, database: URL, engine: URL) async throws -> TelemetryResponse {
        guard request.budget >= 2, request.budget <= 2048, (0...255).contains(request.instance),
              request.timeFrom?.isFinite ?? true, request.timeTo?.isFinite ?? true,
              request.timeFrom == nil || request.timeTo == nil || request.timeFrom! <= request.timeTo! else {
            throw AnalysisError.engine("Fenêtre ou budget de courbes invalide.")
        }
        let data = try await AnalysisService.run(["series", "--log-id", logID, "--database", database.path], engine: engine,
                                                  request: JSONEncoder().encode(request))
        let result = try JSONDecoder().decode(TelemetryResponse.self, from: data)
        guard result.seriesVersion == 1, result.logID == logID, result.series.count <= 4,
              result.displayedPointCount == result.series.reduce(0, { $0 + $1.points.count }),
              result.displayedPointCount >= 0, result.displayedPointCount <= request.budget,
              result.series.allSatisfy({ $0.points.allSatisfy { $0.timeSeconds.isFinite && $0.value.isFinite } }) else {
            throw AnalysisError.engine("Réponse de courbes incompatible ou hors budget.")
        }
        return result
    }
}
