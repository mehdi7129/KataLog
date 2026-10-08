import Combine
import Foundation
import KataLogCore

/// Client membership belongs to logs. Controller identity stays global.
@MainActor
final class ClientStore: ObservableObject {
    @Published private(set) var profiles: [ClientProfile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    private weak var library: LibraryStore?
    private var readTask: Task<Void, Never>?
    private var token = UUID()

    init(library: LibraryStore) { self.library = library }

    func scopeLabel(for id: String?) -> String {
        guard let id else { return "Tous les clients" }
        if id.isEmpty { return "Sans client" }
        return profiles.first { $0.id == id }?.name ?? "Client indisponible"
    }

    /// A cached navigation page may still need to recover a failed client read.
    func reloadIfNeeded(refresh: Bool = false) {
        guard !isLoading, !isWorking, refresh || !hasLoaded || errorMessage != nil else { return }
        reload()
    }

    func cancelRead() {
        readTask?.cancel(); token = UUID(); readTask = nil; isLoading = false
    }

    func cancelReadAndWait() async {
        let pending = readTask
        cancelRead()
        await pending?.value
    }

    func reload() {
        guard !isWorking, library?.isMaintainingLibrary != true else { return }
        let previous = readTask
        previous?.cancel(); let expected = UUID(); token = expected
        readTask = nil; isLoading = false
        guard let library, let engine = library.engineURL,
              FileManager.default.fileExists(atPath: library.databaseURL.path) else {
            errorMessage = "La bibliothèque ou le moteur d’analyse est momentanément indisponible."
            return
        }
        let database = library.databaseURL
        isLoading = true; errorMessage = nil
        readTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, token == expected else { return }
            defer {
                if token == expected { isLoading = false; readTask = nil }
            }
            do {
                struct Response: Decodable { var clients: [ClientProfile] }
                let data = try await AnalysisService.run(["clients", "--database", database.path, "--read-only"], engine: engine)
                let result = try JSONDecoder().decode(Response.self, from: data)
                guard !Task.isCancelled, token == expected else { return }
                profiles = result.clients; hasLoaded = true; errorMessage = nil
                let validIDs = Set(profiles.map(\.id)), previousScope = library.views.state.activeScope
                var issues: [String] = []
                do { try library.views.reconcileClientScope(validIDs: validIDs) }
                catch { issues.append(error.localizedDescription) }
                if previousScope != library.views.state.activeScope { library.reload() }
                if !library.isReadOnly {
                    do { try await library.clientProfilesDidLoad(validIDs) }
                    catch { issues.append("Nettoyage de la collecte incomplet : \(error.localizedDescription)") }
                }
                guard !Task.isCancelled, token == expected else { return }
                if !issues.isEmpty { errorMessage = issues.joined(separator: " ") + " Réessayez de charger les clients." }
            } catch {
                guard !Task.isCancelled, token == expected else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func create(name: String) async throws -> ClientProfile {
        struct Request: Encodable { var name: String }
        let data = try await mutate("create-client", request: Request(name: name))
        let client = try JSONDecoder().decode(ClientProfile.self, from: data)
        profiles.append(client); sortProfiles(); return client
    }

    func rename(id: String, name: String) async throws {
        struct Request: Encodable { var id: String; var name: String }
        let data = try await mutate("rename-client", request: Request(id: id, name: name))
        let client = try JSONDecoder().decode(ClientProfile.self, from: data)
        profiles.removeAll { $0.id == id }; profiles.append(client); sortProfiles()
    }

    func remove(id: String) async throws {
        struct Request: Encodable { var id: String }
        var issues: [String] = []
        _ = try await mutate("delete-client", request: Request(id: id)) { [weak library] in
            do { try await library?.clientDidDelete(id) }
            catch { issues.append("Nettoyage de la collecte incomplet : \(error.localizedDescription)") }
        }
        profiles.removeAll { $0.id == id }
        do { try library?.views.reconcileClientScope(validIDs: Set(profiles.map(\.id))) }
        catch { issues.append(error.localizedDescription) }
        library?.reload()
        if !issues.isEmpty {
            let message = "Client supprimé ; ses logs sont conservés sans client. " + issues.joined(separator: " ") + " Réessayez de charger les clients pour reprendre le nettoyage."
            errorMessage = message
            throw AnalysisError.engine(message)
        }
    }

    func assign(scope: SelectionScope, to clientID: String?) async throws {
        guard let library else { return }
        struct Request: Encodable {
            var scope: SelectionScope
            var clientID: String?
            var annotations: DroneAnnotationState
            var maskedMessageKeys: [String]
        }
        _ = try await mutate("assign-client", request: Request(scope: scope,
            clientID: clientID?.isEmpty == true ? nil : clientID,
            annotations: library.annotations.state, maskedMessageKeys: library.views.state.maskedMessageKeys))
        library.reload()
    }

    func assign(logIDs: [String], to clientID: String?) async throws {
        guard !logIDs.isEmpty else { throw AnalysisError.engine("Sélectionnez au moins un log.") }
        var scope = SelectionScope(); scope.logIDs = logIDs; scope.includeMasked = true
        try await assign(scope: scope, to: clientID)
    }

    private func mutate<T: Encodable>(_ command: String, request: T, after: (() async throws -> Void)? = nil) async throws -> Data {
        guard !isWorking, let library, let engine = library.engineURL else {
            throw AnalysisError.engine("La gestion des clients est indisponible pour le moment.")
        }
        isWorking = true
        defer { isWorking = false }
        let data = try JSONEncoder().encode(request)
        return try await library.performMaintenance {
            let result = try await AnalysisService.run([command, "--database", library.databaseURL.path], engine: engine, request: data)
            try await after?()
            return result
        }
    }

    private func sortProfiles() { profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
}
