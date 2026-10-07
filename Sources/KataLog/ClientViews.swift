import SwiftUI
import KataLogCore

/// Client names are local, user-defined labels. The global scope is never an import destination.
struct ClientScopeControl: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var clients: ClientStore
    @ObservedObject private var views: LibraryViewStore
    let palette: Palette
    var busy = false
    @State private var managing = false
    @State private var error: String?

    init(library: LibraryStore, palette: Palette, busy: Bool = false) {
        self.library = library; self.palette = palette; self.busy = busy
        clients = library.clients; views = library.views
    }

    var body: some View {
        Menu {
            scopeChoice("Tous les clients", id: nil)
            Divider()
            ForEach(clients.profiles) { profile in scopeChoice(profile.name, id: profile.id) }
            scopeChoice("Sans client", id: "")
            if clients.isLoading {
                Divider()
                Text("Chargement des clients…")
            } else if let error = clients.errorMessage {
                Divider()
                Text("Lecture des clients indisponible")
                Button("Réessayer de charger les clients", systemImage: "arrow.clockwise") { clients.reload() }
                    .help(error)
            }
            Divider()
            Button("Créer ou gérer les clients…", systemImage: "person.2.badge.gearshape") { managing = true }
                .disabled(library.isReadOnly)
        } label: {
            HStack(spacing: 6) {
                Label(clients.scopeLabel(for: views.state.activeScope.clientID), systemImage: "person.2")
                    .lineLimit(1).truncationMode(.tail)
                if clients.isLoading { ProgressView().controlSize(.mini).accessibilityLabel("Chargement des clients") }
                else if let error = clients.errorMessage {
                    Image(systemName: "exclamationmark.triangle").help(error)
                        .accessibilityLabel("Lecture des clients indisponible")
                }
            }.frame(maxWidth: 240, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 280, alignment: .leading).fixedSize(horizontal: true, vertical: true)
        .disabled(busy || clients.isWorking)
        .help("Choisir les logs d’un client ou consulter toute la bibliothèque")
        .accessibilityIdentifier("clients.scope")
        .sheet(isPresented: $managing) { ClientManagementView(library: library) }
        .alert("Impossible de changer de client", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func scopeChoice(_ label: String, id: String?) -> some View {
        Button {
            do { try views.chooseClient(id) } catch { self.error = error.localizedDescription }
        } label: {
            if views.state.activeScope.clientID == id { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
    }
}

struct ClientDestinationPicker: View {
    @ObservedObject var clients: ClientStore
    @Binding var selection: String
    var title = "Client destinataire"
    var replacesExistingAssignment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    Button { selection = "" } label: {
                        if selection.isEmpty { Label("Sans client", systemImage: "checkmark") }
                        else { Text("Sans client") }
                    }
                    ForEach(clients.profiles) { client in
                        Button { selection = client.id } label: {
                            if selection == client.id { Label(client.name, systemImage: "checkmark") }
                            else { Text(client.name) }
                        }
                    }
                } label: {
                    Text(clients.scopeLabel(for: selection)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 140, alignment: .trailing)
                }.menuStyle(.borderlessButton)
                    .frame(maxWidth: 160, alignment: .trailing).fixedSize(horizontal: true, vertical: true)
                    .accessibilityLabel(title)
                    .accessibilityValue(clients.scopeLabel(for: selection))
            }
            .accessibilityIdentifier("clients.destination")
            .help(replacesExistingAssignment ? "L’attribution des logs sélectionnés sera remplacée par ce client." : "Les nouveaux logs sont attribués à ce client. Les fichiers déjà connus conservent leur attribution.")
            ClientReadStatus(clients: clients)
        }
        .onAppear { clients.reloadIfNeeded() }
    }
}

private struct ClientReadStatus: View {
    @ObservedObject var clients: ClientStore

    var body: some View {
        if clients.isLoading {
            ProgressView("Chargement des clients…").controlSize(.small)
        } else if let error = clients.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Lecture des clients indisponible : \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Réessayer", systemImage: "arrow.clockwise") { clients.reload() }
                    .disabled(clients.isWorking)
            }
        }
    }
}

