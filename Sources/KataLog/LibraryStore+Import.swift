import AppKit
import Foundation
import KataLogCore

/// Import and reanalysis lifecycle; the store remains the state owner.
extension LibraryStore {
    func chooseFolder() {
        guard commandCapabilities.canChooseImportFolder else { return }
        let panel = NSOpenPanel()
        panel.title = "Importer les logs PX4"
        panel.message = "Choisissez une carte SD ou le dossier contenant plusieurs drones. Les fichiers source sont lus sans modification."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyser"
        if panel.runModal() == .OK, let url = panel.url { importFolder(url) }
    }

    func importFolder(_ folder: URL, archiveDestination: URL? = nil, clientID: String? = nil) {
        guard commandCapabilities.canChooseImportFolder else { return }
        let destination = clientID ?? views.state.activeScope.clientID ?? ""
        Task { _ = try? await importCollectedFolder(folder, archiveDestination: archiveDestination, clientID: destination) }
    }

    /// Used by the collection queue; completion means the snapshot has been committed.
    func importCollectedFolder(_ folder: URL, expectedLogID: String? = nil, archiveDestination: URL? = nil, clientID: String? = nil) async throws -> FleetSnapshot {
        guard commandCapabilities.canAdmitCollectedImport else { throw AnalysisError.engine("La bibliothèque est occupée ou en lecture seule.") }
        while commandCapabilities.mustWaitForCollectedImport { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        guard commandCapabilities.canAdmitCollectedImport else { throw AnalysisError.engine("La bibliothèque est occupée ou en lecture seule.") }
        guard let engine = engineURL else {
            let message = "Le moteur ULog est absent du bundle de l’app."
            errorMessage = message; throw AnalysisError.unavailable(message)
        }
        loadToken = UUID(); isLoading = false
        isImporting = true; errorMessage = nil; statusMessage = nil; progress = nil
        let diagnosticOperation = UUID().uuidString
        diagnostics.record(.importStarted, correlation: diagnosticOperation)
        try? FileManager.default.removeItem(at: progressURL)
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let data = try? Data(contentsOf: self.progressURL), let value = try? JSONDecoder().decode(ImportProgress.self, from: data) { self.progress = value }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        let database = databaseURL, output = snapshotURL, progressFile = progressURL
        let task = Task<FleetSnapshot, Error> { [self] in
            defer { self.invalidateNavigationCache(); self.isImporting = false; self.progressTask?.cancel(); self.progressTask = nil; self.importTask = nil }
            do {
                let result: FleetSnapshot
                if self.usesPagedNavigation {
                    let scanned = try await AnalysisService.scanPaged(folder: folder, database: database, output: output, progress: progressFile, engine: engine, archiveDestination: archiveDestination, clientID: clientID)
                    var request = LibraryQueryRequest(annotations: self.annotations.state)
                    request.scope.includeMasked = true
                    if let expectedLogID { request.scope.logIDs = [expectedLogID] }
                    var page = try await LibraryQueryService.page(LibraryLogPage.self, request: request, database: database, engine: engine, readOnly: true).snapshot
                    page.importStats = scanned.importStats; page.archiveResult = scanned.archiveResult; result = page
                } else {
                    result = try await AnalysisService.scan(folder: folder, database: database, output: output, progress: progressFile, engine: engine, archiveDestination: archiveDestination, clientID: clientID)
                }
                self.annotations.reconcileIdentities(in: result.logs)
                let annotated = self.annotations.state.applying(to: result)
                if !self.usesPagedNavigation { self.snapshot = annotated }
                let stats = result.importStats
                self.statusMessage = "\(stats.discovered) fichiers trouvés · \(stats.imported) nouveaux · \(stats.unchanged) inchangés · \(stats.duplicates) copies identiques · \(stats.failed) erreurs."
                if archiveDestination != nil {
                    self.statusMessage = (self.statusMessage ?? "") + " Archives : \(stats.archiveCompleted ?? 0) copies vérifiées (\(stats.archiveReused ?? 0) réutilisées) · \(stats.archiveFailed ?? 0) erreurs · \(stats.archiveSkipped ?? 0) ignorées."
                    if (stats.archiveFailed ?? 0) > 0 {
                        self.errorMessage = "\(stats.archiveFailed ?? 0) copies d’archive ont échoué : ces fichiers n’ont pas été analysés. Les analyses déjà présentes et les originaux sont conservés. Vérifiez l’espace disponible et l’accès au dossier d’archive avant de recommencer."
                    }
                }
                self.diagnostics.record(.importCompleted, code: stats.failed > 0 ? .analysisFailed : .none, correlation: diagnosticOperation, metrics: [.items: Int64(stats.discovered), .completedItems: Int64(stats.imported + stats.unchanged + stats.duplicates)])
                if self.usesPagedNavigation { Task { self.reloadNavigationSessions() } }
                return annotated
            } catch is CancellationError {
                self.diagnostics.record(.importFailed, code: .cancelled, correlation: diagnosticOperation)
                self.statusMessage = "Import annulé. Les logs déjà traités sont conservés ; un nouvel import reprendra la lecture."
                Task { self.reload() }
                throw CancellationError()
            } catch { self.diagnostics.record(.importFailed, code: .analysisFailed, correlation: diagnosticOperation); self.errorMessage = error.localizedDescription; throw error }
        }
        importTask = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }


    func refreshAnalysis() {
        guard commandCapabilities.canRefreshAnalysis,
              analysisRefreshTask == nil, let engine = engineURL else { return }
        isImporting = true; errorMessage = nil; progress = nil
        try? FileManager.default.removeItem(at: progressURL)
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let data = try? Data(contentsOf: progressURL), let value = try? JSONDecoder().decode(ImportProgress.self, from: data) { progress = value }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        analysisRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.analysisRefreshTask = nil; self.isImporting = false; self.progressTask?.cancel(); self.progressTask = nil; self.reload() }
            do {
                let data = try await AnalysisService.run(["refresh-analysis", "--database", self.databaseURL.path,
                    "--progress", self.progressURL.path], engine: engine)
                let result = try JSONDecoder().decode(JSONValue.self, from: data)
                self.statusMessage = "\(result["reanalyzed"]?.countValue ?? 0) analyses actualisées · \(result["unavailable"]?.countValue ?? 0) sources absentes · \(result["failed"]?.countValue ?? 0) erreurs. Les anciennes analyses sans source sont conservées."
            } catch is CancellationError { self.statusMessage = "Actualisation arrêtée. Les analyses déjà traitées sont conservées." }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    func cancelImport() { analysisRefreshTask?.cancel(); importTask?.cancel() }
}
