import Foundation
import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class ResetReconciliationTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private struct CleanupFailure: LocalizedError { var errorDescription: String? { "synthetic collection reset failure" } }
    private struct Fixture { let library: LibraryStore; let source: URL; let client: ClientProfile; let original: Data }

    private func settle(_ library: LibraryStore) async throws {
        try await Task.sleep(for: .milliseconds(20))
        let deadline = Date().addingTimeInterval(15)
        while library.isLoading || library.isQuerying || library.isMaintainingLibrary || library.clients.isLoading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(library.isLoading || library.isQuerying || library.isMaintainingLibrary || library.clients.isLoading)
    }
    private func fixture(paged: Bool) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-reset-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ulg")
        let process = Process(); process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["KATALOG_TEST_PYTHON"]))
        process.arguments = ["-B", "-c", "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from fixture_ulog import synthetic_ulog;Path(sys.argv[2]).write_bytes(synthetic_ulog(samples=3))", project.appendingPathComponent("Tests").path, source.path]
        try process.run(); ProcessLifetime.wait(for: process); XCTAssertEqual(process.terminationStatus, 0)
        let library = LibraryStore(storageDirectory: root.appendingPathComponent("Library"), engine: project.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"), pagedNavigation: paged)
        try await settle(library)
        let client = try await library.clients.create(name: "Reset fixture client")
        _ = try await library.importCollectedFolder(source, clientID: client.id)
        try await settle(library)
        try library.views.chooseClient(client.id)
        library.loadHistory(); try await settle(library)
        XCTAssertEqual(library.snapshot.logs.count, 1)
        XCTAssertTrue(library.historyResultsCurrent)
        return Fixture(library: library, source: source, client: client, original: try Data(contentsOf: source))
    }
    private func obstacle(_ url: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("preserved"))
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let original = url.appendingPathComponent("preserved.ulg")
        try Data("unexpected directory source".utf8).write(to: original)
        return original
    }
    private func assertDatabaseCount(_ expected: Int, _ library: LibraryStore) async throws {
        let snapshot = try await AnalysisService.snapshot(database: library.databaseURL, engine: try XCTUnwrap(library.engineURL), readOnly: true)
        XCTAssertEqual(snapshot.logs.count, expected)
    }

    func testKnownConfigurationDirectoriesRefuseBeforeDatabaseReset() async throws {
        for paged in [false, true] {
            for collection in [false, true] {
                let value = try await fixture(paged: paged), library = value.library
                let gcs = GCSStore(storageDirectory: library.storageDirectory)
                defer { gcs.stopForTermination(); library.prepareForTermination() }
                gcs.attach(library: library); try await settle(library)
                let preserved = try obstacle(library.storageDirectory.appendingPathComponent(collection ? "gcs-collection.json" : "views.json"))
                let generation = library.resetGeneration
                do { try await library.resetApplication(); XCTFail("Unexpected configuration directory must refuse reset") } catch {}
                XCTAssertEqual(library.resetGeneration, generation)
                try await settle(library)
                try await assertDatabaseCount(1, library)
                XCTAssertEqual(library.snapshot.logs.count, 1)
                XCTAssertEqual(library.clients.profiles.map(\.id), [value.client.id])
                XCTAssertEqual(try Data(contentsOf: value.source), value.original)
                XCTAssertEqual(try Data(contentsOf: preserved), Data("unexpected directory source".utf8))
            }
        }
    }

    func testCommittedResetReconcilesStateWhenCollectionCleanupFails() async throws {
        for paged in [false, true] {
            let value = try await fixture(paged: paged), library = value.library
            defer { library.prepareForTermination() }
            library.resetCollectionState = { throw CleanupFailure() }
            let generation = library.resetGeneration
            do { try await library.resetApplication(); XCTFail("Expected partial reset") }
            catch { XCTAssertTrue(error.localizedDescription.contains("réinitialisé"), error.localizedDescription) }
            XCTAssertEqual(library.resetGeneration, generation + 1)
            XCTAssertTrue(library.snapshot.logs.isEmpty)
            XCTAssertFalse(library.historyResultsCurrent)
            XCTAssertTrue(library.clients.profiles.isEmpty)
            try await settle(library)
            try await assertDatabaseCount(0, library)
            XCTAssertTrue(library.snapshot.logs.isEmpty)
            XCTAssertTrue(library.clients.profiles.isEmpty)
            XCTAssertNil(library.views.state.activeScope.clientID)
            XCTAssertTrue(library.errorMessage?.contains("synthetic collection reset failure") == true)
            XCTAssertTrue(library.statusMessage?.contains("conservés") == true)
            library.loadHistory(); try await settle(library)
            XCTAssertTrue(library.historyPage?.snapshot.logs.isEmpty == true)
            XCTAssertTrue(library.historyResultsCurrent)
            XCTAssertEqual(try Data(contentsOf: value.source), value.original)
            library.resetCollectionState = {}
            try await library.resetApplication(); try await settle(library)
            XCTAssertEqual(library.resetGeneration, generation + 2)
            XCTAssertNil(library.errorMessage)
        }
    }

    func testConfigurationObstacleAppearingAfterCommitIsPreservedAndStateReloaded() async throws {
        for paged in [false, true] {
            let value = try await fixture(paged: paged), library = value.library
            defer { library.prepareForTermination() }
            let views = library.storageDirectory.appendingPathComponent("views.json")
            var preserved: URL?
            library.resetCollectionState = { preserved = try self.obstacle(views) }
            do { try await library.resetApplication(); XCTFail("Expected partial reset") }
            catch { XCTAssertTrue(error.localizedDescription.contains("réinitialisé"), error.localizedDescription) }
            try await settle(library)
            try await assertDatabaseCount(0, library)
            XCTAssertTrue(library.snapshot.logs.isEmpty)
            XCTAssertTrue(library.clients.profiles.isEmpty)
            XCTAssertEqual(library.views.state.activeScope.clientID, "")
            XCTAssertNotNil(library.views.errorMessage)
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(preserved)), Data("unexpected directory source".utf8))
            XCTAssertEqual(try Data(contentsOf: value.source), value.original)
            library.loadHistory(); try await settle(library)
            XCTAssertTrue(library.historyPage?.snapshot.logs.isEmpty == true)
        }
    }

    func testClearLibraryStillReloadsAfterFilterSaveFailureAndKeepsClients() async throws {
        for paged in [false, true] {
            let value = try await fixture(paged: paged), library = value.library
            defer { library.prepareForTermination() }
            var scope = library.views.state.activeScope
            scope.logIDs = library.snapshot.logs.map(\.id); scope.droneKeys = ["ulog:synthetic-controller"]
            try library.views.chooseScope(scope); try await settle(library)
            let preserved = try obstacle(library.storageDirectory.appendingPathComponent("views.json"))
            let savedViews = try Data(contentsOf: library.storageDirectory.appendingPathComponent("views.json.preserved"))
            do { try await library.clearLibrary(); XCTFail("Expected partial cleanup") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Bibliothèque vidée"), error.localizedDescription) }
            try await settle(library)
            try await assertDatabaseCount(0, library)
            XCTAssertTrue(library.snapshot.logs.isEmpty)
            XCTAssertEqual(library.clients.profiles.map(\.id), [value.client.id])
            XCTAssertEqual(library.views.state.activeScope.clientID, value.client.id)
            XCTAssertTrue(library.views.state.activeScope.logIDs.isEmpty)
            XCTAssertTrue(library.views.state.activeScope.droneKeys.isEmpty)
            XCTAssertTrue(library.errorMessage?.contains("Filtre affiché") == true)
            library.loadHistory(); try await settle(library)
            XCTAssertTrue(library.historyPage?.snapshot.logs.isEmpty == true)
            XCTAssertEqual(try Data(contentsOf: value.source), value.original)
            XCTAssertEqual(try Data(contentsOf: preserved), Data("unexpected directory source".utf8))
            let views = library.storageDirectory.appendingPathComponent("views.json")
            try FileManager.default.moveItem(at: views, to: views.appendingPathExtension("obstacle"))
            try savedViews.write(to: views)
            library.clients.reload(); try await settle(library)
            let saved = try JSONDecoder().decode(LibraryViewState.self, from: Data(contentsOf: views))
            XCTAssertTrue(saved.activeScope.logIDs.isEmpty)
            XCTAssertTrue(saved.activeScope.droneKeys.isEmpty)
            XCTAssertEqual(saved.activeScope.clientID, value.client.id)
            XCTAssertNil(library.views.errorMessage)
        }
    }

    func testLateCollectionObstacleStillPausesQueueAfterConfirmedReset() async throws {
        let value = try await fixture(paged: false), library = value.library
        // With no clients, the Q04 cache does not incidentally save settings
        // again after reset. The normal collection timer must persist pause.
        try await library.clients.remove(id: value.client.id); try await settle(library)
        let settingsURL = library.storageDirectory.appendingPathComponent("gcs-settings.json")
        var settings = GCSCollectionState(downloadDirectory: library.storageDirectory.path)
        settings.reconnect = true; settings.queuePaused = false
        try JSONEncoder().encode(settings).write(to: settingsURL)
        let gcs = GCSStore(storageDirectory: library.storageDirectory)
        defer { gcs.stopForTermination(); library.prepareForTermination() }
        gcs.attach(library: library); try await settle(library)
        let reset = library.resetCollectionState
        var preserved: URL?
        library.resetCollectionState = {
            preserved = try self.obstacle(library.storageDirectory.appendingPathComponent("gcs-collection.json"))
            try reset()
        }
        do { try await library.resetApplication(); XCTFail("Expected partial collection reset") } catch {}
        XCTAssertEqual(library.resetGeneration, 1)
        XCTAssertTrue(gcs.isQueuePaused)
        XCTAssertFalse(gcs.isConnected)
        try await settle(library)
        var saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: settingsURL))
        let deadline = Date().addingTimeInterval(2)
        while saved.reconnect, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            saved = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: settingsURL))
        }
        XCTAssertFalse(saved.reconnect)
        XCTAssertEqual(saved.queuePaused, true)
        try await assertDatabaseCount(0, library)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(preserved)), Data("unexpected directory source".utf8))
        XCTAssertEqual(try Data(contentsOf: value.source), value.original)
    }

    func testSecondaryReaderCannotResetOrClearWriterState() async throws {
        let value = try await fixture(paged: true), writer = value.library
        defer { writer.prepareForTermination() }
        let reader = LibraryStore(storageDirectory: writer.storageDirectory, engine: try XCTUnwrap(writer.engineURL), pagedNavigation: true)
        defer { reader.prepareForTermination() }
        try await settle(reader)
        XCTAssertTrue(reader.isReadOnly)
        do { try await reader.resetApplication(); XCTFail("Reader cannot reset") } catch {}
        do { try await reader.clearLibrary(); XCTFail("Reader cannot clear") } catch {}
        XCTAssertEqual(reader.resetGeneration, 0)
        try await assertDatabaseCount(1, writer)
        XCTAssertEqual(try Data(contentsOf: value.source), value.original)
        XCTAssertEqual(writer.clients.profiles.map(\.id), [value.client.id])
    }
}
