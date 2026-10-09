import AppKit
import SwiftUI
import KataLogCore

@MainActor
final class EventBrowserStore: ObservableObject {
    struct Query {
        struct Key: Hashable {
            let database: URL
            let engine: URL?
            let request: Data
            let viewRevision: Int
            let libraryRevision: Int
        }
        let request: LibraryQueryRequest
        let database: URL
        let engine: URL?
        let key: Key

        @MainActor init(request: LibraryQueryRequest, database: URL, engine: URL?, viewRevision: Int = 0, libraryRevision: Int = 0) {
            var request = request; request.cursor = nil
            self.request = request; self.database = database; self.engine = engine
            key = Key(database: database, engine: engine, request: LibraryNavigationCache.key(request),
                      viewRevision: viewRevision, libraryRevision: libraryRevision)
        }
        @MainActor init(library: LibraryStore, logID: String?, levelSource: String, level: String, search: String) {
            var scope = logID == nil ? library.views.state.activeScope : SelectionScope()
            if let logID { scope.logIDs = [logID]; scope.includeMasked = true }
            var request = LibraryQueryRequest(kind: "events", scope: scope, annotations: library.annotations.state,
                                              maskedMessageKeys: library.views.state.maskedMessageKeys)
            request.eventLevelSource = levelSource; request.eventLevels = level.isEmpty ? [] : [level]
            request.eventSearch = search
            self.init(request: request, database: library.databaseURL, engine: library.engineURL,
                      viewRevision: library.views.state.revision, libraryRevision: library.historyPage?.revision ?? 0)
        }
    }
    struct Result {
        let key: Query.Key
        let page: LibraryEventPage
        let cursors: [String?]
        var pageNumber: Int { cursors.count }
        var previousCursor: String? { cursors.count > 1 ? cursors[cursors.count - 2] : nil }
    }
    typealias Loader = @MainActor @Sendable (LibraryQueryRequest, URL, URL) async throws -> LibraryEventPage
    @Published private(set) var result: Result?
    @Published private(set) var requestedKey: Query.Key?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private(set) var requestedCursor: String?
    private let loader: Loader
    private var task: Task<Void, Never>?
    private var token = UUID()

    init(loader: @escaping Loader = { request, database, engine in
        try await LibraryQueryService.page(LibraryEventPage.self, request: request, database: database, engine: engine, readOnly: true)
    }) { self.loader = loader }

    var page: LibraryEventPage? { result?.key == requestedKey ? result?.page : nil }
    // The view checks its current key during rendering, before SwiftUI starts the next task.
    func result(for key: Query.Key) -> Result? { result?.key == key ? result : nil }

    func load(library: LibraryStore, logID: String?, levelSource: String, level: String, search: String, cursor: String? = nil) {
        load(Query(library: library, logID: logID, levelSource: levelSource, level: level, search: search), cursor: cursor)
    }
    func load(_ query: Query, cursor: String? = nil) {
        cancel(); let captured = token
        requestedKey = query.key; requestedCursor = cursor; error = nil
        guard let engine = query.engine else { error = "Moteur indisponible."; return }
        var cursors = result(for: query.key)?.cursors ?? [nil]
        if cursor == nil { cursors = [nil] }
        else if let index = cursors.firstIndex(of: cursor) { cursors = Array(cursors.prefix(index + 1)) }
        else { cursors.append(cursor) }
        var request = query.request; request.cursor = cursor
        let loader = self.loader
        isLoading = true
        task = Task { [weak self] in
            do {
                let value = try await loader(request, query.database, engine)
                try Task.checkCancellation()
                guard let self, token == captured else { return }
                result = Result(key: query.key, page: value, cursors: cursors)
                isLoading = false; task = nil
            } catch {
                guard let self, token == captured else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                isLoading = false; task = nil
            }
        }
    }
    func cancel() { task?.cancel(); task = nil; token = UUID(); isLoading = false }
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
    @State private var selected: LibraryEventOccurrence?
    @State private var presentation = "table"
    @State private var showingCoverage = false
    @State private var dictionaryMessage: String?
    @State private var dictionaryBusy = false
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
    private var query: EventBrowserStore.Query {
        EventBrowserStore.Query(library: library, logID: logID, levelSource: levelSource, level: level, search: search)
    }

