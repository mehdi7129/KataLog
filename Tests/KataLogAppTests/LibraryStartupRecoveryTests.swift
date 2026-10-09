import Foundation
import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class LibraryStartupRecoveryTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var engine: URL { sourceRoot.appendingPathComponent("Sources/KataLog/Resources/analyzer.py") }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-startup-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func pendingLibrary() throws -> URL {
        let root = try directory(), library = root.appendingPathComponent("Library")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["KATALOG_TEST_PYTHON"]))
        process.arguments = ["-B", "-c", """
        import json,sys
        from pathlib import Path
        sys.path[:0]=[sys.argv[1],sys.argv[2]]
        import analyzer
        from fixture_ulog import synthetic_ulog
        root=Path(sys.argv[3]); root.mkdir()
        source=root.parent/'source.ulg'; source.write_bytes(synthetic_ulog(samples=3))
        analyzer.scan(source,root/'library.sqlite',skip_snapshot=True)
        db=analyzer.open_database(root/'library.sqlite')
        db.execute('INSERT INTO clients VALUES(?,?)',('11111111-1111-1111-1111-111111111111','Recovered client'))
        db.commit(); db.close()
        token='a'*32
        recovery=root/('recovery-'+token); original=recovery/'original-files'; original.mkdir(parents=True)
        (root/'library.sqlite').rename(original/'library.sqlite')
        (original/'annotations.json').write_text(json.dumps({'schemaVersion':1,'stockNumbers':{'ulog:fixture':'123'},'familyOverrides':{}}))
        (original/'views.json').write_text(json.dumps({'schemaVersion':1,'revision':0,'activeScope':{},'views':[],'maskedMessageKeys':[],'theme':'light'}))
        (original/'gcs-settings.json').write_text(json.dumps({'schemaVersion':1,'host':'restored.invalid','allowedUUIDs':[],
            'downloadDirectory':str(root/'Collected Logs'),'autoImport':True,'reconnect':False,'queue':[]}))
        names=['library.sqlite','annotations.json','views.json','gcs-settings.json']
        (root/'.restore-journal.json').write_text(json.dumps({'restoreVersion':1,'phase':'prepared',
            'recoveryDirectory':recovery.name,'archiveDirectory':'restored-ulogs-'+token,'moved':names,'installed':[]}))
        """, sourceRoot.appendingPathComponent("Sources/KataLog/Resources").path,
            sourceRoot.appendingPathComponent("Tests").path, library.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run(); ProcessLifetime.wait(for: process)
        XCTAssertEqual(process.terminationStatus, 0)
        return library
    }
    private func settle(_ store: LibraryStore) async throws {
        let deadline = Date().addingTimeInterval(15)
        while store.isMaintainingLibrary || store.isLoading || store.isQuerying || store.clients.isLoading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isMaintainingLibrary || store.isLoading || store.isQuerying || store.clients.isLoading)
    }
    private func managedFiles(_ root: URL) throws -> [String: Data] {
        let names = ["library.sqlite", "annotations.json", "views.json", "gcs-settings.json", "gcs-queue.sqlite"]
        return try names.reduce(into: [:]) { result, name in
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { result[name] = try Data(contentsOf: file) }
        }
    }

    func testStartupRecoversBeforeQueriesAndCollectorWritesInBothNavigationModes() async throws {
        for paged in [false, true] {
            let root = try pendingLibrary()
            let store = LibraryStore(storageDirectory: root, engine: engine, pagedNavigation: paged)
            let gcs = GCSStore(storageDirectory: root)
            defer { store.prepareForTermination(); gcs.stopForTermination() }
            gcs.attach(library: store)
            store.clients.reload() // The view may appear while recovery still owns the gate.
            XCTAssertTrue(store.isMaintainingLibrary, "Recovery must own the gate before init returns.")
            XCTAssertThrowsError(try store.annotations.setStockNumber("456", forKey: "ulog:fixture"))
            XCTAssertThrowsError(try store.views.setTheme("dark"))
            XCTAssertTrue(try managedFiles(root).isEmpty)
            try await settle(store)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-journal.json").path))
            XCTAssertFalse(store.isReadOnly)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.snapshot.logs.count, 1)
            XCTAssertEqual(store.clients.profiles.map(\.name), ["Recovered client"])
            XCTAssertEqual(store.annotations.state.stockNumbers["ulog:fixture"], "123")
            XCTAssertEqual(store.views.state.theme, "light")
            XCTAssertEqual(gcs.host, "restored.invalid")
            XCTAssertTrue(gcs.isQueuePaused); XCTAssertFalse(gcs.isConnected)
            XCTAssertEqual(try store.diagnostics.snapshot().events.filter { $0.kind == .appStarted }.count, 1)
        }
    }

    func testInvalidJournalKeepsManagedFilesUntouchedAndAllowsTermination() async throws {
        let root = try directory()
        try Data("invalid journal".utf8).write(to: root.appendingPathComponent(".restore-journal.json"))
        let store = LibraryStore(storageDirectory: root, engine: engine, pagedNavigation: true)
        let gcs = GCSStore(storageDirectory: root)
        gcs.attach(library: store)
        try await settle(store)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertTrue(store.errorMessage?.contains("restauration") == true)
        XCTAssertNil(store.engineURL)
        store.reload(); store.loadHistory(); store.clients.reload()
        XCTAssertThrowsError(try store.views.setTheme("dark"))
        XCTAssertTrue(try managedFiles(root).isEmpty)
        store.prepareForTermination(); gcs.stopForTermination()
        XCTAssertFalse(store.hasActiveWork)
        XCTAssertTrue(try managedFiles(root).isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".restore-journal.json"), encoding: .utf8), "invalid journal")
    }

    func testReaderCannotRecoverJournalOwnedByAnotherWriter() async throws {
        let root = try pendingLibrary(), lease = try LibraryWriterLease(directory: root)
        XCTAssertTrue(lease.isWritable)
        let journalBefore = try Data(contentsOf: root.appendingPathComponent(".restore-journal.json"))
        let reader = LibraryStore(storageDirectory: root, engine: engine, pagedNavigation: true)
        let gcs = GCSStore(storageDirectory: root)
        gcs.attach(library: reader)
        try await settle(reader)
        XCTAssertTrue(reader.isReadOnly); XCTAssertNil(reader.engineURL)
        XCTAssertTrue(reader.errorMessage?.contains("restauration") == true)
        XCTAssertTrue(try managedFiles(root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".restore-journal.json")), journalBefore)
        reader.prepareForTermination(); gcs.stopForTermination()
        XCTAssertFalse(reader.hasActiveWork)
        withExtendedLifetime(lease) {}
    }

    func testCollectorAttachingAfterRecoveryReloadsStateAndStaysPaused() async throws {
        for initializedBeforeRecovery in [false, true] {
            let root = try pendingLibrary()
            let earlyCollector = initializedBeforeRecovery ? GCSStore(storageDirectory: root) : nil
            let store = LibraryStore(storageDirectory: root, engine: engine)
            try await settle(store)
            let gcs = earlyCollector ?? GCSStore(storageDirectory: root)
            defer { store.prepareForTermination(); gcs.stopForTermination() }
            gcs.attach(library: store)
            await gcs.waitForStorageLoad()
            XCTAssertFalse(store.isStartupBlocked); XCTAssertFalse(gcs.isMaintenanceBlocked)
            XCTAssertEqual(gcs.host, "restored.invalid")
            XCTAssertTrue(gcs.isQueuePaused); XCTAssertFalse(gcs.isConnected)
            XCTAssertNil(gcs.errorMessage)
        }
    }

    func testTerminationCancelsRecoveryWithoutUnlockingPartialStateForQueries() async throws {
        let root = try directory(), script = root.appendingPathComponent("slow-recovery.py")
        let journal = root.appendingPathComponent(".restore-journal.json")
        try Data("pending".utf8).write(to: journal)
        try """
        import sys,time
        from pathlib import Path
        assert sys.argv[1]=='recover-restore'
        root=Path(sys.argv[sys.argv.index('--library')+1])
        (root/'started').touch()
        time.sleep(30)
        """.write(to: script, atomically: true, encoding: .utf8)
        let store = LibraryStore(storageDirectory: root, engine: script)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        store.prepareForTermination()
        try await settle(store)
        XCTAssertTrue(store.isStartupBlocked); XCTAssertTrue(store.isReadOnly)
        XCTAssertNil(store.engineURL); XCTAssertFalse(store.hasActiveWork)
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "pending")
        XCTAssertTrue(try managedFiles(root).isEmpty)
    }
}
