import Foundation
import Darwin
import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class LibraryIntegrationTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testRestoreSucceededButCollectorReopenFailedIsReportedAsRestored() async throws {
        let root = try directory(), engine = root.appendingPathComponent("restore-fixture.py")
        try """
        import sys,json
        from pathlib import Path
        assert sys.argv[1]=='restore'
        Path(sys.argv[sys.argv.index('--output')+1]).write_text(json.dumps({'restored':True}))
        """.write(to: engine, atomically: true, encoding: .utf8)
        let library = LibraryStore(storageDirectory: root, engine: engine)
        struct CollectorFailed: LocalizedError { var errorDescription: String? { "Fixture collector unavailable" } }
        library.didRestoreLibrary = { throw CollectorFailed() }
        let result = try await library.restore(from: root.appendingPathComponent("fixture.zip"))
        XCTAssertEqual(result["restored"], .bool(true))
        XCTAssertTrue(library.statusMessage?.contains("Bibliothèque restaurée") == true)
        XCTAssertTrue(library.errorMessage?.contains("collecte ne peut pas être rouverte") == true)
        XCTAssertFalse(library.isMaintainingLibrary)
        XCTAssertFalse(library.isReadOnly)
    }
    func testTerminationCancelsReaderAndPreventsLateSnapshotReplacement() async throws {
        let root = try directory(), engine = root.appendingPathComponent("slow-reader.py")
        try """
        import time,sys,os
        from pathlib import Path
        Path(sys.argv[sys.argv.index('--database')+1]+'.started').write_text(str(os.getpid()))
        time.sleep(20)
        """.write(to: engine, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: root.appendingPathComponent("library.sqlite").path, contents: Data())
        let library = LibraryStore(storageDirectory: root, engine: engine)
        defer { library.prepareForTermination() }
        let started = root.appendingPathComponent("library.sqlite.started")
        let deadline = Date().addingTimeInterval(3)
        var startedPID: pid_t?
        while startedPID == nil, Date() < deadline {
            startedPID = (try? String(contentsOf: started, encoding: .utf8)).flatMap(Int32.init)
            if startedPID == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let readerPID = try XCTUnwrap(startedPID, "The fixture reader must report its PID before cancellation.")
        library.prepareForTermination()
        let stopped = Date().addingTimeInterval(2)
        // The shared registry can include helpers from other stores. Verify
        // cancellation of this library's exact reader process.
        while Darwin.kill(readerPID, 0) == 0, Date() < stopped { try await Task.sleep(for: .milliseconds(20)) }
        let probe = Darwin.kill(readerPID, 0), probeError = errno
        XCTAssertEqual(probe, -1)
        XCTAssertEqual(probeError, ESRCH)
        XCTAssertFalse(library.hasActiveWork)
        XCTAssertTrue(library.snapshot.logs.isEmpty)
    }

    func testNativeImportWithArchiveReusesCopyAndRemainsReadableAfterCardRemoval() async throws {
        let root = try directory(), card = root.appendingPathComponent("Card"), archives = root.appendingPathComponent("Archives")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let source = card.appendingPathComponent("public-demo.ulg")
        let script = root.appendingPathComponent("create-fixture.py")
        try """
        import sys
        from pathlib import Path
        sys.path.insert(0,sys.argv[1])
        from fixture_ulog import synthetic_ulog
        Path(sys.argv[2]).write_bytes(synthetic_ulog(samples=33))
        """.write(to: script, atomically: true, encoding: .utf8)
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["KATALOG_TEST_PYTHON"])
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script.path, sourceRoot.appendingPathComponent("Tests").path, source.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); ProcessLifetime.wait(for: process); XCTAssertEqual(process.terminationStatus, 0)
        let original = try Data(contentsOf: source)
        let library = LibraryStore(storageDirectory: root.appendingPathComponent("Library"), engine: sourceRoot.appendingPathComponent("Sources/KataLog/Resources/analyzer.py"), pagedNavigation: true)
        let first = try await library.importCollectedFolder(card, archiveDestination: archives)
        XCTAssertEqual(first.importStats.discovered, 1)
        XCTAssertEqual(first.importStats.archiveCompleted, 1)
        XCTAssertEqual(first.importStats.archiveFailed, 0)
        XCTAssertNil(library.errorMessage)
        let second = try await library.importCollectedFolder(card, archiveDestination: archives)
        XCTAssertEqual(second.importStats.archiveReused, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: archives, includingPropertiesForKeys: nil))
        let copies = enumerator.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "ulg" }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original)
        try FileManager.default.removeItem(at: source)
        let log = try XCTUnwrap(first.logs.first)
        let detail = try await AnalysisService.detail(logID: log.id, database: library.databaseURL, engine: XCTUnwrap(library.engineURL))
        XCTAssertFalse(detail.messages.isEmpty)
        XCTAssertEqual(detail.id, log.id)
        let canonicalArchives = archives.resolvingSymlinksInPath().path + "/"
        XCTAssertTrue(detail.sourcePaths.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(canonicalArchives) },
                      "La copie vérifiée doit rester une source du log après retrait de la carte.")
    }
}
