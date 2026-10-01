import Charts
import AppKit
import SwiftUI
import KataLogCore
import UniformTypeIdentifiers

/// Recorded series and their context share the log sheet's bento composition.
struct FlightAnalysisView: View {
    let log: FlightLog
    @ObservedObject var study: FlightStudyStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var recipe = "battery"
    @State private var instance = 0
    @State private var fieldKey = ""
    @State private var windowFrom = ""
    @State private var windowTo = ""
    @State private var cursorInput = ""
    @State private var inputError: String?
    @State private var restorationWarning: String?
    @State private var exportError: String?
    @State private var exportNotice: String?
    @State private var showTable = false

    private var style: FlightUIStyle { FlightUIStyle(colorScheme) }
    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var fields: [TelemetryField] { log.telemetryCatalogue ?? [] }
    private var extractableFields: [TelemetryField] { fields.filter(\.extractable) }
    private var series: [TelemetrySeries] { study.response?.series ?? [] }
    private var domain: ClosedRange<Double> { FlightStudyPresentation.timeDomain(series) }
    private var position: ObservedPosition? {
        study.selectedTime.flatMap { TimelineSelection.position(at: $0, track: log.track) }
    }
    private var instances: [Int] {
        Array(Set(FlightStudyPresentation.recipeFields(recipe, catalogue: fields).map(\.instance))).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                controls
                status
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        curves.frame(minWidth: 530, maxWidth: .infinity)
                        context.frame(width: 320).fixedSize(horizontal: false, vertical: true)
                    }.frame(minWidth: 880)
                    VStack(alignment: .leading, spacing: 18) { curves; context }
                }
                table
            }.padding(24)
        }
        .foregroundStyle(style.primary).background(style.background)
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true)).tint(palette.primary)
        .task(id: log.id) {
            study.reset()
            restoreSelection()
            load()
        }
        .onDisappear { study.cancel() }
        .onChange(of: study.selectedTime) { _, value in cursorInput = value.map { String(format: "%.3f", $0) } ?? "" }
        .accessibilityIdentifier("flight.analysis")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Courbes et chronologie").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                Spacer()
                Text("4 courbes maximum · 2 048 points au total")
                    .font(.system(size: 11)).foregroundStyle(style.secondary)
                Menu {
                    Button("Relevé HTML · courbes et contexte") { chooseExport(html: true) }
                    Button("Relevé JSON · points et provenance") { chooseExport(html: false) }
                } label: { Label(study.isExporting ? "Export…" : "Exporter le relevé", systemImage: "square.and.arrow.up") }
                    .disabled(study.isLoading || study.isExporting || study.response == nil)
                    .accessibilityIdentifier("analysis.export")
            }
            Text("\(log.displayName) · \(log.fileName)")
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Text("Temps relatif du log. Les valeurs affichées sont des observations, sans diagnostic automatique.")
                .font(.system(size: 12)).foregroundStyle(style.secondary)
        }
    }

    private var controls: some View {
        FlightPanel {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { recipeControl; sourceControl }
                    VStack(alignment: .leading, spacing: 14) { recipeControl; sourceControl }
                }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Fenêtre · s").font(.system(size: 12, weight: .medium))
                    TextField("Début", text: $windowFrom).frame(width: 85)
                        .accessibilityLabel("Début de la fenêtre, secondes relatives")
                    Text("→").foregroundStyle(style.secondary)
                    TextField("Fin", text: $windowTo).frame(width: 85)
                        .accessibilityLabel("Fin de la fenêtre, secondes relatives")
                    Button("Appliquer") { load() }.disabled(study.isLoading)
                        .accessibilityIdentifier("analysis.window.apply")
                    Button("Tout le log") { windowFrom = ""; windowTo = ""; load() }
                        .disabled(study.isLoading).controlSize(.small)
                    Spacer(minLength: 0)
                }
                Text("Laisser les bornes vides utilise toute la durée disponible. Les originaux restent inchangés.")
                    .font(.system(size: 11)).foregroundStyle(style.secondary)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var recipeControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Mesures").font(.system(size: 11)).foregroundStyle(style.secondary)
            Picker("Mesures", selection: $recipe) {
                Text("Batterie").tag("battery")
                Text("GNSS").tag("gnss")
                Text("Estimateur EKF").tag("ekf")
                Text("Champ du catalogue").tag("custom")
            }.labelsHidden().frame(width: 210)
                .disabled(study.isLoading)
                .onChange(of: recipe) { _, _ in instance = instances.first ?? 0; load() }
                .accessibilityIdentifier("analysis.recipe")
        }
    }

    @ViewBuilder private var sourceControl: some View {
        if recipe == "custom" {
            VStack(alignment: .leading, spacing: 7) {
                Text("Topic · instance · champ").font(.system(size: 11)).foregroundStyle(style.secondary)
                if extractableFields.isEmpty {
                    Text("Aucun champ numérique extractible dans le catalogue.")
                        .font(.system(size: 12)).foregroundStyle(style.secondary)
                } else {
                    Picker("Champ du catalogue", selection: $fieldKey) {
                        ForEach(extractableFields) { field in
                            Text("\(field.topic) · \(field.instance) · \(field.field) [\(unit(field.unit))]").tag(field.key)
                        }
                    }.labelsHidden().frame(minWidth: 260, maxWidth: .infinity)
                        .disabled(study.isLoading).onChange(of: fieldKey) { _, _ in if recipe == "custom" { load() } }
                        .accessibilityIdentifier("analysis.field")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text("Instance enregistrée").font(.system(size: 11)).foregroundStyle(style.secondary)
                if instances.isEmpty {
                    Text(fields.isEmpty ? "Catalogue indisponible · la lecture précisera les champs absents." : "Aucune instance compatible enregistrée.")
                        .font(.system(size: 12)).foregroundStyle(style.secondary)
                } else {
                    Picker("Instance enregistrée", selection: $instance) {
                        ForEach(instances, id: \.self) { Text("Instance \($0)").tag($0) }
                    }.labelsHidden().frame(width: 160)
                        .disabled(study.isLoading).onChange(of: instance) { _, _ in load() }
                        .accessibilityIdentifier("analysis.instance")
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if study.isExporting {
            HStack { ProgressView().controlSize(.small); Text("Export du relevé…"); Spacer(); Button("Annuler") { study.cancelExport() } }
                .font(.system(size: 12)).accessibilityIdentifier("analysis.exporting")
        }
        if let exportError {
            Label(exportError, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(style.amber).textSelection(.enabled)
        } else if let exportNotice {
            Label(exportNotice, systemImage: "doc.badge.checkmark").font(.system(size: 12)).foregroundStyle(style.secondary)
        }
        if let warning = restorationWarning ?? study.preferenceWarning {
            Label(warning, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(style.amber)
                .textSelection(.enabled).accessibilityIdentifier("analysis.preference-warning")
        }
        if study.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Lecture des mesures de la fenêtre…")
                Spacer()
                Button("Annuler") { study.cancel() }.controlSize(.small)
            }.font(.system(size: 12)).padding(14)
                .background(style.raised, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("analysis.loading")
        }
        if let error = inputError ?? study.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).textSelection(.enabled)
                Spacer()
                Button("Réessayer") { load() }.disabled(study.isLoading)
            }.font(.system(size: 12)).foregroundStyle(style.amber).padding(14)
                .background(style.raised, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("analysis.error")
        }
        if let response = study.response, !response.missingFields.isEmpty {
            DisclosureGroup("\(response.missingFields.count) \(response.missingFields.count == 1 ? "champ absent ou incompatible" : "champs absents ou incompatibles")") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(response.missingFields.enumerated()), id: \.offset) { _, field in
                        Text(field).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(.top, 7)
            }.font(.system(size: 12)).foregroundStyle(style.amber)
                .accessibilityIdentifier("analysis.missing-fields")
        }
    }

    private var curves: some View {
        VStack(alignment: .leading, spacing: 16) {
            if series.isEmpty {
                FlightPanel {
                    FlightEmptyState(symbol: "chart.xyaxis.line", title: study.isLoading ? "Lecture en cours" : "Aucune courbe affichable",
                                     detail: "Les champs absents, valeurs invalides et sources indisponibles sont signalés explicitement. Choisissez une autre mesure ou fenêtre.")
                }
            } else {
                cursor
                ForEach(Array(series.enumerated()), id: \.element.key) { index, curve in
                    curvePanel(curve, index: index)
                }
            }
        }
    }

    private var cursor: some View {
        FlightPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Instant partagé").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(study.selectedTime.map { "t = \(FlightUIFormat.seconds($0))" } ?? "Choisir un instant")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(style.secondary)
                }
                Slider(value: Binding(get: { min(max(study.selectedTime ?? domain.lowerBound, domain.lowerBound), domain.upperBound) },
                                      set: { study.selectedTime = $0 }), in: domain)
                    .accessibilityLabel("Instant relatif partagé par les courbes et la carte")
                    .accessibilityValue(study.selectedTime.map(FlightUIFormat.seconds) ?? "Aucun instant sélectionné")
                    .accessibilityIdentifier("analysis.cursor")
                HStack {
                    TextField("Secondes relatives", text: $cursorInput).textFieldStyle(.roundedBorder).frame(width: 155)
                        .accessibilityLabel("Sélectionner un instant en secondes relatives").onSubmit { selectInputTime() }
                    Button("Aller") { selectInputTime() }.controlSize(.small)
                    Button("Effacer") { study.selectedTime = nil }.controlSize(.small).disabled(study.selectedTime == nil)
                    Spacer()
                }
            }
        }
    }

    private func curvePanel(_ curve: TelemetrySeries, index: Int) -> some View {
        let color = index == 0 ? style.green : index == 1 ? style.amber : style.primary
        return FlightPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(curve.label).font(.system(size: 14, weight: .semibold))
                        Text("\(curve.source) · instance \(curve.instance ?? instance) · \(unit(curve.unit))")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(style.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(curve.interpolation == "step" ? "États discrets" : "Mesures")
                        .font(.system(size: 10)).foregroundStyle(style.secondary)
                }
                if curve.points.isEmpty {
                    Text("Aucun échantillon valide dans cette fenêtre.").font(.system(size: 12)).foregroundStyle(style.secondary)
                } else {
                    Chart {
                        ForEach(curve.points) { point in
                            LineMark(x: .value("Temps relatif, s", point.timeSeconds), y: .value(unit(curve.unit), point.value),
                                     series: .value("Segment", point.segment))
                                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.7))
                                .interpolationMethod(curve.interpolation == "step" ? .stepStart : .linear)
                            PointMark(x: .value("Temps relatif, s", point.timeSeconds), y: .value(unit(curve.unit), point.value))
                                .foregroundStyle(color).symbolSize(5)
                        }
                        if let time = study.selectedTime, domain.contains(time) {
                            RuleMark(x: .value("Instant sélectionné", time))
                                .foregroundStyle(style.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .chartXScale(domain: domain).chartYScale(domain: FlightStudyPresentation.valueDomain(curve))
                    .chartXSelection(value: $study.selectedTime)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) {
                            AxisGridLine().foregroundStyle(style.border); AxisTick(); AxisValueLabel(anchor: .topLeading)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                            AxisGridLine().foregroundStyle(style.border); AxisTick(); AxisValueLabel(anchor: .trailing)
                        }
                    }
                    .chartLegend(.hidden).frame(height: 190)
                    .accessibilityLabel("\(curve.label), \(unit(curve.unit)), \(curve.points.count) échantillons affichés en segments distincts")
                    .accessibilityHint("Le tableau des échantillons et le curseur permettent aussi une consultation au clavier.")
                }
                HStack(alignment: .top) {
                    Text("\(curve.points.count) affichés · \(curve.validSampleCount ?? curve.originalSampleCount) valides · \(curve.segmentCount ?? Set(curve.points.map(\.segment)).count) segments")
                    Spacer()
                    Text("\(curve.rejectedSampleCount ?? 0) rejetés")
                }.font(.system(size: 10)).foregroundStyle(style.secondary)
                Text("Échelle verticale adaptée aux valeurs affichées · aucun seuil de panne appliqué.")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
                Text(FlightStudyPresentation.coverage(curve)).font(.system(size: 11))
                    .foregroundStyle(curve.completeWindow == false ? style.amber : style.secondary)
                if let time = study.selectedTime {
                    if let sample = FlightStudyPresentation.sample(at: time, in: curve) {
                        Text("Échantillon affiché : \(FlightUIFormat.value(sample.value)) \(unit(curve.unit)) · t = \(FlightUIFormat.seconds(sample.timeSeconds)) · écart \(FlightUIFormat.seconds(abs(sample.timeSeconds - time)))")
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text("Aucun échantillon affiché proche de cet instant dans le même segment. Aucune valeur n’est interpolée.")
                            .font(.system(size: 11)).foregroundStyle(style.secondary)
                    }
                }
                if let conversion = curve.sourceConversion {
                    Text(conversion).font(.system(size: 10)).foregroundStyle(style.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var context: some View {
        FlightPanel {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Contexte au même instant").font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                if let time = study.selectedTime {
                    Text("t = \(FlightUIFormat.seconds(time))").font(.system(size: 12, design: .monospaced))
                    if log.track?.points.isEmpty == false {
                        FlightTrackMap(logs: [log], cursorPosition: position?.point,
                                       onSelectTime: { study.selectedTime = $0 })
                            .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(position.map { "Échantillon GPS réel · écart \(FlightUIFormat.seconds($0.timeDifference)) · \($0.source)" }
                             ?? "Aucune position réelle à moins de 2 s, dans le même segment. Aucun repère n’est interpolé.")
                            .font(.system(size: 10)).foregroundStyle(style.secondary)
                    } else {
                        Label("Aucune trajectoire GPS disponible.", systemImage: "map")
                            .font(.system(size: 12)).foregroundStyle(style.secondary)
                    }
                    nearbyRecords(time)
                } else {
                    FlightEmptyState(symbol: "cursorarrow.rays", title: "Choisir un instant",
                                     detail: "Cliquez sur une courbe, utilisez le curseur ou saisissez un temps relatif pour lire le contexte enregistré.")
                }
                Divider()
                Text("Les courbes, messages et positions partagent le temps relatif du log. Une proximité temporelle n’établit pas une cause.")
                    .font(.system(size: 11)).foregroundStyle(style.secondary)
            }
        }
    }

    private func nearbyRecords(_ time: Double) -> some View {
        let messages = log.messages.filter { $0.timestampSeconds.isFinite && abs($0.timestampSeconds - time) <= 2 }
        let events = (log.events ?? []).filter { $0.timeSeconds.map { $0.isFinite && abs($0 - time) <= 2 } ?? false }
        let untimed = (log.events ?? []).filter { $0.timeSeconds == nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(messages.count) messages · \(events.count) événements · ±2 s")
                .font(.system(size: 11, weight: .medium))
            if messages.isEmpty && events.isEmpty {
                Text("Aucun message ou événement horodaté dans cet intervalle.").font(.system(size: 11)).foregroundStyle(style.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            Button { study.selectedTime = message.timestampSeconds } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(message.level) · t = \(FlightUIFormat.seconds(message.timestampSeconds))")
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(style.alertColor(message.level))
                                    Text(message.text).font(.system(size: 11)).multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Message \(message.level), \(FlightUIFormat.seconds(message.timestampSeconds)), \(message.text)")
                        }
                        ForEach(events) { event in
                            DisclosureGroup("Événement \(event.eventID.description) · \(event.timeSeconds.map(FlightUIFormat.seconds) ?? "temps absent")") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(event.message ?? "Texte indisponible · événement brut conservé.")
                                    Text("Niveau \(event.level) · \(event.translationStatus ?? "traduction non renseignée")")
                                    Text("Arguments : \(event.argumentsHex)").font(.system(size: 10, design: .monospaced))
                                    Button("Sélectionner cet instant") { selectEvent(event) }
                                        .controlSize(.small)
                                        .disabled(FlightStudyPresentation.eventTime(event) == nil)
                                        .accessibilityLabel("Sélectionner l’événement \(event.eventID.description) à \(event.timeSeconds.map(FlightUIFormat.seconds) ?? "un temps inconnu")")
                                }.font(.system(size: 11)).textSelection(.enabled).padding(.top, 5)
                            }.font(.system(size: 11))
                        }
                    }
                }.frame(maxHeight: 250)
            }
            if untimed > 0 {
                Text("\(untimed) événements sans temps valide restent disponibles dans les données brutes et ne sont pas alignés ici.")
                    .font(.system(size: 10)).foregroundStyle(style.amber)
            }
        }
    }

    private var table: some View {
        FlightPanel {
            DisclosureGroup("Échantillons affichés · \(series.reduce(0) { $0 + $1.points.count }) valeurs", isExpanded: $showTable) {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack { Text("Mesure").frame(width: 210, alignment: .leading); Text("Temps · s").frame(width: 100); Text("Valeur").frame(width: 115); Text("Unité").frame(width: 90); Text("Segment").frame(width: 65) }
                            .font(.system(size: 11, weight: .semibold)).padding(.vertical, 10)
                        ForEach(series) { curve in
                            ForEach(curve.points) { point in
                                Button { study.selectedTime = point.timeSeconds } label: {
                                    HStack {
                                        Text(curve.label).frame(width: 210, alignment: .leading)
                                        Text(FlightUIFormat.seconds(point.timeSeconds)).frame(width: 100)
                                        Text(FlightUIFormat.value(point.value)).frame(width: 115)
                                        Text(unit(curve.unit)).frame(width: 90)
                                        Text("\(point.segment)").frame(width: 65)
                                    }.font(.system(size: 11)).monospacedDigit().padding(.vertical, 8)
                                        .background(study.selectedTime == point.timeSeconds ? style.raised : .clear)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("\(curve.label), temps \(FlightUIFormat.seconds(point.timeSeconds)), valeur \(FlightUIFormat.value(point.value)) \(unit(curve.unit)), segment \(point.segment). Sélectionner cet instant.")
                            }
                        }
                    }.textSelection(.enabled)
                }.frame(maxHeight: 340)
                Text("Ce tableau reprend tous les points dessinés. La réduction des séries et les données omises sont indiquées au-dessus de chaque courbe.")
                    .font(.system(size: 11)).foregroundStyle(style.secondary).padding(.top, 10)
            }.font(.system(size: 13, weight: .medium))
                .accessibilityIdentifier("analysis.samples-table")
        }
    }

    private func unit(_ value: String) -> String { value.isEmpty || value == "unknown" ? "unité inconnue" : value }
    private func selectEvent(_ event: PX4Event) {
        guard let time = FlightStudyPresentation.eventTime(event) else { return }
        study.selectedTime = time
    }
    private func restoreSelection() {
        recipe = "battery"; windowFrom = ""; windowTo = ""; restorationWarning = nil
        fieldKey = extractableFields.first?.key ?? ""
        instance = instances.first ?? 0
        guard let request = study.lastRequest(logID: log.id) else { return }
        if let savedRecipe = request.recipe {
            guard FlightStudyPresentation.recipeFields(savedRecipe, catalogue: fields).contains(where: { $0.instance == request.instance }) else {
                restorationWarning = "La mesure ou l’instance mémorisée n’est pas disponible dans ce catalogue. La sélection par défaut est affichée."; return
            }
            recipe = savedRecipe; instance = request.instance
        } else {
            guard let field = extractableFields.first(where: { $0.topic == request.topic && $0.field == request.field && $0.instance == request.instance }) else {
                restorationWarning = "Le champ mémorisé n’est plus extractible dans ce catalogue. La sélection par défaut est affichée."; return
            }
            recipe = "custom"; fieldKey = field.key; instance = field.instance
        }
        windowFrom = request.timeFrom.map { String($0) } ?? ""
        windowTo = request.timeTo.map { String($0) } ?? ""
    }
    private func load() {
        do {
            let window = try FlightStudyPresentation.window(from: windowFrom, to: windowTo)
            var request = TelemetryRequest(recipe: recipe, instance: instance)
            if recipe == "custom" {
                guard let field = extractableFields.first(where: { $0.key == fieldKey }) else {
                    inputError = "Aucun champ extractible sélectionné dans le catalogue."; return
                }
                request.recipe = nil; request.topic = field.topic; request.field = field.field; request.instance = field.instance
            }
            request.timeFrom = window.0; request.timeTo = window.1
            inputError = nil; study.load(logID: log.id, request: request)
        } catch { inputError = error.localizedDescription }
    }
    private func selectInputTime() {
        guard let value = FlightStudyPresentation.number(cursorInput), domain.contains(value) else {
            inputError = "Saisissez un temps fini entre \(FlightUIFormat.seconds(domain.lowerBound)) et \(FlightUIFormat.seconds(domain.upperBound))."; return
        }
        inputError = nil; study.selectedTime = value
    }
    private func chooseExport(html: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [html ? .html : .json]
        panel.nameFieldStringValue = "KataLog-releve.\(html ? "html" : "json")"
        panel.message = "Ce relevé conserve les points affichés et leur provenance. Les séries peuvent être réduites ; les échantillons originaux restent dans le fichier ULog."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportError = nil; exportNotice = nil
        Task {
            do {
                try await study.export(log: log, to: destination, html: html)
                exportNotice = "Relevé exporté : \(destination.lastPathComponent) · fichier ULog original inchangé."
            } catch is CancellationError { exportNotice = "Export annulé ; le fichier précédent est conservé." }
            catch { exportError = "Export impossible : \(error.localizedDescription)" }
        }
    }
}

