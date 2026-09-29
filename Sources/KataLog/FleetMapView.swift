import SwiftUI
import MapKit
import KataLogCore

struct FleetMapView: View {
    let logs: [FlightLog]
    let onSelectLog: (FlightLog) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    private var style: FlightUIStyle { FlightUIStyle(colorScheme) }
    private var visibleLogs: [FlightLog] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return logs.filter {
            query.isEmpty || [$0.displayName, $0.droneName, $0.droneID, $0.metadata["gcsUUID"] ?? "", $0.fileName, $0.date].contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { ($0.date, $0.fileName) > ($1.date, $1.fileName) }
    }
    private var mappedCount: Int { visibleLogs.filter { FlightMapGeometry.hasTrack($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Les vols sur la carte").font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                    Text("\(mappedCount) logs géolocalisés sur \(visibleLogs.count) · premiers points et trajectoires enregistrées")
                        .font(.system(size: 12)).foregroundStyle(style.secondary)
                }
                Spacer()
                TextField("Drone, fichier ou date", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 230)
                    .accessibilityIdentifier("map.search")
            }
            HStack(alignment: .top, spacing: 16) {
                FlightTrackMap(logs: visibleLogs, onSelectLog: onSelectLog)
                    .frame(maxWidth: .infinity).frame(height: 650)
                FlightPanel {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Enregistrements").font(.system(size: 15, weight: .semibold))
                        Text("Sélectionner un log ouvre sa fiche.").font(.system(size: 11)).foregroundStyle(style.secondary)
                        Divider()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(visibleLogs) { log in
                                    Button { onSelectLog(log) } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            HStack {
                                                Text(log.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                                Spacer()
                                                Image(systemName: FlightMapGeometry.hasTrack(log) ? "location" : "location.slash")
                                                    .foregroundStyle(FlightMapGeometry.hasTrack(log) ? style.green : style.secondary)
                                            }
                                            Text(log.date.isEmpty ? "Date inconnue" : log.date)
                                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(style.secondary)
                                            Text(log.fileName).font(.system(size: 10)).foregroundStyle(style.secondary).lineLimit(1)
                                            HStack(spacing: 8) {
                                                Text(FlightUIFormat.duration(log.durationSeconds))
                                                Text("·")
                                                Text(FlightMapGeometry.hasTrack(log) ? "GPS disponible" : "Sans trajectoire")
                                            }
                                            .font(.system(size: 10)).foregroundStyle(style.secondary)
                                        }
                                        .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("map.openFlight.\(log.id)")
                                    Divider()
                                }
                                if visibleLogs.isEmpty {
                                    Text("Aucun log pour cette recherche.")
                                        .font(.system(size: 12)).foregroundStyle(style.secondary).padding(.vertical, 20)
                                }
                            }
                        }
                    }
                }
                .frame(width: 275, height: 650)
            }
        }
        .foregroundStyle(style.primary)
    }
}

