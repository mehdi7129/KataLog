import Darwin
import XCTest
@testable import KataLogCore

final class EngineRuntimeTests: XCTestCase {
    private let validInfo = "{\"protocol\":1,\"parserVersion\":\"\(AnalysisService.parserVersion)\",\"python\":\"3.13.0\",\"numpy\":\"2.3.0\",\"pyulog\":\"1.2.2\"}"

    private func folder() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func executable(_ root: URL, name: String = "python", body: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func helper(_ root: URL, body: String? = nil) throws -> URL {
        try executable(root, name: "KataLog.app/Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine",
                       body: body ?? "printf '%s\\n' '\(validInfo)'")
    }

    private func configuration(_ root: URL, required: Bool = true, environment: [String: String] = [:]) -> EngineRuntimeResolver.Configuration {
        .init(bundleURL: root.appendingPathComponent("KataLog.app"), bundledEngineRequired: required,
              environment: environment, externalCandidates: [])
    }

    func testBundledHelperWorksWithoutPATHAndIgnoresExternalOverride() throws {
        let root = try folder(), bundled = try helper(root)
        let config = configuration(root, environment: ["PATH": "", "KATALOG_PYTHON": "/missing/python"])
        let runtime = try EngineRuntimeResolver.resolve(configuration: config)
        XCTAssertEqual(runtime.executableURL, bundled)
        if case .bundled = runtime.kind {} else { XCTFail("Expected bundled runtime") }
    }

    func testInstalledSecondaryCLIInfersItsRequiredBundleWithoutWorkingDirectory() throws {
        let root = try folder(), app = root.appendingPathComponent("KataLog.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "org.example.synthetic.katalog", "KatalogBundledEngineRequired": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let cli = contents.appendingPathComponent("MacOS/katalog-cli")
        XCTAssertEqual(EngineRuntimeResolver.Configuration.distributionBundle(for: cli)?.path, app.path)
        XCTAssertNil(EngineRuntimeResolver.Configuration.distributionBundle(for: contents.appendingPathComponent("MacOS/unrelated-tool")))
        XCTAssertNil(EngineRuntimeResolver.Configuration.distributionBundle(for: root.appendingPathComponent("katalog-cli")))
        try PropertyListSerialization.data(fromPropertyList: ["KatalogBundledEngineRequired": false], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertNil(EngineRuntimeResolver.Configuration.distributionBundle(for: cli))
    }

    func testRequiredMissingHelperDoesNotFallBackToValidExternalRuntime() throws {
        let root = try folder()
        let external = try executable(root, body: "printf '%s\\n' '\(validInfo)'")
        var config = configuration(root, environment: ["KATALOG_PYTHON": external.path])
        config.externalCandidates = [external]
        XCTAssertThrowsError(try EngineRuntimeResolver.resolve(configuration: config)) {
            XCTAssertTrue($0.localizedDescription.contains("Réinstallez KataLog"))
        }
    }

    func testInvalidBundledHandshakeCannotFallBack() throws {
        let root = try folder()
        let external = try executable(root, body: "printf '%s\\n' '\(validInfo)'")
        var config = configuration(root, required: false, environment: ["KATALOG_PYTHON": external.path])
        config.externalCandidates = [external]
        for info in [validInfo.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":2"),
                     validInfo.replacingOccurrences(of: AnalysisService.parserVersion, with: "0.1.0"),
                     validInfo.replacingOccurrences(of: "\"numpy\":\"2.3.0\"", with: "\"numpy\":\"\""),
                     "{}", "not json"] {
            _ = try helper(root, body: "printf '%s\\n' '\(info)'")
            XCTAssertThrowsError(try EngineRuntimeResolver.resolve(configuration: config)) {
                XCTAssertTrue($0.localizedDescription.contains("Réinstallez KataLog"))
            }
        }
    }

    func testBundledHelperMustBeExecutableAndExitSuccessfully() throws {
        let root = try folder(), bundled = try helper(root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundled.path)
        XCTAssertThrowsError(try EngineRuntimeResolver.resolve(configuration: configuration(root)))
        _ = try helper(root, body: "printf '%s\\n' '\(validInfo)'\nexit 3")
        XCTAssertThrowsError(try EngineRuntimeResolver.resolve(configuration: configuration(root)))
    }

    func testExplicitDevelopmentOverrideUsesSanitizedEnvironment() throws {
        let root = try folder()
        let external = try executable(root, body: """
            test -z "${PYTHONHOME+x}" || exit 2
            test -z "${PYTHONPATH+x}" || exit 2
            test -z "${VIRTUAL_ENV+x}" || exit 2
            test -z "${__PYVENV_LAUNCHER__+x}" || exit 2
            test "$PYTHONDONTWRITEBYTECODE" = 1 || exit 2
            test "$PYTHONNOUSERSITE" = 1 || exit 2
            test "$HOME" = /home/synthetic || exit 2
            printf '%s\\n' '\(validInfo)'
            """)
        let config = EngineRuntimeResolver.Configuration(environment: ["KATALOG_PYTHON": external.path,
            "PYTHONHOME": "/bad", "PYTHONPATH": "/bad", "VIRTUAL_ENV": "/bad", "__PYVENV_LAUNCHER__": "/bad",
            "HOME": "/home/synthetic"], externalCandidates: [])
        let runtime = try EngineRuntimeResolver.resolve(configuration: config)
        XCTAssertEqual(runtime.executableURL, external)
        if case .development = runtime.kind {} else { XCTFail("Expected development override") }
    }

    func testBrokenDevelopmentOverrideFailsWithoutSilentFallback() throws {
        let root = try folder()
        let working = try executable(root, body: "printf '%s\\n' '\(validInfo)'")
        let config = EngineRuntimeResolver.Configuration(environment: ["KATALOG_PYTHON": "/missing/python"], externalCandidates: [working])
        XCTAssertThrowsError(try EngineRuntimeResolver.resolve(configuration: config)) {
            XCTAssertTrue($0.localizedDescription.contains("KATALOG_PYTHON"))
        }
    }

    func testDevelopmentSearchRejectsRuntimeWithoutDependencies() throws {
        let root = try folder()
        let broken = try executable(root, name: "broken", body: "exit 1")
        let working = try executable(root, name: "working", body: "printf '%s\\n' '\(validInfo)'")
        let config = EngineRuntimeResolver.Configuration(environment: [:], externalCandidates: [broken, working])
        XCTAssertEqual(try EngineRuntimeResolver.resolve(configuration: config).executableURL, working)
    }

    func testEnvironmentClearsPythonAndDynamicLoaderInjection() {
        let source = ["PYTHONHOME": "/bad", "PYTHONPATH": "/bad", "PYTHONSTARTUP": "/bad",
                      "DYLD_LIBRARY_PATH": "/bad", "DYLD_INSERT_LIBRARIES": "/bad", "LD_PRELOAD": "/bad",
                      "CONDA_PREFIX": "/bad", "VIRTUAL_ENV": "/bad", "KATALOG_PYTHON": "/bad",
                      "HOME": "/home/synthetic", "PATH": "", "LANG": "fr_FR.UTF-8"]
        let cleaned = EngineRuntimeResolver.sanitizedEnvironment(source)
        for key in source.keys where !["HOME", "PATH", "LANG"].contains(key) { XCTAssertNil(cleaned[key], key) }
        XCTAssertEqual(cleaned["HOME"], source["HOME"])
        XCTAssertEqual(cleaned["PYTHONDONTWRITEBYTECODE"], "1")
    }

    func testOversizedHandshakeFailsWithoutPipeDeadlock() throws {
        let root = try folder()
        _ = try helper(root, body: "/usr/bin/head -c 70000 /dev/zero")
        let start = Date()
        XCTAssertThrowsError(try EngineRuntimeResolver.resolve(configuration: configuration(root)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testUnresponsiveHandshakeHasBoundedTimeout() throws {
        let root = try folder()
        _ = try helper(root, body: "exec /bin/sleep 30")
        let start = Date()
        XCTAssertThrowsError(try EngineRuntimeResolver.resolve(configuration: configuration(root)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 12)
    }

    func testImportAndCollectionExecuteTheSameBundledRuntime() async throws {
        let root = try folder()
        let snapshot = root.appendingPathComponent("synthetic-snapshot.json")
        try JSONEncoder().encode(FleetSnapshot.empty).write(to: snapshot)
        let detail = root.appendingPathComponent("synthetic-detail.json")
        let flight = FlightLog(id: "synthetic-log", droneID: "synthetic-drone", droneName: "Drone de test",
            date: "", dateSource: "", sourcePaths: [], fileName: "synthetic.ulg", sizeBytes: 0,
            durationSeconds: 0, flightSeconds: nil, status: "ok", issues: [], metadata: [:], topics: [],
            messages: [], metrics: [], coverage: [], failsafeObserved: false)
        try JSONEncoder().encode(flight).write(to: detail)
        _ = try helper(root, body: """
            if [ "$1" = --katalog-runtime-info ]; then
                printf '%s\\n' '\(validInfo)'
                exit 0
            fi
            test -z "${PYTHONPATH+x}" || exit 3
            test "$PYTHONDONTWRITEBYTECODE" = 1 || exit 3
            source="$KATALOG_TEST_SNAPSHOT"
            for argument do
                case "$argument" in
                    *gcs_collect.py) printf '%s\\n' '{"event":"connection","connected":true}'; exit 0 ;;
                    detail) source="$KATALOG_TEST_DETAIL" ;;
                esac
            done
            while [ "$#" -gt 0 ]; do
                if [ "$1" = --output ]; then
                    shift
                    /bin/cp "$source" "$1"
                    exit $?
                fi
                shift
            done
            exit 4
            """)
        let config = configuration(root, environment: ["PATH": "", "KATALOG_PYTHON": "/missing/python",
            "PYTHONPATH": "/bad", "KATALOG_TEST_SNAPSHOT": snapshot.path, "KATALOG_TEST_DETAIL": detail.path])
        let analyzer = root.appendingPathComponent("analyzer.py"), collector = root.appendingPathComponent("gcs_collect.py")
        try Data().write(to: analyzer); try Data().write(to: collector)
        let database = root.appendingPathComponent("library.sqlite")
        let imported = try await AnalysisService.scan(folder: root, database: database,
            output: root.appendingPathComponent("scan.json"), progress: root.appendingPathComponent("progress.json"),
            engine: analyzer, runtimeConfiguration: config)
        XCTAssertEqual(imported.schemaVersion, 1)
        let saved = try await AnalysisService.snapshot(database: database, engine: analyzer, runtimeConfiguration: config)
        XCTAssertEqual(saved.logs.count, 0)
        let loaded = try await AnalysisService.detail(logID: flight.id, database: database, engine: analyzer,
                                                    runtimeConfiguration: config)
        XCTAssertEqual(loaded.id, flight.id)
        XCTAssertEqual(loaded.droneID, flight.droneID)
        var connections = 0
        for try await event in GCSProcessService.events(script: collector, arguments: [], runtimeConfiguration: config) {
            if event.connected == true { connections += 1 }
        }
        XCTAssertEqual(connections, 1)
    }

    func testRequiredEngineErrorsAreIdenticalForAnalysisAndCollection() async throws {
        let root = try folder(), config = configuration(root)
        let script = root.appendingPathComponent("analyzer.py")
        try Data().write(to: script)
        var analysisMessage = ""
        do {
            _ = try await AnalysisService.snapshot(database: root.appendingPathComponent("library.sqlite"),
                                                   engine: script, runtimeConfiguration: config)
            XCTFail("Expected missing bundled engine")
        } catch { analysisMessage = error.localizedDescription }
        do {
            for try await _ in GCSProcessService.events(script: script, arguments: [], runtimeConfiguration: config) {}
            XCTFail("Expected missing bundled engine")
        } catch { XCTAssertEqual(error.localizedDescription, analysisMessage) }
        XCTAssertTrue(analysisMessage.contains("Réinstallez KataLog"))
    }

    func testCancellationStopsHandshakeProcess() async throws {
        let root = try folder()
        _ = try helper(root, body: "exec /bin/sleep 30")
        let analyzer = root.appendingPathComponent("analyzer.py")
        try Data().write(to: analyzer)
        let config = configuration(root)
        let task = Task {
            try await AnalysisService.snapshot(database: root.appendingPathComponent("library.sqlite"),
                                               engine: analyzer, runtimeConfiguration: config)
        }
        try await Task.sleep(for: .milliseconds(150))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testAnalysisCancellationDrainsWritingHelperAndReleasesItsInheritedLease() async throws {
        let root = try folder(), marker = root.appendingPathComponent("writing-helper.pid")
        _ = try helper(root, body: """
            if [ "$1" = --katalog-runtime-info ]; then
                printf '%s\\n' '\(validInfo)'; exit 0
            fi
            trap '' TERM
            printf '%s' "$$" > "$KATALOG_TEST_PID"
            while :; do :; done
            """)
        let analyzer = root.appendingPathComponent("analyzer.py")
        try Data().write(to: analyzer)
        let config = configuration(root, environment: ["PATH": "", "KATALOG_TEST_PID": marker.path])
        var writer: LibraryWriterLease? = try LibraryWriterLease(directory: root)
        XCTAssertTrue(writer!.isWritable)
        let task = Task {
            try await AnalysisService.run(["scan", "--database", root.appendingPathComponent("library.sqlite").path],
                                          engine: analyzer, runtimeConfiguration: config)
        }
        defer { task.cancel() }
        let pid = try await helperPID(from: marker)
        writer = nil
        XCTAssertFalse(try LibraryWriterLease(directory: root).isWritable,
                       "The helper must retain the lease after the app-side owner is gone")
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let nextWriter = try LibraryWriterLease(directory: root)
        XCTAssertTrue(nextWriter.isWritable)
        withExtendedLifetime(nextWriter) {}
    }

    func testCollectionCancellationDrainsHelperThatKeepsItsOutputOpen() async throws {
        let root = try folder(), marker = root.appendingPathComponent("collection-helper.pid")
        _ = try helper(root, body: """
            if [ "$1" = --katalog-runtime-info ]; then
                printf '%s\\n' '\(validInfo)'; exit 0
            fi
            trap '' TERM
            printf '%s' "$$" > "$KATALOG_TEST_PID"
            while :; do :; done
            """)
        let collector = root.appendingPathComponent("gcs_collect.py")
        try Data().write(to: collector)
        let config = configuration(root, environment: ["PATH": "", "KATALOG_TEST_PID": marker.path])
        var writer: LibraryWriterLease? = try LibraryWriterLease(directory: root)
        XCTAssertTrue(writer!.isWritable)
        let task = Task {
            for try await _ in GCSProcessService.events(script: collector, arguments: [], writerLibrary: root, runtimeConfiguration: config) {}
        }
        defer { task.cancel() }
        let pid = try await helperPID(from: marker)
        writer = nil
        XCTAssertFalse(try LibraryWriterLease(directory: root).isWritable)
        let start = Date()
        task.cancel()
        _ = try? await task.value
        let deadline = start.addingTimeInterval(1.5)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        // Stream cancellation resumes its consumer before the detached reader
        // finishes. A reaped child does not prove that the reader's defer has
        // closed the parent-side lease duplicate. Require both within one bound.
        var nextWriter = try LibraryWriterLease(directory: root)
        while !nextWriter.isWritable, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            nextWriter = try LibraryWriterLease(directory: root)
        }
        XCTAssertTrue(nextWriter.isWritable, "The cancelled reader must release its inherited lease within the cancellation deadline.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        withExtendedLifetime(nextWriter) {}
    }

    func testCollectionChildKeepsExactWriterLeaseAfterItsImmediateParentExits() async throws {
        let root = try folder()
        let childCode = #"""
        import pathlib,sys,time
        root=pathlib.Path(sys.argv[1])
        (root/'child-ready.pid').write_text(str(__import__('os').getpid()))
        time.sleep(.6)
        (root/'child-writing').write_text('written after parent exit')
        time.sleep(.6)
        (root/'child-finished').write_text('done')
        """#
        let parentCode = """
        import os,subprocess,sys
        subprocess.Popen([sys.executable,'-B','-c',\(String(reflecting: childCode)),sys.argv[1]],stdin=sys.stdin,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,close_fds=True)
        os._exit(0)
        """
        let python = root.appendingPathComponent("parent.py")
        try parentCode.write(to: python, atomically: true, encoding: .utf8)
        _ = try helper(root, body: """
            if [ "$1" = --katalog-runtime-info ]; then
                printf '%s\\n' '\(validInfo)'; exit 0
            fi
            for argument do
                test "$argument" != --library || exit 4
            done
            exec /usr/bin/python3 "$KATALOG_TEST_PARENT" "$KATALOG_TEST_ROOT"
            """)
        let collector = root.appendingPathComponent("gcs_collect.py")
        try Data().write(to: collector)
        var writer: LibraryWriterLease? = try LibraryWriterLease(directory: root)
        let config = configuration(root, environment: ["PATH": "", "KATALOG_TEST_PARENT": python.path, "KATALOG_TEST_ROOT": root.path])
        for try await _ in GCSProcessService.events(script: collector, arguments: ["inventory"], writerLibrary: root, runtimeConfiguration: config) {}
        // GCS helper has exited without cleanup. Both app-side FD copies are
        // now closed, so only inherited child stdin can retain this lease.
        writer = nil
        let pid = try await helperPID(from: root.appendingPathComponent("child-ready.pid"))
        XCTAssertFalse(try LibraryWriterLease(directory: root).isWritable)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("child-writing").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("child-finished").path))
        let nextWriter = try LibraryWriterLease(directory: root)
        XCTAssertTrue(nextWriter.isWritable)
        withExtendedLifetime(nextWriter) {}
        withExtendedLifetime(writer) {}
    }

    private func helperPID(from marker: URL) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = pid_t(text) { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AnalysisError.engine("Le helper de test n’a pas démarré.")
    }
}
