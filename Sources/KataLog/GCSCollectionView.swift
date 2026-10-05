import AppKit
import SwiftUI
import KataLogCore

/// Connected devices are admitted automatically when their logs are requested.
struct GCSCollectionView: View {
    @ObservedObject var store: GCSStore
    @ObservedObject var library: LibraryStore
    let dark: Bool
    @State private var droneSearch = ""
    @State private var fileSearch = ""
    @State private var showTransfers = false
    @State private var showInventories = false
    @State private var editingIdentity: DroneIdentityTarget?

    private var palette: Palette { .init(dark: dark) }
    private var mutationsBlocked: Bool { store.isReadOnly || store.isMaintenanceBlocked }
    private var fleet: [GCSDrone] { store.drones.filter(\.isOnline) }
    private var visibleFleet: [GCSDrone] {
        fleet.filter { droneSearch.isEmpty || [$0.uuid, library.annotations.displayName(forGCSUUID: $0.uuid)].contains { $0.localizedCaseInsensitiveContains(droneSearch) } }
    }
    private var selectedDrone: GCSDrone? { store.drones.first { $0.uuid == store.selectedUUID } }
    private var visibleFiles: [GCSLogFile] {
        store.files.filter { fileSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(fileSearch) }
    }
    private var allNewFilesSelected: Bool {
        !visibleNewFileIDs.isEmpty && visibleNewFileIDs.isSubset(of: store.selectedFileIDs)
    }
    private var visibleNewFileIDs: Set<String> { Set(visibleFiles.filter { !$0.isDownloaded }.map(\.id)) }
    private var hiddenSelectedCount: Int { store.selectedFileIDs.subtracting(Set(visibleFiles.map(\.id))).count }
    private var libraryCountLabel: String {
        if library.isImporting { return "Analyse des logs…" }
        if library.historyResultsCurrent, let total = library.historyPage?.totals.logs {
            return "\(total) log\(total == 1 ? "" : "s") dans la sélection de la bibliothèque"
        }
        return library.isQuerying || library.isLoading ? "Lecture de la bibliothèque…" : "Consultez les analyses dans Historique."
    }
    private var canReadSelectedDrone: Bool {
        guard let drone = selectedDrone else { return false }
        return !mutationsBlocked && store.isConnected && drone.isOnline && drone.armed != true
    }
    private var activeTransfer: GCSTransfer? {
        store.queue.first { ["downloading", "importing"].contains($0.state) }
    }
    private var pendingCount: Int { store.queue.filter { ["queued", "retrying"].contains($0.state) }.count }
    private var retryCount: Int { store.retryableCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            BentoColumns(firstMinimum: 330, secondMinimum: 330) {
                networkCard
                destinationCard
            }
            messages
            batchProgressCard
            BentoColumns(firstMinimum: 430, secondMinimum: 320, secondWidth: 350) {
                TimelineView(.periodic(from: .now, by: 2)) { _ in fleetCard }
                optionsCard
            }
            if store.selectedUUID != nil {
                card {
                    DisclosureGroup(isExpanded: $showInventories) {
                        inventoryCard.padding(.top, 14)
                    } label: {
                        HStack(spacing: 10) {
                            BentoIcon(symbol: "doc.text.magnifyingglass")
                            title("Inventaire du drone sélectionné")
                            Spacer(minLength: 4)
                            Text("\(store.files.count) logs")
                                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        }
                    }
                    .accessibilityIdentifier("gcs.inventories")
                }
            }
            HStack(alignment: .top, spacing: 9) {
                BentoIcon(symbol: "info.circle", size: 14)
                Text("La collecte copie les logs sans commande de vol. Les originaux restent sur les drones. La destination et la progression sont propres au dossier choisi.")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.secondary)
        }
        .sheet(item: $editingIdentity) { target in DroneNumberEditor(target: target, store: library.annotations) }
        .onAppear { updateClientDestination() }
        .onChange(of: library.views.state.activeScope.clientID) { _, _ in updateClientDestination() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                heading
                Spacer(minLength: 10)
                collectionActions
            }
            VStack(alignment: .leading, spacing: 16) {
                heading
                collectionActions
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collecte GCS").font(.system(size: 28, weight: .semibold)).tracking(-1)
                .foregroundStyle(palette.primary)
            Text("Drones connectés à cette GCS.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
            Text("Nouveaux logs → " + store.collectionClientName)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
                .help("Le client destinataire se choisit dans Options de collecte. Les logs déjà connus gardent leur attribution.")
                .accessibilityIdentifier("gcs.clientDestination")
        }
    }

