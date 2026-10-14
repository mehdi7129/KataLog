import SwiftUI
import KataLogCore

struct LibraryFavoritesMenu: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var views: LibraryViewStore
    @ObservedObject private var clients: ClientStore
    @State private var showingFavorites = false
    @State private var error: String?

    init(library: LibraryStore) { self.library = library; views = library.views; clients = library.clients }
    private var clientIDs: Set<String>? {
        clients.hasLoaded && !clients.isLoading && !clients.isWorking ? Set(clients.profiles.map(\.id)) : nil
    }

    var body: some View {
        Menu {
            ForEach(views.state.views) { favorite in
                Button(favorite.name) {
                    do { try views.applyView(favorite.id, validClientIDs: clientIDs) }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(favorite.scope.clientID?.isEmpty == false && clientIDs == nil)
            }
            if clients.isLoading { Text("Chargement des clients…") }
            else if let error = clients.errorMessage {
                Text("Lecture des clients indisponible")
                Button("Réessayer de charger les clients") { clients.reload() }.help(error)
            }
            if !views.state.views.isEmpty { Divider() }
            Button("Enregistrer ou gérer les favoris…") { showingFavorites = true }
        } label: { Label("Favoris", systemImage: "star") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Retrouver une sélection de clients, drones, dates et messages.")
        .accessibilityIdentifier("library.favorites")
        .sheet(isPresented: $showingFavorites) { LibraryFavoritesView(library: library) }
        .onAppear { clients.reloadIfNeeded() }
        .alert("Favori indisponible", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Fermer", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct LibraryFavoritesView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var views: LibraryViewStore
    @ObservedObject private var clients: ClientStore
    @State private var name = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
    private var canWrite: Bool { !library.isReadOnly && !library.isMaintainingLibrary && !library.isImporting }

    init(library: LibraryStore) { self.library = library; views = library.views; clients = library.clients }
    private var clientIDs: Set<String>? {
        clients.hasLoaded && !clients.isLoading && !clients.isWorking ? Set(clients.profiles.map(\.id)) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Filtres favoris").font(.title2.weight(.semibold))
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            BentoPanel(palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enregistrer la sélection actuelle").font(.headline)
                    Text(clients.scopeLabel(for: views.state.activeScope.clientID)).font(.callout)
                    Text(views.state.activeScope.description).font(.caption).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Nom du favori", text: $name).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("favorites.name").onSubmit { save() }
                        Button("Enregistrer") { save() }
                            .disabled(!canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("favorites.save")
                    }.disabled(!canWrite)
                    if library.isReadOnly {
                        Text("Lecture seule : vous pouvez appliquer un favori, mais pas le modifier.")
                            .font(.caption).foregroundStyle(palette.secondary)
                    }
                }
            }
            if views.state.views.isEmpty {
                ContentUnavailableView("Aucun favori", systemImage: "star", description: Text("Enregistrez les filtres que vous utilisez régulièrement."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(views.state.views) { favorite in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(favorite.name).font(.headline)
                                    Spacer()
                                    Button("Appliquer") { apply(favorite) }
                                        .disabled(library.isMaintainingLibrary || library.isImporting || (favorite.scope.clientID?.isEmpty == false && clientIDs == nil))
                                        .accessibilityLabel("Appliquer le favori " + favorite.name)
                                    Button("Supprimer", role: .destructive) { edit { try views.removeView(favorite.id) } }
                                        .disabled(!canWrite).accessibilityLabel("Supprimer le favori " + favorite.name)
                                }
                                Text(clients.scopeLabel(for: favorite.scope.clientID) + " · " + favorite.scope.description)
                                    .font(.caption).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                                Divider()
                            }
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            if clients.isLoading { ProgressView("Chargement des clients…").controlSize(.small) }
            else if let issue = clients.errorMessage {
                HStack {
                    Text("Lecture des clients indisponible").font(.caption).foregroundStyle(palette.amber).help(issue)
                    Button("Réessayer") { clients.reload() }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(palette.amber) }
            Text("Un favori conserve les filtres. Les résultats évoluent avec la bibliothèque.")
                .font(.caption).foregroundStyle(palette.secondary)
        }.padding(24).frame(width: 680, height: 580)
        .foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .onAppear { clients.reloadIfNeeded() }
    }
    private func save() {
        guard canWrite else { return }
        edit { try views.saveView(name: name); name = "" }
    }
    private func apply(_ favorite: SavedLibraryView) {
        edit { try views.applyView(favorite.id, validClientIDs: clientIDs); dismiss() }
    }
    private func edit(_ operation: () throws -> Void) {
        do { try operation(); error = nil } catch { self.error = error.localizedDescription }
    }
}
