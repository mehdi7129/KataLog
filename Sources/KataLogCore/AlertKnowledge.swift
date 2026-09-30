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
    public var catalogueVersion: Int { 1 }
    public var confidence: AlertConfidence {
        if id == "unknown" { return .raw }
        return id == "accelerometer-consistency" ? .documented : .interpretation
    }
    public var referenceFirmware: String? {
        sources.isEmpty ? nil : "PX4 v1.14.0 — référence ; compatibilité constructeur non attestée"
    }
    public var isDocumented: Bool { confidence == .documented }
}

public enum AlertConfidence: String, Codable, Sendable {
    case documented, interpretation, raw
    public var label: String {
        switch self {
        case .documented: "Définition documentée"
        case .interpretation: "Interprétation du texte"
        case .raw: "Message source"
        }
    }
}

/// Explanations are tied to complete, observed messages. Classification alone is
/// deliberately insufficient to infer a failure or its cause.
public enum AlertKnowledge {
    public static func explanation(for message: LogMessage) -> AlertExplanation {
        explanation(forText: message.text)
    }

    public static func explanation(forText text: String) -> AlertExplanation {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(#"^\[batt_smbus\] SMBus read error: -1$"#, raw) {
            return AlertExplanation(id: "battery-smbus-read", title: "Lecture de la batterie impossible", meaning: "Le pilote de batterie signale un échec de lecture sur le bus SMBus/I²C. Certaines informations de batterie peuvent manquer à cet instant.", checks: ["Vérifier si le message se répète et si les mesures de batterie restent disponibles.", "Comparer avec les autres logs du même drone et de la même batterie, si celle-ci est identifiée.", "En cas de répétition, contrôler les connexions de communication de la batterie selon la procédure constructeur."], limits: "Le code −1 ne précise pas la cause. Ce message ne prouve ni une batterie défectueuse ni une coupure d’alimentation.", provenance: "Interprétation du message constructeur · contexte du pilote PX4 v1.14", sources: [source("Pilote SMBus PX4 v1.14", "https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/src/drivers/batt_smbus/batt_smbus.cpp#L84-L183")])
        }
        if matches(#"^\[wifi_broadcom\] Wifi link lost$"#, raw) {
            return AlertExplanation(id: "wifi-link-lost", title: "Liaison Wi-Fi perdue", meaning: "Le module Wi-Fi signale la perte de sa liaison à cet instant.", checks: ["Rechercher un message explicite de reconnexion dans la chronologie.", "Comparer les horaires avec ceux des autres drones pour repérer une perte simultanée.", "Examiner la qualité radio enregistrée et la couverture de l’antenne lorsqu’elles sont disponibles."], limits: "La durée de la coupure, la perte éventuelle d’autres communications et un éventuel failsafe ne sont pas établis par ce seul message.", provenance: "Interprétation du message constructeur · définition Drotek non disponible", sources: [])
        }
        if matches(#"^\[rgbled_pwm\] Temperature too high,? disabling LED$"#, raw) {
            return AlertExplanation(id: "led-temperature", title: "Éclairage désactivé pour température élevée", meaning: "Le pilote d’éclairage indique avoir désactivé les LED après une alerte de température.", checks: ["Comparer avec les températures réellement enregistrées et l’utilisation des LED, si ces données sont présentes.", "Vérifier la répétition du message et rechercher une indication explicite de réactivation.", "Si cela se reproduit, contrôler le système d’éclairage selon les consignes du constructeur."], limits: "Le message ne précise ni le capteur ni le seuil. Il ne prouve pas une surchauffe de tout le drone et ne permet pas de dater la réactivation des LED.", provenance: "Interprétation du message constructeur · définition Drotek non disponible", sources: [])
        }
        if matches(#"^\[health_and_arming_checks\] Preflight Fail: Accel [0-9]+ inconsistent - check cal$"#, raw) {
            return AlertExplanation(id: "accelerometer-consistency", title: "Écart entre les accéléromètres", meaning: "Le contrôle avant vol détecte un désaccord entre l’accéléromètre indiqué et les autres capteurs inertiels. Le message invite à vérifier la calibration.", checks: ["Vérifier la calibration et les conditions de mesure selon la procédure constructeur.", "Comparer les accélérations et les vibrations disponibles dans le log.", "Vérifier les autres résultats des contrôles avant vol et la valeur enregistrée de COM_ARM_IMU_ACC."], limits: "Dans PX4 v1.14, ce texte peut apparaître dès 80 % du seuil COM_ARM_IMU_ACC ; le blocage d’armement intervient au-delà du seuil complet. Le comportement exact du firmware Drotek peut différer. Ce texte seul ne prouve pas une panne matérielle ni un armement interdit.", provenance: "Documenté dans PX4 · référence v1.14", sources: [source("Contrôle de cohérence IMU · PX4 v1.14", "https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/src/modules/commander/HealthAndArmingChecks/checks/imuConsistencyCheck.cpp#L38-L69")])
        }
        return AlertExplanation(id: "unknown", title: "Explication non disponible", meaning: "Ce message est conservé intégralement. Il n’existe pas encore d’explication vérifiée dans le catalogue local.", checks: ["Lire les messages voisins et les mesures disponibles dans le log.", "Utiliser le module et la version du firmware pour rechercher la définition correspondante."], limits: "Le niveau et la famille facilitent le tri ; ils ne déterminent pas à eux seuls une cause ou une panne. Une famille peut être attribuée manuellement sans modifier le message source.", provenance: "Message source uniquement", sources: [])
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func source(_ title: String, _ url: String) -> AlertSource {
        AlertSource(title: title, url: URL(string: url)!)
    }
}
