import XCTest
@testable import KataLog
import KataLogCore

@MainActor
final class LibraryViewStoreTests: XCTestCase {
    func testViewsAndMasksPersistAndCanBeReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        let store = LibraryViewStore(url: url)
        var scope = SelectionScope(); scope.families = ["Batterie"]
        try store.setScope(scope); try store.saveView(name: "Batteries")
        try store.mask(["text-v1:7:WARNINGBattery"], masked: true)
        let reloaded = LibraryViewStore(url: url)
        XCTAssertEqual(reloaded.state.activeScope, scope)
        XCTAssertEqual(reloaded.state.views.count, 1)
        XCTAssertEqual(reloaded.state.maskedMessageKeys.count, 1)
        try reloaded.setScope(.init()); try reloaded.mask(reloaded.state.maskedMessageKeys, masked: false)
        XCTAssertTrue(reloaded.state.activeScope.isUnfiltered)
        XCTAssertTrue(reloaded.state.maskedMessageKeys.isEmpty)
    }
    func testReadOnlyAndMaintenanceCannotMutate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        let readOnly = LibraryViewStore(url: url, canWrite: false)
        XCTAssertThrowsError(try readOnly.setScope(.init()))
        let writer = LibraryViewStore(url: url)
        writer.canMutate = { false }
        XCTAssertThrowsError(try writer.saveView(name: "blocked"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testExternalChangeIsPreservedAsConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("views.json")
        let store = LibraryViewStore(url: url)
        let external = try JSONEncoder().encode(LibraryViewState())
        try external.write(to: url)
        XCTAssertThrowsError(try store.saveView(name: "conflict"))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }
}
