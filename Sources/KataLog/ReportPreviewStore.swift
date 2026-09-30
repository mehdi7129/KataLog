import Combine
import Foundation
import KataLogCore

struct ReportPreview: Sendable {
    let request: ReportExportRequest
    let revision: Int
    let totals: LibraryTotals
    let checkedAt: Date
}

/// This preview reads one log page for its SQL totals. It never parses sources,
/// captures the library, or infers detail coverage from a subset of cached logs.
@MainActor
final class ReportPreviewStore: ObservableObject {
    typealias Loader = @MainActor @Sendable (LibraryQueryRequest, URL, URL) async throws -> LibraryLogPage
    @Published private(set) var preview: ReportPreview?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let loader: Loader
    private var task: Task<Void, Never>?
    private var token = UUID()

    init(loader: @escaping Loader = { request, database, engine in
        try await LibraryQueryService.page(LibraryLogPage.self, request: request, database: database, engine: engine, readOnly: true)
    }) { self.loader = loader }

    static func request(mode: ReportScopeManifest.Mode, scope: SelectionScope, annotations: DroneAnnotationState,
                        maskedMessageKeys: [String], viewRevision: Int, options: ReportExportOptions) -> ReportExportRequest {
        var selected = mode == .full ? SelectionScope() : scope
        if mode == .full { selected.includeMasked = true }
        var query = LibraryQueryRequest(scope: selected, annotations: annotations, maskedMessageKeys: maskedMessageKeys)
        query.limit = 1
        return ReportExportRequest(query: query, mode: mode,
            scopeDescription: mode == .full ? "Toute la bibliothèque · messages masqués inclus" : selected.description,
            viewRevision: viewRevision, options: options)
    }

    func load(library: LibraryStore, mode: ReportScopeManifest.Mode, options: ReportExportOptions) {
        let request = Self.request(mode: mode, scope: library.views.state.activeScope, annotations: library.annotations.state,
                                   maskedMessageKeys: library.views.state.maskedMessageKeys,
                                   viewRevision: library.views.state.revision, options: options)
        guard let engine = library.engineURL else {
            cancel(); error = "Le moteur d’analyse est absent. Réinstallez KataLog pour prévisualiser le rapport."; return
        }
        load(request: request, database: library.databaseURL, engine: engine)
    }

    func load(request: ReportExportRequest, database: URL, engine: URL) {
        task?.cancel(); let expected = UUID(); token = expected
        preview = nil; error = nil; isLoading = true
        let loader = self.loader
        task = Task { [weak self] in
            do {
                let page = try await loader(request.query, database, engine)
                try Task.checkCancellation()
                guard let self, token == expected else { return }
                guard page.queryVersion == 1 else { throw AnalysisError.schema(page.queryVersion) }
                guard page.totals.logs >= 0, page.totals.messages >= 0, page.totals.droneCount >= 0 else {
                    throw AnalysisError.engine("Les comptes de la prévisualisation sont invalides.")
                }
                preview = ReportPreview(request: request, revision: page.revision, totals: page.totals, checkedAt: Date())
                isLoading = false; task = nil
            } catch {
                guard let self, token == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription; isLoading = false; task = nil
            }
        }
    }

    func cancel() {
        token = UUID(); task?.cancel(); task = nil; isLoading = false; preview = nil
    }
}