struct ClientManagementView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var clients: ClientStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var editingID: String?
    @State private var removing: ClientProfile?
    @State private var error: String?
    private var palette: Palette { Palette(dark: scheme == .dark) }

    init(library: LibraryStore) { self.library = library; clients = library.clients }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Vos clients").font(.system(size: 25, weight: .semibold))
            Text("Créez votre organisation ou les clients dont vous suivez les drones. Ces noms restent sur ce Mac.")
                .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Nom de l’organisation ou du client", text: $name)
                    .textFieldStyle(.roundedBorder).onSubmit(save)
                    .accessibilityIdentifier("clients.name")
                Button(editingID == nil ? "Créer" : "Enregistrer", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || clients.isWorking || library.isReadOnly)
                if editingID != nil { Button("Annuler") { editingID = nil; name = "" } }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if clients.hasLoaded, clients.profiles.isEmpty, !clients.isLoading, clients.errorMessage == nil {
                        Text("Aucun client créé. Vos logs restent disponibles dans « Sans client ».")
                            .foregroundStyle(palette.secondary).padding(.vertical, 30)
                    }
                    ForEach(clients.profiles) { client in
                        HStack {
                            Label(client.name, systemImage: "person.2").lineLimit(2)
                            Spacer()
                            Button("Renommer") { editingID = client.id; name = client.name }
                            Button("Supprimer…", role: .destructive) { removing = client }
                        }.padding(.vertical, 10).disabled(clients.isWorking || library.isReadOnly)
                        Divider()
                    }
                }
            }
            ClientReadStatus(clients: clients)
            if let error { Text(error).foregroundStyle(palette.red).fixedSize(horizontal: false, vertical: true) }
            if clients.isWorking { ProgressView("Mise à jour des clients…").controlSize(.small) }
            HStack {
                Text("Un drone conserve la même identité dans toute la bibliothèque.")
                    .font(.caption).foregroundStyle(palette.secondary)
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction).disabled(clients.isWorking)
            }
        }
        .padding(26).frame(width: 640, height: 490)
        .background(palette.background).foregroundStyle(palette.primary)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette))
        .interactiveDismissDisabled(clients.isWorking)
        .onAppear { clients.reloadIfNeeded() }
        .confirmationDialog("Supprimer ce client ?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Supprimer le client", role: .destructive) { remove() }
            Button("Annuler", role: .cancel) { removing = nil }
        } message: {
            Text("Les logs de « \(removing?.name ?? "") » passeront dans « Sans client ». Les analyses, drones et fichiers .ulg seront conservés.")
        }
    }

    private func save() {
        guard !clients.isWorking, !library.isReadOnly else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let id = editingID
        Task {
            do {
                if let id { try await clients.rename(id: id, name: value) }
                else { _ = try await clients.create(name: value) }
                name = ""; editingID = nil; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove() {
        guard let client = removing else { return }
        removing = nil
        Task {
            do {
                try await clients.remove(id: client.id)
                if library.views.state.activeScope.clientID == client.id { try library.views.chooseClient("") }
                if editingID == client.id { editingID = nil; name = "" }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ClientAssignmentView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var clients: ClientStore
    let scope: SelectionScope
    let logCount: Int
    var onComplete: () -> Void = {}
    @State private var destination = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    init(library: LibraryStore, scope: SelectionScope, logCount: Int, onComplete: @escaping () -> Void = {}) {
        self.library = library; self.scope = scope; self.logCount = logCount; self.onComplete = onComplete
        clients = library.clients
    }

    var body: some View {
        let palette = Palette(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 20) {
            Text("Attribuer les logs").font(.system(size: 24, weight: .semibold))
            Text("\(logCount) logs concernés · \(clients.scopeLabel(for: scope.clientID))")
                .foregroundStyle(palette.secondary)
            ClientDestinationPicker(clients: clients, selection: $destination, replacesExistingAssignment: true)
            Text("Cette action remplace l’attribution des logs sélectionnés. Elle ne duplique ni les drones ni les fichiers. Choisissez « Sans client » pour retirer leur attribution.")
                .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(palette.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction).disabled(clients.isWorking)
                Spacer()
                if clients.isWorking { ProgressView().controlSize(.small) }
                Button("Attribuer \(logCount) logs") {
                    Task {
                        do {
                            try await clients.assign(scope: scope, to: destination.isEmpty ? nil : destination)
                            onComplete(); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(clients.isWorking || library.isReadOnly || logCount == 0)
            }
        }
        .padding(26).frame(width: 560).foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette))
        .interactiveDismissDisabled(clients.isWorking)
    }
}
