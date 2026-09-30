import Foundation

/// User-facing definitions shared by the native application and exported reports.
public enum LibraryHelp {
    public static let sources = "Dossiers utilisés pour importer des logs. Retirer un dossier de cette liste conserve les fichiers, les analyses et les numéros de drones. Le retrait peut être annulé."
    public static let provenance = "Chemins connus des fichiers conservés dans l’historique. Ils peuvent rester présents après le retrait d’un dossier d’import. La liste des dossiers d’import actifs se consulte dans l’app."
    public static let drones = "Drones identifiés dans les logs sélectionnés à partir de leur contrôleur. Les identités provisoires sans identifiant fiable sont affichées séparément."
    public static let recordedDuration = "Durée totale des enregistrements lisibles sélectionnés, y compris le temps passé au sol."
    public static let flightDuration = "Temps en vol mesuré par le détecteur d’atterrissage PX4 lorsque sa couverture est suffisante. Les logs sans mesure disponible ne sont pas comptés comme zéro."
    public static let alerts = "Nombre de logs contenant des messages textuels d’alerte ou un état failsafe dans la sélection. Plusieurs répétitions dans un log comptent comme un seul log concerné. Les événements PX4 sont évalués dans les badges de niveau."
    public static let profile = "Nombre de logs concernés par famille d’alertes textuelles. Un log peut appartenir à plusieurs familles ; une répétition du même message ne compte pas comme une nouvelle panne."
    public static let assessment = "Niveau le plus élevé des signaux repérés dans le périmètre affiché : messages, événements PX4 évalués et état failsafe. Le badge explique ce qui est enregistré ; il ne confirme pas à lui seul une panne."
    public static let analysisQuality = "Indique si le fichier est lisible en totalité, partiellement ou pas du tout. Les mesures et événements absents ou non interprétés restent signalés dans la couverture de l’analyse."
    public static func flightCoverage(measured: Int, total: Int) -> String {
        "Calculé sur \(measured) / \(total) logs"
    }
}

public struct LogAssessment: Codable, Equatable, Sendable {
    public var state: String
    public var level: String?
    public var primaryText: String?
    public var occurrenceCount: Int
    public var eventCount: Int
    public var untranslatedEventCount: Int

    public init(state: String, level: String? = nil, primaryText: String? = nil,
                occurrenceCount: Int = 0, eventCount: Int = 0, untranslatedEventCount: Int = 0) {
        self.state = state; self.level = level; self.primaryText = primaryText
        self.occurrenceCount = occurrenceCount; self.eventCount = eventCount
        self.untranslatedEventCount = untranslatedEventCount
    }
    public var label: String {
        switch state {
        case "critical": "Signal critique"
        case "error": "Erreur à vérifier"
        case "warning": "Avertissement"
        case "none": "Aucune alerte détectée"
        default: "Niveau indéterminé"
        }
    }
    public var tone: String {
        switch state { case "critical": "red"; case "error": "orange"; case "warning": "yellow"; default: "neutral" }
    }
    public var symbolName: String {
        switch state {
        case "critical": "exclamationmark.octagon.fill"
        case "error": "exclamationmark.triangle"
        case "warning": "exclamationmark.circle"
        case "none": "minus.circle"
        default: "questionmark.circle"
        }
    }
    public var reason: String {
        if let primaryText, !primaryText.isEmpty { return primaryText }
        switch state {
        case "none": return "Aucune alerte classée dans les données évaluées"
        case "unknown": return "Données insuffisantes pour établir le niveau"
        default: return "Signal enregistré dans les données évaluées"
        }
    }
    public var help: String {
        var text = LibraryHelp.assessment
        if state == "unknown" { text += " Le niveau ne peut pas être établi avec les données disponibles." }
        if state == "none" { text += " Aucune alerte classée n’a été repérée dans les données évaluées." }
        if untranslatedEventCount > 0 { text += " \(untranslatedEventCount) événements restent sans texte interprété." }
        return text
    }
}

