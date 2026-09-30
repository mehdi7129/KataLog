import AppKit
import SwiftUI
import KataLogCore

struct SourcesImportView: View {
    @ObservedObject var library: LibraryStore
    var externalBusy: Bool
    @StateObject private var sources: SourcesImportStore
    @State private var includeRemoved = false
    @State private var offsets = [0]
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryStore, externalBusy: Bool = false) {
        self.library = library; self.externalBusy = externalBusy
        _sources = StateObject(wrappedValue: SourcesImportStore(library: library))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Sources d’import").font(.system(size: 25, weight: .semibold)).tracking(-0.6)
                LibraryHelpButton(title: "Sources d’import", text: LibraryHelp.sources)
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Liste globale des dossiers importés. Le retrait conserve les analyses et les fichiers ; vous pouvez restaurer la source à tout moment.")
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
            ScrollView {
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
            }
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
        }
        .padding(24).frame(minWidth: 650, idealWidth: 800, minHeight: 460, idealHeight: 600)
        .onAppear { sources.load() }
        .onChange(of: includeRemoved) { _, value in offsets = [0]; sources.load(includeRemoved: value) }
        .onChange(of: sources.currentOffset) { _, offset in if offset == 0 { offsets = [0] } }
        .onChange(of: sources.errorMessage) { _, error in
            if error != nil, let index = offsets.firstIndex(of: sources.currentOffset) { offsets = Array(offsets.prefix(index + 1)) }
        }
    }

    private func folderRow(_ folder: SourceFolderPage.Folder) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: folder.removed ? "folder.badge.minus" : "folder").frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(folder.name).font(.callout.weight(.medium))
                    Text(folder.removed ? "Retirée de la liste" : "Active").font(.caption).foregroundStyle(.secondary)
                }
                Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(folder.logCount) \(folder.logCount == 1 ? "log" : "logs") · \(folder.availabilityLabel)").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(folder.removed ? "Restaurer" : "Retirer de la liste") {
                sources.setRemoved(!folder.removed, path: folder.path)
            }
            .controlSize(.small).disabled(!sources.canMutate || externalBusy)
            .help(folder.removed ? "Remet ce dossier dans la liste des sources actives." : "Retire ce dossier de la liste. Les analyses et les fichiers sont conservés.")
        }.padding(.vertical, 15)
    }
}
