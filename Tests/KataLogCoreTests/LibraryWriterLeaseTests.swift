import Darwin
import Foundation
import XCTest
@testable import KataLogCore

final class LibraryWriterLeaseTests: XCTestCase {
    func testInheritedInputExistsOnlyForExactWritableLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try LibraryWriterLease(directory: root)
        let reader = try LibraryWriterLease(directory: root)
        XCTAssertTrue(writer.isWritable); XCTAssertFalse(reader.isWritable)
        let libraryInput = try LibraryWriterLease.inheritedInput(for: ["backup", "--library", root.path])
        let databaseInput = try LibraryWriterLease.inheritedInput(for: ["scan", "--database", root.appendingPathComponent("library.sqlite").path])
        defer { try? libraryInput?.close(); try? databaseInput?.close() }
        XCTAssertNotNil(libraryInput); XCTAssertNotNil(databaseInput)
        XCTAssertNotEqual(fcntl(try XCTUnwrap(libraryInput).fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertNotEqual(fcntl(try XCTUnwrap(databaseInput).fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertNil(try LibraryWriterLease.inheritedInput(for: ["scan", "--database", root.appendingPathComponent("different/library.sqlite").path]))
        XCTAssertNil(try LibraryWriterLease.inheritedInput(for: ["discover", "--host", "localhost"]))
        withExtendedLifetime(writer) {}; withExtendedLifetime(reader) {}
    }

    func testOrphanedWritingChildKeepsInheritedLeaseAfterItsParentExits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-orphan-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var writer: LibraryWriterLease? = try LibraryWriterLease(directory: root)
        XCTAssertTrue(writer!.isWritable)
        let input = try XCTUnwrap(LibraryWriterLease.inheritedInput(for: ["scan", "--database", root.appendingPathComponent("library.sqlite").path]))
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KATALOG_TEST_PYTHON"] ?? "/usr/bin/python3")
        parent.arguments = ["-B", "-c", #"""
import os,pathlib,subprocess,sys
child = '''import pathlib,sys,time
root=pathlib.Path(sys.argv[1])
(root/'child-ready').write_text('ready')
time.sleep(.6)
(root/'child-writing').write_text('written after parent exit')
time.sleep(.6)
(root/'child-finished').write_text('done')
'''
subprocess.Popen([sys.executable,'-B','-c',child,sys.argv[1]],stdin=sys.stdin,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,close_fds=True)
os._exit(0)
"""#, root.path]
        parent.standardInput = input
        parent.standardOutput = FileHandle.nullDevice; parent.standardError = FileHandle.nullDevice
        try parent.run()
        // The original app-side copies are gone. Only the child chain can keep
        // the lock, including after its immediate parent dies without cleanup.
        try input.close(); writer = nil
        await Task.detached { ProcessLifetime.wait(for: parent) }.value
        XCTAssertEqual(parent.terminationStatus, 0)
        try await waitFor(root.appendingPathComponent("child-ready"))
        let secondWriter = try LibraryWriterLease(directory: root)
        XCTAssertFalse(secondWriter.isWritable)
        XCTAssertNil(try LibraryWriterLease.inheritedInput(for: ["scan", "--database", root.appendingPathComponent("library.sqlite").path]), "A read-only lease cannot be forwarded")
        try await waitFor(root.appendingPathComponent("child-writing"))
        XCTAssertFalse(try LibraryWriterLease(directory: root).isWritable)
        try await waitFor(root.appendingPathComponent("child-finished"))
        let deadline = Date().addingTimeInterval(3)
        var reacquired: LibraryWriterLease?
        while Date() < deadline {
            let candidate = try LibraryWriterLease(directory: root)
            if candidate.isWritable { reacquired = candidate; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(reacquired?.isWritable == true)
        withExtendedLifetime(secondWriter) {}; withExtendedLifetime(reacquired) {}
    }

    private func waitFor(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing helper marker: \(url.lastPathComponent)")
    }
}