    var body: some View {
        let query = self.query
        let filterKey = query.key
        let visibleResult = store.result(for: filterKey)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Événements disponibles").font(.system(size: 16, weight: .semibold))
                        Text("Données binaires en cache · niveau interne par défaut").font(.caption).foregroundStyle(palette.secondary)
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
                HStack(spacing: 8) {
                    presentationButton("Chronologie", value: "chronology", symbol: "clock")
                    presentationButton("Tableau", value: "table", symbol: "list.bullet.rectangle")
                    Spacer()
                }
                if let coverage = visibleResult?.page.coverage {
                    DisclosureGroup("Couverture du décodage · \(coverage.cachedLogs) / \(coverage.selectedLogs) fiches en cache", isExpanded: $showingCoverage) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(coverage.cachedLogs) / \(coverage.selectedLogs) logs avec fiche en cache · \(coverage.eventLogs) avec événements · \(coverage.translatedLogs) avec traduction").font(.callout)
                        if coverage.unavailableLogs + coverage.legacyCacheLogs + coverage.invalidCacheLogs > 0 {
                            Text("\(coverage.unavailableLogs) fiches non chargées · \(coverage.legacyCacheLogs) anciens caches sans extraction · \(coverage.invalidCacheLogs) caches invalides. Ouvrez les fiches concernées pour extraire les événements si leur source est accessible.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if coverage.previousParserLogs > 0 { Text("\(coverage.previousParserLogs) fiches proviennent d’un ancien parseur ; les données restent accessibles.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 12)).padding(14)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                if let message = dictionaryMessage { Text(message).font(.callout).textSelection(.enabled) }
                if store.requestedKey == filterKey, let error = store.error {
                    VStack(alignment: .leading) { Text(error).textSelection(.enabled); Button("Réessayer") { reload(cursor: store.requestedCursor) } }
                }
                if store.isLoading { ProgressView("Lecture des événements…") }
                if let result = visibleResult {
                    let page = result.page
                    HStack {
                        Text("\(page.total) occurrences disponibles · page \(result.pageNumber)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Précédente") { reload(cursor: result.previousCursor) }.disabled(result.pageNumber <= 1 || store.isLoading)
                        Button("Suivante") { if let next = page.nextCursor { reload(cursor: next) } }.disabled(page.nextCursor == nil || store.isLoading)
                    }
                    if page.occurrences.isEmpty, !store.isLoading {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Aucun événement dans les données disponibles", systemImage: "list.bullet").font(.system(size: 13, weight: .medium))
                            Text("Les fiches non analysées ou sans source ne permettent pas de conclure à une absence d’événements.")
                                .font(.caption).foregroundStyle(palette.secondary)
                        }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if presentation == "table" {
                        HStack(spacing: 16) {
                            Text("Temps / appareil").frame(width: 150, alignment: .leading)
                            Text("Événement").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Niveau").frame(width: 100, alignment: .leading)
                        }.font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.vertical, 10)
                        Rectangle().fill(palette.border).frame(height: 1)
                    }
                    LazyVStack(alignment: .leading, spacing: presentation == "table" ? 0 : 16) {
                        ForEach(page.occurrences) { occurrence in
                            Button { selected = occurrence } label: {
                                if presentation == "table" { tableRow(occurrence) }
                                else { chronologyRow(occurrence) }
                            }.buttonStyle(.plain).accessibilityLabel("Événement \(occurrence.event.eventID.description), \(eventLevel(occurrence.event)), \(occurrence.droneName)")
                            if presentation == "table" { Rectangle().fill(palette.border).frame(height: 1) }
                        }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(palette.border, lineWidth: 1))
        }
        .foregroundStyle(palette.primary).buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .task(id: filterKey) { selected = nil; store.load(query) }
        .onDisappear { store.cancel() }
        .sheet(item: $selected) { occurrence in
            EventDetailSheet(occurrence: occurrence)
        }
    }
    private var levelFilters: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Niveau interne") { levelSource = "internal" }
                Button("Niveau externe") { levelSource = "external" }
            } label: { Label(levelSource == "internal" ? "Niveau interne" : "Niveau externe", systemImage: "slider.horizontal.3") }
            Picker("Sévérité", selection: $level) {
                Text("Tous les niveaux").tag("")
                ForEach(["EMERGENCY", "ALERT", "CRITICAL", "ERROR", "WARNING", "NOTICE", "INFO", "DEBUG"] + (8...15).map { "RAW_\($0)" } + ["UNKNOWN"], id: \.self) { Text($0).tag($0) }
            }.frame(width: 220)
        }
    }
    private var searchField: some View {
        TextField("Rechercher un ID ou du texte", text: $search).textFieldStyle(.roundedBorder)
    }
    private func presentationButton(_ title: String, value: String, symbol: String) -> some View {
        Button(title, systemImage: symbol) { presentation = value }
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(presentation == value ? palette.primary : .clear, lineWidth: 1))
            .accessibilityAddTraits(presentation == value ? .isSelected : [])
            .accessibilityIdentifier("events.presentation.\(value)")
    }
    private func tableRow(_ occurrence: LibraryEventOccurrence) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(occurrence.event.timeSeconds.map { "t = \(FlightUIFormat.seconds($0))" } ?? "Temps inconnu").font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text(occurrence.droneName).font(.system(size: 11)).foregroundStyle(palette.secondary)
                Text(occurrence.date.isEmpty ? "Date inconnue" : occurrence.date).font(.system(size: 10)).foregroundStyle(palette.secondary)
            }.frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(occurrence.event.message ?? "Événement brut · ID \(occurrence.event.eventID.description)").font(.system(size: 12, weight: .medium)).lineLimit(3)
                Text("ID \(occurrence.event.eventID.description) · \(EventTranslationLabel.describe(occurrence.event.translationStatus))")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            BentoStatus(label: eventLevel(occurrence.event), color: eventColor(occurrence.event)).frame(width: 100, alignment: .leading)
        }.padding(.vertical, 16).contentShape(Rectangle())
    }
    private func chronologyRow(_ occurrence: LibraryEventOccurrence) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Circle().fill(eventColor(occurrence.event)).frame(width: 7, height: 7).padding(.top, 5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(occurrence.event.timeSeconds.map { "t = \(FlightUIFormat.seconds($0))" } ?? "Temps inconnu").monospacedDigit()
                    Text(occurrence.droneName)
                    Text(occurrence.date.isEmpty ? "Date inconnue" : occurrence.date)
                    Spacer()
                    BentoStatus(label: eventLevel(occurrence.event), color: eventColor(occurrence.event))
                }.font(.system(size: 11)).foregroundStyle(palette.secondary)
                Text(occurrence.event.message ?? "Événement brut · ID \(occurrence.event.eventID.description)").font(.system(size: 13, weight: .medium)).lineLimit(3)
                Text("ID \(occurrence.event.eventID.description) · \(EventTranslationLabel.describe(occurrence.event.translationStatus)) · \(occurrence.event.topic ?? "event") [\(occurrence.event.instance ?? 0)]")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 12).contentShape(Rectangle())
    }
    private func eventColor(_ event: PX4Event) -> Color {
        switch eventLevel(event) {
        case "EMERGENCY", "ALERT", "CRITICAL", "ERROR": palette.red
        case "WARNING": palette.amber
        default: palette.secondary
        }
    }
    private func eventLevel(_ event: PX4Event) -> String {
        (levelSource == "external" ? event.externalLevelName : event.internalLevelName) ?? event.level
    }
    private func reload(cursor: String? = nil) {
        store.load(query, cursor: cursor)
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
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
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
            .foregroundStyle(palette.primary).background(palette.background)
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
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
