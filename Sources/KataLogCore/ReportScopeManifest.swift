import Foundation

/// Describes what was selected and included in an export. It is separate from
/// FleetSnapshot's schema: an export is never presented as a complete ULog copy.
public struct ReportScopeManifest: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case full, selection, flight }
    public enum Completeness: String, Codable, Sendable { case summary, detailed, partial }

    public var schemaVersion: Int = 1
    public var mode: Mode
    public var scopeDescription: String
    public var revision: String?
    public var generatedAt: String
    public var includesMaskedMessages: Bool
    public var completeness: Completeness
    public var availableSections: [String]
    public var unavailableSections: [String]

    public init(mode: Mode = .full, scopeDescription: String = "Toute la bibliothèque",
                revision: String? = nil, generatedAt: String = "", includesMaskedMessages: Bool = true,
                completeness: Completeness = .summary,
                availableSections: [String] = ["messages", "metrics", "metadata", "topics", "sources"],
                unavailableSections: [String] = []) {
        self.mode = mode; self.scopeDescription = scopeDescription; self.revision = revision
        self.generatedAt = generatedAt; self.includesMaskedMessages = includesMaskedMessages
        self.completeness = completeness; self.availableSections = availableSections
        self.unavailableSections = unavailableSections
    }

    public static func describing(_ snapshot: FleetSnapshot, mode: Mode = .full,
                                 scopeDescription: String? = nil, revision: String? = nil,
                                 includesMaskedMessages: Bool = true) -> Self {
        let optional: [(String, (FlightLog) -> Bool)] = [
            ("parameters", { $0.parameters != nil }), ("parameterChanges", { $0.parameterChanges != nil }),
            ("topicDetails", { $0.topicDetails != nil }), ("events", { $0.events != nil }),
            ("telemetry", { $0.telemetry != nil }),
            ("metadataDetails", { $0.metadataDetails != nil }), ("parameterDetails", { $0.parameterDetails != nil }),
            ("dropouts", { $0.dropouts != nil }), ("batteryDetails", { $0.batteryDetails != nil }),
            ("gnssDetails", { $0.gnssDetails != nil })
        ]
        let available = optional.filter { _, predicate in snapshot.logs.contains(where: predicate) }.map(\.0)
        let unavailable = optional.filter { _, predicate in snapshot.logs.contains { !predicate($0) } }.map(\.0)
        let completeDetails = !snapshot.logs.isEmpty && unavailable.isEmpty
        return Self(mode: mode,
                    scopeDescription: scopeDescription ?? (mode == .full ? "Toute la bibliothèque" : mode == .flight ? "Fiche d’un log" : "Sélection courante"),
                    revision: revision, generatedAt: snapshot.generatedAt,
                    includesMaskedMessages: includesMaskedMessages,
                    completeness: completeDetails ? .detailed : available.isEmpty ? .summary : .partial,
                    availableSections: ["messages", "metrics", "metadata", "topics", "sources"] + available,
                    unavailableSections: unavailable)
    }
}

/// Measured output size; the caller can offer a compact export before publishing
/// an oversized document. No record is silently discarded to satisfy the budget.
public struct ReportHTMLDocument: Sendable {
    public let html: String
    public let manifest: ReportScopeManifest
    public let byteCount: Int
    public let byteBudget: Int
    public var exceedsBudget: Bool { byteCount > byteBudget }
}
