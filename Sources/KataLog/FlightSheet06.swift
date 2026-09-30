import SwiftUI
import KataLogCore

struct FlightSheet06: View {
    @ObservedObject var library: LibraryStore
    @StateObject private var study: FlightStudyStore
    @State private var pane = 0
    @Environment(\.dismiss) private var dismiss
    init(library: LibraryStore) { self.library = library; _study = StateObject(wrappedValue: FlightStudyStore(library: library)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Afficher", selection: $pane) { Text("Fiche").tag(0); Text("Courbes et chronologie").tag(1); Text("Événements PX4").tag(2); Text("Révisions").tag(3) }.pickerStyle(.segmented).frame(maxWidth: 670)
                Spacer()
                Button("Fermer") { study.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            if pane == 3, let logID = library.selectedFlight?.id {
                AnalysisRevisionsView(library: library, logID: logID)
            } else if pane == 2 {
                EventBrowserView(library: library, logID: library.selectedFlight?.id)
            } else if pane == 1 {
                if let log = library.selectedFlight, !library.isLoadingFlight { FlightAnalysisView(log: log, study: study) }
                else if let error = library.flightError { ContentUnavailableView("Détail indisponible", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else { ProgressView("Chargement du détail…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { FlightDetailView(store: library) }
        }.frame(minWidth: 900, minHeight: 620)
        .onDisappear { study.cancel() }
    }
}
