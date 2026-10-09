import AppKit
import Foundation
import KataLogCore

/// Exclusive library maintenance, restore and reset sequencing.
extension LibraryStore {
    /// Library-wide changes run under the stable writer lease with imports,
    /// collection persistence and annotation edits quiescent.
    func performMaintenance<T: Sendable>(allowOwnedExport: Bool = false, allowOwnedQuery: Bool = false, _ operation: () async throws -> T) async throws -> T {
        guard commandCapabilities.canMaintain(allowOwnedExport: allowOwnedExport, allowOwnedQuery: allowOwnedQuery) else {
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
        try await performMaintenance {
            FlightWindowCoordinator.shared.closeAll(library: self)
            closeFlight()
            let data = try await AnalysisService.run(["reset-library", "--database", databaseURL.path,
                "--library", storageDirectory.path] + (allSettings ? ["--all-settings"] : []), engine: engine)
            struct Result: Decodable { var originalsDeleted: Bool }
            guard try JSONDecoder().decode(Result.self, from: data).originalsDeleted == false else {
                throw AnalysisError.engine("Le moteur n’a pas confirmé la conservation des fichiers originaux.")
            }
            if allSettings {
                try await resetCollectionState()
                try Self.removeConfigurationFiles(in: storageDirectory,
                    names: ["views.json", "annotations.json", "import-options.json"])
                annotations.reload(); views.reload()
                diagnosticStore.dismiss()
                try diagnostics.clear()
            }
            // Clearing indices must never revive a legacy JSON snapshot.
            try Self.removeConfigurationFiles(in: storageDirectory, names: ["library.json", "progress.json"])
            displayedQueryKeys.removeAll()
            historyResultsCurrent = false; groupResultsCurrent = false; droneResultsCurrent = false; occurrenceResultsCurrent = false
            snapshot = .empty; historyPage = nil; groupPage = nil; dronePage = nil; mapPage = nil
            occurrencePage = nil; catalogue = nil; progress = nil; mapProximity = nil
            currentHistoryCursor = nil; lastReportExport = nil; indexPrepared = false
        }
        if !allSettings {
            // Keep preferences and selected client, but drop filters tied to deleted logs.
            var scope = SelectionScope(); scope.clientID = views.state.activeScope.clientID
            try views.chooseScope(scope)
        }
        clients.reload(); reload()
        statusMessage = allSettings ? "KataLog réinitialisé. Vos fichiers .ulg sont conservés." : "Bibliothèque vidée. Clients, identifications, réglages et fichiers .ulg conservés."
    }

    /// Only known regular configuration files can be removed. Never recurse into a directory.
    nonisolated static func removeConfigurationFiles(in directory: URL, names: [String]) throws {
        for name in names {
            guard !name.contains("/"), !name.lowercased().hasSuffix(".ulg") else {
                throw AnalysisError.engine("Nom de configuration inattendu.")
            }
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else {
                throw AnalysisError.engine("Un dossier occupe l’emplacement d’un réglage. Il a été conservé.")
            }
            try FileManager.default.removeItem(at: file)
        }
    }
}
