import AppKit
import SwiftUI
import KataLogCore

@main
struct KataLogApp: App {
    @NSApplicationDelegateAdaptor(KataLogApplicationDelegate.self) private var applicationDelegate
    @StateObject private var library = LibraryStore(pagedNavigation: AppPreviewConfiguration().showReviewUI)
    @StateObject private var gcs = GCSStore()

    var body: some Scene {
        WindowGroup("KataLog") {
            Group { if AppPreviewConfiguration().showReviewUI {
                Workspace06View(library: library, gcs: gcs)
            } else { WorkspaceView(store: library, gcs: gcs) } }
                .onAppear { applicationDelegate.library = library; applicationDelegate.gcs = gcs }
        }
            .defaultSize(width: 1440, height: 980)
    }
}

private enum WorkspacePage: String, CaseIterable, Identifiable {
    case overview = "Vue d’ensemble"
    case map = "Carte"
    case drones = "Drones"
    case alerts = "Alertes"
    case collection = "Collecte GCS"
    case reports = "Rapports"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .map: "map"
        case .drones: "airplane"
        case .alerts: "waveform.path.ecg"
        case .collection: "tray.and.arrow.down"
        case .reports: "doc.text"
        }
    }
}

private func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count > 1 ? "s" : "")"
}

private struct FamilyCount: Identifiable {
    let name: String
    let count: Int
    var aggregate = false
    var id: String { (aggregate ? "aggregate:" : "family:") + name }
}
private struct WorkspaceView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var gcs: GCSStore
    @AppStorage("katalog.darkMode") private var dark = true
    @State private var page: WorkspacePage = ProcessInfo.processInfo.environment["KATALOG_INITIAL_PAGE"] == "collection" ? .collection : ProcessInfo.processInfo.environment["KATALOG_INITIAL_PAGE"] == "map" ? .map : .overview
    @State private var search = ""
    @State private var severityFilter = "Tous"
    @State private var familyFilter: String?
    @State private var droneFilter = "Tous"
    @State private var selectedGroupID: String?
    @State private var allGroups: [AlertGroup] = []
    @State private var showsFlight = false
    @State private var showFamilyCounts = false
    @State private var showingSources = false

    private var palette: Palette { Palette(dark: dark) }
    private var logs: [FlightLog] {
        store.snapshot.logs.filter { droneFilter == "Tous" || $0.annotationKey == droneFilter }
            .sorted { ($0.date, $0.fileName) < ($1.date, $1.fileName) }
    }
    private var validLogs: [FlightLog] { logs.filter { $0.status != "error" } }
    private var scopedSnapshot: FleetSnapshot { var result = store.snapshot; result.logs = logs; return result }
    private var groups: [AlertGroup] {
        guard droneFilter != "Tous" else { return allGroups }
        let selectedLogIDs = Set(logs.map(\.id))
        return allGroups.compactMap { group in
            let occurrences = group.occurrences.filter { selectedLogIDs.contains($0.logID) }
            return occurrences.isEmpty ? nil : AlertGroup(id: group.id, occurrences: occurrences)
        }
    }
    private var visibleGroups: [AlertGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.filter { group in
            let levelMatch = severityFilter == "Tous" || group.level == severityFilter ||
                (severityFilter == "Alertes" && group.isAlert)
            return levelMatch && (familyFilter == nil || group.family == familyFilter) &&
                (query.isEmpty || group.title.localizedCaseInsensitiveContains(query) ||
                 group.family.localizedCaseInsensitiveContains(query) ||
                 group.occurrences.contains { $0.message.text.localizedCaseInsensitiveContains(query) })
        }
    }
    private var selectedGroup: AlertGroup? { visibleGroups.first { $0.id == selectedGroupID } }
    private var priorityGroups: [AlertGroup] { groups.filter(\.isAlert) }
    private var familyLogIDs: [String: Set<String>] {
        var affected: [String: Set<String>] = [:]
        for log in validLogs {
            for message in log.messages where message.isAlert {
                affected[message.family, default: []].insert(log.id)
            }
        }
        return affected
    }
    private var familyCounts: [FamilyCount] {
        familyLogIDs.map { FamilyCount(name: $0.key, count: $0.value.count) }.sorted { $0.name < $1.name }
    }
    private var radarCounts: [FamilyCount] {
        let counts = familyCounts
        guard counts.count > 8 else { return counts }
        let remaining = counts.dropFirst(7).reduce(into: Set<String>()) { result, family in
            result.formUnion(familyLogIDs[family.name] ?? [])
        }
        var label = "Autres familles (regroupées)"
        while counts.contains(where: { $0.name == label }) { label += " · groupe" }
        return Array(counts.prefix(7)) + [FamilyCount(name: label, count: remaining.count, aggregate: true)]
    }
    private var hasFilters: Bool {
        !search.isEmpty || severityFilter != "Tous" || familyFilter != nil || droneFilter != "Tous"
    }
    private var sourceLabel: String {
        let folders = store.snapshot.sourceFolders
        guard let first = folders.first else { return "Bibliothèque locale" }
        return folders.count == 1 ? URL(fileURLWithPath: first).lastPathComponent : "\(folders.count) dossiers sources"
    }
    private var period: String {
        let dates = validLogs.map(\.date).filter { !$0.isEmpty && $0 != "unknown" }.sorted()
        guard let first = dates.first, let last = dates.last else { return "Période non déterminée" }
        return "\(dateLabel(first)) → \(dateLabel(last))"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if page != .collection { pageHeader }
                        importStatus
                        if page == .collection {
                            GCSCollectionView(store: gcs, library: store, dark: dark)
                        } else if page == .drones {
                            drones
                        } else if store.snapshot.logs.isEmpty {
                            emptyLibrary
                        } else {
                            switch page {
                            case .overview: overview
                            case .map: fleetMap
                            case .drones: drones
                            case .alerts: alerts
                            case .collection: EmptyView()
                            case .reports: reports
                            }
                        }
                        libraryFooter
                    }
                    .padding(30)
                    .frame(maxWidth: 1550)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(palette.background)
        }
        .frame(minWidth: 1180, minHeight: 800)
        .preferredColorScheme(dark ? .dark : .light)
        .tint(palette.primary)
        .onAppear { gcs.attach(library: store) }
        .onReceive(store.$snapshot) { snapshot in
            allGroups = snapshot.alertGroups
            if droneFilter != "Tous" && !snapshot.logs.contains(where: { $0.annotationKey == droneFilter }) {
                droneFilter = "Tous"
            }
            reconcileSelection()
        }
        .onChange(of: search) { _, _ in reconcileSelection() }
        .onChange(of: familyFilter) { _, _ in reconcileSelection() }
        .onChange(of: severityFilter) { _, _ in reconcileSelection() }
        .onChange(of: droneFilter) { _, _ in reconcileSelection() }
        .sheet(isPresented: $showsFlight, onDismiss: store.closeFlight) {
            FlightDetailView(store: store)
                .preferredColorScheme(dark ? .dark : .light)
        }
        .sheet(isPresented: $showingSources) { SourcesImportView(library: store, externalBusy: gcs.isBusy).preferredColorScheme(dark ? .dark : .light) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23, weight: .medium))
                Text("kataLOG").font(.system(size: 25, weight: .bold)).tracking(-1.2)
            }
            .foregroundStyle(palette.primary)
            Text("Les traces de votre flotte.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .padding(.top, 7).padding(.bottom, 48)
            eyebrow("ESPACE DE TRAVAIL").padding(.horizontal, 12).padding(.bottom, 12)
            ForEach(WorkspacePage.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 18)
                        Text(item.rawValue).font(.system(size: 12, weight: item == page ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if item == .alerts && !priorityGroups.isEmpty {
                            Text("\(priorityGroups.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5).frame(height: 19)
                                .background(palette.card, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .foregroundStyle(item == page ? palette.primary : palette.secondary)
                    .padding(.horizontal, 12).frame(height: 43)
                    .background(item == page ? palette.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).padding(.bottom, 5)
                .accessibilityIdentifier("navigation.\(item == .collection ? "gcs" : item.id)")
            }
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 11) {
                Button { showingSources = true } label: {
                    HStack(spacing: 7) {
                        Circle().fill(palette.mint).frame(width: 5, height: 5)
                        eyebrow("BIBLIOTHÈQUE LOCALE")
                        Image(systemName: "chevron.right").font(.system(size: 8))
                    }
                }.buttonStyle(.plain).help(LibraryHelp.sources).accessibilityIdentifier("library.sources")
                Text(sourceLabel)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.primary)
                    .lineLimit(2)
                Label("\(store.snapshot.logs.count) logs conservés", systemImage: "internaldrive")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                rule
                Text("Vos données restent sur ce Mac.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 24)
        .frame(width: 204).frame(maxHeight: .infinity)
        .background(palette.sidebar)
        .overlay(alignment: .trailing) { palette.border.frame(width: 1) }
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive")
            Text("Espace local")
            Text("/").padding(.horizontal, 3)
            Button { showingSources = true } label: { Text(sourceLabel).foregroundStyle(palette.primary).lineLimit(1) }
                .buttonStyle(.plain).help(LibraryHelp.sources)
            Spacer()
            Text("PX4 · ULog").font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.trailing, 12)
            Button { dark.toggle() } label: {
                Image(systemName: dark ? "sun.max" : "moon")
                    .font(.system(size: 14)).frame(width: 32, height: 30)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(dark ? "Activer le thème clair" : "Activer le thème sombre")
            .accessibilityLabel(dark ? "Activer le thème clair" : "Activer le thème sombre")
        }
        .font(.system(size: 11)).foregroundStyle(palette.secondary)
        .padding(.horizontal, 30).frame(height: 56)
        .overlay(alignment: .bottom) { palette.border.frame(height: 1) }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(page == .map ? "Carte de la flotte" : page.rawValue)
                    .font(.system(size: 32, weight: .semibold)).tracking(-1.2)
                    .foregroundStyle(palette.primary)
                Text(store.snapshot.logs.isEmpty ? "Importez un dossier pour explorer votre flotte." : page == .map ? "Les lieux et les traces de vos enregistrements." : period)
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            Spacer()
            if !store.snapshot.drones.isEmpty && page != .reports {
                dronePicker
            }
            Button(action: store.chooseFolder) {
                Label("Importer un dossier", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 15).frame(height: 39)
                    .foregroundStyle(palette.background)
                    .background(palette.primary, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).disabled(store.isImporting || store.isLoading)
        }
    }

    private var droneChoices: [(key: String, name: String, count: Int)] {
        Dictionary(grouping: store.snapshot.logs, by: \.annotationKey).map { key, logs in
            (key: key, name: logs.first?.displayName ?? key, count: logs.count)
        }.sorted { ($0.name, $0.key) < ($1.name, $1.key) }
    }
    private var dronePicker: some View {
        Menu {
            Button("Tous les drones") { droneFilter = "Tous" }
            Divider()
            ForEach(droneChoices, id: \.key) { drone in
                Button("\(drone.name) · \(drone.count) logs") { droneFilter = drone.key }
                    .help(drone.key)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                Text(store.snapshot.logs.first { $0.annotationKey == droneFilter }?.displayName ?? "Tous les drones")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.primary)
            .padding(.horizontal, 12).frame(height: 38)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 200)
        .accessibilityLabel("Filtrer la bibliothèque par drone")
    }

    @ViewBuilder private var importStatus: some View {
        if store.isImporting || store.isLoading {
            Surface(palette: palette, padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.isLoading ? "Ouverture de la bibliothèque…" : "Analyse des logs en cours…")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if store.isImporting {
                            Button("Annuler", action: store.cancelImport).buttonStyle(.plain).font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(palette.primary)
                    if let progress = store.progress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        HStack {
                            Text(progress.current).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(progress.completed) / \(progress.total)")
                        }
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        if let error = store.errorMessage {
            statusBanner(error, symbol: "exclamationmark.triangle", color: palette.red)
        }
        if let status = store.statusMessage, !store.isImporting {
            statusBanner(status, symbol: "info.circle", color: palette.secondary)
        }
    }

    private func statusBanner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).foregroundStyle(color)
        .padding(14).background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyLibrary: some View {
        Surface(palette: palette) {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 42, weight: .light)).foregroundStyle(palette.primary)
                Text("L’histoire de votre flotte\ncommence avec ses logs.")
                    .font(.system(size: 30, weight: .semibold)).tracking(-1)
                    .foregroundStyle(palette.primary)
                Text("Choisissez une carte SD ou un dossier contenant plusieurs drones. Les fichiers .ulg sont recherchés dans les sous-dossiers, analysés et conservés dans la bibliothèque locale.")
                    .font(.system(size: 13)).lineSpacing(5).foregroundStyle(palette.secondary)
                    .frame(maxWidth: 570, alignment: .leading)
                HStack(spacing: 25) {
                    Label("Import incrémental", systemImage: "arrow.triangle.2.circlepath")
                    Label("Déduplication des logs", systemImage: "square.on.square")
                    Label("Tous les messages", systemImage: "text.bubble")
                }
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            .padding(28).frame(maxWidth: .infinity, minHeight: 390, alignment: .leading)
        }
    }

    private var overview: some View {
        VStack(spacing: 18) {
            coverage
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 18) {
                    reviewCard.frame(width: (geometry.size.width - 18) * 0.65)
                    radarCard.frame(maxWidth: .infinity)
                }
            }
            .frame(height: 354)
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 18) {
                    overviewAlerts.frame(width: (geometry.size.width - 18) * 0.65)
                    historyCard.frame(maxWidth: .infinity)
                }
            }
            .frame(height: 420)
            if logs.contains(where: { $0.status != "ok" || !$0.coverage.isEmpty || !$0.issues.isEmpty }) {
                coverageNotice
            }
        }
    }

    private var coverage: some View {
        HStack(spacing: 0) {
            coverageMetric("\(scopedSnapshot.scannedDroneCount)", label: "Drones scannés", note: "\(scopedSnapshot.provisionalDroneCount) identités provisoires à part", help: LibraryHelp.drones)
            coverageDivider
            coverageMetric("\(validLogs.count)", label: "logs lisibles")
            coverageDivider
            coverageMetric(duration(scopedSnapshot.totalDurationSeconds), label: "Durée enregistrée", help: LibraryHelp.recordedDuration)
            coverageDivider
            coverageMetric(scopedSnapshot.totalFlightSeconds.map(duration) ?? "Indisponible", label: "Temps de vol cumulé", note: "\(scopedSnapshot.flightLogCount) / \(logs.count) logs", help: LibraryHelp.flightDuration)
            coverageDivider
            coverageMetric("\(validLogs.filter(\.hasAlerts).count) / \(validLogs.count)", label: "logs avec alertes", accent: palette.amber, help: LibraryHelp.alerts)
        }
        .padding(.vertical, 16)
        .background(palette.sidebar.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }

    private func coverageMetric(_ value: String, label: String, accent: Color? = nil, note: String? = nil, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 21, weight: .semibold)).tracking(-0.6).foregroundStyle(accent ?? palette.primary)
            HStack(spacing: 3) {
                Text(label).font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                if let help { LibraryHelpButton(title: label, text: help) }
            }
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var coverageDivider: some View { palette.border.frame(width: 1, height: 24) }

    private var reviewCard: some View {
        Surface(palette: palette) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    cardTitle("À examiner")
                    Spacer()
                    Text("\(priorityGroups.count) groupes d’alertes").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                .padding(.bottom, 20)
                if let group = priorityGroups.first {
                    HStack {
                        levelBadge(group.level)
                        Text(group.family.uppercased()).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary)
                        Spacer()
                        Text(dateLabel(group.lastDate)).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                    }
                    Text(group.title)
                        .font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                        .foregroundStyle(palette.primary).lineLimit(2).padding(.top, 12)
                    Text("\(counted(group.messageCount, "message")) · \(counted(group.logCount, "log")) concernés · \(counted(group.droneIDs.count, "drone"))")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 10)
                    Text(group.occurrences.last?.message.text ?? "")
                        .font(.system(size: 11, design: .monospaced)).lineSpacing(3)
                        .foregroundStyle(palette.secondary).lineLimit(2).padding(.top, 10)
                    Button { openGroup(group.id) } label: {
                        Label("Examiner les messages", systemImage: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.primary)
                    }
                    .buttonStyle(.plain).padding(.top, 15)
                    Spacer(minLength: 12)
                    rule
                    if let recurrent = priorityGroups.max(by: { $0.logCount < $1.logCount }) {
                        Button { openGroup(recurrent.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17)).foregroundStyle(palette.amber)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Le plus récurrent · \(counted(recurrent.logCount, "log"))")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.primary)
                                    Text(recurrent.title).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(palette.secondary)
                            }
                            .padding(.top, 14)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 32, weight: .light)).padding(.top, 18)
                    Text("Aucune alerte textuelle repérée")
                        .font(.system(size: 22, weight: .semibold)).padding(.top, 16)
                    Text("Les messages et les limites de lecture restent disponibles. L’absence de message d’alerte ne confirme pas l’absence de panne.")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(palette.secondary).padding(.top, 12)
                    Spacer()
                }
            }
            .foregroundStyle(palette.primary).frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: 354)
    }

    private var radarCard: some View {
        Surface(palette: palette) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    cardTitle("Profil des alertes texte")
                    LibraryHelpButton(title: "Profil des alertes", text: LibraryHelp.profile)
                    Spacer()
                    Text("0 — \(max(validLogs.count, 1)) logs")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                }
                Text("Logs concernés par famille").font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 6)
                if familyCounts.count >= 3 {
                    RadarChart(palette: palette, axes: radarCounts, maximum: max(validLogs.count, 1)).frame(height: 186)
                } else {
                    VStack(spacing: 15) {
                        ForEach(familyCounts) { family in
                            HStack {
                                Text(family.name)
                                Spacer()
                                Text("\(family.count) / \(validLogs.count)").monospacedDigit()
                            }
                            .font(.system(size: 12)).foregroundStyle(palette.primary)
                            GeometryReader { geometry in
                                Capsule().fill(palette.mint)
                                    .frame(width: geometry.size.width * Double(family.count) / Double(max(validLogs.count, 1)), height: 5)
                            }
                            .frame(height: 5)
                        }
                        if familyCounts.isEmpty { Text("Aucune famille d’alerte repérée").font(.system(size: 12)).foregroundStyle(palette.secondary) }
                    }
                    .frame(height: 186)
                }
                Button { showFamilyCounts = true } label: {
                    Text(familyCounts.count > 8 ? "\(familyCounts.count) familles · 7 axes + autres · voir toutes les valeurs" : familyCounts.map { "\($0.name) \($0.count)" }.joined(separator: " · "))
                        .font(.system(size: 10)).lineSpacing(3).foregroundStyle(palette.secondary).lineLimit(2)
                }
                .buttonStyle(.plain).accessibilityIdentifier("radar.allFamilies")
                .popover(isPresented: $showFamilyCounts) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Logs concernés par famille").font(.headline)
                            ForEach(familyCounts) { family in
                                HStack { Text(family.name); Spacer(); Text("\(family.count) / \(validLogs.count)").monospacedDigit() }
                            }
                            Text("Ordre alphabétique stable. Les familles peuvent se recouper ; Autres familles compte les logs uniques des axes regroupés.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(20)
                    }.frame(width: 380, height: min(440, CGFloat(familyCounts.count * 34 + 100)))
                }
                Spacer(minLength: 10)
                rule
                Text("WARN / ERROR et alarmes repérées.\nLes familles peuvent se recouper.")
                    .font(.system(size: 10)).lineSpacing(4).foregroundStyle(palette.secondary).padding(.top, 10)
            }
        }
        .frame(height: 354)
    }

    private var overviewAlerts: some View {
        Surface(palette: palette) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    cardTitle("Alertes repérées")
                    Spacer()
                    Button { severityFilter = "Alertes"; page = .alerts; reconcileSelection() } label: {
                        Label("Explorer", systemImage: "arrow.right").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("\(priorityGroups.count) groupes · textes identiques, même niveau")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 6).padding(.bottom, 17)
                HStack {
                    eyebrow("SIGNALEMENT")
                    Spacer()
                    eyebrow("LOGS").frame(width: 38, alignment: .trailing)
                }
                .padding(.bottom, 9)
                rule
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(priorityGroups.prefix(30)) { group in
                            Button { openGroup(group.id) } label: { compactGroupRow(group) }
                                .buttonStyle(.plain)
                            rule
                        }
                        if priorityGroups.isEmpty {
                            Text("Aucun signalement pour les drones sélectionnés.")
                                .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 25)
                        }
                    }
                }
                Spacer(minLength: 10)
                Text("Une alerte n’est pas une panne confirmée.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
        }
        .frame(height: 420)
    }

    private func compactGroupRow(_ group: AlertGroup) -> some View {
        HStack(spacing: 11) {
            Circle().fill(levelColor(group.level)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(group.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.primary).lineLimit(1)
                Text("\(group.family) · \(counted(group.messageCount, "message")) · \(counted(group.droneIDs.count, "drone"))")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            Spacer()
            Text("\(group.logCount)").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(palette.primary)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(palette.secondary).padding(.leading, 7)
        }
        .frame(height: 58).contentShape(Rectangle())
    }

    private var historyCard: some View {
        Surface(palette: palette) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    cardTitle("Historique")
                    Spacer()
                    Text("\(logs.count) logs").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Text("Signaux enregistrés et qualité de lecture")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.top, 8).padding(.bottom, 15)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(logs) { log in
                            HStack(spacing: 8) {
                                Button { openFlight(log) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(dateLabel(log.date)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(palette.primary)
                                        Text(log.displayName).font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        LogAssessmentBadge(log: log)
                                        Text(log.assessment.reason).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                                        Text(log.analysisQualityLabel).font(.system(size: 10)).foregroundStyle(palette.secondary)
                                        Text("\(duration(log.durationSeconds)) enregistrées").font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                                    }
                                }
                                .padding(.vertical, 10).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("flight.open.\(log.id)")
                                .help("Ouvrir \(log.fileName) · \(log.assessment.help) · \(log.analysisQualityLabel)")
                                Button {
                                    if let source = log.sourcePaths.first { store.revealSource(source) }
                                } label: {
                                    Image(systemName: "folder").font(.system(size: 11))
                                        .foregroundStyle(palette.secondary).frame(width: 24, height: 30)
                                }
                                .buttonStyle(.plain).disabled(log.sourcePaths.isEmpty)
                                .help("Afficher le fichier source dans le Finder")
                                .accessibilityLabel("Afficher \(log.fileName) dans le Finder")
                                .accessibilityIdentifier("flight.reveal.\(log.id)")
                            }
                        }
                    }
                }
                Text("Durée enregistrée · ne vaut pas temps de vol")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.top, 10)
            }
        }
        .frame(height: 420)
    }

    private var coverageNotice: some View {
        let failed = logs.filter { $0.status == "error" }.count
        let partial = logs.filter { $0.status == "partial" }.count
        let limited = logs.filter { !$0.coverage.isEmpty || !$0.issues.isEmpty }.count
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(palette.amber)
            VStack(alignment: .leading, spacing: 5) {
                Text("Couverture de l’analyse").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.primary)
                Text("\(failed) logs illisibles · \(partial) lectures partielles · \(limited) logs avec des limites signalées.")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Spacer()
            Button("Voir les limites") { page = .reports }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.primary)
        }
        .padding(17).background(palette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 16) {
            filterBar
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 18) {
                    alertTable.frame(maxWidth: .infinity)
                    inspector.frame(width: (geometry.size.width - 18) * 0.39)
                }
            }
            .frame(height: 780)
            Text("Tous les niveaux sont conservés. Le filtre « Alertes » inclut les avertissements, erreurs et alarmes repérées dans les messages INFO.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
                TextField("Rechercher dans tous les messages…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
            .frame(maxWidth: 380)
            Picker("Famille", selection: $familyFilter) {
                Text("Toutes").tag(String?.none)
                ForEach(Set(groups.map(\.family)).union(familyFilter.map { [$0] } ?? []).sorted(), id: \.self) { family in
                    Text(groups.contains { $0.family == family } ? family : "\(family) · aucun résultat")
                        .tag(Optional(family))
                }
            }.pickerStyle(.menu).frame(maxWidth: 220).accessibilityIdentifier("alerts.family")
            filterMenu("Niveau", selection: $severityFilter, values: ["Tous", "Alertes"] + Set(groups.map(\.level)).sorted { LogMessage.rank($0) > LogMessage.rank($1) })
            Spacer(minLength: 0)
            Button("Réinitialiser", action: resetFilters)
                .buttonStyle(.plain).font(.system(size: 11))
                .foregroundStyle(hasFilters ? palette.primary : palette.muted).disabled(!hasFilters)
        }
    }

    private func filterMenu(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button { selection.wrappedValue = value } label: {
                    if selection.wrappedValue == value { Label(value, systemImage: "checkmark") } else { Text(value) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selection.wrappedValue == "Tous" || selection.wrappedValue == "Toutes" ? title : selection.wrappedValue)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.primary)
            .padding(.horizontal, 12).frame(height: 38)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Filtrer par \(title) : \(selection.wrappedValue)")
    }

    private var alertTable: some View {
        Surface(palette: palette, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    cardTitle("Messages regroupés")
                    Spacer()
                    Text("\(visibleGroups.count) / \(groups.count)").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                .padding(20)
                HStack {
                    eyebrow("SIGNALEMENT").frame(maxWidth: .infinity, alignment: .leading)
                    eyebrow("LOGS").frame(width: 32, alignment: .trailing)
                    eyebrow("NIVEAU").frame(width: 68, alignment: .trailing)
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
                rule
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if visibleGroups.isEmpty {
                            VStack(spacing: 13) {
                                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 27, weight: .light))
                                Text("Aucun message correspondant").font(.system(size: 13, weight: .medium))
                                Text("Essayez un autre mot ou réinitialisez les filtres.").font(.system(size: 11))
                                Button("Réinitialiser les filtres", action: resetFilters).font(.system(size: 12))
                            }
                            .foregroundStyle(palette.secondary).frame(maxWidth: .infinity).padding(.vertical, 70)
                        }
                        ForEach(visibleGroups) { group in
                            Button { selectedGroupID = group.id } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(group.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.primary).lineLimit(2)
                                        Text("\(group.family) · \(counted(group.messageCount, "message")) · \(counted(group.droneIDs.count, "drone"))")
                                            .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(group.logCount)").font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.primary)
                                        .frame(width: 32, alignment: .trailing)
                                    Text(group.level).font(.system(size: 9, weight: .medium)).foregroundStyle(levelColor(group.level))
                                        .frame(width: 68, alignment: .trailing)
                                }
                                .padding(.horizontal, 20).frame(height: 77)
                                .background(selectedGroupID == group.id ? palette.raised : .clear)
                                .overlay(alignment: .leading) { if selectedGroupID == group.id { palette.primary.frame(width: 2) } }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            rule
                        }
                    }
                }
                Text("\(visibleGroups.reduce(0) { $0 + $1.messageCount }) messages dans les résultats")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).padding(20)
            }
        }
    }

    private var inspector: some View {
        Surface(palette: palette, padding: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        eyebrow("INSPECTEUR")
                        Spacer()
                        Image(systemName: "sidebar.right").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    }
                    if let group = selectedGroup {
                        levelBadge(group.level)
                        Text(group.title).font(.system(size: 23, weight: .semibold)).tracking(-0.6)
                            .foregroundStyle(palette.primary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            detailChip("\(counted(group.droneIDs.count, "drone"))", symbol: "airplane")
                            detailChip("\(counted(group.logCount, "log"))", symbol: "doc.text")
                        }
                        Text("\(counted(group.messageCount, "message")) · \(group.family)")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.primary)
                        Text("\(dateLabel(group.firstDate)) → \(dateLabel(group.lastDate))")
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        Text("Messages regroupés par texte identique et même niveau. La cause et l’effet sur le vol restent à qualifier.")
                            .font(.system(size: 11)).lineSpacing(3).foregroundStyle(palette.secondary)
                        if let message = group.occurrences.first?.message {
                            MessageClassificationControl(message: message, store: store.annotations, families: allGroups.map(\.family))
                            AlertExplanationView(message: message)
                        }
                        rule
                        HStack {
                            eyebrow("MESSAGES ET SOURCES")
                            Spacer()
                            Text("\(min(group.messageCount, 100)) / \(group.messageCount)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                        }
                        Text("t = secondes depuis le début du log ; des messages mis en tampon peuvent avoir un temps négatif.")
                            .font(.system(size: 10)).lineSpacing(3).foregroundStyle(palette.secondary)
                        ForEach(Array(group.occurrences.prefix(100))) { occurrence in
                            evidenceCard(occurrence)
                        }
                        if group.messageCount > 100 {
                            Text("Les 100 premiers messages sont affichés. Le rapport HTML et l’export JSON contiennent les \(counted(group.messageCount, "message")) de ce groupe.")
                                .font(.system(size: 11)).lineSpacing(3).foregroundStyle(palette.secondary)
                        }
                    } else {
                        Image(systemName: "text.page").font(.system(size: 25, weight: .light)).padding(.top, 25)
                        Text("Aucun message sélectionné").font(.system(size: 15, weight: .medium))
                        Text("L’inspecteur suit les résultats de vos filtres.").font(.system(size: 12))
                    }
                }
                .foregroundStyle(palette.secondary).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func evidenceCard(_ occurrence: MessageOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(occurrence.droneName).lineLimit(1)
                Spacer()
                Text("t=\(String(format: "%.3f", occurrence.message.timestampSeconds)) s").monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary)
            Text(occurrence.message.text)
                .font(.system(size: 10, design: .monospaced)).lineSpacing(4)
                .foregroundStyle(palette.primary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(dateLabel(occurrence.date)) · \(occurrence.message.level)")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
            ForEach(occurrence.sourcePaths, id: \.self) { path in
                Button { store.revealSource(path) } label: {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                        .font(.system(size: 10)).lineLimit(1).foregroundStyle(palette.secondary)
                }
                .buttonStyle(.plain).help(path)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var fleetMap: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.needsAnalysisRefresh {
                Surface(palette: palette, padding: 16) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(palette.mint)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Des analyses peuvent être enrichies").font(.system(size: 13, weight: .semibold))
                            Text("Relisez les fichiers locaux pour enrichir les identités, les familles et les données disponibles avec le parseur actuel.")
                                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Actualiser les analyses", action: store.refreshAnalysis)
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(store.isImporting || store.isLoading)
                            .accessibilityIdentifier("map.refreshAnalyses")
                    }
                }
            }
            FleetMapView(logs: logs, onSelectLog: openFlight)
        }
    }

    private var drones: some View {
        VStack(alignment: .leading, spacing: 18) {
            DroneRegistryView(library: store, gcs: gcs, annotations: store.annotations) { log in
                droneFilter = log.annotationKey; page = .overview
            }
            if !logs.isEmpty {
                Text(droneFilter == "Tous" ? "Historique des drones" : "Historique du drone sélectionné")
                    .font(.caption).foregroundStyle(palette.secondary)
                historyCard
            }
        }
    }

    private var reports: some View {
        VStack(alignment: .leading, spacing: 18) {
            Surface(palette: palette) {
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 17) {
                        Image(systemName: "doc.text").font(.system(size: 30, weight: .light))
                        Text("Le rapport complet de votre flotte")
                            .font(.system(size: 26, weight: .semibold)).tracking(-0.7)
                        Text("\(store.snapshot.logs.count) logs · \(store.snapshot.scannedDroneCount) drones scannés · \(store.snapshot.provisionalDroneCount) identités provisoires · \(store.snapshot.logs.reduce(0) { $0 + $1.messages.count }) messages conservés")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        Text("Les exports couvrent toute la bibliothèque, y compris les logs illisibles, les limites de lecture et les messages de tous niveaux. Les filtres de l’interface ne réduisent pas le rapport.")
                            .font(.system(size: 12)).lineSpacing(4).foregroundStyle(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        Button(action: store.exportHTML) { Label(store.isExporting ? "Export en cours…" : "Exporter le rapport HTML", systemImage: "doc.richtext") }.disabled(store.isExporting)
                            .buttonStyle(.borderedProminent)
                        Button(action: store.exportJSON) { Label("Exporter les données JSON", systemImage: "curlybraces") }.disabled(store.isExporting)
                            .buttonStyle(.bordered)
                        Text("Sources, métriques disponibles, chronologie\net messages horodatés.")
                            .font(.system(size: 10)).lineSpacing(4).foregroundStyle(palette.secondary)
                    }
                    .font(.system(size: 12)).disabled(store.isImporting || store.isLoading)
                }
                .foregroundStyle(palette.primary)
            }
            importSummary
            limitations
        }
    }

    private var importSummary: some View {
        let stats = store.snapshot.importStats
        return Surface(palette: palette) {
            VStack(alignment: .leading, spacing: 15) {
                cardTitle("Dernier import")
                HStack(spacing: 25) {
                    reportCount("\(stats.discovered)", "fichiers trouvés")
                    reportCount("\(stats.imported)", "nouveaux logs")
                    reportCount("\(stats.unchanged)", "inchangés")
                    reportCount("\(stats.duplicates)", "doublons")
                    reportCount("\(stats.failed)", "échecs de lecture")
                }
                Text(store.snapshot.sourceFolders.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary).textSelection(.enabled)
            }
        }
    }
    private func reportCount(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 23, weight: .semibold)).foregroundStyle(palette.primary)
            Text(label).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var limitations: some View {
        let incomplete = store.snapshot.logs.filter { $0.status != "ok" || !$0.issues.isEmpty || !$0.coverage.isEmpty }
        return Surface(palette: palette) {
            VStack(alignment: .leading, spacing: 16) {
                cardTitle("Couverture et limites · \(incomplete.count) logs")
                Text("Les alertes textuelles et métriques disponibles dépendent de ce que le firmware a enregistré. Les événements binaires non décodés sont explicités par log.")
                    .font(.system(size: 12)).lineSpacing(4).foregroundStyle(palette.secondary)
                ForEach(incomplete.prefix(100)) { log in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(log.displayName) · \(dateLabel(log.date)) · \(log.fileName)")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.primary)
                            Spacer()
                            Text(log.status).font(.system(size: 10, design: .monospaced)).foregroundStyle(log.status == "error" ? palette.red : palette.amber)
                        }
                        Text((log.issues + log.coverage).joined(separator: "\n"))
                            .font(.system(size: 11)).lineSpacing(4).foregroundStyle(palette.secondary).textSelection(.enabled)
                    }
                    rule
                }
                if incomplete.count > 100 {
                    Text("100 logs affichés ici. Tous les détails sont inclus dans les exports.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                if incomplete.isEmpty {
                    Text("Aucune limite technique remontée par le parseur. Cela ne constitue pas un diagnostic de santé matérielle.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
        }
    }

    private var libraryFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: "internaldrive")
            Text("Analyse locale · sources conservées")
            Spacer()
            if !store.snapshot.generatedAt.isEmpty {
                Text("Bibliothèque actualisée : \(store.snapshot.generatedAt)").lineLimit(1)
            }
        }
        .font(.system(size: 10)).foregroundStyle(palette.secondary)
    }
    private var rule: some View { palette.border.frame(height: 1) }
    private func eyebrow(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(palette.secondary)
    }
    private func cardTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold)).tracking(-0.35).foregroundStyle(palette.primary)
    }
    private func levelColor(_ level: String) -> Color {
        LogMessage.rank(level) >= 5 ? palette.red : LogMessage.rank(level) >= 4 ? palette.amber : palette.secondary
    }
    private func levelBadge(_ level: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(levelColor(level)).frame(width: 5, height: 5)
            Text(level).font(.system(size: 10, weight: .semibold)).foregroundStyle(levelColor(level))
        }
    }
    private func detailChip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(palette.secondary)
            .padding(.horizontal, 9).padding(.vertical, 6).background(palette.raised, in: RoundedRectangle(cornerRadius: 6))
    }
    private func duration(_ seconds: Double) -> String {
        if seconds >= 3600 { return String(format: "%.1f h", seconds / 3600) }
        return String(format: "%.1f min", seconds / 60)
    }
    private func dateLabel(_ date: String) -> String {
        guard date.count >= 10 else { return "Date inconnue" }
        return String(date.prefix(10))
    }
    private func reconcileSelection() {
        if !visibleGroups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = visibleGroups.first?.id
        }
    }
    private func resetFilters() {
        search = ""
        familyFilter = nil
        severityFilter = "Tous"
        droneFilter = "Tous"
        reconcileSelection()
    }
    private func openGroup(_ id: String) {
        search = ""
        familyFilter = nil
        severityFilter = "Tous"
        selectedGroupID = id
        page = .alerts
    }
    private func openFlight(_ log: FlightLog) {
        store.loadFlight(log)
        showsFlight = true
    }
}

