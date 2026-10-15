import Foundation

public struct AlertSource: Sendable {
    public let title: String
    public let url: URL
}

public struct AlertExplanation: Sendable {
    public let id: String
    public let title: String
    public let meaning: String
    public let checks: [String]
    public let limits: String
    public let provenance: String
    public let sources: [AlertSource]
    public let confidence: AlertConfidence
    public let referenceFirmware: String?
    public let technicalDetails: String?
    public var catalogueVersion: Int { AlertKnowledge.catalogueVersion }
    public var isDocumented: Bool { confidence == .documented }

    init(id: String, title: String, meaning: String, checks: [String], limits: String,
         provenance: String, sources: [AlertSource], confidence: AlertConfidence,
         referenceFirmware: String?, technicalDetails: String? = nil) {
        self.id = id; self.title = title; self.meaning = meaning; self.checks = checks
        self.limits = limits; self.provenance = provenance; self.sources = sources
        self.confidence = confidence; self.referenceFirmware = referenceFirmware
        self.technicalDetails = technicalDetails
    }
}

public enum AlertConfidence: String, Codable, Sendable {
    case documented, interpretation, unresolved, context, raw

    public var label: String {
        switch self {
        case .documented: "Définition documentée"
        case .interpretation: "Interprétation du texte"
        case .unresolved: "Sens exact inconnu"
        case .context: "Contexte du module uniquement"
        case .raw: "Message source"
        }
    }

    public var summaryLabel: String {
        switch self {
        case .documented: "Documenté"
        case .interpretation: "Sens déduit du texte"
        case .unresolved, .raw: "Sens exact inconnu"
        case .context: "Contexte uniquement"
        }
    }
}

/// An upstream definition explains a message, not the cause of a failure on a
/// particular vehicle. The manufacturer's build is never inferred from a label.
public enum AlertKnowledge {
    public static let catalogueVersion = 3

    public static func explanation(for message: LogMessage) -> AlertExplanation {
        explanation(forText: message.text)
    }

    public static func explanation(forText text: String) -> AlertExplanation {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry = AlertCatalogueData.entries.first(where: { $0.matches(raw) }) {
            return entry.explanation
        }
        return fallback(for: raw)
    }

    private static func fallback(for raw: String) -> AlertExplanation {
        // A prefix supplies context, never an event diagnosis. Only full-message
        // rules above can return a specific explanation.
        if raw.hasPrefix("["), let end = raw.firstIndex(of: "]") {
            let module = String(raw[raw.index(after: raw.startIndex)..<end])
            let baseModule = module.lowercased().split(separator: ":").first.map(String.init) ?? module.lowercased()
            if let context = AlertCatalogueData.moduleContexts[baseModule] {
                return AlertExplanation(
                    id: "unknown", title: "Message \(module) à identifier",
                    meaning: "Le sens exact de ce message reste inconnu. \(context)",
                    checks: ["Relever le texte complet et la version du firmware pour rechercher sa définition."],
                    limits: "Le rôle du module ne permet pas de déduire le sens du message ni sa gravité réelle.",
                    provenance: "Contexte technique uniquement · message sans définition spécifique dans le catalogue",
                    sources: [], confidence: .context, referenceFirmware: nil)
            }
        }
        return AlertExplanation(
            id: "unknown", title: "Sens du message à identifier",
            meaning: "La signification de ce message n’a pas encore été identifiée.",
            checks: ["Relever le texte complet et la version du firmware pour rechercher sa définition."],
            limits: "Le niveau enregistré ne suffit pas à identifier une panne ou sa cause.",
            provenance: "Message source uniquement · définition spécifique non identifiée",
            sources: [], confidence: .raw, referenceFirmware: nil)
    }
}

struct AlertCatalogueEntry: Sendable {
    let patterns: [String]
    let explanation: AlertExplanation
    private let expressions: [NSRegularExpression]

    init(patterns: [String], explanation: AlertExplanation) {
        self.patterns = patterns
        self.explanation = explanation
        self.expressions = patterns.map { pattern in
            // Reviewed, generated catalogue data; tests validate every expression.
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expressions.contains { expression in
            expression.firstMatch(in: text, range: range)?.range == range
        }
    }
}
