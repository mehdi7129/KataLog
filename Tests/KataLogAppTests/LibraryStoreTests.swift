import XCTest
@testable import KataLog

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testReloadUsesCommittedDatabaseInsteadOfStaleJSONAfterInterruptedImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-db-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // An import can commit SQLite before the snapshot file is refreshed.
        try Data().write(to: root.appendingPathComponent("library.sqlite"))
        let stale = #"{"schemaVersion":1,"generatedAt":"stale-json","sourceFolders":[],"importStats":{"discovered":0,"imported":0,"unchanged":0,"duplicates":0,"failed":0},"logs":[]}"#
        try stale.write(to: root.appendingPathComponent("library.json"), atomically: true, encoding: .utf8)
        let engine = root.appendingPathComponent("engine.py")
        try #"""
import sys,json,pathlib
assert sys.argv[1]=='snapshot'
result=json.loads((pathlib.Path(__file__).parent/'library.json').read_text())
result['generatedAt']='authoritative-db'
pathlib.Path(sys.argv[sys.argv.index('--output')+1]).write_text(json.dumps(result))
"""#.write(to: engine, atomically: true, encoding: .utf8)
        let store = LibraryStore(storageDirectory: root, engine: engine)
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot.generatedAt, "authoritative-db")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8), stale,
                       "A background read must not overwrite an importer's snapshot.")
    }
}
