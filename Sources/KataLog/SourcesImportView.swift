import AppKit
import SwiftUI
import KataLogCore

struct SourcesImportView: View {
    @ObservedObject var library: LibraryStore
    var externalBusy: Bool
    @StateObject private var sources: SourcesImportStore
    @State private var includeRemoved = false
    @State private var offsets = [0]
    @State private var confirmingRetireAll = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }

    init(library: LibraryStore, externalBusy: Bool = false) {
        self.library = library; self.externalBusy = externalBusy
        _sources = StateObject(wrappedValue: SourcesImportStore(library: library))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Bibliothèque locale").font(.system(size: 25, weight: .semibold)).tracking(-0.6)
                LibraryHelpButton(title: "Sources d’import", text: LibraryHelp.sources)
                Spacer()
                Button { dismiss() } label: { BentoIcon(symbol: "xmark") }
                    .keyboardShortcut(.cancelAction).accessibilityLabel("Fermer les sources d’import")
            }
            Text("Gérer les dossiers suivis. Les fichiers et les analyses restent conservés après un retrait ; vous pouvez restaurer la source à tout moment.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let page = sources.page {
                    Text("\(page.activeCount) \(page.activeCount == 1 ? "source active" : "sources actives") · \(page.removedCount) \(page.removedCount == 1 ? "retirée" : "retirées")").font(.subheadline.weight(.medium)).monospacedDigit()
                }
                Spacer()
                Toggle("Afficher les sources retirées", isOn: $includeRemoved).toggleStyle(.checkbox)
                    .disabled(sources.isLoading || sources.isWorking)
                Button("Actualiser", systemImage: "arrow.clockwise") { sources.load(includeRemoved: includeRemoved) }
                    .disabled(sources.isLoading || sources.isWorking)
            }
            HStack {
                Text("Tous les clients · Références de dossiers uniquement").font(.caption).foregroundStyle(palette.secondary)
                Spacer()
                Button("Retirer toutes les sources…", systemImage: "folder.badge.minus") { confirmingRetireAll = true }
                    .disabled(!sources.canMutate || externalBusy || (sources.page?.activeCount ?? 0) == 0)
                    .accessibilityIdentifier("sources.retireAll")
            }
            if library.isReadOnly {
                Label("Bibliothèque en lecture seule. Le retrait et la restauration sont indisponibles.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = sources.message {
                HStack {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let change = sources.lastChange {
                        Button(change.undoLabel) { sources.undo() }.disabled(!sources.canMutate || externalBusy)
                    }
                }
            }
            if let error = sources.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                if sources.page != nil { Text("Dernière liste conservée · actualisation impossible").font(.caption).foregroundStyle(.secondary) }
            }
            if sources.isLoading || sources.isWorking { ProgressView(sources.isWorking ? "Mise à jour de la liste…" : "Vérification des dossiers…").controlSize(.small) }
            BentoPanel(palette: palette) { ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sources.page?.folders ?? []) { folder in
                        folderRow(folder)
                        Divider()
                    }
                    if sources.page?.folders.isEmpty == true, !sources.isLoading {
                        Text(includeRemoved ? "Aucun dossier source enregistré." : "Aucune source active. Affichez les sources retirées pour les restaurer.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
            } }
            if let page = sources.page {
                HStack {
                    Button("Précédent") {
                        guard offsets.count > 1 else { return }
                        offsets.removeLast(); sources.load(offset: offsets.last ?? 0, includeRemoved: includeRemoved)
                    }.disabled(offsets.count <= 1 || sources.isLoading || sources.isWorking)
                    Text(page.folders.isEmpty ? "0 / \(page.total) \(page.total == 1 ? "dossier" : "dossiers")" : "\(sources.currentOffset + 1)–\(sources.currentOffset + page.folders.count) / \(page.total) \(page.total == 1 ? "dossier" : "dossiers")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Suivant") {
                        guard let next = page.nextOffset else { return }
                        offsets.append(next); sources.load(offset: next, includeRemoved: includeRemoved)
                    }.disabled(page.nextOffset == nil || sources.isLoading || sources.isWorking)
                }
            }
            HStack {
                Label("Retirer un dossier désactive son suivi et conserve ses fichiers et analyses.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Terminé") { dismiss() }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true))
            }
        }
        .padding(24).frame(minWidth: 650, idealWidth: 800, minHeight: 460, idealHeight: 600)
        .foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .onAppear { sources.load() }
        .onChange(of: includeRemoved) { _, value in offsets = [0]; sources.load(includeRemoved: value) }
        .onChange(of: sources.currentOffset) { _, offset in if offset == 0 { offsets = [0] } }
        .onChange(of: sources.errorMessage) { _, error in
            if error != nil, let index = offsets.firstIndex(of: sources.currentOffset) { offsets = Array(offsets.prefix(index + 1)) }
        }
        .confirmationDialog("Retirer toutes les sources du suivi ?", isPresented: $confirmingRetireAll, titleVisibility: .visible) {
            Button("Retirer toutes les sources", role: .destructive) { sources.retireAll() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le suivi de tous les dossiers sera désactivé, pour tous les clients. Les analyses et les fichiers .ulg restent conservés. Vous pourrez restaurer les références en affichant les sources retirées. Pour effacer aussi les analyses, utilisez « Vider la bibliothèque » dans Stockage.")
        }
    }

    private func folderRow(_ folder: SourceFolderPage.Folder) -> some View {
        HStack(alignment: .top, spacing: 16) {
            BentoIcon(symbol: folder.removed ? "folder.badge.minus" : "folder", size: 22).frame(width: 24).foregroundStyle(palette.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(folder.name).font(.callout.weight(.medium))
                    BentoStatus(label: folder.removed ? "Suivi désactivé" : "Active", color: folder.removed ? palette.secondary : palette.mint)
                }
                Text("\(folder.logCount) \(folder.logCount == 1 ? "log" : "logs") · \(folder.availabilityLabel)").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Chemin du dossier") {
                    Text(folder.path).font(.caption.monospaced()).foregroundStyle(palette.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }.font(.system(size: 10)).foregroundStyle(palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(folder.removed ? "Restaurer" : "Retirer du suivi") {
                sources.setRemoved(!folder.removed, path: folder.path)
            }
            .controlSize(.small).disabled(!sources.canMutate || externalBusy)
            .help(folder.removed ? "Remet ce dossier dans la liste des sources actives." : "Désactive le suivi de ce dossier. Les analyses et les fichiers sont conservés.")
        }.padding(.vertical, 15)
    }
}
