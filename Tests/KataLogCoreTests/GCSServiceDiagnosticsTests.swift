import Foundation
import XCTest
@testable import KataLogCore

final class GCSServiceDiagnosticsTests: XCTestCase, @unchecked Sendable {
    private func archive(_ entries: [(String, String)], symlink: Bool = false) throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("fixture.zip")
        try JSONSerialization.data(withJSONObject: entries.map { [$0.0, $0.1] }).write(to: input)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys,json,zipfile; z=zipfile.ZipFile(sys.argv[2],'w',compression=zipfile.ZIP_DEFLATED); entries=json.load(open(sys.argv[1])); [(lambda i,t:(setattr(i,'external_attr',0o120777<<16) if sys.argv[3]=='yes' else None,z.writestr(i,t)))(zipfile.ZipInfo(n),t) for n,t in entries]; z.close()", input.path, output.path, symlink ? "yes" : "no"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); ProcessLifetime.wait(for: process); XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: output)
    }

    func testEndpointUsesGCSHTTPPortAndRejectsCredentialsOrUnexpectedPaths() throws {
        XCTAssertEqual(try GCSServiceDiagnostics.endpoint(host: "gcs.example").absoluteString, "http://gcs.example:8080/servicelogs")
        XCTAssertEqual(try GCSServiceDiagnostics.endpoint(host: "https://gcs.example:8443/").absoluteString, "https://gcs.example:8443/servicelogs")
        for bad in ["", "http://user:secret@gcs.example", "file:///tmp/gcs", "https://gcs.example/other", "gcs.example/path", "http://gcs.example?secret=test"] {
            XCTAssertThrowsError(try GCSServiceDiagnostics.endpoint(host: bad))
        }
    }

    func testValidArchiveReadsOnlyKnownFilesWithoutExtractingPaths() async throws {
        let data = try archive([("reactor.log", "INFO service started\n"), ("metadata.json", "{\"gcsVersion\":\"test\"}")])
        let files = try await GCSServiceDiagnostics.decodeArchive(data)
        XCTAssertEqual(files.map(\.name), ["metadata.json", "reactor.log"])
        XCTAssertEqual(files.last?.text, "INFO service started\n")
    }

    func testUnsafeNamesDuplicatesAndSymlinksAreRejected() async throws {
        for entries in [[("../node.log", "x")], [("/node.log", "x")], [("private.log", "x")], [("node.log", "x"), ("node.log", "y")], [("folder/node.log", "x")]] {
            do { _ = try await GCSServiceDiagnostics.decodeArchive(try archive(entries)); XCTFail("Unsafe archive accepted") }
            catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, .unsafeArchive) }
        }
        do { _ = try await GCSServiceDiagnostics.decodeArchive(try archive([("node.log", "target")], symlink: true)); XCTFail("Symlink accepted") }
        catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, .unsafeArchive) }
    }

    func testSizeAndTextValidationRejectsOversizedOrBinaryEntries() async throws {
        var limits = GCSServiceDiagnostics.Limits(); limits.entryBytes = 16
        do { _ = try await GCSServiceDiagnostics.decodeArchive(try archive([("node.log", String(repeating: "x", count: 32))]), limits: limits); XCTFail("Oversized entry accepted") }
        catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, .tooLarge) }
        do { _ = try await GCSServiceDiagnostics.decodeArchive(try archive([("node.log", "a\0b")])); XCTFail("Binary entry accepted") }
        catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, .invalidArchive) }
        do { _ = try await GCSServiceDiagnostics.decodeArchive(Data("not a zip".utf8)); XCTFail("Invalid ZIP accepted") }
        catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, .invalidArchive) }
    }

    func testHTTPUnavailableRedirectServerAndTimeoutHaveStableErrors() async throws {
        let endpoint = try GCSServiceDiagnostics.endpoint(host: "gcs.example")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ServiceProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        for (status, expected) in [(404, GCSServiceDiagnosticsError.unsupported), (302, .redirectDenied), (500, .server(500))] {
            ServiceProtocol.state.set(status: status, data: Data(), error: nil)
            do { _ = try await GCSServiceDiagnostics.fetch(endpoint: endpoint, session: session); XCTFail("HTTP error accepted") }
            catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, expected) }
        }
        ServiceProtocol.state.set(status: 200, data: Data(), error: URLError(.timedOut))
        do { _ = try await GCSServiceDiagnostics.fetch(endpoint: endpoint, session: session); XCTFail("Timeout accepted") }
        catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, .timeout) }
        ServiceProtocol.state.set(status: 200, data: Data(), error: URLError(.notConnectedToInternet))
        do { _ = try await GCSServiceDiagnostics.fetch(endpoint: endpoint, session: session); XCTFail("Offline accepted") }
        catch { XCTAssertEqual(error as? GCSServiceDiagnosticsError, .offline) }
    }

    func testHTTPFetchValidatesArchiveAndHonoursCancellation() async throws {
        let endpoint = try GCSServiceDiagnostics.endpoint(host: "gcs.example")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ServiceProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        ServiceProtocol.state.set(status: 200, data: try archive([("node.log", "ready")]), error: nil)
        let result = try await GCSServiceDiagnostics.fetch(endpoint: endpoint, session: session)
        XCTAssertEqual(result.files, [.init(name: "node.log", text: "ready")]); XCTAssertTrue(result.currentBootOnly)
        let task = Task { try await GCSServiceDiagnostics.fetch(endpoint: endpoint, session: session) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class ServiceProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock(); private var value: (Int, Data, URLError?) = (200, Data(), nil)
        func set(status: Int, data: Data, error: URLError?) { lock.lock(); defer { lock.unlock() }; value = (status, data, error) }
        func get() -> (Int, Data, URLError?) { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, error) = Self.state.get()
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/zip", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
