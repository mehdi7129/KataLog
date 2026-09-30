import AppKit
import SwiftUI
import KataLogCore
import UniformTypeIdentifiers

private enum FlightDetailTab: String, CaseIterable, Identifiable {
    case overview = "Vue du log"
    case messages = "Messages"
    case metrics = "Mesures"
    case parameters = "Paramètres"
    case topics = "Topics"
    case coverage = "Couverture"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "airplane"
        case .messages: "text.bubble"
        case .metrics: "gauge.with.needle"
        case .parameters: "slider.horizontal.3"
        case .topics: "list.bullet.rectangle"
        case .coverage: "info.circle"
        }
    }
}

/// One log is inspected at a time; details are loaded by LibraryStore on demand.
struct FlightDetailView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: FlightDetailTab = .overview
    @State private var messageSearch = ""
    @State private var messageLevel = "Tous"
    @State private var messageFamily: String?
    @State private var parameterSearch = ""
    @State private var topicSearch = ""
    @State private var selectedMessageID: String?
    @State private var exportError: String?
    @State private var isExporting = false
    @State private var editingIdentity: DroneIdentityTarget?
    private var style: FlightUIStyle { FlightUIStyle(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    loadingStatus
                    if let log = store.selectedFlight {
                        summary(log)
                        switch tab {
                        case .overview: overview(log)
                        case .messages: messages(log)
                        case .metrics: measurements(log)
                        case .parameters: parameters(log)
                        case .topics: topics(log)
                        case .coverage: coverage(log)
                        }
                    } else if !store.isLoadingFlight {
                        FlightPanel {
                            FlightEmptyState(symbol: "doc.questionmark", title: "Détails indisponibles",
                                             detail: "Fermez cette fiche pour choisir un autre enregistrement. Les résumés de la bibliothèque restent conservés.")
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            tabBar
        }
        .foregroundStyle(style.primary).background(style.background)
        .frame(minWidth: 840, idealWidth: 1180, maxWidth: 1400, minHeight: 540, idealHeight: 870, maxHeight: 1100)
        .sheet(item: $editingIdentity) { target in DroneNumberEditor(target: target, store: store.annotations) }
        .onChange(of: store.selectedFlight?.id) { _, _ in
            tab = .overview; selectedMessageID = nil
            messageSearch = ""; messageLevel = "Tous"; messageFamily = nil
            topicSearch = ""; parameterSearch = ""; exportError = nil
        }
        .onChange(of: messageSearch) { _, _ in selectedMessageID = nil }
        .onChange(of: messageLevel) { _, _ in selectedMessageID = nil }
        .onChange(of: messageFamily) { _, _ in selectedMessageID = nil }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    store.closeFlight(); dismiss()
                } label: {
                    Label("Fermer la fiche", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(style.secondary)
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("flight.close")
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(store.selectedFlight?.displayName ?? "Enregistrement")
                        .font(.system(size: 26, weight: .semibold)).tracking(-0.7).lineLimit(1)
                    if let log = store.selectedFlight {
                        Text(log.fileName).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(style.secondary).lineLimit(1)
                    }
                }
                if let log = store.selectedFlight {
                    Text("\(log.date.isEmpty ? "Date inconnue" : log.date) · \(dateOrigin(log.dateSource))")
                        .font(.system(size: 11)).foregroundStyle(style.secondary)
                }
            }
            Spacer(minLength: 10)
            if let log = store.selectedFlight {
                Button { editingIdentity = DroneIdentityTarget(log: log) } label: {
                    Label("Identifier…", systemImage: "number")
                }
                .controlSize(.small).accessibilityIdentifier("flight.identify")
                Menu {
                    Button("Rapport HTML · messages et mesures") { export(log, html: true) }
                    Button("Données de la fiche (JSON)") { export(log, html: false) }
                } label: {
                    Label(isExporting ? "Export…" : "Exporter ce log", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(style.raised, in: RoundedRectangle(cornerRadius: 8))
                .disabled(isExporting || store.isExporting || store.isLoadingFlight)
                .accessibilityIdentifier("flight.export")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 19)
    }

    @ViewBuilder private var loadingStatus: some View {
        if store.isLoadingFlight {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Lecture des détails du log…").font(.system(size: 12))
                Spacer()
                Text("La bibliothèque reste disponible.").font(.system(size: 10)).foregroundStyle(style.secondary)
            }
            .padding(14).background(style.raised, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("flight.loading")
        }
        if let error = store.flightError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).font(.system(size: 12)).textSelection(.enabled)
                Spacer()
                if let log = store.selectedFlight {
                    Button("Réessayer") { store.loadFlight(log) }.buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("flight.retry")
                }
            }
            .foregroundStyle(style.amber).padding(14)
            .background(style.raised, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("flight.error")
        }
        if let error = exportError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(style.amber).textSelection(.enabled)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(FlightDetailTab.allCases) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                        .padding(.horizontal, 14).frame(height: 38)
                        .foregroundStyle(tab == item ? style.primary : style.secondary)
                        .background(tab == item ? style.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(store.selectedFlight == nil)
                .accessibilityIdentifier("flight.tab.\(tabIdentifier(item))")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(style.card)
    }

    private func summary(_ log: FlightLog) -> some View {
        FlightPanel {
            HStack(spacing: 22) {
                summaryValue(symbol: "clock", value: FlightUIFormat.duration(log.durationSeconds), label: "Durée enregistrée")
                Divider().frame(height: 36)
                summaryValue(symbol: "exclamationmark.triangle", value: "\(log.messages.filter(\.isAlert).count)", label: "Messages d’alerte", color: style.amber)
                Divider().frame(height: 36)
                summaryValue(symbol: "antenna.radiowaves.left.and.right", value: log.primaryGNSSCoverage.map { "\(formatted($0.fixedPercent)) %" } ?? "—", label: log.primaryGNSSCoverage.map { "RTK fixé · GNSS \($0.instance) · \($0.observedSeconds.map(FlightUIFormat.duration) ?? "durée inconnue") observés" } ?? "RTK · données indisponibles")
                Divider().frame(height: 36)
                summaryValue(symbol: "battery.50percent", value: log.metrics.first { $0.key == "battery.remaining_min" }.map { "\(formatted($0.value)) %" } ?? "—", label: "Charge minimum observée")
            }
        }
    }

    private func summaryValue(symbol: String, value: String, label: String, color: Color? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(color ?? style.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Text(label).font(.system(size: 10)).foregroundStyle(style.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overview(_ log: FlightLog) -> some View {
        let selected = log.messages.first { $0.id == selectedMessageID }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                FlightTrackMap(logs: [log], cursorTime: selected?.position == nil ? nil : selected?.timestampSeconds,
                               cursorPosition: selected?.position,
                               onSelectTime: { time in selectedMessageID = log.messages.min { abs($0.timestampSeconds - time) < abs($1.timestampSeconds - time) }?.id })
                    .frame(maxWidth: .infinity).frame(height: 475)
                chronology(log).frame(width: 310, height: 475)
            }
            if let selected {
                FlightPanel {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            levelLabel(selected)
                            Text("t = \(FlightUIFormat.seconds(selected.timestampSeconds))")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(style.secondary)
                            Spacer()
                            Text(selected.position == nil ? "Sans position associée" : "Position GPS associée")
                                .font(.system(size: 10)).foregroundStyle(style.secondary)
                        }
                        Text(selected.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        if let source = selected.source {
                            Text("Source : \(source == "ULog:logging_tagged" ? "message avec tag" : "message textuel")\(selected.tag.map { " · tag " + String($0) } ?? "")")
                                .font(.caption).foregroundStyle(style.secondary)
                        }
                        MessageClassificationControl(message: selected, store: store.annotations, families: log.messages.map(\.family))
                        AlertExplanationView(message: selected)
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                FlightPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Contexte de l’enregistrement")
                        detailLine("Temps en vol qualifié", log.flightSeconds.map(FlightUIFormat.duration) ?? "Couverture insuffisante ou indisponible")
                        if let observed = log.flightObservedSeconds { detailLine("Vol observé, sans extrapolation", FlightUIFormat.duration(observed)) }
                        if let fraction = log.flightCoverageFraction { detailLine("Couverture du détecteur", "\(formatted(fraction * 100)) % de l’enregistrement") }
                        detailLine("Failsafe observé", log.failsafeObserved ? "Oui" : "Non repéré")
                        detailLine("Lecture du fichier", log.status == "ok" ? "Réussie" : log.status == "partial" ? "Partielle" : "En erreur")
                        Text("La durée enregistrée inclut le temps au sol. Une alerte enregistrée ne confirme pas à elle seule une panne.")
                            .font(.system(size: 10)).foregroundStyle(style.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                FlightPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Données disponibles")
                        detailLine("Mesures", "\(log.metrics.count)")
                        detailLine("Topics", "\(log.topicDetails?.count ?? log.topics.count)")
                        detailLine("Paramètres initiaux", log.parameters.map { "\($0.count)" } ?? "Détails non chargés")
                        Button { tab = .coverage } label: {
                            Label("Voir la couverture et les sources", systemImage: "arrow.right")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("flight.showCoverage")
                    }
                }
            }
        }
    }

    private func chronology(_ log: FlightLog) -> some View {
        let alerts = log.messages.filter(\.isAlert).sorted { $0.timestampSeconds < $1.timestampSeconds }
        return FlightPanel {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Chronologie des alertes")
                Text("Temps relatif au début du log").font(.system(size: 10)).foregroundStyle(style.secondary)
                Divider()
                if alerts.isEmpty {
                    Text("Aucune alerte textuelle repérée.").font(.system(size: 12)).foregroundStyle(style.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(alerts) { message in
                                Button { selectedMessageID = message.id } label: {
                                    HStack(alignment: .top, spacing: 11) {
                                        VStack(spacing: 3) {
                                            Circle().fill(style.alertColor(message.level)).frame(width: 7, height: 7)
                                            Rectangle().fill(style.border).frame(width: 1).frame(minHeight: 33)
                                        }
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(FlightUIFormat.seconds(message.timestampSeconds))
                                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(style.secondary)
                                            Text(message.title).font(.system(size: 11, weight: .medium)).lineLimit(3)
                                            Text(message.family).font(.system(size: 9)).foregroundStyle(style.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedMessageID == message.id ? style.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain).accessibilityIdentifier("flight.timeline.\(message.id)")
                            }
                        }
                    }
                }
                Button { tab = .messages } label: {
                    Label("Tous les messages · \(log.messages.count)", systemImage: "text.bubble")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).accessibilityIdentifier("flight.showMessages")
            }
        }
    }

    private func filteredMessages(_ log: FlightLog) -> [LogMessage] {
        let query = messageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return log.messages.filter {
            (messageLevel == "Tous" || $0.level == messageLevel || (messageLevel == "Alertes" && $0.isAlert)) &&
            (messageFamily == nil || $0.family == messageFamily) &&
            (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.family.localizedCaseInsensitiveContains(query))
        }.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    private func messages(_ log: FlightLog) -> some View {
        let visible = filteredMessages(log)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                searchField("Rechercher dans ce log…", text: $messageSearch, identifier: "flight.messages.search")
                Picker("Niveau", selection: $messageLevel) {
                    ForEach(["Tous", "Alertes"] + Set(log.messages.map(\.level)).sorted { LogMessage.rank($0) > LogMessage.rank($1) }, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 180).accessibilityIdentifier("flight.messages.level")
                Picker("Famille", selection: $messageFamily) {
                    Text("Toutes").tag(String?.none)
                    ForEach(Set(log.messages.map(\.family)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(width: 205).accessibilityIdentifier("flight.messages.family")
                Button("Réinitialiser") { messageSearch = ""; messageLevel = "Tous"; messageFamily = nil }
                    .controlSize(.small).disabled(messageSearch.isEmpty && messageLevel == "Tous" && messageFamily == nil)
            }
            Text("\(visible.count) / \(log.messages.count) messages · temps relatif en secondes")
                .font(.system(size: 11)).foregroundStyle(style.secondary)
            if visible.isEmpty {
                FlightPanel { FlightEmptyState(symbol: "text.magnifyingglass", title: "Aucun message correspondant", detail: "Modifiez les filtres pour retrouver les messages de cet enregistrement.") }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(visible) { message in
                        FlightPanel(padding: 15) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    levelLabel(message)
                                    Text(message.family).font(.system(size: 10)).foregroundStyle(style.secondary)
                                    Spacer()
                                    Text("t = \(FlightUIFormat.seconds(message.timestampSeconds))")
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(style.secondary)
                                    Button("Comprendre / classer") { selectedMessageID = message.id; tab = .overview }
                                        .controlSize(.small).accessibilityIdentifier("flight.explain.\(message.id)")
                                    if message.position != nil {
                                        Button { selectedMessageID = message.id; tab = .overview } label: {
                                            Label("Voir sur la carte", systemImage: "mappin.and.ellipse")
                                        }
                                        .controlSize(.small).accessibilityIdentifier("flight.messageMap.\(message.id)")
                                    }
                                }
                                Text(message.text).font(.system(size: 12, design: .monospaced)).lineSpacing(3)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    private func measurements(_ log: FlightLog) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("\(log.metrics.count) mesures disponibles")
            Text("Chaque mesure conserve sa source, son unité et sa méthode de calcul.")
                .font(.system(size: 12)).foregroundStyle(style.secondary)
            if log.metrics.isEmpty {
                FlightPanel { FlightEmptyState(symbol: "gauge.with.needle", title: "Aucune mesure exploitable", detail: "Le firmware n’a pas enregistré les données nécessaires ou le fichier n’a pas pu être lu.") }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 265), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(log.metrics) { metric in
                        FlightPanel {
                            VStack(alignment: .leading, spacing: 13) {
                                Text(metric.label).font(.system(size: 12, weight: .medium))
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(formatted(metric.value)).font(.system(size: 25, weight: .semibold)).monospacedDigit()
                                    Text(metric.unit).font(.system(size: 12)).foregroundStyle(style.secondary)
                                }
                                Text(metric.detail).font(.system(size: 10)).foregroundStyle(style.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func parameters(_ log: FlightLog) -> some View {
        let values = log.parameters ?? [:]
        let query = parameterSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = values.keys.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) || (values[$0]?.localizedCaseInsensitiveContains(query) ?? false) }.sorted()
        let changes = (log.parameterChanges ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("Paramètres initiaux · \(names.count) / \(values.count)")
                Spacer()
                searchField("Paramètre ou valeur…", text: $parameterSearch, identifier: "flight.parameters.search").frame(width: 300)
            }
            if log.parameters == nil {
                FlightPanel { FlightEmptyState(symbol: "slider.horizontal.3", title: "Paramètres détaillés indisponibles", detail: "La lecture du fichier source est nécessaire pour récupérer les paramètres et leurs changements.") }
            } else if names.isEmpty {
                Text(values.isEmpty ? "Aucun paramètre initial enregistré." : "Aucun paramètre correspondant à la recherche.")
                    .font(.system(size: 12)).foregroundStyle(style.secondary).padding(.vertical, 16)
            } else {
                FlightPanel {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(names, id: \.self) { name in
                            HStack(alignment: .top, spacing: 18) {
                                Text(name).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                                Text(values[name] ?? "").frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.vertical, 9)
                            Divider()
                        }
                    }
                }
            }
            sectionTitle("Changements horodatés · \(changes.count)")
            if changes.isEmpty {
                Text(query.isEmpty ? "Aucun changement de paramètre enregistré." : "Aucun changement correspondant à la recherche.")
                    .font(.system(size: 12)).foregroundStyle(style.secondary)
            } else {
                FlightPanel {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                            HStack(spacing: 20) {
                                Text(FlightUIFormat.seconds(change.timeSeconds)).frame(width: 105, alignment: .leading)
                                Text(change.name).frame(maxWidth: .infinity, alignment: .leading)
                                Text(change.value).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.vertical, 9)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func topics(_ log: FlightLog) -> some View {
        let query = topicSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (log.topicDetails ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.fields.contains { $0.localizedCaseInsensitiveContains(query) } }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("Topics et instances enregistrés")
                Spacer()
                searchField("Topic ou champ…", text: $topicSearch, identifier: "flight.topics.search").frame(width: 300)
            }
            if log.topicDetails == nil {
                FlightPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Le résumé conserve les noms des topics. Les instances et champs nécessitent les détails du fichier source.")
                            .font(.system(size: 12)).foregroundStyle(style.secondary)
                        Text(log.topics.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.joined(separator: " · "))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } else if details.isEmpty {
                FlightPanel { FlightEmptyState(symbol: "list.bullet.rectangle", title: "Aucun topic correspondant", detail: "Modifiez la recherche pour retrouver un topic ou un champ enregistré.") }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(details) { topic in
                        FlightPanel(padding: 16) {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(topic.fields, id: \.self) { field in
                                        HStack(spacing: 18) {
                                            Text(field).frame(maxWidth: .infinity, alignment: .leading)
                                            Text(topic.fieldUnits?[field] ?? "Unité non renseignée").foregroundStyle(style.secondary)
                                        }
                                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(.vertical, 7)
                                        Divider()
                                    }
                                }
                                .padding(.top, 12)
                            } label: {
                                HStack(spacing: 16) {
                                    Text(topic.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                    Text("Instance \(topic.instance)").font(.system(size: 10)).foregroundStyle(style.secondary)
                                    Spacer()
                                    Text("\(topic.sampleCount) échantillons · \(topic.fields.count) champs")
                                        .font(.system(size: 10)).foregroundStyle(style.secondary)
                                }
                            }
                            .accessibilityIdentifier("flight.topic.\(topic.id)")
                        }
                    }
                }
            }
        }
    }

    private func coverage(_ log: FlightLog) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            FlightPanel {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Couverture et limites")
                    if log.metadata["detailCacheStatus"] == "previous" {
                        Label("Dernière analyse conservée · parseur \(log.metadata["detailParserVersion"] ?? "inconnu"). Source nécessaire pour actualiser.", systemImage: "clock.arrow.circlepath").font(.callout).foregroundStyle(style.amber)
                    }
                    ForEach(log.sourceAvailability ?? []) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.label).font(.callout.weight(.medium))
                            Text(source.path).font(.caption).foregroundStyle(style.secondary).textSelection(.enabled)
                            if let detail = source.detail { Text(detail).font(.caption).foregroundStyle(style.secondary) }
                        }
                    }
                    if log.issues.isEmpty && log.coverage.isEmpty {
                        Text("Aucune limite technique remontée. Ce résultat ne constitue pas un diagnostic matériel.")
                            .font(.system(size: 12)).foregroundStyle(style.secondary)
                    }
                    ForEach(Array((log.issues + log.coverage).enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "info.circle").foregroundStyle(style.amber)
                            Text(text).textSelection(.enabled)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            FlightPanel {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Provenance du fichier")
                    if let warning = log.annotationWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let number = log.stockNumber { detailLine("Numéro local", number) }
                    detailLine("Nom source", log.droneName)
                    detailLine("Identité contrôleur ULog", log.droneID)
                    if let gcs = log.metadata["gcsUUID"] { detailLine("Identité GCS vérifiée", gcs) }
                    Button("Modifier le numéro du drone…") { editingIdentity = DroneIdentityTarget(log: log) }
                        .controlSize(.small).accessibilityIdentifier("flight.identifyFromSource")
                    detailLine("Taille", ByteCountFormatter.string(fromByteCount: log.sizeBytes, countStyle: .file))
                    Text("SHA256 · \(log.id)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(style.secondary)
                    if log.sourcePaths.isEmpty {
                        Text("Source originale indisponible. Le résumé historique est conservé.")
                            .font(.system(size: 12)).foregroundStyle(style.amber)
                    }
                    ForEach(log.sourcePaths, id: \.self) { path in
                        HStack(alignment: .top, spacing: 15) {
                            Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .foregroundStyle(style.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Button { store.revealSource(path) } label: { Label("Finder", systemImage: "folder") }
                                .controlSize(.small).accessibilityLabel("Afficher le fichier source dans le Finder")
                        }
                    }
                }
            }
            FlightPanel {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Métadonnées")
                    RecordedMetadataView(log: log)
                    ForEach(log.metadata.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top, spacing: 22) {
                            Text(key).frame(width: 190, alignment: .leading).foregroundStyle(style.secondary)
                            Text(log.metadata[key] ?? "").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).tracking(-0.25)
    }
    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label).foregroundStyle(style.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 11))
    }
    private func levelLabel(_ message: LogMessage) -> some View {
        Label(message.level, systemImage: message.isAlert ? "exclamationmark.circle" : "text.bubble")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(style.alertColor(message.level))
    }
    private func searchField(_ placeholder: String, text: Binding<String>, identifier: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(style.secondary)
            TextField(placeholder, text: text).textFieldStyle(.plain).accessibilityIdentifier(identifier)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(style.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Effacer la recherche")
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 11).frame(height: 36)
        .background(style.raised, in: RoundedRectangle(cornerRadius: 8))
    }
    private func formatted(_ value: Double) -> String { String(format: abs(value) >= 1000 ? "%.1f" : "%.2f", value) }
    private func dateOrigin(_ source: String) -> String {
        source == "gps" ? "Date GPS · UTC" : source == "path" ? "Date du chemin · fuseau inconnu" : "Date non déterminée"
    }
    private func tabIdentifier(_ tab: FlightDetailTab) -> String {
        switch tab {
        case .overview: "overview"
        case .messages: "messages"
        case .metrics: "metrics"
        case .parameters: "parameters"
        case .topics: "topics"
        case .coverage: "coverage"
        }
    }
    private func export(_ log: FlightLog, html: Bool) {
        guard !isExporting, !store.isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [html ? .html : .json]
        panel.nameFieldStringValue = "KataLog-\((log.fileName as NSString).deletingPathExtension).\(html ? "html" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var selection = FleetSnapshot.empty
        selection.logs = [log]
        selection.generatedAt = ISO8601DateFormatter().string(from: Date())
        selection.sourceFolders = Array(Set(log.sourcePaths.map { ( $0 as NSString).deletingLastPathComponent })).sorted()
        let snapshot = selection
        isExporting = true; exportError = nil
        Task {
            defer { isExporting = false }
            do {
                try await store.export(to: url, html: html, selection: snapshot)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { exportError = "Échec de l’export : \(error.localizedDescription)" }
        }
    }
}
