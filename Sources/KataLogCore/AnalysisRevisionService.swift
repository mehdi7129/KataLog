import Foundation

public struct AnalysisRevision: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var parserVersion: String
    public var analysisSHA256: String
    public var createdAt: String
    public var sizeBytes: Int64
    public var current: Bool
}

public struct AnalysisRevisionPage: Codable, Sendable {
    public var revisionVersion: Int
    public var logID: String
    public var total: Int
    public var revisions: [AnalysisRevision]
    public var nextOffset: Int?
}

public enum AnalysisRevisionService {
    public static func page(logID: String, offset: Int = 0, database: URL, engine: URL) async throws -> AnalysisRevisionPage {
        guard offset >= 0 else { throw AnalysisError.engine("Page de révisions invalide.") }
        let data = try await AnalysisService.run(["analysis-revisions", "--log-id", logID, "--offset", String(offset), "--limit", "32", "--database", database.path, "--read-only"], engine: engine, outputLimit: 4 * 1024 * 1024)
        let page = try JSONDecoder().decode(AnalysisRevisionPage.self, from: data)
        guard page.revisionVersion == 1, page.logID == logID, page.total >= page.revisions.count,
              page.revisions.count <= 32, page.nextOffset.map({ $0 > offset }) ?? true,
              page.revisions.allSatisfy({ isSHA($0.id) && isSHA($0.analysisSHA256) && $0.sizeBytes >= 0 && ["summary", "detail"].contains($0.kind) }) else {
            throw AnalysisError.engine("Réponse de révisions incompatible ou invalide.")
        }
        return page
    }
    public static func detail(logID: String, revisionID: String, database: URL, engine: URL) async throws -> FlightLog {
        guard isSHA(revisionID) else { throw AnalysisError.engine("Identifiant de révision invalide.") }
        let data = try await AnalysisService.run(["detail", "--log-id", logID, "--revision", revisionID, "--database", database.path, "--read-only"], engine: engine, outputLimit: 64 * 1024 * 1024)
        let log = try JSONDecoder().decode(FlightLog.self, from: data)
        guard log.id == logID, log.analysisRevision?["id"]?.stringValue == revisionID else {
            throw AnalysisError.engine("L’analyse historique reçue ne correspond pas à la révision demandée.")
        }
        return log
    }
    private static func isSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
