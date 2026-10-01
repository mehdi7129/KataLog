import AppKit
import SwiftUI
import KataLogCore

struct ImportOptionsState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var archiveDirectory: String?
}

@MainActor
enum ImportOptionsPersistence {
    static func load(directory: URL) throws -> ImportOptionsState {
        let url = directory.appendingPathComponent("import-options.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 else { throw AnalysisError.engine("Les réglages d’import dépassent la taille autorisée.") }
        let value = try JSONDecoder().decode(ImportOptionsState.self, from: data)
        guard value.schemaVersion == 1 else { throw AnalysisError.schema(value.schemaVersion) }
        return value
    }
    static func save(_ value: ImportOptionsState, library: LibraryStore) throws {
        guard !library.isReadOnly, library.views.canMutate(), !library.isImporting else {
            throw AnalysisError.engine("Les réglages d’import ne peuvent pas être modifiés pendant cette opération ou en lecture seule.")
        }
        try save(value, directory: library.storageDirectory)
    }
    static func save(_ value: ImportOptionsState, directory: URL) throws {
        // Validate existing data before writing; future or malformed settings
        // are preserved instead of silently replaced by an older application.
        _ = try load(directory: directory)
        guard value.schemaVersion == 1 else { throw AnalysisError.schema(value.schemaVersion) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 64 * 1024 else { throw AnalysisError.engine("Le chemin d’archives est trop long.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("import-options.json"), options: .atomic)
    }
}

struct ImportOptions06: View {
    let source: URL
    let initialState: ImportOptionsState
    var initialCopy = false
    let canApply: () -> Bool
    let onApply: (URL?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var copy = false
    @State private var archiveDirectory = ""
    @State private var error: String?
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Importer et conserver").font(.title2.weight(.semibold))
            Text(source.path).font(.caption.monospaced()).foregroundStyle(palette.secondary).textSelection(.enabled)
            HStack(spacing: 8) {
                conservationButton("Référencer les fichiers", copies: false)
                conservationButton("Copier vers mes archives", copies: true)
                Spacer()
            }
            BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
            if copy {
                Text("Copies vérifiées par taille et SHA-256 pendant l’import. Attendez sa fin et vérifiez le bilan avant de retirer la carte SD. Les sources d’origine restent conservées.").font(.callout).foregroundStyle(.secondary)
                HStack { Text(archiveDirectory.isEmpty ? "Aucun dossier d’archives choisi" : archiveDirectory).font(.caption.monospaced()).textSelection(.enabled); Spacer(); Button("Choisir le dossier…") { chooseArchiveDirectory() } }
                Text("Ce dossier sera proposé aux prochains imports, y compris après redémarrage. Aucun dossier de remplacement n’est choisi automatiquement.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Les ULog restent à leur emplacement actuel. Leur résumé reste consultable après retrait de la carte SD ; recalcul et nouvelles courbes nécessitent une source accessible.").font(.callout).foregroundStyle(.secondary)
            }
            }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout) }
            Spacer(minLength: 0)
            HStack { Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(copy ? "Copier et analyser" : "Analyser") { apply() }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true)).keyboardShortcut(.defaultAction).disabled(!canApply() || (copy && archiveDirectory.isEmpty)) }
        }.padding(24).frame(width: 700, height: 480).foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette)).tint(palette.primary)
        .onAppear { archiveDirectory = initialState.archiveDirectory ?? ""; copy = initialCopy }
    }
    private func conservationButton(_ title: String, copies: Bool) -> some View {
        Button { copy = copies } label: {
            HStack(spacing: 7) {
                Image(systemName: "checkmark").opacity(copy == copies ? 1 : 0)
                Text(title)
            }
        }
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
            .accessibilityAddTraits(copy == copies ? .isSelected : [])
    }
    private func chooseArchiveDirectory() {
        let panel = NSOpenPanel(); panel.title = "Choisir mon dossier d’archives ULog"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if !archiveDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: archiveDirectory) }
        if panel.runModal() == .OK, let url = panel.url { archiveDirectory = url.path }
    }
    private func apply() {
        do { try onApply(copy ? URL(fileURLWithPath: archiveDirectory, isDirectory: true) : nil); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
