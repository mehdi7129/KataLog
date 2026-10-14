import SwiftUI
import KataLogCore

struct DroneIdentityTarget: Identifiable {
    let key: String
    let sourceName: String
    var stockNumber: String? = nil
    var legacyKey: String? = nil
    var warning: String? = nil
    var id: String { key }
    init(key: String, sourceName: String) { self.key = key; self.sourceName = sourceName }
    init(drone: LibraryDrone) {
        key = drone.id; sourceName = drone.name; stockNumber = drone.stockNumber
        if drone.id.hasPrefix("gcs:"), !drone.droneID.isEmpty { legacyKey = "ulog:" + drone.droneID }
    }
    init(log: FlightLog) {
        key = log.annotationKey; sourceName = log.droneName; stockNumber = log.stockNumber
        if log.annotationKey.hasPrefix("gcs:") { legacyKey = "ulog:" + log.droneID }
        warning = log.annotationWarning
    }
    init(gcsUUID: String, snapshot: FleetSnapshot, annotations: DroneAnnotationState) {
        let canonical = "gcs:" + gcsUUID.uppercased()
        let current = annotations.applying(to: snapshot)
        if let log = current.logs.first(where: { $0.annotationKey == canonical }) {
            self.init(log: log)
        } else {
            self.init(key: canonical, sourceName: "")
            stockNumber = annotations.stockNumbers[canonical]
        }
    }
}

/// Kept self-contained so both the paged and legacy registries use the same editor.
struct DroneNoteControl: View {
    let target: DroneIdentityTarget
    @ObservedObject var store: DroneAnnotationStore
    @State private var editing = false
    private var note: PersonalNote? { store.state.droneNotes[target.key] ?? target.legacyKey.flatMap { store.state.droneNotes[$0] } }
    var body: some View {
        Button(note == nil ? "Ajouter une note…" : "Note du drone…", systemImage: "note.text") { editing = true }
            .controlSize(.small).accessibilityIdentifier("notes.drone.\(target.key)")
            .sheet(isPresented: $editing) { PersonalNoteEditor(target: .drone(target), store: store) }
    }
}

