import AppKit
import KataLogCore

@MainActor
final class KataLogApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryStore?
    weak var gcs: GCSStore?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        let hasWork = library?.hasActiveWork == true || gcs?.isBusy == true
        if hasWork {
            let alert = NSAlert()
            alert.messageText = "Une opération est en cours"
            alert.informativeText = "Vous pouvez la laisser se terminer ou l’arrêter avant de quitter. Les fichiers déjà validés sont conservés. Un transfert arrêté localement peut encore se terminer sur le drone."
            alert.addButton(withTitle: "Continuer l’opération")
            alert.addButton(withTitle: "Arrêter et quitter")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        terminating = true
        library?.prepareForTermination(); gcs?.stopCollection(); gcs?.disconnect()
        EngineOperations.beginTermination()
        Task { [weak self] in
            while EngineOperations.activeProcessCount > 0 || self?.library?.hasActiveWork == true || self?.gcs?.isBusy == true {
                try? await Task.sleep(for: .milliseconds(50))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
