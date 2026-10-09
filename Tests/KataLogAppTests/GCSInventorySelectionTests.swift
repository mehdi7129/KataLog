import XCTest
import KataLogCore
@testable import KataLog

@MainActor
extension GCSStoreTests {
    func testFilteredInventorySelectionPreservesChoicesOutsideSearch() async throws {
        let (store, root) = try fixture(mode: "normal")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { store.canCollectAll }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        let visible = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        let hidden = try XCTUnwrap(store.files.first { $0.filename == "b.ulg" })

        store.selectAllFiles(visibleIDs: [visible.id])
        XCTAssertEqual(store.selectedFileIDs, [visible.id], "A filtered bulk action must not select hidden files.")
        store.toggleFile(hidden)
        store.selectAllFiles(visibleIDs: [visible.id])
        XCTAssertEqual(store.selectedFileIDs, [hidden.id], "Deselecting visible files must preserve an explicit choice outside the search.")
        store.selectAllFiles(visibleIDs: [])
        XCTAssertEqual(store.selectedFileIDs, [hidden.id], "An empty search result must not change the selection.")
        store.selectAllFiles()
        XCTAssertEqual(store.selectedFileIDs, [visible.id, hidden.id])
        store.selectAllFiles()
        XCTAssertTrue(store.selectedFileIDs.isEmpty)
        XCTAssertTrue(store.queue.isEmpty, "Selection alone must never start collection.")
    }

    func testFilteredInventorySelectionExcludesCachedAndUnknownFiles() async throws {
        let (store, root) = try fixture(mode: "normal")
        defer { store.stopCollection(); store.disconnect(); try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x41, count: 64).write(to: root.appendingPathComponent(first + "a.ulg.cache"))
        try await waitUntil { store.canCollectAll }
        await store.selectDrone(first)
        try await waitUntil { !store.isBusy && store.files.count == 2 }
        let cached = try XCTUnwrap(store.files.first { $0.filename == "a.ulg" })
        let pending = try XCTUnwrap(store.files.first { $0.filename == "b.ulg" })
        XCTAssertTrue(cached.isDownloaded)
        XCTAssertFalse(pending.isDownloaded)

        store.selectAllFiles(visibleIDs: [cached.id, pending.id, "/stale-inventory.ulg"])
        XCTAssertEqual(store.selectedFileIDs, [pending.id], "Only pending files from the current inventory may be selected.")
        store.selectAllFiles(visibleIDs: [cached.id, "/stale-inventory.ulg"])
        XCTAssertEqual(store.selectedFileIDs, [pending.id], "A search containing no selectable files must leave existing choices intact.")
        XCTAssertTrue(store.queue.isEmpty)
    }
}
