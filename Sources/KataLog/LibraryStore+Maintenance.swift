import AppKit
import Foundation
import KataLogCore

/// Exclusive library maintenance, restore and reset sequencing.
extension LibraryStore {
    /// Library-wide changes run under the stable writer lease with imports,
    /// collection persistence and annotation edits quiescent.
    func performMaintenance<T: Sendable>(allowOwnedExport: Bool = false, allowOwnedQuery: Bool = false, navigationOwner: LibraryNavigationStore? = nil, _ operation: () async throws -> T) async throws -> T {
        var capabilities = commandCapabilities
        capabilities.querying = hasOtherNavigationWork(than: navigationOwner)
        guard capabilities.canMaintain(allowOwnedExport: allowOwnedExport, allowOwnedQuery: allowOwnedQuery) else {
            throw AnalysisError.engine("Terminez ou arrêtez les opérations en cours avant de modifier ou sauvegarder la bibliothèque.")
        }
        isMaintainingLibrary = true
        defer { isMaintainingLibrary = false; invalidateNavigationCache() }
        try await willMaintainLibrary()
        await clients.cancelReadAndWait()
        try Task.checkCancellation()
        return try await operation()
    }

    func backup(to destination: URL, includeULog: Bool) async throws -> LibraryBackupResult {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        return try await performMaintenance {
            statusMessage = "Sauvegarde et vérification…"
            let result = try await LibraryStorageService.backup(library: storageDirectory, destination: destination, includeULog: includeULog, engine: engine)
            statusMessage = "Sauvegarde vérifiée · \(result.logCount) logs · \(result.archivedLogCount) fichiers ULog · \(result.missingSourceCount) sources absentes."
            return result
        }
    }

    func restore(from archive: URL) async throws -> JSONValue {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        var postRestoreIssue: String?
        let result = try await performMaintenance {
            statusMessage = "Restauration vérifiée…"
            FlightWindowCoordinator.shared.closeAll(library: self)
            try await willRestoreLibrary()
            do {
                let result = try await LibraryStorageService.restore(archive: archive, library: storageDirectory, engine: engine)
                annotations.reload(); views.reload()
                indexPrepared = false
                closeFlight()
                do { try await didRestoreLibrary() }
                catch { postRestoreIssue = error.localizedDescription }
                return result
            } catch {
                try? await didRestoreLibrary()
                throw error
            }
        }
        clients.reload(); reload()
        statusMessage = "Bibliothèque restaurée. L’ancien état est conservé dans le dossier de récupération. Les collectes actives sont interrompues."
        if let postRestoreIssue { errorMessage = "La bibliothèque a été restaurée, mais la collecte ne peut pas être rouverte : \(postRestoreIssue). Elle reste bloquée ; relancez l’app ou restaurez sa configuration." }
        return result
    }

    func clearLibrary() async throws { try await resetLibrary(allSettings: false) }
    func resetApplication() async throws { try await resetLibrary(allSettings: true) }

    private func resetLibrary(allSettings: Bool) async throws {
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        guard !diagnosticStore.isExporting, !diagnosticStore.isFetchingGCS, !diagnosticStore.isLoading else {
            throw AnalysisError.engine("Terminez ou arrêtez le diagnostic avant de réinitialiser la bibliothèque.")
        }
        let settings = ["views.json", "annotations.json", "import-options.json"]
        let indices = ["library.json", "progress.json"]
        var cleanupIssues: [String] = []
        try await performMaintenance {
            try Self.validateConfigurationFiles(in: storageDirectory, names: indices + (allSettings ? settings : []))
            if allSettings { try await validateCollectionReset() }
            FlightWindowCoordinator.shared.closeAll(library: self)
            closeFlight()
            let data = try await AnalysisService.run(["reset-library", "--database", databaseURL.path,
                "--library", storageDirectory.path] + (allSettings ? ["--all-settings"] : []), engine: engine)
            struct Result: Decodable { var originalsDeleted: Bool }
            guard try JSONDecoder().decode(Result.self, from: data).originalsDeleted == false else {
                throw AnalysisError.engine("Le moteur n’a pas confirmé la conservation des fichiers originaux.")
            }
            resetGeneration += 1
            if allSettings {
                clients.clearAfterApplicationReset()
                do { try await resetCollectionState() }
                catch { cleanupIssues.append("Collecte : \(error.localizedDescription)") }
                do { try Self.removeConfigurationFiles(in: storageDirectory, names: settings) }
                catch { cleanupIssues.append("Réglages : \(error.localizedDescription)") }
                annotations.reload(); views.reload()
                diagnosticStore.dismiss()
                do { try diagnostics.clear() }
                catch { cleanupIssues.append("Diagnostic : \(error.localizedDescription)") }
            }
            // Clearing indices must never revive a legacy JSON snapshot.
            do { try Self.removeConfigurationFiles(in: storageDirectory, names: indices) }
            catch { cleanupIssues.append("Anciens index : \(error.localizedDescription)") }
            resetNavigationSessions()
            snapshot = .empty; progress = nil
            lastReportExport = nil; indexPrepared = false
        }
        if !allSettings {
            // Keep preferences and selected client, but drop filters tied to deleted logs.
            do { try views.clearLogFiltersAfterReset() }
            catch { cleanupIssues.append("Filtre affiché : \(error.localizedDescription)") }
        }
        clients.reload(); reload()
        statusMessage = allSettings ? "KataLog réinitialisé. Vos fichiers .ulg sont conservés." : "Bibliothèque vidée. Clients, identifications, réglages et fichiers .ulg conservés."
        if !cleanupIssues.isEmpty {
            let message = (statusMessage ?? "") + " Nettoyage incomplet : " + cleanupIssues.joined(separator: " ")
            errorMessage = message
            throw AnalysisError.engine(message)
        }
        errorMessage = nil
    }

    /// Only known regular configuration files can be removed. Never recurse into a directory.
    nonisolated static func removeConfigurationFiles(in directory: URL, names: [String]) throws {
        for name in names {
            try validateConfigurationFiles(in: directory, names: [name])
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    /// Refuse known obstacles before a database mutation; cleanup validates again.
    nonisolated static func validateConfigurationFiles(in directory: URL, names: [String]) throws {
        for name in names {
            guard !name.contains("/"), !name.lowercased().hasSuffix(".ulg") else {
                throw AnalysisError.engine("Nom de configuration inattendu.")
            }
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else {
                throw AnalysisError.engine("Un dossier occupe l’emplacement du réglage \(name). Il a été conservé.")
            }
        }
    }
}
