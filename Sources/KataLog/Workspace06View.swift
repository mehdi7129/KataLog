import AppKit
import SwiftUI
import KataLogCore

/// Paged library workflows in the original monochrome bento workspace.
struct Workspace06View: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var gcs: GCSStore
    @ObservedObject private var views: LibraryViewStore
    @StateObject private var storage: LibraryStorageStore
    @StateObject private var updates: UpdateStore
    @StateObject private var reportPreview = ReportPreviewStore()
    @StateObject private var diagnostics: DiagnosticStore
    @State private var page: Page = .overview
    @State private var showingFlight = false
    @State private var showingScope = false
    @State private var showingSources = false
    @State private var showingSavedViews = false
    @State private var profileExpanded = false
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
    @State private var reportPreviewWasCancelled = false
    @State private var restoreCandidate: URL?
    @State private var restorePreview: JSONValue?
    @State private var maintenanceTask: Task<Void, Never>?
    @State private var showingDiagnostic = false
    @State private var importSource: URL?
    @State private var importOptions = ImportOptionsState()
    @State private var maskGroup: LibraryGroup?
    @State private var masking = true
    @State private var lastOpenedLogID: String?
    @State private var selectedStorageLogs: Set<String> = []
    @State private var storageOffsets = [0]
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focusedControl: FocusControl?
    private enum FocusControl: Hashable { case importFolder, scope, refresh, savedViews, viewName, historyLog(String), mask(Bool), diagnostic, restore }

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
            case .drones: "drone"
            case .collection: "tray.and.arrow.down"
            case .storage: "externaldrive"
            case .reports: "doc.text"
            case .settings: "gearshape"
            }
        }
    }
    init(library: LibraryStore, gcs: GCSStore, initialPage: Page = .overview, updates: UpdateStore? = nil) {
        self.library = library; self.gcs = gcs; views = library.views
        _page = State(initialValue: initialPage)
        _updates = StateObject(wrappedValue: updates ?? UpdateStore())
        _storage = StateObject(wrappedValue: LibraryStorageStore(library: library))
        _diagnostics = StateObject(wrappedValue: library.diagnosticStore)
    }
    private var totals: LibraryTotals? { library.historyPage?.totals }
    private var theme: ColorScheme? { WorkspaceAppearance.colorScheme(for: views.state.theme) }
    private var palette: Palette { Palette(dark: (theme ?? scheme) == .dark) }
    private var themeSelection: Binding<String> { Binding(get: { WorkspaceAppearance.selection(for: views.state.theme) }, set: { value in edit { try views.setTheme(value) } }) }
    private var busy: Bool { library.isImporting || library.isMaintainingLibrary || library.isQuerying || library.isLoading || library.isLoadingFlight }
    private var mutationBusy: Bool { busy || gcs.isBusy }
    private var queryResultsUnavailable: Bool { library.isQuerying || library.queryWasCancelled || library.queryError != nil }
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
                    VStack(alignment: .leading, spacing: BentoTokens.spacing) {
                        if page != .collection { header }
                        notices
                        if [.overview, .history, .alerts, .events, .map].contains(page), views.state.activeScope != SelectionScope() || !views.state.maskedMessageKeys.isEmpty { scopeBar }
                        if [.overview, .history, .alerts, .map, .drones].contains(page), queryResultsUnavailable {
                            queryPlaceholder
                        } else { switch page {
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
                        } }
                        Text("Les alertes décrivent des observations enregistrées. Elles ne prouvent pas à elles seules une panne matérielle.")
                            .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    }.padding(28).frame(maxWidth: 1550, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.background(palette.background)
        }
        .frame(minWidth: 900, minHeight: 620)
        .font(.system(size: 12)).foregroundStyle(palette.primary)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette))
        .preferredColorScheme(theme).tint(palette.primary)
        .onAppear {
            gcs.attach(library: library)
            updates.installationAllowed = { !library.isReadOnly && !library.isImporting && !library.isExporting && !library.isMaintainingLibrary && !gcs.isBusy && !library.isQuerying && !library.isLoadingFlight }
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
        .onChange(of: showingSavedViews) { _, shown in if !shown { focusedControl = .savedViews } }
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
        .sheet(isPresented: $showingDiagnostic, onDismiss: { diagnostics.dismiss(); focusedControl = .diagnostic }) {
            DiagnosticView(store: diagnostics, host: gcs.host, readOnly: library.isReadOnly, externalBusy: mutationBusy || library.isExporting,
                refresh: { diagnostics.load(report: currentDiagnosticReport()) }, close: { showingDiagnostic = false })
                .preferredColorScheme(theme)
        }
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
        GeometryReader { geometry in
            let compact = geometry.size.height < 760
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 25, weight: .medium))
                    Text("kataLOG").font(.system(size: 26, weight: .bold)).tracking(-1.2)
                }.padding(.horizontal, 10)
                Text("Les traces de votre flotte.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, compact ? 22 : 38)
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                        navigationHeading("BIBLIOTHÈQUE")
                        ForEach([Page.overview, .history, .alerts, .events, .map, .drones]) { navigationItem($0, compact: compact) }
                        navigationHeading("OUTILS").padding(.top, compact ? 14 : 24)
                        ForEach([Page.collection, .storage, .reports, .settings]) { navigationItem($0, compact: compact) }
                    }
                }.scrollIndicators(.hidden)
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    Button { showingSources = true } label: {
                        HStack(spacing: 10) {
                            BentoIcon(symbol: "folder", size: 16)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bibliothèque locale").font(.system(size: 11, weight: .medium))
                                Text(quantity(library.snapshot.sourceFolders.count, "dossier") + (library.snapshot.sourceFolders.count == 1 ? " source" : " sources"))
                                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                            }
                            Spacer(minLength: 0)
                            BentoIcon(symbol: "chevron.right", size: 9)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(LibraryHelp.sources).accessibilityIdentifier("library.sources")
                    if library.isReadOnly { Label("Lecture seule", systemImage: "lock").font(.system(size: 10)) }
                    if !compact { Text("Vos données restent sur ce Mac.").font(.system(size: 10)).foregroundStyle(palette.secondary) }
                }.padding(.horizontal, 10).padding(.top, 14)
            }.padding(.horizontal, 16).padding(.top, compact ? 24 : 34).padding(.bottom, compact ? 16 : 24)
        }.frame(width: BentoTokens.sidebarWidth)
            .background(palette.sidebar).overlay(alignment: .trailing) { palette.border.frame(width: 1) }
    }
    private func navigationHeading(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.4)
            .foregroundStyle(palette.secondary).padding(.horizontal, 12).padding(.bottom, 7)
    }
    private func navigationItem(_ item: Page, compact: Bool) -> some View {
        Button { page = item } label: {
            HStack(spacing: 11) {
                BentoIcon(symbol: item.symbol, size: 17).frame(width: 20)
                Text(item.rawValue).font(.system(size: 12, weight: item == page ? .semibold : .regular))
                Spacer(minLength: 0)
            }.foregroundStyle(item == page ? palette.primary : palette.secondary)
                .padding(.horizontal, 12).frame(height: compact ? 34 : 42)
                .background(item == page ? palette.card : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityIdentifier("navigation.\(item.id)")
            .accessibilityAddTraits(item == page ? .isSelected : [])
    }
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showingSources = true } label: { Label("Bibliothèque", systemImage: "externaldrive") }
                .buttonStyle(.plain).help(LibraryHelp.sources)
            Text("/").foregroundStyle(palette.muted)
            Text(page.rawValue).foregroundStyle(palette.primary).lineLimit(1)
            Spacer(minLength: 8)
            if AppPreviewConfiguration().reviewBuild {
                Text("Preview").font(.system(size: 10)).help("Bibliothèque de validation séparée de l’app installée.")
            }
            Button { showingSavedViews = true } label: { BentoIcon(symbol: "bookmark", size: 14) }
                .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
                .disabled(busy).help("Vues enregistrées").focused($focusedControl, equals: .savedViews)
                .accessibilityLabel("Vues enregistrées").accessibilityIdentifier("library.savedViews")
                .popover(isPresented: $showingSavedViews) { savedViews.padding(20).frame(width: 340).preferredColorScheme(theme) }
            WorkspaceThemeControl(selection: themeSelection, palette: palette)
                .disabled(library.isReadOnly || library.isMaintainingLibrary)
            Button("Importer", systemImage: "plus") { chooseImport() }
                .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
                .disabled(mutationBusy || library.isReadOnly).focused($focusedControl, equals: .importFolder)
                .keyboardShortcut("o", modifiers: .command).help("Importer un dossier de logs")
        }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            .padding(.horizontal, 28).frame(height: 64)
            .overlay(alignment: .bottom) { palette.border.frame(height: 1) }
    }
    private var subtitle: String {
        switch page {
        case .overview: "L’essentiel de votre flotte, au même endroit."
        case .history: "Retrouvez chaque enregistrement et son niveau d’alerte."
        case .alerts: "Les messages enregistrés, regroupés pour mieux les comprendre."
        case .events: "Reconstituez les événements enregistrés par PX4."
        case .map: "Les positions et les trajectoires présentes dans vos logs."
        case .drones: "Votre registre, y compris les drones sans log."
        case .collection: "Récupérez les logs de votre flotte dans un seul dossier."
        case .storage: "Conservez vos sources et protégez vos analyses."
        case .reports: "Un rapport clair, avec le périmètre que vous choisissez."
        case .settings: "L’apparence, les mises à jour et le diagnostic de KataLog."
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(page.rawValue).font(.system(size: 32, weight: .semibold)).tracking(-1.2)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.secondary)
        }
    }
    private var headerActions: some View {
        HStack(spacing: 9) {
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Opération en cours") }
            Button { reload(page) } label: { BentoIcon(symbol: "arrow.clockwise", size: 14) }
                .help("Actualiser").accessibilityLabel("Actualiser").disabled(busy).focused($focusedControl, equals: .refresh)
            if [.overview, .history, .alerts, .events, .map].contains(page) {
                Button("Filtrer", systemImage: "line.3.horizontal.decrease") { showingScope = true }
                    .disabled(busy).focused($focusedControl, equals: .scope).keyboardShortcut("f", modifiers: .command)
            }
        }
    }
    @ViewBuilder private var notices: some View {
        if library.isReadOnly { notice("Une autre instance utilise la bibliothèque. Fermez-la puis relancez KataLog pour modifier les données.", symbol: "lock") }
        if let message = library.statusMessage { notice(message, symbol: "info.circle") }
        if library.isQuerying || (page == .reports && reportPreview.isLoading) {
            LibraryReadRecoveryNotice(requestID: library.isQuerying ? library.queryToken.uuidString : reportPreviewKey,
                                      isCancelling: library.isCancellingQuery, palette: palette,
                                      cancel: cancelLibraryReads)
        }
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
    private var queryPlaceholder: some View {
        panel {
            if library.isQuerying {
                ProgressView(library.isCancellingQuery ? "Arrêt de la lecture…" : "Lecture de la sélection…").controlSize(.small)
                Text("Les résultats s’afficheront une fois la lecture terminée.").foregroundStyle(palette.secondary)
            } else {
                Text(library.queryWasCancelled ? "Lecture annulée" : "Lecture indisponible").font(.system(size: 16, weight: .semibold))
                Text("Les analyses sont conservées. Vous pouvez reprendre la lecture ou choisir le dossier source avec « Importer un dossier ».")
                    .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Reprendre la lecture", systemImage: "arrow.clockwise") { reload(page) }.disabled(busy)
            }
        }.accessibilityIdentifier("library.query-state")
    }
    private func cancelLibraryReads() {
        if reportPreview.isLoading { reportPreviewWasCancelled = true; reportPreview.cancel() }
        Task { await library.cancelQuery() }
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
                .focused($focusedControl, equals: .viewName).onSubmit { saveCurrentView() }
            HStack {
                Button("Enregistrer la sélection") { saveCurrentView() }.disabled(viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isReadOnly || busy)
                Spacer()
            }
            Text("\(quantity(views.state.maskedMessageKeys.count, "règle")) de masquage · retrait réversible").font(.caption).foregroundStyle(palette.secondary)
        }.buttonStyle(WorkspaceActionButtonStyle(palette: palette))
            .onAppear { focusedControl = .viewName }
    }
    private func saveCurrentView() {
        guard !viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !library.isReadOnly, !busy else { return }
        edit { try views.saveView(name: viewName); viewName = "" }
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
                        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).padding(.top, 22).disabled(busy)
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
                    Text("Échelle : 0 à \(AlertProfile06.displayMaximum(counts: counts, denominator: totals?.validLogs ?? 0)) logs").font(.system(size: 10)).foregroundStyle(palette.secondary)
                    Spacer()
                    Button("Explorer", systemImage: "arrow.right") { page = .alerts }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
                }
            }.frame(minHeight: 280, alignment: .topLeading)
        }
    }
    private var overviewGroups: some View {
        panel {
            HStack {
                Text("Alertes repérées").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button("Explorer", systemImage: "arrow.right") { page = .alerts }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).foregroundStyle(palette.secondary)
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
                Text("Activité récente").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button("Tout voir", systemImage: "arrow.right") { page = .history }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Text("Aperçu : \(quantity(min(6, library.snapshot.logs.count), "log")) sur \(totals?.logs ?? 0) dans la sélection")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
            Text("Durées enregistrées, temps au sol inclus").font(.system(size: 10)).foregroundStyle(palette.secondary)
            if !recentActivity.isEmpty { activityChart }
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
    private var recentActivity: [(day: String, count: Int)] {
        var counts: [String: Int] = [:]
        for log in library.snapshot.logs {
            if let day = SelectionScope.calendarDay(log.date) { counts[day, default: 0] += 1 }
        }
        return counts.keys.sorted().suffix(14).map { ($0, counts[$0] ?? 0) }
    }
    private var activityChart: some View {
        let activity = recentActivity
        let maximum = max(1, activity.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(Array(activity.enumerated()), id: \.offset) { _, item in
                    let height = CGFloat(max(3.0, 56.0 * Double(item.count) / Double(maximum)))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.primary.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .help(item.day + " · " + quantity(item.count, "log"))
                        .accessibilityLabel(item.day + ", " + quantity(item.count, "log"))
                }
            }.frame(height: 56, alignment: .bottom)
            HStack {
                Text(activity.first?.day ?? ""); Spacer(); Text(activity.last?.day ?? "")
            }.font(.system(size: 9)).foregroundStyle(palette.secondary)
            Text("Logs datés de la page courante · 14 jours observés au maximum")
                .font(.system(size: 9)).foregroundStyle(palette.secondary)
        }.padding(.vertical, 8)
    }
    private func showOverviewGroup(_ group: LibraryGroup) { pendingOverviewGroup = group; page = .alerts }
    private func quantity(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
    private var overviewMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 0)], spacing: 14) {
            metric("Drones scannés", value: totals.map { $0.scannedDrones.formatted() } ?? "—", note: "", help: LibraryHelp.drones + "\n\(totals?.provisionalDrones ?? 0) identités provisoires, comptées à part.")
            metric("Logs enregistrés", value: totals.map { $0.logs.formatted() } ?? "—", note: "Copies identiques dédupliquées", help: "Logs uniques dans la sélection. Les fichiers illisibles restent dans l’historique ; leur qualité de lecture est indiquée séparément.")
            metric("Temps de vol cumulé", value: totals?.measuredFlightSeconds.map(FlightUIFormat.duration) ?? "Indisponible", note: totals.map { FlightUIFormat.duration($0.recordedSeconds) + " enregistrées" } ?? "", help: LibraryHelp.flightDuration + "\n" + LibraryHelp.recordedDuration + "\n\(totals?.flightLogCount ?? 0) / \(totals?.logs ?? 0) logs avec temps de vol mesuré.")
            metric("Logs avec alerte", value: totals.map { $0.alertLogs.formatted() } ?? "—", note: totals.map { "Sur \($0.validLogs) logs lus" } ?? "", help: LibraryHelp.alerts)
        }.padding(.vertical, 18).background(palette.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            overviewMetrics
            panel {
                ViewThatFits(in: .horizontal) {
                    HStack { historyHeading; Spacer(); historySort }
                    VStack(alignment: .leading, spacing: 10) { historyHeading; historySort }
                }
                if library.snapshot.logs.isEmpty {
                    empty("Aucun enregistrement dans cette sélection.", action: "Réinitialiser") { edit { try views.chooseScope(.init()) } }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(library.snapshot.logs) { log in
                        historyRow(log)
                        Divider()
                    }
                }
                pagination(cursors: $historyCursors, next: library.historyPage?.nextCursor) { library.loadHistory(cursor: $0) }
                DisclosureGroup("Couverture et états enregistrés") {
                    Text("\(totals?.flightLogCount ?? 0) / \(totals?.logs ?? 0) logs avec temps de vol mesuré · \(totals?.failsafeLogs ?? 0) logs avec état failsafe. " + (views.state.activeScope.hasMessageFilters ? "Les états failsafe ne sont pas inclus dans ce filtre de messages." : "Un état failsafe est distinct d’une alerte textuelle et ne confirme pas une panne."))
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }.font(.system(size: 11))
            }
        }
    }
    private var historyHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Enregistrements").font(.system(size: 16, weight: .semibold))
            Text("\(totals?.logs ?? 0) résultats · \(library.snapshot.logs.count) sur cette page")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }
    private var historySort: some View {
        Menu {
            Button("Récents d’abord") { edit { try views.chooseHistorySort("recent") } }
            Button("Anciens d’abord") { edit { try views.chooseHistorySort("oldest") } }
        } label: {
            Label(views.state.historySort == "oldest" ? "Anciens d’abord" : "Récents d’abord", systemImage: "arrow.up.arrow.down")
        }.menuStyle(.borderlessButton).fixedSize().disabled(busy)
            .padding(.horizontal, 12).frame(height: 32)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.buttonBorder, lineWidth: 1))
    }
    private func historyRow(_ log: FlightLog) -> some View {
        Button { open(log) } label: {
            HStack(spacing: 14) {
                BentoIcon(symbol: "doc.text", size: 17).foregroundStyle(palette.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text(log.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(log.displayName + " · " + observationDate(log.date)).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    LogAssessmentBadge(log: log)
                    Text(log.analysisQualityLabel).font(.system(size: 10)).foregroundStyle(palette.secondary)
                }.frame(minWidth: 116, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(FlightUIFormat.duration(log.durationSeconds)).font(.system(size: 11)).monospacedDigit()
                    Text("enregistrées").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }.frame(width: 86, alignment: .trailing)
                BentoIcon(symbol: "arrow.up.right", size: 12).foregroundStyle(palette.secondary)
            }.padding(.vertical, 17).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focusedControl, equals: .historyLog(log.id)).disabled(busy)
            .help(log.assessment.reason).accessibilityLabel("Ouvrir \(log.fileName), \(log.displayName), \(date(log.date)), \(log.assessment.label), \(log.analysisQualityLabel)")
    }
    private var alertProfile: some View {
        let counts = totals?.familyLogCounts ?? [:]
        let axes = views.state.profileAxes ?? Array(counts.keys.sorted().prefix(8))
        let allFamilies = AlertProfile06.families(counts: counts, selectedAxes: axes)
        return panel {
            HStack {
                Text("Profil des alertes").font(.system(size: 16, weight: .semibold))
                LibraryHelpButton(title: "Profil des alertes", text: LibraryHelp.profile + " Jusqu’à huit axes sont conservés, même à zéro. L’échelle est ajustée aux comptes affichés ; le nombre de logs lus reste indiqué.")
                Spacer()
                Text(quantity(allFamilies.count, "famille")).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    AlertProfileChart06(axes: axes, counts: counts, denominator: totals?.validLogs ?? 0).frame(minWidth: 260, maxWidth: 390).frame(height: axes.count >= 3 ? 210 : 125).accessibilityHidden(true)
                    profileFamilyList(allFamilies, counts: counts).frame(minWidth: 220, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) {
                    AlertProfileChart06(axes: axes, counts: counts, denominator: totals?.validLogs ?? 0).frame(height: axes.count >= 3 ? 210 : 125).accessibilityHidden(true)
                    profileFamilyList(allFamilies, counts: counts)
                }
            }
            Text("\(quantity(totals?.validLogs ?? 0, "log")) lus · échelle visuelle de 0 à \(AlertProfile06.displayMaximum(counts: counts, denominator: totals?.validLogs ?? 0)) logs")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
            DisclosureGroup("Personnaliser les axes", isExpanded: $profileExpanded) {
                HStack {
                    Menu("Choisir les axes") {
                        ForEach(Array(Set(counts.keys).union(axes)).sorted(), id: \.self) { family in
                            Button((axes.contains(family) ? "✓ " : "") + family) {
                                var selected = axes
                                if let index = selected.firstIndex(of: family) { selected.remove(at: index) }
                                else if selected.count < 8 { selected.append(family) }
                                edit { try views.setProfileAxes(selected) }
                            }
                        }
                        Button("Axes automatiques") { edit { try views.setProfileAxes(Array(counts.keys.sorted().prefix(8))) } }
                    }
                    if axes.count > 1 {
                        Menu("Ordre des axes") {
                            ForEach(Array(axes.enumerated()), id: \.element) { index, family in
                                Button("↑ Monter « \(family) »") { moveAxis(family, in: axes, by: -1) }.disabled(index == 0)
                                Button("↓ Descendre « \(family) »") { moveAxis(family, in: axes, by: 1) }.disabled(index == axes.count - 1)
                            }
                        }
                    }
                }.padding(.top, 10).disabled(library.isReadOnly || busy)
            }.font(.system(size: 11)).accessibilityIdentifier("alerts.profile")
        }
    }
    private func profileFamilyList(_ families: [String], counts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logs concernés par famille").font(.system(size: 11)).foregroundStyle(palette.secondary)
            if families.isEmpty { Text("Aucune famille d’alerte textuelle dans cette sélection.").foregroundStyle(palette.secondary) }
            ForEach(Array(families.prefix(profileExpanded ? families.count : 6)), id: \.self) { family in
                Button { var scope = views.state.activeScope; scope.families = [family]; edit { try views.chooseScope(scope) } } label: {
                    HStack(spacing: 9) {
                        Circle().fill(palette.mint).frame(width: 5, height: 5)
                        Text(family).lineLimit(1); Spacer()
                        Text("\(counts[family] ?? 0) / \(totals?.validLogs ?? 0)").font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary)
                        BentoIcon(symbol: "chevron.right", size: 9).foregroundStyle(palette.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy).accessibilityLabel("Filtrer \(family), \(counts[family] ?? 0) logs sur \(totals?.validLogs ?? 0)")
            }
            if families.count > 6 && !profileExpanded { Button("Voir toutes les familles") { profileExpanded = true }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)) }
        }
    }
    private var alerts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                alertGroups.frame(minWidth: 350, maxWidth: .infinity)
                alertInspector.frame(minWidth: 280, maxWidth: 440)
            }
            VStack(alignment: .leading, spacing: 18) { alertGroups; alertInspector }
        }
    }
    private var alertGroups: some View {
        panel {
            HStack { Text("Messages regroupés").font(.system(size: 16, weight: .semibold)); LibraryHelpButton(title: "Alertes enregistrées", text: LibraryHelp.alerts); Spacer() }
            Text("\(quantity(library.groupPage?.total ?? 0, "groupe")) · tous niveaux disponibles").font(.system(size: 11)).foregroundStyle(palette.secondary)
            if library.groupPage?.groups.isEmpty != false { Text("Aucun message dans cette sélection. Modifiez les filtres ou consultez les événements PX4.").foregroundStyle(palette.secondary).padding(.vertical, 12) }
            ForEach(library.groupPage?.groups ?? []) { group in
                Button { selectedGroup = group; groupCursors = [nil]; library.loadOccurrences(groupID: group.id) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(groupColor(group)).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(group.family + " · " + group.level).font(.system(size: 10)).foregroundStyle(palette.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(quantity(group.logCount, "log")).font(.system(size: 11)).monospacedDigit()
                            Text(quantity(group.messageCount, "message")).font(.system(size: 10)).foregroundStyle(palette.secondary)
                        }
                    }.padding(10).background(selectedGroup?.id == group.id ? palette.raised : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy).accessibilityAddTraits(selectedGroup?.id == group.id ? .isSelected : [])
                Divider()
            }
            if selectedGroup == nil { pagination(cursors: $groupCursors, next: library.groupPage?.nextCursor) { library.loadAuxiliary(kind: "groups", cursor: $0) } }
            else { Button("Tous les groupes") { selectedGroup = nil; groupCursors = [nil]; library.loadHistory() } }
        }
    }
    private func groupColor(_ group: LibraryGroup) -> Color { group.priority >= 5 ? palette.red : group.priority >= 4 ? palette.amber : palette.muted }
    private var alertInspector: some View {
        panel {
            if let group = selectedGroup {
                HStack { BentoStatus(label: group.level, color: groupColor(group)); Spacer(); Text(group.family).font(.system(size: 10)).foregroundStyle(palette.secondary) }
                Text(group.title).font(.system(size: 19, weight: .semibold)).tracking(-0.5).textSelection(.enabled)
                Text("\(quantity(group.logCount, "log")) · \(quantity(group.droneCount, "drone")) · \(quantity(library.occurrencePage?.total ?? group.messageCount, "occurrence"))").font(.system(size: 11)).foregroundStyle(palette.secondary)
                if let first = library.occurrencePage?.occurrences.first { AlertExplanationView(message: first.message) }
                ViewThatFits(in: .horizontal) {
                    HStack { maskActions(group) }
                    VStack(alignment: .leading, spacing: 9) { maskActions(group) }
                }
                Divider()
                Text("Messages d’origine").font(.system(size: 13, weight: .semibold))
                ForEach(library.occurrencePage?.occurrences ?? []) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(item.message.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(occurrenceLabel(item)).font(.system(size: 10)).foregroundStyle(palette.secondary)
                        DisclosureGroup("Classification du message") {
                            MessageClassificationControl(message: item.message, store: library.annotations, families: Array(totals?.familyLogCounts.keys ?? Dictionary<String, Int>().keys)).padding(.top, 8)
                        }.font(.system(size: 10))
                        Button("Voir le log", systemImage: "arrow.up.right") {
                            var scope = SelectionScope(); scope.logIDs = [item.logID]; edit { try views.chooseScope(scope); page = .history }
                        }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
                    }.padding(.vertical, 5)
                    Divider()
                }
                pagination(cursors: $groupCursors, next: library.occurrencePage?.nextCursor) { library.loadOccurrences(groupID: group.id, cursor: $0) }
            } else {
                BentoIcon(symbol: "text.book.closed", size: 23).foregroundStyle(palette.secondary)
                Text("Comprendre un message").font(.system(size: 19, weight: .semibold)).tracking(-0.5)
                Text("Choisissez un groupe pour consulter son explication, ses messages d’origine et les logs concernés.").foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                BentoStatus(label: "ERROR et plus · à examiner en priorité", color: palette.red)
                BentoStatus(label: "WARN · point d’attention", color: palette.amber)
                BentoStatus(label: "INFO et autres · contexte enregistré", color: palette.muted)
                Text("La sévérité vient des messages PX4. Elle ne confirme pas une panne matérielle.").font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private func maskActions(_ group: LibraryGroup) -> some View {
        Button("Masquer…", systemImage: "eye.slash") { masking = true; maskGroup = group }
            .disabled(group.classKeys?.isEmpty != false || group.classKeysComplete != true || library.isReadOnly || mutationBusy).focused($focusedControl, equals: .mask(true))
        Button("Rétablir…", systemImage: "eye") { masking = false; maskGroup = group }
            .disabled(group.classKeys?.isEmpty != false || group.classKeysComplete != true || library.isReadOnly || mutationBusy).focused($focusedControl, equals: .mask(false))
    }
    private var map: some View {
        VStack(alignment: .leading, spacing: 14) {
            FleetMapView(logs: library.mapPage?.snapshot.logs ?? [], showsHeading: false, onSelectLog: open)
            Text("80 trajectoires récentes au maximum · les compteurs et les exports couvrent toute la sélection. Les positions proviennent des logs.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var registry: some View {
        VStack(alignment: .leading, spacing: 18) {
            panel {
                ViewThatFits(in: .horizontal) {
                    HStack { registryHeading; Spacer(); registrySearchControls }
                    VStack(alignment: .leading, spacing: 12) { registryHeading; registrySearchControls }
                }
                ForEach(library.dronePage?.drones ?? []) { drone in
                    registryRow(drone)
                    Divider()
                }
                if library.dronePage?.drones.isEmpty != false {
                    Text(registrySearch.isEmpty ? "Aucune identité enregistrée. Importez des logs ou collectez les drones de votre GCS." : "Aucun résultat pour cette recherche.").foregroundStyle(palette.secondary).padding(.vertical, 16)
                }
                pagination(cursors: $registryCursors, next: library.dronePage?.nextCursor) { library.loadAuxiliary(kind: "drones", cursor: $0, search: registrySearch) }
            }
            Text("Le registre reste global. Les numéros de stock sont vos repères ; ils ne fusionnent pas les identités techniques des contrôleurs.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var registryHeading: some View {
        HStack(spacing: 8) {
            Text("\(library.dronePage?.total ?? 0) drones enregistrés").font(.system(size: 16, weight: .semibold))
            LibraryHelpButton(title: "Registre des drones", text: LibraryHelp.drones)
        }
    }
    private var registrySearchControls: some View {
        HStack(spacing: 8) {
            TextField("Numéro, nom ou identité", text: $registrySearch).textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 240)
                .onSubmit { searchRegistry() }
            Button { searchRegistry() } label: { BentoIcon(symbol: "magnifyingglass", size: 14) }
                .accessibilityLabel("Rechercher un drone").disabled(busy)
        }
    }
    private func searchRegistry() { registryCursors = [nil]; library.loadAuxiliary(kind: "drones", search: registrySearch) }
    private func registryRow(_ drone: LibraryDrone) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { registryIdentity(drone); Spacer(); registryActions(drone) }
                VStack(alignment: .leading, spacing: 12) { registryIdentity(drone); registryActions(drone) }
            }
            DisclosureGroup("Identité technique et provenance") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(drone.id).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Text(drone.lastGCSDate.map { "Dernière observation GCS : " + observationDate($0) + " · " + (drone.lastGCSSource == "gcs-telemetry" ? "télémétrie reçue" : "provenance non renseignée") } ?? "Aucune observation GCS datée conservée")
                    Text(drone.sourceCheckedAt.map { "Sources au contrôle du " + observationDate($0) + " : " + sourceStatus(drone.sourceStatus) } ?? "Disponibilité des sources non vérifiée à une date connue")
                }.font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.top, 8)
            }.font(.system(size: 10)).foregroundStyle(palette.secondary)
        }.padding(.vertical, 14)
    }
    private func registryIdentity(_ drone: LibraryDrone) -> some View {
        HStack(spacing: 13) {
            BentoIcon(symbol: "drone", size: 25).foregroundStyle(palette.secondary).frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(drone.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(drone.logCount == 0 ? "Aucun log enregistré · état non déterminé" : "\(quantity(drone.logCount, "log")) · \(quantity(drone.alertLogCount, "log")) avec alerte · dernier : \(date(drone.lastDate))")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func registryActions(_ drone: LibraryDrone) -> some View {
        HStack(spacing: 8) {
            Button("Historique") { var scope = SelectionScope(); scope.droneKeys = [drone.id]; edit { try views.chooseScope(scope); page = .history } }.disabled(drone.logCount == 0 || busy)
            Button(drone.stockNumber == nil ? "Identifier" : "Modifier") { identity = DroneIdentityTarget(key: drone.id, sourceName: drone.name) }.disabled(library.isReadOnly || busy)
        }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
    }
    private var storagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    storageOverview.frame(minWidth: 320, maxWidth: .infinity)
                    storageBackup.frame(minWidth: 320, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) {
                    storageOverview
                    storageBackup
                }
            }
            storageSources
        }
        .onAppear { storage.load() }
    }

    private var storageOverview: some View {
        panel {
            HStack(spacing: 12) {
                Text("Espace de la bibliothèque").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                Spacer(minLength: 4)
                BentoIcon(symbol: "externaldrive", size: 20).foregroundStyle(palette.secondary)
            }
            Text("Les ULog sont conservés dans leurs dossiers sources.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            if let info = storage.info {
                if storage.errorMessage != nil {
                    Text("Dernière vérification conservée · actualisation impossible")
                        .font(.system(size: 11)).foregroundStyle(palette.amber)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 0)], spacing: 18) {
                    metric("Logs indexés", value: info.logCount, note: "\(quantity(info.sourceCount, "chemin")) \(info.sourceCount == 1 ? "conservé" : "conservés")")
                    metric("Analyses détaillées", value: info.detailCacheCount, note: bytes(info.detailCacheBytes) + " en cache")
                    metric("Base de données", value: bytes(info.databaseBytes), note: "Sur ce Mac", help: "Le cache peut être nettoyé sans supprimer les ULog. La taille affichée est celle de la base ; les fichiers ULog sont conservés dans leurs dossiers sources.")
                    metric("Révisions conservées", value: info.analysisRevisionCount.map { $0.formatted() } ?? "—", note: info.analysisRevisionBytes.map(bytes) ?? "Taille inconnue", help: "Historique des analyses : limite de 512 Mio de données compressées. Aucune ancienne analyse n’est supprimée automatiquement.")
                }
                .padding(.vertical, 12)
                Divider()
                Text("Le cache et les anciennes analyses restent récupérables après nettoyage.")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            } else if storage.isLoading {
                ProgressView("Vérification de la bibliothèque…").controlSize(.small).padding(.vertical, 20)
            } else if let error = storage.errorMessage {
                Label("Le stockage n’a pas pu être vérifié.", systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .medium))
                Text(error).font(.system(size: 11)).foregroundStyle(palette.secondary).textSelection(.enabled)
                Button("Réessayer", systemImage: "arrow.clockwise") { storage.load() }.disabled(busy)
            } else {
                Text("Aucun log enregistré").font(.system(size: 15, weight: .semibold)).padding(.top, 10)
                Text("Importez un dossier ou collectez les logs de vos drones pour consulter les sources et le cache.")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
        }
    }

    private var storageBackup: some View {
        panel {
            HStack(spacing: 8) {
                Text("Sauvegarder et retrouver").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                LibraryHelpButton(title: "Sauvegardes", text: "Analyses + réglages conserve la bibliothèque et ses réglages. Sauvegarde complète ajoute les ULog accessibles. La restauration importe une sauvegarde vérifiée et conserve une récupération des données remplacées. Aucune source d’origine n’est supprimée.")
            }
            Text("Une copie vérifiée de votre bibliothèque.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            Text("La sauvegarde complète inclut les fichiers ULog accessibles. Les fichiers absents sont signalés.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) { backupButtons }
                VStack(alignment: .leading, spacing: 9) { backupButtons }
            }
            .disabled(mutationBusy || library.isReadOnly || library.isExporting || storage.isWorking)
            if library.isMaintainingLibrary || storage.isWorking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(storage.message ?? "Vérification et traitement…").font(.system(size: 11))
                    Spacer(minLength: 4)
                    Button("Arrêter", systemImage: "stop") { maintenanceTask?.cancel(); storage.cancel() }
                }
            }
            if let message = storage.message { Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
            if let error = storage.errorMessage { notice(error, symbol: "exclamationmark.triangle") }
            if let recovery = storage.recoveryURL {
                Button("Voir le dossier de récupération", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) }
            }
            Text("La restauration vérifie l’archive et conserve l’état remplacé dans un dossier de récupération.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storageSources: some View {
        panel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    storageSourcesHeading
                    Spacer(minLength: 8)
                    storageSourceHeaderActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    storageSourcesHeading
                    storageSourceHeaderActions
                }
            }
            Text("\(quantity(selectedStorageLogs.count, "log")) \(selectedStorageLogs.count == 1 ? "choisi" : "choisis") · sélection conservée sur toutes les pages")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            if storage.isLoading, storage.info != nil { ProgressView("Chargement des sources…").controlSize(.small) }
            ForEach(storage.info?.sources ?? []) { source in
                HStack(spacing: 12) {
                    Toggle("Choisir", isOn: Binding(get: { selectedStorageLogs.contains(source.logID) }, set: {
                        if $0 { selectedStorageLogs.insert(source.logID) } else { selectedStorageLogs.remove(source.logID) }
                    }))
                    .labelsHidden().accessibilityLabel("Choisir " + URL(fileURLWithPath: source.path).lastPathComponent)
                    BentoIcon(symbol: "folder", size: 17).foregroundStyle(palette.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(URL(fileURLWithPath: source.path).lastPathComponent)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled).help(source.path)
                        if let size = source.sizeBytes {
                            Text(bytes(size)).font(.system(size: 10)).foregroundStyle(palette.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    BentoStatus(label: source.availability.label,
                                color: source.availability.state == "present" ? palette.mint : source.availability.state == "unknown" ? palette.secondary : palette.amber)
                        .help(source.availability.detail ?? source.path)
                }
                .padding(.vertical, 9)
                Divider()
            }
            if let info = storage.info {
                if info.sources.isEmpty { Text("Aucun chemin source enregistré.").font(.system(size: 12)).foregroundStyle(palette.secondary) }
                HStack(spacing: 12) {
                    Button("Précédent", systemImage: "chevron.left") {
                        guard storageOffsets.count > 1 else { return }
                        storageOffsets.removeLast(); storage.load(offset: storageOffsets.last ?? 0)
                    }
                    .disabled(storageOffsets.count <= 1 || storage.isLoading || storage.isWorking || busy)
                    Text(info.sources.isEmpty ? "0 / \(info.sourceCount) sources" : "\(storage.currentOffset + 1)–\(storage.currentOffset + info.sources.count) / \(info.sourceCount) sources")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Spacer(minLength: 4)
                    Button("Suivant", systemImage: "chevron.right") {
                        guard let next = info.nextOffset else { return }
                        storageOffsets.append(next); storage.load(offset: next)
                    }
                    .disabled(info.nextOffset == nil || storage.isLoading || storage.isWorking || busy)
                }
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choisissez les logs à archiver ou les données calculées à nettoyer. Les ULog et la dernière analyse sont conservés ; les données retirées restent récupérables.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    HStack(spacing: 9) {
                        Button("Choisir cette page") { selectedStorageLogs.formUnion((storage.info?.sources ?? []).map(\.logID)) }
                        Button("Tout désélectionner") { selectedStorageLogs = [] }
                    }
                    .disabled(storage.isWorking || storage.isLoading || busy)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 9) { sourceActions }
                        VStack(alignment: .leading, spacing: 9) { sourceActions }
                    }
                    .disabled(mutationBusy || library.isReadOnly || storage.isWorking || storage.isLoading)
                    ForEach(storage.info?.recoveries ?? []) { recovery in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(recovery.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                    .help(library.storageDirectory.appendingPathComponent(recovery.name).path)
                                Text(bytes(recovery.sizeBytes)).font(.system(size: 10)).foregroundStyle(palette.secondary)
                            }
                            Spacer(minLength: 4)
                            if recovery.name.hasPrefix("recovery-cache-") {
                                Button("Restaurer le cache", systemImage: "arrow.counterclockwise") {
                                    storage.perform(command: "restore-cache", recovery: library.storageDirectory.appendingPathComponent(recovery.name))
                                }
                                .disabled(mutationBusy || library.isReadOnly || storage.isWorking)
                            }
                        }
                    }
                }
                .padding(.top, 14)
            } label: {
                HStack(spacing: 7) {
                    Text("Gestion avancée · cache, archivage et récupération").font(.system(size: 11, weight: .medium))
                    LibraryHelpButton(title: "Nettoyer les données calculées", text: "Le nettoyage déplace le cache détaillé et les anciennes révisions des logs choisis dans un dossier de récupération. Le dernier résumé et la dernière analyse détaillée de chaque log restent dans l’historique. Les ULog sont conservés ; aucun gain disque n’est garanti sans compactage.")
                }
            }
        }
    }

    private var storageSourcesHeading: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("Disponibilité des sources").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                LibraryHelpButton(title: "Sources et cache", text: "Retrouver un dossier associe des ULog dont le SHA256 correspond aux analyses conservées. Archiver copie et vérifie les ULog choisis dans un autre dossier. Nettoyer déplace le cache et les anciennes révisions dans une récupération ; le dernier résumé, la dernière analyse détaillée et les ULog restent disponibles.")
            }
            Text("Le retrait d’une carte SD ne retire pas vos analyses.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }

    private var storageSourceHeaderActions: some View {
        HStack(spacing: 9) {
            sourceReconnectAction
                .disabled(mutationBusy || library.isReadOnly || storage.isWorking || storage.isLoading)
            Button("Sources d’import…", systemImage: "folder.badge.gearshape") { showingSources = true }.help(LibraryHelp.sources)
        }
    }

    private var sourceReconnectAction: some View {
        Button("Retrouver un dossier…", systemImage: "magnifyingglass") {
            if let folder = selectFolder("Retrouver les sources") { storage.perform(command: "reassociate", folder: folder) }
        }
        .help("Cherche des ULog dont le SHA256 correspond aux analyses conservées et associe les chemins retrouvés.")
    }

    @ViewBuilder private var sourceActions: some View {
        Button("Archiver les logs choisis…", systemImage: "folder") {
            if let folder = selectFolder("Copier les ULog sélectionnés") { storage.perform(command: "archive", logIDs: selectedStorageLogs.sorted(), destination: folder) }
        }
        .disabled(selectedStorageLogs.isEmpty)
        .help("Copie et vérifie les ULog choisis dans un autre dossier. Les originaux sont conservés.")
        Button("Nettoyer cache et anciennes analyses", systemImage: "trash") { storage.perform(command: "clean-cache", logIDs: selectedStorageLogs.sorted()) }
            .disabled(selectedStorageLogs.isEmpty)
            .help("Déplace le cache et les anciennes révisions dans une récupération. Le dernier résumé, la dernière analyse détaillée et les ULog restent disponibles.")
    }

    @ViewBuilder private var backupButtons: some View {
        Button("Sauvegarde complète…", systemImage: "arrow.down.to.line") { backup(includeULog: true) }
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true))
        Button("Analyses + réglages…", systemImage: "doc.text") { backup(includeULog: false) }
        Button("Restaurer…", systemImage: "arrow.counterclockwise") { previewRestore() }.focused($focusedControl, equals: .restore)
    }

    private var reportPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    reportConfiguration.frame(width: 310)
                    reportSummary.frame(minWidth: 310, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) { reportConfiguration; reportSummary }
            }
            if library.isExporting {
                panel {
                    if let progress = library.reportProgress {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).tint(palette.mint)
                        Text("\(progress.completed) / \(progress.total) · \(progress.current)").font(.system(size: 12))
                    } else { ProgressView("Capture de la bibliothèque…") }
                }
            }
            if let report = library.lastReportExport {
                panel {
                    HStack(spacing: 9) { BentoIcon(symbol: "checkmark.circle", size: 19); Text("Rapport prêt").font(.system(size: 15, weight: .semibold)) }
                    Text("\(quantity(report.logCount, "log")) · \(quantity(report.messageCount, "message")) · révision \(report.revision)")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    HStack(spacing: 9) {
                        Button("Ouvrir le rapport", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.open(report.entryPoint) }
                        Button("Voir les fichiers", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([report.destination]) }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                BentoIcon(symbol: "info.circle", size: 14)
                Text("L’aperçu est vérifié avant génération. Le rapport distingue les alertes, la qualité des logs et le temps de vol.")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.secondary)
        }
        .task(id: reportPreviewKey) { refreshReportPreview() }
        .onDisappear { reportPreview.cancel() }
    }

    private var reportConfiguration: some View {
        panel {
            Text("Composer le rapport").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
            Text("Choisissez les données à inclure.").font(.system(size: 11)).foregroundStyle(palette.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Périmètre").font(.system(size: 11)).foregroundStyle(palette.secondary)
                Picker("Périmètre", selection: $reportMode) {
                    Text("Sélection active").tag(ReportScopeManifest.Mode.selection)
                    Text("Bibliothèque complète").tag(ReportScopeManifest.Mode.full)
                }
                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Format").font(.system(size: 11)).foregroundStyle(palette.secondary)
                Picker("Format", selection: $reportFormat) {
                    Text("HTML interactif + JSON").tag(ReportExportOptions.Format.html)
                    Text("Données JSON").tag(ReportExportOptions.Format.json)
                }
                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Détails déjà calculés").font(.system(size: 12, weight: .medium))
                    Text("Fiches, paramètres, événements et séries disponibles.").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 4)
                Toggle("Détails déjà calculés", isOn: $cachedDetails).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(palette.mint)
                LibraryHelpButton(title: "Détails déjà calculés", text: "Ajoute les fiches, paramètres, événements et séries présents dans le cache sans réanalyse. Leur couverture sera vérifiée lors de la capture ; les détails absents ne sont pas inventés.")
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Anonymiser pour le partage").font(.system(size: 12, weight: .medium))
                    Text("Retirer identités, chemins et positions.").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 4)
                Toggle("Anonymiser pour le partage", isOn: $sharedReport).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(palette.mint)
                LibraryHelpButton(title: "Synthèse anonymisée", text: "Retire identités, chemins, coordonnées, textes libres et métadonnées brutes de toutes les pièces. Les comptes sont conservés.")
            }
            Text(sharedReport ? "Partage · identités, chemins, coordonnées, textes libres et métadonnées brutes retirés." : "Usage interne · identités, chemins et positions inclus.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
            DisclosureGroup("Contenu et fichiers joints") {
                VStack(alignment: .leading, spacing: 9) {
                    Text(cachedDetails ? "Les fiches déjà calculées seront ajoutées sans réanalyse. La couverture des paramètres, événements et séries sera vérifiée lors de la capture ; elle n’est pas encore connue ici." : "Le rapport inclut les résumés et les messages sélectionnés. Les fiches détaillées, paramètres, événements et séries ne sont pas ajoutés.")
                    Text("Si le HTML dépasse 10 Mio, une synthèse et les données intégrales sont fournies dans le même dossier, avec un manifeste de vérification. Les messages ne sont jamais tronqués silencieusement.")
                    Text("Taille finale inconnue avant génération. Les fichiers ULog originaux ne sont pas copiés dans le rapport.")
                }
                .font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.top, 10)
            }
            .font(.system(size: 11)).foregroundStyle(palette.secondary)
            Divider()
            Button("Générer le rapport…", systemImage: "doc.badge.plus") { exportReport() }
                .buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true))
                .disabled(library.isExporting || mutationBusy || library.isReadOnly || reportPreview.isLoading || (reportPreview.preview?.totals.logs ?? 0) == 0)
                .accessibilityIdentifier("reports.generate")
            if library.isExporting { Button("Arrêter", systemImage: "stop") { library.cancelExport() } }
        }
    }

    private var reportSummary: some View {
        panel {
            HStack(spacing: 9) {
                Text("Aperçu du rapport").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                Spacer(minLength: 4)
                BentoIcon(symbol: "doc.text", size: 19).foregroundStyle(palette.secondary)
            }
            Text(reportFormat == .html ? "Synthèse du HTML exporté" : "Contenu des données JSON exportées")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            if reportPreview.isLoading {
                ProgressView("Vérification du périmètre…").controlSize(.small).padding(.vertical, 28)
            } else if let preview = reportPreview.preview {
                reportDocument(preview)
                HStack(spacing: 6) {
                    BentoStatus(label: "Périmètre vérifié à \(preview.checkedAt.formatted(date: .omitted, time: .shortened))", color: palette.mint)
                    LibraryHelpButton(title: "Périmètre vérifié", text: "Révision \(preview.revision) · \(quantity(preview.request.query.maskedMessageKeys.count, "règle")) de masquage. \(quantity(preview.totals.provisionalDrones, "identité")) \(preview.totals.provisionalDrones == 1 ? "provisoire, comptée" : "provisoires, comptées") à part. Le périmètre est vérifié à nouveau avant la génération.")
                }
                if preview.totals.logs == 0 {
                    Text("Aucun log dans ce périmètre. Choisissez une autre sélection ou la bibliothèque complète.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            } else if let issue = reportPreview.error {
                Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 12)).textSelection(.enabled)
                Button("Réessayer", systemImage: "arrow.clockwise") { refreshReportPreview() }.disabled(busy)
            } else if reportPreviewWasCancelled {
                Text("Lecture annulée · le périmètre du rapport n’a pas été vérifié.").font(.system(size: 12)).foregroundStyle(palette.secondary)
                Button("Reprendre la lecture", systemImage: "play") { refreshReportPreview() }.disabled(busy)
            }
        }
    }

    private func reportDocument(_ preview: ReportPreview) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("kataLOG").font(.system(size: 21, weight: .semibold)).tracking(-1)
                Spacer(minLength: 4)
                Text("RAPPORT DE FLOTTE").font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(palette.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Votre flotte, en un coup d’œil.").font(.system(size: 22, weight: .semibold)).tracking(-0.7)
                Text(preview.request.scopeDescription).font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], alignment: .leading, spacing: 16) {
                reportDocumentMetric("Drones scannés", value: preview.totals.scannedDrones.formatted())
                reportDocumentMetric("Logs dans le rapport", value: preview.totals.logs.formatted())
                reportDocumentMetric("Temps de vol", value: preview.totals.measuredFlightSeconds.map(FlightUIFormat.duration) ?? "Indisponible")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Familles d’alertes").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("\(quantity(preview.totals.alertLogs, "log")) \(preview.totals.alertLogs == 1 ? "concerné" : "concernés")")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                ForEach(preview.totals.familyLogCounts.keys.sorted {
                    let left = preview.totals.familyLogCounts[$0] ?? 0
                    let right = preview.totals.familyLogCounts[$1] ?? 0
                    return left == right ? $0 < $1 : left > right
                }.prefix(8).map { $0 }, id: \.self) { family in
                    HStack(spacing: 10) {
                        Text(family).font(.system(size: 11))
                        Spacer(minLength: 4)
                        Text(quantity(preview.totals.familyLogCounts[family] ?? 0, "log"))
                            .font(.system(size: 10)).foregroundStyle(palette.secondary).monospacedDigit()
                    }
                }
                if preview.totals.familyLogCounts.isEmpty {
                    Text("Aucune famille d’alerte dans ce périmètre.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                if preview.totals.familyLogCounts.count > 8 {
                    Text("8 familles affichées sur \(preview.totals.familyLogCounts.count). Toutes sont conservées dans l’export.")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
            }
            Divider()
            Text("\(quantity(preview.totals.messages, "message")) · \(FlightUIFormat.duration(preview.totals.recordedSeconds)) enregistrées · révision \(preview.revision)")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
            Text("Une famille compte une seule fois par log. Le temps de vol couvre \(preview.totals.measuredFlightLogCount) / \(preview.totals.logs) logs ; la durée enregistrée inclut le temps au sol.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border, lineWidth: 1))
        .padding(12).background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func reportDocumentMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: value == "Indisponible" ? 14 : 20, weight: .semibold)).tracking(-0.5).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { appearanceSettings.frame(minWidth: 340, maxWidth: .infinity); UpdateSettingsView(store: updates, readOnly: library.isReadOnly).frame(minWidth: 280, maxWidth: .infinity) }
                VStack(alignment: .leading, spacing: 18) { appearanceSettings; UpdateSettingsView(store: updates, readOnly: library.isReadOnly) }
            }
            panel {
                HStack(alignment: .top, spacing: 14) {
                    BentoIcon(symbol: "waveform.path.ecg", size: 23).foregroundStyle(palette.secondary)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Diagnostic local").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                        Text("Le journal de KataLog aide à comprendre une connexion, une collecte ou une analyse. Vérifiez le contenu avant de l’exporter.")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Données privées exclues par défaut · aucun envoi automatique.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                Button("Ouvrir le diagnostic", systemImage: "doc.text.magnifyingglass") { makeDiagnostic() }
                    .focused($focusedControl, equals: .diagnostic).accessibilityIdentifier("diagnostic.open")
            }
        }
    }
    private var appearanceSettings: some View {
        panel {
            HStack { Text("Apparence").font(.system(size: 16, weight: .semibold)); Spacer(); BentoIcon(symbol: "circle.lefthalf.filled", size: 17).foregroundStyle(palette.secondary) }
            Text("Le même espace de travail, en clair ou en sombre.").foregroundStyle(palette.secondary)
            WorkspaceThemeChoices(selection: themeSelection, palette: palette).disabled(library.isReadOnly || library.isMaintainingLibrary)
            Text("Système suit le réglage de macOS. Votre choix est conservé au redémarrage.").font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 205, alignment: .top)
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
        BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 14, content: content)
        }
    }
    private func notice(_ text: String, symbol: String) -> some View { Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func metric(_ title: String, value: Int, note: String) -> some View { metric(title, value: value.formatted(), note: note) }
    private func metric(_ title: String, value: String, note: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: value == "Indisponible" ? 15 : 27, weight: .semibold)).tracking(-0.6).monospacedDigit()
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
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Date inconnue" }
        return RegistryObservationFormat.date(value).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? value
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
    private func refreshReportPreview() {
        reportPreviewWasCancelled = false
        reportPreview.load(library: library, mode: reportMode, options: reportOptions)
    }
    private func makeDiagnostic() {
        diagnostics.load(report: currentDiagnosticReport()); showingDiagnostic = true
    }
    private func currentDiagnosticReport() -> DiagnosticReport {
        var counts = ["masks": views.state.maskedMessageKeys.count, "savedViews": views.state.views.count]
        var scopes: [String: DiagnosticReport.CountScope] = ["masks": .application, "savedViews": .application]
        if let jobCount = gcs.diagnosticJobCount { counts["jobs"] = jobCount; scopes["jobs"] = .application }
        if let totals { counts["logs"] = totals.logs; counts["messages"] = totals.messages; counts["identities"] = totals.droneCount; scopes["logs"] = .activeSelection; scopes["messages"] = .activeSelection; scopes["identities"] = .activeSelection }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine")
        return DiagnosticReport(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development", operations: ["import": library.isImporting, "collection": gcs.isBusy, "export": library.isExporting, "maintenance": library.isMaintainingLibrary, "readOnly": library.isReadOnly, "gcsConnected": gcs.isConnected], counts: counts, countScope: scopes, runtimeBundled: FileManager.default.isExecutableFile(atPath: helper.path))
    }
}

