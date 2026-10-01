import XCTest
import AppKit
import KataLogCore
@testable import KataLog

@MainActor
final class FlightDetailSessionTests: XCTestCase {
    private func log(_ id: String, name: String = "Synthetic") throws -> FlightLog {
        let fields: [String: Any] = ["id": id, "droneID": "test-controller", "droneName": name,
            "date": "2026-01-01", "dateSource": "gps", "sourcePaths": [], "fileName": id + ".ulg",
            "sizeBytes": 0, "durationSeconds": 60, "status": "ok", "issues": [], "metadata": [:],
            "topics": [], "messages": [], "metrics": [], "coverage": [], "failsafeObserved": false]
        return try JSONDecoder().decode(FlightLog.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func settle(_ session: FlightDetailSession) async throws {
        for _ in 0..<100 where session.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(session.isLoading)
    }

    func testTwoWindowsLoadIndependentlyAndClosingOneDoesNotCancelTheOther() async throws {
        var pending: CheckedContinuation<FlightLog, Error>?
        let first = FlightDetailSession(log: try log("first")) { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let second = FlightDetailSession(log: try log("second")) { [self] id in try log(id, name: "Second detail") }
        first.load(); second.load()
        try await settle(second)
        XCTAssertTrue(first.isLoading)
        XCTAssertEqual(second.log?.droneName, "Second detail")
        first.cancel()
        pending?.resume(returning: try log("first", name: "Too late"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(first.log?.droneName, "Synthetic")
        XCTAssertEqual(second.log?.id, "second")
        XCTAssertNil(second.error)
    }

    func testRetryCannotBeOverwrittenByAnEarlierResponse() async throws {
        var first: CheckedContinuation<FlightLog, Error>?
        var calls = 0
        let session = FlightDetailSession(log: try log("same")) { [self] id in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { first = $0 } }
            return try log(id, name: "Current")
        }
        session.load()
        for _ in 0..<100 where first == nil { await Task.yield() }
        XCTAssertNotNil(first)
        session.load(); try await settle(session)
        first?.resume(returning: try log("same", name: "Stale"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(session.log?.droneName, "Current")
    }

    func testFailurePreservesSummaryAndRetryClearsError() async throws {
        var attempt = 0
        let session = FlightDetailSession(log: try log("retry")) { [self] id in
            attempt += 1
            if attempt == 1 { throw AnalysisError.engine("Synthetic missing source") }
            return try log(id, name: "Restored")
        }
        session.load(); try await settle(session)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.log?.id, "retry")
        session.load(); try await settle(session)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.log?.droneName, "Restored")
    }

    func testWindowIdentityIncludesLibraryToKeepPreviewAndProductionSeparate() {
        let first = FlightWindowCoordinator.key(logID: "same-log", database: URL(fileURLWithPath: "/tmp/one/library.sqlite"))
        let second = FlightWindowCoordinator.key(logID: "same-log", database: URL(fileURLWithPath: "/tmp/two/library.sqlite"))
        XCTAssertNotEqual(first, second)
    }

    func testCachePublicationsAreSerializedAndMaintenanceRemainsBlockedUntilReadersDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-detail-queue-\(UUID().uuidString)")
        let library = LibraryStore(storageDirectory: root)
        defer { library.prepareForTermination(); try? FileManager.default.removeItem(at: root) }
        var first: CheckedContinuation<FlightLog, Error>?
        var entered: [String] = []
        let reader: FlightDetailLoader.Reader = { [self] id, readOnly in
            entered.append(id)
            XCTAssertFalse(readOnly)
            if id == "first" { return try await withCheckedThrowingContinuation { first = $0 } }
            return try log(id)
        }
        let a = Task { try await FlightDetailLoader.read(logID: "first", library: library, reader: reader) }
        for _ in 0..<100 where first == nil { await Task.yield() }
        XCTAssertNotNil(first)
        let b = Task { try await FlightDetailLoader.read(logID: "second", library: library, reader: reader) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(entered, ["first"])
        XCTAssertEqual(library.activeDetailLoads, 2)
        XCTAssertTrue(library.hasActiveWork)
        do { try await library.performMaintenance {}; XCTFail("Maintenance must not race a live detail publication") }
        catch {}
        b.cancel()
        first?.resume(returning: try log("first"))
        _ = try await a.value
        do { _ = try await b.value; XCTFail("Cancelled queued reader must not run") }
        catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        XCTAssertEqual(entered, ["first"])
        XCTAssertEqual(library.activeDetailLoads, 0)
    }

    func testNativeDetailPersistsEventsAndRemainsReadableAfterSourceIsMoved() async throws {
        guard let python = ProcessInfo.processInfo.environment["KATALOG_TEST_PYTHON"] else {
            throw XCTSkip("Set KATALOG_TEST_PYTHON and KATALOG_PYTHON to the fixture runtime.")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-window-cache-\(UUID().uuidString)")
        let card = root.appendingPathComponent("Card"), source = card.appendingPathComponent("synthetic.ulg")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: python)
        fixture.arguments = ["-B", "-c", "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from fixture_ulog import synthetic_ulog;Path(sys.argv[2]).write_bytes(synthetic_ulog(samples=33))", project.appendingPathComponent("Tests").path, source.path]
        try fixture.run(); fixture.waitUntilExit(); XCTAssertEqual(fixture.terminationStatus, 0)
        let engine = project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py")
        let library = LibraryStore(storageDirectory: root.appendingPathComponent("Library"), engine: engine)
        defer { library.prepareForTermination() }
        let imported = try await library.importCollectedFolder(card)
        let id = try XCTUnwrap(imported.logs.first?.id)
        let detail = try await FlightDetailLoader.read(logID: id, library: library)
        XCTAssertEqual(detail.events?.count, 1)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("offline-source.ulg"))
        let cached = try await FlightDetailLoader.read(logID: id, library: library)
        XCTAssertEqual(cached.events?.count, 1, "Opening a native window must retain the existing detail-cache contract")
        var request = LibraryQueryRequest(kind: "events")
        request.scope.logIDs = [id]
        request.scope.includeMasked = true
        let events = try await LibraryQueryService.page(LibraryEventPage.self, request: request,
            database: library.databaseURL, engine: engine, readOnly: true)
        XCTAssertEqual(events.total, 1, "Advanced events must be available after detail extraction")
        XCTAssertEqual(library.activeDetailLoads, 0)
    }

    func testNativeWindowsHaveStandardControlsReuseSameLogAndCloseIndependently() throws {
        guard ProcessInfo.processInfo.environment["KATALOG_TEST_NATIVE_WINDOWS"] == "1" else {
            throw XCTSkip("Set KATALOG_TEST_NATIVE_WINDOWS=1 in a GUI session to exercise native macOS windows.")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-window-test-\(UUID().uuidString)")
        let library = LibraryStore(storageDirectory: root)
        defer {
            FlightWindowCoordinator.shared.closeAll(library: library)
            library.prepareForTermination()
            try? FileManager.default.removeItem(at: root)
        }
        let first = try log("native-first"), second = try log("native-second")
        FlightWindowCoordinator.shared.open(log: first, library: library)
        let firstWindow = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "flight.window.native-first" })
        FlightWindowCoordinator.shared.open(log: second, library: library)
        let secondWindow = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "flight.window.native-second" })
        XCTAssertFalse(firstWindow === secondWindow)
        XCTAssertTrue(firstWindow.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertNotNil(firstWindow.standardWindowButton(.closeButton))
        XCTAssertNotNil(firstWindow.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(firstWindow.standardWindowButton(.zoomButton))
        try library.views.setTheme("light")
        XCTAssertEqual(firstWindow.appearance?.name, .aqua)
        XCTAssertEqual(secondWindow.appearance?.name, .aqua)
        try library.views.setTheme("dark")
        XCTAssertEqual(firstWindow.appearance?.name, .darkAqua)
        XCTAssertEqual(secondWindow.appearance?.name, .darkAqua)
        try library.views.setTheme("system")
        XCTAssertNil(firstWindow.appearance)
        XCTAssertNil(secondWindow.appearance)
        FlightWindowCoordinator.shared.open(log: first, library: library)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "flight.window.native-first" }.count, 1)
        let frame = NSRect(x: firstWindow.frame.minX + 20, y: firstWindow.frame.minY + 20, width: 900, height: 700)
        firstWindow.setFrame(frame, display: false)
        XCTAssertEqual(firstWindow.frame.size, frame.size)
        firstWindow.performClose(nil)
        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertTrue(secondWindow.isVisible)
    }

    func testGeographicSearchParsesCoordinatesLocallyAndRejectsInvalidValues() throws {
        let decimal = try XCTUnwrap(MapPlaceSearchStore.coordinate("45.76, 4.84"))
        XCTAssertEqual(decimal.latitude, 45.76); XCTAssertEqual(decimal.longitude, 4.84)
        let french = try XCTUnwrap(MapPlaceSearchStore.coordinate("45,76 ; 4,84"))
        XCTAssertEqual(french.latitude, decimal.latitude); XCTAssertEqual(french.longitude, decimal.longitude)
        XCTAssertNotNil(MapPlaceSearchStore.coordinate("-23.5 -46.6"))
        for invalid in ["Lyon", "91, 4", "45, 181", "nan, 4", "inf, 4", "45, 4, 2", ""] {
            XCTAssertNil(MapPlaceSearchStore.coordinate(invalid), invalid)
        }
        let search = MapPlaceSearchStore()
        search.search("45.76, 4.84")
        XCTAssertEqual(search.results.count, 1)
        XCTAssertFalse(search.isSearching)
        search.clear()
        XCTAssertTrue(search.results.isEmpty)
    }
}
