import Foundation

private final class GCSProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run(); self.process = process
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        process = nil
        if cancelled { throw CancellationError() }
    }
}

public enum GCSProcessService {
    public static func events(script: URL, arguments: [String]) -> AsyncThrowingStream<GCSCollectorEvent, Error> {
        let control = GCSProcessControl()
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let errors = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-gcs-\(UUID().uuidString).stderr")
                defer { try? FileManager.default.removeItem(at: errors) }
                do {
                    guard FileManager.default.fileExists(atPath: script.path) else { throw AnalysisError.unavailable("Le collecteur GCS est absent de l’app.") }
                    let python = try pythonExecutable()
                    FileManager.default.createFile(atPath: errors.path, contents: nil)
                    let err = try FileHandle(forWritingTo: errors)
                    defer { try? err.close() }
                    let pipe = Pipe(), process = Process()
                    process.executableURL = python
                    process.arguments = ["-u", "-B", script.path] + arguments
                    process.standardOutput = pipe; process.standardError = err
                    process.standardInput = FileHandle.nullDevice
                    try control.start(process)
                    var buffer = Data()
                    var reportedError: String?
                    do {
                        while true {
                            // read(upToCount:) can wait for the requested byte count on a pipe.
                            // Discovery is a long-lived stream: consume each available chunk now.
                            let chunk = pipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            buffer.append(chunk)
                            while let newline = buffer.firstIndex(of: 10) {
                                let line = Data(buffer[..<newline])
                                buffer.removeSubrange(...newline)
                                if !line.isEmpty {
                                    let event = try JSONDecoder().decode(GCSCollectorEvent.self, from: line)
                                    if event.event == "error" { reportedError = event.message }
                                    continuation.yield(event)
                                }
                            }
                            guard buffer.count <= 4 * 1024 * 1024 else { throw AnalysisError.engine("Réponse GCS trop volumineuse.") }
                        }
                        if !buffer.isEmpty { continuation.yield(try JSONDecoder().decode(GCSCollectorEvent.self, from: buffer)) }
                    } catch { control.cancel(); throw error }
                    process.waitUntilExit()
                    try control.finish()
                    guard process.terminationStatus == 0 else {
                        let detail = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
                        throw AnalysisError.engine(reportedError ?? (detail.isEmpty ? "La collecte a été interrompue (code \(process.terminationStatus))." : String(detail.suffix(1500))))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in control.cancel(); task.cancel() }
        }
    }

    private static func pythonExecutable() throws -> URL {
        let candidates = [ProcessInfo.processInfo.environment["KATALOG_PYTHON"],
            "/opt/homebrew/opt/python@3.13/bin/python3.13", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AnalysisError.unavailable("Python 3 est requis pour la collecte GCS sur ce Mac.")
        }
        return URL(fileURLWithPath: path)
    }
}
