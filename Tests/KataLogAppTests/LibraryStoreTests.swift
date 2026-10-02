import XCTest
import Darwin
import KataLogCore
@testable import KataLog

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func blockedQueryFixture(kind: String = "logs") throws -> (URL, LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-query-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("library.sqlite"))
        try Data().write(to: root.appendingPathComponent("block-" + kind))
        let engine = root.appendingPathComponent("engine.py")
        try #"""
import sys,json,pathlib,signal,time,os
root=pathlib.Path(__file__).parent
command=sys.argv[1]
request=json.loads(pathlib.Path(sys.argv[sys.argv.index('--request')+1]).read_text()) if '--request' in sys.argv else {}
kind=request.get('kind','logs') if command=='query' else command
block_kind='map' if kind=='map-overview' else kind
if command=='query':
    with (root/'query-calls').open('a') as stream: stream.write(kind+'\n')
if (root/('block-'+block_kind)).exists():
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    (root/('active-'+block_kind)).write_text(str(os.getpid()))
    while (root/('block-'+block_kind)).exists(): time.sleep(.02)
result={'queryVersion':1,'revision':7,'scopeHash':'synthetic','total':0}
if kind in ('logs','map'):
    result['snapshot']={'schemaVersion':1,'generatedAt':'resumed-query','sourceFolders':[],'importStats':{'discovered':0,'imported':0,'unchanged':0,'duplicates':0,'failed':0},'logs':[]}
    result['totals']={'logs':3,'validLogs':3,'messages':5,'alertLogs':2,'failsafeLogs':0,'recordedSeconds':60,'droneCount':1,'familyLogCounts':{},'groupCount':0}
