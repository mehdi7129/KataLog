import AppKit
import Foundation
import KataLogCore
import UniformTypeIdentifiers

/// Report capture, rendering and cancellation; public store entry points stay stable.
extension LibraryStore {
    func exportHTML() { export(html: true) }
    func exportJSON() { export(html: false) }

    private func export(html: Bool) {
        guard commandCapabilities.canBeginReport else { statusMessage = "Un export est déjà en cours."; return }
        guard !snapshot.logs.isEmpty else { errorMessage = "Importez un dossier avant de générer un rapport."; return }
        let panel = NSSavePanel()
        if usesPagedNavigation && html {
            panel.title = "Exporter toute la bibliothèque"
            panel.message = "Le rapport HTML est un dossier avec index.html, les données complètes et un manifeste de vérification."
            panel.nameFieldStringValue = "KataLog-rapport"
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                Task { do { _ = try await exportReport(to: url, mode: .full, options: .init(format: .html)) }
                    catch { errorMessage = "Échec de l’export : \(error.localizedDescription)" } }
            }
            return
        }
        panel.allowedContentTypes = [html ? .html : .json]
        panel.nameFieldStringValue = "KataLog-rapport.\(html ? "html" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await export(to: url, html: html)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError { statusMessage = "Export annulé. Le fichier précédent est conservé." }
            catch { errorMessage = "Échec de l’export : \(error.localizedDescription)" }
        }
    }

    /// A single export captures one immutable annotated revision. The final file
    /// is only replaced after rendering and a final cancellation check.
    func export(to url: URL, html: Bool, selection: FleetSnapshot? = nil) async throws {
        guard !isStartupBlocked else { throw AnalysisError.engine(errorMessage ?? "La restauration de la bibliothèque est en cours.") }
        if usesPagedNavigation && selection == nil {
            _ = try await exportReport(to: url, mode: .full, options: .init(format: html ? .html : .json))
            return
        }
        guard commandCapabilities.canBeginReport else { throw AnalysisError.engine("Un export est déjà en cours.") }
        isExporting = true; errorMessage = nil; statusMessage = "Préparation du rapport…"
        let diagnosticOperation = UUID().uuidString
        diagnostics.record(.exportStarted, correlation: diagnosticOperation)
        var diagnosticCompleted = false
        var diagnosticFailure: DiagnosticEvent.Code = .exportFailed
        defer { diagnostics.record(diagnosticCompleted ? .exportCompleted : .exportFailed, code: diagnosticCompleted ? .none : diagnosticFailure, correlation: diagnosticOperation) }
        defer { isExporting = false; exportTask = nil }
        let captured = selection ?? snapshot
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if html {
                let contents = ReportRenderer.cancellableHTML(captured,
                    manifest: .describing(captured, mode: selection == nil ? .full : .flight), isCancelled: { Task.isCancelled })
                try Task.checkCancellation()
                guard contents.utf8.count <= 10 * 1024 * 1024 else {
                    throw AnalysisError.engine("Ce relevé dépasse 10 Mio en HTML. Exportez le JSON intégral ou utilisez le rapport de bibliothèque avec données jointes.")
                }
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } else {
                let contents = try ReportRenderer.json(captured)
                try Task.checkCancellation()
                try contents.write(to: url, options: .atomic)
            }
        }
        exportTask = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { if error is CancellationError { diagnosticFailure = .cancelled }; throw error }
        diagnosticCompleted = true
        statusMessage = "Rapport exporté : \(url.lastPathComponent)"
    }

    func cancelExport() { statusMessage = "Annulation du rapport…"; exportTask?.cancel() }

    func exportReport(to destination: URL, mode: ReportScopeManifest.Mode, options: ReportExportOptions) async throws -> ReportExportResult {
        var scope = mode == .full ? SelectionScope() : views.state.activeScope
        if mode == .full { scope.includeMasked = true; scope.clientID = views.state.activeScope.clientID }
        let query = LibraryQueryRequest(scope: scope, annotations: annotations.state, maskedMessageKeys: views.state.maskedMessageKeys)
        let request = ReportExportRequest(query: query, mode: mode,
            scopeDescription: clients.scopeLabel(for: scope.clientID) + " · " + (mode == .full ? "Tous les logs · messages masqués inclus" : scope.description),
            viewRevision: views.state.revision, options: options)
        return try await exportReport(to: destination, reviewedRequest: request)
    }

    /// Review fixes the scope, annotations and options. If the source revision
    /// changed meanwhile, no report is published and the user refreshes review.
    func exportReport(to destination: URL, reviewedRequest request: ReportExportRequest,
                      expectedRevision: Int? = nil) async throws -> ReportExportResult {
        guard commandCapabilities.canBeginReport else { throw AnalysisError.engine("Un export est déjà en cours.") }
        guard let engine = engineURL else { throw AnalysisError.unavailable("Moteur d’analyse absent.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard request.viewRevision == views.state.revision,
              try encoder.encode(request.query.annotations) == encoder.encode(annotations.state),
              request.query.maskedMessageKeys == views.state.maskedMessageKeys else {
            throw AnalysisError.engine("Les réglages ont changé depuis la prévisualisation. Actualisez-la avant de générer le rapport.")
        }
        isExporting = true; lastReportExport = nil; errorMessage = nil
        let diagnosticOperation = UUID().uuidString
        diagnostics.record(.exportStarted, correlation: diagnosticOperation)
        var diagnosticCompleted = false
        var diagnosticFailure: DiagnosticEvent.Code = .exportFailed
        defer { diagnostics.record(diagnosticCompleted ? .exportCompleted : .exportFailed, code: diagnosticCompleted ? .none : diagnosticFailure, correlation: diagnosticOperation) }
        reportProgress = nil
        var reportProgressTask: Task<Void, Never>?
        defer { isExporting = false; exportTask = nil; reportProgressTask?.cancel() }
        let captureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let reportProgressURL = captureDirectory.appendingPathComponent("progress.json")
        let task = Task<Void, Error> { [self] in
            self.statusMessage = "Capture d’une révision cohérente…"
            let capture = try await self.performMaintenance(allowOwnedExport: true) {
                try await ReportExportService.capture(database: self.databaseURL, directory: captureDirectory, request: request, engine: engine)
            }
            try Task.checkCancellation()
            if let expectedRevision, capture.manifest.revision != expectedRevision {
                throw AnalysisError.engine("La bibliothèque a changé depuis la prévisualisation. Actualisez-la avant de générer le rapport.")
            }
            self.statusMessage = "Génération du rapport · \(capture.manifest.totalLogs) logs · \(capture.manifest.totalMessages) messages…"
            reportProgressTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let data = try? Data(contentsOf: reportProgressURL), let value = try? JSONDecoder().decode(ImportProgress.self, from: data) { self?.reportProgress = value }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
            let result = try await ReportExportService.export(capture: capture, destination: destination, engine: engine, progress: reportProgressURL)
            if let data = try? Data(contentsOf: reportProgressURL) { self.reportProgress = try? JSONDecoder().decode(ImportProgress.self, from: data) }
            self.lastReportExport = result
        }
        exportTask = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { if error is CancellationError { diagnosticFailure = .cancelled }; throw error }
        guard let result = lastReportExport else { throw AnalysisError.engine("Le rapport n’a pas été publié.") }
        diagnosticCompleted = true
        statusMessage = "Rapport publié · \(result.logCount) logs · \(result.messageCount) messages · révision \(result.revision)."
        return result
    }
}