    private var collectionActions: some View {
        HStack(spacing: 10) {
            action("Arrêter", symbol: "stop") { store.stopCollection() }
                .disabled(!store.canStopCollection)
                .help("Arrêter immédiatement la collecte sur ce Mac et annuler les transferts en attente.")
                .accessibilityIdentifier("gcs.stop")
            action("Tout collecter", symbol: "arrow.down.to.line", primary: true) {
                store.collectAll()
            }
            .disabled(!store.canCollectAll)
            .help("Ajouter à la bibliothèque les nouveaux drones de cette GCS, puis récupérer les logs manquants de tous les drones disponibles. Les drones signalés armés sont exclus. Aucun numéro de stock n’est nécessaire.")
            .accessibilityIdentifier("gcs.collectAll")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var batchProgressCard: some View {
        let progress = store.batchProgress
        let fraction = min(max(store.overallFraction(for: progress), 0), 1)
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
                Text("\(Int(fraction * 100))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .tracking(-1.5).monospacedDigit()
                Text("%").font(.system(size: 20, weight: .medium)).foregroundStyle(palette.secondary)
                    .padding(.leading, -10)
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
            .accessibilityValue(progress.totalCount > 0 ? "\(Int(fraction * 100)) pour cent, \(progress.completedCount) fichiers vérifiés sur \(progress.totalCount)" : "\(Int(fraction * 100)) pour cent, \(store.cachedFileCount) logs déjà présents et vérifiés")
            .accessibilityIdentifier("gcs.batchProgress")
            .help("La progression suit Drone → GCS, puis GCS → Mac, en tenant compte de la taille des fichiers. 100 % signifie que tous les fichiers de cette collecte sont vérifiés. Les octets affichés comptent uniquement la copie reçue sur ce Mac.")

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.totalCount == 0 ? (store.cachedFileCount > 0 ? "\(store.cachedFileCount) logs déjà présents" : "Aucun fichier en collecte") : "\(progress.completedCount) / \(progress.totalCount) fichiers vérifiés")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.primary)
                    if progress.totalCount > 0 {
                        Text("\(bytes(progress.completedBytes)) / \(bytes(progress.totalBytes)) reçus sur ce Mac · \(store.cachedFileCount) logs déjà présents")
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                }
                Spacer(minLength: 6)
                if store.isQueuePaused && (pendingCount > 0 || activeTransfer != nil) {
                    action("Reprendre", symbol: "play.fill") { store.resumeQueue() }
                        .disabled(!store.isConnected || mutationsBlocked)
                        .accessibilityIdentifier("gcs.resume")
                } else if pendingCount > 0 || activeTransfer != nil {
                    action("Mettre en pause", symbol: "pause.fill") { store.pauseQueue() }
                        .disabled(mutationsBlocked)
                        .accessibilityIdentifier("gcs.pause")
                }
            }
            rule
            HStack(spacing: 15) {
                statusDot("\(store.activeTransferCount) drones en transfert", color: store.activeTransferCount > 0 ? palette.mint : palette.secondary)
                Text("\(progress.pendingCount) en attente")
                Spacer(minLength: 4)
                Text("\(store.maxConcurrentDownloads) drones maximum simultanément")
            }
            .font(.system(size: 10)).foregroundStyle(palette.secondary)
            HStack(alignment: .top, spacing: 8) {
                BentoIcon(symbol: "info.circle", size: 13)
                Text("Drone → GCS · GCS → Mac · 100 % = tous les fichiers vérifiés")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10)).foregroundStyle(palette.secondary)
            if !store.expectedInventoryUUIDs.isEmpty || progress.failedCount > 0 || progress.stoppedCount > 0 {
                HStack(spacing: 15) {
                    if !store.expectedInventoryUUIDs.isEmpty {
                        Text(store.inventoryCoverageLabel).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                    if progress.failedCount > 0 { statusDot("\(progress.failedCount) en échec", color: palette.amber) }
                    if progress.stoppedCount > 0 { statusDot("\(progress.stoppedCount) arrêté(s)", color: palette.amber) }
                    Spacer(minLength: 0)
                }
            }

            if store.isQueuePaused && activeTransfer != nil {
                message("La pause prendra effet à la fin des fichiers en cours.", symbol: "pause.circle", color: palette.amber)
            }
            if progress.totalBytes > 0 && progress.completedBytes == progress.totalBytes && progress.completedCount < progress.totalCount && progress.activeCount > 0 {
                message("Copie sur ce Mac terminée · vérification des fichiers et analyse en cours.", symbol: "checkmark.shield", color: palette.secondary)
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
        store.batchStatusMessage
    }

    private var networkCard: some View {
        card {
            HStack {
                title("Connexion GCS")
                Spacer(minLength: 6)
                statusDot(store.isConnected ? "Connectée" : store.isConnecting ? "Connexion…" : "Non connectée",
                          color: store.isConnected ? palette.mint : palette.secondary)
            }
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    BentoIcon(symbol: "network", size: 15).foregroundStyle(palette.secondary)
                    TextField("Adresse IP ou nom de la GCS", text: $store.host)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .disabled(store.isConnected || store.isConnecting || store.isBusy || mutationsBlocked)
                        .onSubmit { if !store.isConnected && !store.isConnecting { store.connect() } }
                        .accessibilityLabel("Adresse de la GCS")
                        .accessibilityIdentifier("gcs.host")
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
                action(store.isConnected ? "Déconnecter" : store.isConnecting ? "Annuler" : "Connecter",
                       symbol: store.isConnected ? "personalhotspot.slash" : "network") {
                    if store.isConnected || store.isConnecting { store.disconnect() } else { store.connect() }
                }
                .disabled(store.isBusy || (!store.isConnected && !store.isConnecting && (mutationsBlocked || store.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
                .accessibilityIdentifier("gcs.connect")
            }
            Text("\(store.drones.filter(\.isOnline).count) drones disponibles · lecture des logs uniquement")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }

    private var destinationCard: some View {
        card {
            HStack {
                title("Dossier de collecte")
                Spacer()
                BentoIcon(symbol: "folder").foregroundStyle(palette.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    destinationDescription
                    Spacer(minLength: 8)
                    destinationActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    destinationDescription
                    destinationActions
                }
            }
            if let issue = store.downloadDirectoryIssue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(palette.amber)
                    .accessibilityIdentifier("gcs.directoryIssue")
            }
        }
    }

    private var destinationDescription: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.downloadDirectory.lastPathComponent)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(palette.primary)
                .lineLimit(1).truncationMode(.middle)
            Text("Dossier conservé au prochain lancement")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
            Text(store.downloadDirectory.path)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .help(store.downloadDirectory.path)
        }
    }

