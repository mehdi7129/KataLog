import SwiftUI
import KataLogCore

struct LogComparisonView: View {
    let logIDs: [String]
    @StateObject private var store: LogComparisonStore
    @State private var search = ""
    @State private var limit = 200
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }

    init(library: LibraryStore, logIDs: [String], store: LogComparisonStore? = nil) {
        self.logIDs = logIDs
        _store = StateObject(wrappedValue: store ?? LogComparisonStore(library: library))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Comparer deux logs").font(.title2.weight(.semibold))
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if store.isLoading {
                ProgressView("Lecture des deux logs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.error {
                VStack(alignment: .leading, spacing: 14) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(palette.amber)
                    Button("Réessayer") { store.load(logIDs: logIDs) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let first = store.first, let second = store.second, let comparison = store.comparison {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        BentoPanel(palette: palette) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Text(first.displayName).font(.headline); Spacer(); Button("Inverser A et B", systemImage: "arrow.left.arrow.right") { store.swap() } }
                                source(first, label: "A", firmware: comparison.previousFirmware)
                                Divider()
                                source(second, label: "B", firmware: comparison.currentFirmware)
                                if comparison.firmwareDiffers { Label("Les métadonnées firmware diffèrent.", systemImage: "info.circle").font(.callout) }
                            }
                        }
                        BentoPanel(palette: palette) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Paramètres · A → B").font(.headline)
                                Text(comparison.explanation).font(.caption).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                                if comparison.comparable { parameterDifferences(comparison) }
                            }
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
        }.padding(24).frame(width: 820, height: 590)
        .foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .onChange(of: search) { _, _ in limit = 200 }
        .task { store.load(logIDs: logIDs) }
        .onDisappear { store.cancel() }
    }

    private func source(_ log: FlightLog, label: String, firmware: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(label) · \(log.fileName)").font(.callout.weight(.medium))
            Text(log.date.isEmpty ? "Date inconnue" : log.date).font(.caption).foregroundStyle(palette.secondary)
            Text("Firmware : \(firmware ?? "non enregistré")").font(.caption.monospaced())
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parameterDifferences(_ comparison: ParameterComparison) -> some View {
        let differences = comparison.differences.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Rechercher un paramètre", text: $search).textFieldStyle(.roundedBorder)
            Text("\(differences.count) écart(s) · \(min(limit, differences.count)) affiché(s)").font(.caption).foregroundStyle(palette.secondary)
            if differences.isEmpty {
                Text(comparison.differences.isEmpty ? "Aucun écart parmi les paramètres typés enregistrés." : "Aucun écart ne correspond à cette recherche.").font(.callout)
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(differences.prefix(limit)) { difference in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(difference.name + " · " + label(difference.change)).font(.callout.weight(.medium))
                        Text("A : \(difference.before?.description ?? "non enregistré") [\(difference.beforeType ?? "inconnu")]\nB : \(difference.after?.description ?? "non enregistré") [\(difference.afterType ?? "inconnu")]")
                            .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Divider()
                    }
                }
            }
            if differences.count > limit { Button("Afficher 200 écarts supplémentaires") { limit += 200 } }
        }
    }
    private func label(_ change: ParameterDifference.Change) -> String {
        switch change {
        case .added: "enregistré uniquement dans B"
        case .absent: "enregistré uniquement dans A"
        case .value: "valeur différente"
        case .type: "type différent"
        }
    }
}
