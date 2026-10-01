import SwiftUI
import MapKit
import KataLogCore

struct FleetMapView: View {
    let logs: [FlightLog]
    var showsHeading = true
    let onSelectLog: (FlightLog) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    @State private var selectedLogID: String?
    @State private var fitRequest = UUID()
    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var visibleLogs: [FlightLog] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return logs.filter {
            query.isEmpty || [$0.displayName, $0.droneName, $0.droneID, $0.metadata["gcsUUID"] ?? "", $0.fileName, $0.date].contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { ($0.date, $0.fileName) > ($1.date, $1.fileName) }
    }
    private var mappedCount: Int { visibleLogs.filter { FlightMapGeometry.hasTrack($0) }.count }
    private var selectedLog: FlightLog? {
        visibleLogs.first { $0.id == selectedLogID } ?? visibleLogs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                if showsHeading { VStack(alignment: .leading, spacing: 7) {
                    Text("Carte").font(.system(size: 28, weight: .semibold)).tracking(-1)
                    Text("Situer les vols et les alertes à partir des positions contenues dans les logs.")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                } }
                Spacer(minLength: 8)
                Button { fitRequest = UUID() } label: {
                    HStack(spacing: 7) { BentoIcon(symbol: "mappin.and.ellipse", size: 16); Text("Recentrer") }
                }
                .buttonStyle(WorkspaceActionButtonStyle(palette: palette))
                .disabled(mappedCount == 0)
                .accessibilityIdentifier("map.recenter")
            }
            HStack(spacing: 10) {
                BentoIcon(symbol: "magnifyingglass", size: 17).foregroundStyle(palette.secondary)
                TextField("Rechercher un log ou un drone…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityIdentifier("map.search")
                if !search.isEmpty {
                    Button { search = "" } label: { BentoIcon(symbol: "xmark.circle.fill", size: 14) }
                        .buttonStyle(.plain).foregroundStyle(palette.secondary)
                        .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border, lineWidth: 1))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    mapCanvas.frame(minWidth: 430, maxWidth: .infinity).frame(height: 560)
                    recordingsCard.frame(width: 250, height: 560)
                }
                VStack(alignment: .leading, spacing: 18) {
                    mapCanvas.frame(height: 480)
                    recordingsCard.frame(height: 300)
                }
            }
            HStack(alignment: .top, spacing: 9) {
                BentoIcon(symbol: "info.circle", size: 14)
                Text("La carte utilise les positions enregistrées. Les logs sans coordonnées restent accessibles dans l’historique.")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.secondary)
        }
        .foregroundStyle(palette.primary)
        .onChange(of: visibleLogs.map(\.id)) { _, ids in
            if let selectedLogID, !ids.contains(selectedLogID) { self.selectedLogID = nil }
        }
    }

    private var mapCanvas: some View {
        FlightTrackMap(logs: visibleLogs, fitRequest: fitRequest, onSelectLog: { log in
            selectedLogID = log.id
            onSelectLog(log)
        })
    }

    private var recordingsCard: some View {
        BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Logs géolocalisés").font(.system(size: 15, weight: .semibold)).tracking(-0.25)
                    Text("Sélection de la carte").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleLogs) { log in
                            recordingRow(log)
                        }
                        if visibleLogs.isEmpty {
                            Text("Aucun log pour cette recherche.")
                                .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 20)
                        }
                    }
                }
                Divider().overlay(palette.border)
                HStack(alignment: .top, spacing: 10) {
                    BentoIcon(symbol: "mappin.and.ellipse", size: 18).foregroundStyle(palette.secondary)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(mappedCount) / \(visibleLogs.count)")
                            .font(.system(size: 24, weight: .semibold)).tracking(-1).monospacedDigit()
                        Text("logs avec positions GPS").font(.system(size: 10)).foregroundStyle(palette.secondary)
                    }
                }
                Text("Les 80 plus récents sont affichés. Les lacunes GPS ne sont pas reliées artificiellement.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let selectedLog { onSelectLog(selectedLog) }
                } label: {
                    HStack(spacing: 7) { BentoIcon(symbol: "doc.text", size: 15); Text("Ouvrir le log sélectionné") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
                .disabled(selectedLog == nil)
                .accessibilityIdentifier("map.openSelectedFlight")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func recordingRow(_ log: FlightLog) -> some View {
        let hasTrack = FlightMapGeometry.hasTrack(log)
        let positionedAlertCount = log.messages.filter {
            $0.isAlert && $0.position.map(FlightMapGeometry.isValid) == true
        }.count
        let selected = selectedLog?.id == log.id
        return Button {
            selectedLogID = log.id
            onSelectLog(log)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(log.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if !hasTrack { BentoIcon(symbol: "location.slash", size: 13).foregroundStyle(palette.secondary) }
                }
                Text(log.date.isEmpty ? "Date inconnue" : log.date)
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                Text(log.fileName).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                BentoStatus(label: !hasTrack ? "Sans trajectoire" : positionedAlertCount > 0 ? "\(positionedAlertCount) alertes localisées" : "Sans alerte localisée",
                            color: positionedAlertCount > 0 ? palette.amber : palette.secondary)
                Text(FlightUIFormat.duration(log.durationSeconds))
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            .foregroundStyle(palette.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.raised : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? palette.border : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Ouvrir la fiche de \(log.fileName)")
        .accessibilityIdentifier("map.openFlight.\(log.id)")
    }
}

/// Shared map used by the fleet view and the single-flight inspector.
/// Coordinates always come from the log; the map never requests the Mac's location.
struct FlightTrackMap: View {
    let logs: [FlightLog]
    var cursorTime: Double? = nil
    var cursorPosition: TrackPoint? = nil
    var fitRequest: UUID? = nil
    var onSelectLog: ((FlightLog) -> Void)? = nil
    var onSelectTime: ((Double) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var camera: MapCameraPosition = .automatic
    @State private var satellite = false
    @State private var showAlerts = true
    @State private var alertFamily: String?
    @State private var alertLevel = "Tous"
    @State private var selectedAlertID: String?
    @State private var mapRefreshID = UUID()
    @State private var visibleMapRect: MKMapRect?
    private var selectedAlert: PositionedFlightAlert? { filteredAlerts.first { $0.id == selectedAlertID } }
    private var style: FlightUIStyle { FlightUIStyle(colorScheme) }
    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var displayedLogs: [FlightLog] { FlightMapGeometry.displayedLogs(logs) }
    private var segments: [FlightMapSegment] { FlightMapGeometry.segments(displayedLogs) }
    private var mappedLogs: [FlightLog] { logs.filter { FlightMapGeometry.hasTrack($0) } }
    private var allPositionedAlerts: [PositionedFlightAlert] {
        displayedLogs.flatMap { log in
            log.messages.compactMap { message in
                guard message.isAlert, let point = message.position, FlightMapGeometry.isValid(point) else { return nil }
                return PositionedFlightAlert(log: log, message: message, point: point)
            }
        }
    }
    private var filteredAlerts: [PositionedFlightAlert] {
        allPositionedAlerts.filter {
            (alertFamily == nil || $0.message.family == alertFamily) &&
            (alertLevel == "Tous" || (alertLevel == "WARNING+" && $0.message.priority >= 4) ||
             (alertLevel == "ERROR+" && $0.message.priority >= 5))
        }
    }
    private var alertPins: [PositionedFlightAlert] {
        var groups = Set<String>()
        return filteredAlerts.sorted {
            $0.message.priority != $1.message.priority ? $0.message.priority > $1.message.priority : $0.message.timestampSeconds < $1.message.timestampSeconds
        }.filter { groups.insert($0.log.id + ":" + $0.message.groupKey).inserted }.prefix(40).map { $0 }
    }
    private var cursorPoint: TrackPoint? {
        if let point = cursorPosition, FlightMapGeometry.isValid(point) { return point }
        guard logs.count == 1, let time = cursorTime, let points = logs.first?.track?.points else { return nil }
        return FlightMapGeometry.point(at: time, in: points)
    }
    private var dataIdentity: [String] { logs.map { $0.id + ":" + String($0.track?.points.count ?? 0) } }

    var body: some View {
        FlightPanel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if segments.isEmpty {
                        FlightEmptyState(symbol: "location.slash", title: "Aucune trajectoire GPS affichable",
                                         detail: "Aucune trajectoire n’est disponible dans l’analyse actuelle. Si ces logs proviennent d’un ancien import, actualisez les analyses. Les messages et les autres mesures restent consultables.")
                            .padding(.top, 95).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        nativeMap
                            .id(mapRefreshID)
                            .overlay(alignment: .bottomLeading) {
                                if mappedLogs.count < logs.count {
                                    Text("\(logs.count - mappedLogs.count) logs sans trajectoire")
                                        .font(.system(size: 10, weight: .medium)).padding(9)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(12)
                                }
                            }
                    }
                    controls.padding(12)
                }
                mapFooter.padding(14)
            }
        }
        .onAppear(perform: fitTracks)
        .onChange(of: fitRequest) { _, _ in fitTracks() }
        .onChange(of: dataIdentity) { _, _ in selectedAlertID = nil; fitTracks() }
        .onChange(of: filteredAlerts.map(\.id)) { _, ids in
            if let selectedAlertID, !ids.contains(selectedAlertID) { self.selectedAlertID = nil }
        }
        .onChange(of: alertFamily) { _, _ in selectedAlertID = nil }
        .onChange(of: alertLevel) { _, _ in selectedAlertID = nil }
        .onChange(of: showAlerts) { _, shown in if !shown { selectedAlertID = nil } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    mapStyleButtons
                    Spacer(minLength: 8)
                    cameraButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    mapStyleButtons
                    cameraButtons
                }
            }
            HStack(spacing: 10) {
                Toggle("Alertes", isOn: $showAlerts).toggleStyle(.checkbox).font(.system(size: 11))
                if showAlerts {
                    Picker("Famille", selection: $alertFamily) {
                        Text("Toutes").tag(String?.none)
                        ForEach(Set(allPositionedAlerts.map { $0.message.family }).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(maxWidth: 135)
                    Picker("Niveau", selection: $alertLevel) {
                        ForEach(["Tous", "WARNING+", "ERROR+"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small).padding(9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var mapStyleButtons: some View {
        HStack(spacing: 8) {
            Button { satellite = false } label: {
                HStack(spacing: 7) {
                    BentoIcon(symbol: "map", size: 16)
                    Text("Plan")
                    if !satellite { BentoIcon(symbol: "checkmark", size: 11) }
                }
            }
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
            .accessibilityValue(satellite ? "Non sélectionné" : "Sélectionné")
            .accessibilityIdentifier("map.plan")
            Button { satellite = true } label: {
                HStack(spacing: 7) {
                    BentoIcon(symbol: "square.3.layers.3d", size: 16)
                    Text("Satellite")
                    if satellite { BentoIcon(symbol: "checkmark", size: 11) }
                }
            }
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
            .accessibilityValue(satellite ? "Sélectionné" : "Non sélectionné")
            .accessibilityIdentifier("map.satellite")
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("map.style")
    }

    private var cameraButtons: some View {
        HStack(spacing: 8) {
            mapControl(symbol: "minus.magnifyingglass", label: "Dézoomer", identifier: "map.zoomOut") { zoomMap(factor: 1.7) }
            mapControl(symbol: "plus.magnifyingglass", label: "Zoomer", identifier: "map.zoomIn") { zoomMap(factor: 1 / 1.7) }
            mapControl(symbol: "arrow.up.left.and.arrow.down.right", label: "Cadrer les trajectoires", identifier: "map.fit", action: fitTracks)
            mapControl(symbol: "arrow.clockwise", label: "Recharger le fond", identifier: "map.reloadBackground") { mapRefreshID = UUID() }
                .help("Si le fond reste vide, vérifiez votre connexion. Les fichiers ULog ne sont pas relus.")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func mapControl(symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { BentoIcon(symbol: symbol, size: 16).frame(width: 16) }
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
            .disabled(segments.isEmpty).help(label).accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private var nativeMap: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
            ForEach(segments) { segment in
                if segment.points.count > 1 {
                    MapPolyline(coordinates: segment.points.map(FlightMapGeometry.coordinate))
                        .stroke(style.green.opacity(logs.count == 1 ? 0.95 : 0.65), lineWidth: logs.count == 1 ? 3 : 2)
                } else if let point = segment.points.first {
                    Annotation("Position GPS isolée", coordinate: FlightMapGeometry.coordinate(point)) {
                        Circle().fill(style.green).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(style.card, lineWidth: 2))
                            .help("Échantillon isolé · aucune trajectoire déduite")
                    }
                }
            }
            ForEach(displayedLogs) { log in
                if let point = log.track?.points.first(where: FlightMapGeometry.isValid) {
                    Annotation("\(log.displayName) · premier point", coordinate: FlightMapGeometry.coordinate(point)) {
                        Button { onSelectLog?(log) } label: {
                            BentoIcon(symbol: "drone", size: 14)
                                .foregroundStyle(style.primary).padding(8)
                                .background(style.card, in: Circle())
                                .overlay(Circle().stroke(style.primary.opacity(0.4)))
                        }
                        .buttonStyle(.plain).help("\(log.displayName) · \(log.date)\nPremier point GPS enregistré")
                    }
                }
            }
            if showAlerts {
                ForEach(alertPins) { alert in
                    Annotation(alert.message.title, coordinate: FlightMapGeometry.coordinate(alert.point)) {
                        Button {
                            selectedAlertID = alert.id
                            onSelectTime?(alert.message.timestampSeconds)
                        } label: {
                            Image(systemName: alert.message.priority >= 5 ? "exclamationmark" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 24, height: 24)
                                .background(alert.message.priority >= 5 ? style.red : style.amber, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("\(alert.message.level) · \(alert.message.text)\nt=\(FlightUIFormat.seconds(alert.message.timestampSeconds))")
                    }
                }
            }
            if let point = cursorPoint {
                Annotation("Curseur · échantillon GPS", coordinate: FlightMapGeometry.coordinate(point)) {
                    Circle().fill(.white).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.black, lineWidth: 3))
                        .shadow(color: .black.opacity(0.25), radius: 3)
                }
            }
        }
        .mapStyle(satellite ? .imagery(elevation: .flat) : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .onEnd) { visibleMapRect = $0.rect }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mapFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let alert = selectedAlert {
                HStack(alignment: .top, spacing: 8) {
                    Text(alert.message.level).font(.system(size: 10, weight: .semibold)).foregroundStyle(style.alertColor(alert.message.level))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.message.text).font(.system(size: 11)).lineLimit(3).textSelection(.enabled)
                        Text("\(alert.log.displayName) · t=\(FlightUIFormat.seconds(alert.message.timestampSeconds)) · position GPS associée")
                            .font(.system(size: 10)).foregroundStyle(style.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { selectedAlertID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            HStack(alignment: .top) {
                Text("\(segments.reduce(0) { $0 + $1.points.count }) points affichés · \(displayedLogs.reduce(0) { $0 + ($1.track?.rejectedPointCount ?? 0) }) rejetés")
                Spacer()
                if showAlerts { Text("\(alertPins.count) repères / \(filteredAlerts.count) messages géolocalisés") }
            }
            .font(.system(size: 10)).foregroundStyle(style.secondary)
            if showAlerts && !filteredAlerts.isEmpty {
                Text("Un repère par type et par log, au plus 40. Les messages complets sont dans la fiche du vol.")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
            }
            if mappedLogs.count > 80 {
                Text("80 logs géolocalisés récents affichés sur \(mappedLogs.count). Filtrez la liste pour explorer les autres trajectoires.")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
            }
            if logs.count == 1, let track = logs.first?.track {
                Text("Source : \(track.source) · \(track.points.count) / \(track.originalPointCount) points conservés. Les interruptions sont séparées.")
                    .font(.system(size: 10)).foregroundStyle(style.secondary)
            }
            Label("Le fond Apple dépend du réseau et de son cache. Un fond vide ne signifie pas une absence de GPS ; les coordonnées des logs restent locales.", systemImage: "network")
                .font(.system(size: 10)).foregroundStyle(style.secondary)
        }
    }

    private func fitTracks() {
        guard let rect = FlightMapGeometry.bounds(segments.flatMap(\.points)) else { return }
        visibleMapRect = rect
        camera = .rect(rect)
    }

    private func zoomMap(factor: Double) {
        guard let rect = visibleMapRect ?? camera.rect ?? FlightMapGeometry.bounds(segments.flatMap(\.points)) else { return }
        let width = max(rect.size.width * factor, 1)
        let height = max(rect.size.height * factor, 1)
        let zoomed = MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        visibleMapRect = zoomed
        camera = .rect(zoomed)
    }
}

private struct PositionedFlightAlert: Identifiable {
    let log: FlightLog
    let message: LogMessage
    let point: TrackPoint
    var id: String { log.id + ":" + message.id }
}

struct FlightMapSegment: Identifiable {
    let id: String
    let points: [TrackPoint]
}

enum FlightMapGeometry {
    static func isValid(_ point: TrackPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite && point.timeSeconds.isFinite &&
        abs(point.latitude) < 90 && abs(point.longitude) <= 180
    }
    static func coordinate(_ point: TrackPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
    static func hasTrack(_ log: FlightLog) -> Bool { log.track?.points.contains(where: isValid) ?? false }
    static func displayedLogs(_ logs: [FlightLog], limit: Int = 80) -> [FlightLog] {
        Array(logs.filter(hasTrack).sorted { ($0.date, $0.fileName, $0.id) > ($1.date, $1.fileName, $1.id) }.prefix(max(0, limit)))
    }
    static func segments(_ logs: [FlightLog]) -> [FlightMapSegment] {
        logs.flatMap { log in
            Dictionary(grouping: log.track?.points.filter(isValid) ?? [], by: \.segment).map { segment, points in
                FlightMapSegment(id: log.id + ":" + String(segment), points: points.sorted { $0.timeSeconds < $1.timeSeconds })
            }.sorted { $0.id < $1.id }
        }
    }
    static func bounds(_ points: [TrackPoint]) -> MKMapRect? {
        let projected = points.filter(isValid).map { MKMapPoint(coordinate($0)) }.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = projected.first else { return nil }
        var rect = MKMapRect(x: first.x, y: first.y, width: 0, height: 0)
        for point in projected.dropFirst() { rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0)) }
        let paddingX = max(rect.size.width * 0.12, 300)
        let paddingY = max(rect.size.height * 0.12, 300)
        return rect.insetBy(dx: -paddingX, dy: -paddingY)
    }
    static func point(at time: Double, in points: [TrackPoint]) -> TrackPoint? {
        for segment in Dictionary(grouping: points.filter(isValid), by: \.segment).values {
            guard let first = segment.min(by: { $0.timeSeconds < $1.timeSeconds }),
                  let last = segment.max(by: { $0.timeSeconds < $1.timeSeconds }),
                  (first.timeSeconds...last.timeSeconds).contains(time) else { continue }
            return segment.min { abs($0.timeSeconds - time) < abs($1.timeSeconds - time) }
        }
        return nil
    }
}

struct FlightUIStyle {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    private var palette: Palette { Palette(dark: dark) }
    var background: Color { palette.background }
    var card: Color { palette.card }
    var raised: Color { palette.raised }
    var border: Color { palette.border }
    var primary: Color { palette.primary }
    var secondary: Color { palette.secondary }
    var green: Color { palette.mint }
    var amber: Color { palette.amber }
    var red: Color { palette.red }
    func alertColor(_ level: String) -> Color { LogMessage.rank(level) >= 5 ? red : LogMessage.rank(level) >= 4 ? amber : secondary }
}

struct FlightPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = BentoTokens.cardPadding
    @ViewBuilder let content: Content
    var body: some View {
        let style = FlightUIStyle(colorScheme)
        content.padding(padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(style.card, in: RoundedRectangle(cornerRadius: BentoTokens.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: BentoTokens.cardRadius).stroke(style.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: BentoTokens.cardRadius))
    }
}

struct FlightEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).frame(maxWidth: 570, alignment: .leading)
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum FlightUIFormat {
    static func duration(_ seconds: Double) -> String { String(format: "%.1f min", max(0, seconds) / 60) }
    static func seconds(_ seconds: Double) -> String { String(format: "%.3f s", seconds) }
    static func value(_ value: Double) -> String {
        if abs(value) >= 1000 { return String(format: "%.1f", value) }
        return String(format: "%.3f", value)
    }
}
