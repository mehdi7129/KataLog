import Foundation

/// The default diagnostic deliberately contains no free-text errors, paths,
/// logs, positions, controller identity, GCS endpoint or machine username.
public struct DiagnosticReport: Codable, Sendable {
    public enum CountScope: String, Codable, Sendable { case activeSelection, library, application, unavailable }
    public var diagnosticVersion = 1
    public var appVersion: String
    public var appBuild: String
    public var parserVersion: String
    public var osVersion: String
    public var architecture: String
    public var generatedAt: String
    public var operations: [String: Bool]
    public var counts: [String: Int]
    /// Per-count qualification prevents a scoped count being reported as a
    /// global library total. Values and keys are structured and allowlisted.
    public var countScope: [String: CountScope]
    public var runtimeBundled: Bool
    public var privateDataIncluded = false
    public init(appVersion: String, appBuild: String, operations: [String: Bool], counts: [String: Int],
                countScope: [String: CountScope] = [:], runtimeBundled: Bool) {
        self.appVersion = appVersion; self.appBuild = appBuild
        parserVersion = AnalysisService.parserVersion
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #else
        architecture = "other"
        #endif
        generatedAt = ISO8601DateFormatter().string(from: Date())
        let allowedOperations: Set<String> = ["import", "collection", "export", "maintenance", "readOnly", "gcsConnected", "loading"]
        let allowedCounts: Set<String> = ["logs", "messages", "identities", "jobs", "pendingJobs", "failedJobs", "masks", "savedViews"]
        self.operations = operations.filter { allowedOperations.contains($0.key) }
        self.counts = counts.filter { allowedCounts.contains($0.key) }
        self.countScope = Dictionary(uniqueKeysWithValues: self.counts.keys.map { ($0, countScope[$0] ?? .unavailable) })
        self.runtimeBundled = runtimeBundled
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 64 * 1024 else { throw AnalysisError.engine("Diagnostic trop volumineux.") }
        return data
    }
}
