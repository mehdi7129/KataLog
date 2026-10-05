import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KataLogCore

/// Local support workflow using the workspace's monochrome cards and accents.
struct DiagnosticView: View {
    @ObservedObject var store: DiagnosticStore
    let host: String
    let readOnly: Bool
    var externalBusy = false
    let refresh: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var showingSnapshot = false
    @State private var showingExplanation = false
    @State private var showingTimeline = false
    @State private var confirmingJournalClear = false
    private var palette: Palette { Palette(dark: scheme == .dark) }
    private var journalClearExplanation: String {
        if readOnly { return "Le journal ne peut pas être effacé dans cette instance en lecture seule." }
        if externalBusy { return "Terminez l’opération en cours dans KataLog avant d’effacer le journal." }
        if store.isLoading || store.isFetchingGCS || store.isExporting { return "Attendez la fin du diagnostic en cours avant d’effacer le journal." }
        return "Efface uniquement le journal technique de KataLog, après confirmation."
    }
    private var exportExplanation: String {
        if store.isLoading { return "Attendez la fin de la lecture du journal local." }
        if store.isFetchingGCS { return "Terminez ou annulez la récupération GCS avant d’exporter." }
        if !store.canExport { return "Le contenu du diagnostic doit être disponible avant l’export." }
        return "Enregistre le diagnostic vérifié dans un ZIP sur votre Mac. Aucun envoi automatique."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Diagnostic local").font(.system(size: 24, weight: .semibold)).tracking(-0.8)
                    Text("KataLog, GCS et logs de drones · vérifiez le contenu avant de l’exporter.")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                BentoIcon(symbol: "waveform.path.ecg", size: 22)
                    .frame(width: 46, height: 46).background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }.padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 16) {
                        services
                        attachments
                    }
                    contents
                    timeline
                    if let error = store.errorMessage {
                        card {
                            Label("Diagnostic indisponible", systemImage: "exclamationmark.circle")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.red)
                            Text(error).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let message = store.exportMessage {
                        Label(message, systemImage: "checkmark.circle").font(.system(size: 12))
                            .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("diagnostic.export-message")
                    }
                }.padding(.horizontal, 24).padding(.bottom, 22)
            }
            footer
        }
        .foregroundStyle(palette.primary).background(palette.background)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 550, idealHeight: 700)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette)).tint(palette.primary)
        .onChange(of: host) { _, value in store.endpointChanged(to: value) }
        .interactiveDismissDisabled(store.isExporting)
        .confirmationDialog("Effacer le journal de KataLog ?", isPresented: $confirmingJournalClear, titleVisibility: .visible) {
            Button("Effacer le journal", role: .destructive) { store.clearJournal() }
                .disabled(readOnly || externalBusy || store.isLoading || store.isFetchingGCS || store.isExporting)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Seuls les événements techniques de KataLog seront effacés. Les ULogs, analyses et journaux GCS restent conservés.")
        }
        .onDisappear { store.dismiss() }
    }

    private var summary: some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vos données restent sur ce Mac").font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                    Text("Le diagnostic contient les versions et les événements techniques de l’app. Les journaux GCS sont récupérés uniquement à votre demande. Aucun fichier n’est envoyé automatiquement.")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.shield").font(.system(size: 21)).foregroundStyle(palette.mint).accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 18) {
                metric("Événements KataLog", value: store.isLoading ? "…" : store.eventCount.formatted())
                metric("Services GCS", value: store.serviceFiles.count.formatted())
                metric("ULogs inclus", value: store.privateULogs.count.formatted())
            }.padding(.top, 4)
            if store.isLoading { ProgressView(store.isClearingJournal ? "Effacement du journal…" : "Lecture du journal local…").controlSize(.small) }
            if readOnly {
                Label("Bibliothèque en lecture seule · le journal de cette instance reste en mémoire. Son contenu n’est pas écrit dans la bibliothèque.", systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var services: some View {
        card {
            Label("1 · Récupérer les journaux GCS", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .semibold))
            Text("MQTT, liaison radio, backend et serveur web, si votre firmware fournit ces journaux.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            if store.isFetchingGCS {
                ProgressView("Récupération des journaux…").controlSize(.small)
                Button("Annuler la récupération") { store.cancelGCS() }
                    .accessibilityIdentifier("diagnostic.cancel-gcs")
            } else {
                Button(store.serviceFiles.isEmpty ? "Récupérer les journaux GCS" : "Actualiser les journaux GCS", systemImage: "arrow.down.doc") {
                    store.fetchGCS(host: host)
                }.disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isExporting)
                    .accessibilityIdentifier("diagnostic.fetch-gcs")
                    .help(store.isExporting ? "Attendez la fin de l’export avant de récupérer les journaux GCS." : host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Renseignez l’adresse de votre serveur dans Collecte GCS." : "Demande les journaux du serveur GCS sans lancer de collecte sur les drones.")
            }
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Renseignez l’adresse dans Collecte GCS.").font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            if let date = store.serviceCapturedAt {
                Text("Capture du \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            if let message = store.serviceMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("diagnostic.gcs-status")
            }
            Divider().overlay(palette.border)
            Text("2 · Choisir le contenu à partager").font(.system(size: 12, weight: .semibold))
            Toggle("Inclure les textes complets de la GCS", isOn: $store.includePrivateGCS)
                .toggleStyle(.switch).controlSize(.small).tint(palette.mint)
                .font(.system(size: 12)).disabled(store.serviceFiles.isEmpty || store.isExporting)
                .accessibilityIdentifier("diagnostic.private-gcs")
                .help(store.isExporting ? "Le contenu est figé pendant l’export." : store.serviceFiles.isEmpty ? "Récupérez les journaux GCS ci-dessus pour activer cette option." : "Ajoute les journaux bruts au diagnostic que vous allez exporter.")
            Text(store.serviceFiles.isEmpty
                 ? "Récupérez d’abord les journaux ci-dessus. Cette option sera disponible dès qu’un journal aura été reçu."
                 : store.includePrivateGCS
                 ? "Données privées incluses : les textes bruts peuvent contenir des identités, adresses, positions et détails de votre infrastructure."
                 : "Par défaut, le diagnostic GCS conserve une synthèse filtrée des journaux récupérés.")
                .font(.system(size: 11)).foregroundStyle(store.includePrivateGCS ? palette.amber : palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attachments: some View {
        card {
            Label("Logs des drones", systemImage: "doc.zipper").font(.system(size: 14, weight: .semibold))
            Text("Ajoutez les ULogs utiles à ce problème. Les fichiers sont copiés dans le diagnostic, sans import ni modification des originaux.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Joindre des ULogs privés", isOn: $store.includeULogs)
                .toggleStyle(.checkbox).font(.system(size: 12)).disabled(store.isExporting)
                .accessibilityIdentifier("diagnostic.private-ulogs")
            if store.includeULogs {
                Button(store.selectedULogs.isEmpty ? "Choisir les ULogs…" : "Modifier la sélection…", systemImage: "plus") { chooseULogs() }
                    .disabled(store.isExporting).accessibilityIdentifier("diagnostic.choose-ulogs")
                if store.selectedULogs.isEmpty {
                    Text("Aucun ULog sélectionné.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                } else {
                    Text("\(store.selectedULogs.count) fichiers sélectionnés").font(.system(size: 12, weight: .medium))
                    ForEach(Array(store.selectedULogs.prefix(3).enumerated()), id: \.offset) { _, url in
                        Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                    if store.selectedULogs.count > 3 { Text("Et \(store.selectedULogs.count - 3) autres…").font(.system(size: 11)).foregroundStyle(palette.secondary) }
                    Button("Retirer la sélection") { store.selectULogs([]) }.disabled(store.isExporting)
                }
                Text("Les ULogs contiennent les données brutes du drone, dont ses identifiants et éventuellement ses positions.")
                    .font(.system(size: 11)).foregroundStyle(palette.amber).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Aucun ULog joint par défaut. Les ULogs bruts peuvent contenir des identifiants et des positions ; vous choisissez précisément les fichiers à partager.")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var timeline: some View {
        card {
            HStack {
                HStack(spacing: 6) {
                    Text("Journal de KataLog").font(.system(size: 14, weight: .semibold))
                    LibraryHelpButton(title: "Conservation du journal", text: store.journalStorageExplanation)
                }
                Spacer()
                Button("Actualiser", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(store.isLoading || store.isExporting || store.isFetchingGCS)
                    .accessibilityIdentifier("diagnostic.refresh-local")
            }
            HStack {
                Text("Journal technique local · rotation automatique").font(.system(size: 10)).foregroundStyle(palette.secondary)
                Spacer()
                Button("Effacer…") { confirmingJournalClear = true }
                    .disabled(readOnly || externalBusy || store.isLoading || store.isFetchingGCS || store.isExporting)
                    .accessibilityIdentifier("diagnostic.clear-journal")
                    .help(journalClearExplanation)
                    .accessibilityHint(journalClearExplanation)
            }
            DisclosureGroup(isExpanded: $showingTimeline) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Les événements récents apparaissent en premier. Les heures suivent le fuseau de votre Mac ; l’archive conserve les horodatages UTC.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    if let snapshot = store.snapshot {
                        Text("Capture locale du \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)). L’export reprend cette capture vérifiée.")
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        if snapshot.events.isEmpty {
                            Text("Aucun événement enregistré pour le moment. Les prochaines connexions, collectes et analyses rempliront ce journal.")
                                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if snapshot.corruptedLineCount > 0 || snapshot.droppedEventCount > 0 {
                            Label("\(snapshot.corruptedLineCount) entrées illisibles · \(snapshot.droppedEventCount) événements non enregistrés. Le diagnostic indique ces limites.", systemImage: "exclamationmark.circle")
                                .font(.system(size: 11)).foregroundStyle(palette.amber).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(store.recentEvents.enumerated()), id: \.offset) { _, event in eventRow(event) }
                        if store.eventCount > 100 {
                            Text("Les 100 derniers événements sont affichés. Le ZIP inclut l’ensemble des événements conservés.")
                                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        }
                    }
                }.padding(.top, 12)
            } label: {
                Text("Voir les événements récents").font(.system(size: 11))
            }
        }
    }

    private var contents: some View {
        card {
            HStack {
                Text("3 · Vérifier avant d’exporter").font(.system(size: 14, weight: .semibold))
                Spacer()
                BentoStatus(label: store.privateDataRequested ? "Pièces privées incluses" : "Sans pièces brutes privées", color: store.privateDataRequested ? palette.amber : palette.mint)
            }
            if let preview = store.preview {
                Text("\(preview.eventCount) événements KataLog · \(preview.gcsSourceCount) services GCS · \(store.privateULogs.count) ULogs choisis")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(preview.fileNames, id: \.self) { name in
                    Label(name, systemImage: "doc").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Lire les explications du diagnostic", isExpanded: $showingExplanation) {
                    Text(preview.summary).font(.system(size: 11)).foregroundStyle(palette.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9)
                }.font(.system(size: 11))
            } else {
                Text(store.isLoading ? "Préparation de l’aperçu…" : store.errorMessage != nil ? "Corrigez le problème indiqué ci-dessous avant d’exporter." : "Le contenu sera disponible après lecture du journal.")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            DisclosureGroup("Voir le snapshot technique JSON", isExpanded: $showingSnapshot) {
                Text(store.snapshotJSON).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9)
            }.font(.system(size: 11)).disabled(store.snapshotJSON.isEmpty)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Fermer", action: close).keyboardShortcut(.cancelAction).disabled(store.isExporting)
            Spacer(minLength: 8)
            if store.isExporting {
                ProgressView(store.isCancellingExport ? "Arrêt de l’export…" : "Création du ZIP…").controlSize(.small)
                Button("Annuler") { store.cancelExport() }.disabled(store.isCancellingExport)
                    .accessibilityIdentifier("diagnostic.cancel-export")
            } else {
                Button("Exporter le ZIP…", systemImage: "square.and.arrow.up") { exportZIP() }
                    .buttonStyle(WorkspaceActionButtonStyle(palette: palette, prominent: true))
                    .disabled(!store.canExport).accessibilityIdentifier("diagnostic.export")
                    .help(exportExplanation)
                    .accessibilityHint(exportExplanation)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18).background(palette.card)
            .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func eventRow(_ event: DiagnosticEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.code == .none ? "circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: event.code == .none ? 5 : 12)).foregroundStyle(event.code == .none ? palette.muted : palette.amber)
                .frame(width: 14, height: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(palette.secondary).monospacedDigit()
                }
                Text(event.code == .none ? event.kind.explanation : event.code.title + " · " + event.code.explanation)
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                if let phase = event.phase {
                    Text(phaseTitle(phase) + progressText(event))
                        .font(.system(size: 10)).foregroundStyle(palette.secondary).monospacedDigit()
                }
            }
        }.padding(12).background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 14, content: content)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 23, weight: .semibold)).tracking(-0.6).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phaseTitle(_ phase: DiagnosticEvent.Phase) -> String {
        switch phase {
        case .drone: "Drone → GCS"
        case .http: "GCS → Mac"
        case .verification: "Validation du fichier"
        case .analysis: "Analyse du log"
        }
    }

    private func progressText(_ event: DiagnosticEvent) -> String {
        guard let received = event.metrics[.bytes], let total = event.metrics[.totalBytes], total > 0 else { return "" }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        return " · " + formatter.string(fromByteCount: max(0, received)) + " / " + formatter.string(fromByteCount: total)
    }

    private func chooseULogs() {
        let panel = NSOpenPanel(); panel.title = "Choisir les ULogs à joindre au diagnostic"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ulg") ?? .data]
        if panel.runModal() == .OK { store.selectULogs(panel.urls) }
    }

    private func exportZIP() {
        guard store.canExport else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "KataLog-diagnostic.zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { store.export(to: url) }
    }
}
