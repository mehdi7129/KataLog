import Combine
import Foundation
import KataLogCore

struct LibraryStorageInfo: Decodable, Sendable {
    struct Source: Decodable, Identifiable, Sendable {
        var logID: String
        var path: String
        var sizeBytes: Int64?
        var availability: SourceAvailability
        var id: String { logID + ":" + path }
    }
    struct Recovery: Decodable, Identifiable, Sendable {
        var name: String
        var sizeBytes: Int64
        var id: String { name }
    }
    var storageVersion: Int
    var checkedAt: String
    var logCount: Int
    var sourceCount: Int
    var detailCacheCount: Int
    var detailCacheBytes: Int64
    var databaseBytes: Int64
    var analysisRevisionCount: Int?
    var analysisRevisionBytes: Int64?
    var sources: [Source]
    var nextOffset: Int?
    var recoveries: [Recovery]
}

@MainActor
final class LibraryStorageStore: ObservableObject {
    @Published private(set) var info: LibraryStorageInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var currentOffset = 0
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryURL: URL?
    private weak var library: LibraryStore?
    private var readTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var token = UUID()
    init(library: LibraryStore) { self.library = library }
    func load(offset: Int = 0, clearError: Bool = true) {
        readTask?.cancel(); let expected = UUID(); token = expected
        guard let library, FileManager.default.fileExists(atPath: library.databaseURL.path) else {
            info = nil; isLoading = false; readTask = nil; currentOffset = 0
            if clearError { errorMessage = nil }
            return
        }
        guard let engine = library.engineURL else {
            info = nil; isLoading = false; readTask = nil; currentOffset = 0
            errorMessage = "Le moteur d’analyse est absent. Réinstallez KataLog pour consulter le stockage."
            return
        }
        isLoading = true; if clearError { errorMessage = nil }
        let database = library.databaseURL, directory = library.storageDirectory
        readTask = Task { [weak self] in
            do {
                let data = try await AnalysisService.run(["storage-info", "--database", database.path, "--library", directory.path,
                    "--offset", String(offset), "--limit", "200"], engine: engine)
                let result = try JSONDecoder().decode(LibraryStorageInfo.self, from: data)
                guard !Task.isCancelled, let self, token == expected else { return }
                info = result; currentOffset = offset; isLoading = false; readTask = nil
            } catch {
                guard !Task.isCancelled, let self, token == expected else { return }
                errorMessage = error.localizedDescription; isLoading = false; readTask = nil
            }
        }
    }
    func perform(command: String, logIDs: [String] = [], destination: URL? = nil, folder: URL? = nil, recovery: URL? = nil) {
        guard !isWorking, let library, let engine = library.engineURL else { return }
        let allowed = ["archive", "reassociate", "clean-cache", "restore-cache", "recover-archive"]
        guard allowed.contains(command) else { return }
        isWorking = true; errorMessage = nil; message = "Vérification et traitement…"
        var arguments = [command, "--database", library.databaseURL.path]
        if command != "reassociate" && command != "restore-cache" { arguments += ["--library", library.storageDirectory.path] }
        if let destination { arguments += ["--destination", destination.path] }
        if let folder { arguments += ["--folder", folder.path] }
        if let recovery { arguments += ["--recovery", recovery.path] }
        struct Selection: Encodable { var logIDs: [String] }
        let request = ["archive", "clean-cache"].contains(command) ? try? JSONEncoder().encode(Selection(logIDs: logIDs)) : nil
        readTask?.cancel(); isLoading = false
        workTask = Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false; workTask = nil }
            do {
                let data = try await library.performMaintenance {
                    try await AnalysisService.run(arguments, engine: engine, request: request)
                }
                let result = try JSONDecoder().decode(JSONValue.self, from: data)
                recoveryURL = result["recoveryDirectory"]?.stringValue.map { URL(fileURLWithPath: $0, isDirectory: true) }
                message = Self.summary(command: command, result: result)
                library.reload(); load()
            } catch is CancellationError { message = "Opération interrompue. Les originaux sont conservés ; une récupération peut être nécessaire." }
            catch { errorMessage = error.localizedDescription; load(clearError: false) }
        }
    }
    func cancel() { message = "Arrêt en cours…"; workTask?.cancel() }
    static func summary(command: String, result: JSONValue) -> String {
        func count(_ key: String) -> Int { result[key]?.countValue ?? 0 }
        switch command {
        case "archive": return "\(count("completed")) fichiers archivés · \(count("reused")) copies déjà présentes · \(count("failed")) erreurs. Les originaux sont conservés."
        case "reassociate": return "\(count("matched")) sources retrouvées · \(count("unrelated")) fichiers sans correspondance · \(count("errors")) erreurs."
        case "clean-cache": return "\(count("removedCount")) caches détaillés et \(count("removedRevisionCount")) anciennes révisions déplacés vers la récupération · \(count("retainedRevisionCount")) dernières révisions conservées dans l’historique. Les ULog et les résumés restent disponibles. L’espace de la base n’est pas automatiquement compacté."
        case "restore-cache": return "\(count("restoredCount")) caches détaillés restaurés · \(count("skippedCount")) caches déjà présents ou incompatibles. Les révisions récupérables sont également réintégrées dans l’historique."
        default: return "\(count("completed")) archives vérifiées · \(count("interrupted")) transferts interrompus préservés pour récupération."
        }
    }
}
