import Foundation

public struct EventDictionaryImport: Codable, Sendable {
    public var dictionaryVersion: Int
    public var sha256: String
    public var definitionVersion: Int
    public var path: String
    public var sizeBytes: Int
    public var reused: Bool
    public var matchingCachedLogs: Int
}

public enum EventDictionaryService {
    public static func importFile(_ file: URL, database: URL, engine: URL) async throws -> EventDictionaryImport {
        let data = try await AnalysisService.run(["event-dictionary", "--database", database.path, "--file", file.path], engine: engine)
        let result = try JSONDecoder().decode(EventDictionaryImport.self, from: data)
        guard result.dictionaryVersion == 1, result.sha256.count == 64,
              result.sha256.allSatisfy({ "0123456789abcdef".contains($0) }), result.sizeBytes > 0,
              result.sizeBytes <= 4 * 1024 * 1024 else {
            throw AnalysisError.engine("Le dictionnaire retourné par le moteur est invalide.")
        }
        return result
    }
}
