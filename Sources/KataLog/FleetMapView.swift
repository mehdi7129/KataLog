import SwiftUI
import MapKit
import Combine
import KataLogCore

struct FleetMapView: View {
    let logs: [FlightLog]
    var showsHeading = true
    var proximity: GeographicProximity? = nil
    var totalCount: Int? = nil
    var proximityUnavailableLogs: Int? = nil
    var isSearching = false
    var onProximityChange: ((GeographicProximity?) -> Void)? = nil
    let onSelectLog: (FlightLog) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var places = MapPlaceSearchStore()
    @State private var search = ""
    @State private var radiusMeters: Double = 5_000
    @State private var selectedPlaceName = ""
    @State private var selectedLogID: String?
    @State private var fitRequest = UUID()
    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var visibleLogs: [FlightLog] { logs.sorted { ($0.date, $0.fileName) > ($1.date, $1.fileName) } }
    private var mappedCount: Int { visibleLogs.filter { FlightMapGeometry.hasTrack($0) }.count }
    private var resultCount: Int { totalCount ?? visibleLogs.count }
    private var radiusLabel: String { MapPlaceSearchStore.radiusLabel(proximity?.radiusMeters ?? radiusMeters) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeading {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Carte").font(.system(size: 28, weight: .semibold)).tracking(-1)
                    Text("Retrouvez les logs autour d’un lieu.").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }
            if onProximityChange != nil { searchControls }
            if let error = places.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(palette.amber) }
            if !places.results.isEmpty { placeResults }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    mapCanvas.frame(minWidth: 430, maxWidth: .infinity).frame(height: 560)
                    recordingsCard.frame(width: 280, height: 560)
                }
                VStack(alignment: .leading, spacing: 18) {
                    mapCanvas.frame(height: 480)
                    recordingsCard.frame(height: 360)
                }
            }
            Text("La recherche de lieu utilise Apple Plans. Les trajectoires sont filtrées localement ; aucune position des logs n’est envoyée pour cette recherche.")
                .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.primary)
        .onAppear { if let proximity { radiusMeters = proximity.radiusMeters } }
        .onChange(of: search) { _, _ in places.clear() }
        .onChange(of: visibleLogs.map(\.id)) { _, ids in
            if let selectedLogID, !ids.contains(selectedLogID) { self.selectedLogID = nil }
        }
        .onChange(of: proximity) { _, value in
            if let value { radiusMeters = value.radiusMeters }
            else { search = ""; selectedPlaceName = "" }
            fitRequest = UUID()
        }
        .onDisappear { places.cancel() }
    }

    private var searchControls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Button { places.search(search) } label: { BentoIcon(symbol: "magnifyingglass", size: 17) }
                    .buttonStyle(.plain).foregroundStyle(palette.secondary)
                    .accessibilityLabel("Rechercher ce lieu").disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                TextField("Ville, adresse ou coordonnées…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12)).onSubmit { places.search(search) }
                    .accessibilityIdentifier("map.search")
                    .help("Exemple : Lyon, une adresse ou 45.76, 4.84. Validez avec Entrée puis choisissez un lieu.")
                if places.isSearching { ProgressView().controlSize(.small) }
                if !search.isEmpty || proximity != nil {
                    Button { search = ""; places.clear(); selectedPlaceName = ""; onProximityChange?(nil) } label: { BentoIcon(symbol: "xmark", size: 12) }
                        .buttonStyle(.plain).foregroundStyle(palette.secondary)
                        .accessibilityLabel("Effacer le lieu et le filtre géographique")
                }
            }
            .padding(.horizontal, 14).frame(height: 42)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border, lineWidth: 1))
            Menu {
                ForEach([500.0, 1_000, 2_000, 5_000, 10_000, 25_000, 50_000], id: \.self) { radius in
                    Button(MapPlaceSearchStore.radiusLabel(radius)) {
                        radiusMeters = radius
                        if let proximity {
                            onProximityChange?(.init(latitude: proximity.latitude, longitude: proximity.longitude, radiusMeters: radius))
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) { Text("Rayon \(MapPlaceSearchStore.radiusLabel(radiusMeters))"); BentoIcon(symbol: "chevron.down", size: 11) }
                    .font(.system(size: 12)).padding(.vertical, 10)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("map.radius")
        }
    }

    private var placeResults: some View {
        BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choisir un lieu").font(.caption).foregroundStyle(palette.secondary)
                ForEach(places.results) { place in
                    Button {
                        selectedPlaceName = place.title; search = place.title
                        onProximityChange?(.init(latitude: place.latitude, longitude: place.longitude, radiusMeters: radiusMeters))
                        places.clear(); fitRequest = UUID()
                    } label: {
                        HStack(spacing: 12) {
                            BentoIcon(symbol: "mappin.and.ellipse", size: 15)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.title).font(.system(size: 12, weight: .medium))
                                if !place.subtitle.isEmpty { Text(place.subtitle).font(.caption).foregroundStyle(palette.secondary) }
                            }
                            Spacer(); BentoIcon(symbol: "chevron.right", size: 11)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
                }
            }
        }
    }

    private var mapCanvas: some View {
        FlightTrackMap(logs: visibleLogs, fitRequest: fitRequest, proximity: proximity, onSelectLog: { log in
            selectedLogID = log.id
            onSelectLog(log)
        })
    }

    private var recordingsCard: some View {
        BentoPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(proximity == nil ? "Logs géolocalisés" : "\(resultCount) logs à proximité")
                            .font(.system(size: 15, weight: .semibold)).tracking(-0.25)
                        if isSearching { ProgressView().controlSize(.small) }
                    }
                    Text(proximity == nil ? "Positions enregistrées dans vos logs." : "Trajectoires passant dans un rayon de \(radiusLabel).")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    if proximity != nil && !selectedPlaceName.isEmpty {
                        Text(selectedPlaceName).font(.caption).foregroundStyle(palette.secondary).lineLimit(2)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleLogs) { log in recordingRow(log) }
                        if visibleLogs.isEmpty && !isSearching {
                            Text(proximity == nil ? "Aucune trajectoire disponible dans cette sélection." : "Aucune trajectoire exploitable ne passe dans cette zone. Essayez un rayon plus grand.")
                                .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 20)
                        }
                    }
                }
                Divider().overlay(palette.border)
                Text(proximity == nil ? "\(mappedCount) trajectoires affichées." : "Recherche dans toute la bibliothèque du client sélectionné.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                if resultCount > visibleLogs.count {
                    Text("\(visibleLogs.count) logs affichés sur \(resultCount). Resserrez le rayon ou les filtres pour voir les autres.")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Les logs sans trajectoire restent consultables dans l’historique.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                if let unavailable = proximityUnavailableLogs, unavailable > 0 {
                    Text("\(unavailable) logs non vérifiables : source ou trajectoire intégrale indisponible. Ils ne sont pas comptés comme étant hors zone.")
                        .font(.system(size: 10)).foregroundStyle(palette.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func recordingRow(_ log: FlightLog) -> some View {
        Button {
            selectedLogID = log.id
            onSelectLog(log)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(log.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    BentoIcon(symbol: "chevron.right", size: 11).foregroundStyle(palette.secondary)
                }
                Text(log.clientName ?? "Sans client").font(.system(size: 10)).foregroundStyle(palette.secondary)
                Text("\(FlightUIFormat.date(log.date)) · \(FlightUIFormat.duration(log.durationSeconds))")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(2)
                Text(log.fileName).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            .foregroundStyle(palette.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedLogID == log.id ? palette.raised : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).help("Ouvrir la fenêtre de \(log.fileName)")
        .accessibilityIdentifier("map.openFlight.\(log.id)")
    }
}

struct MapSearchPlace: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
}

@MainActor
final class MapPlaceSearchStore: ObservableObject {
    @Published private(set) var results: [MapSearchPlace] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    private var operation: MKLocalSearch?
    private var generation = UUID()

    static func coordinate(_ query: String) -> CLLocationCoordinate2D? {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]
        if cleaned.contains(";") { parts = cleaned.components(separatedBy: ";").map { $0.replacingOccurrences(of: ",", with: ".") } }
        else { parts = cleaned.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) }
        guard parts.count == 2,
              let latitude = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let longitude = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              latitude.isFinite, longitude.isFinite, abs(latitude) < 90, abs(longitude) <= 180 else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }
    static func radiusLabel(_ radius: Double) -> String {
        radius < 1_000 ? "\(Int(radius)) m" : "\(Int(radius / 1_000)) km"
    }
    func search(_ query: String) {
        cancel(); results = []; error = nil
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let point = Self.coordinate(query) {
            results = [.init(title: query, subtitle: "Coordonnées GPS", latitude: point.latitude, longitude: point.longitude)]
            return
        }
        let expected = generation
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        operation = search; isSearching = true
        // Older SDKs do not make MKLocalSearch.Response Sendable. Extract value
        // types inside the callback before handing the result to the main actor.
        let completion: @Sendable (MKLocalSearch.Response?, Error?) -> Void = { [weak self] response, error in
            let failed = error != nil || response == nil
            let places: [MapSearchPlace] = response?.mapItems.prefix(6).map {
                .init(title: $0.name ?? query, subtitle: $0.placemark.title ?? "",
                      latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude)
            } ?? []
            Task { @MainActor [weak self] in
                guard let self, expected == self.generation else { return }
                if failed {
                    self.error = "Lieu indisponible. Vérifiez le réseau ou saisissez directement des coordonnées GPS."
                } else {
                    self.results = places
                    if places.isEmpty { self.error = "Aucun lieu trouvé. Précisez la ville ou saisissez des coordonnées." }
                }
                self.isSearching = false; self.operation = nil
            }
        }
        search.start(completionHandler: completion)
    }
    func cancel() { generation = UUID(); operation?.cancel(); operation = nil; isSearching = false }
    func clear() { cancel(); results = []; error = nil }
}

