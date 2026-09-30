import AppKit
import SwiftUI
import KataLogCore

@MainActor
final class EventBrowserStore: ObservableObject {
    @Published private(set) var page: LibraryEventPage?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var token = UUID()
    func load(library: LibraryStore, logID: String?, levelSource: String, level: String, search: String, cursor: String? = nil) {
        task?.cancel(); token = UUID(); let captured = token
        guard let engine = library.engineURL else { error = "Moteur indisponible."; return }
        var scope = logID == nil ? library.views.state.activeScope : SelectionScope()
        if let logID { scope.logIDs = [logID]; scope.includeMasked = true }
        var request = LibraryQueryRequest(kind: "events", scope: scope, annotations: library.annotations.state, maskedMessageKeys: library.views.state.maskedMessageKeys)
        request.eventLevelSource = levelSource; request.eventLevels = level.isEmpty ? [] : [level]
        request.eventSearch = search; request.cursor = cursor
        let database = library.databaseURL
        isLoading = true; error = nil
        task = Task {
            defer { if token == captured { isLoading = false } }
            do {
                let value = try await LibraryQueryService.page(LibraryEventPage.self, request: request, database: database, engine: engine, readOnly: true)
                try Task.checkCancellation()
                guard token == captured else { return }
                page = value
            } catch is CancellationError {} catch { if token == captured { self.error = error.localizedDescription } }
        }
    }
    func cancel() { task?.cancel(); token = UUID(); isLoading = false }
}

/// Binary events stay separate from text messages. Missing detail caches are
/// reported explicitly, rather than counted as flights with zero events.
struct EventBrowserView: View {
    @ObservedObject var library: LibraryStore
    var logID: String? = nil
    @StateObject private var store = EventBrowserStore()
    @State private var levelSource = "internal"
    @State private var level = ""
    @State private var search = ""
    @State private var cursors: [String?] = [nil]
    @State private var selected: LibraryEventOccurrence?
    @State private var dictionaryMessage: String?
    @State private var dictionaryBusy = false
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
    private var filterKey: String { [levelSource, level, search, logID ?? "", library.views.state.activeScope.description, String(library.views.state.revision), String(library.historyPage?.revision ?? 0)].joined(separator: "|") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Occurrences binaires").font(.system(size: 16, weight: .semibold))
                        Text("Niveau interne par défaut · données en cache").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Associer un dictionnaire…") { chooseDictionary() }
                        .disabled(dictionaryBusy || library.isReadOnly || library.hasActiveWork || library.hasExternalActivity())
                        .help("Fichier all_events.json.xz exact du firmware ; aucun dictionnaire générique n’est substitué.")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { levelFilters; searchField.frame(minWidth: 200) }
                    VStack(alignment: .leading, spacing: 12) { levelFilters; searchField }
                }
                if let coverage = store.page?.coverage {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(coverage.cachedLogs) / \(coverage.selectedLogs) logs avec fiche en cache · \(coverage.eventLogs) avec événements · \(coverage.translatedLogs) avec traduction").font(.callout)
                        if coverage.unavailableLogs + coverage.legacyCacheLogs + coverage.invalidCacheLogs > 0 {
                            Text("\(coverage.unavailableLogs) fiches non chargées · \(coverage.legacyCacheLogs) anciens caches sans extraction · \(coverage.invalidCacheLogs) caches invalides. Ouvrez les fiches concernées pour extraire les événements si leur source est accessible.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if coverage.previousParserLogs > 0 { Text("\(coverage.previousParserLogs) fiches proviennent d’un ancien parseur ; les données restent accessibles.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                if let message = dictionaryMessage { Text(message).font(.callout).textSelection(.enabled) }
                if let error = store.error {
                    VStack(alignment: .leading) { Text(error).textSelection(.enabled); Button("Réessayer") { reload() } }
                }
                if store.isLoading { ProgressView("Lecture des événements…") }
                if let page = store.page {
                    HStack {
                        Text("\(page.total) occurrences disponibles · page \(cursors.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Précédente") { cursors.removeLast(); reload(cursor: cursors.last ?? nil) }.disabled(cursors.count <= 1 || store.isLoading)
                        Button("Suivante") { if let next = page.nextCursor { cursors.append(next); reload(cursor: next) } }.disabled(page.nextCursor == nil || store.isLoading)
                    }
                    if page.occurrences.isEmpty, !store.isLoading {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Aucun événement dans les données disponibles", systemImage: "list.bullet").font(.system(size: 13, weight: .medium))
                            Text("Les fiches non analysées ou sans source ne permettent pas de conclure à une absence d’événements.")
                                .font(.caption).foregroundStyle(palette.secondary)
                        }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(page.occurrences) { occurrence in
                            Button { selected = occurrence } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(occurrence.droneName).fontWeight(.semibold)
                                        Text(occurrence.date.isEmpty ? "Date inconnue" : occurrence.date).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(eventLevel(occurrence.event)).font(.caption.weight(.semibold))
                                        Text(occurrence.event.timeSeconds.map { "t = \(FlightUIFormat.seconds($0))" } ?? "Temps inconnu").font(.caption.monospaced())
                                    }
                                    Text(occurrence.event.message ?? "Événement brut · ID \(occurrence.event.eventID.description)").font(.callout).lineLimit(3)
                                    Text("ID \(occurrence.event.eventID.description) · \(EventTranslationLabel.describe(occurrence.event.translationStatus)) · \(occurrence.event.topic ?? "event") [\(occurrence.event.instance ?? 0)]").font(.caption).foregroundStyle(.secondary)
                                }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityLabel("Événement \(occurrence.event.eventID.description), \(eventLevel(occurrence.event)), \(occurrence.droneName)")
                        }
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.border, lineWidth: 1))
        }
        .task(id: filterKey) { cursors = [nil]; selected = nil; reload() }
        .onDisappear { store.cancel() }
        .sheet(item: $selected) { occurrence in
            EventDetailSheet(occurrence: occurrence)
        }
    }
    private var levelFilters: some View {
        HStack(spacing: 12) {
            Picker("Niveau", selection: $levelSource) {
                Text("Interne").tag("internal"); Text("Externe").tag("external")
            }.pickerStyle(.segmented).frame(width: 200)
            Picker("Sévérité", selection: $level) {
                Text("Tous les niveaux").tag("")
                ForEach(["EMERGENCY", "ALERT", "CRITICAL", "ERROR", "WARNING", "NOTICE", "INFO", "DEBUG"] + (8...15).map { "RAW_\($0)" } + ["UNKNOWN"], id: \.self) { Text($0).tag($0) }
            }.frame(width: 220)
        }
    }
    private var searchField: some View {
        TextField("Rechercher un ID ou du texte", text: $search).textFieldStyle(.roundedBorder)
    }
    private func eventLevel(_ event: PX4Event) -> String {
        (levelSource == "external" ? event.externalLevelName : event.internalLevelName) ?? event.level
    }
    private func reload(cursor: String? = nil) {
        store.load(library: library, logID: logID, levelSource: levelSource, level: level, search: search, cursor: cursor)
    }
    private func chooseDictionary() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Associer le dictionnaire exact PX4"; panel.message = "Choisissez all_events.json.xz fourni avec le firmware. Le SHA-256 doit correspondre à celui du log ; les événements bruts sont toujours conservés."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        dictionaryBusy = true
        Task {
            defer { dictionaryBusy = false }
            do {
                let result = try await library.importEventDictionary(file)
                dictionaryMessage = "Dictionnaire vérifié · \(result.matchingCachedLogs) fiches compatibles. Les autres firmwares conservent leurs événements bruts."
                reload()
            } catch { dictionaryMessage = "Association impossible : \(error.localizedDescription)" }
        }
    }
}

