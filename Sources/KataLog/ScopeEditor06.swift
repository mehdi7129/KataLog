import SwiftUI
import KataLogCore

struct ScopeEditor06: View {
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var scope = SelectionScope()
    @State private var search = ""
    @State private var error: String?
    @State private var registryCursors: [String?] = [nil]
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Explorer la bibliothèque").font(.title2.weight(.semibold)); Spacer(); Button("Tout réinitialiser") { scope = .init() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Drones · \(scope.droneKeys.count) identités sélectionnées").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { TextField("Numéro, nom ou identité", text: $search).onSubmit { findDrones() }; Button("Rechercher") { findDrones() }.disabled(library.isQuerying) }
                            ForEach(library.dronePage?.drones ?? []) { drone in
                                Toggle(isOn: selection(drone.id, values: $scope.droneKeys)) { VStack(alignment: .leading) { Text(drone.displayName); Text(drone.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) } }
                            }
                            HStack { Button("Précédent") { guard registryCursors.count > 1 else { return }; registryCursors.removeLast(); library.loadAuxiliary(kind: "drones", cursor: registryCursors.last ?? nil, search: search) }.disabled(registryCursors.count <= 1 || library.isQuerying); Spacer(); Text("Page \(registryCursors.count)").font(.caption); Button("Suivant") { guard let cursor = library.dronePage?.nextCursor else { return }; registryCursors.append(cursor); library.loadAuxiliary(kind: "drones", cursor: cursor, search: search) }.disabled(library.dronePage?.nextCursor == nil || library.isQuerying) }
                            Text("Aucune sélection = tous les contrôleurs. Les choix des autres pages sont conservés.").font(.caption).foregroundStyle(.secondary)
                            ForEach(scope.droneKeys.filter { key in !(library.dronePage?.drones ?? []).contains { $0.id == key } }, id: \.self) { key in HStack { Text(key).font(.system(.caption, design: .monospaced)); Spacer(); Button("Retirer") { scope.droneKeys.removeAll { $0 == key } } } }
                        }
                    }
                    }
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Période").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { TextField("Début · AAAA-MM-JJ", text: optional($scope.dateFrom)); Text("→"); TextField("Fin · AAAA-MM-JJ", text: optional($scope.dateTo)) }
                            Toggle("Inclure les dates inconnues", isOn: $scope.includeUnknownDates)
                            Text("Jours enregistrés dans la source. Aucun fuseau horaire n’est inventé pour les dates issues des dossiers.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    }
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Messages").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Texte, titre ou famille", text: $scope.search)
                            HStack {
                                Menu("Familles · \(scope.families.count)") { ForEach(Array(Set((library.catalogue?.families ?? []) + scope.families)).sorted(), id: \.self) { family in Toggle(family, isOn: selection(family, values: $scope.families)) } }
                                Menu("Niveaux · \(scope.levels.count)") { ForEach(Array(Set((library.catalogue?.levels ?? []) + scope.levels)).sorted(), id: \.self) { level in Toggle(level, isOn: selection(level, values: $scope.levels)) } }
                            }
                            if let issue = library.catalogueError { Label("Catalogue indisponible : " + issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                            else if library.catalogue == nil { ProgressView("Chargement des familles et niveaux…").controlSize(.small) }
                            else if library.catalogue?.families.isEmpty == true { Text("Aucune famille de messages enregistrée. Les filtres déjà choisis restent conservés.").font(.caption).foregroundStyle(.secondary) }
                            Toggle("Alertes uniquement", isOn: $scope.alertOnly)
                            Toggle("Inclure les messages masqués", isOn: $scope.includeMasked)
                            Text("Une recherche de messages exige une occurrence correspondante. Un état failsafe sans texte reste une mesure distincte.").font(.caption).foregroundStyle(.secondary)
                            if !scope.families.isEmpty { Text("Familles : " + scope.families.joined(separator: ", ")).font(.caption) }
                            if !scope.levels.isEmpty { Text("Niveaux : " + scope.levels.joined(separator: ", ")).font(.caption) }
                        }
                    }
                    }
                    BentoPanel(palette: palette) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Enregistrements").font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Fichier, SHA, drone ou chemin", text: $scope.logSearch)
                            HStack { Toggle("Lecture complète", isOn: selection("ok", values: $scope.statuses)); Toggle("Lecture partielle", isOn: selection("partial", values: $scope.statuses)); Toggle("Erreur de lecture", isOn: selection("error", values: $scope.statuses)) }
                            Text("Aucun statut sélectionné = tous. Les erreurs de lecture restent consultables.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    }
                    if library.isReadOnly { Label("Lecture seule : cette sélection reste temporaire et ne modifie pas les réglages enregistrés.", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
                }
            }.textFieldStyle(.roundedBorder)
            if let error = error ?? library.queryError { Label(error, systemImage: "exclamationmark.triangle").font(.callout) }
            HStack { Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Appliquer la sélection") { apply() }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true)).keyboardShortcut(.defaultAction).disabled(library.isMaintainingLibrary || library.isImporting || library.isQuerying) }
        }.padding(24).frame(width: 720, height: 620).foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .onAppear { scope = library.views.state.activeScope; findDrones() }
        .task { await library.loadCatalogue() }
    }
    private func selection(_ value: String, values: Binding<[String]>) -> Binding<Bool> { Binding(get: { values.wrappedValue.contains(value) }, set: { selected in var set = Set(values.wrappedValue); if selected { set.insert(value) } else { set.remove(value) }; values.wrappedValue = set.sorted() }) }
    private func optional(_ value: Binding<String?>) -> Binding<String> { Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 }) }
    private func findDrones() { registryCursors = [nil]; library.loadAuxiliary(kind: "drones", search: search) }
    private func apply() {
        for bound in [scope.dateFrom, scope.dateTo].compactMap({ $0 }) { guard SelectionScope.calendarDay(bound) == bound else { error = "Utilisez une date valide au format AAAA-MM-JJ."; return } }
        if let start = scope.dateFrom, let end = scope.dateTo, start > end { error = "Le début doit précéder la fin de la période."; return }
        do { try library.views.chooseScope(scope); dismiss() } catch { self.error = error.localizedDescription }
    }
}
