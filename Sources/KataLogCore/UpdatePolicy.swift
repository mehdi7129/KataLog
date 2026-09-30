import Foundation

public enum UpdateChannel: String, Sendable { case stable, staging }

public struct UpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String
    public let channel: UpdateChannel
}

/// Network updating is opt-in at build time. Invalid security settings fail closed.
public enum UpdatePolicy {
    public static let sparkleVersion = "2.10.0"
    public static func configuration(info: [String: Any]) throws -> UpdateConfiguration? {
        guard info["KatalogUpdatesEnabled"] as? Bool == true else { return nil }
        guard info["KatalogSparkleVersion"] as? String == sparkleVersion,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUEnableAutomaticChecks"] as? Bool == false,
              info["SUEnableJavaScript"] as? Bool == false,
              info["SUEnableSystemProfiling"] as? Bool == false else {
            throw error("La configuration des mises à jour signées est incomplète. Réinstallez une version officielle.")
        }
        guard let rawChannel = info["KatalogUpdateChannel"] as? String,
              let channel = UpdateChannel(rawValue: rawChannel) else { throw error("Le canal de mise à jour est invalide.") }
        guard let text = info["SUFeedURL"] as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.lowercased().hasSuffix(".xml"), (url.port == nil || url.port == 443),
              !host.contains(":"), !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw error("Le flux de mise à jour doit être une adresse HTTPS sans identifiants.")
        }
        guard let key = info["SUPublicEDKey"] as? String, let data = Data(base64Encoded: key),
              data.count == 32, data.contains(where: { $0 != 0 }), data.base64EncodedString() == key else {
            throw error("La clé publique de mise à jour est absente ou invalide.")
        }
        return UpdateConfiguration(feedURL: url, publicKey: key, channel: channel)
    }
    public static func requireIdle(_ allowed: Bool) throws {
        guard allowed else { throw error("Attendez la fin des imports, collectes, exports et opérations de stockage avant de mettre à jour KataLog.") }
    }
    private static func error(_ message: String) -> NSError {
        NSError(domain: "KataLog.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
