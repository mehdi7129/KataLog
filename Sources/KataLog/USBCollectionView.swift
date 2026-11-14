import SwiftUI
import KataLogCore

struct USBCollectionView: View {
    @ObservedObject var store: USBCollectionStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("USB direct", systemImage: "cable.connector").font(.headline)
                    Spacer()
                    if store.isBusy { ProgressView().controlSize(.small) }
                    Button("Actualiser les ports") { store.refreshPorts() }.disabled(store.isBusy || store.mutationsBlocked)
                }
                Text("Branchez le drone ou AquaDrone désarmé et libérez son port dans QGroundControl.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Port", selection: $store.port) {
                        Text("Sélectionner…").tag("")
                        ForEach(store.ports) { port in Text("\(port.label) — \(port.path)").tag(port.path) }
                    }.frame(maxWidth: .infinity)
                    Picker("Baud", selection: $store.baud) {
                        ForEach([57600, 115200, 230400, 460800, 921600], id: \.self) { Text(String($0)).tag($0) }
                    }.frame(width: 165)
                    Button("Lire les logs") { store.readInventory() }.disabled(store.port.isEmpty)
                }.disabled(store.isBusy || store.mutationsBlocked)
                if let device = store.device, store.hasCurrentInventory {
                    Text("\(device.label) · \(device.identity)").font(.caption.monospaced()).textSelection(.enabled)
                    if store.logs.isEmpty { Text("Aucun log disponible sur cet appareil.").foregroundStyle(.secondary) }
                    else {
                        HStack {
                            Text("\(store.logs.count) logs · \(store.selection.count) sélectionné(s)").font(.subheadline)
                            Spacer()
                            Button("Tout sélectionner") { store.selection = Set(store.logs.map(\.id)) }.disabled(store.isReadingInventory || store.mutationsBlocked)
                            Button("Ajouter à la file") { store.enqueueSelected() }.disabled(!store.canAdd)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(store.logs) { log in
                                    Toggle(isOn: Binding(get: { store.selection.contains(log.id) }, set: { selected in
                                        if selected { store.selection.insert(log.id) } else { store.selection.remove(log.id) }
                                    })) {
                                        HStack {
                                            Text("Log \(log.id)").monospacedDigit()
                                            Text(log.timeUTC > 0 ? Date(timeIntervalSince1970: Double(log.timeUTC)).formatted(date: .abbreviated, time: .shortened) : "Date inconnue")
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(ByteCountFormatter.string(fromByteCount: log.size, countStyle: .file)).monospacedDigit()
                                        }
                                    }.toggleStyle(.checkbox).disabled(store.isReadingInventory || store.mutationsBlocked)
                                }
                            }.padding(4)
                        }.frame(maxHeight: 230)
                    }
                }
                HStack {
                    Button(store.isPaused ? "Reprendre cet appareil" : "Pause après ce fichier") {
                        if store.isPaused { store.resume() } else { store.pause() }
                    }.disabled(store.mutationsBlocked || (store.isPaused && (store.isBusy || !store.hasCurrentInventory)))
                    Button("Arrêter") { store.stop() }.disabled(!store.isBusy)
                    Spacer()
                    Text("\(store.pendingCount) en attente").font(.callout).foregroundStyle(.secondary)
                }
                if let message = store.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                if let error = store.errorMessage { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if !store.queue.isEmpty {
                    Divider()
                    Text("File USB · demandes conservées par appareil").font(.subheadline.weight(.semibold))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.queue) { job in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(job.log.filename).font(.callout)
                                        Spacer()
                                        Text(status(job)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(job.device.identity).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    if job.isActive { ProgressView(value: job.progress) }
                                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }.padding(4)
                    }.frame(maxHeight: 250)
                }
                Text("Pour préparer plusieurs appareils : mettez la file en pause, ajoutez leurs logs successivement, puis reconnectez chaque appareil et reprenez sa file. Les originaux restent sur la carte SD.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        .accessibilityIdentifier("collection.usb")
    }

    private func status(_ job: USBLogTransfer) -> String {
        switch job.state {
        case "queued": return job.device.identity == store.device?.identity ? "En attente" : "Attente de cet appareil"
        case "downloading": return "Téléchargement \(Int(job.progress * 100)) %"
        case "importing": return "Analyse…"
        case "downloaded": return "Copie vérifiée"
        case "complete": return "Analysé"
        case "interrupted": return "Interrompu · reprise manuelle"
        default: return "Échec · reprise manuelle"
        }
    }
}
