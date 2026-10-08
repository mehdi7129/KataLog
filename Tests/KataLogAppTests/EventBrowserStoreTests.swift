import Foundation
import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class EventBrowserStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-event-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func settle(_ store: EventBrowserStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isLoading)
    }
    private func page(_ label: String = "A", next: String? = nil) throws -> LibraryEventPage {
        let value: [String: Any] = [
            "queryVersion": 1, "revision": 1, "scopeHash": label, "total": 1,
            "nextCursor": next as Any? ?? NSNull(),
            "coverage": ["selectedLogs": 1, "cachedLogs": 1, "unavailableLogs": 0,
                         "legacyCacheLogs": 0, "invalidCacheLogs": 0, "eventLogs": 1,
                         "translatedLogs": 0, "previousParserLogs": 0],
            "occurrences": [["logID": String(repeating: "a", count: 64), "droneID": "fixture", "droneName": label,
                             "date": "", "sourcePaths": [], "event": ["id": label, "eventID": 1, "level": "INFO", "argumentsHex": ""]]]
        ]
        return try JSONDecoder().decode(LibraryEventPage.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testFailedNewFilterNeverPublishesPreviousFilterPage() async throws {
        let root = try directory(), engine = root.appendingPathComponent("events.py")
        let first = String(decoding: try JSONEncoder().encode(page()), as: UTF8.self)
        try """
        import json,sys
        from pathlib import Path
        request=json.loads(Path(sys.argv[sys.argv.index('--request')+1]).read_text())
        if request['eventSearch']=='B': raise RuntimeError('Synthetic filter failure')
        Path(sys.argv[sys.argv.index('--output')+1]).write_text(\(String(reflecting: first)))
        """.write(to: engine, atomically: true, encoding: .utf8)
        let library = LibraryStore(storageDirectory: root, engine: engine), store = EventBrowserStore()
        defer { store.cancel(); library.prepareForTermination() }
        store.load(library: library, logID: nil, levelSource: "internal", level: "", search: "A")
        try await settle(store)
        XCTAssertEqual(store.page?.occurrences.first?.droneName, "A")
        store.load(library: library, logID: nil, levelSource: "internal", level: "", search: "B")
        XCTAssertNil(store.page, "A cannot be shown while filter B is being read.")
        try await settle(store)
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.page, "Failure of B must not relabel A's data as B.")
    }
    private func query(_ search: String, engine: URL? = URL(fileURLWithPath: "/fixture/engine.py")) -> EventBrowserStore.Query {
        var request = LibraryQueryRequest(kind: "events")
        request.eventSearch = search
        return EventBrowserStore.Query(request: request, database: URL(fileURLWithPath: "/fixture/library.sqlite"), engine: engine)
    }

    @MainActor private final class PendingReads {
        var requests: [LibraryQueryRequest] = []
        var continuations: [CheckedContinuation<LibraryEventPage, Error>] = []
        func read(_ request: LibraryQueryRequest) async throws -> LibraryEventPage {
            requests.append(request)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func waitFor(_ count: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while continuations.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(continuations.count, count)
        }
    }

    func testLateResponseAndCancellationCannotPublishForAnotherFilter() async throws {
        let reads = PendingReads(), a = query("A"), b = query("B")
        let store = EventBrowserStore { request, _, _ in try await reads.read(request) }
        store.load(a); try await reads.waitFor(1)
        store.load(b); try await reads.waitFor(2)
        reads.continuations[1].resume(returning: try page("B"))
        try await settle(store)
        reads.continuations[0].resume(returning: try page("late A"))
        await Task.yield()
        XCTAssertEqual(store.page?.occurrences.first?.droneName, "B")
        XCTAssertNil(store.result(for: a.key))

        store.load(a); try await reads.waitFor(3)
        XCTAssertNil(store.page)
        store.cancel()
        reads.continuations[2].resume(returning: try page("cancelled A"))
        await Task.yield()
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.page)
        XCTAssertEqual(store.result(for: b.key)?.page.occurrences.first?.droneName, "B")
    }

    func testPageAndCursorCommitTogetherAfterSuccessfulRetry() async throws {
        let reads = PendingReads(), query = query("A")
        let store = EventBrowserStore { request, _, _ in try await reads.read(request) }
        store.load(query); try await reads.waitFor(1)
        reads.continuations[0].resume(returning: try page("first", next: "cursor-2"))
        try await settle(store)
        store.load(query, cursor: "cursor-2"); try await reads.waitFor(2)
        XCTAssertEqual(store.result?.pageNumber, 1)
        reads.continuations[1].resume(throwing: AnalysisError.engine("Synthetic cursor failure"))
        try await settle(store)
        XCTAssertEqual(store.result?.pageNumber, 1)
        XCTAssertEqual(store.page?.occurrences.first?.droneName, "first")
        XCTAssertEqual(store.requestedCursor, "cursor-2")
        store.load(query, cursor: store.requestedCursor); try await reads.waitFor(3)
        XCTAssertEqual(reads.requests[2].cursor, "cursor-2")
        reads.continuations[2].resume(returning: try page("second"))
        try await settle(store)
        XCTAssertEqual(store.result?.pageNumber, 2)
        XCTAssertEqual(store.page?.occurrences.first?.droneName, "second")
        store.load(query, cursor: store.result?.previousCursor); try await reads.waitFor(4)
        XCTAssertEqual(store.result?.pageNumber, 2)
        reads.continuations[3].resume(throwing: CancellationError())
        try await settle(store)
        XCTAssertEqual(store.result?.pageNumber, 2)
        XCTAssertEqual(store.page?.occurrences.first?.droneName, "second")
    }

    func testMissingEngineResetsLoadingAndRejectsEarlierResponse() async throws {
        let reads = PendingReads(), store = EventBrowserStore { request, _, _ in try await reads.read(request) }
        store.load(query("A")); try await reads.waitFor(1)
        store.load(query("B", engine: nil))
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(store.error)
        reads.continuations[0].resume(returning: try page())
        await Task.yield()
        XCTAssertNil(store.page)
        XCTAssertFalse(store.isLoading)
    }

    func testVisibilityUsesFullScopeBeforeNextLoadStarts() async throws {
        var request = LibraryQueryRequest(kind: "events")
        request.scope.clientID = "client-A"
        let database = URL(fileURLWithPath: "/fixture/library.sqlite"), engine = URL(fileURLWithPath: "/fixture/engine.py")
        let a = EventBrowserStore.Query(request: request, database: database, engine: engine)
        let response = try page()
        let store = EventBrowserStore { _, _, _ in response }
        store.load(a); try await settle(store)
        XCTAssertNotNil(store.result(for: a.key))
        request.scope.clientID = "client-B" // Both scopes have the same human-readable description.
        let b = EventBrowserStore.Query(request: request, database: database, engine: engine)
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertNil(store.result(for: b.key), "Rendering B must hide A even before the .task callback loads B.")
        request.scope.clientID = "client-A"
        request.annotations.stockNumbers["ulog:fixture"] = "42"
        XCTAssertNil(store.result(for: EventBrowserStore.Query(request: request, database: database, engine: engine).key))
        request.annotations = DroneAnnotationState()
        request.maskedMessageKeys = ["masked"]
        XCTAssertNil(store.result(for: EventBrowserStore.Query(request: request, database: database, engine: engine).key))
        request.maskedMessageKeys = []
        XCTAssertNotEqual(a.key, EventBrowserStore.Query(request: request, database: database, engine: engine, viewRevision: 1).key)
        XCTAssertNotEqual(a.key, EventBrowserStore.Query(request: request, database: database, engine: engine, libraryRevision: 1).key)
        XCTAssertNotEqual(a.key, EventBrowserStore.Query(request: request, database: database.appendingPathExtension("other"), engine: engine).key)
        request.eventLevelSource = "internal|ERROR"; request.eventLevels = []; request.eventSearch = "A"
        let delimited = EventBrowserStore.Query(request: request, database: database, engine: engine)
        request.eventLevelSource = "internal"; request.eventLevels = ["ERROR|"]
        XCTAssertNotEqual(delimited.key, EventBrowserStore.Query(request: request, database: database, engine: engine).key)
    }

}
