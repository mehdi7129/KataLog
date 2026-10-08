import Combine
import Foundation
import KataLogCore

@MainActor
final class LibraryViewStore: ObservableObject {
    @Published private(set) var state = LibraryViewState()
    @Published private(set) var errorMessage: String?
    var canMutate: () -> Bool = { true }
    private let url: URL
    private let canWrite: Bool
    private var persisted: Data?
    private var loadFailed = false
    private var reconciledScopeNeedsSave = false
    init(url: URL, canWrite: Bool = true) {
        self.url = url; self.canWrite = canWrite
        reload()
    }
    func reload() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            persisted = nil; state = .init(); loadFailed = false; reconciledScopeNeedsSave = false; errorMessage = nil; return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(LibraryViewState.self, from: data)
            guard decoded.schemaVersion == 1 else { throw AnalysisError.schema(decoded.schemaVersion) }
            persisted = data; state = decoded; loadFailed = false; reconciledScopeNeedsSave = false; errorMessage = nil
        } catch { loadFailed = true; errorMessage = "Vues illisibles : \(error.localizedDescription). Le fichier est conservé." }
    }
    func setScope(_ scope: SelectionScope) throws {
        var next = state; next.activeScope = scope; try save(next)
    }
    func chooseClient(_ id: String?) throws {
        var scope = state.activeScope
        scope.clientID = id
        scope.logIDs = []
        scope.droneKeys = []
        try chooseScope(scope)
    }
    func setAdvancedMode(_ enabled: Bool) throws {
        var next = state; next.advancedMode = enabled; try save(next)
    }
    /// A deleted client cannot remain the active filter even if saving fails.
    func reconcileClientScope(validIDs: Set<String>) throws {
        let invalidClient = state.activeScope.clientID.map { !$0.isEmpty && !validIDs.contains($0) } ?? false
        guard invalidClient || reconciledScopeNeedsSave else { return }
        var scope = state.activeScope
        if invalidClient {
            scope.clientID = ""; scope.logIDs = []; scope.droneKeys = []
        }
        try reconcileScope(scope)
    }
    func clearLogFiltersAfterReset() throws {
        var scope = SelectionScope(); scope.clientID = state.activeScope.clientID
        try reconcileScope(scope)
    }
    private func reconcileScope(_ scope: SelectionScope) throws {
        do { try chooseScope(scope) }
        catch {
            var next = state; next.activeScope = scope
            next.revision += 1; state = next
            reconciledScopeNeedsSave = true
            let message = "Le filtre affiché a été actualisé, mais le réglage n’a pas pu être enregistré : \(error.localizedDescription)"
            errorMessage = message
            throw AnalysisError.engine(message)
        }
    }
    /// A secondary reader may explore the library without writing settings.
    func chooseScope(_ scope: SelectionScope) throws {
        guard canMutate() else { throw AnalysisError.engine("La bibliothèque est en maintenance.") }
        if canWrite { try setScope(scope) }
        else { var next = state; next.activeScope = scope; next.revision += 1; state = next }
    }
    func setTheme(_ value: String) throws {
        guard ["system", "light", "dark"].contains(value) else { throw AnalysisError.engine("Thème inconnu.") }
        var next = state; next.theme = value; try save(next)
    }
    func chooseHistorySort(_ value: String) throws {
        guard ["recent", "oldest"].contains(value), canMutate() else { throw AnalysisError.engine("Le tri est invalide ou la bibliothèque est en maintenance.") }
        var next = state; next.historySort = value
        if canWrite { try save(next) } else { next.revision += 1; state = next }
    }
    func setProfileAxes(_ axes: [String]) throws {
        guard axes.count <= 8, Set(axes).count == axes.count else { throw AnalysisError.engine("Choisissez au maximum huit axes distincts.") }
        var next = state; next.profileAxes = axes; try save(next)
    }
    func setStudy(_ request: TelemetryRequest, for logID: String) throws {
        var next = state; var preferences = next.studyPreferences ?? [:]
        preferences[logID] = request; next.studyPreferences = preferences; try save(next)
    }
    func saveView(name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw AnalysisError.engine("Le nom de la vue doit contenir entre 1 et 80 caractères.") }
        var next = state
        next.views.append(SavedLibraryView(name: name, scope: state.activeScope))
        try save(next)
    }
    func removeView(_ id: String) throws {
        var next = state; next.views.removeAll { $0.id == id }; try save(next)
    }
    func mask(_ keys: [String], masked: Bool) throws {
        var next = state; var selected = Set(next.maskedMessageKeys)
        for key in keys where key.hasPrefix("text-v1:") { if masked { selected.insert(key) } else { selected.remove(key) } }
        next.maskedMessageKeys = selected.sorted(); try save(next)
    }
    private func save(_ value: LibraryViewState) throws {
        guard canWrite, canMutate(), !loadFailed else { throw AnalysisError.engine("La bibliothèque est occupée, en lecture seule ou les vues sont illisibles.") }
        let current = try? Data(contentsOf: url)
        guard current == persisted else { throw AnalysisError.engine("Les vues ont changé dans un autre processus. Rechargez-les avant de modifier.") }
        var next = value; next.revision += 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        persisted = data; state = next; reconciledScopeNeedsSave = false; errorMessage = nil
    }
}
