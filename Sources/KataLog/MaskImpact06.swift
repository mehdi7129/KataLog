import Combine
import Foundation
import SwiftUI
import KataLogCore

struct MaskImpact: Sendable {
    let messages: Int
    let revision: Int
    let viewRevision: Int
    let annotations: DroneAnnotationState
    let classKeys: [String]
}

struct MaskClassKeysPage: Decodable, Sendable, LibraryPageContract {
    var queryVersion: Int
    var revision: Int
    var total: Int
    var classKeys: [String]
    var nextCursor: String?
}

@MainActor
final class MaskImpactStore: ObservableObject {
    typealias Loader = @MainActor @Sendable (LibraryQueryRequest, URL, URL) async throws -> LibraryMessagePage
    typealias KeyLoader = @MainActor @Sendable (LibraryQueryRequest, URL, URL) async throws -> MaskClassKeysPage
    @Published private(set) var impact: MaskImpact?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private let loader: Loader
    private let keyLoader: KeyLoader
    private var task: Task<Void, Never>?
    private var token = UUID()
    init(loader: @escaping Loader = { request, database, engine in
        try await LibraryQueryService.page(LibraryMessagePage.self, request: request, database: database, engine: engine, readOnly: true)
    }, keyLoader: @escaping KeyLoader = { request, database, engine in
        try await LibraryQueryService.page(MaskClassKeysPage.self, request: request, database: database, engine: engine, readOnly: true)
    }) { self.loader = loader; self.keyLoader = keyLoader }
    static func request(groupID: String, annotations: DroneAnnotationState, maskedMessageKeys: [String]) -> LibraryQueryRequest {
        var scope = SelectionScope(); scope.includeMasked = true
        var request = LibraryQueryRequest(kind: "messages", scope: scope, annotations: annotations, maskedMessageKeys: maskedMessageKeys)
        request.groupID = groupID; request.limit = 1
        return request
    }
    static func displayText(_ key: String) -> String {
        guard key.hasPrefix("text-v1:") else { return "Texte du groupe" }
        let payload = key.dropFirst(8)
        guard let separator = payload.firstIndex(of: ":"), let levelSize = Int(payload[..<separator]), levelSize >= 0 else { return "Texte du groupe" }
        let bytes = Array(payload[payload.index(after: separator)...].utf8)
        guard levelSize <= bytes.count else { return "Texte du groupe" }
        let level = String(decoding: bytes.prefix(levelSize), as: UTF8.self)
        let text = String(decoding: bytes.dropFirst(levelSize), as: UTF8.self)
        return level + " · " + text
    }
    func load(group: LibraryGroup, library: LibraryStore) {
        task?.cancel(); let expected = UUID(); token = expected; impact = nil; error = nil; isLoading = false
        guard group.classKeysComplete == true, let keys = group.classKeys, !keys.isEmpty,
              keys.allSatisfy({ $0.hasPrefix("text-v1:") }) else {
            error = "Impact global indisponible : la liste complète des textes de ce groupe n’est pas disponible. Aucun masquage n’a été appliqué."; return
        }
        guard let engine = library.engineURL else { error = "Impact global indisponible : moteur d’analyse absent."; return }
        let request = Self.request(groupID: group.id, annotations: library.annotations.state, maskedMessageKeys: library.views.state.maskedMessageKeys)
        let database = library.databaseURL, viewRevision = library.views.state.revision, loader = self.loader, keyLoader = self.keyLoader
        isLoading = true
        task = Task { [weak self] in
            do {
                let page = try await loader(request, database, engine)
                try Task.checkCancellation()
                var keysRequest = request; keysRequest.kind = "group-keys"; keysRequest.limit = 200
                var currentKeys: [String] = []
                var expectedKeyCount: Int?, seenCursors: Set<String> = [], keyPages = 0
                repeat {
                    let keyPage = try await keyLoader(keysRequest, database, engine)
                    try Task.checkCancellation()
                    keyPages += 1
                    guard keyPage.queryVersion == 1, keyPage.revision == page.revision,
                          keyPage.total <= 512, keyPage.total >= keyPage.classKeys.count, keyPages <= 3,
                          expectedKeyCount == nil || expectedKeyCount == keyPage.total,
                          keyPage.classKeys.allSatisfy({ $0.hasPrefix("text-v1:") }) else {
                        throw AnalysisError.engine("La liste globale des textes a changé ou dépasse le budget de prévisualisation.")
                    }
                    expectedKeyCount = keyPage.total
                    currentKeys += keyPage.classKeys
                    guard currentKeys.count <= 512, currentKeys.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024 else {
                        throw AnalysisError.engine("La liste globale des textes dépasse le budget de prévisualisation.")
                    }
                    if let cursor = keyPage.nextCursor {
                        guard !keyPage.classKeys.isEmpty, seenCursors.insert(cursor).inserted else {
                            throw AnalysisError.engine("La pagination des textes ne progresse pas.")
                        }
                    }
                    keysRequest.cursor = keyPage.nextCursor
                } while keysRequest.cursor != nil
                guard currentKeys.count == expectedKeyCount, Set(currentKeys) == Set(keys), Set(currentKeys).count == currentKeys.count else {
                    throw AnalysisError.engine("Les textes du groupe ont changé. Rouvrez le groupe avant de modifier le masquage.")
                }
                guard let self, token == expected else { return }
                guard page.queryVersion == 1, page.total >= 0 else { throw AnalysisError.engine("Impact global invalide.") }
                impact = MaskImpact(messages: page.total, revision: page.revision, viewRevision: viewRevision,
                                    annotations: request.annotations, classKeys: keys)
                isLoading = false; task = nil
            } catch {
                guard let self, token == expected, !Task.isCancelled else { return }
                self.error = "Impact global indisponible : " + error.localizedDescription; isLoading = false; task = nil
            }
        }
    }
    func cancel() { token = UUID(); task?.cancel(); task = nil; isLoading = false; impact = nil }
    static func validate(_ impact: MaskImpact, library: LibraryStore) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard impact.viewRevision == library.views.state.revision,
              impact.revision == library.historyPage?.revision,
              try encoder.encode(impact.annotations) == encoder.encode(library.annotations.state) else {
            throw AnalysisError.engine("Les données ou les règles ont changé. Actualisez l’aperçu avant de modifier le masquage.")
        }
    }
}

