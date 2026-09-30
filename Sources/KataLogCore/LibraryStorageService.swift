import Foundation

public struct LibraryBackupResult: Codable, Sendable {
    public var backupVersion: Int
    public var path: String
    public var sha256: String
    public var sizeBytes: Int64
    public var logCount: Int
    public var archivedLogCount: Int
    public var missingSourceCount: Int
    public var inspection: JSONValue
}

public enum LibraryStorageService {
    public static func backup(library: URL, destination: URL, includeULog: Bool, engine: URL) async throws -> LibraryBackupResult {
        var command = ["backup", "--library", library.path, "--destination", destination.path]
        if includeULog { command.append("--include-ulog") }
        let data = try await AnalysisService.run(command, engine: engine)
        return try JSONDecoder().decode(LibraryBackupResult.self, from: data)
    }
    public static func inspect(archive: URL, engine: URL) async throws -> JSONValue {
        let data = try await AnalysisService.run(["inspect-backup", "--archive", archive.path], engine: engine)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public static func restore(archive: URL, library: URL, engine: URL) async throws -> JSONValue {
        let data = try await AnalysisService.run(["restore", "--archive", archive.path, "--library", library.path], engine: engine)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
