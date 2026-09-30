import Foundation
import XCTest
@testable import KataLog
import KataLogCore

@MainActor
final class LibraryMaintenanceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-coordinator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testMaintenanceBlocksEditsAndAlwaysReleasesAfterFailure() async throws {
        let store = LibraryStore(storageDirectory: try directory())
        var didFlush = false; store.willMaintainLibrary = { didFlush = true }
        struct Expected: Error {}
        do { _ = try await store.performMaintenance {
            XCTAssertTrue(store.isMaintainingLibrary)
            XCTAssertThrowsError(try store.views.saveView(name: "blocked"))
            XCTAssertThrowsError(try store.annotations.setStockNumber("001", forKey: "ulog:fixture"))
            throw Expected()
        } as Int; XCTFail("Expected failure") } catch is Expected {}
        XCTAssertTrue(didFlush); XCTAssertFalse(store.isMaintainingLibrary)
        try store.views.saveView(name: "after")
        XCTAssertEqual(store.views.state.views.count, 1)
    }
    func testExternalCollectionAndReaderCannotTakeMaintenance() async throws {
        let root = try directory(), writer = LibraryStore(storageDirectory: root)
        writer.hasExternalActivity = { true }
        do { _ = try await writer.performMaintenance { 1 }; XCTFail("busy collector") } catch {}
        XCTAssertFalse(writer.isMaintainingLibrary)
        let reader = LibraryStore(storageDirectory: root)
        XCTAssertTrue(reader.isReadOnly)
        do { _ = try await reader.performMaintenance { 1 }; XCTFail("secondary writer") } catch {}
        var scope = SelectionScope(); scope.families = ["Fixture family"]
        try reader.views.chooseScope(scope)
        XCTAssertEqual(reader.views.state.activeScope, scope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("views.json").path))
    }
    func testStorageMessagesDescribeEffectsWithoutExposingJSON() throws {
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"completed":2,"failed":1,"reused":1,"path":"/private/source"}"#.utf8))
        let text = LibraryStorageStore.summary(command: "archive", result: result)
        XCTAssertTrue(text.contains("2 fichiers")); XCTAssertTrue(text.contains("1 erreurs"))
        XCTAssertFalse(text.contains("/private/source")); XCTAssertFalse(text.contains("{\""))
    }
    func testCleanupDescribesHistoricalRevisionEffectsAndRecovery() throws {
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"removedCount":3,"removedRevisionCount":7,"retainedRevisionCount":6,"recoveryDirectory":"/private/recovery-cache-fixture","originalsDeleted":false}"#.utf8))
        let text = LibraryStorageStore.summary(command: "clean-cache", result: result)
        XCTAssertTrue(text.contains("3 caches détaillés"))
        XCTAssertTrue(text.contains("7 anciennes révisions"))
        XCTAssertTrue(text.contains("6 dernières révisions conservées"))
        XCTAssertTrue(text.contains("récupération"))
        XCTAssertTrue(text.contains("ULog et les résumés restent disponibles"))
        XCTAssertFalse(text.contains("/private/recovery"))
    }
}
