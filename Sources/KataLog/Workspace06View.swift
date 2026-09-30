import AppKit
import SwiftUI
import KataLogCore

/// Native preview of the proposed 0.6 flows. Activation is explicit; installed
/// copies retain their current workspace until the design has been approved.
struct Workspace06View: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var gcs: GCSStore
    @ObservedObject private var views: LibraryViewStore
    @StateObject private var storage: LibraryStorageStore
    @StateObject private var updates = UpdateStore()
    @StateObject private var reportPreview = ReportPreviewStore()
    @State private var page: Page = .history
    @State private var showingFlight = false
    @State private var showingScope = false
    @State private var identity: DroneIdentityTarget?
    @State private var viewName = ""
    @State private var localError: String?
    @State private var historyCursors: [String?] = [nil]
    @State private var groupCursors: [String?] = [nil]
    @State private var registryCursors: [String?] = [nil]
    @State private var selectedGroup: LibraryGroup?
    @State private var registrySearch = ""
    @State private var reportMode = ReportScopeManifest.Mode.selection
    @State private var reportFormat = ReportExportOptions.Format.html
    @State private var sharedReport = false
    @State private var cachedDetails = false
    @State private var restoreCandidate: URL?
    @State private var restorePreview: JSONValue?
    @State private var maintenanceTask: Task<Void, Never>?
    @State private var diagnosticPreview: String?
    @State private var importSource: URL?
    @State private var importOptions = ImportOptionsState()
    @State private var maskGroup: LibraryGroup?
    @State private var masking = true
    @State private var lastOpenedLogID: String?
    @State private var selectedStorageLogs: Set<String> = []
    @State private var storageOffsets = [0]
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focusedControl: FocusControl?
    private enum FocusControl: Hashable { case importFolder, scope, refresh, historyLog(String), mask(Bool), diagnostic, restore }

    enum Page: String, CaseIterable, Identifiable {
        case history = "Historique", alerts = "Alertes", events = "Événements PX4", map = "Carte", drones = "Drones"
        case collection = "Collecte GCS", storage = "Stockage", reports = "Rapports", settings = "Réglages"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .history: "clock.arrow.circlepath"
            case .alerts: "waveform.path.ecg"
            case .events: "list.bullet.rectangle.portrait"
            case .map: "map"
            case .drones: "airplane"
            case .collection: "tray.and.arrow.down"
            case .storage: "externaldrive"
            case .reports: "doc.text"
            case .settings: "gearshape"
            }
        }
    }
    init(library: LibraryStore, gcs: GCSStore, initialPage: Page = .history) {
        self.library = library; self.gcs = gcs; views = library.views
        _page = State(initialValue: initialPage)
        _storage = StateObject(wrappedValue: LibraryStorageStore(library: library))
    }
    private var totals: LibraryTotals? { library.historyPage?.totals }
    private var background: Color { Color(nsColor: .windowBackgroundColor) }
    private var theme: ColorScheme? {
        switch views.state.theme { case "dark": .dark; case "light": .light; default: nil }
    }
    private var busy: Bool { library.isImporting || library.isMaintainingLibrary || library.isQuerying || library.isLoading || library.isLoadingFlight }
    private var mutationBusy: Bool { busy || gcs.isBusy }
    private var reportOptions: ReportExportOptions {
        .init(format: reportFormat, excludePaths: sharedReport, excludeIdentity: sharedReport,
              excludeCoordinates: sharedReport, includeCachedDetails: cachedDetails)
    }
    private var reportPreviewKey: String {
        let request = ReportPreviewStore.request(mode: reportMode, scope: views.state.activeScope,
            annotations: library.annotations.state, maskedMessageKeys: views.state.maskedMessageKeys,
            viewRevision: views.state.revision, options: reportOptions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ((try? encoder.encode(request))?.base64EncodedString() ?? "") + ":\(library.historyPage?.revision ?? 0)"
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                Label("kataLOG", systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 25, weight: .bold)).tracking(-1).foregroundStyle(sidebarForeground)
                Text("Les traces de votre flotte.").font(.caption).foregroundStyle(sidebarForeground.opacity(0.65))
                if AppPreviewConfiguration().reviewBuild {
                    Text("Preview 0.6 · bibliothèque séparée")
                        .font(.caption2).foregroundStyle(sidebarForeground.opacity(0.75))
                        .help("Cette version utilise sa propre bibliothèque et conserve les données de l’app installée.")
                }
                List { ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        HStack(spacing: 10) { Image(systemName: item.symbol).foregroundStyle(sidebarForeground).frame(width: 20); Text(item.rawValue).foregroundStyle(sidebarForeground) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.buttonStyle(.plain).listRowBackground(page == item ? Color.primary.opacity(0.08) : Color.clear)
                } }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    Label(library.isReadOnly ? "Lecture seule" : "Bibliothèque locale", systemImage: library.isReadOnly ? "lock" : "internaldrive")
                    Text("Vos fichiers restent sur votre Mac.").foregroundStyle(.secondary)
                }.font(.caption).foregroundStyle(sidebarForeground)
            }.padding(18).navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    notices
                    if [.history, .alerts, .events, .map].contains(page) { scopeBar }
                    switch page {
                    case .history: history
                    case .alerts: alertProfile; alerts
                    case .events: EventBrowserView(library: library)
                    case .map: map
                    case .drones: registry
                    case .collection: GCSCollectionView(store: gcs, library: library, dark: scheme == .dark)
                    case .storage: storagePage
                    case .reports: reportPage
                    case .settings: settings
                    }
                    Text("Les alertes décrivent des observations enregistrées. Elles ne prouvent pas à elles seules une panne matérielle.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(26).frame(maxWidth: 1500, alignment: .leading).frame(maxWidth: .infinity)
            }.background(background)
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(theme).tint(.primary)
        .onAppear {
            gcs.attach(library: library)
            updates.installationAllowed = { !library.isImporting && !library.isExporting && !library.isMaintainingLibrary && !gcs.isBusy && !library.isQuerying && !library.isLoadingFlight }
            if !library.usesPagedNavigation { library.enablePagedNavigation() }
        }
        .onChange(of: page) { _, value in selectedGroup = nil; reload(value) }
        .onChange(of: views.state.activeScope) { _, _ in historyCursors = [nil]; groupCursors = [nil]; selectedGroup = nil }
        .onChange(of: views.state.historySort) { _, _ in historyCursors = [nil]; groupCursors = [nil] }
        .onChange(of: library.currentHistoryCursor) { _, cursor in if cursor == nil { historyCursors = [nil] } }
        .onReceive(library.annotations.$state.dropFirst()) { _ in selectedGroup = nil; groupCursors = [nil] }
        .onChange(of: storage.currentOffset) { _, offset in if offset == 0 { storageOffsets = [0] } }
        .onChange(of: storage.errorMessage) { _, issue in
            if issue != nil, let index = storageOffsets.firstIndex(of: storage.currentOffset) { storageOffsets = Array(storageOffsets.prefix(index + 1)) }
        }
        .sheet(isPresented: $showingScope, onDismiss: { library.loadHistory(); focusedControl = .scope }) { ScopeEditor06(library: library) }
        .sheet(isPresented: $showingFlight, onDismiss: { library.closeFlight(); focusedControl = page == .history ? lastOpenedLogID.map(FocusControl.historyLog) : .refresh }) { FlightSheet06(library: library).preferredColorScheme(theme) }
        .sheet(item: $identity) { DroneNumberEditor(target: $0, store: library.annotations) }
        .sheet(isPresented: Binding(get: { restorePreview != nil }, set: { if !$0 { restorePreview = nil; restoreCandidate = nil } }), onDismiss: { focusedControl = .restore }) { restoreSheet }
        .sheet(isPresented: Binding(get: { diagnosticPreview != nil }, set: { if !$0 { diagnosticPreview = nil } }), onDismiss: { focusedControl = .diagnostic }) { diagnosticSheet }
        .sheet(isPresented: Binding(get: { importSource != nil }, set: { if !$0 { importSource = nil } }), onDismiss: { focusedControl = .importFolder }) {
            if let source = importSource { ImportOptions06(source: source, initialState: importOptions, canApply: { !mutationBusy && !library.isReadOnly }) { destination in
                if let destination { importOptions.archiveDirectory = destination.path; try ImportOptionsPersistence.save(importOptions, library: library) }
                library.importFolder(source, archiveDestination: destination)
            } }
        }
        .sheet(isPresented: Binding(get: { maskGroup != nil }, set: { if !$0 { maskGroup = nil } }), onDismiss: { focusedControl = selectedGroup == nil ? .scope : .mask(masking) }) {
            if let group = maskGroup { MaskImpact06(group: group, masked: masking, library: library, canApply: { !mutationBusy && !library.isReadOnly }) { selectedGroup = nil; library.loadHistory() } }
        }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack { heading; Spacer(); headerActions }
            VStack(alignment: .leading, spacing: 14) { heading; headerActions }
        }
    }
    private var sidebarForeground: Color { scheme == .dark ? .white.opacity(0.9) : .black.opacity(0.88) }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(page.rawValue).font(.system(size: 31, weight: .semibold)).tracking(-0.8)
            Text(page == .drones ? "Registre global · les identités sans log restent visibles" : page == .collection ? "Une seule copie, dans le dossier que vous choisissez." : "Retrouver, comprendre et conserver les données enregistrées.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private var headerActions: some View {
        HStack {
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Opération en cours") }
            Button("Actualiser", systemImage: "arrow.clockwise") { reload(page) }.disabled(busy).focused($focusedControl, equals: .refresh)
            Button("Importer", systemImage: "plus") { chooseImport() }.disabled(mutationBusy || library.isReadOnly).focused($focusedControl, equals: .importFolder)
                .keyboardShortcut("o", modifiers: .command)
        }
    }
    @ViewBuilder private var notices: some View {
        if library.isReadOnly { notice("Une autre instance utilise la bibliothèque. Fermez-la puis relancez KataLog pour modifier les données.", symbol: "lock") }
        if let message = library.statusMessage { notice(message, symbol: "info.circle") }
        if library.isImporting {
            panel {
                HStack { Text("Analyse en cours").font(.headline); Spacer(); Button("Arrêter") { library.cancelImport() } }
                if let p = library.progress { ProgressView(value: Double(p.completed), total: Double(max(1, p.total))); Text("\(p.completed) / \(p.total) · \(p.current)").font(.caption) }
                else { ProgressView("Préparation de l’analyse…") }
            }
        }
        if let error = localError ?? library.errorMessage ?? library.queryError ?? views.errorMessage {
            notice(error, symbol: "exclamationmark.triangle")
        }
        if library.needsAnalysisRefresh {
            panel { HStack { Text("Certaines analyses ont été calculées avec un ancien moteur.").font(.callout); Spacer(); Button("Actualiser les analyses") { library.refreshAnalysis() }.disabled(mutationBusy || library.isReadOnly) } }
        }
    }
    private var scopeBar: some View {
        panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("SÉLECTION ACTIVE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(views.state.activeScope.description).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Filtrer", systemImage: "line.3.horizontal.decrease") { showingScope = true }.disabled(busy).focused($focusedControl, equals: .scope).keyboardShortcut("f", modifiers: .command)
                Button("Réinitialiser") { edit { try views.chooseScope(.init()) } }.disabled(busy)
            }
            HStack {
                Menu("Vues enregistrées") {
                    ForEach(views.state.views) { saved in
                        Button(saved.name) { edit { try views.chooseScope(saved.scope) } }
                        Button("Supprimer « \(saved.name) »") { edit { try views.removeView(saved.id) } }.disabled(library.isReadOnly)
                    }
                    if views.state.views.isEmpty { Text("Aucune vue enregistrée") }
                }.disabled(busy)
                TextField("Nom de la vue", text: $viewName).textFieldStyle(.roundedBorder).frame(maxWidth: 220).disabled(library.isReadOnly || busy)
                Button("Enregistrer") { edit { try views.saveView(name: viewName); viewName = "" } }.disabled(viewName.trimmingCharacters(in: .whitespaces).isEmpty || library.isReadOnly || busy)
                Spacer()
                Text("\(views.state.maskedMessageKeys.count) règles de masquage").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 20) {
            metrics
            panel {
                HStack {
                    Text("Enregistrements").font(.headline); Spacer()
                    Picker("Tri", selection: Binding(get: { views.state.historySort ?? "recent" }, set: { value in edit { try views.chooseHistorySort(value) } })) { Text("Récents d’abord").tag("recent"); Text("Anciens d’abord").tag("oldest") }.frame(maxWidth: 190).disabled(busy)
                    Text("\(totals?.logs ?? 0) résultats · \(library.snapshot.logs.count) sur cette page").font(.caption).foregroundStyle(.secondary)
                }
                if library.snapshot.logs.isEmpty { empty(library.isQuerying ? "Chargement de l’historique…" : "Aucun enregistrement dans cette sélection.", action: "Réinitialiser") { edit { try views.chooseScope(.init()) } } }
                LazyVStack(alignment: .leading, spacing: 14) {
                  ForEach(library.snapshot.logs) { log in
                    Button { open(log) } label: {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: log.status == "error" ? "exclamationmark.triangle" : "doc.text").frame(width: 24)
                            VStack(alignment: .leading, spacing: 5) { Text(log.fileName).fontWeight(.medium); Text(log.displayName + " · " + date(log.date)).font(.caption).foregroundStyle(.secondary); Text(String(log.id.prefix(16))).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) { Text("\(log.summaryMessageCount ?? log.messages.count) messages"); Text(log.status == "error" ? "Lecture impossible" : log.status == "partial" ? "Lecture partielle" : FlightUIFormat.duration(log.durationSeconds)).foregroundStyle(.secondary) }.font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain).focused($focusedControl, equals: .historyLog(log.id)).accessibilityLabel("Ouvrir \(log.fileName), \(log.displayName), \(date(log.date))")
                    Divider()
                  }
                }
                pagination(cursors: $historyCursors, next: library.historyPage?.nextCursor) { library.loadHistory(cursor: $0) }
            }
        }
    }
    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 14)], spacing: 14) {
            metric("Enregistrements", value: totals?.logs ?? 0, note: "Copies identiques dédupliquées")
            metric("Contrôleurs", value: totals?.droneCount ?? 0, note: "Identités du périmètre")
            metric("Avec alerte", value: totals?.alertLogs ?? 0, note: "Logs uniques sur \(totals?.validLogs ?? 0) lus")
            metric("Failsafe", value: totals?.failsafeLogs ?? 0, note: views.state.activeScope.hasMessageFilters ? "Non inclus dans ce filtre de messages" : "État enregistré, distinct des textes")
        }
    }
    private var alertProfile: some View {
        let counts = totals?.familyLogCounts ?? [:]
        let axes = views.state.profileAxes ?? Array(counts.keys.sorted().prefix(8))
        let allFamilies = AlertProfile06.families(counts: counts, selectedAxes: axes)
        return panel {
            HStack { Text("Profil des alertes textuelles").font(.headline); Spacer(); Menu("Choisir les axes") {
                ForEach(Array(Set(counts.keys).union(axes)).sorted(), id: \.self) { family in
                    Button((axes.contains(family) ? "✓ " : "") + family) {
                        var selected = axes
                        if let index = selected.firstIndex(of: family) { selected.remove(at: index) }
                        else if selected.count < 8 { selected.append(family) }
                        edit { try views.setProfileAxes(selected) }
                    }
                }
                Button("Axes automatiques") { edit { try views.setProfileAxes(Array(counts.keys.sorted().prefix(8))) } }
                if axes.count > 1 { Menu("Ordre des axes") {
                    ForEach(Array(axes.enumerated()), id: \.element) { index, family in
                        Button("↑ Monter « \(family) »") { moveAxis(family, in: axes, by: -1) }.disabled(index == 0)
                        Button("↓ Descendre « \(family) »") { moveAxis(family, in: axes, by: 1) }.disabled(index == axes.count - 1)
                    }
                } }
            }.disabled(library.isReadOnly || busy) }
            Text("Logs uniques concernés / \(totals?.validLogs ?? 0) logs lus · aucune somme de pannes. Jusqu’à huit axes, conservés même à zéro.").font(.caption).foregroundStyle(.secondary)
            AlertProfileChart06(axes: axes, counts: counts, denominator: totals?.validLogs ?? 0)
                .frame(height: axes.count >= 3 ? 250 : 100).accessibilityHidden(true)
            Text("Toutes les familles · \(allFamilies.count)").font(.subheadline.weight(.semibold))
            Text("Cliquez sur une famille pour filtrer les logs concernés. Ce classement inclut aussi les familles absentes du graphique.").font(.caption).foregroundStyle(.secondary)
            ForEach(allFamilies, id: \.self) { family in
                Button { var scope = views.state.activeScope; scope.families = [family]; edit { try views.chooseScope(scope) } } label: {
                    HStack { Text(family); Spacer(); Text("\(counts[family] ?? 0) / \(totals?.validLogs ?? 0)").monospacedDigit() }
                }.buttonStyle(.plain).accessibilityLabel("Filtrer \(family), \(counts[family] ?? 0) logs sur \(totals?.validLogs ?? 0)")
            }
            if allFamilies.isEmpty { Text("Aucune famille d’alerte disponible pour cette sélection.").foregroundStyle(.secondary) }
        }
    }
    private var alerts: some View {
        panel {
            HStack { Text(selectedGroup == nil ? "Messages regroupés" : "Occurrences du groupe").font(.headline); Spacer(); if selectedGroup != nil { Button("Tous les groupes") { selectedGroup = nil; library.loadHistory() } } }
            if let group = selectedGroup {
                Text(group.title).font(.title3); Text(group.family + " · " + group.level).font(.caption).foregroundStyle(.secondary)
                Text("\(library.occurrencePage?.total ?? group.messageCount) occurrences dans la sélection").font(.caption)
                HStack {
                    Button("Masquer ces textes…") { masking = true; maskGroup = group }
                        .disabled(group.classKeys?.isEmpty != false || group.classKeysComplete != true || library.isReadOnly || mutationBusy).focused($focusedControl, equals: .mask(true))
                    Button("Rétablir ces textes…") { masking = false; maskGroup = group }
                        .disabled(group.classKeys?.isEmpty != false || group.classKeysComplete != true || library.isReadOnly || mutationBusy).focused($focusedControl, equals: .mask(false))
                }
                ForEach(library.occurrencePage?.occurrences ?? []) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.message.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text(occurrenceLabel(item)).font(.caption).foregroundStyle(.secondary)
                            MessageClassificationControl(message: item.message, store: library.annotations, families: Array(totals?.familyLogCounts.keys ?? Dictionary<String, Int>().keys))
                        }; Spacer()
                        Button("Voir dans l’historique") { var scope = SelectionScope(); scope.logIDs = [item.logID]; edit { try views.chooseScope(scope); page = .history } }
                    }; Divider()
                }
                pagination(cursors: $groupCursors, next: library.occurrencePage?.nextCursor) { library.loadOccurrences(groupID: group.id, cursor: $0) }
            } else {
                Text("\(library.groupPage?.total ?? 0) groupes · tous niveaux disponibles. Les masquages restent réversibles.").font(.caption).foregroundStyle(.secondary)
                ForEach(library.groupPage?.groups ?? []) { group in
                    Button { selectedGroup = group; groupCursors = [nil]; library.loadOccurrences(groupID: group.id) } label: {
                        HStack { VStack(alignment: .leading, spacing: 5) { Text(group.title); Text(group.family + " · " + group.level).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(group.messageCount) messages · \(group.logCount) logs").font(.caption).monospacedDigit(); Image(systemName: "chevron.right") }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain); Divider()
                }
                pagination(cursors: $groupCursors, next: library.groupPage?.nextCursor) { library.loadAuxiliary(kind: "groups", cursor: $0) }
            }
        }
    }
    private var map: some View {
        VStack(alignment: .leading, spacing: 14) {
            notice("80 trajectoires récentes au maximum dans cette sélection. Les compteurs et les exports couvrent l’ensemble des résultats. Les positions proviennent des logs, pas du Mac.", symbol: "map")
            ScrollView(.horizontal) { FleetMapView(logs: library.mapPage?.snapshot.logs ?? [], onSelectLog: open).frame(minWidth: 860) }
        }
    }
    private var registry: some View {
        panel {
            HStack { Text("\(library.dronePage?.total ?? 0) identités").font(.headline); Spacer(); TextField("Numéro, nom ou identité", text: $registrySearch).textFieldStyle(.roundedBorder).frame(maxWidth: 320).onSubmit { registryCursors = [nil]; library.loadAuxiliary(kind: "drones", search: registrySearch) }; Button("Rechercher") { registryCursors = [nil]; library.loadAuxiliary(kind: "drones", search: registrySearch) }.disabled(busy) }
            Text("Le registre reste global. Un numéro de stock n’est pas une preuve d’identité et ne fusionne pas les contrôleurs.").font(.caption).foregroundStyle(.secondary)
            ForEach(library.dronePage?.drones ?? []) { drone in
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(drone.displayName).font(.headline)
                        Text(drone.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(drone.logCount == 0 ? "Aucun log enregistré · état non déterminé" : "\(drone.logCount) \(drone.logCount == 1 ? "log" : "logs") · dernier log : \(date(drone.lastDate))").font(.caption).foregroundStyle(.secondary)
                        Text(drone.lastGCSDate.map { "Dernière observation GCS : " + observationDate($0) + " · " + (drone.lastGCSSource == "gcs-telemetry" ? "télémétrie reçue" : "provenance non renseignée") } ?? "Aucune observation GCS datée conservée").font(.caption).foregroundStyle(.secondary)
                        Text(drone.sourceCheckedAt.map { "Sources au contrôle du " + observationDate($0) + " : " + sourceStatus(drone.sourceStatus) } ?? "Disponibilité des sources non vérifiée à une date connue").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Historique") { var scope = SelectionScope(); scope.droneKeys = [drone.id]; edit { try views.chooseScope(scope); page = .history } }.disabled(drone.logCount == 0)
                    Button(drone.stockNumber == nil ? "Identifier" : "Modifier le numéro") { identity = DroneIdentityTarget(key: drone.id, sourceName: drone.name) }.disabled(library.isReadOnly || busy)
                }.padding(.vertical, 9); Divider()
            }
            if library.dronePage?.drones.isEmpty != false { Text(registrySearch.isEmpty ? "Aucune identité enregistrée. Importez des logs ou autorisez les drones de votre GCS." : "Aucun résultat pour cette recherche.").foregroundStyle(.secondary) }
            pagination(cursors: $registryCursors, next: library.dronePage?.nextCursor) { library.loadAuxiliary(kind: "drones", cursor: $0, search: registrySearch) }
        }
    }
    private var storagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let info = storage.info {
                if storage.errorMessage != nil { Text("Dernière vérification conservée · actualisation impossible").font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175))]) {
                    metric("Logs indexés", value: info.logCount, note: "\(info.sourceCount) chemins conservés")
                    metric("Analyses détaillées", value: info.detailCacheCount, note: bytes(info.detailCacheBytes) + " · données logiques")
                    panel { Text("Base de données").font(.caption); Text(bytes(info.databaseBytes)).font(.title); Text("Le cache peut être nettoyé sans supprimer les ULog.").font(.caption).foregroundStyle(.secondary) }
                    panel { Text("Historique des analyses").font(.caption); Text(info.analysisRevisionCount.map { "\($0) \($0 == 1 ? "révision" : "révisions")" } ?? "Compte indisponible").font(.title3); Text(info.analysisRevisionBytes.map { bytes($0) + " compressés · limite 512 Mio" } ?? "Taille non renseignée par ce moteur").font(.caption).foregroundStyle(.secondary); Text("Aucune ancienne analyse n’est supprimée automatiquement.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if storage.isLoading {
                panel { ProgressView("Vérification de la bibliothèque…") }
            } else if let error = storage.errorMessage {
                panel { Label("Le stockage n’a pas pu être vérifié.", systemImage: "exclamationmark.triangle").font(.headline); Text(error).foregroundStyle(.secondary); Button("Réessayer") { storage.load() }.disabled(busy) }
            } else {
                panel { Label("Aucun log enregistré", systemImage: "externaldrive").font(.headline); Text("Importez un dossier ou collectez les logs de vos drones pour consulter les sources et le cache.").foregroundStyle(.secondary) }
            }
            panel {
                Text("Sauvegarder et retrouver").font(.headline)
                Text("Une sauvegarde analyses + réglages conserve les numéros, les familles, les vues et la collecte. La version complète ajoute les ULog accessibles. Aucune source d’origine n’est supprimée.").font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) { HStack { backupButtons }; VStack(alignment: .leading) { backupButtons } }.disabled(mutationBusy || library.isReadOnly || library.isExporting || storage.isWorking)
                if library.isMaintainingLibrary || storage.isWorking { HStack { ProgressView().controlSize(.small); Text(storage.message ?? "Vérification et traitement…"); Spacer(); Button("Arrêter") { maintenanceTask?.cancel(); storage.cancel() } } }
                if let message = storage.message { Text(message).font(.callout) }
                if let error = storage.errorMessage { notice(error, symbol: "exclamationmark.triangle") }
                if let recovery = storage.recoveryURL { Button("Voir le dossier de récupération") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) } }
            }
            panel {
                Text("Sources et cache").font(.headline)
                Text("Les chemins restent dans l’historique même si une carte SD est retirée. Retrouver des sources vérifie leur contenu par SHA256.").font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) { HStack { sourceActions }; VStack(alignment: .leading, spacing: 10) { sourceActions } }.disabled(mutationBusy || library.isReadOnly || storage.isWorking || storage.isLoading)
                Text("\(selectedStorageLogs.count) logs choisis, y compris sur les autres pages. Le nettoyage déplace leur cache détaillé et leurs anciennes révisions dans un dossier de récupération. Le dernier résumé et la dernière analyse détaillée de chaque log restent dans l’historique. Les ULog sont conservés ; aucun gain disque n’est garanti sans compactage.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Choisir cette page") { selectedStorageLogs.formUnion((storage.info?.sources ?? []).map(\.logID)) }
                    Button("Tout désélectionner") { selectedStorageLogs = [] }
                }.disabled(storage.isWorking || storage.isLoading || busy)
                if storage.isLoading, storage.info != nil { ProgressView("Chargement des sources…").controlSize(.small) }
                ForEach(storage.info?.sources ?? []) { source in
                    HStack {
                        Toggle("Choisir", isOn: Binding(get: { selectedStorageLogs.contains(source.logID) }, set: { if $0 { selectedStorageLogs.insert(source.logID) } else { selectedStorageLogs.remove(source.logID) } })).labelsHidden().accessibilityLabel("Choisir " + URL(fileURLWithPath: source.path).lastPathComponent)
                        VStack(alignment: .leading, spacing: 4) { Text(URL(fileURLWithPath: source.path).lastPathComponent); Text(source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }; Spacer(); Text(source.availability.label).font(.caption)
                    }.padding(.vertical, 6); Divider()
                }
                if let info = storage.info {
                    if info.sources.isEmpty { Text("Aucun chemin source enregistré.").foregroundStyle(.secondary) }
                    HStack {
                        Button("Précédent") { guard storageOffsets.count > 1 else { return }; storageOffsets.removeLast(); storage.load(offset: storageOffsets.last ?? 0) }.disabled(storageOffsets.count <= 1 || storage.isLoading || storage.isWorking || busy)
                        Text(info.sources.isEmpty ? "0 / \(info.sourceCount) sources" : "\(storage.currentOffset + 1)–\(storage.currentOffset + info.sources.count) / \(info.sourceCount) sources").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Suivant") { guard let next = info.nextOffset else { return }; storageOffsets.append(next); storage.load(offset: next) }.disabled(info.nextOffset == nil || storage.isLoading || storage.isWorking || busy)
                    }
                }
                ForEach(storage.info?.recoveries ?? []) { recovery in
                    HStack { Text(recovery.name).font(.caption); Spacer(); Text(bytes(recovery.sizeBytes)).font(.caption); if recovery.name.hasPrefix("recovery-cache-") { Button("Restaurer le cache") { storage.perform(command: "restore-cache", recovery: library.storageDirectory.appendingPathComponent(recovery.name)) }.disabled(mutationBusy || library.isReadOnly || storage.isWorking) } }
                }
            }
        }.onAppear { storage.load() }
    }
    @ViewBuilder private var sourceActions: some View {
        Button("Retrouver un dossier…") { if let folder = selectFolder("Retrouver les sources") { storage.perform(command: "reassociate", folder: folder) } }
        Button("Archiver les logs choisis…") { if let folder = selectFolder("Copier les ULog sélectionnés") { storage.perform(command: "archive", logIDs: selectedStorageLogs.sorted(), destination: folder) } }.disabled(selectedStorageLogs.isEmpty)
        Button("Nettoyer cache et anciennes analyses") { storage.perform(command: "clean-cache", logIDs: selectedStorageLogs.sorted()) }.disabled(selectedStorageLogs.isEmpty)
    }
    @ViewBuilder private var backupButtons: some View {
        Button("Analyses + réglages…") { backup(includeULog: false) }
        Button("Sauvegarde complète…") { backup(includeULog: true) }
        Button("Restaurer…") { previewRestore() }.focused($focusedControl, equals: .restore)
    }
    private var reportPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            panel {
                Text("Un rapport à votre mesure").font(.headline)
                Picker("Périmètre", selection: $reportMode) { Text("Sélection active").tag(ReportScopeManifest.Mode.selection); Text("Bibliothèque complète").tag(ReportScopeManifest.Mode.full) }.pickerStyle(.segmented)
                if reportPreview.isLoading { ProgressView("Prévisualisation des comptes…").controlSize(.small) }
                else if let preview = reportPreview.preview {
                    Text(preview.request.scopeDescription).font(.callout).foregroundStyle(.secondary)
                    Text("\(preview.totals.logs) logs · \(preview.totals.messages) messages · \(preview.totals.droneCount) contrôleurs").font(.headline)
                    Text("Révision \(preview.revision) · vérifiée à \(preview.checkedAt.formatted(date: .omitted, time: .shortened)) · \(preview.request.query.maskedMessageKeys.count) règles de masquage").font(.caption).foregroundStyle(.secondary)
                    if preview.totals.logs == 0 { Text("Cette sélection ne contient aucun log. Choisissez une autre sélection ou la bibliothèque complète.").font(.callout).foregroundStyle(.secondary) }
                } else if let issue = reportPreview.error {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    Button("Réessayer la prévisualisation") { refreshReportPreview() }.disabled(busy)
                }
                Picker("Format", selection: $reportFormat) { Text("HTML interactif + données JSON").tag(ReportExportOptions.Format.html); Text("Données JSON").tag(ReportExportOptions.Format.json) }
                Toggle("Ajouter les détails déjà calculés", isOn: $cachedDetails)
                Text(cachedDetails ? "Les fiches déjà calculées seront ajoutées sans réanalyse. La couverture des paramètres, événements et séries sera vérifiée lors de la capture ; elle n’est pas encore connue ici." : "Le rapport inclut les résumés et les messages sélectionnés. Les fiches détaillées, paramètres, événements et séries ne sont pas ajoutés.").font(.caption).foregroundStyle(.secondary)
                Toggle("Synthèse anonymisée pour le partage", isOn: $sharedReport)
                Text(sharedReport ? "Retire identités, chemins, coordonnées, textes libres et métadonnées brutes de toutes les pièces. Les comptes sont conservés." : "Rapport interne : contient les identités, chemins et positions disponibles. Vérifiez le destinataire avant de le partager.").font(.caption).foregroundStyle(.secondary)
                Text("Si le HTML dépasse 10 Mio, une synthèse et les données intégrales sont fournies dans le même dossier, avec un manifeste de vérification. Les messages ne sont jamais tronqués silencieusement.").font(.caption).foregroundStyle(.secondary)
                Text("Taille finale inconnue avant génération. Ce rapport conserve les données analysées choisies ; les fichiers ULog originaux ne sont pas copiés.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Générer le rapport…", systemImage: "doc.badge.plus") { exportReport() }.disabled(library.isExporting || mutationBusy || library.isReadOnly || reportPreview.isLoading || (reportPreview.preview?.totals.logs ?? 0) == 0); if library.isExporting { Button("Arrêter") { library.cancelExport() } }; Spacer() }
            }
            if library.isExporting {
                panel {
                    if let progress = library.reportProgress { ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))); Text("\(progress.completed) / \(progress.total) · \(progress.current)").font(.callout) }
                    else { ProgressView("Capture de la bibliothèque…") }
                }
            }
            if let report = library.lastReportExport {
                panel { Label("Rapport prêt", systemImage: "checkmark.circle").font(.headline); Text("\(report.logCount) logs · \(report.messageCount) messages · révision \(report.revision)"); HStack { Button("Ouvrir le rapport") { NSWorkspace.shared.open(report.entryPoint) }; Button("Voir les fichiers") { NSWorkspace.shared.activateFileViewerSelecting([report.destination]) } } }
            }
        }.task(id: reportPreviewKey) { refreshReportPreview() }.onDisappear { reportPreview.cancel() }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            panel {
                Text("Apparence").font(.headline)
                Picker("Thème", selection: Binding(get: { views.state.theme ?? "system" }, set: { value in edit { try views.setTheme(value) } })) { Text("Système").tag("system"); Text("Clair").tag("light"); Text("Sombre").tag("dark") }.pickerStyle(.segmented).disabled(library.isReadOnly)
            }
            UpdateSettingsView(store: updates, readOnly: library.isReadOnly)
            panel { Text("Diagnostic local").font(.headline); Text("Versions, système et états de l’app uniquement. Aucun log, texte d’erreur libre, chemin, identité, endpoint GCS ou coordonnée n’est inclus.").font(.callout).foregroundStyle(.secondary); Text("Les comptes de logs, messages et contrôleurs qualifient la sélection active. Les jobs, masquages et vues qualifient l’app ; chaque compte indique son périmètre dans le JSON.").font(.caption).foregroundStyle(.secondary); Button("Prévisualiser le diagnostic") { makeDiagnostic() }.focused($focusedControl, equals: .diagnostic) }
        }
    }
    private var diagnosticSheet: some View {
        VStack(alignment: .leading, spacing: 16) { Text("Diagnostic sans données privées").font(.title2); ScrollView { Text(diagnosticPreview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }; HStack { Button("Fermer") { diagnosticPreview = nil }.keyboardShortcut(.cancelAction); Spacer(); Button("Exporter…") { let panel = NSSavePanel(); panel.nameFieldStringValue = "KataLog-diagnostic.json"; if panel.runModal() == .OK, let url = panel.url { edit { try (diagnosticPreview ?? "").write(to: url, atomically: true, encoding: .utf8) } } } } }.padding(26).frame(width: 640, height: 580)
    }
    private var restoreSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Restaurer cette sauvegarde ?").font(.title2)
            Text("L’archive a été vérifiée. L’état actuel sera conservé dans un dossier de récupération. Les jobs de collecte actifs restaurés seront interrompus ; aucune collecte ne redémarrera automatiquement.").font(.callout).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 12) { Text("\(restorePreview?["logCount"]?.countValue ?? 0) logs · \(restorePreview?["fileCount"]?.countValue ?? 0) fichiers").font(.headline); Text("\(restorePreview?["missingSourceCount"]?.countValue ?? 0) sources absentes de la sauvegarde"); Text("Taille décompressée : " + bytes(Int64(restorePreview?["uncompressedBytes"]?.countValue ?? 0))); Text("Date : " + (restorePreview?["createdAt"]?.stringValue ?? "inconnue")) }.frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Button("Annuler") { restorePreview = nil; restoreCandidate = nil }.keyboardShortcut(.cancelAction); Spacer(); Button("Restaurer") { guard let candidate = restoreCandidate else { return }; restorePreview = nil; maintenanceTask = Task { do { _ = try await library.restore(from: candidate); storage.load() } catch { localError = error.localizedDescription }; maintenanceTask = nil } }.disabled(mutationBusy || library.isReadOnly).keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 620, height: 500)
    }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.09), lineWidth: 1))
    }
    private func notice(_ text: String, symbol: String) -> some View { Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func metric(_ title: String, value: Int, note: String) -> some View { panel { Text(title).font(.caption).foregroundStyle(.secondary); Text(value.formatted()).font(.system(size: 30, weight: .semibold)).monospacedDigit(); Text(note).font(.caption).foregroundStyle(.secondary) } }
    private func empty(_ title: String, action: String, perform: @escaping () -> Void) -> some View { VStack(alignment: .leading, spacing: 12) { Text(title).foregroundStyle(.secondary); Button(action, action: perform).disabled(busy) }.padding(.vertical, 25) }
    private func pagination(cursors: Binding<[String?]>, next: String?, action: @escaping (String?) -> Void) -> some View {
        HStack { Button("Précédent") { var stack = cursors.wrappedValue; guard stack.count > 1 else { return }; stack.removeLast(); cursors.wrappedValue = stack; action(stack.last ?? nil) }.disabled(cursors.wrappedValue.count <= 1 || busy); Text("Page \(cursors.wrappedValue.count)").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Suivant") { guard let next else { return }; cursors.wrappedValue.append(next); action(next) }.disabled(next == nil || busy) }
    }
    private func edit(_ operation: () throws -> Void) { do { try operation(); localError = nil } catch { localError = error.localizedDescription } }
    private func open(_ log: FlightLog) { lastOpenedLogID = log.id; library.loadFlight(log); showingFlight = true }
    private func chooseImport() {
        do { importOptions = try ImportOptionsPersistence.load(directory: library.storageDirectory) }
        catch { localError = "Les réglages d’import sont illisibles et sont conservés : " + error.localizedDescription; return }
        if let source = selectFolder("Choisir le dossier de logs à importer") { importSource = source }
    }
    private func moveAxis(_ family: String, in axes: [String], by offset: Int) {
        edit { try views.setProfileAxes(AlertProfile06.moving(family, in: axes, by: offset)); library.statusMessage = "Ordre des axes enregistré. Les valeurs et les familles restent inchangées." }
    }
    private func reload(_ value: Page) { switch value { case .drones: library.loadAuxiliary(kind: "drones", search: registrySearch); case .map: library.loadAuxiliary(kind: "map"); case .storage: storage.load(); case .collection: break; default: library.loadHistory() } }
    private func date(_ value: String) -> String { SelectionScope.calendarDay(value) ?? "Date inconnue" }
    private func observationDate(_ value: String) -> String {
        RegistryObservationFormat.date(value).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? value
    }
    private func sourceStatus(_ value: String) -> String {
        RegistryObservationFormat.sourceDescription(value)
    }
    private func occurrenceLabel(_ item: LibraryOccurrence) -> String {
        "\(item.droneName) · \(date(item.date)) · \(FlightUIFormat.seconds(item.message.timestampSeconds))"
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func selectFolder(_ title: String) -> URL? { let p = NSOpenPanel(); p.title = title; p.canChooseDirectories = true; p.canChooseFiles = false; return p.runModal() == .OK ? p.url : nil }
    private func backup(includeULog: Bool) { let p = NSSavePanel(); p.nameFieldStringValue = includeULog ? "KataLog-complet.zip" : "KataLog-analyses.zip"; guard p.runModal() == .OK, let url = p.url else { return }; maintenanceTask = Task { do { _ = try await library.backup(to: url, includeULog: includeULog) } catch { localError = error.localizedDescription }; maintenanceTask = nil } }
    private func previewRestore() { guard let engine = library.engineURL else { return }; let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; guard p.runModal() == .OK, let url = p.url else { return }; maintenanceTask = Task { do { let result = try await LibraryStorageService.inspect(archive: url, engine: engine); restoreCandidate = url; restorePreview = result } catch { localError = error.localizedDescription }; maintenanceTask = nil } }
    private func exportReport() {
        guard let preview = reportPreview.preview, preview.totals.logs > 0, !reportPreview.isLoading else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = preview.request.options.format == .html ? "KataLog-rapport" : "KataLog-rapport.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { do { _ = try await library.exportReport(to: url, reviewedRequest: preview.request, expectedRevision: preview.revision) } catch is CancellationError { localError = nil; library.statusMessage = "Export arrêté. Aucun rapport partiel n’a été publié." } catch { localError = error.localizedDescription; refreshReportPreview() } }
    }
    private func refreshReportPreview() { reportPreview.load(library: library, mode: reportMode, options: reportOptions) }
    private func makeDiagnostic() {
        var counts = ["jobs": gcs.queue.count, "masks": views.state.maskedMessageKeys.count, "savedViews": views.state.views.count]
        var scopes: [String: DiagnosticReport.CountScope] = ["jobs": .application, "masks": .application, "savedViews": .application]
        if let totals { counts["logs"] = totals.logs; counts["messages"] = totals.messages; counts["identities"] = totals.droneCount; scopes["logs"] = .activeSelection; scopes["messages"] = .activeSelection; scopes["identities"] = .activeSelection }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine")
        let report = DiagnosticReport(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development", operations: ["import": library.isImporting, "collection": gcs.isBusy, "export": library.isExporting, "maintenance": library.isMaintainingLibrary, "readOnly": library.isReadOnly, "gcsConnected": gcs.isConnected], counts: counts, countScope: scopes, runtimeBundled: FileManager.default.isExecutableFile(atPath: helper.path))
        edit { diagnosticPreview = String(data: try report.data(), encoding: .utf8) }
    }
}

enum RegistryObservationFormat {
    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func sourceDescription(_ value: String) -> String {
        switch value {
        case "present", "present-at-check", "available", "available-at-check": "accessibles"
        case "missing", "missing-at-check": "absentes"
        case "modified", "modified-at-check", "changed", "changed-at-check": "contenu modifié"
        case "inaccessible", "inaccessible-at-check", "unreadable", "unreadable-at-check": "illisibles"
        case "mixed": "états différents selon les fichiers"
        case "none": "aucun chemin source"
        default: "état indéterminé"
        }
    }
}

enum AlertProfile06 {
    enum ChartKind: Equatable { case empty, bars, radar }
    static func chartKind(axisCount: Int) -> ChartKind { axisCount == 0 ? .empty : axisCount < 3 ? .bars : .radar }
    static func moving(_ family: String, in axes: [String], by offset: Int) -> [String] {
        guard let index = axes.firstIndex(of: family), axes.indices.contains(index + offset) else { return axes }
        var result = axes; result.swapAt(index, index + offset); return result
    }
    static func families(counts: [String: Int], selectedAxes: [String]) -> [String] {
        Array(Set(counts.keys).union(selectedAxes)).sorted {
            let lhs = counts[$0] ?? 0, rhs = counts[$1] ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
    }
}

struct AlertProfileChart06: View {
    let axes: [String]; let counts: [String: Int]; let denominator: Int
    var body: some View {
        switch AlertProfile06.chartKind(axisCount: axes.count) {
        case .empty:
            Text("Aucun axe sélectionné. Choisissez des familles pour afficher leur fréquence.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .bars:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(axes, id: \.self) { family in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(family).font(.caption); Spacer(); Text("\(counts[family] ?? 0) / \(denominator)").font(.caption).monospacedDigit() }
                        GeometryReader { geometry in
                            let fraction = denominator > 0 ? min(1, max(0, Double(counts[family] ?? 0) / Double(denominator))) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.08))
                                Capsule().fill(.primary.opacity(0.6)).frame(width: geometry.size.width * fraction)
                            }
                        }.frame(height: 8)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .radar: ProfileRadar06(axes: axes, counts: counts, denominator: denominator)
        }
    }
}

private struct ProfileRadar06: View {
    let axes: [String]; let counts: [String: Int]; let denominator: Int
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width / 3, geometry.size.height / 2.6)
            let count = axes.count
            ZStack {
                ForEach(1...4, id: \.self) { ring in Path { path in for index in 0..<count { let p = point(index, count, center, radius * Double(ring) / 4); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.stroke(.primary.opacity(0.12), lineWidth: 1) }
                Path { path in for (index, axis) in axes.enumerated() { let fraction = denominator > 0 ? min(1, Double(counts[axis] ?? 0) / Double(denominator)) : 0; let p = point(index, count, center, radius * fraction); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.fill(.primary.opacity(0.14)).overlay(Path { path in for (index, axis) in axes.enumerated() { let p = point(index, count, center, radius * (denominator > 0 ? min(1, Double(counts[axis] ?? 0) / Double(denominator)) : 0)); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.stroke(.primary.opacity(0.7), lineWidth: 2))
                ForEach(Array(axes.enumerated()), id: \.element) { index, axis in Text(axis).font(.caption2).frame(width: 130).position(point(index, count, center, radius + 25)) }
            }
        }
    }
    private func point(_ index: Int, _ count: Int, _ center: CGPoint, _ radius: Double) -> CGPoint { let angle = Double(index) * .pi * 2 / Double(count) - .pi / 2; return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius) }
}
