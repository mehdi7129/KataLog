import Foundation
import XCTest
@testable import KataLogCore

final class CLIOutputCollisionTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-cli-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func run(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("katalog-cli")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["KATALOG_PYTHON"] = arguments.contains("--folder")
            ? try XCTUnwrap(environment["KATALOG_TEST_PYTHON"]) : "/missing/katalog-test-python"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testImportHTMLCollisionsAreRejectedBeforeAnyLogIsImported() throws {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KataLog/Resources/analyzer.py")
        for destination in ["library.sqlite", "original.ulg", "library.json", "progress.json"] {
            let root = try folder(), source = root.appendingPathComponent("original.ulg")
            let original = Data("Synthetic unreadable ULog, retained byte for byte".utf8)
            try original.write(to: source)
            let database = root.appendingPathComponent("library.sqlite")
            let result = try run(["--folder", source.path, "--database", database.path,
                                  "--output", root.appendingPathComponent("library.json").path,
                                  "--html", root.appendingPathComponent(destination).path, "--engine", engine.path])
            XCTAssertEqual(result.0, 1, destination)
            XCTAssertTrue(result.1.lowercased().contains("sortie"), result.1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: database.path), destination)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testSnapshotHTMLCannotReplaceSnapshotThroughAnyAlias() throws {
        for aliasKind in ["same", "symlink", "hardlink"] {
            let root = try folder(), input = root.appendingPathComponent("snapshot.json")
            let original = try JSONEncoder().encode(FleetSnapshot.empty)
            try original.write(to: input)
            let alias = aliasKind == "same" ? input : root.appendingPathComponent("alias.html")
            if aliasKind == "symlink" { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input) }
            if aliasKind == "hardlink" { try FileManager.default.linkItem(at: input, to: alias) }
            let result = try run(["--snapshot", input.path, "--html", alias.path])
            XCTAssertEqual(result.0, 1, aliasKind)
            XCTAssertTrue(result.1.lowercased().contains("sortie"), result.1)
            XCTAssertEqual(try Data(contentsOf: input), original)
            XCTAssertEqual(try Data(contentsOf: alias), original)
        }
    }

    func testSnapshotHTMLCannotReplaceReferencedSourceAndValidExportStillWorks() throws {
        let root = try folder(), source = root.appendingPathComponent("original.ulg")
        let original = Data("Synthetic original source".utf8)
        try original.write(to: source)
        var snapshot = FleetSnapshot.empty
        snapshot.logs = [FlightLog(id: "synthetic", droneID: "synthetic", droneName: "Synthetic",
            date: "", dateSource: "unknown", sourcePaths: [source.path], fileName: source.lastPathComponent,
            sizeBytes: Int64(original.count), durationSeconds: 0, flightSeconds: nil, status: "error",
            issues: [], metadata: [:], topics: [], messages: [], metrics: [], coverage: [], failsafeObserved: false)]
        let input = root.appendingPathComponent("snapshot.json")
        try JSONEncoder().encode(snapshot).write(to: input)
        let rejected = try run(["--snapshot", input.path, "--html", source.path])
        XCTAssertEqual(rejected.0, 1)
        XCTAssertTrue(rejected.1.lowercased().contains("sortie"), rejected.1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let output = root.appendingPathComponent("report.html")
        let accepted = try run(["--snapshot", input.path, "--html", output.path])
        XCTAssertEqual(accepted.0, 0, accepted.1)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).lowercased().contains("<!doctype html>"))
    }

    func testSnapshotHTMLReservesLibraryDatabaseAndControlPathsWithoutPython() throws {
        for name in ["Library.sqlite", "library.sqlite-wal", ".library-writer.lock", "annotations.json", "gcs-queue.sqlite"] {
            let root = try folder(), input = root.appendingPathComponent("library.json")
            try JSONEncoder().encode(FleetSnapshot.empty).write(to: input)
            let output = root.appendingPathComponent(name)
            let result = try run(["--snapshot", input.path, "--html", output.path])
            XCTAssertEqual(result.0, 1, name)
            XCTAssertTrue(result.1.lowercased().contains("sortie"), result.1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), name)
        }
    }
}
