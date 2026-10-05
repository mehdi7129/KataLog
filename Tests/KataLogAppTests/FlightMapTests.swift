import XCTest
import MapKit
import SwiftUI
@testable import KataLog
@testable import KataLogCore

final class FlightMapTests: XCTestCase {
    func testTracksKeepRecordingGapsAsSeparatePolylines() throws {
        let log = try fixture(id: "gap", points: [
            point(time: 2, segment: 0), point(time: 0, segment: 0),
            point(time: 22, segment: 1), point(time: 20, segment: 1)
        ])
        let segments = FlightMapGeometry.segments([log])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].points.map(\.timeSeconds), [0, 2])
        XCTAssertEqual(segments[1].points.map(\.timeSeconds), [20, 22])
        XCTAssertNil(FlightMapGeometry.point(at: 10, in: try XCTUnwrap(log.track).points), "A cursor in a recording gap must not invent a GPS position.")
    }

    func testCursorUsesAnExistingSampleAndNeverInterpolates() throws {
        let points = [point(time: 0, latitude: 45), point(time: 10, latitude: 46)]
        let early = try XCTUnwrap(FlightMapGeometry.point(at: 3, in: points))
        let late = try XCTUnwrap(FlightMapGeometry.point(at: 8, in: points))
        XCTAssertEqual(early.timeSeconds, 0)
        XCTAssertEqual(early.latitude, 45)
        XCTAssertEqual(late.timeSeconds, 10)
        XCTAssertEqual(late.latitude, 46)
        XCTAssertNil(FlightMapGeometry.point(at: -1, in: points))
        XCTAssertNil(FlightMapGeometry.point(at: 11, in: points))
    }

    func testIsolatedPositionsRemainVisibleWithoutCreatingATrajectory() throws {
        let points = [point(time: 1, segment: 0), point(time: 40, segment: 1)]
        let log = try fixture(id: "isolated", points: points)
        let segments = FlightMapGeometry.segments([log])
        XCTAssertTrue(FlightMapGeometry.hasTrack(log))
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { $0.points.count == 1 }, "Single-point segments are displayed as points, not joined by a polyline.")
        XCTAssertNotNil(FlightMapGeometry.point(at: 1, in: points))
        XCTAssertNotNil(FlightMapGeometry.point(at: 40, in: points))
        XCTAssertNil(FlightMapGeometry.point(at: 20, in: points))
        let bounds = try XCTUnwrap(FlightMapGeometry.bounds([points[0]]))
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testInvalidCoordinatesCannotCreateMapContentOrBounds() throws {
        var invalidLongitude = point(time: 1)
        invalidLongitude.longitude = 181
        let invalid = [point(time: 0, latitude: .nan), point(time: .infinity), point(time: 2, latitude: 91), invalidLongitude]
        let log = try fixture(id: "invalid", points: invalid)
        XCTAssertFalse(FlightMapGeometry.hasTrack(log))
        XCTAssertTrue(FlightMapGeometry.segments([log]).isEmpty)
        XCTAssertNil(FlightMapGeometry.bounds(invalid))
        XCTAssertNil(FlightMapGeometry.point(at: 1, in: invalid))
    }

    func testMapGeometryNeverHidesOlderLocationsBehindARecencyLimit() throws {
        var logs = try (0..<84).map { index in
            try fixture(id: String(format: "%03d", index), date: String(format: "2026-09-29T%02d:%02d:00Z", index / 60, index % 60), points: [point(time: 0)])
        }
        let unlocated = try fixture(id: "unlocated", date: "2026-09-30T00:00:00Z", points: [])
        logs.insert(unlocated, at: 0)
        let displayed = FlightMapGeometry.displayedLogs(logs)
        XCTAssertEqual(displayed.count, 84)
        XCTAssertEqual(displayed.first?.id, "083")
        XCTAssertEqual(displayed.last?.id, "000")
        XCTAssertFalse(displayed.contains { $0.id == "unlocated" })
        XCTAssertTrue(displayed.contains { $0.id == "000" })
    }

    @MainActor
    func testLegacyOverviewKeepsOldEnglishLocationAndCountsLogsWithoutGPS() throws {
        var logs = try (0..<90).map { index in
            try fixture(id: "recent-\(index)", points: [point(time: 0), point(time: 1)])
        }
        var english = point(time: 0, latitude: 51.5)
        english.longitude = -0.12
        let old = try fixture(id: "old-england", date: "2025-12-15T00:00:00Z", points: [english])
        logs.append(old)
        logs.append(try fixture(id: "no-gps", points: []))
        var selected: String?
        let view = FleetMapView(logs: logs) { selected = $0.id }
        XCTAssertEqual(view.markers.count, 91)
        XCTAssertEqual(view.totalCount, 92)
        XCTAssertEqual(view.markers.last?.id, old.id)
        XCTAssertEqual(view.markers.last?.latitude, 51.5)
        XCTAssertFalse(view.markers.contains { $0.id == "no-gps" })
        view.onSelectLog(old.id)
        XCTAssertEqual(selected, old.id)
    }

    @MainActor
    func testNativeMapReceivesEveryMarkerAndSelectionOpensItsLog() async throws {
        _ = NSApplication.shared
        let markers = (0..<180).map { index in
            LibraryMapMarker(id: "synthetic-\(index)", droneName: "Synthetic", date: "2025-12-15", fileName: "synthetic.ulg", durationSeconds: 60,
                             latitude: 51.2 + Double(index % 4) * 0.1, longitude: -1 + Double(index % 3) * 0.1)
        }
        var opened: String?
        let host = NSHostingView(rootView: FleetMapView(markers: markers, onSelectLog: { opened = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        host.layoutSubtreeIfNeeded()
        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            for child in view.subviews { if let map = findMap(child) { return map } }
            return nil
        }
        func logAnnotations(_ map: MKMapView?) -> [any MKAnnotation] {
            (map?.annotations ?? []).filter { !($0 is MKClusterAnnotation) && !($0 is MKUserLocation) }
        }
        let deadline = Date().addingTimeInterval(3)
        while logAnnotations(findMap(host)).count != 180, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let map = try XCTUnwrap(findMap(host))
        XCTAssertEqual(logAnnotations(map).count, 180)
        let annotation = try XCTUnwrap(logAnnotations(map).first)
        let annotationView = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
        XCTAssertEqual(annotationView.clusteringIdentifier, "flight-locations")
        map.delegate?.mapView?(map, didSelect: annotationView)
        XCTAssertNotNil(opened)
        XCTAssertTrue(markers.contains { $0.id == opened })
        for marker in markers {
            XCTAssertTrue(map.visibleMapRect.contains(MKMapPoint(.init(latitude: marker.latitude, longitude: marker.longitude))))
        }
    }

    @MainActor
    func testCoincidentClusterListsEveryMemberWithoutOpeningAnArbitraryLog() async throws {
        _ = NSApplication.shared
        let markers = (0..<4).map { index in
            LibraryMapMarker(id: "cluster-\(index)", droneName: "Synthetic", date: "2026-01-01", fileName: "\(index).ulg", durationSeconds: 60,
                             latitude: index < 3 ? 51.5 : 48.9, longitude: index < 3 ? -0.12 : 2.3)
        }
        let presentation = FleetMapPresentationState()
        var opened: String?
        let host = NSHostingView(rootView: FleetMapView(markers: markers, scopeID: "client-a", presentation: presentation, onSelectLog: { opened = $0 }))
        let window = mapWindow(host)
        defer { window.close() }
        let map = try await waitForMap(host, count: markers.count)
        let members = map.annotations.filter { !($0 is MKClusterAnnotation) && $0.coordinate.latitude == 51.5 }
        XCTAssertEqual(members.count, 3)
        let cluster = MKClusterAnnotation(memberAnnotations: members)
        let clusterView = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: cluster))
        map.delegate?.mapView?(map, didSelect: clusterView)
        XCTAssertEqual(presentation.clusterLogIDs, Set(["cluster-0", "cluster-1", "cluster-2"]))
        XCTAssertEqual(presentation.listedMarkers(markers).map(\.id), ["cluster-0", "cluster-1", "cluster-2"])
        XCTAssertNil(opened, "Coincident positions must let the user choose which log to open.")
        XCTAssertEqual(map.annotations.filter { !($0 is MKClusterAnnotation) && !($0 is MKUserLocation) }.count, 4,
                       "Choosing a cluster filters only the list, never the complete map.")

        let member = try XCTUnwrap(members.first)
        let memberView = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: member))
        map.delegate?.mapView?(map, didSelect: memberView)
        let selectedID = try XCTUnwrap(presentation.selectedLogID)
        XCTAssertEqual(opened, selectedID)
        XCTAssertTrue(presentation.clusterLogIDs?.contains(selectedID) == true)

        presentation.showAllLocations()
        XCTAssertNil(presentation.clusterLogIDs)
        XCTAssertEqual(presentation.listedMarkers(markers).map(\.id), markers.map(\.id))
        XCTAssertEqual(map.annotations.filter { !($0 is MKClusterAnnotation) && !($0 is MKUserLocation) }.count, 4)

        // The new scope has the same IDs: ID-only invalidation would miss it.
        presentation.selectCluster(["cluster-0", "cluster-1"], availableIDs: Set(markers.map(\.id)))
        host.rootView = FleetMapView(markers: markers, scopeID: "client-b", presentation: presentation, onSelectLog: { opened = $0 })
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while presentation.clusterLogIDs != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(presentation.clusterLogIDs)
        XCTAssertNil(presentation.selectedLogID)
    }

    @MainActor
    func testClusterSelectionClearsWhenMembersDisappearAndIgnoresUnknownIDs() {
        let presentation = FleetMapPresentationState()
        presentation.reconcile(scopeID: "all", availableIDs: ["a", "b", "c"])
        presentation.selectCluster(["a", "b", "b", "unknown"], availableIDs: ["a", "b", "c"])
        XCTAssertEqual(presentation.clusterLogIDs, Set(["a", "b"]))
        presentation.selectLog("a")
        presentation.reconcile(scopeID: "all", availableIDs: ["a", "b", "c", "d"])
        XCTAssertEqual(presentation.clusterLogIDs, Set(["a", "b"]))
        presentation.reconcile(scopeID: "all", availableIDs: ["a", "c"])
        XCTAssertNil(presentation.clusterLogIDs, "An incomplete cluster must return to the full current list.")
        XCTAssertEqual(presentation.selectedLogID, "a")
        presentation.reconcile(scopeID: "all", availableIDs: ["c"])
        XCTAssertNil(presentation.selectedLogID)
        presentation.selectCluster(["unknown"], availableIDs: ["c"])
        XCTAssertNil(presentation.clusterLogIDs)
    }

    @MainActor
    func testMapViewportBelongsToItsScopeCoordinatesAndProximity() throws {
        let presentation = FleetMapPresentationState()
        let marker = LibraryMapMarker(id: "same-id", droneName: "Synthetic", date: "2026-01-01", fileName: "test.ulg", durationSeconds: 60,
                                      latitude: 51.5, longitude: -0.12)
        let key = FleetMapViewportKey(scopeID: "a", markers: [marker], proximity: nil)
        let rect = MKMapRect(x: 100, y: 200, width: 300, height: 400)
        presentation.rememberViewport(rect, for: key)
        let saved = try XCTUnwrap(presentation.viewport(for: key))
        XCTAssertEqual(saved.origin.x, rect.origin.x)
        XCTAssertEqual(saved.origin.y, rect.origin.y)
        XCTAssertEqual(saved.size.width, rect.size.width)
        XCTAssertEqual(saved.size.height, rect.size.height)
        XCTAssertNil(presentation.viewport(for: .init(scopeID: "b", markers: [marker], proximity: nil)))
        XCTAssertNil(presentation.viewport(for: .init(scopeID: "a", markers: [], proximity: nil)))
        XCTAssertNil(presentation.viewport(for: .init(scopeID: "a", markers: [marker], proximity: .init(latitude: 51.5, longitude: -0.12, radiusMeters: 500))))
        let moved = LibraryMapMarker(id: marker.id, droneName: marker.droneName, date: marker.date, fileName: marker.fileName, durationSeconds: marker.durationSeconds,
                                     latitude: 48.9, longitude: 2.3)
        XCTAssertNil(presentation.viewport(for: .init(scopeID: "a", markers: [moved], proximity: nil)))
        presentation.rememberViewport(.null, for: key)
        let preserved = try XCTUnwrap(presentation.viewport(for: key), "A disappearing native view must not replace the last valid camera with invalid bounds.")
        XCTAssertEqual(preserved.origin.x, rect.origin.x)
        XCTAssertEqual(preserved.origin.y, rect.origin.y)
        XCTAssertEqual(preserved.size.width, rect.size.width)
        XCTAssertEqual(preserved.size.height, rect.size.height)
    }

    @MainActor
    func testNativeMapRestoresCameraAndStyleWhenReturningToTab() async throws {
        _ = NSApplication.shared
        let markers = [
            LibraryMapMarker(id: "one", droneName: "Synthetic", date: "2026-01-01", fileName: "one.ulg", durationSeconds: 60, latitude: 51.5, longitude: -0.12),
            LibraryMapMarker(id: "two", droneName: "Synthetic", date: "2026-01-02", fileName: "two.ulg", durationSeconds: 60, latitude: 48.9, longitude: 2.3)
        ]
        let presentation = FleetMapPresentationState()
        presentation.satellite = true
        let firstHost = NSHostingView(rootView: FleetMapView(markers: markers, scopeID: "all", presentation: presentation, onSelectLog: { _ in }))
        let firstWindow = mapWindow(firstHost)
        defer { firstWindow.close() }
        let firstMap = try await waitForMap(firstHost, count: 2)
        XCTAssertEqual(firstMap.mapType, .satellite)
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12))
        firstMap.setVisibleMapRect(MKMapRect(x: center.x - 5_000, y: center.y - 5_000, width: 10_000, height: 10_000), animated: false)
        firstMap.delegate?.mapView?(firstMap, regionDidChangeAnimated: false)
        let expected = firstMap.visibleMapRect
        firstWindow.close()

        let returnedHost = NSHostingView(rootView: FleetMapView(markers: markers, scopeID: "all", presentation: presentation, onSelectLog: { _ in }))
        let returnedWindow = mapWindow(returnedHost)
        defer { returnedWindow.close() }
        let returnedMap = try await waitForMap(returnedHost, count: 2)
        XCTAssertEqual(returnedMap.mapType, .satellite)
        XCTAssertEqual(returnedMap.visibleMapRect.midX, expected.midX, accuracy: 10)
        XCTAssertEqual(returnedMap.visibleMapRect.midY, expected.midY, accuracy: 10)
        XCTAssertEqual(returnedMap.visibleMapRect.width, expected.width, accuracy: max(10, expected.width * 0.01))
    }

    @MainActor
    private func mapWindow(_ host: NSView) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func waitForMap(_ host: NSView, count: Int) async throws -> MKMapView {
        func find(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap(find).first
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let map = find(host), map.annotations.filter({ !($0 is MKClusterAnnotation) && !($0 is MKUserLocation) }).count == count { return map }
            try await Task.sleep(for: .milliseconds(20))
        }
        let map = try XCTUnwrap(find(host), "Native map should be installed in the view hierarchy.")
        XCTAssertEqual(map.annotations.filter { !($0 is MKClusterAnnotation) && !($0 is MKUserLocation) }.count, count)
        return map
    }

    private func point(time: Double, latitude: Double = 45, segment: Int = 0) -> TrackPoint {
        TrackPoint(timeSeconds: time, latitude: latitude, longitude: 4, altitudeMeters: 10, segment: segment)
    }

    private func fixture(id: String, date: String = "2026-09-29T00:00:00Z", points: [TrackPoint]) throws -> FlightLog {
        let fields: [String: Any] = [
            "id": id, "droneID": "synthetic-controller", "droneName": "Fixture", "date": date, "dateSource": "gps",
            "sourcePaths": [], "fileName": "\(id).ulg", "sizeBytes": 1, "durationSeconds": 60,
            "status": "ok", "issues": [], "metadata": ["parserVersion": "1.1.0"], "topics": [],
            "messages": [], "metrics": [], "coverage": [], "failsafeObserved": false
        ]
        var log = try JSONDecoder().decode(FlightLog.self, from: JSONSerialization.data(withJSONObject: fields))
        log.track = FlightTrack(source: "synthetic", originalPointCount: points.count, rejectedPointCount: 0, points: points)
        return log
    }
}
