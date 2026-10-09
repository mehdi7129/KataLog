import Foundation
import XCTest
@testable import KataLogCore

final class ProcessLifetimeTests: XCTestCase {
    func testTerminationCancelsRegisteredHelpersAndClosesLaunchGateOnlyForOwnedRegistry() async throws {
        let registry = EngineOperationRegistry()
        let control = ProcessLifetime(grace: 0.1, registry: registry)
        let owned = Process(), output = Pipe(), unrelated = Process()
        owned.executableURL = URL(fileURLWithPath: "/bin/sh")
        owned.arguments = ["-c", "trap '' TERM; printf ready; while :; do :; done"]
        owned.standardOutput = output; owned.standardError = FileHandle.nullDevice
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["5"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            ProcessLifetime.wait(for: unrelated)
            control.cleanup()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        try control.run(owned)
        XCTAssertNotNil(try control.readChunk(from: output.fileHandleForReading))
        XCTAssertEqual(registry.activeProcessCount, 1)
        registry.beginTermination()
        let rejected = Process(); rejected.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try ProcessLifetime(registry: registry).run(rejected)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(rejected.isRunning)
        XCTAssertEqual(registry.activeProcessCount, 1, "Keep the helper registered until it has been reaped")
        await Task.detached { ProcessLifetime.wait(for: owned) }.value
        XCTAssertEqual(owned.terminationStatus, SIGKILL)
        XCTAssertTrue(unrelated.isRunning, "Never terminate an unregistered process")
        XCTAssertThrowsError(try control.finish()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(registry.activeProcessCount, 0)
    }

    func testCancelledQuitReopensLaunchGateOnlyAfterOwnedHelpersHaveDrained() async throws {
        let registry = EngineOperationRegistry(), process = Process()
        let control = ProcessLifetime(registry: registry)
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["5"]
        try control.run(process)
        defer { control.cleanup() }
        registry.beginTermination()
        XCTAssertFalse(registry.cancelTermination(), "A registered helper still owns the interrupted operation.")
        let late = Process(); late.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try ProcessLifetime(registry: registry).run(late)) { XCTAssertTrue($0 is CancellationError) }
        await Task.detached { ProcessLifetime.wait(for: process) }.value
        XCTAssertThrowsError(try control.finish()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(registry.cancelTermination())
        let resumed = ProcessLifetime(registry: registry)
        try resumed.run(late)
        await Task.detached { ProcessLifetime.wait(for: late) }.value
        XCTAssertEqual(late.terminationStatus, 0)
        try resumed.finish()
        XCTAssertEqual(registry.activeProcessCount, 0)
    }

    func testFailedLaunchAndExceptionalCleanupReleaseRegistryEntries() throws {
        let registry = EngineOperationRegistry(), failed = Process()
        failed.executableURL = URL(fileURLWithPath: "/nonexistent-katalog-helper")
        XCTAssertThrowsError(try ProcessLifetime(registry: registry).run(failed))
        XCTAssertEqual(registry.activeProcessCount, 0)
        let control = ProcessLifetime(grace: 0.1, registry: registry), process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf ready; while :; do :; done"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        defer { control.cleanup(); try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        try control.run(process)
        XCTAssertNotNil(try control.readChunk(from: output.fileHandleForReading))
        XCTAssertEqual(registry.activeProcessCount, 1)
        control.cleanup()
        XCTAssertEqual(registry.activeProcessCount, 0)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testCancellationKillsOnlyOwnedHelperIgnoringTermination() async throws {
        let control = ProcessLifetime(grace: 0.15)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf ready; while :; do :; done"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try control.run(process)
        XCTAssertNotNil(try control.readChunk(from: output.fileHandleForReading))
        let start = Date()
        control.cancel()
        await Task.detached { ProcessLifetime.wait(for: process) }.value
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertThrowsError(try control.finish()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellationBeforeLaunchDoesNotStartProcess() {
        let control = ProcessLifetime()
        control.cancel()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try control.run(process)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(process.isRunning)
    }

    func testCancelledReaderReturnsEvenWhileWriterIsOpen() async throws {
        let control = ProcessLifetime(), pipe = Pipe()
        let reader = Task.detached { try control.readChunk(from: pipe.fileHandleForReading) }
        try await Task.sleep(for: .milliseconds(50))
        control.cancel()
        do { _ = try await reader.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try pipe.fileHandleForReading.close(); try pipe.fileHandleForWriting.close()
    }
}
