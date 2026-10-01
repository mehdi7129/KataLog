import XCTest
@testable import KataLogCore

final class DiagnosticJournalTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-diagnostic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testPersistenceReopenCorrelationsAndPrivacy() throws {
        let directory = try directory()
        let raw = "A1B2C3D4E5F60718293A4B5 /Users/example/secret-folder/log.ulg http://192.0.2.1 password=secret"
        let journal = DiagnosticJournal(directory: directory)
        journal.record(.transferStarted, phase: .drone, correlation: raw, metrics: [.bytes: 4, .totalBytes: 10])
        journal.record(.transferProgress, phase: .http, correlation: raw, metrics: [.bytes: 7])
        let events = try journal.snapshot().events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].correlationID, events[1].correlationID)
        XCTAssertEqual(events.map(\.phase), [.drone, .http])
        XCTAssertLessThanOrEqual(events[0].elapsedMilliseconds, events[1].elapsedMilliseconds)
        let reopened = DiagnosticJournal(directory: directory)
        reopened.record(.transferCompleted, correlation: raw)
        let snapshot = try reopened.snapshot()
        XCTAssertEqual(snapshot.events.count, 3)
        XCTAssertNotEqual(snapshot.events[0].correlationID, snapshot.events[2].correlationID)
        XCTAssertNotEqual(snapshot.events[0].sessionID, snapshot.events[2].sessionID)
        let contents = String(decoding: try snapshot.jsonLines(), as: UTF8.self)
        for privateValue in [raw, "A1B2C3D4E5F60718293A4B5", "/Users", "secret-folder", "192.0.2", "secret"] {
            XCTAssertFalse(contents.contains(privateValue))
        }
    }

    func testConcurrentWritersProduceCompleteRecords() throws {
        let journal = DiagnosticJournal(directory: try directory(), configuration: .init(maximumFileBytes: 1024 * 1024))
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            journal.record(.transferProgress, correlation: "job-\(index)", metrics: [.bytes: Int64(index)])
        }
        let snapshot = try journal.snapshot()
        XCTAssertEqual(snapshot.events.count, 200)
        XCTAssertEqual(snapshot.corruptedLineCount, 0)
        XCTAssertEqual(Set(snapshot.events.compactMap { $0.metrics[.bytes] }).count, 200)
    }

    func testRotationIsBoundedAndKeepsNewestRecords() throws {
        let directory = try directory()
        let journal = DiagnosticJournal(directory: directory, configuration: .init(maximumFileBytes: 1024, maximumArchives: 2))
        for index in 0..<50 { journal.record(.transferProgress, metrics: [.bytes: Int64(index)]) }
        let snapshot = try journal.snapshot()
        XCTAssertLessThan(snapshot.events.count, 50)
        XCTAssertEqual(snapshot.events.last?.metrics[.bytes], 49)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertTrue(try files.allSatisfy { (try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 })
    }

    func testZeroArchivesRetainsOnlyCurrentFile() throws {
        let directory = try directory()
        let journal = DiagnosticJournal(directory: directory, configuration: .init(maximumFileBytes: 1024, maximumArchives: 0))
        for index in 0..<20 { journal.record(.cacheHit, metrics: [.items: Int64(index)]) }
        XCTAssertEqual(try journal.snapshot().events.last?.metrics[.items], 19)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["events.jsonl"])
    }

    func testCorruptedAndTruncatedLinesAreSkippedAndNextEventSurvives() throws {
        let directory = try directory()
        let journal = DiagnosticJournal(directory: directory)
        journal.record(.appStarted)
        _ = try journal.snapshot()
        let current = directory.appendingPathComponent("events.jsonl")
        let writer = try FileHandle(forWritingTo: current)
        try writer.seekToEnd(); try writer.write(contentsOf: Data("not-json\n{\"truncated\":true".utf8)); try writer.close()
        let reopened = DiagnosticJournal(directory: directory)
        reopened.record(.gcsConnected)
        let snapshot = try reopened.snapshot()
        XCTAssertEqual(snapshot.events.map(\.kind), [.appStarted, .gcsConnected])
        XCTAssertEqual(snapshot.corruptedLineCount, 2)
    }

    func testUntrustedStructuredFieldsAreRejectedOnRead() throws {
        let directory = try directory()
        let journal = DiagnosticJournal(directory: directory)
        journal.record(.appStarted)
        let event = try journal.snapshot().events[0]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
        object["correlationID"] = "/Users/example/secret-folder"
        var data = try JSONSerialization.data(withJSONObject: object); data.append(0x0A)
        try data.write(to: directory.appendingPathComponent("events.jsonl"))
        let snapshot = try journal.snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.corruptedLineCount, 1)
    }

    func testAgeRetentionRemovesExpiredFileAndExpiredEventsInFreshFile() throws {
        let directory = try directory()
        let journal = DiagnosticJournal(directory: directory, configuration: .init(maximumAge: 60))
        journal.record(.appStarted)
        let event = try journal.snapshot().events[0]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
        old["timestamp"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
        var mixed = try JSONSerialization.data(withJSONObject: old); mixed.append(0x0A)
        mixed.append(try encoder.encode(event)); mixed.append(0x0A)
        let current = directory.appendingPathComponent("events.jsonl")
        try mixed.write(to: current)
        XCTAssertEqual(try journal.snapshot().events.count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: current), as: UTF8.self).contains(old["timestamp"] as! String))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: current.path)
        XCTAssertTrue(try journal.snapshot().events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    func testClearDoesNotRemoveOtherFilesAndJournalCanContinue() throws {
        let directory = try directory()
        let protected = directory.appendingPathComponent("flight.ulg")
        try Data("untouched".utf8).write(to: protected)
        let journal = DiagnosticJournal(directory: directory)
        journal.record(.appStarted)
        _ = try journal.snapshot()
        try journal.clear()
        XCTAssertTrue(try journal.snapshot().events.isEmpty)
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "untouched")
        journal.record(.gcsConnected)
        XCTAssertEqual(try journal.snapshot().events.map(\.kind), [.gcsConnected])
    }

    func testMemoryOnlyModeNeverCreatesDirectory() throws {
        let path = try directory().appendingPathComponent("not-created")
        let journal = DiagnosticJournal(directory: path, configuration: .init(persistent: false))
        journal.record(.appStarted)
        XCTAssertEqual(try journal.snapshot().events.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        try journal.clear()
        XCTAssertTrue(try journal.snapshot().events.isEmpty)
    }

    func testTerminalTransferTitlesDistinguishSuccessStopAndFailure() throws {
        let journal = DiagnosticJournal(directory: try directory(), configuration: .init(persistent: false))
        journal.record(.transferCompleted)
        journal.record(.transferCompleted, code: .cancelled)
        journal.record(.transferCompleted, code: .verificationFailed)
        let events = try journal.snapshot().events
        XCTAssertEqual(events.map(\.title), ["Transfert terminé", "Transfert arrêté", "Échec du transfert"])
        XCTAssertFalse(events[1].previewLine.contains("Transfert terminé"))
        XCTAssertFalse(events[2].previewLine.contains("Transfert terminé"))
        XCTAssertTrue(events[2].previewLine.contains("Fichier non validé"))
    }

    func testUnavailableStorageDoesNotCrashRecordAndReportsDroppedEvents() throws {
        let directory = try directory().appendingPathComponent("file")
        try Data("protected".utf8).write(to: directory)
        let journal = DiagnosticJournal(directory: directory)
        journal.record(.appStarted)
        XCTAssertThrowsError(try journal.snapshot())
        XCTAssertEqual(try String(contentsOf: directory, encoding: .utf8), "protected")
    }

    func testSymlinkJournalCannotWriteOrClearTarget() throws {
        let directory = try directory()
        let protected = directory.appendingPathComponent("protected.txt")
        try Data("untouched".utf8).write(to: protected)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("events.jsonl"), withDestinationURL: protected)
        let journal = DiagnosticJournal(directory: directory)
        journal.record(.appStarted)
        XCTAssertThrowsError(try journal.snapshot())
        XCTAssertThrowsError(try journal.clear())
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "untouched")
    }
}
