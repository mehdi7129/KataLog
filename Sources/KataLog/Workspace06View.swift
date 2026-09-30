import AppKit
import SwiftUI
import KataLogCore

/// Paged library workflows in the original monochrome bento workspace.
struct Workspace06View: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var gcs: GCSStore
    @ObservedObject private var views: LibraryViewStore
    @StateObject private var storage: LibraryStorageStore
    @StateObject private var updates = UpdateStore()
    @StateObject private var reportPreview = ReportPreviewStore()
    @State private var page: Page = .overview
    @State private var showingFlight = false
    @State private var showingScope = false
    @State private var showingSources = false
    @State private var showingSavedViews = false
    @State private var identity: DroneIdentityTarget?
    @State private var viewName = ""
    @State private var localError: String?
    @State private var historyCursors: [String?] = [nil]
    @State private var groupCursors: [String?] = [nil]
    @State private var registryCursors: [String?] = [nil]
    @State private var selectedGroup: LibraryGroup?
    @State private var pendingOverviewGroup: LibraryGroup?
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
        case overview = "Vue d’ensemble"
        case history = "Historique", alerts = "Alertes", events = "Événements PX4", map = "Carte", drones = "Drones"
        case collection = "Collecte GCS", storage = "Stockage", reports = "Rapports", settings = "Réglages"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
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
    init(library: LibraryStore, gcs: GCSStore, initialPage: Page = .overview) {
        self.library = library; self.gcs = gcs; views = library.views
        _page = State(initialValue: initialPage)
        _storage = StateObject(wrappedValue: LibraryStorageStore(library: library))
    }
    private var totals: LibraryTotals? { library.historyPage?.totals }
    private var theme: ColorScheme? { WorkspaceAppearance.colorScheme(for: views.state.theme) }
    private var palette: Palette { Palette(dark: (theme ?? scheme) == .dark) }
    private var themeSelection: Binding<String> { Binding(get: { WorkspaceAppearance.selection(for: views.state.theme) }, set: { value in edit { try views.setTheme(value) } }) }
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
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if page != .collection { header }
                        notices
                        if [.overview, .history, .alerts, .events, .map].contains(page), views.state.activeScope != SelectionScope() || !views.state.maskedMessageKeys.isEmpty { scopeBar }
                        switch page {
                        case .overview: overview
                        case .history: history
                        case .alerts: alertProfile; alerts
                        case .events: EventBrowserView(library: library)
                        case .map: map
                        case .drones: registry
                        case .collection: GCSCollectionView(store: gcs, library: library, dark: palette.dark)
                        case .storage: storagePage
                        case .reports: reportPage
                        case .settings: settings
                        }
                        Text("Les alertes décrivent des observations enregistrées. Elles ne prouvent pas à elles seules une panne matérielle.")
                            .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    }.padding(30).frame(maxWidth: 1550, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.background(palette.background)
        }
        .frame(minWidth: 900, minHeight: 620)
        .font(.system(size: 12)).foregroundStyle(palette.primary)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette))
        .preferredColorScheme(theme).tint(palette.primary)
        .onAppear {
            gcs.attach(library: library)
            updates.installationAllowed = { !library.isImporting && !library.isExporting && !library.isMaintainingLibrary && !gcs.isBusy && !library.isQuerying && !library.isLoadingFlight }
            if !library.usesPagedNavigation { library.enablePagedNavigation() }
        }
        .onChange(of: page) { _, value in
            selectedGroup = nil
            if value == .alerts, let group = pendingOverviewGroup {
                pendingOverviewGroup = nil; selectedGroup = group; groupCursors = [nil]
                library.loadOccurrences(groupID: group.id)
            } else { pendingOverviewGroup = nil; reload(value) }
        }
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
        .sheet(isPresented: $showingSources) { SourcesImportView(library: library, externalBusy: gcs.isBusy).preferredColorScheme(theme) }
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
    private var sourceLabel: String {
        let folders = library.snapshot.sourceFolders
        guard let first = folders.first else { return "Bibliothèque locale" }
        return folders.count == 1 ? URL(fileURLWithPath: first).lastPathComponent : "\(folders.count) dossiers sources"
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23, weight: .medium))
                Text("kataLOG").font(.system(size: 25, weight: .bold)).tracking(-1.2)
            }
            Text("Les traces de votre flotte.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                .padding(.top, 7).padding(.bottom, 36)
            Text("ESPACE DE TRAVAIL").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                .foregroundStyle(palette.secondary).padding(.horizontal, 12).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach([Page.overview, .map, .drones, .alerts, .history, .events, .collection, .storage, .reports, .settings]) { item in
                        Button { page = item } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 18)
                                Text(item.rawValue).font(.system(size: 12, weight: item == page ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }.foregroundStyle(item == page ? palette.primary : palette.secondary)
                                .padding(.horizontal, 12).frame(height: 43)
                                .background(item == page ? palette.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("navigation.\(item.id)")
                    }
                }
            }.scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 10) {
                Button { showingSources = true } label: {
                    HStack(spacing: 6) {
                        Circle().fill(palette.mint).frame(width: 5, height: 5)
                        Text("BIBLIOTHÈQUE LOCALE").font(.system(size: 8, weight: .semibold)).tracking(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 8))
                    }
                }.buttonStyle(.plain).help(LibraryHelp.sources).accessibilityIdentifier("library.sources")
                Text(sourceLabel).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                if library.isReadOnly { Label("Lecture seule", systemImage: "lock").font(.system(size: 10)) }
                Rectangle().fill(palette.border).frame(height: 1)
                Text("Vos données restent sur ce Mac.").font(.system(size: 10)).foregroundStyle(palette.secondary)
            }.padding(14).background(palette.card, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 20)
        }.padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 24).frame(width: 204)
            .background(palette.sidebar).overlay(alignment: .trailing) { palette.border.frame(width: 1) }
    }
    private var topBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive")
            Text("Espace local")
            Text("/").padding(.horizontal, 3)
            Button { showingSources = true } label: { Text(sourceLabel).foregroundStyle(palette.primary).lineLimit(1) }
                .buttonStyle(.plain).help(LibraryHelp.sources)
            Spacer(minLength: 12)
            if AppPreviewConfiguration().reviewBuild {
                Text("Preview 0.6").font(.system(size: 10))
                    .help("Cette version utilise une bibliothèque séparée et conserve les données de l’app installée.")
            }
            Button { showingSavedViews = true } label: { Image(systemName: "bookmark").frame(width: 30, height: 30) }
                .buttonStyle(.plain).disabled(busy).help("Vues enregistrées")
                .accessibilityLabel("Vues enregistrées").accessibilityIdentifier("library.savedViews")
                .popover(isPresented: $showingSavedViews) { savedViews.padding(20).frame(width: 340).preferredColorScheme(theme) }
            Text("PX4 · ULog").font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.trailing, 6)
            WorkspaceThemeControl(selection: themeSelection, palette: palette).disabled(library.isReadOnly || library.isMaintainingLibrary)
        }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            .padding(.horizontal, 30).frame(height: 56)
            .overlay(alignment: .bottom) { palette.border.frame(height: 1) }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(page.rawValue).font(.system(size: 32, weight: .semibold)).tracking(-1.2)
            Text(page == .overview ? "Les observations de votre flotte, dans une seule bibliothèque." : page == .drones ? "Registre global · les identités sans log restent visibles" : page == .collection ? "Une seule copie, dans le dossier que vous choisissez." : "Retrouver, comprendre et conserver les données enregistrées.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
        }
    }
    private var headerActions: some View {
        HStack {
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Opération en cours") }
            Button { reload(page) } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 38) }
                .buttonStyle(.plain).help("Actualiser").accessibilityLabel("Actualiser").disabled(busy).focused($focusedControl, equals: .refresh)
            if [.overview, .history, .alerts, .events, .map].contains(page) {
                Button("Filtrer", systemImage: "line.3.horizontal.decrease") { showingScope = true }
                    .buttonStyle(.plain).padding(.horizontal, 8).frame(height: 38).disabled(busy)
                    .focused($focusedControl, equals: .scope).keyboardShortcut("f", modifiers: .command)
            }
            Button("Importer un dossier", systemImage: "folder.badge.plus") { chooseImport() }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true)).disabled(mutationBusy || library.isReadOnly).focused($focusedControl, equals: .importFolder)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scopeDescription; Spacer(minLength: 8); scopeActions }
            VStack(alignment: .leading, spacing: 12) { scopeDescription; scopeActions }
        }.font(.system(size: 11))
    }
    private var scopeDescription: some View {
        Label(views.state.activeScope == SelectionScope() ? "Tous les enregistrements" : views.state.activeScope.description, systemImage: "line.3.horizontal.decrease")
            .foregroundStyle(palette.secondary).lineLimit(2).help(views.state.activeScope.description)
    }
    private var scopeActions: some View {
        HStack(spacing: 8) {
            if views.state.activeScope != SelectionScope() {
                Button("Réinitialiser") { edit { try views.chooseScope(.init()) } }.disabled(busy)
            }
            if !views.state.maskedMessageKeys.isEmpty { Text("\(views.state.maskedMessageKeys.count) règles de masquage").foregroundStyle(palette.secondary) }
        }
    }
    private var savedViews: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vues enregistrées").font(.system(size: 16, weight: .semibold))
            if !views.state.views.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(views.state.views) { saved in
                            HStack {
                                Button(saved.name) { edit { try views.chooseScope(saved.scope); showingSavedViews = false } }.buttonStyle(.plain).lineLimit(2)
                                Spacer()
                                Button("Supprimer", systemImage: "trash") { edit { try views.removeView(saved.id) } }.labelStyle(.iconOnly).disabled(library.isReadOnly)
                                    .accessibilityLabel("Supprimer la vue « \(saved.name) »")
                            }
                        }
                    }
                }.frame(maxHeight: 220)
                }
            if views.state.views.isEmpty { Text("Aucune vue enregistrée.").foregroundStyle(palette.secondary) }
            Divider()
            TextField("Nom de la vue", text: $viewName).textFieldStyle(.roundedBorder).disabled(library.isReadOnly || busy)
            HStack {
                Button("Enregistrer la sélection") { edit { try views.saveView(name: viewName); viewName = "" } }.disabled(viewName.trimmingCharacters(in: .whitespaces).isEmpty || library.isReadOnly || busy)
                Spacer()
            }
            Text("\(views.state.maskedMessageKeys.count) règles de masquage · retrait réversible").font(.caption).foregroundStyle(palette.secondary)
        }.buttonStyle(WorkspaceActionButtonStyle(palette: palette))
    }
    private var priorityGroups: [LibraryGroup] { (library.groupPage?.groups ?? []).filter { $0.priority >= 4 } }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            overviewMetrics
            if totals?.logs == 0 {
                panel {
                    Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(palette.secondary)
                    Text("Votre flotte commence ici.").font(.system(size: 23, weight: .semibold)).tracking(-0.6)
                    Text("Importez un dossier de logs ou récupérez-les depuis votre GCS. KataLog conserve les analyses et déduplique les copies identiques.").foregroundStyle(palette.secondary)
                    Button("Importer un dossier", systemImage: "folder.badge.plus") { chooseImport() }
                        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true)).disabled(mutationBusy || library.isReadOnly)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        overviewReview.frame(minWidth: 350, maxWidth: .infinity)
                        overviewProfile.frame(minWidth: 285, maxWidth: 400)
                    }
                    VStack(spacing: 18) { overviewReview; overviewProfile }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        overviewGroups.frame(minWidth: 350, maxWidth: .infinity)
                        overviewHistory.frame(minWidth: 285, maxWidth: 400)
                    }
                    VStack(spacing: 18) { overviewGroups; overviewHistory }
                }
            }
        }
    }
    private var overviewReview: some View {
        panel {
            VStack(alignment: .leading, spacing: 0) {
                Text("À examiner").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                if let group = priorityGroups.first {
                    HStack(spacing: 7) {
                        Circle().fill(group.priority >= 5 ? palette.red : palette.amber).frame(width: 5, height: 5)
                        Text(group.level).foregroundStyle(group.priority >= 5 ? palette.red : palette.amber)
                        Text(group.family.uppercased()).foregroundStyle(palette.secondary)
                        Spacer()
                        Text(date(group.lastDate)).foregroundStyle(palette.secondary)
                    }.font(.system(size: 10, weight: .medium)).padding(.top, 22)
                    Text(group.title).font(.system(size: 25, weight: .semibold)).tracking(-0.7).lineLimit(3).padding(.top, 12)
                    Text("\(quantity(group.messageCount, "message")) · \(quantity(group.logCount, "log")) \(group.logCount == 1 ? "concerné" : "concernés") · \(quantity(group.droneCount, "drone"))")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 10)
                    Button { showOverviewGroup(group) } label: { Label("Examiner les messages", systemImage: "arrow.up.right") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).padding(.top, 22).disabled(busy)
                } else {
                    Text("Aucun message WARN ou de niveau supérieur dans cette sélection.").font(.system(size: 20, weight: .medium)).padding(.top, 22)
                    Text("Les événements PX4 et les états failsafe restent consultables dans leurs vues dédiées.")
                        .foregroundStyle(palette.secondary).padding(.top, 12)
                }
                Spacer(minLength: 22)
                Rectangle().fill(palette.border).frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(palette.amber)
                    Text("Priorité issue des messages enregistrés").font(.system(size: 11, weight: .medium))
                    Spacer()
                    LibraryHelpButton(title: "À examiner", text: "Le premier groupe est choisi par niveau de sévérité, puis par nombre de logs concernés, sur toute la sélection. Ce panneau couvre les messages WARN et les niveaux supérieurs ; les événements PX4 et les états failsafe sont présentés séparément.")
                }.padding(.top, 16)
            }.frame(minHeight: 280, alignment: .topLeading)
        }
    }
    private var overviewProfile: some View {
        let counts = totals?.familyLogCounts ?? [:]
        let axes = views.state.profileAxes ?? Array(counts.keys.sorted().prefix(8))
        return panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Profil des alertes").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                    Spacer()
                    LibraryHelpButton(title: "Profil des alertes", text: LibraryHelp.profile)
                }
                Text("Logs concernés par famille").font(.system(size: 11)).foregroundStyle(palette.secondary)
                if counts.isEmpty {
                    Text("Aucune famille d’alerte textuelle dans cette sélection.").foregroundStyle(palette.secondary).frame(maxHeight: .infinity, alignment: .center)
                } else {
                    AlertProfileChart06(axes: axes, counts: counts, denominator: totals?.validLogs ?? 0)
                        .frame(height: axes.count >= 3 ? 170 : 130).accessibilityHidden(true)
                    Text(axes.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(3)
                }
                Spacer(minLength: 0)
                Rectangle().fill(palette.border).frame(height: 1)
                HStack {
                    Text("Échelle : 0 à \(quantity(totals?.validLogs ?? 0, "log"))").font(.system(size: 10)).foregroundStyle(palette.secondary)
                    Spacer()
                    Button("Explorer", systemImage: "arrow.right") { page = .alerts }.buttonStyle(.plain).font(.system(size: 11))
                }
            }.frame(minHeight: 280, alignment: .topLeading)
        }
    }
    private var overviewGroups: some View {
        panel {
            HStack {
                Text("Alertes repérées").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button("Explorer", systemImage: "arrow.right") { page = .alerts }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Text("Messages WARN et niveaux supérieurs · textes regroupés").font(.system(size: 10)).foregroundStyle(palette.secondary)
            ForEach(Array(priorityGroups.prefix(6))) { group in
                Button { showOverviewGroup(group) } label: {
                    HStack(spacing: 12) {
                        Circle().fill(group.priority >= 5 ? palette.red : palette.amber).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                            Text("\(group.family) · \(quantity(group.messageCount, "message")) · \(quantity(group.droneCount, "drone"))").font(.system(size: 10)).foregroundStyle(palette.secondary)
                        }
                        Spacer()
                        Text("\(group.logCount)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(palette.secondary)
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy)
                Divider()
            }
            if priorityGroups.isEmpty { Text("Aucun message WARN ou supérieur repéré.").foregroundStyle(palette.secondary).padding(.vertical, 18) }
        }
    }
    private var overviewHistory: some View {
        panel {
            HStack {
                Text("Historique").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button("Tout voir", systemImage: "arrow.right") { page = .history }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Text("Aperçu : \(quantity(min(6, library.snapshot.logs.count), "log")) sur \(totals?.logs ?? 0) dans la sélection")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
            Text("Durées enregistrées, temps au sol inclus").font(.system(size: 10)).foregroundStyle(palette.secondary)
            ForEach(Array(library.snapshot.logs.prefix(6))) { log in
                Button { open(log) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(log.status == "error" ? palette.red : log.hasAlerts ? palette.amber : palette.muted).frame(width: 5, height: 5).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(date(log.date)).font(.system(size: 11, weight: .semibold))
                            Text(log.displayName).font(.system(size: 10)).foregroundStyle(palette.secondary)
                            LogAssessmentBadge(log: log)
                        }
                        Spacer(minLength: 4)
                        Text(FlightUIFormat.duration(log.durationSeconds)).font(.system(size: 10)).foregroundStyle(palette.secondary).monospacedDigit()
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy).help("Ouvrir \(log.fileName)").accessibilityLabel("Ouvrir \(log.fileName), \(log.displayName), \(date(log.date))")
                Divider()
            }
        }
    }
    private func showOverviewGroup(_ group: LibraryGroup) { pendingOverviewGroup = group; page = .alerts }
    private func quantity(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
    private var overviewMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 0)], spacing: 12) {
            metric("Drones scannés", value: totals.map { $0.scannedDrones.formatted() } ?? "—", note: "", help: LibraryHelp.drones + "\n\(totals?.provisionalDrones ?? 0) identités provisoires, comptées à part.")
            metric("Enregistrements", value: totals.map { $0.logs.formatted() } ?? "—", note: "", help: "Logs uniques de toute la sélection. Les copies identiques sont dédupliquées par contenu ; les fichiers illisibles restent conservés.")
            metric("Durée enregistrée", value: totals.map { FlightUIFormat.duration($0.recordedSeconds) } ?? "—", note: "", help: LibraryHelp.recordedDuration)
            metric("Temps de vol cumulé", value: totals?.measuredFlightSeconds.map(FlightUIFormat.duration) ?? "Indisponible", note: "", help: LibraryHelp.flightDuration + "\n\(totals?.flightLogCount ?? 0) / \(totals?.logs ?? 0) logs avec temps de vol mesuré.")
            metric("Avec alerte", value: totals.map { "\($0.alertLogs) / \($0.validLogs)" } ?? "—", note: "", help: LibraryHelp.alerts)
        }.padding(.vertical, 12).background(palette.sidebar.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
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
                            VStack(alignment: .trailing, spacing: 6) {
                                LogAssessmentBadge(log: log)
                                Text(log.assessment.reason).lineLimit(2).frame(maxWidth: 290, alignment: .trailing).foregroundStyle(.secondary)
                                Text(log.analysisQualityLabel).foregroundStyle(.secondary)
                                Text("\(FlightUIFormat.duration(log.durationSeconds)) enregistrées").foregroundStyle(.secondary)
                            }.font(.caption)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 0)], spacing: 12) {
            metric("Enregistrements", value: totals.map { $0.logs.formatted() } ?? "—", note: "Copies identiques dédupliquées", help: "Nombre de logs uniques dans la sélection active. Les copies identiques sont dédupliquées par contenu ; les fichiers illisibles restent dans l’historique.")
            metric("Drones scannés", value: totals.map { $0.scannedDrones.formatted() } ?? "—", note: totals.map { "\($0.provisionalDrones) identités provisoires, comptées à part" } ?? "Identités en cours de lecture", help: LibraryHelp.drones)
            metric("Durée enregistrée", value: totals.map { FlightUIFormat.duration($0.recordedSeconds) } ?? "—", note: "Inclut le temps au sol", help: LibraryHelp.recordedDuration)
            metric("Temps de vol cumulé", value: totals?.measuredFlightSeconds.map(FlightUIFormat.duration) ?? "Indisponible", note: totals.flatMap { total in total.flightLogCount.map { "\($0) / \(total.logs) logs avec temps de vol mesuré" } } ?? "Couverture non déterminée", help: LibraryHelp.flightDuration)
            metric("Avec alerte", value: totals.map { $0.alertLogs.formatted() } ?? "—", note: totals.map { "Logs uniques sur \($0.validLogs) lus" } ?? "Lecture en cours", help: LibraryHelp.alerts)
            metric("Failsafe", value: totals.map { $0.failsafeLogs.formatted() } ?? "—", note: views.state.activeScope.hasMessageFilters ? "Non inclus dans ce filtre de messages" : "État enregistré, distinct des textes", help: "Nombre de logs où PX4 a enregistré un état failsafe. Ce compte décrit un état du système et ne confirme pas une panne. Un filtre de messages n’inclut pas cet état dans son périmètre.")
        }.padding(.vertical, 16).background(palette.sidebar.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }
    private var alertProfile: some View {
        let counts = totals?.familyLogCounts ?? [:]
        let axes = views.state.profileAxes ?? Array(counts.keys.sorted().prefix(8))
        let allFamilies = AlertProfile06.families(counts: counts, selectedAxes: axes)
        return panel {
            HStack { Text("Profil des alertes textuelles").font(.headline); LibraryHelpButton(title: "Profil des alertes", text: LibraryHelp.profile); Spacer(); Menu("Choisir les axes") {
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
            HStack { Text(selectedGroup == nil ? "Messages regroupés" : "Occurrences du groupe").font(.headline); LibraryHelpButton(title: "Alertes enregistrées", text: LibraryHelp.alerts); Spacer(); if selectedGroup != nil { Button("Tous les groupes") { selectedGroup = nil; library.loadHistory() } } }
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
            HStack { Text("\(library.dronePage?.total ?? 0) entrées du registre").font(.headline); LibraryHelpButton(title: "Drones scannés", text: LibraryHelp.drones); Spacer(); TextField("Numéro, nom ou identité", text: $registrySearch).textFieldStyle(.roundedBorder).frame(maxWidth: 320).onSubmit { registryCursors = [nil]; library.loadAuxiliary(kind: "drones", search: registrySearch) }; Button("Rechercher") { registryCursors = [nil]; library.loadAuxiliary(kind: "drones", search: registrySearch) }.disabled(busy) }
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
                HStack { Text("Sauvegarder et retrouver").font(.headline); LibraryHelpButton(title: "Sauvegardes", text: "Analyses + réglages conserve la bibliothèque et ses réglages. Sauvegarde complète ajoute les ULog accessibles. La restauration importe une sauvegarde vérifiée et conserve une récupération des données remplacées. Aucune source d’origine n’est supprimée.") }
                Text("Une sauvegarde analyses + réglages conserve les numéros, les familles, les vues et la collecte. La version complète ajoute les ULog accessibles. Aucune source d’origine n’est supprimée.").font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) { HStack { backupButtons }; VStack(alignment: .leading) { backupButtons } }.disabled(mutationBusy || library.isReadOnly || library.isExporting || storage.isWorking)
                if library.isMaintainingLibrary || storage.isWorking { HStack { ProgressView().controlSize(.small); Text(storage.message ?? "Vérification et traitement…"); Spacer(); Button("Arrêter") { maintenanceTask?.cancel(); storage.cancel() } } }
                if let message = storage.message { Text(message).font(.callout) }
                if let error = storage.errorMessage { notice(error, symbol: "exclamationmark.triangle") }
                if let recovery = storage.recoveryURL { Button("Voir le dossier de récupération") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) } }
            }
            panel {
                HStack { Text("Sources et cache").font(.headline); LibraryHelpButton(title: "Sources et cache", text: "Retrouver un dossier associe des ULog dont le SHA256 correspond aux analyses conservées. Archiver copie et vérifie les ULog choisis dans un autre dossier. Nettoyer déplace le cache et les anciennes révisions dans une récupération ; le dernier résumé, la dernière analyse détaillée et les ULog restent disponibles."); Spacer(); Button("Sources d’import…") { showingSources = true }.help(LibraryHelp.sources) }
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
            .help("Cherche des ULog dont le SHA256 correspond aux analyses conservées et associe les chemins retrouvés.")
        Button("Archiver les logs choisis…") { if let folder = selectFolder("Copier les ULog sélectionnés") { storage.perform(command: "archive", logIDs: selectedStorageLogs.sorted(), destination: folder) } }.disabled(selectedStorageLogs.isEmpty)
            .help("Copie et vérifie les ULog choisis dans un autre dossier. Les originaux sont conservés.")
        Button("Nettoyer cache et anciennes analyses") { storage.perform(command: "clean-cache", logIDs: selectedStorageLogs.sorted()) }.disabled(selectedStorageLogs.isEmpty)
            .help("Déplace le cache et les anciennes révisions dans une récupération. Le dernier résumé, la dernière analyse détaillée et les ULog restent disponibles.")
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
                    Text("\(preview.totals.logs) logs · \(preview.totals.messages) messages · \(preview.totals.scannedDrones) drones scannés").font(.headline)
                    Text("\(preview.totals.provisionalDrones) identités provisoires, comptées à part").font(.caption).foregroundStyle(.secondary)
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
                Picker("Thème", selection: themeSelection) { Text("Système").tag("system"); Text("Clair").tag("light"); Text("Sombre").tag("dark") }.pickerStyle(.segmented).disabled(library.isReadOnly || library.isMaintainingLibrary)
            }
            UpdateSettingsView(store: updates, readOnly: library.isReadOnly)
            panel { Text("Diagnostic local").font(.headline); Text("Versions, système et états de l’app uniquement. Aucun log, texte d’erreur libre, chemin, identité, endpoint GCS ou coordonnée n’est inclus.").font(.callout).foregroundStyle(.secondary); Text("Les comptes de la bibliothèque qualifient la sélection active. Les jobs, masquages et vues qualifient l’app ; chaque compte indique son périmètre dans le JSON.").font(.caption).foregroundStyle(.secondary); Button("Prévisualiser le diagnostic") { makeDiagnostic() }.focused($focusedControl, equals: .diagnostic) }
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
        VStack(alignment: .leading, spacing: 14, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.border, lineWidth: 1))
    }
    private func notice(_ text: String, symbol: String) -> some View { Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func metric(_ title: String, value: Int, note: String) -> some View { metric(title, value: value.formatted(), note: note) }
    private func metric(_ title: String, value: String, note: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: value == "Indisponible" ? 15 : 21, weight: .semibold)).tracking(-0.6).monospacedDigit()
            HStack(spacing: 3) { Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary); if let help { LibraryHelpButton(title: title, text: help) } }
            if !note.isEmpty { Text(note).font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: note.isEmpty ? 40 : 68, alignment: .topLeading)
    }
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
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
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
                                Capsule().fill(palette.border)
                                Capsule().fill(palette.mint.opacity(0.8)).frame(width: geometry.size.width * fraction)
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
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width / 3, geometry.size.height / 2.6)
            let count = axes.count
            ZStack {
                ForEach(1...4, id: \.self) { ring in Path { path in for index in 0..<count { let p = point(index, count, center, radius * Double(ring) / 4); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.stroke(palette.border, lineWidth: 1) }
                Path { path in for (index, axis) in axes.enumerated() { let fraction = denominator > 0 ? min(1, Double(counts[axis] ?? 0) / Double(denominator)) : 0; let p = point(index, count, center, radius * fraction); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.fill(palette.mint.opacity(0.15)).overlay(Path { path in for (index, axis) in axes.enumerated() { let p = point(index, count, center, radius * (denominator > 0 ? min(1, Double(counts[axis] ?? 0) / Double(denominator)) : 0)); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.stroke(palette.mint, lineWidth: 1.5))
                ForEach(Array(axes.enumerated()), id: \.element) { index, axis in Text(axis).font(.system(size: 9)).foregroundStyle(palette.secondary).frame(width: 100).position(point(index, count, center, radius + 25)) }
            }
        }
    }
    private func point(_ index: Int, _ count: Int, _ center: CGPoint, _ radius: Double) -> CGPoint { let angle = Double(index) * .pi * 2 / Double(count) - .pi / 2; return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius) }
}
