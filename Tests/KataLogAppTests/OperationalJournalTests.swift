import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class OperationalJournalTests: XCTestCase {
    private func root() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-operational-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var state = GCSCollectionState(downloadDirectory: folder.appendingPathComponent("A").path)
        state.reconnect = false
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("gcs-settings.json"))
        return folder
    }

    func testRealStoreActionsRecordLifecycleDestinationAndStopWithoutPrivatePaths() throws {
        let root = try root(), library = LibraryStore(storageDirectory: root)
        let gcs = GCSStore(storageDirectory: root); gcs.attach(library: library)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        gcs.pauseQueue(); gcs.stopCollection()
        try gcs.setDownloadDirectory(root.appendingPathComponent("B"))
        library.prepareForTermination()
        let capture = try library.diagnostics.snapshot()
        XCTAssertEqual(capture.events.first?.kind, .appStarted)
        for kind: DiagnosticEvent.Kind in [.collectionPaused, .collectionStopped, .destinationChanged, .appStopped] {
            XCTAssertTrue(capture.events.contains { $0.kind == kind }, "Missing \(kind)")
        }
        XCTAssertFalse(String(decoding: try capture.jsonLines(), as: UTF8.self).contains(root.path))
        XCTAssertEqual(capture.events.filter { $0.kind == .appStopped }.count, 1)
        library.prepareForTermination()
        XCTAssertEqual(try library.diagnostics.snapshot().events.filter { $0.kind == .appStopped }.count, 1)
    }

    func testReportExportSuccessAndFailureAreJournalledWithoutFreeText() async throws {
        let root = try root(), library = LibraryStore(storageDirectory: root)
        defer { library.prepareForTermination() }
        try await library.export(to: root.appendingPathComponent("report.json"), html: false, selection: .empty)
        do {
            try await library.export(to: root.appendingPathComponent("missing/report.json"), html: false, selection: .empty)
            XCTFail("Export to missing directory succeeded")
        } catch { /* Expected failure; the journal keeps a code, not its path. */ }
        let capture = try library.diagnostics.snapshot()
        XCTAssertEqual(capture.events.filter { $0.kind == .exportStarted }.count, 2)
        XCTAssertEqual(capture.events.filter { $0.kind == .exportCompleted }.count, 1)
        XCTAssertTrue(capture.events.contains { $0.kind == .exportFailed && $0.code == .exportFailed })
        XCTAssertFalse(String(decoding: try capture.jsonLines(), as: UTF8.self).contains(root.path))
    }

    func testSecondInstanceDoesNotWriteToPersistentJournal() throws {
        let root = try root(), first = LibraryStore(storageDirectory: root)
        defer { first.prepareForTermination() }
        let before = try first.diagnostics.snapshot().jsonLines()
        let second = LibraryStore(storageDirectory: root)
        XCTAssertTrue(second.isReadOnly); XCTAssertFalse(second.diagnostics.configuration.persistent)
        second.prepareForTermination()
        _ = try second.diagnostics.snapshot()
        XCTAssertEqual(try first.diagnostics.snapshot().jsonLines(), before)
    }
}