elif kind=='map-overview': result.update(markers=[],totalLogs=3,locatedLogs=3)
elif kind=='groups': result['groups']=[]
elif kind=='drones': result['drones']=[]
elif kind=='messages': result['occurrences']=[]
pathlib.Path(sys.argv[sys.argv.index('--output')+1]).write_text(json.dumps(result))
"""#.write(to: engine, atomically: true, encoding: .utf8)
        let store = LibraryStore(storageDirectory: root, engine: engine, pagedNavigation: true)
        addTeardownBlock { @MainActor in store.prepareForTermination() }
        return (root, store)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "The synthetic query did not reach its expected state.")
    }

    private func activePID(_ root: URL, kind: String) async throws -> pid_t {
        let marker = root.appendingPathComponent("active-" + kind)
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        return try XCTUnwrap(pid_t(String(contentsOf: marker, encoding: .utf8)))
    }

    func testCancelBlockedHistoryDrainsOwnedHelperAndAllowsRetryWithoutPublishingEmptyResults() async throws {
        let (root, store) = try blockedQueryFixture()
        let pid = try await activePID(root, kind: "logs")
        XCTAssertTrue(store.isQuerying); XCTAssertNil(store.historyPage)
        let start = Date()
        let cancellation = Task { await store.cancelQuery() }
        try await waitUntil { store.isCancellingQuery }
        XCTAssertTrue(store.isQuerying, "Mutations must remain disabled while the helper drains.")
        let cancelledToken = store.queryToken
        store.loadHistory()
        XCTAssertEqual(store.queryToken, cancelledToken, "A replacement query must not race cancellation.")
        await cancellation.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(store.isQuerying); XCTAssertFalse(store.isCancellingQuery)
        XCTAssertTrue(store.queryWasCancelled); XCTAssertNil(store.historyPage); XCTAssertNil(store.queryError)
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        store.loadHistory()
        XCTAssertFalse(store.queryWasCancelled)
        try await waitUntil { !store.isQuerying }
        XCTAssertNil(store.queryError); XCTAssertEqual(store.historyPage?.totals.logs, 3)
        XCTAssertEqual(store.snapshot.generatedAt, "resumed-query")
    }

    func testCancelAuxiliaryAndOccurrenceQueriesPreservesCommittedHistoryAndResumes() async throws {
        let (root, store) = try blockedQueryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying }
        XCTAssertEqual(store.historyPage?.totals.logs, 3)
        for kind in ["drones", "map", "groups", "messages"] {
            try Data().write(to: root.appendingPathComponent("block-" + kind))
            if kind == "messages" { store.loadOccurrences(groupID: "fixture") }
            else { store.loadAuxiliary(kind: kind) }
            let pid = try await activePID(root, kind: kind)
            await store.cancelQuery()
            XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
            XCTAssertTrue(store.queryWasCancelled); XCTAssertFalse(store.isQuerying)
            XCTAssertEqual(store.historyPage?.totals.logs, 3, "Cancellation must retain the last committed result.")
            try FileManager.default.removeItem(at: root.appendingPathComponent("block-" + kind))
            if kind == "messages" { store.loadOccurrences(groupID: "fixture") }
            else { store.loadAuxiliary(kind: kind) }
            try await waitUntil { !store.isQuerying }
            XCTAssertFalse(store.queryWasCancelled); XCTAssertNil(store.queryError)
        }
        XCTAssertEqual(store.dronePage?.revision, 7); XCTAssertEqual(store.mapPage?.revision, 7)
        XCTAssertEqual(store.groupPage?.revision, 7); XCTAssertEqual(store.occurrencePage?.revision, 7)
    }

    func testCancelDuringInitialIndexPreparationReleasesMaintenanceBeforeRetry() async throws {
        let (root, store) = try blockedQueryFixture(kind: "ensure-index")
        _ = try await activePID(root, kind: "ensure-index")
        XCTAssertTrue(store.isMaintainingLibrary)
        await store.cancelQuery()
        XCTAssertFalse(store.isMaintainingLibrary); XCTAssertFalse(store.hasActiveWork)
        XCTAssertTrue(store.queryWasCancelled); XCTAssertNil(store.historyPage)
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-ensure-index"))
        store.loadHistory(); try await waitUntil { !store.isQuerying }
        XCTAssertEqual(store.historyPage?.totals.logs, 3); XCTAssertNil(store.queryError)
    }

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
    func testMapCanPrepareInitialIndexBeforeHistoryHasStarted() async throws {
        let (root, store) = try blockedQueryFixture(kind: "ensure-index")
        // Switch immediately, before the initial history task gets an actor turn.
        store.loadAuxiliary(kind: "map")
        _ = try await activePID(root, kind: "ensure-index")
        XCTAssertTrue(store.isMaintainingLibrary)
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-ensure-index"))
        try await waitUntil { !store.isQuerying }
        XCTAssertNil(store.queryError)
        XCTAssertEqual(store.mapPage?.revision, 7)
        XCTAssertEqual(callCount(root, "map-overview"), 1)
        XCTAssertEqual(callCount(root, "logs"), 0)
    }

    private func callCount(_ root: URL, _ kind: String? = nil) -> Int {
        let calls = (try? String(contentsOf: root.appendingPathComponent("query-calls"), encoding: .utf8)) ?? ""
        return calls.split(separator: "\n").filter { kind == nil || $0 == kind! }.count
    }

    func testNavigationReusesResultsAndExplicitReloadInvalidatesThem() async throws {
        let (root, store) = try blockedQueryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying }
        store.loadAuxiliary(kind: "map", usingCache: true)
        try await waitUntil { !store.isQuerying }
        let firstReadCalls = callCount(root)
        let start = ContinuousClock.now
        for _ in 0..<20 {
            store.loadHistory(usingCache: true)
            XCTAssertFalse(store.isQuerying)
            XCTAssertTrue(store.historyResultsCurrent)
            XCTAssertEqual(store.snapshot.generatedAt, "resumed-query")
            store.loadAuxiliary(kind: "map", usingCache: true)
            XCTAssertFalse(store.isQuerying)
        }
        XCTAssertEqual(callCount(root), firstReadCalls, "Revisiting unchanged tabs must launch no helper.")
        print("NAVIGATION_CACHE 40 warm tab changes: \(start.duration(to: .now)); helper queries: 0")
        store.reload()
        try await waitUntil { !store.isQuerying }
        XCTAssertEqual(callCount(root, "logs"), 2)
        store.loadAuxiliary(kind: "map", usingCache: true)
        try await waitUntil { !store.isQuerying }
        XCTAssertEqual(callCount(root, "map-overview"), 2)
    }

    func testCacheHitDrainsSupersededHelperBeforeUnlockingMutations() async throws {
        let (root, store) = try blockedQueryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying }
        let initialLogCalls = callCount(root, "logs")
        try Data().write(to: root.appendingPathComponent("block-drones"))
        store.loadAuxiliary(kind: "drones")
        let pid = try await activePID(root, kind: "drones")
        store.loadHistory(usingCache: true)
        XCTAssertTrue(store.isQuerying, "The previous process still owns work while it drains.")
        try await waitUntil { !store.isQuerying }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(callCount(root, "logs"), initialLogCalls)
        XCTAssertTrue(store.historyResultsCurrent)
        XCTAssertEqual(store.snapshot.generatedAt, "resumed-query")
        XCTAssertNil(store.queryError)
    }

    func testWALAndMaintenanceInvalidateCachedNavigation() async throws {
        let (root, store) = try blockedQueryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying }
        try Data([1]).write(to: root.appendingPathComponent("library.sqlite-wal"))
        store.loadHistory(usingCache: true)
        try await waitUntil { !store.isQuerying }
        XCTAssertEqual(callCount(root, "logs"), 2)
        try await store.performMaintenance { () async throws -> Void in }
        store.loadHistory(usingCache: true)
        try await waitUntil { !store.isQuerying }
        XCTAssertEqual(callCount(root, "logs"), 3)
    }

    func testDifferentSortAndCursorDoNotReuseWrongHistoryPage() async throws {
        let (root, store) = try blockedQueryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying }
        store.historySortOverride = "oldest"
        store.loadHistory(usingCache: true)
        try await waitUntil { !store.isQuerying }
        store.loadHistory(cursor: "synthetic-page-two", usingCache: true)
        try await waitUntil { !store.isQuerying }
        XCTAssertEqual(store.currentHistoryCursor, "synthetic-page-two")
        XCTAssertEqual(callCount(root, "logs"), 3)
        store.historySortOverride = nil
        store.loadHistory(usingCache: true)
        XCTAssertFalse(store.isQuerying)
        XCTAssertNil(store.currentHistoryCursor)
        XCTAssertEqual(callCount(root, "logs"), 3)
    }

}