struct FlightNotesPanel: View {
    let log: FlightLog
    @ObservedObject var store: DroneAnnotationStore
    @State private var editing = false
    var body: some View {
        FlightPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Notes personnelles").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(log.personalNote == nil ? "Ajouter une note au log…" : "Modifier la note du log…") { editing = true }
                        .controlSize(.small).accessibilityIdentifier("notes.log.edit")
                    DroneNoteControl(target: DroneIdentityTarget(log: log), store: store)
                }
                if let note = log.personalNote { noteContent(note, title: "Ce log") }
                if let note = log.droneNote { noteContent(note, title: "Ce drone · commune à ses logs") }
                if log.personalNote == nil && log.droneNote == nil {
                    Text("Conservez le contexte d’un essai ou vos conclusions. Les notes sont incluses dans les sauvegardes et les exports privés, et retirées des rapports partagés.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $editing) { PersonalNoteEditor(target: .log(id: log.id, name: log.fileName), store: store) }
    }
    private func noteContent(_ note: PersonalNote, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title) · \(PersonalNoteEditor.dateLabel(note.updatedAt))").font(.caption).foregroundStyle(.secondary)
            Text(note.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum PersonalNoteTarget {
    case log(id: String, name: String)
    case drone(DroneIdentityTarget)
    var title: String { switch self { case .log: "Note de ce log"; case .drone: "Note de ce drone" } }
    var context: String { switch self { case .log(_, let name): name; case .drone(let target): target.sourceName.isEmpty ? target.key : target.sourceName } }
    func existing(in state: DroneAnnotationState) -> PersonalNote? {
        switch self {
        case .log(let id, _): state.logNotes[id]
        case .drone(let target): state.droneNotes[target.key] ?? target.legacyKey.flatMap { state.droneNotes[$0] }
        }
    }
    func legacyConflict(in state: DroneAnnotationState) -> PersonalNote? {
        guard case .drone(let target) = self, let current = state.droneNotes[target.key],
              let key = target.legacyKey, let legacy = state.droneNotes[key], legacy.text != current.text else { return nil }
        return legacy
    }
}

private struct PersonalNoteEditor: View {
    let target: PersonalNoteTarget
    @ObservedObject var store: DroneAnnotationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var text = ""
    @State private var error: String?
    @State private var originalNote: PersonalNote?
    @State private var originalLegacyNote: PersonalNote?
    private var palette: Palette { Palette(dark: scheme == .dark) }
    private var existing: PersonalNote? { target.existing(in: store.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.title).font(.title2.weight(.semibold))
            Text(target.context).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let note = existing {
                Text("Créée le \(Self.dateLabel(note.createdAt)) · modifiée le \(Self.dateLabel(note.updatedAt))").font(.caption).foregroundStyle(.secondary)
            }
            if target.legacyConflict(in: store.state) != nil {
                Text("Deux notes locales existent pour cette identité. Leur contenu est réuni ci-dessous ; l’enregistrement remplacera ces deux notes par le texte que vous aurez validé.")
                    .font(.callout).foregroundStyle(.orange)
            }
            TextEditor(text: $text).font(.body).frame(minHeight: 210).padding(6)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.secondary.opacity(0.25)))
                .accessibilityIdentifier("notes.text").disabled(!store.isEditable)
            HStack {
                Text("\(text.count) / \(DroneAnnotationValidation.maximumNoteLength) caractères")
                Spacer()
                Text("Incluse dans les exports privés")
            }.font(.caption).foregroundStyle(.secondary)
            if !store.isEditable { Text("Bibliothèque occupée ou en lecture seule.").font(.callout).foregroundStyle(.secondary) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Retirer la note") { save(nil) }.disabled(existing == nil || !store.isEditable)
                    .accessibilityIdentifier("notes.remove")
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(text) }.keyboardShortcut(.defaultAction)
                    .buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true))
                    .disabled(!store.isEditable || text.count > DroneAnnotationValidation.maximumNoteLength)
                    .accessibilityIdentifier("notes.save")
            }
        }
        .padding(24).frame(width: 640).foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette)).tint(palette.primary)
        .onAppear {
            originalNote = existing
            originalLegacyNote = target.legacyConflict(in: store.state)
            text = existing?.text ?? ""
            if let legacy = target.legacyConflict(in: store.state) { text += "\n\n" + legacy.text }
        }
    }
    private func save(_ value: String?) {
        do {
            guard existing == originalNote, target.legacyConflict(in: store.state) == originalLegacyNote else {
                throw DroneAnnotationError.invalid("Cette note a changé dans une autre fenêtre. Copiez votre texte, puis rouvrez la note avant de l’enregistrer.")
            }
            switch target {
            case .log(let id, _): try store.setLogNote(value, forLogID: id)
            case .drone(let target): try store.setDroneNote(value, forKey: target.key, replacingLegacyKey: target.legacyKey)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    static func dateLabel(_ value: String) -> String {
        ISO8601DateFormatter().date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

struct DroneNumberEditor: View {
    let target: DroneIdentityTarget
    @ObservedObject var store: DroneAnnotationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var number = ""
    @State private var error: String?
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Identifier ce drone").font(.title2.weight(.semibold))
            BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
            Text("Le numéro est enregistré localement pour cette identité. Deux contrôleurs portant le même numéro restent distincts.")
                .font(.callout).foregroundStyle(.secondary)
            Text(target.key).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if !target.sourceName.isEmpty { Text("Nom source : \(target.sourceName)").font(.caption).foregroundStyle(.secondary) }
            if let warning = target.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if let legacy = target.legacyKey, store.state.stockNumbers[legacy] != nil {
                Text("Enregistrer ou retirer le numéro met aussi à jour l’ancienne annotation ULog de cette identité, en une seule opération.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Numéro du drone", text: $number).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("identity.number")
            Text("32 caractères maximum · les zéros initiaux sont conservés").font(.caption).foregroundStyle(.secondary)
            }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).accessibilityIdentifier("identity.error") }
            HStack {
                Button("Retirer le numéro") { save(nil) }.disabled(store.state.stockNumbers[target.key] == nil && target.stockNumber == nil)
                    .accessibilityIdentifier("identity.reset")
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(number) }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("identity.save")
            }
        }
        .padding(24).frame(width: 620).foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette)).tint(palette.primary)
        .onAppear { number = store.state.stockNumbers[target.key] ?? target.stockNumber ?? "" }
    }
    private func save(_ value: String?) {
        do { try store.setStockNumber(value, forKey: target.key, replacingLegacyKey: target.legacyKey); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct MessageClassificationControl: View {
    let message: LogMessage
    @ObservedObject var store: DroneAnnotationStore
    let families: [String]
    @State private var editing = false
    var body: some View {
        HStack(spacing: 9) {
            Text(store.state.familyOverride(for: message) == nil ? "Famille détectée : \(message.family)" : "Famille personnalisée : \(message.family)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Classer…") { editing = true }.controlSize(.small)
                .accessibilityIdentifier("classification.edit")
        }
        .sheet(isPresented: $editing) { MessageFamilyEditor(message: message, store: store, families: families) }
    }
}

private struct MessageFamilyEditor: View {
    let message: LogMessage
    @ObservedObject var store: DroneAnnotationStore
    let families: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var family = ""
    @State private var custom = false
    @State private var error: String?
    private var palette: Palette { Palette(dark: scheme == .dark) }
    private var choices: [String] { Set(families + Array(store.state.familyOverrides.values) + [message.family, message.sourceFamily ?? message.family]).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Classer ces messages").font(.title2.weight(.semibold))
            BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
            Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(5)
            Text("S’applique au même texte et au même niveau dans tous les logs, présents et futurs. Seuls les espaces sont normalisés. Le texte et la sévérité source sont conservés.")
                .font(.callout).foregroundStyle(.secondary)
            if custom {
                TextField("Nom de la famille", text: $family).textFieldStyle(.roundedBorder).accessibilityIdentifier("classification.custom")
                Button("Choisir une famille existante") { custom = false; family = choices.first ?? message.family }
            } else {
                Picker("Famille", selection: $family) { ForEach(choices, id: \.self) { Text($0).tag($0) } }
                    .accessibilityIdentifier("classification.family")
                Button("Autre famille…") { custom = true; family = "" }.accessibilityIdentifier("classification.other")
            }
            Text("Détection d’origine : \(message.sourceFamily ?? message.family) · 48 caractères maximum").font(.caption).foregroundStyle(.secondary)
            }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Rétablir la détection") { save(nil) }.disabled(store.state.familyOverride(for: message) == nil)
                    .accessibilityIdentifier("classification.reset")
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(family) }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("classification.save")
            }
        }
        .padding(24).frame(width: 660).foregroundStyle(palette.primary).background(palette.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette)).tint(palette.primary)
        .onAppear { family = message.family }
    }
    private func save(_ value: String?) {
        do { try store.setFamily(value, for: message); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
