import XCTest
import AppKit
import SwiftUI
import KataLogCore
@testable import KataLog

@MainActor
final class AppFlightStudyStoreTests: XCTestCase {
    private func response(_ logID: String, count: Int = 0) throws -> TelemetryResponse {
        try JSONDecoder().decode(TelemetryResponse.self, from: Data("""
        {"seriesVersion":1,"logID":"\(logID)","series":[],"missingFields":[],"pointBudget":2048,"displayedPointCount":\(count)}
        """.utf8))
    }

    private func settle(_ store: FlightStudyStore, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isLoading, "Injected fixture reader did not settle in time.")
    }

    func testCacheIsPerLogAndCompleteWindowRequest() async throws {
        var calls: [String] = []
        let store = FlightStudyStore { [self] id, request in
            calls.append(id + request.fingerprint); return try response(id)
        }
        let request = TelemetryRequest()
        store.load(logID: "fixture-a", request: request); try await settle(store)
        store.load(logID: "fixture-a", request: request); try await settle(store)
        XCTAssertEqual(calls.count, 1)
        var window = request; window.timeFrom = 1; window.timeTo = 2
        store.load(logID: "fixture-a", request: window); try await settle(store)
        store.load(logID: "fixture-b", request: request); try await settle(store)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(store.response?.logID, "fixture-b")
    }

    func testLateResultCannotReplaceNewerSelectionEvenIfReaderIgnoresCancellation() async throws {
        var first: CheckedContinuation<TelemetryResponse, Error>?
        let store = FlightStudyStore { [self] id, _ in
            if id == "slow" { return try await withCheckedThrowingContinuation { first = $0 } }
            return try response(id)
        }
        store.load(logID: "slow", request: TelemetryRequest())
        for _ in 0..<100 where first == nil { await Task.yield() }
        XCTAssertNotNil(first)
        store.load(logID: "current", request: TelemetryRequest()); try await settle(store)
        first?.resume(returning: try response("slow"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.response?.logID, "current")
        XCTAssertNil(store.errorMessage)
    }

    func testCancelClearsLoadingAndPreventsLatePublication() async throws {
        var pending: CheckedContinuation<TelemetryResponse, Error>?
        let store = FlightStudyStore { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        store.load(logID: "cancelled", request: TelemetryRequest())
        for _ in 0..<100 where pending == nil { await Task.yield() }
        store.cancel()
        XCTAssertFalse(store.isLoading)
        pending?.resume(returning: try response("cancelled"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(store.response)
        XCTAssertNil(store.errorMessage)
    }

    func testErrorThenRetryDoesNotKeepStaleState() async throws {
        var attempts = 0
        let store = FlightStudyStore { [self] id, _ in
            attempts += 1
            if attempts == 1 { throw AnalysisError.engine("Source absente · fixture") }
            return try response(id)
        }
        store.load(logID: "retry", request: TelemetryRequest()); try await settle(store)
        XCTAssertTrue(store.errorMessage?.contains("Source absente") == true)
        XCTAssertNil(store.response)
        store.load(logID: "retry", request: TelemetryRequest()); try await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.response?.logID, "retry")
    }

    func testSharedTimeSurvivesRecipeChangeButNotAnotherLogOrReset() async throws {
        let store = FlightStudyStore { [self] id, _ in try response(id) }
        store.load(logID: "a", request: TelemetryRequest()); try await settle(store)
        store.selectedTime = 8
        store.load(logID: "a", request: TelemetryRequest(recipe: "gnss")); try await settle(store)
        XCTAssertEqual(store.selectedTime, 8)
        store.load(logID: "b", request: TelemetryRequest()); try await settle(store)
        XCTAssertNil(store.selectedTime)
        store.selectedTime = 2; store.reset()
        XCTAssertNil(store.selectedTime); XCTAssertNil(store.response); XCTAssertFalse(store.isLoading)
    }

    func testCacheKeepsMostRecentlyUsedTwelveQueries() async throws {
        var calls = 0
        let store = FlightStudyStore { [self] id, _ in calls += 1; return try response(id) }
        for number in 0..<12 { store.load(logID: "log-\(number)", request: TelemetryRequest()); try await settle(store) }
        store.load(logID: "log-0", request: TelemetryRequest()); try await settle(store)
        store.load(logID: "log-12", request: TelemetryRequest()); try await settle(store)
        store.load(logID: "log-0", request: TelemetryRequest()); try await settle(store)
        XCTAssertEqual(calls, 13)
        store.load(logID: "log-1", request: TelemetryRequest()); try await settle(store)
        XCTAssertEqual(calls, 14, "Least recently used query must be evicted, not the recently revisited query.")
    }

    func testWindowInputAcceptsFrenchDecimalAndRejectsNonfiniteOrReversedRange() throws {
        let window = try FlightStudyPresentation.window(from: " 1,25 ", to: "2.5")
        XCTAssertEqual(window.0, 1.25); XCTAssertEqual(window.1, 2.5)
        XCTAssertNil(try FlightStudyPresentation.window(from: "", to: " ").0)
        XCTAssertThrowsError(try FlightStudyPresentation.window(from: "nan", to: "3"))
        XCTAssertThrowsError(try FlightStudyPresentation.window(from: "1", to: "inf"))
        XCTAssertThrowsError(try FlightStudyPresentation.window(from: "3", to: "2"))
        XCTAssertThrowsError(try FlightStudyPresentation.window(from: "invalid", to: ""))
    }

    func testSingletonTimeDomainRemainsUsableAndCoverageExplainsOmission() throws {
        let curve = try JSONDecoder().decode(TelemetrySeries.self, from: Data(#"{"key":"field","label":"Champ","unit":"unknown","source":"topic.field","originalSampleCount":4,"points":[{"timeSeconds":2,"value":7,"segment":3}],"completeWindow":false,"omittedSegmentCount":2,"omittedTransitionCount":1,"omittedExtremaCount":4}"#.utf8))
        let domain = FlightStudyPresentation.timeDomain([curve])
        XCTAssertTrue(domain.contains(2)); XCTAssertLessThan(domain.lowerBound, domain.upperBound)
        let values = FlightStudyPresentation.valueDomain(curve)
        XCTAssertTrue(values.contains(7)); XCTAssertLessThan(values.lowerBound, values.upperBound)
        let coverage = FlightStudyPresentation.coverage(curve)
        XCTAssertTrue(coverage.contains("2 segments")); XCTAssertTrue(coverage.contains("1 transitions")); XCTAssertTrue(coverage.contains("4 extrema"))
        XCTAssertEqual(FlightStudyPresentation.timeDomain([]), 0...1)
    }

    func testIdenticalInFlightQueryIsNotRestarted() async throws {
        var calls = 0
        var pending: CheckedContinuation<TelemetryResponse, Error>?
        let store = FlightStudyStore { _, _ in calls += 1; return try await withCheckedThrowingContinuation { pending = $0 } }
        store.load(logID: "same", request: TelemetryRequest())
        for _ in 0..<100 where pending == nil { await Task.yield() }
        store.load(logID: "same", request: TelemetryRequest())
        XCTAssertEqual(calls, 1)
        pending?.resume(returning: try response("same")); try await settle(store)
        XCTAssertEqual(store.response?.logID, "same")
    }

    func testPreferencesRestoreAcrossStoresAndAreKeyedByParserAndLog() async throws {
        var saved: [String: TelemetryRequest] = [:]
        var request = TelemetryRequest(recipe: "gnss", instance: 1); request.timeFrom = 1.25; request.timeTo = 20
        let first = FlightStudyStore(savedRequest: { saved[$0] }, saveRequest: { saved[$0] = $1 }) { [self] id, _ in try response(id) }
        first.load(logID: "sha-a", request: request); try await settle(first)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[AnalysisService.parserVersion + ":sha-a"], request)
        let second = FlightStudyStore(savedRequest: { saved[$0] }) { [self] id, _ in try response(id) }
        XCTAssertEqual(second.lastRequest(logID: "sha-a"), request)
        XCTAssertNil(second.lastRequest(logID: "sha-b"))
        saved["old-parser:sha-b"] = request
        XCTAssertNil(second.lastRequest(logID: "sha-b"))
    }

    func testInvalidSavedRequestAndSaveFailureRemainExplicitWithoutPreventingReading() async throws {
        var invalid = TelemetryRequest(); invalid.budget = 3000
        let store = FlightStudyStore(savedRequest: { _ in invalid }, saveRequest: { _, _ in throw AnalysisError.engine("Lecture seule") }) { [self] id, _ in try response(id) }
        XCTAssertNil(store.lastRequest(logID: "fixture"))
        XCTAssertNotNil(store.preferenceWarning)
        store.load(logID: "fixture", request: TelemetryRequest()); try await settle(store)
        XCTAssertEqual(store.response?.logID, "fixture")
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.preferenceWarning?.contains("non enregistrée") == true)
        store.load(logID: "fixture", request: invalid)
        XCTAssertFalse(store.isLoading); XCTAssertNotNil(store.errorMessage); XCTAssertNil(store.response)
    }

    func testNewWindowClearsCursorOutsideItsBounds() async throws {
        let store = FlightStudyStore { [self] id, _ in try response(id) }
        store.load(logID: "same", request: TelemetryRequest()); try await settle(store); store.selectedTime = 50
        var request = TelemetryRequest(); request.timeFrom = 2; request.timeTo = 5
        store.load(logID: "same", request: request); try await settle(store)
        XCTAssertNil(store.selectedTime)
    }

    func testSelectedSampleNeverBridgesGapsOrExtrapolates() throws {
        let curve = try JSONDecoder().decode(TelemetrySeries.self, from: Data(#"{"key":"field","label":"Champ","unit":"unknown","source":"topic.field","originalSampleCount":4,"points":[{"timeSeconds":0,"value":7,"segment":0},{"timeSeconds":2,"value":8,"segment":0},{"timeSeconds":8,"value":9,"segment":1},{"timeSeconds":10,"value":10,"segment":1}]}"#.utf8))
        XCTAssertNotNil(FlightStudyPresentation.sample(at: 1, in: curve))
        XCTAssertNil(FlightStudyPresentation.sample(at: 5, in: curve))
        XCTAssertNil(FlightStudyPresentation.sample(at: -0.01, in: curve))
        XCTAssertNil(FlightStudyPresentation.sample(at: 10.01, in: curve))
        XCTAssertNil(FlightStudyPresentation.sample(at: .nan, in: curve))
        XCTAssertTrue(FlightStudyPresentation.coverage(curve).contains("non renseignée"))
        var partial = curve; partial.completeWindow = false; partial.longGapCount = 1
        XCTAssertTrue(FlightStudyPresentation.coverage(partial).contains("1 longues lacunes"))
        XCTAssertFalse(FlightStudyPresentation.coverage(partial).contains("Budget de dessin"), "A real source gap is not a point-budget omission.")
    }

    func testEventTimeSelectsSharedCursorWithoutInventingMissingOrInvalidTimestamp() throws {
        var event = try JSONDecoder().decode(PX4Event.self, from: Data(#"{"id":"event:0:1","eventID":42,"timeSeconds":2.5,"level":"WARNING","argumentsHex":"00"}"#.utf8))
        let store = FlightStudyStore { [self] id, _ in try response(id) }
        store.selectedTime = FlightStudyPresentation.eventTime(event)
        XCTAssertEqual(store.selectedTime, 2.5)
        event.timeSeconds = nil; XCTAssertNil(FlightStudyPresentation.eventTime(event))
        event.timeSeconds = .nan; XCTAssertNil(FlightStudyPresentation.eventTime(event))
        event.timeSeconds = .infinity; XCTAssertNil(FlightStudyPresentation.eventTime(event))
        event.timeSeconds = -1; XCTAssertNil(FlightStudyPresentation.eventTime(event))
        event.timeSeconds = 0; XCTAssertEqual(FlightStudyPresentation.eventTime(event), 0)
    }

    func testAnonymousNativePreviewRendersInBothThemesAndNarrowWindow() async throws {
        _ = NSApplication.shared
        let log = try JSONDecoder().decode(FlightLog.self, from: Data(#"{"id":"synthetic-preview","droneID":"DEMO-A","droneName":"DEMO-A","date":"2026-01-01","dateSource":"fixture","sourcePaths":[],"fileName":"log_demo.ulg","sizeBytes":100,"durationSeconds":120,"status":"ok","issues":[],"metadata":{},"topics":[],"messages":[],"metrics":[],"coverage":[],"failsafeObserved":false}"#.utf8))
        let payload = #"{"seriesVersion":1,"logID":"synthetic-preview","series":[{"key":"battery","label":"Tension batterie","unit":"V","source":"battery_status.voltage_v","instance":0,"originalSampleCount":6,"validSampleCount":6,"completeWindow":true,"points":[{"timeSeconds":0,"value":16,"segment":0},{"timeSeconds":2,"value":15.8,"segment":0},{"timeSeconds":4,"value":15.7,"segment":0},{"timeSeconds":90,"value":15.5,"segment":1},{"timeSeconds":100,"value":15.4,"segment":1},{"timeSeconds":120,"value":15.2,"segment":1}]},{"key":"gnss","label":"Précision horizontale GNSS","unit":"m","source":"sensor_gps.eph","instance":1,"originalSampleCount":2,"validSampleCount":2,"completeWindow":true,"points":[{"timeSeconds":0,"value":0.4,"segment":0},{"timeSeconds":120,"value":0.5,"segment":0}]}],"missingFields":["battery_status[0].current_a absent"],"pointBudget":2048,"displayedPointCount":8}"#
        let result = try JSONDecoder().decode(TelemetryResponse.self, from: Data(payload.utf8))
        for (name, width, scheme) in [("dark-wide", 1100.0, ColorScheme.dark), ("light-wide", 1100.0, ColorScheme.light), ("dark-narrow", 620.0, ColorScheme.dark)] {
            let store = FlightStudyStore(initialResponse: result) { _, _ in result }
            let view = NSHostingView(rootView: FlightAnalysisView(log: log, study: store).environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            defer { window.close(); store.cancel() }
            for _ in 0..<4 { await Task.yield() }
            try await settle(store)
            store.selectedTime = 2
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5_000, "Preview should render its native content, not an empty bitmap.")
            if let directory = ProcessInfo.processInfo.environment["KATALOG_UI_ARTIFACTS"] {
                let folder = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("analysis-\(name).png"))
            }
        }
    }

    func testStudyExportKeepsExactPointsWindowProvenanceAndOriginalSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-study-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.ulg"), originalBytes = Data([0, 7, 13, 255])
        try originalBytes.write(to: original)
        var log = try JSONDecoder().decode(FlightLog.self, from: Data(#"{"id":"study-log","droneID":"DEMO-A","droneName":"DEMO-A","date":"2026-01-01","dateSource":"fixture","sourcePaths":[],"fileName":"log_demo.ulg","sizeBytes":4,"durationSeconds":20,"status":"ok","issues":[],"metadata":{},"topics":[],"messages":[],"metrics":[],"coverage":[],"failsafeObserved":false}"#.utf8))
        log.sourcePaths = [original.path]; log.fileName = "<script>⚠️ & relevé.ulg"
        let result = try JSONDecoder().decode(TelemetryResponse.self, from: Data(#"{"seriesVersion":1,"logID":"study-log","series":[{"key":"state","label":"État <script>","unit":"unknown","source":"topic.field","instance":1,"originalSampleCount":10,"validSampleCount":4,"completeWindow":false,"longGapCount":1,"interpolation":"step","points":[{"timeSeconds":1,"value":0,"segment":0},{"timeSeconds":2,"value":1,"segment":0},{"timeSeconds":15,"value":1,"segment":1},{"timeSeconds":16,"value":0,"segment":1}]}],"missingFields":["autre champ absent"],"pointBudget":2048,"displayedPointCount":4}"#.utf8))
        var request = TelemetryRequest(recipe: "gnss", instance: 1); request.timeFrom = 1; request.timeTo = 16
        let store = FlightStudyStore { _, _ in result }
        store.load(logID: log.id, request: request); try await settle(store)
        let json = root.appendingPathComponent("releve.json"), html = root.appendingPathComponent("releve.html")
        try await store.export(log: log, to: json, html: false)
        try await store.export(log: log, to: html, html: true)
        let exported = try JSONDecoder().decode(FleetSnapshot.self, from: Data(contentsOf: json))
        let curve = try XCTUnwrap(exported.logs.first?.telemetry?.first)
        XCTAssertEqual(curve.points.map(\.timeSeconds), result.series[0].points.map(\.timeSeconds))
        XCTAssertEqual(curve.points.map(\.value), result.series[0].points.map(\.value))
        XCTAssertEqual(curve.points.map(\.segment), [0, 0, 1, 1])
        let provenance = try XCTUnwrap(exported.logs[0].metadataDetails?["telemetryReport"])
        XCTAssertEqual(provenance["originalULogIncluded"], .bool(false))
        XCTAssertEqual(provenance["request"]?["timeFrom"], .integer(1))
        XCTAssertEqual(provenance["request"]?["timeTo"], .integer(16))
        XCTAssertEqual(provenance["request"]?["instance"], .integer(1))
        let content = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(content.contains("data-telemetry-segment=\"0\"")); XCTAssertTrue(content.contains("data-telemetry-segment=\"1\""))
        XCTAssertTrue(content.contains("H")); XCTAssertTrue(content.contains("État &lt;script&gt;"))
        XCTAssertFalse(content.contains("<script>⚠️"))
        XCTAssertTrue(content.contains("originaux restent dans le fichier ULog"))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertFalse(store.isExporting)
    }

    func testRecipeInstancesExcludeTimestampsAndUnrelatedFields() throws {
        let fields = try JSONDecoder().decode([TelemetryField].self, from: Data(#"[{"key":"a","topic":"sensor_gps","instance":0,"field":"timestamp","type":"uint64_t","sampleCount":5,"numeric":true,"extractable":true,"rawUnit":"us","unit":"us","scale":1,"unitStatus":"known","interpolation":"linear"},{"key":"b","topic":"sensor_gps","instance":1,"field":"eph","type":"float","sampleCount":5,"numeric":true,"extractable":true,"rawUnit":"m","unit":"m","scale":1,"unitStatus":"known","interpolation":"linear"}]"#.utf8))
        XCTAssertEqual(FlightStudyPresentation.recipeFields("gnss", catalogue: fields).map(\.instance), [1])
        XCTAssertTrue(FlightStudyPresentation.recipeFields("battery", catalogue: fields).isEmpty)
    }
}
