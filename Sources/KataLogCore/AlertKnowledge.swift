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
    public var catalogueVersion: Int { AlertKnowledge.catalogueVersion }
    public var isDocumented: Bool { confidence == .documented }
}

public enum AlertConfidence: String, Codable, Sendable {
    case documented, interpretation, context, raw

    public var label: String {
        switch self {
        case .documented: "Définition documentée"
        case .interpretation: "Interprétation du texte"
        case .context: "Contexte du module uniquement"
        case .raw: "Message source"
        }
    }
}

/// An upstream definition explains a message, not the cause of a failure on a
/// particular vehicle. The manufacturer's build is never inferred from a label.
public enum AlertKnowledge {
    public static let catalogueVersion = 2

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
                    id: "unknown", title: "Message du module \(module)",
                    meaning: context,
                    checks: ["Lire le texte source et les messages voisins pour identifier ce qui s’est produit.",
                             "Comparer avec les mesures du même instant et les autres logs du même drone."],
                    limits: "Ce contexte décrit le rôle du module. La signification précise de ce message et sa cause ne sont pas établies ; son niveau ne prouve pas une panne.",
                    provenance: "Contexte technique uniquement · message sans définition spécifique dans le catalogue",
                    sources: [], confidence: .context, referenceFirmware: nil)
            }
        }
        return AlertExplanation(
            id: "unknown", title: "Message à interpréter",
            meaning: "Le texte source décrit un événement enregistré par le firmware. Sa signification précise n’est pas encore établie dans le catalogue local.",
            checks: ["Lire les messages voisins et les mesures disponibles dans le log.",
                     "Rechercher ce texte exact dans les sources correspondant à la version du firmware."],
            limits: "La famille et le niveau facilitent le tri ; ils ne déterminent pas une cause. Une définition constructeur ou un dictionnaire d’événements correspondant exactement au firmware peut être nécessaire.",
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