private struct Surface<Content: View>: View {
    let palette: Palette
    var padding: CGFloat = 22
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 17))
    }
}

private struct RadarChart: View {
    let palette: Palette
    let axes: [FamilyCount]
    let maximum: Int
    var body: some View {
        Canvas { context, size in
            guard axes.count >= 3 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 2)
            let radius = min(size.width * 0.34, size.height * 0.35)
            func point(_ index: Int, _ fraction: CGFloat) -> CGPoint {
                let angle = CGFloat(index) * .pi * 2 / CGFloat(axes.count) - .pi / 2
                return CGPoint(x: center.x + cos(angle) * radius * fraction, y: center.y + sin(angle) * radius * fraction)
            }
            for ring in 1...3 {
                var grid = Path()
                for index in axes.indices {
                    let vertex = point(index, CGFloat(ring) / 3)
                    if index == 0 { grid.move(to: vertex) } else { grid.addLine(to: vertex) }
                }
                grid.closeSubpath()
                context.stroke(grid, with: .color(palette.border), lineWidth: 1)
            }
            for index in axes.indices {
                var spoke = Path()
                spoke.move(to: center)
                spoke.addLine(to: point(index, 1))
                context.stroke(spoke, with: .color(palette.border), lineWidth: 1)
                context.draw(Text(axes[index].name).font(.system(size: 9)).foregroundColor(palette.secondary), at: point(index, 1.28))
            }
            var profile = Path()
            for index in axes.indices {
                let vertex = point(index, CGFloat(axes[index].count) / CGFloat(max(maximum, 1)))
                if index == 0 { profile.move(to: vertex) } else { profile.addLine(to: vertex) }
            }
            profile.closeSubpath()
            context.fill(profile, with: .color(palette.mint.opacity(0.18)))
            context.stroke(profile, with: .color(palette.mint), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            for index in axes.indices {
                let vertex = point(index, CGFloat(axes[index].count) / CGFloat(max(maximum, 1)))
                context.fill(Path(ellipseIn: CGRect(x: vertex.x - 2.5, y: vertex.y - 2.5, width: 5, height: 5)), with: .color(palette.mint))
            }
        }
        .accessibilityLabel("Logs avec alertes par famille, échelle 0 à \(maximum) : " + axes.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
    }
}
