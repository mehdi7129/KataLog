import SwiftUI
import KataLogCore

struct ScopeEditor06: View {
    @ObservedObject var library: LibraryStore
    @StateObject private var navigation: LibraryNavigationStore
    @ObservedObject private var views: LibraryViewStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var scope = SelectionScope()
    @State private var search = ""
    @State private var error: String?
    @State private var registryCursors: [String?] = [nil]
    @State private var knownDroneNames: [String: String] = [:]
    private var advancedMode: Bool { views.state.advancedMode == true }
    init(library: LibraryStore) {
        self.library = library
        _navigation = StateObject(wrappedValue: library.makeNavigationSession())
        views = library.views
    }
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Explorer la bibliothèque").font(.title2.weight(.semibold)); Spacer(); Button("Tout réinitialiser") { scope = .init() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(scope.droneKeys.isEmpty ? "Drones · Tous" : "Drones · \(scope.droneKeys.count) sélectionnés").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { TextField(advancedMode ? "Numéro, nom ou identité" : "Rechercher un drone", text: $search).onSubmit { findDrones() }; Button("Rechercher") { findDrones() }.disabled(navigation.isQuerying) }
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(navigation.dronePage?.drones ?? []) { drone in
                                        Toggle(isOn: selection(drone.id, values: $scope.droneKeys)) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(drone.displayName)
                                                if advancedMode { Text(drone.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                                            }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                            }.frame(height: min(200, CGFloat(navigation.dronePage?.drones.count ?? 0) * (advancedMode ? 44 : 30)))
                            if registryCursors.count > 1 || navigation.dronePage?.nextCursor != nil {
                            HStack { Button("Précédent") { guard registryCursors.count > 1 else { return }; registryCursors.removeLast(); navigation.loadAuxiliary(kind: "drones", cursor: registryCursors.last ?? nil, search: search) }.disabled(registryCursors.count <= 1 || navigation.isQuerying); Spacer(); Text("Page \(registryCursors.count)").font(.caption); Button("Suivant") { guard let cursor = navigation.dronePage?.nextCursor else { return }; registryCursors.append(cursor); navigation.loadAuxiliary(kind: "drones", cursor: cursor, search: search) }.disabled(navigation.dronePage?.nextCursor == nil || navigation.isQuerying) }
                            }
                            Text("Sans sélection, tous les drones sont inclus.").font(.caption).foregroundStyle(.secondary)
                            ForEach(scope.droneKeys.filter { key in !(navigation.dronePage?.drones ?? []).contains { $0.id == key } }, id: \.self) { key in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(nameForSelectedDrone(key)).font(.caption)
                                        if advancedMode { Text(key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Button("Retirer") { scope.droneKeys.removeAll { $0 == key } }
                                }
                            }
                        }
                    }
                    }
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Période").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { TextField("Début · AAAA-MM-JJ", text: optional($scope.dateFrom)); Text("→"); TextField("Fin · AAAA-MM-JJ", text: optional($scope.dateTo)) }
                            Toggle("Inclure les dates inconnues", isOn: $scope.includeUnknownDates)
                            Text("Dates présentes dans les logs.").font(.caption).foregroundStyle(.secondary)
                                .help("Jours enregistrés dans la source. Aucun fuseau horaire n’est inventé pour les dates issues des dossiers.")
                        }
                    }
                    }
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Messages").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Texte, titre ou famille", text: $scope.search)
                            HStack {
                                Menu("Familles · \(scope.families.count)") { ForEach(Array(Set((navigation.catalogue?.families ?? []) + scope.families)).sorted(), id: \.self) { family in Toggle(family, isOn: selection(family, values: $scope.families)) } }
                                Menu("Niveaux · \(scope.levels.count)") { ForEach(Array(Set((navigation.catalogue?.levels ?? []) + scope.levels)).sorted(), id: \.self) { level in Toggle(level, isOn: selection(level, values: $scope.levels)) } }
                            }
                            if let issue = navigation.catalogueError { Label("Catalogue indisponible : " + issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                            else if navigation.catalogue == nil { ProgressView("Chargement des familles et niveaux…").controlSize(.small) }
                            else if navigation.catalogue?.families.isEmpty == true { Text("Aucune famille de messages enregistrée. Les filtres déjà choisis restent conservés.").font(.caption).foregroundStyle(.secondary) }
                            Toggle("Alertes uniquement", isOn: $scope.alertOnly)
                            Toggle("Inclure les messages masqués", isOn: $scope.includeMasked)
                            if advancedMode { Text("Une recherche de messages exige une occurrence correspondante. Un état failsafe sans texte reste une mesure distincte.").font(.caption).foregroundStyle(.secondary) }
                            if !scope.families.isEmpty { Text("Familles : " + scope.families.joined(separator: ", ")).font(.caption) }
                            if !scope.levels.isEmpty { Text("Niveaux : " + scope.levels.joined(separator: ", ")).font(.caption) }
                        }
                    }
                    }
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Enregistrements").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 12) {
                            TextField(advancedMode ? "Fichier, SHA, drone ou chemin" : "Rechercher un fichier ou un drone", text: $scope.logSearch)
                            HStack { Toggle("Lecture complète", isOn: selection("ok", values: $scope.statuses)); Toggle("Lecture partielle", isOn: selection("partial", values: $scope.statuses)); Toggle("Erreur de lecture", isOn: selection("error", values: $scope.statuses)) }
                            Text("Aucun statut sélectionné = tous. Les erreurs de lecture restent consultables.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    }
                    if library.isReadOnly { Label("Lecture seule : cette sélection reste temporaire et ne modifie pas les réglages enregistrés.", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
                }
            }.textFieldStyle(.roundedBorder)
            if let error = error ?? navigation.queryError { Label(error, systemImage: "exclamationmark.triangle").font(.callout) }
            HStack { Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Appliquer la sélection") { apply() }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true)).keyboardShortcut(.defaultAction).disabled(library.isMaintainingLibrary || library.isImporting || navigation.isQuerying) }
        }.padding(24).frame(width: 720, height: 620).foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .onAppear { scope = views.state.activeScope; rememberDroneNames(); findDrones() }
        .onReceive(navigation.$dronePage) { page in
            for drone in page?.drones ?? [] { knownDroneNames[drone.id] = drone.displayName }
        }
        .task { await navigation.loadCatalogue() }
        .onDisappear { navigation.close() }
    }
    private func rememberDroneNames() {
        for log in library.snapshot.logs { knownDroneNames[log.annotationKey] = log.displayName }
        for drone in navigation.dronePage?.drones ?? [] { knownDroneNames[drone.id] = drone.displayName }
    }
    private func nameForSelectedDrone(_ key: String) -> String {
        if let name = knownDroneNames[key] { return name }
        if let number = library.annotations.state.stockNumbers[key] { return "Drone " + number }
        // An older selection can refer to a drone outside the currently loaded page.
        // Keep it removable even when its name has not been loaded in this session.
        return "Drone · …" + String(key.suffix(6))
    }
    private func selection(_ value: String, values: Binding<[String]>) -> Binding<Bool> { Binding(get: { values.wrappedValue.contains(value) }, set: { selected in var set = Set(values.wrappedValue); if selected { set.insert(value) } else { set.remove(value) }; values.wrappedValue = set.sorted() }) }
    private func optional(_ value: Binding<String?>) -> Binding<String> { Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 }) }
    private func findDrones() { registryCursors = [nil]; navigation.loadAuxiliary(kind: "drones", search: search) }
    private func apply() {
        for bound in [scope.dateFrom, scope.dateTo].compactMap({ $0 }) { guard SelectionScope.calendarDay(bound) == bound else { error = "Utilisez une date valide au format AAAA-MM-JJ."; return } }
        if let start = scope.dateFrom, let end = scope.dateTo, start > end { error = "Le début doit précéder la fin de la période."; return }
        do { try library.views.chooseScope(scope); dismiss() } catch { self.error = error.localizedDescription }
    }
}