public extension FlightLog {
    var isProvisionalIdentity: Bool {
        if let identityProvisional { return identityProvisional }
        let key = droneID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty || key.hasPrefix("card:") || key.hasPrefix("unknown:")
    }
    var analysisQualityLabel: String {
        switch status { case "error": "Lecture impossible"; case "partial": "Lecture partielle"; default: "Lecture complète" }
    }
    var assessment: LogAssessment {
        if let signalAssessment { return signalAssessment }
        return inferredAssessment
    }
    /// Conservative fallback for older analyses or a freshly loaded detailed log.
    var inferredAssessment: LogAssessment {
        let includesEvents = selectionIncludesEvents ?? selectionIncludesFailsafe ?? true
        let observedEvents = includesEvents ? (events ?? []) : []
        let untranslated = observedEvents.filter { $0.translationStatus != "translated" }.count
        var candidates: [(rank: Int, level: String?, text: String)] = []
        var unknown = false
        var failsafeMessage = false
        for message in messages {
            let level = message.level.uppercased()
            let rank = LogMessage.rank(level)
            let failsafe = message.text.range(of: #"\bfailsafe activated\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            failsafeMessage = failsafeMessage || failsafe
            if rank == 0 { unknown = true }
            if message.isAlert || rank >= 4 || failsafe || message.text.uppercased().contains("[ALARM]") {
                candidates.append((max(4, rank), rank == 0 ? nil : level,
                                   message.text.isEmpty ? message.title : message.text))
            }
        }
        for event in observedEvents {
            let names = [event.internalLevelName, event.externalLevelName].compactMap { $0?.uppercased() }.filter { !$0.isEmpty }
            let level = names.max(by: { LogMessage.rank($0) < LogMessage.rank($1) }) ?? event.level.uppercased()
            let rank = LogMessage.rank(level.uppercased())
            if rank == 0 { unknown = true }
            if rank >= 4 {
                let translatedText = event.translationStatus == "translated" ? event.message : nil
                candidates.append((rank, level, translatedText ?? "Événement PX4 \(event.eventID.description)"))
            }
        }
        if (selectionIncludesFailsafe ?? true) && failsafeObserved && !failsafeMessage {
            candidates.append((4, nil, "Failsafe observé"))
        }
        if let highest = candidates.enumerated().max(by: {
            $0.element.rank == $1.element.rank ? $0.offset > $1.offset : $0.element.rank < $1.element.rank
        })?.element {
            let state = highest.rank >= 6 ? "critical" : highest.rank >= 5 ? "error" : "warning"
            return .init(state: state, level: highest.level, primaryText: highest.text,
                         occurrenceCount: candidates.count, eventCount: observedEvents.count,
                         untranslatedEventCount: untranslated)
        }
        let eventsComplete = !includesEvents || events != nil || (!topics.contains("event") && metadata["parserVersion"]?.isEmpty == false)
        let incomplete = status != "ok" || unknown || !eventsComplete
            || (summaryMessageCount ?? messages.count) > messages.count
            || (summaryAlertMessageCount ?? 0) > 0 || (summaryHasAlerts ?? false)
        return .init(state: incomplete ? "unknown" : "none", eventCount: observedEvents.count,
                     untranslatedEventCount: untranslated)
    }
}

public extension FleetSnapshot {
    var scannedDroneCount: Int { Set(logs.filter { !$0.isProvisionalIdentity }.map(\.droneID)).count }
    var provisionalDroneCount: Int { Set(logs.filter(\.isProvisionalIdentity).map(\.droneID)).count }
    var flightLogCount: Int { validLogs.filter { $0.flightSeconds.map { $0.isFinite && $0 >= 0 } ?? false }.count }
    var totalFlightSeconds: Double? {
        guard flightLogCount > 0 else { return nil }
        return validLogs.compactMap(\.flightSeconds).filter { $0.isFinite && $0 >= 0 }.reduce(0, +)
    }
}

public extension LibraryTotals {
    var scannedDrones: Int { scannedDroneCount ?? max(0, droneCount - (provisionalDroneCount ?? 0)) }
    var provisionalDrones: Int { provisionalDroneCount ?? 0 }
    var measuredFlightLogCount: Int { flightLogCount ?? 0 }
    var measuredFlightSeconds: Double? {
        guard measuredFlightLogCount > 0, let flightSeconds, flightSeconds.isFinite, flightSeconds >= 0 else { return nil }
        return flightSeconds
    }
}