private struct EventDetailSheet: View {
    let occurrence: LibraryEventOccurrence
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Événement \(occurrence.event.eventID.description)").font(.title2.weight(.semibold)); Spacer(); Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(occurrence.event.message ?? "Traduction indisponible").font(.headline)
                    if let description = occurrence.event.description { Text(description) }
                    row("Drone", occurrence.droneName)
                    row("Log SHA-256", occurrence.logID)
                    row("Temps relatif", occurrence.event.timeSeconds.map(FlightUIFormat.seconds) ?? "Inconnu")
                    row("Niveau interne", occurrence.event.internalLevelName ?? "Inconnu")
                    row("Niveau externe", occurrence.event.externalLevelName ?? "Inconnu")
                    row("Traduction", EventTranslationLabel.describe(occurrence.event.translationStatus))
                    row("Dictionnaire", occurrence.event.definitionSource ?? "Aucun artefact associé")
                    row("Topic / instance", "\(occurrence.event.topic ?? "event") / \(occurrence.event.instance ?? 0)")
                    row("Séquence", occurrence.event.sequence.map(String.init) ?? "Inconnue")
                    row("Arguments bruts (hex)", occurrence.event.argumentsHex)
                    if let invalid = occurrence.event.invalidReason { row("Limite de décodage", invalid) }
                    if let values = occurrence.event.argumentValues { row("Arguments décodés", values.map(\.description).joined(separator: " · ")) }
                    Text("Un événement enregistré décrit un état du firmware ; il ne confirme pas seul une panne matérielle.").font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled)
            }
        }.padding(24).frame(width: 620, height: 540)
    }
    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout.monospaced()) }
    }
}

enum EventTranslationLabel {
    static func describe(_ status: String?) -> String {
        switch status {
        case "translated": "Traduit avec le dictionnaire exact"
        case "missing": "Dictionnaire exact manquant · données brutes conservées"
        case "incompatible": "Dictionnaire incompatible · traduction indisponible"
        case "unknown": "ID absent du dictionnaire · données brutes conservées"
        case "invalid": "Arguments ou définition invalides · données brutes conservées"
        default: "État de traduction non renseigné"
        }
    }
}
