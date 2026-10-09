import Darwin
import Foundation
import XCTest
@testable import KataLogCore

final class GCSBackpressureTests: XCTestCase {
    private func fixture(count: Int, payloadBytes: Int, fail: Bool = false) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gcs-backpressure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("burst.py"), progress = root.appendingPathComponent("written.txt")
        try """
        import json, sys
        payload = 'x' * \(payloadBytes)
        with open(sys.argv[1], 'w', buffering=1) as progress:
            for i in range(\(count)):
                print(json.dumps({'event': 'inventory_page', 'pageIndex': i, 'message': payload}), flush=True)
                progress.write(str(i + 1) + '\\n')
            print(json.dumps({'event': 'inventory_complete', 'pageCount': \(count)}), flush=True)
            if \(fail ? "True" : "False"):
                print(json.dumps({'event': 'error', 'message': 'synthetic terminal failure'}), flush=True)
                sys.exit(7)
        """.write(to: script, atomically: true, encoding: .utf8)
        return (script, progress)
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    func testSlowConsumerBoundsRealHelperBacklogWithoutLosingPagesOrTerminalError() async throws {
        let count = 512, payload = 64 * 1024
        let (script, progress) = try fixture(count: count, payloadBytes: payload, fail: true)
        let before = residentBytes()
        var iterator = GCSProcessService.events(script: script, arguments: [progress.path]).makeAsyncIterator()
        var pages: [Int] = [], terminals: [String] = []
        for expected in 0..<3 {
            let event = try await iterator.next()
            XCTAssertEqual(event?.pageIndex, expected)
            pages.append(try XCTUnwrap(event?.pageIndex))
            try await Task.sleep(for: .milliseconds(20))
        }
        // Deliberately pause this consumer while the real helper continues its burst.
        try await Task.sleep(for: .seconds(1))
        let produced = try String(contentsOf: progress, encoding: .utf8).split(separator: "\n").last.flatMap { Int($0) } ?? 0
        let after = residentBytes(), delta = after > before ? after - before : 0
        print("GCS_BACKPRESSURE produced=\(produced) consumed=\(pages.count) backlog=\(produced - pages.count) payloadBytes=\(payload) residentDeltaBytes=\(delta)")
        XCTAssertLessThanOrEqual(produced - pages.count, 16, "The real helper must stop writing when the consumer stops; the allowance includes the OS pipe.")
        do {
            while let event = try await iterator.next() {
                if let index = event.pageIndex { pages.append(index) }
                else { terminals.append(event.event) }
            }
            XCTFail("Expected the helper's terminal failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("synthetic terminal failure")) }
        XCTAssertEqual(pages, Array(0..<count))
        XCTAssertEqual(terminals, ["inventory_complete", "error"])
    }

    func testFollowingConsumerMeasuresNormalBurstThroughput() async throws {
        let count = 4_000
        let (script, progress) = try fixture(count: count, payloadBytes: 512)
        var received = 0, began: Date?
        for try await event in GCSProcessService.events(script: script, arguments: [progress.path]) {
            if began == nil { began = Date() }
            if event.event == "inventory_page" {
                XCTAssertEqual(event.pageIndex, received)
                received += 1
            } else { XCTAssertEqual(event.event, "inventory_complete") }
        }
        let seconds = Date().timeIntervalSince(try XCTUnwrap(began))
        print("GCS_THROUGHPUT events=\(received) seconds=\(seconds) eventsPerSecond=\(Double(received) / seconds)")
        XCTAssertEqual(received, count)
        XCTAssertLessThan(seconds, 10, "A following consumer should drain this small burst promptly.")
    }

    private func assertHelperExited(_ pidFile: URL, since start: Date) async throws {
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let deadline = start.addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let status = kill(pid, 0), errorCode = errno
        XCTAssertEqual(status, -1, "The owned helper must be reaped even when it ignores SIGTERM.")
        XCTAssertEqual(errorCode, ESRCH)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testAbandoningIterationKeepsWriterLeaseUntilHelperIsReapedWithoutBlockingConsumerActor() async throws {
        struct ConsumerFailure: Error {}
        for throwsFromBody in [false, true] {
            let (script, pidFile) = try fixture(count: 1, payloadBytes: 0)
            let library = script.deletingLastPathComponent().appendingPathComponent("library")
            var owner: LibraryWriterLease? = try LibraryWriterLease(directory: library)
            XCTAssertTrue(owner?.isWritable == true)
            try """
            import json, os, signal, sys
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(sys.argv[1], 'w').write(str(os.getpid()))
            print('{"event":"connection","connected":true}', flush=True)
            while True: print(json.dumps({'event':'inventory_page','message':'x'*65536}), flush=True)
            """.write(to: script, atomically: true, encoding: .utf8)
            let consumer = Task { @MainActor in
                for try await event in GCSProcessService.events(script: script, arguments: [pidFile.path], writerLibrary: library) {
                    XCTAssertEqual(event.connected, true)
                    if throwsFromBody { throw ConsumerFailure() }
                    break
                }
            }
            do { try await consumer.value; XCTAssertFalse(throwsFromBody) }
            catch { XCTAssertTrue(throwsFromBody && error is ConsumerFailure) }
            // The loop has returned on MainActor while the SIGTERM-ignoring child
            // is still in its grace period. Only the reader/helper copies remain.
            withExtendedLifetime(owner) {}
            owner = nil
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            XCTAssertEqual(kill(pid, 0), 0, "Loop teardown must not wait for the helper on MainActor.")
            XCTAssertFalse(try LibraryWriterLease(directory: library).isWritable)
            try await assertHelperExited(pidFile, since: Date())
            let deadline = Date().addingTimeInterval(2)
            var reacquired: LibraryWriterLease?
            while Date() < deadline {
                let candidate = try LibraryWriterLease(directory: library)
                if candidate.isWritable { reacquired = candidate; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(reacquired?.isWritable == true)
            withExtendedLifetime(reacquired) {}
        }
    }

    func testCancellationStopsBlockedProducerAndProcessThatClosedStdout() async throws {
        // Cover cancellation in next(), a throwing body, and a body that handles
        // its own cancellation before requesting the next collector event.
        for (closedOutput, resumeNext) in [(false, false), (false, true), (true, false)] {
            let (script, pidFile) = try fixture(count: 1, payloadBytes: 0)
            let consumed = script.appendingPathExtension("consumed")
            try """
            import json, os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(sys.argv[1], 'w').write(str(os.getpid()))
            print('{"event":"connection","connected":true}', flush=True)
            if \(closedOutput ? "True" : "False"):
                os.close(1)
                time.sleep(30)
            else:
                while True: print(json.dumps({'event':'inventory_page','message':'x'*65536}), flush=True)
            """.write(to: script, atomically: true, encoding: .utf8)
            let consumer = Task {
                for try await event in GCSProcessService.events(script: script, arguments: [pidFile.path]) {
                    if event.event == "connection" {
                        FileManager.default.createFile(atPath: consumed.path, contents: nil)
                        if !closedOutput {
                            if resumeNext { try? await Task.sleep(for: .seconds(30)) }
                            else { try await Task.sleep(for: .seconds(30)) }
                        }
                    } else {
                        XCTFail("A cancelled consumer must not receive another page.")
                    }
                }
            }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: consumed.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: consumed.path))
            let start = Date(); consumer.cancel()
            do {
                try await consumer.value
                // A next() called on an already-cancelled task may end the stream
                // with nil. The body/active-read variants must still throw.
                XCTAssertTrue(resumeNext)
            }
            catch { XCTAssertTrue(error is CancellationError) }
            try await assertHelperExited(pidFile, since: start)
        }
    }

    func testLargeStderrAndUnterminatedLastEventRemainBoundedAndOrdered() async throws {
        let (script, unused) = try fixture(count: 1, payloadBytes: 0)
        try """
        import sys
        sys.stderr.write('x' * (8 * 1024 * 1024) + 'synthetic stderr tail')
        sys.stderr.flush()
        sys.stdout.write('{"event":"inventory_complete","pageCount":0}')
        sys.stdout.flush()
        sys.exit(3)
        """.write(to: script, atomically: true, encoding: .utf8)
        var events: [String] = []
        do {
            for try await event in GCSProcessService.events(script: script, arguments: [unused.path]) { events.append(event.event) }
            XCTFail("Expected process failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasSuffix("synthetic stderr tail"))
            XCTAssertLessThanOrEqual(error.localizedDescription.count, 1_500)
        }
        XCTAssertEqual(events, ["inventory_complete"])
    }

    func testMalformedOrOversizedFrameStopsOwnedHelper() async throws {
        for oversized in [false, true] {
            let (script, pidFile) = try fixture(count: 1, payloadBytes: 0)
            try """
            import os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(sys.argv[1], 'w').write(str(os.getpid()))
            sys.stdout.write('x' * (4 * 1024 * 1024 + 1) if \(oversized ? "True" : "False") else 'invalid-json\\n')
            sys.stdout.flush()
            time.sleep(30)
            """.write(to: script, atomically: true, encoding: .utf8)
            do {
                for try await _ in GCSProcessService.events(script: script, arguments: [pidFile.path]) { XCTFail("No valid event") }
                XCTFail("Expected invalid frame failure")
            } catch {
                if oversized { XCTAssertTrue(error.localizedDescription.contains("trop volumineuse")) }
                else { XCTAssertTrue(error is DecodingError) }
            }
            try await assertHelperExited(pidFile, since: Date())
        }
    }
}
