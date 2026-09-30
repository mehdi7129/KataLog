import Combine
import Foundation
import KataLogCore

struct SourceFolderPage: Decodable, Sendable {
    struct Folder: Decodable, Identifiable, Sendable {
        var path: String
        var logCount: Int
        var state: String
        var removed: Bool
        var id: String { path }
        var name: String {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? path : name
        }
        var availabilityLabel: String {
            switch state {
            case "present": "Dossier accessible"
            case "missing": "Dossier absent"
            case "offline": "Volume hors ligne"
            case "inaccessible": "Dossier inaccessible"
            default: "Disponibilité non vérifiée"
            }
        }
    }
    var activeCount: Int
    var removedCount: Int
    var total: Int
    var nextOffset: Int?
    var folders: [Folder]
    static let empty = SourceFolderPage(activeCount: 0, removedCount: 0, total: 0, folders: [])
}

@MainActor
final class SourcesImportStore: ObservableObject {
    typealias Runner = ([String], URL) async throws -> Data
    private struct ChangeResult: Decodable {
        var path: String
        var removed: Bool
        var logsDeleted: Bool
        var originalsDeleted: Bool
    }
    struct Change {
        var path: String
        var removed: Bool
        var undoLabel: String { removed ? "Annuler le retrait" : "Annuler la restauration" }
    }
    @Published private(set) var page: SourceFolderPage?
    @Published private(set) var currentOffset = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var message: String?
    @Published private(set) var lastChange: Change?
    private weak var library: LibraryStore?
    private let runner: Runner
    private var readTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var token = UUID()
    private var includeRemoved = false

    init(library: LibraryStore, runner: @escaping Runner = { arguments, engine in
        try await AnalysisService.run(arguments, engine: engine)
    }) { self.library = library; self.runner = runner }

    var canMutate: Bool {
        guard let library else { return false }
        return !library.isReadOnly && !library.isMaintainingLibrary && !library.isImporting &&
            !library.isExporting && !library.isLoading && !library.isQuerying && !library.isLoadingFlight &&
            !library.hasExternalActivity() && !isWorking && !isLoading
    }

    func load(offset: Int = 0, includeRemoved: Bool = false, clearError: Bool = true) {
        readTask?.cancel(); let expected = UUID(); token = expected
        self.includeRemoved = includeRemoved
        guard let library, FileManager.default.fileExists(atPath: library.databaseURL.path) else {
            page = .empty; currentOffset = 0; isLoading = false; readTask = nil
            if clearError { errorMessage = nil }; return
        }
        guard let engine = library.engineURL else {
            errorMessage = "Le moteur d’analyse est absent. Réinstallez KataLog pour consulter les sources."
            isLoading = false; readTask = nil; return
        }
        isLoading = true; if clearError { errorMessage = nil }
        let arguments = Self.listArguments(database: library.databaseURL,
            offset: offset, includeRemoved: includeRemoved)
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await runner(arguments, engine)
                let result = try JSONDecoder().decode(SourceFolderPage.self, from: data)
                guard !Task.isCancelled, token == expected else { return }
                page = result; currentOffset = offset; isLoading = false; readTask = nil
            } catch {
                guard !Task.isCancelled, token == expected else { return }
                errorMessage = error.localizedDescription; isLoading = false; readTask = nil
            }
        }
    }

    func setRemoved(_ removed: Bool, path: String, recordsUndo: Bool = true) {
        guard canMutate, let library, let engine = library.engineURL else { return }
        isWorking = true; errorMessage = nil
        message = removed ? "Retrait de la liste…" : "Restauration de la source…"
        token = UUID(); readTask?.cancel(); readTask = nil; isLoading = false
        let arguments = Self.changeArguments(database: library.databaseURL, path: path, removed: removed)
        workTask = Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false; workTask = nil }
            do {
                let data = try await library.performMaintenance { try await runner(arguments, engine) }
                try Task.checkCancellation()
                let result = try JSONDecoder().decode(ChangeResult.self, from: data)
                guard result.path == path, result.removed == removed, !result.logsDeleted, !result.originalsDeleted else {
                    throw AnalysisError.engine("Le moteur n’a pas confirmé la conservation des analyses et des fichiers.")
                }
                lastChange = recordsUndo ? Change(path: path, removed: removed) : nil
                message = removed ? "Source retirée de la liste. Les analyses et les fichiers sont conservés." : "Source restaurée dans la liste. Les analyses et les fichiers sont conservés."
                library.reload(); load(includeRemoved: includeRemoved)
            } catch is CancellationError {
                message = "Opération interrompue. Actualisez la liste pour vérifier l’état de la source."
                load(includeRemoved: includeRemoved, clearError: false)
            } catch {
                errorMessage = error.localizedDescription
                load(includeRemoved: includeRemoved, clearError: false)
            }
        }
    }

    func undo() {
        guard let lastChange else { return }
        setRemoved(!lastChange.removed, path: lastChange.path, recordsUndo: false)
    }
    static func listArguments(database: URL, offset: Int, includeRemoved: Bool) -> [String] {
        var arguments = ["source-folders", "--database", database.path,
                         "--offset", String(max(0, offset)), "--limit", "200"]
        if includeRemoved { arguments.append("--include-removed") }
        return arguments
    }
    static func changeArguments(database: URL, path: String, removed: Bool) -> [String] {
        [removed ? "retire-source" : "restore-source", "--database", database.path,
         "--folder", path]
    }
}
