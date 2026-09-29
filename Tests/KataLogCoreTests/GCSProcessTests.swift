import XCTest
@testable import KataLogCore

final class GCSProcessTests: XCTestCase {
    func testEventsArriveBeforeLongLivedCollectorExits() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gcs-stream-\(UUID().uuidString).py")
        try "import time\nprint('{\"event\":\"connection\",\"connected\":true}', flush=True)\ntime.sleep(5)\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date()
        let consumer = Task {
            for try await event in GCSProcessService.events(script: file, arguments: []) {
                if event.event == "connection" { return event.connected }
            }
            return false
        }
        let connected = try await consumer.value
        consumer.cancel()
        XCTAssertEqual(connected, true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "A live event must not wait for EOF or a full pipe buffer.")
    }

    func testStructuredCollectorFailureSurvivesProcessExit() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gcs-error-\(UUID().uuidString).py")
        try "import sys\nprint('{\"event\":\"error\",\"message\":\"Taille du log modifiee\"}', flush=True)\nsys.exit(1)\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            for try await _ in GCSProcessService.events(script: file, arguments: []) {}
            XCTFail("Expected collector failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Taille du log modifiee")) }
    }
}