/// Shared map used by the fleet view and the single-flight inspector.
/// Coordinates always come from the log; the map never requests the Mac's location.
struct FlightTrackMap: View {
    let logs: [FlightLog]
    var cursorTime: Double? = nil
    var cursorPosition: TrackPoint? = nil
    var onSelectLog: ((FlightLog) -> Void)? = nil
    var onSelectTime: ((Double) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var camera: MapCameraPosition = .automatic
    @State private var satellite = false
    @State private var showAlerts = true
    @State private var alertFamily: String?
    @State private var alertLevel = "Tous"
    @State private var selectedAlertID: String?
    private var selectedAlert: PositionedFlightAlert? { filteredAlerts.first { $0.id == selectedAlertID } }
    private var style: FlightUIStyle { FlightUIStyle(colorScheme) }
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
                controls.padding(16)
                if segments.isEmpty {
                    FlightEmptyState(symbol: "location.slash", title: "Aucune trajectoire GPS affichable",
                                     detail: "Aucune trajectoire n’est disponible dans l’analyse actuelle. Si ces logs proviennent d’un ancien import, actualisez les analyses. Les messages et les autres mesures restent consultables.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    nativeMap
                        .overlay(alignment: .topLeading) {
                            if mappedLogs.count < logs.count {
                                Text("\(logs.count - mappedLogs.count) logs sans trajectoire")
                                    .font(.system(size: 10, weight: .medium)).padding(9)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7)).padding(12)
                            }
                        }
                }
                mapFooter.padding(14)
            }
        }
        .onAppear(perform: fitTracks)
        .onChange(of: dataIdentity) { _, _ in selectedAlertID = nil; fitTracks() }
        .onChange(of: filteredAlerts.map(\.id)) { _, ids in
            if let selectedAlertID, !ids.contains(selectedAlertID) { self.selectedAlertID = nil }
        }
        .onChange(of: alertFamily) { _, _ in selectedAlertID = nil }
        .onChange(of: alertLevel) { _, _ in selectedAlertID = nil }
        .onChange(of: showAlerts) { _, shown in if !shown { selectedAlertID = nil } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Fond", selection: $satellite) {
                    Text("Plan").tag(false)
                    Text("Satellite").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 175)
                .accessibilityIdentifier("map.style")
                Spacer()
                Button(action: fitTracks) { Label("Cadrer", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(segments.isEmpty)
                    .accessibilityIdentifier("map.fit")
            }
            HStack(spacing: 12) {
                Toggle("Alertes", isOn: $showAlerts).toggleStyle(.checkbox).font(.system(size: 11))
                if showAlerts {
                    Picker("Famille", selection: $alertFamily) {
                        Text("Toutes").tag(String?.none)
                        ForEach(Set(allPositionedAlerts.map { $0.message.family }).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(maxWidth: 150)
                    Picker("Niveau", selection: $alertLevel) {
                        ForEach(["Tous", "WARNING+", "ERROR+"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
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
                            Image(systemName: "airplane")
                                .font(.system(size: 11, weight: .semibold))
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
        .mapControls { MapCompass(); MapScaleView(); MapZoomStepper() }
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
            Label("Fond de carte Apple chargé via le réseau. Les logs restent dans la bibliothèque locale.", systemImage: "network")
                .font(.system(size: 10)).foregroundStyle(style.secondary)
        }
    }

    private func fitTracks() {
        guard let rect = FlightMapGeometry.bounds(segments.flatMap(\.points)) else { return }
        camera = .rect(rect)
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
    var background: Color { dark ? Color(white: 0.045) : Color(white: 0.966) }
    var card: Color { dark ? Color(white: 0.095) : .white }
    var raised: Color { dark ? Color(white: 0.14) : Color(white: 0.946) }
    var border: Color { dark ? Color(white: 0.20) : Color(white: 0.87) }
    var primary: Color { dark ? Color(white: 0.95) : Color(white: 0.09) }
    var secondary: Color { dark ? Color(white: 0.67) : Color(white: 0.40) }
    var green: Color { dark ? Color(red: 0.55, green: 0.77, blue: 0.67) : Color(red: 0.20, green: 0.47, blue: 0.35) }
    var amber: Color { dark ? Color(red: 0.89, green: 0.72, blue: 0.44) : Color(red: 0.62, green: 0.39, blue: 0.09) }
    var red: Color { dark ? Color(red: 0.9, green: 0.55, blue: 0.51) : Color(red: 0.69, green: 0.25, blue: 0.21) }
    func alertColor(_ level: String) -> Color { LogMessage.rank(level) >= 5 ? red : LogMessage.rank(level) >= 4 ? amber : secondary }
}

struct FlightPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = 20
    @ViewBuilder let content: Content
    var body: some View {
        let style = FlightUIStyle(colorScheme)
        content.padding(padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(style.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(style.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
