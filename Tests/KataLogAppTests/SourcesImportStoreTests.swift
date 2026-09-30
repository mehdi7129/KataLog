import Foundation
import XCTest
@testable import KataLog

@MainActor
final class SourcesImportStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-sources-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testListArgumentsAreGlobalPaginatedAndCanIncludeRetiredSources() {
        let database = URL(fileURLWithPath: "/fixture/library.sqlite")
        let arguments = SourcesImportStore.listArguments(database: database, offset: 200, includeRemoved: true)
        XCTAssertEqual(arguments, ["source-folders", "--database", database.path,
                                   "--offset", "200", "--limit", "200", "--include-removed"])
        XCTAssertFalse(SourcesImportStore.listArguments(database: database, offset: -1, includeRemoved: false).contains("--include-removed"))
        XCTAssertFalse(arguments.contains("--output"), "AnalysisService owns its temporary output.")
        XCTAssertFalse(arguments.contains("--scope"))
    }

    func testRetireAndRestoreCommandsOnlyChangeSourceRegistration() {
        let database = URL(fileURLWithPath: "/fixture/library.sqlite")
        XCTAssertEqual(SourcesImportStore.changeArguments(database: database, path: "/Volumes/Fixture logs", removed: true),
                       ["retire-source", "--database", database.path, "--folder", "/Volumes/Fixture logs"])
        XCTAssertEqual(SourcesImportStore.changeArguments(database: database, path: "/Volumes/Fixture logs", removed: false).first, "restore-source")
    }

    func testPageDecodesServiceDataAndKeepsGlobalCountsBeyondThePage() async throws {
        let root = try directory(), library = LibraryStore(storageDirectory: root, engine: root.appendingPathComponent("fixture-engine.py"))
        try Data().write(to: library.databaseURL)
        var captured = [String]()
        let store = SourcesImportStore(library: library) { arguments, _ in
            captured = arguments
            let result = #"{"activeCount":201,"removedCount":3,"total":204,"nextOffset":null,"folders":[{"path":"/Volumes/Card/Logs","logCount":42,"state":"offline","removed":true}]}"#
            return Data(result.utf8)
        }
        store.load(offset: 200, includeRemoved: true)
        let deadline = Date().addingTimeInterval(2)
        while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isLoading); XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.currentOffset, 200)
        XCTAssertEqual(store.page?.activeCount, 201)
        XCTAssertEqual(store.page?.removedCount, 3)
        XCTAssertEqual(store.page?.folders.first?.availabilityLabel, "Volume hors ligne")
        XCTAssertEqual(store.page?.folders.first?.name, "Logs")
        XCTAssertFalse(captured.contains("--output"))
    }

    func testReadOnlyAndCollectionBusyRefuseSourceChangesBeforeLaunchingEngine() throws {
        let root = try directory(), writer = LibraryStore(storageDirectory: root), reader = LibraryStore(storageDirectory: root)
        var launches = 0
        let runner: SourcesImportStore.Runner = { _, _ in launches += 1; return Data() }
        let readerSources = SourcesImportStore(library: reader, runner: runner)
        XCTAssertTrue(reader.isReadOnly); XCTAssertFalse(readerSources.canMutate)
        readerSources.setRemoved(true, path: "/fixture")
        writer.hasExternalActivity = { true }
        let writerSources = SourcesImportStore(library: writer, runner: runner)
        XCTAssertFalse(writerSources.canMutate)
        writerSources.setRemoved(true, path: "/fixture")
        XCTAssertEqual(launches, 0)
        XCTAssertFalse(writerSources.isWorking)
    }
}
