import SwiftUI
import KataLogCore

@MainActor
final class AnalysisRevisionsStore: ObservableObject {
    @Published private(set) var page: AnalysisRevisionPage?
    @Published private(set) var detail: FlightLog?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var error: String?
    @Published private(set) var selected: AnalysisRevision?
    private var pageTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var pageToken = UUID(), detailToken = UUID()
    func load(library: LibraryStore, logID: String, offset: Int = 0) {
        pageTask?.cancel(); detailTask?.cancel(); pageToken = UUID(); detailToken = UUID()
        let token = pageToken
        page = nil; detail = nil; selected = nil; isLoadingDetail = false; error = nil
        guard let engine = library.engineURL else { error = "Moteur indisponible."; return }
        let database = library.databaseURL
        isLoading = true
        pageTask = Task {
            defer { if pageToken == token { isLoading = false } }
            do {
                let result = try await AnalysisRevisionService.page(logID: logID, offset: offset, database: database, engine: engine)
                try Task.checkCancellation(); guard pageToken == token else { return }
                page = result
            } catch is CancellationError {} catch { if pageToken == token { self.error = error.localizedDescription } }
        }
    }
    func select(_ revision: AnalysisRevision, library: LibraryStore, logID: String) {
        detailTask?.cancel(); detailToken = UUID(); let token = detailToken
        selected = revision; detail = nil; error = nil
        guard let engine = library.engineURL else { error = "Moteur indisponible."; return }
        let database = library.databaseURL
        isLoadingDetail = true
        detailTask = Task {
            defer { if detailToken == token { isLoadingDetail = false } }
            do {
                let result = try await AnalysisRevisionService.detail(logID: logID, revisionID: revision.id, database: database, engine: engine)
                try Task.checkCancellation(); guard detailToken == token else { return }
                detail = result
            } catch is CancellationError {} catch { if detailToken == token { self.error = error.localizedDescription } }
        }
    }
    func cancel() { pageTask?.cancel(); detailTask?.cancel(); pageToken = UUID(); detailToken = UUID(); isLoading = false; isLoadingDetail = false }
}

