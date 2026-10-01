import XCTest
import CryptoKit
@testable import KataLogCore

final class DiagnosticBundleTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-diagnostic-bundle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func report() -> DiagnosticReport {
        DiagnosticReport(appVersion: "0.6.1", appBuild: "15", operations: ["collection": false], counts: ["logs": 2], runtimeBundled: true)
    }
    private func snapshot() throws -> DiagnosticJournalSnapshot {
        let journal = DiagnosticJournal(directory: try directory(), configuration: .init(persistent: false))
        journal.record(.transferStarted, phase: .drone, correlation: "secret-drone-uuid")
        journal.record(.transferCompleted, phase: .http, metrics: [.bytes: 100])
        return try journal.snapshot()
    }
    private func extract(_ zip: URL, to directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run(); ProcessLifetime.wait(for: process)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testConservativeGCSProjectionNeverRetainsFreeTextOrPrivateValues() {
        let text = """
        2026-09-30T11:30:00Z ERROR mqtt disconnected user Alice missionPrivate http://192.0.2.1 /Users/example/Alice password=secret
        2026-09-30 11:30:02 WARNING ftp download timeout lat=43.7 lon=7.25 UUID=A1B2C3D4E5F60718293A4B5 email=alice@example.com
        2026-09-30T11:30:05Z HTTP 503 connection failure token=private-token
        arbitrary private-person unpublished-show 1234
        """
        let redacted = DiagnosticTextRedactor.sanitize(text, source: .python)
        for privateValue in ["Alice", "missionPrivate", "192.0.2", "/Users", "password", "secret", "43.7", "7.25", "A1B2C3", "alice@example", "private-token", "unpublished-show", "1234"] {
            XCTAssertFalse(redacted.contains(privateValue), privateValue)
        }
        XCTAssertTrue(redacted.contains("MQTT"))
        XCTAssertTrue(redacted.contains("délai dépassé"))
        XCTAssertTrue(redacted.contains("HTTP 503"))
    }

    func testDefaultArchiveContainsSnapshotChronologyManifestAndRedactedServices() async throws {
        let directory = try directory()
        let target = directory.appendingPathComponent("diagnostic.zip")
        let service = DiagnosticGCSText(source: .python, text: "ERROR download failed private-user 192.0.2.1")
        let result = try await DiagnosticBundle.export(to: target, report: report(), journal: snapshot(), gcs: [service])
        XCTAssertFalse(result.privateDataIncluded)
        XCTAssertEqual(result.fileCount, 5)
        let extracted = directory.appendingPathComponent("extracted")
        try extract(target, to: extracted)
        let gcs = try String(contentsOf: extracted.appendingPathComponent("gcs/python.log"), encoding: .utf8)
        XCTAssertFalse(gcs.contains("private-user")); XCTAssertFalse(gcs.contains("192.0.2"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: extracted.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["privateDataIncluded"] as? Bool, false)
        XCTAssertEqual(manifest["eventCount"] as? Int, 2)
        let entries = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 4, "The manifest hashes its attachments without a circular hash of itself.")
        for entry in entries {
            let name = try XCTUnwrap(entry["name"] as? String)
            XCTAssertFalse(name.contains("..")); XCTAssertFalse(name.hasPrefix("/"))
            let data = try Data(contentsOf: extracted.appendingPathComponent(name))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(entry["sha256"] as? String, digest)
            XCTAssertEqual(entry["sizeBytes"] as? Int, data.count)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["diagnostic.zip", "extracted"])
    }

    func testPrivateULogSelectionDoesNotUnmaskGCSAndHidesOriginalFilename() async throws {
        let directory = try directory()
        let source = directory.appendingPathComponent("Alice-private-drone.ulg")
        let data = Data([0x55, 0x4c, 0x6f, 0x67, 1, 2, 3])
        try data.write(to: source)
        let target = directory.appendingPathComponent("diagnostic.zip")
        let service = DiagnosticGCSText(source: .node, text: "ERROR private-account transfer failed")
        let preview = try DiagnosticBundle.preview(report: report(), journal: snapshot(), gcs: [service], privateULogs: [source])
        XCTAssertTrue(preview.privateDataIncluded)
        XCTAssertTrue(preview.fileNames.contains("ulog/0001.ulg"))
        XCTAssertFalse(preview.fileNames.contains(where: { $0.contains("Alice") }))
        _ = try await DiagnosticBundle.export(to: target, report: report(), journal: snapshot(), gcs: [service], privateULogs: [source])
        let extracted = directory.appendingPathComponent("extracted")
        try extract(target, to: extracted)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("ulog/0001.ulg")), data)
        XCTAssertFalse(try String(contentsOf: extracted.appendingPathComponent("gcs/node.log"), encoding: .utf8).contains("private-account"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: extracted.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["gcsRawTextIncluded"] as? Bool, false)
        XCTAssertEqual(manifest["privateDataIncluded"] as? Bool, true)
    }

    func testPrivateGCSTextRequiresItsIndependentOptIn() async throws {
        let directory = try directory()
        let target = directory.appendingPathComponent("diagnostic.zip")
        let service = DiagnosticGCSText(source: .reactor, text: "original private data")
        _ = try await DiagnosticBundle.export(to: target, report: report(), journal: snapshot(), gcs: [service], includePrivateGCS: true)
        let extracted = directory.appendingPathComponent("extracted")
        try extract(target, to: extracted)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("gcs/reactor.log"), encoding: .utf8), service.text)
    }

    func testInvalidAttachmentDuplicateAndSymlinkAreRejected() throws {
        let directory = try directory()
        let wrong = directory.appendingPathComponent("passwords.txt")
        try Data("private".utf8).write(to: wrong)
        XCTAssertThrowsError(try DiagnosticBundle.preview(report: report(), journal: snapshot(), privateULogs: [wrong]))
        let log = directory.appendingPathComponent("flight.ulg")
        try Data("data".utf8).write(to: log)
        XCTAssertThrowsError(try DiagnosticBundle.preview(report: report(), journal: snapshot(), privateULogs: [log, log]))
        let symlink = directory.appendingPathComponent("link.ulg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: log)
        XCTAssertThrowsError(try DiagnosticBundle.preview(report: report(), journal: snapshot(), privateULogs: [symlink]))
    }

    func testDuplicateServiceAndSizeLimitsAreRejected() throws {
        let service = DiagnosticGCSText(source: .python, text: "ERROR")
        XCTAssertThrowsError(try DiagnosticBundle.preview(report: report(), journal: snapshot(), gcs: [service, service]))
        let huge = DiagnosticGCSText(source: .python, text: String(repeating: "x", count: 8 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try DiagnosticBundle.preview(report: report(), journal: snapshot(), gcs: [huge]))
    }

    func testCancelledExportPreservesPreviousDestinationAndLeavesNoStagingFiles() async throws {
        let directory = try directory()
        let target = directory.appendingPathComponent("diagnostic.zip")
        let previous = Data("previous valid export".utf8)
        try previous.write(to: target)
        let report = report(), snapshot = try snapshot()
        let task = Task { try await DiagnosticBundle.export(to: target, report: report, journal: snapshot) }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled task must not export.") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: target), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["diagnostic.zip"])
    }

    func testCancellationAfterStagingStartsRemovesPartialArchive() async throws {
        let initialProcessCount = EngineOperations.activeProcessCount
        let directory = try directory()
        let source = directory.appendingPathComponent("large.ulg")
        let writer = FileManager.default.createFile(atPath: source.path, contents: nil)
        XCTAssertTrue(writer)
        let handle = try FileHandle(forWritingTo: source)
        let chunk = Data(repeating: 0x57, count: 1024 * 1024)
        for _ in 0..<64 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let target = directory.appendingPathComponent("diagnostic.zip")
        let previous = Data("previous export".utf8)
        try previous.write(to: target)
        let report = report(), snapshot = try snapshot()
        let task = Task { try await DiagnosticBundle.export(to: target, report: report, journal: snapshot, privateULogs: [source]) }
        var stageFound = false
        for _ in 0..<500 {
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".katalog-diagnostic-") }) {
                stageFound = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(stageFound)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation after staging must abort export.") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: target), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["diagnostic.zip", "large.ulg"])
        XCTAssertEqual(EngineOperations.activeProcessCount, initialProcessCount)
    }

    func testCompletedExportAtomicallyReplacesPreviousFile() async throws {
        let directory = try directory()
        let target = directory.appendingPathComponent("diagnostic.zip")
        try Data("old export".utf8).write(to: target)
        let result = try await DiagnosticBundle.export(to: target, report: report(), journal: snapshot())
        XCTAssertEqual(result.url, target)
        XCTAssertEqual(Array(try Data(contentsOf: target).prefix(2)), [0x50, 0x4B])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["diagnostic.zip"])
    }

    func testMetadataAndMutableReportAreProjectedThroughAllowlists() async throws {
        let directory = try directory()
        let target = directory.appendingPathComponent("diagnostic.zip")
        let metadata = DiagnosticGCSText(source: .metadata, text: "{\"gcsVersion\":\"3.7.2\",\"temperature\":42.5,\"frontSha\":\"\(String(repeating: "a", count: 40))\",\"hostname\":\"private-person\",\"account\":\"private@example.com\"}")
        let projected = DiagnosticTextRedactor.sanitize(metadata.text, source: .metadata)
        XCTAssertTrue(projected.contains("3.7.2")); XCTAssertTrue(projected.contains("42.5"))
        XCTAssertFalse(projected.contains("private-person")); XCTAssertFalse(projected.contains("private@example"))
        var maliciousReport = report()
        maliciousReport.appVersion = "private-person"
        maliciousReport.appBuild = "/Users/example/private"
        maliciousReport.osVersion = "private-ip"
        maliciousReport.architecture = "private-machine"
        maliciousReport.parserVersion = "private-parser"
        maliciousReport.operations["private-key"] = true
        maliciousReport.counts["private-key"] = 12
        _ = try await DiagnosticBundle.export(to: target, report: maliciousReport, journal: snapshot(), gcs: [metadata])
        let extracted = directory.appendingPathComponent("extracted")
        try extract(target, to: extracted)
        let snapshotText = try String(contentsOf: extracted.appendingPathComponent("snapshot.json"), encoding: .utf8)
        for privateValue in ["private-person", "/Users", "private-ip", "private-machine", "private-parser", "private-key"] {
            XCTAssertFalse(snapshotText.contains(privateValue))
        }
        XCTAssertTrue(snapshotText.contains("unknown"))
    }

    func testInvalidDestinationDoesNotOverwriteSourceAttachment() async throws {
        let directory = try directory()
        let target = directory.appendingPathComponent("source.ulg")
        let previous = Data("source".utf8)
        try previous.write(to: target)
        do {
            _ = try await DiagnosticBundle.export(to: target, report: report(), journal: snapshot())
            XCTFail("Only ZIP destinations are accepted.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: target), previous)
    }
}
