import XCTest
import Darwin
import KataLogCore
@testable import KataLog

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func blockedQueryFixture(kind: String = "logs", failingClients: Bool = false,
                                     createDatabase: Bool = true, emptyClients: Bool = false) throws -> (URL, LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-query-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        if createDatabase { try Data().write(to: root.appendingPathComponent("library.sqlite")) }
        try Data().write(to: root.appendingPathComponent("block-" + kind))
        if failingClients { try Data().write(to: root.appendingPathComponent("fail-clients")) }
        if emptyClients { try Data().write(to: root.appendingPathComponent("empty-clients")) }
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
    if '--proximity-cache' in sys.argv:
        cache=pathlib.Path(sys.argv[sys.argv.index('--proximity-cache')+1])
        cache.write_text('synthetic cache')
        (root/'last-map-cache').write_text(str(cache))
if command=='clients':
    with (root/'client-calls').open('a') as stream: stream.write('clients\n')
if (root/('block-'+block_kind)).exists():
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    marker=root/('active-'+block_kind)
    temporary=root/('active-'+block_kind+'.tmp')
    temporary.write_text(str(os.getpid()))
    temporary.replace(marker)
    while (root/('block-'+block_kind)).exists(): time.sleep(.02)
if command=='ensure-index': (root/'library.sqlite').touch()
if (root/('fail-'+block_kind)).exists():
    sys.stderr.write('synthetic '+kind+' failure')
    sys.exit(1)
result={'queryVersion':1,'revision':7,'scopeHash':'synthetic','total':0}
if kind in ('logs','map'):
    result['snapshot']={'schemaVersion':1,'generatedAt':'resumed-query','sourceFolders':[],'importStats':{'discovered':0,'imported':0,'unchanged':0,'duplicates':0,'failed':0},'logs':[]}
    result['totals']={'logs':3,'validLogs':3,'messages':5,'alertLogs':2,'failsafeLogs':0,'recordedSeconds':60,'droneCount':1,'familyLogCounts':{},'groupCount':0}
elif kind=='map-overview': result.update(markers=[],totalLogs=3,locatedLogs=3)
elif kind=='groups': result['groups']=[]
elif kind=='drones': result['drones']=[]
elif kind=='messages': result['occurrences']=[]
elif kind=='clients': result={'clients':[] if (root/'empty-clients').exists() else [{'id':'synthetic-client','name':'Synthetic client'}]}
elif kind=='create-client': result={'id':'created-client','name':request['name']}
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

    func testMapSelectionCacheIsRemovedAfterCompletionAndCancellation() async throws {
        let (root, store) = try blockedQueryFixture(kind: "map")
        let area = GeographicProximity(latitude: 45, longitude: 4, radiusMeters: 100)
        store.loadMap(proximity: area)
        _ = try await activePID(root, kind: "map")
        let cancelledCache = URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("last-map-cache"), encoding: .utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cancelledCache.path))
        await store.cancelQuery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledCache.deletingLastPathComponent().path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-map"))
        store.loadMap(proximity: area)
        try await waitUntil { !store.isQuerying }
        XCTAssertNil(store.queryError)
        let completedCache = URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("last-map-cache"), encoding: .utf8))
        XCTAssertNotEqual(completedCache, cancelledCache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedCache.deletingLastPathComponent().path))
        XCTAssertEqual(store.mapPage?.revision, 7)
    }

    private func callCount(_ root: URL, _ kind: String? = nil) -> Int {
        let calls = (try? String(contentsOf: root.appendingPathComponent("query-calls"), encoding: .utf8)) ?? ""
        return calls.split(separator: "\n").filter { kind == nil || $0 == kind! }.count
    }

    private func clientCallCount(_ root: URL) -> Int {
        let calls = (try? String(contentsOf: root.appendingPathComponent("client-calls"), encoding: .utf8)) ?? ""
        return calls.split(separator: "\n").count
    }

    func testClientsRemainAvailableWhenInitialGroupQueryFails() async throws {
        let (root, store) = try blockedQueryFixture(kind: "groups")
        _ = try await activePID(root, kind: "groups")
        try await waitUntil { store.clients.hasLoaded && !store.clients.isLoading }
        XCTAssertEqual(store.clients.profiles.map(\.name), ["Synthetic client"])
        XCTAssertNil(store.historyPage)
        try Data().write(to: root.appendingPathComponent("fail-groups"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-groups"))
        try await waitUntil { !store.isQuerying }
        XCTAssertTrue(store.queryError?.contains("synthetic groups failure") == true)
        XCTAssertEqual(store.clients.scopeLabel(for: "synthetic-client"), "Synthetic client")
        XCTAssertNil(store.clients.errorMessage)
    }

    func testCachedNavigationRetriesClientFailureWithoutRepeatingHistoryQueries() async throws {
        let (root, store) = try blockedQueryFixture(failingClients: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying && !store.clients.isLoading }
        store.loadAuxiliary(kind: "map", usingCache: true)
        try await waitUntil { !store.isQuerying && !store.clients.isLoading }
        XCTAssertFalse(store.clients.hasLoaded)
        XCTAssertNotNil(store.clients.errorMessage)
        XCTAssertTrue(store.clients.profiles.isEmpty)
        let historyCalls = callCount(root), failedClientCalls = clientCallCount(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-clients"))
        store.loadAuxiliary(kind: "map", usingCache: true)
        XCTAssertFalse(store.isQuerying)
        try await waitUntil { !store.clients.isLoading }
        XCTAssertTrue(store.clients.hasLoaded)
        XCTAssertNil(store.clients.errorMessage)
        XCTAssertEqual(store.clients.profiles.map(\.id), ["synthetic-client"])
        XCTAssertEqual(callCount(root), historyCalls)
        XCTAssertEqual(clientCallCount(root), failedClientCalls + 1)
        for _ in 0..<20 { store.loadHistory(usingCache: true) }
        XCTAssertFalse(store.clients.isLoading)
        XCTAssertEqual(clientCallCount(root), failedClientCalls + 1)
    }

    func testFailedClientRefreshAndMissingDatabasePreserveLastValidProfiles() async throws {
        let (root, store) = try blockedQueryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying && !store.clients.isLoading }
        let previous = store.clients.profiles
        XCTAssertEqual(previous.count, 1)
        try Data().write(to: root.appendingPathComponent("fail-clients"))
        store.clients.reload()
        try await waitUntil { !store.clients.isLoading }
        XCTAssertNotNil(store.clients.errorMessage)
        XCTAssertTrue(store.clients.hasLoaded)
        XCTAssertEqual(store.clients.profiles, previous)
        try FileManager.default.removeItem(at: root.appendingPathComponent("library.sqlite"))
        store.clients.reload()
        XCTAssertFalse(store.clients.isLoading)
        XCTAssertNotNil(store.clients.errorMessage)
        XCTAssertEqual(store.clients.profiles, previous)
    }

    func testClientReadIsNotRestartedByRepeatedWarmNavigation() async throws {
        let (root, store) = try blockedQueryFixture(kind: "clients")
        try await waitUntil { !store.isQuerying }
        _ = try await activePID(root, kind: "clients")
        let initialReads = clientCallCount(root)
        for _ in 0..<20 { store.loadHistory(usingCache: true) }
        XCTAssertTrue(store.clients.isLoading)
        XCTAssertEqual(clientCallCount(root), initialReads)
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-clients"))
        try await waitUntil { !store.clients.isLoading }
        XCTAssertTrue(store.clients.hasLoaded)
        XCTAssertEqual(clientCallCount(root), initialReads)
    }

    func testMaintenanceDrainsClientReaderBeforeReplacingDatabase() async throws {
        let (root, store) = try blockedQueryFixture(kind: "clients")
        try await waitUntil { !store.isQuerying }
        let pid = try await activePID(root, kind: "clients")
        XCTAssertTrue(store.clients.isLoading)
        try await store.performMaintenance {
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            XCTAssertFalse(store.clients.isLoading)
            try Data("replacement".utf8).write(to: root.appendingPathComponent("library.sqlite"), options: .atomic)
            store.clients.reload()
            XCTAssertFalse(store.clients.isLoading, "A reader cannot restart while the database is being replaced.")
        }
        XCTAssertTrue(store.clients.profiles.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-clients"))
        store.loadHistory(usingCache: true)
        try await waitUntil { !store.isQuerying && !store.clients.isLoading }
        XCTAssertEqual(store.clients.profiles.map(\.name), ["Synthetic client"])
    }

    func testMaintenanceGateCoversAwaitedStorageDrainAndItsFailure() async throws {
        let (root, store) = try blockedQueryFixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-logs"))
        try await waitUntil { !store.isQuerying && !store.clients.isLoading }
        for fails in [false, true] {
            var release: CheckedContinuation<Void, Never>?
            defer { release?.resume() }
            var operationEntered = false
            store.willMaintainLibrary = {
                await withCheckedContinuation { release = $0 }
                if fails { throw AnalysisError.engine("Synthetic durable drain failure") }
            }
            let maintenance = Task {
                try await store.performMaintenance { operationEntered = true }
            }
            try await waitUntil { release != nil }
            XCTAssertTrue(store.isMaintainingLibrary, "Raise the gate before awaiting collection persistence.")
            XCTAssertFalse(operationEntered)
            var concurrentOperationEntered = false
            do {
                try await store.performMaintenance { concurrentOperationEntered = true }
                XCTFail("A second operation cannot enter during the storage drain.")
            } catch {}
            XCTAssertFalse(concurrentOperationEntered)
            let calls = clientCallCount(root)
            store.clients.reload()
            XCTAssertFalse(store.clients.isLoading)
            XCTAssertEqual(clientCallCount(root), calls)
            let continuation = try XCTUnwrap(release)
            release = nil
            continuation.resume()
            do {
                try await maintenance.value
                XCTAssertFalse(fails)
            } catch {
                XCTAssertTrue(fails)
                XCTAssertTrue(error.localizedDescription.contains("Synthetic durable drain failure"))
            }
            XCTAssertEqual(operationEntered, !fails)
            XCTAssertFalse(store.isMaintainingLibrary, "A failed drain must also release the gate.")
        }
    }

    func testFirstIndexCreationRecoversClientReadWithoutExistingDatabase() async throws {
        let (root, store) = try blockedQueryFixture(kind: "ensure-index", createDatabase: false, emptyClients: true)
        store.clients.reload()
        XCTAssertNotNil(store.clients.errorMessage)
        XCTAssertFalse(store.clients.hasLoaded)
        _ = try await activePID(root, kind: "ensure-index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("block-ensure-index"))
        try await waitUntil { !store.isQuerying && !store.clients.isLoading }
        XCTAssertTrue(store.clients.hasLoaded)
        XCTAssertNil(store.clients.errorMessage)
        XCTAssertTrue(store.clients.profiles.isEmpty)
    }

    func testClientMutationOwnsMaintenanceWhileItsReaderDrains() async throws {
        let (root, store) = try blockedQueryFixture(kind: "clients")
        try await waitUntil { !store.isQuerying }
        let pid = try await activePID(root, kind: "clients")
        let creation = Task { try await store.clients.create(name: "New client") }
        try await waitUntil { store.clients.isWorking }
        XCTAssertTrue(store.isMaintainingLibrary)
        var concurrentMaintenanceEntered = false
        do {
            try await store.performMaintenance { concurrentMaintenanceEntered = true }
            XCTFail("A second maintenance operation cannot enter while the client reader drains.")
        } catch {}
        XCTAssertFalse(concurrentMaintenanceEntered)
        let client = try await creation.value
        XCTAssertEqual(client.name, "New client")
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(store.clients.isWorking)
        XCTAssertFalse(store.isMaintainingLibrary)
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