    private var destinationActions: some View {
        HStack(spacing: 8) {
            action("Ouvrir", symbol: "arrow.up.forward.square") { store.revealDownloads() }
                .accessibilityIdentifier("gcs.revealDownloads")
            action("Changer", symbol: "folder.badge.gearshape") { store.chooseDownloadDirectory() }
                .disabled(store.isBusy || pendingCount > 0 || mutationsBlocked)
                .accessibilityIdentifier("gcs.chooseDirectory")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var optionsCard: some View {
        card(padding: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            title("Options de collecte")
            Text("Les fichiers existants sont vérifiés avant transfert.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Analyser après collecte").font(.system(size: 12, weight: .semibold))
                    Text("Ajouter les nouveaux logs à la bibliothèque.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                Toggle("Analyser après collecte", isOn: $store.autoImport).labelsHidden()
                    .disabled(mutationsBlocked)
                    .toggleStyle(.switch).controlSize(.small).tint(palette.mint)
                    .accessibilityIdentifier("gcs.autoImport")
            }
            rule.padding(.vertical, 3)
            ClientDestinationPicker(clients: library.clients, selection: Binding(
                get: { store.collectionClientID ?? "" },
                set: { store.chooseCollectionClient($0) }
            ))
            .disabled(store.isBusy || mutationsBlocked)
            Text("Les nouveaux logs seront attribués à ce client. Les fichiers déjà connus conservent leur attribution.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            rule.padding(.vertical, 3)
            collectionFact("Déjà collectés", value: "\(store.cachedFileCount) logs vérifiés")
            collectionFact("Réessais automatiques", value: "\(GCSQueuePolicy.maxAttempts) tentatives maximum")
            collectionFact("Fichiers originaux", value: "Conservés sur les drones")
            if !store.queue.isEmpty {
                rule.padding(.vertical, 3)
                transferCard
            }
            DisclosureGroup {
                Text("La page web GCS ouverte dans Edge peut aussi déclencher une copie dans Téléchargements. Fermez cette page pendant la collecte pour éviter ce doublon navigateur.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } label: {
                Text("Éviter les doublons du navigateur").font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
                }.padding(20)
            }.frame(height: 540)
        }
    }

    private func collectionFact(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(palette.secondary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(palette.primary).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11)).padding(.vertical, 3)
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
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        fleetHeading
                        Spacer(minLength: 8)
                        if !fleet.isEmpty { searchField("Numéro ou identifiant", text: $droneSearch).frame(width: 170) }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        fleetHeading
                        if !fleet.isEmpty { searchField("Numéro ou identifiant", text: $droneSearch) }
                    }
                }.padding(20)
                ScrollView {
                    if fleet.isEmpty {
                        emptyState(symbol: "drone", title: "Aucun drone connecté",
                            detail: store.isConnected ? "Les drones apparaissent automatiquement dès leur connexion à cette GCS." : "Connectez votre GCS pour retrouver les drones disponibles.")
                    } else if visibleFleet.isEmpty {
                        emptyState(symbol: "magnifyingglass", title: "Aucun drone correspondant", detail: "Modifiez votre recherche pour retrouver un drone.")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleFleet) { drone in
                                rule
                                fleetRow(drone)
                            }
                        }
                    }
                }
                rule
                Text("Collecte automatique des appareils connectés. Le numéro de stock est facultatif. Les appareils signalés armés sont exclus.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(20)
            }.frame(height: 540)
        }
    }

    private var fleetHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Drones connectés")
            Text("\(fleet.count) appareils détectés automatiquement")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fleetRow(_ drone: GCSDrone) -> some View {
        let selected = store.selectedUUID == drone.uuid
        let transfer = store.queue.last { $0.droneUUID == drone.uuid }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                droneBadge
                VStack(alignment: .leading, spacing: 5) {
                    Text(library.annotations.displayName(forGCSUUID: drone.uuid))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let transfer {
                        Text("\(transfer.filename) · \(transfer.state == "downloading" ? phaseLabel(transfer.phase) : stateLabel(transfer.state))")
                            .font(.system(size: 10)).foregroundStyle(stateColor(transfer.state)).lineLimit(2)
                    } else {
                        Text("Firmware \(drone.firmware.isEmpty ? "inconnu" : drone.firmware)")
                            .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    }
                    statusDot(drone.isOnline ? "Connecté" : "Hors ligne", color: drone.isOnline ? palette.mint : palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).help(drone.uuid)
                if let transfer, ["downloading", "queued", "retrying", "interrupted", "stopped"].contains(transfer.state) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(transfer.phaseProgress.map { "\(Int($0 * 100)) %" } ?? stateLabel(transfer.state))
                            .font(.system(size: 10)).foregroundStyle(palette.secondary).monospacedDigit()
                        ProgressView(value: min(max(transfer.phaseProgress ?? transfer.progress, 0), 1))
                            .tint(stateColor(transfer.state)).frame(width: 100)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    droneTelemetry(drone)
                    Spacer(minLength: 4)
                    droneActions(drone, selected: selected)
                }
                VStack(alignment: .leading, spacing: 10) {
                    droneTelemetry(drone)
                    droneActions(drone, selected: selected)
                }
            }
            .padding(.leading, 54)
        }
        .foregroundStyle(palette.primary).padding(.horizontal, 20).padding(.vertical, 16)
        .background(selected ? palette.raised.opacity(0.75) : .clear)
        .contextMenu {
            Button("Copier l’UUID") { copy(drone.uuid) }
            Button("Modifier le numéro…") { editingIdentity = identityTarget(drone.uuid) }
        }
    }

    private var droneBadge: some View {
        BentoIcon(symbol: "drone", size: 21).foregroundStyle(palette.secondary)
            .frame(width: 42, height: 42)
            .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func droneTelemetry(_ drone: GCSDrone) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(drone.armed.map { $0 ? "Armé · collecte bloquée" : "Désarmé" } ?? "Armement inconnu")
                .foregroundStyle(drone.armed == true ? palette.amber : palette.secondary)
            Text("\(drone.battery.map { "\(Int(($0 * 100).rounded())) %" } ?? "Batterie inconnue") · \(drone.rssi.map { "\($0) dBm" } ?? "Signal inconnu")")
                .foregroundStyle(palette.secondary).monospacedDigit()
        }
        .font(.system(size: 10))
    }

    private func droneActions(_ drone: GCSDrone, selected: Bool) -> some View {
        HStack(spacing: 8) {
            action("Identifier", symbol: "pencil") { editingIdentity = identityTarget(drone.uuid) }
                .accessibilityIdentifier("gcs.identify.\(drone.uuid)")
            action(selected ? "Actualiser" : "Voir les logs", symbol: selected ? "arrow.clockwise" : "doc.text.magnifyingglass") {
                showInventories = true
                if selected { store.refreshInventory() } else { fileSearch = ""; store.selectDrone(drone.uuid) }
            }
            .disabled(!store.isConnected || !drone.isOnline || drone.armed == true || store.isBusy || mutationsBlocked)
            .accessibilityIdentifier("gcs.inventory.\(drone.uuid)")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var inventoryCard: some View {
        card(padding: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    inventoryHeading
                    Spacer()
                    inventoryActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    inventoryHeading
                    inventoryActions
                }
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
                    Button(allNewFilesSelected ? "Désélectionner les affichés" : "Sélectionner les nouveaux affichés") {
                        store.selectAllFiles(visibleIDs: Set(visibleFiles.map(\.id)))
                    }
                        .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                        .disabled(!canReadSelectedDrone || visibleNewFileIDs.isEmpty).accessibilityIdentifier("gcs.selectAllFiles")
                        .help("La sélection ne change que pour les fichiers visibles. Les fichiers déjà collectés sont exclus.")
                    Spacer()
                    Text("\(store.selectedFileIDs.count) sélectionné\(store.selectedFileIDs.count == 1 ? "" : "s") · \(visibleFiles.count) / \(store.files.count) logs affichés")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                if hiddenSelectedCount > 0 {
                    Text("\(hiddenSelectedCount) fichier\(hiddenSelectedCount == 1 ? " sélectionné reste inclus" : "s sélectionnés restent inclus") hors recherche.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                }
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

    private var inventoryHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            title("Logs disponibles")
            Text(store.selectedUUID.map { library.annotations.displayName(forGCSUUID: $0) } ?? "")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
        }
    }

    private var inventoryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField("Nom ou dossier…", text: $fileSearch).frame(width: 170)
                inventoryButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                searchField("Nom ou dossier…", text: $fileSearch)
                inventoryButtons
            }
        }
    }

    private var inventoryButtons: some View {
        HStack(spacing: 8) {
            action("Actualiser", symbol: "arrow.clockwise") { store.refreshInventory() }
                .disabled(!canReadSelectedDrone || store.isBusy)
                .accessibilityIdentifier("gcs.refreshInventory")
            action("Collecter la sélection", symbol: "arrow.down.to.line", primary: true) { store.enqueueSelected() }
                .disabled(!canReadSelectedDrone || store.selectedFileIDs.isEmpty || store.isScanningFleet || store.isStopping)
                .accessibilityIdentifier("gcs.enqueue")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $showTransfers) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.queue.reversed()) { transfer in
                            rule
                            transferRow(transfer)
                        }
                    }
                }
                .frame(maxHeight: 360).padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    BentoIcon(symbol: "list.bullet.rectangle", size: 15)
                    Text("File détaillée et erreurs · \(store.queue.count)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.primary)
                }
            }
            .accessibilityIdentifier("gcs.transferDetails")
            if retryCount > 0 {
                action("Relancer (\(retryCount))", symbol: "arrow.clockwise") { store.retryFailed() }
                    .disabled(!store.isConnected || store.isBusy || mutationsBlocked)
                    .accessibilityIdentifier("gcs.retry")
            }
            HStack(spacing: 7) {
                if library.isImporting { ProgressView().controlSize(.small) }
                Text(libraryCountLabel).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
    }

    private func transferRow(_ transfer: GCSTransfer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    Text(transfer.state == "downloading" ? phaseLabel(transfer.phase) : stateLabel(transfer.state)).foregroundStyle(stateColor(transfer.state))
                    Spacer()
                    if transfer.state == "downloading" {
                        if let phaseProgress = transfer.phaseProgress {
                            Text("\(Int(phaseProgress * 100)) %").foregroundStyle(palette.secondary)
                        }
                    }
                }
                .font(.system(size: 10)).monospacedDigit()
                if ["downloading", "queued", "retrying", "interrupted", "stopped"].contains(transfer.state) {
                    if transfer.state == "downloading", let phaseProgress = transfer.phaseProgress {
                        ProgressView(value: phaseProgress).tint(stateColor(transfer.state))
                    } else {
                        ProgressView(value: min(max(transfer.progress, 0), 1)).tint(stateColor(transfer.state))
                    }
                }
                if transfer.state == "retrying", let nextRetry = transfer.nextRetryAt {
                    HStack(spacing: 4) {
                        Text("Nouvel essai")
                        if nextRetry > Date() { Text(nextRetry, style: .relative).monospacedDigit() }
                        else { Text("en attente de connexion") }
                    }
                    .font(.system(size: 10)).foregroundStyle(palette.amber)
                }
                Text("\(bytes(transfer.phaseBytes ?? transfer.completedBytes)) / \(bytes(transfer.phaseTotal ?? transfer.size))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(palette.primary).padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gcs.transfer.\(transfer.id)")
    }

    private func phaseLabel(_ phase: String?) -> String {
        switch phase {
        case "drone": "Drone → GCS"
        case "http": "GCS → Mac"
        case "verification": "Vérification"
        default: "Préparation"
        }
    }

    private func updateClientDestination() {
        guard !store.isBusy else { return }
        // The visible picker makes Sans client explicit when browsing all clients.
        store.chooseCollectionClient(library.views.state.activeScope.clientID ?? "")
    }

    private func card<Content: View>(padding: CGFloat = 20, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: padding == 0 ? 0 : 14, content: content)
            .padding(padding).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(palette.card, in: RoundedRectangle(cornerRadius: BentoTokens.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: BentoTokens.cardRadius).stroke(palette.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: BentoTokens.cardRadius))
    }

    private func action(_ label: String, symbol: String, primary: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                BentoIcon(symbol: symbol, size: 15)
                Text(label)
            }
            .font(.system(size: 11, weight: primary ? .semibold : .medium))
        }
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: primary, compact: !primary))
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).tracking(-0.25).foregroundStyle(palette.primary)
    }

    private func statusDot(_ label: String, color: Color) -> some View {
        BentoStatus(label: label, color: color)
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
            BentoIcon(symbol: symbol, size: 25).foregroundStyle(palette.secondary).padding(.bottom, 3)
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
