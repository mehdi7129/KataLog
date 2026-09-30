import AppKit
import SwiftUI
import XCTest
@testable import KataLog
@testable import KataLogCore

/// Public synthetic records in an isolated SQLite library. This suite never connects a GCS or opens the user's library.
@MainActor
final class WorkspacePreviewTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let library: LibraryStore
        let gcs: GCSStore
        let noNetworkMarker: URL
    }

    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KataLog/Resources")
    }

    private func fixture(count: Int = 120, blockQueries: Bool = false) async throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard let python = environment["KATALOG_TEST_PYTHON"] ?? environment["KATALOG_PYTHON"],
              FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("Set KATALOG_TEST_PYTHON and KATALOG_PYTHON to a runtime with pyulog/numpy for native SQLite previews.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-workspace-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture.py")
        try """
        import sys,hashlib
        from pathlib import Path
        sys.path.insert(0,sys.argv[2])
        import analyzer
        folder=Path(sys.argv[1]).resolve();db=analyzer.open_database(folder/'library.sqlite')
        db.execute('INSERT INTO folders(path) VALUES(?)',(str(folder),))
        families=['Batterie','GNSS','Estimateur','Moteurs','Liaison radio','Capteurs','Stockage','Navigation','Alimentation']
        for i in range(int(sys.argv[3])):
            source=folder/('log_demo_%03d.ulg'%i);source.write_bytes(b'anonymous synthetic source')
            identity=hashlib.sha256(('fixture-'+str(i)).encode()).hexdigest()
            log=analyzer.base_log(source,folder,identity,source.stat().st_size)
            log.update(droneID='demo-controller-'+str(i%4),droneName='DEMO-'+str(i%4),date='2026-01-%02dT12:00:00Z'%(i%28+1),dateSource='fixture',durationSeconds=120,status='error' if i==3 else 'partial' if i==4 else 'ok',failsafeObserved=i==2,metadata={'parserVersion':analyzer.PARSER_VERSION})
            family=families[i%len(families)]
            log['messages']=[{'id':identity+'-message','timestampSeconds':5,'level':'WARNING','family':family,'title':'Exemple '+family,'text':'[fixture] '+family+' warning · message synthétique','groupKey':family+'|WARNING','isAlert':True},{'id':identity+'-info','timestampSeconds':10,'level':'INFO','family':'Autres','title':'Résumé prêt','text':'[fixture] Résumé prêt','groupKey':'Autres|INFO','isAlert':False}]
            if i==0:
                log['messages'] += [{'id':identity+'-raw','timestampSeconds':11,'level':'RAW','family':'Données brutes','title':'Événement brut','text':'[fixture] raw data','groupKey':'Données brutes|RAW','isAlert':False},{'id':identity+'-unknown','timestampSeconds':12,'level':'UNKNOWN','family':'Autres','title':'Niveau inconnu','text':'[fixture] unknown level','groupKey':'Autres|UNKNOWN','isAlert':False}]
            analyzer.remember_log(db,log);db.execute('INSERT INTO sources(log_id,path) VALUES(?,?)',(identity,str(source)))
        db.commit();db.close()
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script.path, root.path, resources.path, String(count)]
        process.environment = EngineRuntimeResolver.sanitizedEnvironment(environment)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        let errorFile = root.appendingPathComponent("fixture-error.txt")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorFile); defer { try? errors.close() }
        process.standardError = errors
        try process.run(); ProcessLifetime.wait(for: process)
        guard process.terminationStatus == 0 else {
            XCTFail(try String(contentsOf: errorFile, encoding: .utf8)); throw AnalysisError.engine("Synthetic SQLite fixture failed.")
        }
        let noNetworkMarker = root.appendingPathComponent("collector-was-invoked")
        let collector = root.appendingPathComponent("no-network.py")
        try "from pathlib import Path\nPath(\(String(reflecting: noNetworkMarker.path))).write_text('unexpected')\nraise RuntimeError('A native preview must not invoke a collector')\n"
            .write(to: collector, atomically: true, encoding: .utf8)
        var state = GCSCollectionState(downloadDirectory: root.appendingPathComponent("Collected Logs").path)
        state.host = ""; state.reconnect = false; state.autoImport = false
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-settings.json"))
        var engine = resources.appendingPathComponent("analyzer.py")
        if blockQueries {
            engine = root.appendingPathComponent("blocked-query.py")
            try """
            import sys,time,signal,runpy
            from pathlib import Path
            if sys.argv[1]=='query':
                signal.signal(signal.SIGTERM,signal.SIG_IGN)
                Path(\(String(reflecting: root.appendingPathComponent("query-blocked").path))).write_text('ready')
                while True: time.sleep(.02)
            sys.path.insert(0,\(String(reflecting: resources.path)))
            runpy.run_path(\(String(reflecting: resources.appendingPathComponent("analyzer.py").path)),run_name='__main__')
            """.write(to: engine, atomically: true, encoding: .utf8)
        }
        let library = LibraryStore(storageDirectory: root, engine: engine, pagedNavigation: true)
        addTeardownBlock { @MainActor in library.prepareForTermination() }
        let gcs = GCSStore(storageDirectory: root, collector: collector, snapshot: { library.snapshot })
        let fixture = Fixture(root: root, library: library, gcs: gcs, noNetworkMarker: noNetworkMarker)
        if blockQueries {
            let deadline = Date().addingTimeInterval(8)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("query-blocked").path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("query-blocked").path))
        } else { try await settle(library) }
        XCTAssertNil(library.queryError)
        return fixture
    }

    private func settle(_ library: LibraryStore) async throws {
        // @Published observers schedule work on the next main-actor turn.
        try await Task.sleep(for: .milliseconds(20))
        let deadline = Date().addingTimeInterval(20)
        while (library.isQuerying || library.isLoading || library.isLoadingFlight), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(library.isQuerying || library.isLoading || library.isLoadingFlight, "Isolated library did not settle within 20 seconds.")
    }

    private func render<V: View>(_ content: V, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme,
                                settleDelay: Duration = .milliseconds(450)) async throws -> NSSize {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: content.environment(\.colorScheme, scheme).preferredColorScheme(scheme).background(Color(nsColor: .windowBackgroundColor)))
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.close() }
        window.setContentSize(NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settleDelay)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        // Probe the requested size, not the unconstrained ideal size (a larger ideal is allowed).
        let fitting = controller.sizeThatFits(in: CGSize(width: width, height: height))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000)
        if let output = ProcessInfo.processInfo.environment["KATALOG_UI_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name + ".png"))
            try "requested=\(width)x\(height); fitting=\(fitting.width)x\(fitting.height); rendered=\(host.frame.width)x\(host.frame.height)\n"
                .write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
        return fitting
    }

    private func renderWorkspace(_ fixture: Fixture, page: Workspace06View.Page, name: String,
                                 width: CGFloat, height: CGFloat, scheme: ColorScheme) async throws -> NSSize {
        // Workspace appearance is persistent and takes precedence over the host.
        // Set the selected mode explicitly so a light capture cannot render dark.
        try fixture.library.views.setTheme(scheme == .dark ? "dark" : "light")
        try await settle(fixture.library)
        return try await render(Workspace06View(library: fixture.library, gcs: fixture.gcs, initialPage: page),
                                name: name, width: width, height: height, scheme: scheme)
    }

    func testWorkspacePagesRenderInBothThemesAtMinimumWindow() async throws {
        let f = try await fixture()
        XCTAssertEqual(f.library.historyPage?.totals.logs, 120)
        XCTAssertEqual(f.library.historyPage?.totals.familyLogCounts.count, 9)
        for page in [Workspace06View.Page.overview, .history, .alerts, .events, .drones,
                     .collection, .storage, .reports, .settings] {
            for scheme in [ColorScheme.dark, .light] {
                let fitting = try await renderWorkspace(f, page: page, name: "workspace-\(page)-\(scheme)",
                                                        width: 900, height: 620, scheme: scheme)
                XCTAssertLessThanOrEqual(fitting.width, 900.5, "\(page) exceeds the announced minimum window width.")
                XCTAssertLessThanOrEqual(fitting.height, 620.5, "\(page) exceeds the announced minimum window height.")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
        XCTAssertFalse(f.gcs.isConnected)
    }

    func testBlockedReadAndCancellationRenderRecoverableStatesAtMinimumWindow() async throws {
        let f = try await fixture(count: 1, blockQueries: true)
        try f.library.views.setTheme("dark")
        let waiting = try await render(Workspace06View(library: f.library, gcs: f.gcs),
            name: "query-waiting-dark", width: 900, height: 620, scheme: .dark, settleDelay: .seconds(13))
        XCTAssertTrue(f.library.isQuerying, "The delayed hint must not time out a long-running query.")
        XCTAssertNil(f.library.historyPage, "Pending results are not an established empty selection.")
        XCTAssertLessThanOrEqual(waiting.width, 900.5); XCTAssertLessThanOrEqual(waiting.height, 620.5)
        await f.library.cancelQuery()
        XCTAssertTrue(f.library.queryWasCancelled); XCTAssertFalse(f.library.hasActiveWork)
        try f.library.views.setTheme("light")
        let cancelled = try await render(Workspace06View(library: f.library, gcs: f.gcs),
            name: "query-cancelled-light", width: 900, height: 620, scheme: .light)
        XCTAssertLessThanOrEqual(cancelled.width, 900.5); XCTAssertLessThanOrEqual(cancelled.height, 620.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
        for scheme in [ColorScheme.dark, .light] {
            let fitting = try await render(LibraryReadRecoveryNotice(requestID: "fixture", isCancelling: false,
                palette: Palette(dark: scheme == .dark), cancel: {}, delay: .milliseconds(1)),
                name: "query-help-\(scheme)", width: 610, height: 240, scheme: scheme)
            XCTAssertLessThanOrEqual(fitting.width, 610.5)
            XCTAssertLessThanOrEqual(fitting.height, 240.5)
        }
    }

    func testOverviewRendersInBothThemesAtDesktopSizeWithoutStartingCollection() async throws {
        for count in [1, 120] {
            let f = try await fixture(count: count)
            XCTAssertEqual(f.library.historyPage?.totals.logs, count)
            for scheme in [ColorScheme.dark, .light] {
                let name = count == 1 ? "workspace-overview-single-\(scheme)-desktop" : "workspace-overview-\(scheme)-desktop"
                let fitting = try await renderWorkspace(f, page: .overview, name: name,
                                                        width: 1440, height: 980, scheme: scheme)
                XCTAssertLessThanOrEqual(fitting.width, 1440.5)
                XCTAssertLessThanOrEqual(fitting.height, 980.5)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
            XCTAssertFalse(f.gcs.isConnected)
        }
    }

    func testBentoUtilityPagesFitSingleLogAndWideFleetWindows() async throws {
        // These panels mix forms, summary cards and expanding secondary details.
        // Cover the narrow/single-log case as well as a populated desktop layout.
        for (count, width, height) in [(1, 900.0, 620.0), (1, 1440.0, 980.0), (120, 1440.0, 980.0)] {
            let f = try await fixture(count: count)
            for page in [Workspace06View.Page.alerts, .storage, .reports, .settings] {
                for scheme in [ColorScheme.dark, .light] {
                    let fitting = try await renderWorkspace(f, page: page,
                        name: "bento-\(page)-\(count)-\(Int(width))-\(scheme)",
                        width: width, height: height, scheme: scheme)
                    XCTAssertLessThanOrEqual(fitting.width, width + 0.5)
                    XCTAssertLessThanOrEqual(fitting.height, height + 0.5)
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
            XCTAssertFalse(f.gcs.isConnected)
        }
    }

    func testSourcesSheetRetirementUndoPreservesLogsAndFitsBothThemes() async throws {
        let f = try await fixture(count: 3)
        let sources = SourcesImportStore(library: f.library)
        sources.load(includeRemoved: true)
        var deadline = Date().addingTimeInterval(10)
        while sources.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(sources.errorMessage)
        let folder = try XCTUnwrap(sources.page?.folders.first)
        let originalCount = f.library.historyPage?.totals.logs
        let original = f.root.appendingPathComponent("log_demo_000.ulg")
        let originalData = try Data(contentsOf: original)
        sources.setRemoved(true, path: folder.path)
        deadline = Date().addingTimeInterval(10)
        while sources.isWorking || sources.isLoading || f.library.isQuerying, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(sources.errorMessage)
        XCTAssertEqual(sources.page?.removedCount, 1)
        XCTAssertEqual(sources.lastChange?.undoLabel, "Annuler le retrait")
        XCTAssertEqual(f.library.historyPage?.totals.logs, originalCount)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        sources.undo()
        deadline = Date().addingTimeInterval(10)
        while sources.isWorking || sources.isLoading || f.library.isQuerying, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(sources.errorMessage)
        XCTAssertEqual(sources.page?.activeCount, 1)
        XCTAssertEqual(sources.page?.removedCount, 0)
        XCTAssertNil(sources.lastChange)
        XCTAssertEqual(f.library.historyPage?.totals.logs, originalCount)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        for scheme in [ColorScheme.dark, .light] {
            let fitting = try await render(SourcesImportView(library: f.library), name: "sources-\(scheme)", width: 650, height: 460, scheme: scheme)
            XCTAssertLessThanOrEqual(fitting.width, 651)
            XCTAssertLessThanOrEqual(fitting.height, 461)
        }
    }

    func testPagedHistoryAndMessageScopeKeepReportCountsInSync() async throws {
        let f = try await fixture(count: 240)
        XCTAssertEqual(f.library.snapshot.logs.count, 200)
        let next = try XCTUnwrap(f.library.historyPage?.nextCursor)
        f.library.loadHistory(cursor: next); try await settle(f.library)
        XCTAssertEqual(f.library.snapshot.logs.count, 40)
        XCTAssertEqual(f.library.historyPage?.totals.logs, 240)
        f.library.hasExternalActivity = { true }
        defer { f.library.hasExternalActivity = { false } }
        var scope = SelectionScope(); scope.families = ["Batterie"]; scope.levels = ["WARNING"]
        try f.library.views.chooseScope(scope); try await settle(f.library)
        XCTAssertNil(f.library.queryError, "Navigation after index preparation stays read-only while a GCS collection is active.")
        XCTAssertEqual(f.library.historyPage?.totals.logs, 27)
        XCTAssertEqual(f.library.historyPage?.totals.messages, 27)
        XCTAssertEqual(f.library.historyPage?.totals.failsafeLogs, 0)
        XCTAssertEqual(f.library.groupPage?.groups.first?.messageCount, 27)
        XCTAssertNil(f.library.currentHistoryCursor)
    }

    func testScopeAndFlightSheetsFitTheAnnouncedMinimumHeight() async throws {
        let f = try await fixture(count: 4)
        let scope = try await render(ScopeEditor06(library: f.library), name: "scope-dark-minimum", width: 900, height: 620, scheme: .dark)
        XCTAssertLessThanOrEqual(scope.width, 900.5)
        XCTAssertLessThanOrEqual(scope.height, 620.5, "Filter sheet must keep its footer reachable in a 620-point-high window.")
        try await settle(f.library)
        f.library.loadFlight(try XCTUnwrap(f.library.snapshot.logs.first))
        try await settle(f.library)
        XCTAssertNotNil(f.library.selectedFlight)
        let flight = try await render(FlightSheet06(library: f.library), name: "flight-dark-minimum", width: 900, height: 620, scheme: .dark)
        XCTAssertLessThanOrEqual(flight.width, 900.5, "The embedded legacy sheet must not impose a larger minimum than the new workspace.")
        XCTAssertLessThanOrEqual(flight.height, 620.5)
    }

    func testProfileIncludesFamiliesBeyondEightAxesWithoutInventingRadarAxes() async throws {
        XCTAssertEqual(AlertProfile06.chartKind(axisCount: 0), .empty)
        XCTAssertEqual(AlertProfile06.chartKind(axisCount: 1), .bars)
        XCTAssertEqual(AlertProfile06.chartKind(axisCount: 2), .bars)
        XCTAssertEqual(AlertProfile06.chartKind(axisCount: 3), .radar)
        let counts = Dictionary(uniqueKeysWithValues: (0..<9).map { ("Famille \($0)", 9 - $0) })
        let families = AlertProfile06.families(counts: counts, selectedAxes: ["Famille 0", "Ancien axe"])
        XCTAssertEqual(families.count, 10)
        XCTAssertEqual(families.first, "Famille 0")
        XCTAssertTrue(families.contains("Famille 8"), "A ninth family must remain in the full frequency table.")
        XCTAssertEqual(families.last, "Ancien axe", "A persisted axis at zero remains visible.")
        for axes in [[], ["Batterie"], ["Batterie", "GNSS"]] {
            for scheme in [ColorScheme.dark, .light] {
                let fitting = try await render(AlertProfileChart06(axes: axes, counts: ["Batterie": 3, "GNSS": 0], denominator: 10),
                                               name: "profile-\(axes.count)-\(scheme)", width: 600, height: 130, scheme: scheme)
                XCTAssertLessThanOrEqual(fitting.width, 600.5)
                XCTAssertLessThanOrEqual(fitting.height, 130.5)
            }
        }
    }

    func testReadOnlySavedScopeAndResetAreTransientAndPreserveSettings() async throws {
        let f = try await fixture(count: 20)
        var scope = SelectionScope(); scope.families = ["Batterie"]
        try f.library.views.chooseScope(scope)
        try f.library.views.saveView(name: "Batterie")
        try await settle(f.library)
        let settings = f.root.appendingPathComponent("views.json")
        let before = try Data(contentsOf: settings)
        let reader = LibraryStore(storageDirectory: f.root, engine: resources.appendingPathComponent("analyzer.py"), pagedNavigation: true)
        try await settle(reader)
        XCTAssertTrue(reader.isReadOnly)
        let saved = try XCTUnwrap(reader.views.state.views.first)
        try reader.views.chooseScope(saved.scope); try await settle(reader)
        XCTAssertEqual(reader.historyPage?.totals.logs, 3)
        try reader.views.chooseScope(.init()); try await settle(reader)
        XCTAssertEqual(reader.historyPage?.totals.logs, 20)
        XCTAssertThrowsError(try reader.views.removeView(saved.id))
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    func testStoragePagesReportGlobalCountsAndCanReturnToFirstPage() async throws {
        let f = try await fixture(count: 240)
        let storage = LibraryStorageStore(library: f.library)
        func waitForStorage() async throws {
            let deadline = Date().addingTimeInterval(20)
            while storage.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(storage.isLoading); XCTAssertNil(storage.errorMessage)
        }
        storage.load(); try await waitForStorage()
        XCTAssertEqual(storage.info?.sourceCount, 240)
        XCTAssertEqual(storage.info?.sources.count, 200)
        XCTAssertEqual(storage.currentOffset, 0)
        let next = try XCTUnwrap(storage.info?.nextOffset)
        storage.load(offset: next); try await waitForStorage()
        XCTAssertEqual(storage.info?.sources.count, 40)
        XCTAssertEqual(storage.currentOffset, 200)
        XCTAssertNil(storage.info?.nextOffset)
        storage.load(); try await waitForStorage()
        XCTAssertEqual(storage.currentOffset, 0)
        XCTAssertEqual(storage.info?.sources.count, 200)
    }

    func testFilterCatalogueIncludesInfoOnlyFamiliesAndObservedUnknownLevels() async throws {
        let f = try await fixture(count: 20)
        await f.library.loadCatalogue()
        XCTAssertNil(f.library.catalogueError)
        let catalogue = try XCTUnwrap(f.library.catalogue)
        XCTAssertTrue(catalogue.families.contains("Autres"))
        XCTAssertTrue(catalogue.families.contains("Données brutes"))
        XCTAssertTrue(catalogue.levels.contains("INFO"))
        XCTAssertTrue(catalogue.levels.contains("RAW"))
        XCTAssertTrue(catalogue.levels.contains("UNKNOWN"))
    }

    func testEventBrowserShowsUnavailableCoverageAndFitsBothThemes() async throws {
        let f = try await fixture(count: 4)
        let store = EventBrowserStore()
        store.load(library: f.library, logID: nil, levelSource: "internal", level: "", search: "")
        let deadline = Date().addingTimeInterval(20)
        while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.isLoading); XCTAssertNil(store.error)
        let page = try XCTUnwrap(store.page)
        XCTAssertEqual(page.coverage.selectedLogs, 4)
        XCTAssertEqual(page.coverage.cachedLogs, 0)
        XCTAssertEqual(page.coverage.unavailableLogs, 4)
        XCTAssertEqual(page.total, 0, "Only cached occurrences are counted; unavailable logs are not described as free of events.")
        for scheme in [ColorScheme.dark, .light] {
            let fitting = try await render(EventBrowserView(library: f.library), name: "events-\(scheme)-minimum", width: 900, height: 620, scheme: scheme)
            XCTAssertLessThanOrEqual(fitting.width, 900.5)
            XCTAssertLessThanOrEqual(fitting.height, 620.5)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
    }

    func testReportPreviewCountsFullLibraryAndRejectsChangedReviewBeforePublication() async throws {
        let f = try await fixture(count: 20)
        var scope = SelectionScope(); scope.families = ["Batterie"]
        try f.library.views.chooseScope(scope); try await settle(f.library)
        let store = ReportPreviewStore()
        func waitForPreview() async throws {
            let deadline = Date().addingTimeInterval(20)
            while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(store.isLoading); XCTAssertNil(store.error)
        }
        store.load(library: f.library, mode: .full, options: .init(format: .json)); try await waitForPreview()
        let full = try XCTUnwrap(store.preview)
        XCTAssertEqual(full.totals.logs, 20); XCTAssertTrue(full.request.query.scope.includeMasked)
        XCTAssertTrue(full.request.query.scope.families.isEmpty); XCTAssertEqual(full.request.query.limit, 1)
        store.load(library: f.library, mode: .selection, options: .init(format: .json)); try await waitForPreview()
        let selected = try XCTUnwrap(store.preview)
        XCTAssertEqual(selected.totals.logs, 3); XCTAssertEqual(selected.totals.messages, 3)
        XCTAssertEqual(selected.request.query.scope.families, ["Batterie"])
        let report = f.root.appendingPathComponent("reviewed-report.json")
        let result = try await f.library.exportReport(to: report, reviewedRequest: selected.request, expectedRevision: selected.revision)
        XCTAssertEqual(result.logCount, selected.totals.logs); XCTAssertEqual(result.messageCount, selected.totals.messages)
        let published = try JSONDecoder().decode(FleetSnapshot.self, from: Data(contentsOf: report))
        XCTAssertEqual(published.logs.count, 3); XCTAssertEqual(published.logs.flatMap(\.messages).count, 3)
        let rejected = f.root.appendingPathComponent("must-not-publish.json")
        do { _ = try await f.library.exportReport(to: rejected, reviewedRequest: selected.request, expectedRevision: selected.revision - 1); XCTFail("A revision that was not reviewed must not publish.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("prévisualisation")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        try f.library.views.chooseScope(.init()); try await settle(f.library)
        do { _ = try await f.library.exportReport(to: rejected, reviewedRequest: selected.request, expectedRevision: selected.revision); XCTFail("A scope changed after review must not publish.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("prévisualisation")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertFalse(f.library.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
    }

    func testAnalysisRevisionsListReadOnlyWithoutLoadingDetailAndFitBothThemes() async throws {
        let f = try await fixture(count: 4)
        let log = try XCTUnwrap(f.library.snapshot.logs.first(where: { $0.status == "ok" }))
        let store = AnalysisRevisionsStore()
        store.load(library: f.library, logID: log.id)
        let deadline = Date().addingTimeInterval(20)
        while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.isLoading); XCTAssertNil(store.error); XCTAssertNil(store.detail)
        let page = try XCTUnwrap(store.page)
        XCTAssertEqual(page.total, 1); XCTAssertEqual(page.revisions.first?.kind, "summary")
        XCTAssertFalse(store.isLoadingDetail, "Listing metadata must not decompress or parse a detail before selection.")
        for scheme in [ColorScheme.dark, .light] {
            let fitting = try await render(AnalysisRevisionsView(library: f.library, logID: log.id), name: "revisions-\(scheme)-minimum", width: 900, height: 620, scheme: scheme)
            XCTAssertLessThanOrEqual(fitting.width, 900.5); XCTAssertLessThanOrEqual(fitting.height, 620.5)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
    }

    func testArchiveImportSettingsPersistAndRefuseFutureOrReadOnlyWrites() async throws {
        let f = try await fixture(count: 4)
        let archive = f.root.appendingPathComponent("Demo Archives", isDirectory: true)
        let state = ImportOptionsState(archiveDirectory: archive.path)
        try ImportOptionsPersistence.save(state, library: f.library)
        XCTAssertEqual(try ImportOptionsPersistence.load(directory: f.root), state)
        let settings = f.root.appendingPathComponent("import-options.json"), before = try Data(contentsOf: settings)
        let reader = LibraryStore(storageDirectory: f.root, engine: resources.appendingPathComponent("analyzer.py"), pagedNavigation: true)
        try await settle(reader); XCTAssertTrue(reader.isReadOnly)
        XCTAssertThrowsError(try ImportOptionsPersistence.save(.init(archiveDirectory: "synthetic-other"), library: reader))
        XCTAssertEqual(try Data(contentsOf: settings), before)
        let future = Data(#"{"schemaVersion":99,"archiveDirectory":"synthetic-future"}"#.utf8)
        try future.write(to: settings)
        XCTAssertThrowsError(try ImportOptionsPersistence.save(state, library: f.library))
        XCTAssertEqual(try Data(contentsOf: settings), future)
    }

    func testMaskImpactIsGlobalIncludesAlreadyMaskedMessagesAndReviewsExactKeys() async throws {
        let f = try await fixture(count: 20)
        let group = try XCTUnwrap(f.library.groupPage?.groups.first(where: { $0.family == "Batterie" }))
        var scope = SelectionScope(); scope.families = ["Batterie"]
        // The log page can have stripped messages. A message query gives an exact source log ID.
        var lookup = MaskImpactStore.request(groupID: group.id, annotations: f.library.annotations.state, maskedMessageKeys: [])
        lookup.limit = 1
        let occurrence = try await LibraryQueryService.page(LibraryMessagePage.self, request: lookup, database: f.library.databaseURL, engine: resources.appendingPathComponent("analyzer.py"), readOnly: true)
        scope.logIDs = [try XCTUnwrap(occurrence.occurrences.first).logID]
        try f.library.views.chooseScope(scope); try await settle(f.library)
        let selectedGroup = try XCTUnwrap(f.library.groupPage?.groups.first)
        XCTAssertEqual(selectedGroup.messageCount, 1)
        let store = MaskImpactStore()
        func waitForImpact() async throws { let deadline = Date().addingTimeInterval(20); while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }; XCTAssertFalse(store.isLoading); XCTAssertNil(store.error) }
        store.load(group: selectedGroup, library: f.library); try await waitForImpact()
        let impact = try XCTUnwrap(store.impact)
        XCTAssertEqual(impact.messages, 3); XCTAssertEqual(Set(impact.classKeys), Set(selectedGroup.classKeys ?? []))
        try MaskImpactStore.validate(impact, library: f.library)
        try f.library.views.mask(impact.classKeys, masked: true); try await settle(f.library)
        XCTAssertThrowsError(try MaskImpactStore.validate(impact, library: f.library))
        store.load(group: selectedGroup, library: f.library); try await waitForImpact()
        XCTAssertEqual(store.impact?.messages, 3, "Global preview includes messages already hidden by their rules.")
        XCTAssertEqual(MaskImpactStore.displayText("text-v1:7:WARNINGGPS error"), "WARNING · GPS error")
        for scheme in [ColorScheme.dark, .light] {
            let fitting = try await render(MaskImpact06(group: selectedGroup, masked: false, library: f.library, canApply: { true }, onApplied: {}), name: "mask-impact-\(scheme)-minimum", width: 900, height: 620, scheme: scheme)
            XCTAssertLessThanOrEqual(fitting.width, 900.5); XCTAssertLessThanOrEqual(fitting.height, 620.5)
            let importFit = try await render(ImportOptions06(source: f.root, initialState: .init(archiveDirectory: "synthetic-archives"), canApply: { true }, onApply: { _ in }), name: "import-options-\(scheme)-minimum", width: 900, height: 620, scheme: scheme)
            XCTAssertLessThanOrEqual(importFit.width, 900.5); XCTAssertLessThanOrEqual(importFit.height, 620.5)
            let copyFit = try await render(ImportOptions06(source: f.root, initialState: .init(archiveDirectory: "synthetic-archives"), initialCopy: true, canApply: { true }, onApply: { _ in }), name: "import-copy-\(scheme)-minimum", width: 900, height: 620, scheme: scheme)
            XCTAssertLessThanOrEqual(copyFit.width, 900.5); XCTAssertLessThanOrEqual(copyFit.height, 620.5)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
    }

    func testProfileAxesCanBeReorderedAndRestoreWithoutChangingCounts() async throws {
        let f = try await fixture(count: 4)
        let counts = f.library.historyPage?.totals.familyLogCounts
        let axes = ["Batterie", "GNSS", "Estimateur"]
        try f.library.views.setProfileAxes(axes)
        let moved = AlertProfile06.moving("GNSS", in: axes, by: -1)
        XCTAssertEqual(moved, ["GNSS", "Batterie", "Estimateur"])
        XCTAssertEqual(AlertProfile06.moving("GNSS", in: moved, by: -1), moved)
        try f.library.views.setProfileAxes(moved)
        let reopened = LibraryViewStore(url: f.root.appendingPathComponent("views.json"))
        XCTAssertEqual(reopened.state.profileAxes, moved)
        XCTAssertEqual(f.library.historyPage?.totals.familyLogCounts, counts)
    }

    func testMaskPreviewCannotClaimImpactWhenGlobalKeysOrRevisionChanged() async throws {
        let f = try await fixture(count: 4)
        let group = try XCTUnwrap(f.library.groupPage?.groups.first(where: { $0.family == "Batterie" }))
        let reply = try JSONDecoder().decode(LibraryMessagePage.self, from: Data(#"{"queryVersion":1,"revision":8,"scopeHash":"synthetic","occurrences":[],"total":99}"#.utf8))
        for mismatchedRevision in [false, true] {
            let store = MaskImpactStore(loader: { _, _, _ in reply }, keyLoader: { _, _, _ in
                MaskClassKeysPage(queryVersion: 1, revision: mismatchedRevision ? 7 : 8, total: 1,
                                  classKeys: mismatchedRevision ? group.classKeys ?? [] : ["text-v1:7:WARNINGDifferent text"], nextCursor: nil)
            })
            store.load(group: group, library: f.library)
            let deadline = Date().addingTimeInterval(2)
            while store.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(store.isLoading); XCTAssertNil(store.impact)
            XCTAssertTrue(store.error?.contains("Impact global indisponible") == true)
        }
        XCTAssertTrue(f.library.views.state.maskedMessageKeys.isEmpty)
    }

    func testGlobalRegistryAndDiagnosticSettingsFitBothThemesAtMinimumWindow() async throws {
        let f = try await fixture(count: 4)
        f.library.loadAuxiliary(kind: "drones"); try await settle(f.library)
        XCTAssertEqual(f.library.dronePage?.total, 4, "The fixture must render populated rows, not merely an empty state.")
        for page in [Workspace06View.Page.drones, .settings] {
            for scheme in [ColorScheme.dark, .light] {
                let fitting = try await renderWorkspace(f, page: page, name: "workspace-\(page)-\(scheme)-minimum",
                                                        width: 900, height: 620, scheme: scheme)
                XCTAssertLessThanOrEqual(fitting.width, 900.5); XCTAssertLessThanOrEqual(fitting.height, 620.5)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.noNetworkMarker.path))
    }
}
