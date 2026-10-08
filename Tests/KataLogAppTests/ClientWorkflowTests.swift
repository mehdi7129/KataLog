import Foundation
import XCTest
@testable import KataLog
import KataLogCore

@MainActor
final class ClientWorkflowTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-client-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func settle(_ library: LibraryStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while (library.isLoading || library.isQuerying || library.isMaintainingLibrary || library.clients.isLoading || library.hasExternalActivity()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(library.isLoading || library.isQuerying || library.isMaintainingLibrary || library.clients.isLoading || library.hasExternalActivity())
    }
    func testSettleWaitsForClientReconciliationAfterClearLibrary() async throws {
        let library = LibraryStore(storageDirectory: try directory(), engine: project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"))
        defer { library.prepareForTermination() }
        _ = try await library.clients.create(name: "Readiness fixture")
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        var reconciling = false
        library.hasExternalActivity = { reconciling }
        library.clientProfilesDidLoad = { _ in
            reconciling = true
            await withCheckedContinuation { release = $0 }
            reconciling = false
        }
        try await library.clearLibrary()
        let deadline = Date().addingTimeInterval(10)
        while (!reconciling || library.isLoading || library.isQuerying || library.isMaintainingLibrary), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(library.clients.isLoading)
        XCTAssertTrue(library.hasExternalActivity())
        let continuation = try XCTUnwrap(release)
        release = nil
        var settleReturned = false
        let releasing = Task { @MainActor in
            let wasWaiting = !settleReturned
            continuation.resume()
            return wasWaiting
        }
        try await settle(library)
        settleReturned = true
        let releasedWhileWaiting = await releasing.value
        XCTAssertTrue(releasedWhileWaiting, "The helper returned while client reconciliation was still held.")
        XCTAssertFalse(library.clients.isLoading || library.hasExternalActivity())
    }
    func testClientAttributionDuplicateBulkAssignmentAndBothResetsPreserveOriginals() async throws {
        let root = try directory(), card = root.appendingPathComponent("Card"), base = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let source = card.appendingPathComponent("synthetic.ulg")
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["KATALOG_TEST_PYTHON"])
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: python)
        fixture.arguments = ["-B", "-c", "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from fixture_ulog import synthetic_ulog;Path(sys.argv[2]).write_bytes(synthetic_ulog(samples=33))", project.appendingPathComponent("Tests").path, source.path]
        try fixture.run(); fixture.waitUntilExit(); XCTAssertEqual(fixture.terminationStatus, 0)
        let original = try Data(contentsOf: source)
        let library = LibraryStore(storageDirectory: base, engine: project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"))
        defer { library.prepareForTermination() }
        let first = try await library.clients.create(name: "Client Alpha")
        let second = try await library.clients.create(name: "Client Beta")
        let imported = try await library.importCollectedFolder(card, clientID: first.id)
        let id = try XCTUnwrap(imported.logs.first?.id)
        XCTAssertEqual(imported.logs.first?.clientID, first.id)
        let duplicate = try await library.importCollectedFolder(card, clientID: second.id)
        XCTAssertEqual(duplicate.logs.count, 1)
        XCTAssertEqual(duplicate.logs.first?.clientID, first.id, "A duplicate must not move to another client.")
        // An upgraded library has summaries but no complete spatial cache yet.
        let legacy = Process(); legacy.executableURL = URL(fileURLWithPath: python)
        legacy.arguments = ["-B", "-c", "import sqlite3,sys;db=sqlite3.connect(sys.argv[1]);db.execute('DELETE FROM spatial_tracks');db.commit();db.close()", base.appendingPathComponent("library.sqlite").path]
        try legacy.run(); legacy.waitUntilExit(); XCTAssertEqual(legacy.terminationStatus, 0)
        let area = GeographicProximity(latitude: 1, longitude: 2, radiusMeters: 1_000)
        library.loadMap(proximity: area); try await settle(library)
        XCTAssertNil(library.queryError)
        XCTAssertEqual(library.mapPage?.markers.map(\.id), [id])
        let offline = card.appendingPathComponent("synthetic.offline")
        try FileManager.default.moveItem(at: source, to: offline)
        defer { if FileManager.default.fileExists(atPath: offline.path) { try? FileManager.default.moveItem(at: offline, to: source) } }
        library.loadMap(proximity: area); try await settle(library)
        XCTAssertNil(library.queryError)
        XCTAssertEqual(library.mapPage?.markers.map(\.id), [id], "First search must persist complete tracks for later offline use.")
        try FileManager.default.moveItem(at: offline, to: source)
        try await library.clients.assign(logIDs: [id], to: second.id)
        try await settle(library)
        XCTAssertEqual(library.snapshot.logs.first?.clientID, second.id)
        try library.views.chooseClient(second.id)
        try library.views.setTheme("light")
        try library.annotations.setStockNumber("123", forKey: "ulog:synthetic-controller")
        let gcs = GCSStore(storageDirectory: base); gcs.attach(library: library)
        defer { gcs.stopForTermination() }
        let collected = base.appendingPathComponent("Collected Logs/preserved.ulg")
        try FileManager.default.createDirectory(at: collected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: collected)
        gcs.host = "synthetic-gcs.local"; gcs.chooseCollectionClient(second.id)
        let temporaryClient = try await library.clients.create(name: "Temporary client")
        let drone = "0102030405060708090A0B0C"
        gcs.setAllowed(uuid: drone, allowed: true)
        gcs.isQueuePaused = true
        _ = try await gcs.enqueue([.init(path: "/log/queued.ulg", size: 100)], uuid: drone,
            host: gcs.host, destination: gcs.downloadDirectory.path, clientID: temporaryClient.id)
        let queuedID = try XCTUnwrap(gcs.queue.first?.id)
        try await library.clients.remove(id: temporaryClient.id)
        try await settle(library)
        XCTAssertNil(gcs.queue.first?.clientID)
        let persisted = try GCSQueueRepository(url: base.appendingPathComponent("gcs-queue.sqlite"), readOnly: true)
        XCTAssertNil(try persisted.transfer(id: queuedID)?.clientID)
        try await library.clearLibrary(); try await settle(library)
        XCTAssertTrue(library.snapshot.logs.isEmpty)
        XCTAssertEqual(library.views.state.theme, "light")
        XCTAssertEqual(library.views.state.activeScope.clientID, second.id)
        XCTAssertEqual(library.annotations.state.stockNumbers["ulog:synthetic-controller"], "123")
        XCTAssertEqual(library.clients.profiles.count, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: collected), original)
        try await library.resetApplication(); try await settle(library)
        XCTAssertTrue(library.snapshot.logs.isEmpty)
        XCTAssertNil(library.views.state.theme)
        XCTAssertNil(library.views.state.activeScope.clientID)
        XCTAssertTrue(library.annotations.state.stockNumbers.isEmpty)
        XCTAssertEqual(gcs.host, "")
        XCTAssertTrue(gcs.queue.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: collected), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent(".library-writer.lock").path))
    }
    func testFullReportPreservesClientWhileRemovingOtherFilters() {
        var scope = SelectionScope(); scope.clientID = "CLIENT-A"; scope.search = "battery"; scope.logIDs = ["one"]
        let request = ReportPreviewStore.request(mode: .full, scope: scope, annotations: .init(), maskedMessageKeys: [], viewRevision: 0, options: .init())
        XCTAssertEqual(request.query.scope.clientID, "CLIENT-A")
        XCTAssertTrue(request.query.scope.logIDs.isEmpty)
        XCTAssertTrue(request.query.scope.search.isEmpty)
        XCTAssertTrue(request.query.scope.includeMasked)
    }
    func testCleanupNeverRecursesIntoUnexpectedConfigurationDirectory() throws {
        let root = try directory(), unexpected = root.appendingPathComponent("views.json")
        try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: true)
        let original = unexpected.appendingPathComponent("preserved.ulg")
        try Data("fixture".utf8).write(to: original)
        XCTAssertThrowsError(try LibraryStore.removeConfigurationFiles(in: root, names: ["views.json"]))
        XCTAssertEqual(try Data(contentsOf: original), Data("fixture".utf8))
        XCTAssertThrowsError(try LibraryStore.removeConfigurationFiles(in: root, names: ["../other.json"]))
    }
    func testQueuedClientIsDurableAndDoesNotFollowLaterChoice() async throws {
        let root = try directory(), drone = "0102030405060708090A0B0C"
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "synthetic-gcs.local"; state.allowedUUIDs = [drone]; state.autoImport = false
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-settings.json"))
        let gcs = GCSStore(storageDirectory: root); defer { gcs.stopForTermination() }
        _ = try await gcs.enqueue([.init(path: "/log/synthetic.ulg", size: 100)], uuid: drone,
            host: state.host, destination: root.path, clientID: "CLIENT-A")
        gcs.chooseCollectionClient("")
        XCTAssertEqual(gcs.queue.first?.clientID, "CLIENT-A")
        let decoded = try JSONDecoder().decode(GCSTransfer.self, from: JSONEncoder().encode(XCTUnwrap(gcs.queue.first)))
        XCTAssertEqual(decoded.clientID, "CLIENT-A")
    }
}
