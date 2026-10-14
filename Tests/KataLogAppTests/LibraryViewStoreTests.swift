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
    func testFavoriteRestoresCompleteScopeAndRemovalPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        let store = LibraryViewStore(url: url)
        var scope = SelectionScope()
        scope.clientID = "synthetic-client"; scope.droneKeys = ["ulog:synthetic"]
        scope.dateFrom = "2026-01-01"; scope.dateTo = "2026-01-10"; scope.includeUnknownDates = false
        scope.families = ["GNSS"]; scope.levels = ["WARNING"]; scope.alertOnly = true
        scope.search = "GPS"; scope.logSearch = "test"; scope.statuses = ["ok"]; scope.includeMasked = true
        try store.chooseScope(scope); try store.saveView(name: "  Essais GNSS  ")
        let favorite = try XCTUnwrap(store.state.views.first)
        XCTAssertEqual(favorite.name, "Essais GNSS")
        try store.chooseScope(.init())
        try store.applyView(favorite.id, validClientIDs: ["synthetic-client"])
        XCTAssertEqual(store.state.activeScope, scope)
        let reloaded = LibraryViewStore(url: url)
        XCTAssertEqual(reloaded.state.activeScope, scope)
        try reloaded.removeView(favorite.id)
        XCTAssertTrue(LibraryViewStore(url: url).state.views.isEmpty)
        XCTAssertEqual(reloaded.state.activeScope, scope, "Removing a favorite must not silently change the current results.")
    }
    func testFavoriteForDeletedClientDoesNotBroadenCurrentScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryViewStore(url: root.appendingPathComponent("views.json"))
        var scope = SelectionScope(); scope.clientID = "deleted"
        try store.chooseScope(scope); try store.saveView(name: "Ancien client")
        let id = try XCTUnwrap(store.state.views.first?.id)
        scope.clientID = "current"; scope.families = ["Batterie"]
        try store.chooseScope(scope)
        XCTAssertThrowsError(try store.applyView(id, validClientIDs: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("chargement"), "An unloaded client catalogue must not be presented as a deleted client.")
        }
        XCTAssertThrowsError(try store.applyView(id, validClientIDs: ["current"]))
        XCTAssertThrowsError(try store.applyView("absent", validClientIDs: ["current"]))
        XCTAssertEqual(store.state.activeScope, scope)
    }
    func testReadOnlyFavoriteAppliesTemporarilyAndRejectsModification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        let writer = LibraryViewStore(url: url)
        var scope = SelectionScope(); scope.search = "synthetic"
        try writer.chooseScope(scope); try writer.saveView(name: "Recherche")
        let id = try XCTUnwrap(writer.state.views.first?.id)
        try writer.chooseScope(.init())
        let original = try Data(contentsOf: url)
        let reader = LibraryViewStore(url: url, canWrite: false)
        try reader.applyView(id, validClientIDs: [])
        XCTAssertEqual(reader.state.activeScope, scope)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try reader.removeView(id))
        XCTAssertThrowsError(try reader.saveView(name: "Forbidden"))
        reader.canMutate = { false }
        XCTAssertThrowsError(try reader.applyView(id, validClientIDs: []))
    }
}
