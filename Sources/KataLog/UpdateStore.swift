import Combine
import Foundation
import KataLogCore
import Sparkle

@MainActor
final class UpdateStore: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum State: Equatable {
        case disabled, ready, checking, available(String), upToDate, deferred, failed(String)
    }
    @Published private(set) var state: State = .disabled
    @Published private(set) var driverCanCheck = false
    @Published private(set) var workBlocked = false
    var installationAllowed: () -> Bool = { true }
    private let configuration: UpdateConfiguration?
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private var postponement: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    var canCheck: Bool { configuration != nil && driverCanCheck && installationAllowed() && !workBlocked }
    var title: String {
        switch state {
        case .disabled: "Mises à jour manuelles"
        case .ready: "Rechercher une mise à jour"
        case .checking: "Recherche en cours…"
        case .available(let version): "Version \(version) disponible"
        case .upToDate: "KataLog est à jour"
        case .deferred: "Installation en attente"
        case .failed: "Mise à jour indisponible"
        }
    }
    var message: String {
        if workBlocked { return "Terminez les opérations en cours avant la mise à jour." }
        return switch state {
        case .disabled: "Ce build n’active aucun flux distant. Téléchargez le nouveau DMG et remplacez KataLog dans Applications. Votre bibliothèque est conservée."
        case .ready: "Vérifiez les nouvelles versions signées de KataLog."
        case .checking: "Vérification du flux signé…"
        case .available: "Sparkle affiche la version proposée et demande votre choix."
        case .upToDate: "Aucune nouvelle version compatible n’a été trouvée."
        case .deferred: "La mise à jour reprendra lorsque les opérations seront terminées."
        case .failed(let message): message
        }
    }

    init(info: [String: Any]? = nil, start: Bool = true) {
        do { configuration = try UpdatePolicy.configuration(info: info ?? Bundle.main.infoDictionary ?? [:]) }
        catch { configuration = nil; super.init(); state = .failed(error.localizedDescription); return }
        super.init()
        guard configuration != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            Task { @MainActor in self?.driverCanCheck = value }
        }
        state = .ready
        if start {
            do { try controller.updater.start() }
            catch { state = .failed(error.localizedDescription); return }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.workBlocked = !self.installationAllowed()
            }
        }
    }
    func checkForUpdates() {
        do { try UpdatePolicy.requireIdle(installationAllowed()) }
        catch { state = .failed(error.localizedDescription); return }
        guard let controller, driverCanCheck else { return }
        state = .checking; controller.checkForUpdates(nil)
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try UpdatePolicy.requireIdle(installationAllowed())
    }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { configuration?.channel == .staging ? ["staging"] : [] }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try UpdatePolicy.requireIdle(installationAllowed())
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state = .available(item.displayVersionString)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { state = .upToDate }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { state = .upToDate }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        postponement?.cancel()
        if state != .upToDate { state = .failed(error.localizedDescription) }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !installationAllowed() else { return false }
        state = .deferred; postponement?.cancel()
        postponement = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.installationAllowed() { self.postponement = nil; installHandler(); return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        return true
    }
}