/// A delayed hint, not a timeout: large libraries may keep reading normally.
struct LibraryReadRecoveryNotice: View {
    let requestID: String
    let isCancelling: Bool
    let palette: Palette
    let cancel: () -> Void
    var delay: Duration = .seconds(12)
    @State private var isDelayed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isDelayed || isCancelling {
                VStack(alignment: .leading, spacing: 12) {
                    Text(isCancelling ? "Arrêt de la lecture…" : "La lecture prend plus de temps que prévu").font(.system(size: 14, weight: .semibold))
                    Text("macOS peut attendre votre accord pour lire un dossier. Si une demande d’accès à KataLog est affichée, répondez-y. Un fichier sur le réseau ou dans le cloud peut aussi ralentir la lecture.")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Vous pouvez annuler, puis choisir à nouveau le dossier source avec « Importer un dossier ». Vos analyses restent conservées.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Annuler la lecture", systemImage: "stop.circle", action: cancel)
                        .buttonStyle(WorkspaceActionButtonStyle(palette: palette)).disabled(isCancelling)
                        .accessibilityIdentifier("library.cancel-query")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.border, lineWidth: 1))
                    .accessibilityIdentifier("library.slow-query")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).task(id: requestID) {
            isDelayed = false
            do { try await Task.sleep(for: delay); try Task.checkCancellation(); isDelayed = true }
            catch { /* A completed or replaced query has no delayed notice. */ }
        }
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
    /// Presentation zoom only. Raw counts and the number of readable logs stay unchanged.
    static func displayMaximum(counts: [String: Int], denominator: Int) -> Int {
        guard denominator > 0 else { return 1 }
        let peak = max(0, counts.values.max() ?? 0)
        guard peak > 0 else { return 1 }
        let remainder = peak % 4
        guard remainder > 0, peak <= Int.max - (4 - remainder) else { return peak }
        return peak + 4 - remainder
    }
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
                            let fraction = denominator > 0 ? min(1, max(0, Double(max(0, counts[family] ?? 0)) / Double(AlertProfile06.displayMaximum(counts: counts, denominator: denominator)))) : 0
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
                Path { path in for (index, axis) in axes.enumerated() { let fraction = denominator > 0 ? min(1, Double(max(0, counts[axis] ?? 0)) / Double(AlertProfile06.displayMaximum(counts: counts, denominator: denominator))) : 0; let p = point(index, count, center, radius * fraction); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.fill(palette.mint.opacity(0.15)).overlay(Path { path in for (index, axis) in axes.enumerated() { let p = point(index, count, center, radius * (denominator > 0 ? min(1, Double(max(0, counts[axis] ?? 0)) / Double(AlertProfile06.displayMaximum(counts: counts, denominator: denominator))) : 0)); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.stroke(palette.mint, lineWidth: 1.5))
                ForEach(Array(axes.enumerated()), id: \.element) { index, axis in Text(axis).font(.system(size: 9)).foregroundStyle(palette.secondary).frame(width: 100).position(point(index, count, center, radius + 25)) }
            }
        }
    }
    private func point(_ index: Int, _ count: Int, _ center: CGPoint, _ radius: Double) -> CGPoint { let angle = Double(index) * .pi * 2 / Double(count) - .pi / 2; return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius) }
}
