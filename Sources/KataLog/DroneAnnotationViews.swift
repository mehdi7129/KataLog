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
    init(log: FlightLog) {
        key = log.annotationKey; sourceName = log.droneName; stockNumber = log.stockNumber
        if log.annotationGCSUUID != nil { legacyKey = "ulog:" + log.droneID }
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

struct DroneNumberEditor: View {
    let target: DroneIdentityTarget
    @ObservedObject var store: DroneAnnotationStore
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Identifier ce drone").font(.title2.weight(.semibold))
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
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).accessibilityIdentifier("identity.error") }
            HStack {
                Button("Retirer le numéro") { save(nil) }.disabled(store.state.stockNumbers[target.key] == nil && target.stockNumber == nil)
                    .accessibilityIdentifier("identity.reset")
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(number) }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("identity.save")
            }
        }
        .padding(26).frame(width: 540)
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
    @State private var family = ""
    @State private var custom = false
    @State private var error: String?
    private var choices: [String] { Set(families + Array(store.state.familyOverrides.values) + [message.family, message.sourceFamily ?? message.family]).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Classer ces messages").font(.title2.weight(.semibold))
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
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Rétablir la détection") { save(nil) }.disabled(store.state.familyOverride(for: message) == nil)
                    .accessibilityIdentifier("classification.reset")
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(family) }.keyboardShortcut(.defaultAction)
                    .disabled(family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("classification.save")
            }
        }
        .padding(26).frame(width: 580)
        .onAppear { family = message.family }
    }
    private func save(_ value: String?) {
        do { try store.setFamily(value, for: message); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
