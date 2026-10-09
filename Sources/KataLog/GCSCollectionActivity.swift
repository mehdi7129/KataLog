import Foundation

/// Keep an unattended collection alive without preventing the display sleeping.
final class GCSCollectionActivity {
    private var token: NSObjectProtocol?
    @MainActor var isActive: Bool { token != nil }

    @MainActor func update(needed: Bool) {
        if needed, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Collecte des logs GCS")
        } else if !needed, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