/// Shared map used by the fleet view and the single-flight inspector.
/// Coordinates always come from the log; the map never requests the Mac's location.
struct FlightTrackMap: View {
    let logs: [FlightLog]
    var cursorTime: Double? = nil
    var cursorPosition: TrackPoint? = nil
    var fitRequest: UUID? = nil
    var proximity: GeographicProximity? = nil
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
                    if segments.isEmpty && proximity == nil {
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
        .onChange(of: proximity) { _, _ in fitTracks() }
        .onChange(of: dataIdentity) { _, _ in selectedAlertID = nil; fitTracks() }
        .onChange(of: filteredAlerts.map(\.id)) { _, ids in
            if let selectedAlertID, !ids.contains(selectedAlertID) { self.selectedAlertID = nil }
        }
        .onChange(of: alertFamily) { _, _ in selectedAlertID = nil }
        .onChange(of: alertLevel) { _, _ in selectedAlertID = nil }
        .onChange(of: showAlerts) { _, shown in if !shown { selectedAlertID = nil } }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                mapStyleButtons
                alertControls
                Spacer(minLength: 8)
                cameraButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { mapStyleButtons; Spacer(); alertControls }
                cameraButtons
            }
        }
    }

    private var alertControls: some View {
        Menu {
            Toggle("Afficher les alertes", isOn: $showAlerts)
            if showAlerts {
                Picker("Famille", selection: $alertFamily) {
                    Text("Toutes les familles").tag(String?.none)
                    ForEach(Set(allPositionedAlerts.map { $0.message.family }).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker("Niveau", selection: $alertLevel) {
                    Text("Tous les niveaux").tag("Tous")
                    Text("Avertissements et erreurs").tag("WARNING+")
                    Text("Erreurs").tag("ERROR+")
                }
            }
            Divider()
            Button("Recharger le fond de carte") { mapRefreshID = UUID() }
        } label: {
            BentoIcon(symbol: "line.3.horizontal.decrease", size: 15).padding(11)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .help("Affichage des alertes et options de carte").accessibilityLabel("Options de carte")
            .accessibilityIdentifier("map.options")
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
        .padding(3).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("map.style")
    }

    private var cameraButtons: some View {
        HStack(spacing: 8) {
            mapControl(symbol: "minus", label: "Dézoomer", identifier: "map.zoomOut") { zoomMap(factor: 1.7) }
            mapControl(symbol: "plus", label: "Zoomer", identifier: "map.zoomIn") { zoomMap(factor: 1 / 1.7) }
            mapControl(symbol: "scope", label: "Recentrer la carte", identifier: "map.fit", action: fitTracks)

        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(3).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func mapControl(symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { BentoIcon(symbol: symbol, size: 16).frame(width: 16) }
            .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
            .disabled(segments.isEmpty && proximity == nil).help(label).accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private var nativeMap: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
            if let proximity {
                MapCircle(center: CLLocationCoordinate2D(latitude: proximity.latitude, longitude: proximity.longitude), radius: proximity.radiusMeters)
                    .foregroundStyle(style.green.opacity(0.09))
                    .stroke(style.green.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                Annotation("Lieu recherché", coordinate: CLLocationCoordinate2D(latitude: proximity.latitude, longitude: proximity.longitude)) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 24)).foregroundStyle(style.green)
                }
            }
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
        if let proximity {
            let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: proximity.latitude, longitude: proximity.longitude),
                                            latitudinalMeters: proximity.radiusMeters * 2.5, longitudinalMeters: proximity.radiusMeters * 2.5)
            camera = .region(region)
            return
        }
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
    static func date(_ value: String) -> String {
        guard !value.isEmpty else { return "Date inconnue" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: value)
        if date == nil { parser.formatOptions = [.withInternetDateTime]; date = parser.date(from: value) }
        guard let date else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter.string(from: date)
    }
    static func duration(_ seconds: Double) -> String { String(format: "%.1f min", max(0, seconds) / 60) }
    static func seconds(_ seconds: Double) -> String { String(format: "%.3f s", seconds) }
    static func value(_ value: Double) -> String {
        if abs(value) >= 1000 { return String(format: "%.1f", value) }
        return String(format: "%.3f", value)
    }
}