struct AnalysisRevisionsView: View {
    @ObservedObject var library: LibraryStore
    let logID: String
    var currentLog: FlightLog? = nil
    @StateObject private var store = AnalysisRevisionsStore()
    @State private var offset = 0
    @State private var comparisonLimit = 200
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Analyses conservées").font(.system(size: 20, weight: .semibold))
            Text("Lecture seule, sans recalcul et sans fichier source requis. La date indique la capture de l’analyse, pas la date du vol.").font(.caption).foregroundStyle(.secondary)
            if let error = store.error { HStack { Text(error).textSelection(.enabled); Spacer(); Button("Réessayer") { store.load(library: library, logID: logID, offset: offset) } } }
            if store.isLoading { ProgressView("Lecture des révisions…") }
            HStack {
                if let count = store.page?.total { Text("\(count) \(count == 1 ? "révision conservée" : "révisions conservées")").font(.caption) }
                Spacer()
                Button("Précédente") { offset = max(0, offset - 32) }.disabled(offset == 0 || store.isLoading)
                Button("Suivante") { if let next = store.page?.nextOffset { offset = next } }.disabled(store.page?.nextOffset == nil || store.isLoading)
            }
            HStack(alignment: .top, spacing: 18) {
                BentoPanel(palette: palette) { ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.page?.revisions ?? []) { revision in
                            Button { store.select(revision, library: library, logID: logID) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(revision.kind == "detail" ? "Fiche détaillée" : "Résumé").fontWeight(.semibold); Spacer(); if revision.current { Text("Courante").font(.caption) } }
                                    Text("Parseur \(revision.parserVersion)").font(.caption)
                                    Text(revision.createdAt).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(ByteCountFormatter.string(fromByteCount: revision.sizeBytes, countStyle: .file)).font(.caption)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.selected?.id == revision.id ? palette.raised : palette.card, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.selected?.id == revision.id ? palette.primary : palette.border, lineWidth: 1))
                            }.buttonStyle(.plain).accessibilityLabel("\(revision.kind == "detail" ? "Fiche détaillée" : "Résumé"), parseur \(revision.parserVersion), capture \(revision.createdAt)")
                        }
                    }
                } }.frame(width: 280)
                BentoPanel(palette: palette) { ScrollView {
                    if store.isLoadingDetail { ProgressView("Lecture de l’analyse conservée…").frame(maxWidth: .infinity) }
                    else if let log = store.detail, let revision = store.selected {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(log.droneName).font(.headline)
                            Text(revision.kind == "detail" ? "Fiche historique conservée" : "Résumé historique · données détaillées non incluses").font(.callout)
                            Text("Log : \(log.date.isEmpty ? "date inconnue" : log.date) · \(log.fileName)").font(.caption).textSelection(.enabled)
                            Text("Empreinte de l’analyse : \(revision.analysisSHA256)").font(.caption.monospaced()).textSelection(.enabled)
                            if let current = currentLog ?? library.selectedFlight, current.id == logID { comparison(previous: log, current: current) }
                            RecordedMetadataView(log: log)
                            DisclosureGroup("Messages conservés · \(log.messages.count)") {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(log.messages) { message in
                                        Text("\(message.level) · \(String(format: "%.2f", message.timestampSeconds)) s · \(message.text)").font(.caption).textSelection(.enabled)
                                    }
                                }.padding(.top, 8)
                            }
                            DisclosureGroup("Données complètes de cette analyse") { Text(json(log)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else { ContentUnavailableView("Choisir une analyse", systemImage: "clock.arrow.circlepath", description: Text("Les révisions précédentes restent séparées de la fiche courante.")).frame(maxWidth: .infinity) }
                } }.frame(maxWidth: .infinity)
            }.frame(maxHeight: .infinity)
        }.padding(24)
        .foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .task(id: "\(logID)|\(offset)") { store.load(library: library, logID: logID, offset: offset) }
        .onDisappear { store.cancel() }
    }
    private func json(_ log: FlightLog) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(log), encoding: .utf8)) ?? "Données indisponibles."
    }
    private func comparison(previous: FlightLog, current: FlightLog) -> some View {
        let comparison = ParameterComparison.compare(previous: previous, current: current)
        return DisclosureGroup("Comparer à la fiche courante") {
            VStack(alignment: .leading, spacing: 10) {
                Text(comparison.explanation).font(.caption).foregroundStyle(.secondary)
                Text("Firmware conservé : \(comparison.previousFirmware ?? "non enregistré") · fiche courante : \(comparison.currentFirmware ?? "non enregistré")").font(.caption).textSelection(.enabled)
                if comparison.firmwareDiffers { Text("Les métadonnées firmware diffèrent entre ces analyses.").font(.caption.weight(.semibold)) }
                if comparison.comparable {
                Text("\(comparison.differences.count) \(comparison.differences.count == 1 ? "écart de paramètres" : "écarts de paramètres") · \(min(comparisonLimit, comparison.differences.count)) affiché(s)").font(.caption)
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(comparison.differences.prefix(comparisonLimit)) { difference in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(difference.name + " · " + label(difference.change)).font(.caption.weight(.semibold))
                                Text("\(difference.before?.description ?? "non enregistré") [\(difference.beforeType ?? "inconnu")] → \(difference.after?.description ?? "non enregistré") [\(difference.afterType ?? "inconnu")]").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    if comparison.differences.count > comparisonLimit { Button("Afficher 200 écarts supplémentaires") { comparisonLimit += 200 } }
                }
            }.padding(.top, 8)
        }
    }
    private func label(_ change: ParameterDifference.Change) -> String {
        switch change { case .added: "nouvellement enregistré"; case .absent: "absent de la fiche courante"; case .value: "valeur différente"; case .type: "type différent" }
    }
}