enum FlightStudyPresentation {
    static func eventTime(_ event: PX4Event) -> Double? {
        guard let time = event.timeSeconds, time.isFinite, time >= 0 else { return nil }
        return time
    }
    /// Matches the extractor's version-one built-in recipes; timestamps and unrelated fields do not create a selectable instance.
    static func recipeFields(_ recipe: String, catalogue: [TelemetryField]) -> [TelemetryField] {
        let specification: (String, Set<String>)
        switch recipe {
        case "battery": specification = ("battery_status", ["voltage_v", "current_a", "remaining", "discharged_mah"])
        case "gnss": specification = ("sensor_gps", ["fix_type", "satellites_used", "eph", "epv"])
        case "ekf": specification = ("estimator_status", ["pos_test_ratio", "vel_test_ratio", "hgt_test_ratio", "mag_test_ratio"])
        default: return []
        }
        return catalogue.filter { $0.extractable && $0.topic == specification.0 && specification.1.contains($0.field) }
    }
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite else { return nil }; return value
    }
    static func window(from: String, to: String) throws -> (Double?, Double?) {
        let lowerEmpty = from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let upperEmpty = to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let lower = lowerEmpty ? nil : number(from), upper = upperEmpty ? nil : number(to)
        guard (lowerEmpty || lower != nil), (upperEmpty || upper != nil),
              lower == nil || upper == nil || lower! <= upper! else {
            throw AnalysisError.engine("Fenêtre invalide : utilisez des secondes finies et un début inférieur ou égal à la fin.")
        }
        return (lower, upper)
    }
    static func timeDomain(_ series: [TelemetrySeries]) -> ClosedRange<Double> {
        let times = series.flatMap(\.points).map(\.timeSeconds).filter(\.isFinite)
        guard let lower = times.min(), let upper = times.max() else { return 0...1 }
        return lower == upper ? (lower - 0.5)...(upper + 0.5) : lower...upper
    }
    static func valueDomain(_ series: TelemetrySeries) -> ClosedRange<Double> {
        let values = series.points.map(\.value).filter(\.isFinite)
        guard let lower = values.min(), let upper = values.max() else { return 0...1 }
        let padding = max((upper - lower) * 0.06, max(max(abs(lower), abs(upper)), 1) * 0.0001)
        let paddedLower = lower - padding, paddedUpper = upper + padding
        if paddedLower.isFinite && paddedUpper.isFinite && paddedLower < paddedUpper { return paddedLower...paddedUpper }
        if lower < upper { return lower...upper }
        let before = lower.nextDown, after = lower.nextUp
        return (before.isFinite ? before : lower)...(after.isFinite ? after : lower)
    }
    static func coverage(_ series: TelemetrySeries) -> String {
        let omitted = (series.omittedSegmentCount ?? 0) + (series.omittedTransitionCount ?? 0) + (series.omittedExtremaCount ?? 0)
        if omitted > 0 {
            return "Budget de dessin : \(series.omittedSegmentCount ?? 0) segments, \(series.omittedTransitionCount ?? 0) transitions et \(series.omittedExtremaCount ?? 0) extrema omis. Les lacunes restent séparées."
        }
        if series.completeWindow == false {
            return "Couverture partielle : \(series.rejectedSampleCount ?? 0) échantillons rejetés, \(series.longGapCount ?? 0) longues lacunes et \(series.timeReversalCount ?? 0) inversions de temps signalés. Les segments restent séparés."
        }
        guard let valid = series.validSampleCount, series.completeWindow != nil else {
            return "Couverture non renseignée pour cette série. Les points dessinés restent des échantillons enregistrés."
        }
        if series.points.count < valid {
            return "Série réduite pour l’affichage ; extrema et transitions conservés dans le budget disponible. Les lacunes restent séparées."
        }
        return "Tous les échantillons valides de cette fenêtre sont affichés. Les lacunes restent séparées."
    }
    static func sample(at time: Double, in series: TelemetrySeries) -> TelemetryPoint? {
        guard time.isFinite else { return nil }
        return Dictionary(grouping: series.points, by: \.segment).values.compactMap { points -> TelemetryPoint? in
            guard let first = points.first, let last = points.last,
                  time >= first.timeSeconds, time <= last.timeSeconds,
                  let nearest = points.min(by: { abs($0.timeSeconds - time) < abs($1.timeSeconds - time) }),
                  abs(nearest.timeSeconds - time) <= 2 else { return nil }
            return nearest
        }.min { abs($0.timeSeconds - time) < abs($1.timeSeconds - time) }
    }
}
