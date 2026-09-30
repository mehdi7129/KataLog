import Foundation
import XCTest
@testable import KataLogCore

@MainActor
final class ReportExportTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func runtime() throws -> EngineRuntimeResolver.Configuration {
        let environment = ProcessInfo.processInfo.environment
        guard let python = environment["KATALOG_TEST_PYTHON"] ?? environment["KATALOG_PYTHON"],
              FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("Set KATALOG_TEST_PYTHON to a development runtime with pyulog/numpy for real CLI report tests.")
        }
        var options = environment; options["KATALOG_PYTHON"] = python
        return .init(environment: options, externalCandidates: [])
    }

    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KataLog/Resources")
    }

    private func fixture(_ root: URL, messageCount: Int = 2) throws -> (URL, EngineRuntimeResolver.Configuration) {
        let configuration = try runtime()
        let python = try XCTUnwrap(configuration.environment["KATALOG_PYTHON"])
        let script = root.appendingPathComponent("fixture.py")
        try """
        import sys,json,hashlib
        from pathlib import Path
        sys.path.insert(0,sys.argv[2])
        import analyzer
        source=Path(sys.argv[3])/'PRIVATE-NEEDLE-42.ulg'
        source.write_bytes(b'invented source remains unchanged')
        identity=hashlib.sha256(b'invented log').hexdigest()
        log=analyzer.base_log(source,source.parent,identity,source.stat().st_size)
        log.update(droneID='PRIVATE-NEEDLE-42',droneName='PRIVATE-NEEDLE-42',date='2026-01-01T12:00:00Z',durationSeconds=60,status='ok',metadata={'secret':'PRIVATE-NEEDLE-42'})
        log['messages']=[{'id':str(i),'timestampSeconds':i,'level':'WARNING','family':'Batterie','title':'PRIVATE-NEEDLE-42','text':'PRIVATE-NEEDLE-42 warning','groupKey':'warning','isAlert':True} for i in range(int(sys.argv[4]))]
        db=analyzer.open_database(sys.argv[1]);analyzer.remember_log(db,log)
        db.execute('INSERT INTO sources VALUES(?,?)',(identity,str(source)));db.commit();db.close()
        """.write(to: script, atomically: true, encoding: .utf8)
        let database = root.appendingPathComponent("library.sqlite")
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script.path, database.path, resources.path, root.path, String(messageCount)]
        process.environment = EngineRuntimeResolver.sanitizedEnvironment(configuration.environment)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (database, configuration)
    }

    func testAtomicFolderSwapAndUnrelatedFolderRefusal() throws {
        let root = try folder(), target = root.appendingPathComponent("target"), stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("{\"producer\":\"KataLog\",\"schemaVersion\":1}".utf8).write(to: target.appendingPathComponent("manifest.json"))
        try Data("old".utf8).write(to: target.appendingPathComponent("index.html"))
        try Data("new".utf8).write(to: stage.appendingPathComponent("index.html"))
        try ReportExportService.atomicPublishFolder(stage, to: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("index.html"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("index.html"), encoding: .utf8), "old")
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("{\"producer\":\"Other\",\"schemaVersion\":1}".utf8).write(to: unrelated.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ReportExportService.atomicPublishFolder(stage, to: unrelated))
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("index.html"), encoding: .utf8), "old")
    }

    func testAtomicFileReplacementDoesNotModifySourceSibling() throws {
        let root = try folder(), target = root.appendingPathComponent("report.json"), stage = root.appendingPathComponent("new.json")
        let source = root.appendingPathComponent("original.ulg")
        try Data("original".utf8).write(to: source)
        try Data("previous".utf8).write(to: target)
        try Data("complete".utf8).write(to: stage)
        try ReportExportService.atomicPublishFile(stage, to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "complete")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }

    func testRealCLIPublishesInteractiveHTMLAndIntegralJSONWithManifests() async throws {
        let root = try folder(), (database, configuration) = try fixture(root)
        let engine = resources.appendingPathComponent("analyzer.py")
        let request = ReportExportRequest(query: .init(), mode: .selection, scopeDescription: "Fixture selection")
        let capture = try await ReportExportService.capture(database: database, directory: root.appendingPathComponent("capture"),
            request: request, engine: engine, runtimeConfiguration: configuration)
        let destination = root.appendingPathComponent("report")
        let progress = root.appendingPathComponent("progress.json")
        let result = try await ReportExportService.export(capture: capture, destination: destination, engine: engine, progress: progress, runtimeConfiguration: configuration)
        XCTAssertEqual(result.renderMode, "interactive")
        XCTAssertEqual(result.messageCount, 2)
        let html = try String(contentsOf: result.entryPoint, encoding: .utf8)
        XCTAssertTrue(html.contains("Fixture selection"))
        XCTAssertTrue(html.contains("report-attachments"))
        XCTAssertLessThanOrEqual(html.utf8.count, ReportExportService.htmlBudget)
        let full = try AnalysisService.decode(Data(contentsOf: destination.appendingPathComponent("rapport.json")))
        XCTAssertEqual(full.logs[0].messages.count, 2)
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual((manifest["files"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(manifest["truncated"] as? Bool, false)
        let value = try JSONDecoder().decode(ImportProgress.self, from: Data(contentsOf: progress))
        XCTAssertEqual(value.completed, capture.manifest.totalLogs)
        XCTAssertEqual(value.current, "Rapport publié")
    }

    func testDenseReportFallsBackAndSharedPayloadHasNoPrivateTextInAnyFile() async throws {
        let root = try folder(), (database, configuration) = try fixture(root, messageCount: 5_001)
        let engine = resources.appendingPathComponent("analyzer.py")
        let request = ReportExportRequest(query: .init(), options: .init(excludeCoordinates: true))
        let capture = try await ReportExportService.capture(database: database, directory: root.appendingPathComponent("capture"),
            request: request, engine: engine, runtimeConfiguration: configuration)
        let destination = root.appendingPathComponent("report")
        let result = try await ReportExportService.export(capture: capture, destination: destination, engine: engine, runtimeConfiguration: configuration)
        XCTAssertEqual(result.renderMode, "summary-with-attachments")
        XCTAssertEqual(result.messageCount, 5_001)
        XCTAssertFalse(result.rawDataIncluded)
        for file in try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("PRIVATE-NEEDLE-42"), file.lastPathComponent)
        }
        XCTAssertEqual(try AnalysisService.decode(Data(contentsOf: destination.appendingPathComponent("rapport.json"))).logs[0].messages.count, 5_001)
    }

    func testJSONDestinationIsOneStreamedFileAndDoesNotPublishStaging() async throws {
        let root = try folder(), (database, configuration) = try fixture(root)
        let engine = resources.appendingPathComponent("analyzer.py")
        let request = ReportExportRequest(query: .init(), options: .init(format: .json))
        let capture = try await ReportExportService.capture(database: database, directory: root.appendingPathComponent("capture"),
            request: request, engine: engine, runtimeConfiguration: configuration)
        let destination = root.appendingPathComponent("rapport.json")
        let result = try await ReportExportService.export(capture: capture, destination: destination, engine: engine, runtimeConfiguration: configuration)
        XCTAssertEqual(result.entryPoint, destination)
        XCTAssertEqual(result.renderMode, "json-stream")
        XCTAssertEqual(try AnalysisService.decode(Data(contentsOf: destination)).logs[0].messages.count, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".katalog-report-") })
    }

    func testCancellationKillsUncooperativeHelperAndPreservesPreviousDestination() async throws {
        let root = try folder(), configuration = try runtime()
        let directory = root.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("started")
        let engine = root.appendingPathComponent("slow.py")
        try """
        import signal,time,sys
        from pathlib import Path
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        capture=Path(sys.argv[sys.argv.index('--capture')+1]);(capture/'started').write_text('running')
        time.sleep(30)
        """.write(to: engine, atomically: true, encoding: .utf8)
        let manifest = ReportCaptureManifest(reportVersion: 1, revision: 1, scopeHash: "fixture", captureID: "fixture", capturedAt: "2026-01-01T00:00:00Z", contextSHA256: "fixture", databaseSHA256: "fixture", totalLogs: 1, totalMessages: 1)
        let capture = ReportCapture(directory: directory, manifest: manifest, request: .init(query: .init(), options: .init(format: .json)))
        let destination = root.appendingPathComponent("old.json")
        try Data("previous complete report".utf8).write(to: destination)
        let task = Task { try await ReportExportService.export(capture: capture, destination: destination, engine: engine, runtimeConfiguration: configuration) }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous complete report")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".katalog-report-") })
    }
}
