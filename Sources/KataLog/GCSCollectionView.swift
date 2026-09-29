import AppKit
import SwiftUI
import KataLogCore

/// Read-only log collection. Fleet membership is an explicit choice by the operator.
struct GCSCollectionView: View {
    @ObservedObject var store: GCSStore
    @ObservedObject var library: LibraryStore
    let dark: Bool
    @State private var droneSearch = ""
    @State private var fileSearch = ""
    @State private var showUnknown = true
    @State private var showTransfers = true
    @State private var editingIdentity: DroneIdentityTarget?

    private var palette: GCSCollectionPalette { .init(dark: dark) }
    private var fleet: [GCSDrone] { store.drones.filter { store.allowedUUIDs.contains($0.uuid) } }
    private var unknown: [GCSDrone] { store.drones.filter { !store.allowedUUIDs.contains($0.uuid) && $0.isOnline } }
    private var visibleFleet: [GCSDrone] {
        fleet.filter { droneSearch.isEmpty || [$0.uuid, library.annotations.displayName(forGCSUUID: $0.uuid)].contains { $0.localizedCaseInsensitiveContains(droneSearch) } }
    }
    private var selectedDrone: GCSDrone? { store.drones.first { $0.uuid == store.selectedUUID } }
    private var visibleFiles: [GCSLogFile] {
        store.files.filter { fileSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(fileSearch) }
    }
    private var allNewFilesSelected: Bool {
        let newIDs = Set(store.files.filter { !$0.isDownloaded }.map(\.id))
        return !newIDs.isEmpty && store.selectedFileIDs == newIDs
    }
    private var canReadSelectedDrone: Bool {
        guard let drone = selectedDrone else { return false }
        return store.isConnected && drone.isOnline && drone.armed != true && store.allowedUUIDs.contains(drone.uuid)
    }
    private var activeTransfer: GCSTransfer? {
        store.queue.first { ["downloading", "importing"].contains($0.state) }
    }
    private var pendingCount: Int { store.queue.filter { ["queued", "retrying"].contains($0.state) }.count }
    private var retryCount: Int { store.queue.filter { ["failed", "interrupted", "stopped"].contains($0.state) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(alignment: .top, spacing: 18) {
                networkCard.frame(maxWidth: .infinity)
                optionsCard.frame(width: 290)
            }
            messages
            batchProgressCard
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                fleetCard
            }
            if store.selectedUUID != nil { inventoryCard }
            if !store.queue.isEmpty { transferCard }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                unknownCard
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle").font(.system(size: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Récupération des logs uniquement.").font(.system(size: 12, weight: .medium))
                    Text("Les originaux restent sur les drones. Seuls les appareils ajoutés à votre flotte peuvent être collectés.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            .foregroundStyle(palette.primary).padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .sheet(item: $editingIdentity) { target in DroneNumberEditor(target: target, store: library.annotations) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Collecte des logs").font(.system(size: 32, weight: .semibold)).tracking(-1.2)
                    .foregroundStyle(palette.primary)
                Text("Les drones de votre flotte, depuis votre GCS.")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 10)
            Label("Lecture seule", systemImage: "lock")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 9))
            action("Tout collecter", symbol: "arrow.down.to.line", primary: true) {
                store.collectAll()
            }
            .disabled(!store.canCollectAll)
            .help("Recenser et collecter les nouveaux logs de tous les drones autorisés actuellement connectés.")
            .accessibilityIdentifier("gcs.collectAll")
            action("Arrêter", symbol: "stop.fill") { store.stopCollection() }
                .disabled(!store.canStopCollection)
                .help("Arrêter immédiatement la collecte sur ce Mac et annuler les transferts en attente.")
                .accessibilityIdentifier("gcs.stop")
        }
    }

    private var batchProgressCard: some View {
        let progress = store.batchProgress
        let fraction = min(max(progress.fraction, 0), 1)
        return card(padding: 22) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    title("Progression globale")
                    Text(batchStatus(progress))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if store.isScanningFleet {
                    ProgressView().controlSize(.small)
                }
                Text(progress.totalCount == 0 ? "—" : "\(Int(fraction * 100))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .tracking(-1.5).monospacedDigit()
                if progress.totalCount > 0 {
                    Text("%").font(.system(size: 20, weight: .medium)).foregroundStyle(palette.secondary)
                        .padding(.leading, -10)
                }
            }
            .foregroundStyle(palette.primary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.raised)
                    Capsule().fill(progress.stoppedCount > 0 && progress.activeCount == 0 ? palette.amber : palette.mint)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progression du transfert")
            .accessibilityValue(progress.totalCount == 0 ? "Aucun téléchargement nécessaire" : "\(Int(fraction * 100)) pour cent, \(progress.completedCount) fichiers vérifiés sur \(progress.totalCount)")
            .accessibilityIdentifier("gcs.batchProgress")

            HStack(alignment: .center, spacing: 16) {
                Text(progress.totalCount == 0 ? (store.cachedFileCount > 0 ? "\(store.cachedFileCount) logs déjà présents" : "Aucun fichier en collecte") : "\(progress.completedCount) / \(progress.totalCount) fichiers vérifiés")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.primary)
                if progress.totalCount > 0 {
                    Text("\(bytes(progress.completedBytes)) / \(bytes(progress.totalBytes))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondary)
                }
                Spacer()
                if store.isQueuePaused && (pendingCount > 0 || activeTransfer != nil) {
                    action("Reprendre", symbol: "play.fill") { store.resumeQueue() }
                        .disabled(!store.isConnected)
                        .accessibilityIdentifier("gcs.resume")
                } else if pendingCount > 0 || activeTransfer != nil {
                    action("Mettre en pause", symbol: "pause.fill") { store.pauseQueue() }
                        .accessibilityIdentifier("gcs.pause")
                }
            }

            HStack(spacing: 15) {
                statusDot("\(store.activeTransferCount) / \(store.maxConcurrentDownloads) drones en transfert", color: store.activeTransferCount > 0 ? palette.mint : palette.secondary)
                Text("\(progress.pendingCount) en attente").font(.system(size: 11)).foregroundStyle(palette.secondary)
                if progress.failedCount > 0 { statusDot("\(progress.failedCount) en échec", color: palette.amber) }
                if progress.stoppedCount > 0 { statusDot("\(progress.stoppedCount) arrêté(s)", color: palette.amber) }
                Spacer()
            }

            if store.isQueuePaused && activeTransfer != nil {
                message("La pause prendra effet à la fin des fichiers en cours.", symbol: "pause.circle", color: palette.amber)
            }
            if fraction >= 1 && progress.completedCount < progress.totalCount && progress.activeCount > 0 {
                message("Transfert terminé · vérification des fichiers et analyse en cours.", symbol: "checkmark.shield", color: palette.secondary)
            }
            if store.canStopCollection || progress.stoppedCount > 0 {
                Text("L’arrêt est immédiat sur ce Mac. La GCS peut terminer un transfert déjà lancé.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            if !store.inventoryErrors.isEmpty {
                rule
                VStack(alignment: .leading, spacing: 7) {
                    message("\(store.inventoryErrors.count) inventaire(s) non récupéré(s)", symbol: "exclamationmark.triangle", color: palette.amber)
                    ForEach(Array(store.inventoryErrors.prefix(3).enumerated()), id: \.offset) { _, error in
                        Text(error).font(.system(size: 11)).foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if store.inventoryErrors.count > 3 {
                        Text("Et \(store.inventoryErrors.count - 3) autre(s). Relancez « Tout collecter » pour réessayer les inventaires manquants.")
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                }
            }
        }
    }

    private func batchStatus(_ progress: GCSBatchProgress) -> String {
        if store.isScanningFleet { return "Lecture des inventaires de la flotte · \(store.cachedFileCount) logs déjà présents" }
        if progress.totalCount == 0 && store.cachedFileCount > 0 { return "À jour · \(store.cachedFileCount) logs déjà présents et vérifiés." }
        if progress.totalCount == 0 { return "Collectez toute la flotte connectée ou sélectionnez les logs d’un drone." }
        if progress.stoppedCount > 0 && progress.activeCount == 0 && progress.pendingCount == 0 {
            return "Collecte arrêtée · les fichiers déjà vérifiés sont conservés."
        }
        if progress.completedCount == progress.totalCount { return "Collecte terminée · tous les fichiers ont été vérifiés." }
        if store.isQueuePaused { return activeTransfer == nil ? "Collecte en pause" : "Pause demandée · les fichiers en cours se terminent" }
        if progress.activeCount > 0 { return "Collecte en cours · jusqu’à \(store.maxConcurrentDownloads) drones simultanément" }
        if store.queue.contains(where: { $0.state == "retrying" }) { return "Nouvel essai automatique programmé pour les transferts interrompus." }
        if progress.pendingCount > 0 { return "En attente d’un drone disponible ou de la fin du transfert GCS précédent." }
        if progress.stoppedCount > 0 { return "Collecte arrêtée · les fichiers déjà vérifiés sont conservés." }
        if progress.failedCount > 0 { return "Collecte terminée avec des erreurs · relancez les fichiers concernés." }
        return "Les fichiers téléchargés sont conservés sur ce Mac."
    }

    private var networkCard: some View {
        card {
            title("Réseau et sources")
            HStack(spacing: 10) {
                networkNode(symbol: "desktopcomputer", label: "Réseau GCS",
                            detail: store.isConnected ? "GCS connectée" : store.isConnecting ? "Connexion…" : "Non connectée",
                            highlighted: store.isConnected)
                connector
                networkNode(symbol: "airplane", label: "Ma flotte enregistrée",
                            detail: "\(store.allowedUUIDs.count) appareil\(store.allowedUUIDs.count == 1 ? "" : "s")",
                            highlighted: false)
                connector
                networkNode(symbol: "externaldrive", label: "Bibliothèque locale",
                            detail: "Stockage sur ce Mac", highlighted: false)
            }
            .padding(.vertical, 8)
            rule
            HStack(spacing: 10) {
                Text("GCS").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                TextField("Adresse IP ou nom de la GCS", text: $store.host)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
                    .disabled(store.isConnected || store.isConnecting || store.isBusy)
                    .onSubmit { if !store.isConnected && !store.isConnecting { store.connect() } }
                    .accessibilityLabel("Adresse de la GCS")
                    .accessibilityIdentifier("gcs.host")
                action(store.isConnected ? "Déconnecter" : store.isConnecting ? "Annuler" : "Connecter",
                       symbol: store.isConnected ? "personalhotspot.slash" : "network") {
                    if store.isConnected || store.isConnecting { store.disconnect() } else { store.connect() }
                }
                .disabled(store.isBusy || (!store.isConnected && !store.isConnecting && store.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("gcs.connect")
            }
        }
    }

    private var optionsCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Analyser après collecte").font(.system(size: 13, weight: .semibold))
                    Text("Ajouter les nouveaux logs à KataLog.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                Toggle("Analyser après collecte", isOn: $store.autoImport).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small).tint(palette.mint)
                    .accessibilityIdentifier("gcs.autoImport")
            }
            rule.padding(.vertical, 3)
            HStack(spacing: 7) {
                Image(systemName: "folder")
                Text("Dossier de collecte").fontWeight(.medium)
            }
            .font(.system(size: 11)).foregroundStyle(palette.secondary)
            Text(store.downloadDirectory.path)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .help(store.downloadDirectory.path)
            if let issue = store.downloadDirectoryIssue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(palette.amber)
                    .accessibilityIdentifier("gcs.directoryIssue")
            } else {
                Label("Dossier accessible", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            Text("La page web GCS ouverte dans Edge peut aussi déclencher une copie dans Téléchargements. Fermez cette page pendant la collecte pour éviter ce doublon navigateur.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                action("Ouvrir", symbol: "arrow.up.forward.square") { store.revealDownloads() }
                    .accessibilityIdentifier("gcs.revealDownloads")
                action("Changer", symbol: "folder.badge.gearshape") { store.chooseDownloadDirectory() }
                    .disabled(store.isBusy || pendingCount > 0)
                    .accessibilityIdentifier("gcs.chooseDirectory")
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = store.errorMessage {
            message(error, symbol: "exclamationmark.triangle", color: palette.amber)
                .accessibilityIdentifier("gcs.error")
        } else if let message = store.statusMessage, !message.isEmpty {
            self.message(message, symbol: "info.circle", color: palette.secondary)
                .accessibilityIdentifier("gcs.status")
        }
    }

    private var fleetCard: some View {
        card(padding: 0) {
            HStack(spacing: 16) {
                title("Drones de ma flotte")
                Text("\(fleet.filter(\.isOnline).count) connecté\(fleet.filter(\.isOnline).count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer()
                if !fleet.isEmpty { searchField("Numéro ou UUID", text: $droneSearch).frame(width: 205) }
            }
            .padding(20)
            rule
            if fleet.isEmpty {
                emptyState(symbol: "airplane", title: store.allowedUUIDs.isEmpty ? "Votre flotte commence ici" : "Aucun drone de la flotte visible",
                           detail: store.allowedUUIDs.isEmpty
                            ? (store.isConnected ? "Ajoutez ci-dessous les drones que vous souhaitez retrouver et collecter." : "Connectez la GCS pour découvrir les drones, puis ajoutez-les à votre flotte.")
                            : "Vos \(store.allowedUUIDs.count) appareils sont enregistrés. Ils apparaîtront dès leur connexion à la GCS.")
            } else if visibleFleet.isEmpty {
                emptyState(symbol: "magnifyingglass", title: "Aucun drone correspondant", detail: "Modifiez votre recherche pour retrouver un drone.")
            } else {
                HStack(spacing: 14) {
                    Text("DRONE").frame(maxWidth: .infinity, alignment: .leading)
                    Text("ÉTAT").frame(width: 132, alignment: .leading)
                    Text("BATTERIE · WI-FI").frame(width: 120, alignment: .leading)
                    Text("COLLECTE").frame(width: 164, alignment: .leading)
                }
                .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(palette.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10)
                LazyVStack(spacing: 0) {
                    ForEach(visibleFleet) { drone in
                        rule
                        fleetRow(drone)
                    }
                }
            }
        }
    }

    private func fleetRow(_ drone: GCSDrone) -> some View {
        let selected = store.selectedUUID == drone.uuid
        let transfer = store.queue.last { $0.droneUUID == drone.uuid }
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(library.annotations.displayName(forGCSUUID: drone.uuid)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("Firmware \(drone.firmware.isEmpty ? "inconnu" : drone.firmware)")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                Button("Identifier…") { editingIdentity = identityTarget(drone.uuid) }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .accessibilityIdentifier("gcs.identify.\(drone.uuid)")
            }
            .frame(maxWidth: .infinity, alignment: .leading).help(drone.uuid)
            VStack(alignment: .leading, spacing: 5) {
                statusDot(drone.isOnline ? "Connecté" : "Hors ligne", color: drone.isOnline ? palette.mint : palette.secondary)
                Text(drone.armed.map { $0 ? "Armé · collecte bloquée" : "Désarmé" } ?? "Armement inconnu")
                    .font(.system(size: 10)).foregroundStyle(drone.armed == true ? palette.amber : palette.secondary)
            }
            .frame(width: 132, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(drone.battery.map { "\(Int(($0 * 100).rounded())) %" } ?? "Batterie inconnue")
                    .font(.system(size: 12)).monospacedDigit()
                Text(drone.rssi.map { "\($0) dBm" } ?? "Signal inconnu")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                action(selected ? "Actualiser les logs" : "Voir les logs", symbol: selected ? "arrow.clockwise" : "doc.text.magnifyingglass") {
                    if selected { store.refreshInventory() } else { fileSearch = ""; store.selectDrone(drone.uuid) }
                }
                .disabled(!store.isConnected || !drone.isOnline || drone.armed == true || store.isBusy)
                .accessibilityIdentifier("gcs.inventory.\(drone.uuid)")
                if let transfer {
                    Text(stateLabel(transfer.state)).font(.system(size: 10)).foregroundStyle(stateColor(transfer.state))
                }
            }
            .frame(width: 164, alignment: .leading)
        }
        .foregroundStyle(palette.primary).padding(.horizontal, 20).padding(.vertical, 14)
        .background(selected ? palette.raised.opacity(0.75) : .clear)
        .contextMenu {
            Button("Copier l’UUID") { copy(drone.uuid) }
            Button("Modifier le numéro…") { editingIdentity = identityTarget(drone.uuid) }
            Button("Retirer de ma flotte") { store.setAllowed(uuid: drone.uuid, allowed: false) }.disabled(store.isBusy)
        }
    }

    private var inventoryCard: some View {
        card(padding: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    title("Logs disponibles")
                    Text(store.selectedUUID.map { library.annotations.displayName(forGCSUUID: $0) } ?? "")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                }
                Spacer()
                searchField("Nom ou dossier…", text: $fileSearch).frame(width: 190)
                action("Actualiser", symbol: "arrow.clockwise") { store.refreshInventory() }
                    .disabled(!canReadSelectedDrone || store.isBusy)
                    .accessibilityIdentifier("gcs.refreshInventory")
                action("Collecter la sélection", symbol: "arrow.down.to.line", primary: true) { store.enqueueSelected() }
                    .disabled(!canReadSelectedDrone || store.selectedFileIDs.isEmpty || store.isScanningFleet || store.isStopping)
                    .accessibilityIdentifier("gcs.enqueue")
            }
            .padding(20)
            rule
            if !canReadSelectedDrone {
                message(selectedDrone?.armed == true ? "Ce drone est armé. La collecte est suspendue." : "Reconnectez ce drone pour actualiser ou collecter ses logs.", symbol: "pause.circle", color: palette.amber)
                    .padding(16)
            }
            if store.files.isEmpty {
                emptyState(symbol: store.isBusy ? "arrow.triangle.2.circlepath" : "doc",
                           title: store.isBusy ? "Lecture de l’inventaire…" : "Aucun log disponible",
                           detail: store.isBusy ? "L’inventaire peut prendre quelques instants." : "Actualisez l’inventaire pour rechercher les fichiers ULog.")
            } else {
                HStack(spacing: 14) {
                    Button(allNewFilesSelected ? "Tout désélectionner" : "Sélectionner les nouveaux") { store.selectAllFiles() }
                        .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                        .disabled(!canReadSelectedDrone).accessibilityIdentifier("gcs.selectAllFiles")
                    Spacer()
                    Text("\(store.selectedFileIDs.count) sélectionné\(store.selectedFileIDs.count == 1 ? "" : "s") · \(store.files.count) logs")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                LazyVStack(spacing: 0) {
                    ForEach(visibleFiles) { file in
                        rule
                        HStack(spacing: 12) {
                            Toggle("Sélectionner \(file.path)", isOn: Binding(
                                get: { store.selectedFileIDs.contains(file.id) },
                                set: { _ in store.toggleFile(file) }
                            ))
                            .toggleStyle(.checkbox).labelsHidden()
                            .disabled(file.isDownloaded || !canReadSelectedDrone)
                            .accessibilityIdentifier("gcs.file.\(file.id)")
                            Image(systemName: "doc.text").foregroundStyle(palette.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.filename).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text(file.dateFolder).font(.system(size: 10)).foregroundStyle(palette.secondary)
                            }
                            Spacer()
                            if file.isDownloaded { statusDot("Déjà collecté", color: palette.mint) }
                            Text(bytes(file.size)).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.secondary).frame(width: 80, alignment: .trailing)
                        }
                        .foregroundStyle(palette.primary).padding(.horizontal, 20).padding(.vertical, 12)
                    }
                }
                if visibleFiles.isEmpty {
                    Text("Aucun fichier correspondant à la recherche.").font(.system(size: 12))
                        .foregroundStyle(palette.secondary).padding(20)
                }
            }
        }
    }

    private var transferCard: some View {
        card(padding: 0) {
            HStack(spacing: 12) {
                DisclosureGroup(isExpanded: $showTransfers) {
                    EmptyView()
                } label: {
                    title("File de collecte · \(store.queue.count)")
                }
                Spacer()
                if retryCount > 0 {
                    action("Relancer (\(retryCount))", symbol: "arrow.clockwise") { store.retryFailed() }
                        .disabled(!store.isConnected || store.isBusy)
                        .accessibilityIdentifier("gcs.retry")
                }
            }
            .padding(20)
            if showTransfers {
                LazyVStack(spacing: 0) {
                    ForEach(store.queue.reversed()) { transfer in
                        rule
                        transferRow(transfer)
                    }
                }
            }
            rule
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle")
                Text("\(store.batchProgress.completedCount) vérifié(s) · \(pendingCount) en attente")
                Spacer()
                if library.isImporting {
                    ProgressView().controlSize(.small)
                    Text("Analyse des logs…")
                } else {
                    Text("\(library.snapshot.logs.count) logs dans la bibliothèque")
                }
            }
            .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(17)
        }
    }

    private func transferRow(_ transfer: GCSTransfer) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: transferSymbol(transfer.state))
                .font(.system(size: 17)).foregroundStyle(stateColor(transfer.state))
            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.filename).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(library.annotations.displayName(forGCSUUID: transfer.droneUUID)).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                if transfer.attemptCount > 1 {
                    Text("Tentative \(transfer.attemptCount)").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                if let error = transfer.error, !error.isEmpty {
                    Text(error).font(.system(size: 11)).foregroundStyle(palette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(stateLabel(transfer.state)).foregroundStyle(stateColor(transfer.state))
                    Spacer()
                    if transfer.state == "downloading" {
                        Text("\(Int(min(max(transfer.progress, 0), 1) * 100)) %").foregroundStyle(palette.secondary)
                    }
                }
                .font(.system(size: 10)).monospacedDigit()
                if ["downloading", "queued", "retrying", "interrupted", "stopped"].contains(transfer.state) {
                    ProgressView(value: min(max(transfer.progress, 0), 1)).tint(stateColor(transfer.state))
                }
                if transfer.state == "retrying", let nextRetry = transfer.nextRetryAt {
                    HStack(spacing: 4) {
                        Text("Nouvel essai")
                        if nextRetry > Date() { Text(nextRetry, style: .relative).monospacedDigit() }
                        else { Text("en attente de connexion") }
                    }
                    .font(.system(size: 10)).foregroundStyle(palette.amber)
                }
                Text("\(bytes(transfer.completedBytes)) / \(bytes(transfer.size))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
            }
            .frame(width: 205)
        }
        .foregroundStyle(palette.primary).padding(.horizontal, 20).padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gcs.transfer.\(transfer.id)")
    }

    private var unknownCard: some View {
        card {
            DisclosureGroup(isExpanded: $showUnknown) {
                VStack(alignment: .leading, spacing: 0) {
                    if unknown.isEmpty {
                        Text(store.isConnected ? "Aucun appareil à ajouter pour le moment." : "Les appareils détectés apparaîtront ici après connexion.")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 14)
                    }
                    ForEach(unknown) { drone in
                        HStack(spacing: 14) {
                            Image(systemName: "airplane").font(.system(size: 19)).foregroundStyle(palette.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(library.annotations.displayName(forGCSUUID: drone.uuid)).font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .help(drone.uuid)
                                statusDot("À identifier · aucun téléchargement", color: palette.amber)
                            }
                            Spacer()
                            Button("Identifier…") { editingIdentity = identityTarget(drone.uuid) }
                                .controlSize(.small).accessibilityIdentifier("gcs.identifyUnknown.\(drone.uuid)")
                            action("Ajouter à ma flotte", symbol: "plus") { store.setAllowed(uuid: drone.uuid, allowed: true) }
                                .disabled(store.isBusy).accessibilityIdentifier("gcs.allow.\(drone.uuid)")
                        }
                        .padding(.top, 18)
                        .contextMenu { Button("Copier l’UUID") { copy(drone.uuid) } }
                    }
                }
            } label: {
                Text("Appareils non enregistrés · \(unknown.count)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.primary)
            }
            .accessibilityIdentifier("gcs.unregistered")
        }
    }

    private var connector: some View {
        HStack(spacing: 0) {
            Circle().frame(width: 3, height: 3)
            Rectangle().frame(height: 1)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(palette.secondary.opacity(0.6)).frame(minWidth: 12, maxWidth: 46).padding(.bottom, 43)
        .accessibilityHidden(true)
    }

    private func networkNode(symbol: String, label: String, detail: String, highlighted: Bool) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 20))
                .frame(width: 46, height: 46).background(palette.raised, in: Circle())
                .overlay(Circle().stroke(palette.border, lineWidth: 1))
            Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.9)
            Text(detail).font(.system(size: 10)).foregroundStyle(highlighted ? palette.mint : palette.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(palette.primary).frame(maxWidth: .infinity)
    }

    private func card<Content: View>(padding: CGFloat = 20, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: padding == 0 ? 0 : 14, content: content)
            .padding(padding).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func action(_ label: String, symbol: String, primary: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(label, systemImage: symbol).font(.system(size: 11, weight: primary ? .semibold : .medium))
        }
        .buttonStyle(GCSActionStyle(palette: palette, primary: primary))
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).tracking(-0.25).foregroundStyle(palette.primary)
    }

    private func statusDot(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(color)
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.system(size: 12)).foregroundStyle(color)
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(palette.secondary).padding(.bottom, 3)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.primary)
            Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 450)
        }
        .frame(maxWidth: .infinity).padding(32)
    }

    private func searchField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
            TextField(placeholder, text: text).textFieldStyle(.plain).accessibilityLabel(placeholder)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(palette.secondary).accessibilityLabel("Effacer la recherche")
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 9).frame(height: 32)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
    }

    private var rule: some View { palette.border.frame(height: 1) }
    private func identityTarget(_ uuid: String) -> DroneIdentityTarget {
        DroneIdentityTarget(gcsUUID: uuid, snapshot: library.snapshot, annotations: library.annotations.state)
    }
    private func shortUUID(_ uuid: String) -> String { uuid.count > 18 ? "\(uuid.prefix(8))…\(uuid.suffix(6))" : uuid }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(count, 0), countStyle: .file) }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func stateLabel(_ state: String) -> String {
        switch state {
        case "queued": "En attente"
        case "downloading": "Récupération"
        case "downloaded": "Téléchargé"
        case "importing": "Analyse en cours"
        case "complete": "Terminé"
        case "failed": "Échec"
        case "interrupted": "Interrompu"
        case "retrying": "Nouvel essai prévu"
        case "stopped": "Arrêté"
        default: state
        }
    }
    private func stateColor(_ state: String) -> Color {
        switch state {
        case "complete", "downloading", "importing", "downloaded": palette.mint
        case "failed", "interrupted", "retrying", "stopped": palette.amber
        default: palette.secondary
        }
    }

    private func transferSymbol(_ state: String) -> String {
        switch state {
        case "complete", "downloaded": "checkmark.circle"
        case "failed", "interrupted": "exclamationmark.circle"
        case "retrying": "arrow.clockwise.circle"
        case "stopped": "stop.circle"
        default: "doc.text"
        }
    }
}

private struct GCSActionStyle: ButtonStyle {
    let palette: GCSCollectionPalette
    let primary: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .padding(.horizontal, 11).frame(height: primary ? 39 : 32)
            .foregroundStyle(primary ? palette.background : palette.primary)
            .background(primary ? palette.primary : palette.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? .clear : palette.border, lineWidth: 1))
            .opacity(enabled ? configuration.isPressed ? 0.7 : 1 : 0.4)
    }
}

private struct GCSCollectionPalette {
    let dark: Bool
    var background: Color { color(dark ? 0x0B0B0B : 0xF7F7F5) }
    var card: Color { color(dark ? 0x191919 : 0xFFFFFF) }
    var raised: Color { color(dark ? 0x222222 : 0xF2F2EF) }
    var border: Color { color(dark ? 0x303030 : 0xE1E1DC) }
    var primary: Color { color(dark ? 0xF3F3F1 : 0x171717) }
    var secondary: Color { color(dark ? 0xA4A4A4 : 0x666666) }
    var mint: Color { color(dark ? 0x8BC4AC : 0x397E61) }
    var amber: Color { color(dark ? 0xE3B771 : 0x956019) }
    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
