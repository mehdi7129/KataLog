import SwiftUI
import KataLogCore

/// Includes controller identities with no imported logs, including offline fleet members.
struct DroneRegistryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var gcs: GCSStore
    @ObservedObject var annotations: DroneAnnotationStore
    let onExplore: (FlightLog) -> Void
    @State private var search = ""
    @State private var editing: DroneIdentityTarget?
    private struct Entry: Identifiable {
        let id: String
        let rawID: String
        let name: String
        let sourceName: String
        let logs: [FlightLog]
        let online: Bool
        let inFleet: Bool
    }
    private var entries: [Entry] {
        let byKey = Dictionary(grouping: library.snapshot.logs, by: \.annotationKey)
        let gcsKeys = gcs.allowedUUIDs.map { "gcs:" + $0 }
        let keys = Set(byKey.keys).union(gcsKeys).union(annotations.state.stockNumbers.keys)
        return keys.map { key in
            let logs = byKey[key] ?? []
            let uuid = key.hasPrefix("gcs:") ? String(key.dropFirst(4)) : nil
            let raw = uuid ?? String(key.dropFirst(5))
            let source = logs.first?.droneName ?? ""
            let fallback = source.isEmpty ? (raw.count > 22 ? "\(raw.prefix(10))…\(raw.suffix(6))" : raw) : source
            return Entry(id: key, rawID: raw, name: annotations.state.stockNumbers[key].map { "Drone " + $0 } ?? fallback,
                         sourceName: source, logs: logs,
                         online: uuid.map { id in gcs.isConnected && gcs.drones.contains { $0.uuid == id && $0.isOnline } } ?? false,
                         inFleet: uuid.map(gcs.allowedUUIDs.contains) ?? false)
        }.filter { row in search.isEmpty || [row.name, row.sourceName, row.rawID].contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedSame ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Identités de vos drones").font(.title3.weight(.semibold))
                    Text("Numérotation locale · chaque contrôleur conserve son historique distinct").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Numéro, nom ou UUID", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                    .accessibilityIdentifier("registry.search")
            }
            if let error = annotations.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("annotations.error")
            }
            if entries.isEmpty {
                Text("Aucune identité à afficher. Importez des logs ou ajoutez un drone à votre flotte depuis Collecte GCS.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
            }
            LazyVStack(spacing: 0) {
                ForEach(entries) { row in
                    HStack(spacing: 16) {
                        Image(systemName: "airplane").font(.title2).frame(width: 34)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.name).font(.system(size: 15, weight: .semibold))
                            if let warning = row.logs.compactMap(\.annotationWarning).first { Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            Text(row.rawID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(row.inFleet ? (row.online ? "Ma flotte · connecté" : "Ma flotte · hors ligne") : "Identité issue des logs")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.logs.isEmpty ? "Aucun log" : "\(row.logs.count) logs").font(.callout).foregroundStyle(.secondary)
                        Button(annotations.state.stockNumbers[row.id] == nil ? "Identifier…" : "Modifier le numéro…") {
                            editing = row.logs.first.map(DroneIdentityTarget.init(log:)) ?? DroneIdentityTarget(key: row.id, sourceName: row.sourceName)
                        }.controlSize(.small).accessibilityIdentifier("registry.identify.\(row.id)")
                        if let log = row.logs.first {
                            Button("Historique") { onExplore(log) }.controlSize(.small)
                                .accessibilityIdentifier("registry.history.\(row.id)")
                        }
                    }.padding(.vertical, 18)
                    Divider()
                }
            }
        }
        .padding(22).background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
        .sheet(item: $editing) { target in DroneNumberEditor(target: target, store: annotations) }
    }
}
