import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class ReportPreviewStoreTests: XCTestCase {
    private let placeholder = URL(fileURLWithPath: "/synthetic/unused")
    private var fixtureShouldFail = true
    private func page(logs: Int, revision: Int) throws -> LibraryLogPage {
        try JSONDecoder().decode(LibraryLogPage.self, from: Data("""
        {"queryVersion":1,"revision":\(revision),"scopeHash":"synthetic","snapshot":{"schemaVersion":1,"generatedAt":"","sourceFolders":[],"importStats":{"discovered":0,"imported":0,"unchanged":0,"duplicates":0,"failed":0},"logs":[]},"totals":{"logs":\(logs),"validLogs":\(logs),"messages":\(logs),"alertLogs":0,"failsafeLogs":0,"recordedSeconds":0,"droneCount":1,"familyLogCounts":{},"groupCount":0}}
        """.utf8))
    }
    private func settle(_ store: ReportPreviewStore) async throws {
        let deadline = Date().addingTimeInterval(2)
        while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isLoading)
    }
    func testFullRequestIncludesMaskedMessagesAndClearsSelectionWithoutChangingSourceScope() {
        var scope = SelectionScope(); scope.families = ["Batterie"]; scope.droneKeys = ["ulog:DEMO-A"]
        let full = ReportPreviewStore.request(mode: .full, scope: scope, annotations: .init(), maskedMessageKeys: ["text-v1:demo"], viewRevision: 7, options: .init(format: .json, excludePaths: true, includeCachedDetails: true))
        XCTAssertTrue(full.query.scope.isUnfiltered); XCTAssertTrue(full.query.scope.includeMasked)
        XCTAssertEqual(full.query.limit, 1); XCTAssertEqual(full.viewRevision, 7)
        XCTAssertEqual(full.query.maskedMessageKeys, ["text-v1:demo"])
        XCTAssertTrue(full.options.includeCachedDetails); XCTAssertEqual(full.options.format, .json)
        let selected = ReportPreviewStore.request(mode: .selection, scope: scope, annotations: .init(), maskedMessageKeys: [], viewRevision: 8, options: .init())
        XCTAssertEqual(selected.query.scope, scope); XCTAssertFalse(selected.query.scope.includeMasked)
    }
    func testLateResponseCannotReplaceNewPreviewAndCancelClearsReview() async throws {
        var pending: [String: CheckedContinuation<LibraryLogPage, Error>] = [:]
        let store = ReportPreviewStore { request, _, _ in
            try await withCheckedThrowingContinuation { pending[request.scope.search] = $0 }
        }
        var first = ReportPreviewStore.request(mode: .selection, scope: .init(), annotations: .init(), maskedMessageKeys: [], viewRevision: 1, options: .init())
        first.query.scope.search = "old"
        store.load(request: first, database: placeholder, engine: placeholder)
        for _ in 0..<100 where pending["old"] == nil { await Task.yield() }
        var second = first; second.query.scope.search = "new"; second.options.format = .json
        store.load(request: second, database: placeholder, engine: placeholder)
        for _ in 0..<100 where pending["new"] == nil { await Task.yield() }
        let fresh = try XCTUnwrap(pending.removeValue(forKey: "new"))
        fresh.resume(returning: try page(logs: 3, revision: 8)); try await settle(store)
        let old = try XCTUnwrap(pending.removeValue(forKey: "old"))
        old.resume(returning: try page(logs: 99, revision: 1)); await Task.yield()
        XCTAssertEqual(store.preview?.totals.logs, 3); XCTAssertEqual(store.preview?.revision, 8)
        XCTAssertEqual(store.preview?.request.query.scope.search, "new"); XCTAssertEqual(store.preview?.request.options.format, .json)
        store.cancel(); XCTAssertNil(store.preview); XCTAssertFalse(store.isLoading)
    }
    func testFailureClearsReviewAndRetryCanPublishEmptySelection() async throws {
        let store = ReportPreviewStore { [self] _, _, _ in
            if fixtureShouldFail { throw AnalysisError.engine("Erreur synthétique") }
            return try page(logs: 0, revision: 3)
        }
        let request = ReportPreviewStore.request(mode: .selection, scope: .init(), annotations: .init(), maskedMessageKeys: [], viewRevision: 1, options: .init())
        store.load(request: request, database: placeholder, engine: placeholder); try await settle(store)
        XCTAssertNil(store.preview); XCTAssertNotNil(store.error)
        fixtureShouldFail = false; store.load(request: request, database: placeholder, engine: placeholder); try await settle(store)
        XCTAssertNil(store.error); XCTAssertEqual(store.preview?.totals.logs, 0)
    }
}