struct MaskImpact06: View {
    let group: LibraryGroup
    let masked: Bool
    @ObservedObject var library: LibraryStore
    let canApply: () -> Bool
    let onApplied: () -> Void
    @StateObject private var store = MaskImpactStore()
    @State private var localError: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(masked ? "Masquer ces textes dans la bibliothèque ?" : "Rétablir ces textes dans la bibliothèque ?").font(.title2.weight(.semibold))
            Text(group.title).font(.headline)
            Text("La règle s’applique à tous les logs, y compris ceux qui ne sont pas dans la sélection active. Les textes originaux restent conservés.").font(.callout).foregroundStyle(.secondary)
            if store.isLoading { ProgressView("Vérification de l’impact global…") }
            else if let impact = store.impact {
                Text("\(impact.messages) \(impact.messages == 1 ? "message concerné" : "messages concernés") · \(impact.classKeys.count) \(impact.classKeys.count == 1 ? "texte distinct" : "textes distincts") · révision \(impact.revision)").font(.headline)
                ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(impact.classKeys, id: \.self) { Text(MaskImpactStore.displayText($0)).font(.caption.monospaced()).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading) }
                Text("Ce compte inclut les textes déjà masqués. Le réglage « Inclure les messages masqués » permet de les consulter et de les rétablir.").font(.caption).foregroundStyle(.secondary)
            }
            if let issue = localError ?? store.error { Label(issue, systemImage: "exclamationmark.triangle").font(.callout); Button("Actualiser l’aperçu") { localError = nil; store.load(group: group, library: library) } }
            Spacer(minLength: 0)
            HStack { Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(masked ? "Masquer ces textes" : "Rétablir ces textes") { apply() }.keyboardShortcut(.defaultAction).disabled(store.isLoading || store.impact == nil || !canApply()) }
        }.padding(26).frame(width: 660, height: 500).background(Color(nsColor: .windowBackgroundColor))
        .task { store.load(group: group, library: library) }.onDisappear { store.cancel() }
    }
    private func apply() {
        guard let impact = store.impact else { return }
        do { try MaskImpactStore.validate(impact, library: library); try library.views.mask(impact.classKeys, masked: masked); onApplied(); dismiss() }
        catch { localError = error.localizedDescription }
    }
}
