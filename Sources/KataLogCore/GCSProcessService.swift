import Foundation

public enum GCSProcessService {
    public static func events(script: URL, arguments: [String], writerLibrary: URL? = nil) -> AsyncThrowingStream<GCSCollectorEvent, Error> {
        events(script: script, arguments: arguments, writerLibrary: writerLibrary, runtimeConfiguration: .current)
    }

    static func events(script: URL, arguments: [String], writerLibrary: URL? = nil,
                       runtimeConfiguration: EngineRuntimeResolver.Configuration) -> AsyncThrowingStream<GCSCollectorEvent, Error> {
        let control = ProcessLifetime()
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                defer { control.cleanup() }
                let errors = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-gcs-\(UUID().uuidString).stderr")
                defer { try? FileManager.default.removeItem(at: errors) }
                do {
                    guard FileManager.default.fileExists(atPath: script.path) else { throw AnalysisError.unavailable("Le collecteur GCS est absent de l’app.") }
                    let runtime = try EngineRuntimeResolver.resolve(configuration: runtimeConfiguration,
                                                                   launch: control.run, finished: control.finish)
                    FileManager.default.createFile(atPath: errors.path, contents: nil)
                    let err = try FileHandle(forWritingTo: errors)
                    defer { try? err.close() }
                    let pipe = Pipe(), process = Process()
                    defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                    process.executableURL = runtime.executableURL
                    process.arguments = ["-u", "-B", script.path] + arguments
                    process.environment = runtime.environment
                    process.standardOutput = pipe; process.standardError = err
                    // A bounded transfer/inventory can finish after a parent
                    // crash. Retain only this app's exact writable lease until
                    // that helper exits. Discovery has no library writer input.
                    let writerInput = try writerLibrary.flatMap {
                        try LibraryWriterLease.inheritedInput(for: ["--library", $0.path])
                    }
                    defer { try? writerInput?.close() }
                    process.standardInput = writerInput ?? FileHandle.nullDevice
                    try control.run(process)
                    var buffer = Data()
                    var reportedError: String?
                    do {
                        while true {
                            // Polling keeps discovery responsive and cancellation bounded.
                            guard let chunk = try control.readChunk(from: pipe.fileHandleForReading) else { break }
                            buffer.append(chunk)
                            while let newline = buffer.firstIndex(of: 10) {
                                guard newline <= 4 * 1024 * 1024 else { throw AnalysisError.engine("Réponse GCS trop volumineuse.") }
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
                    } catch {
                        control.cancel()
                        ProcessLifetime.wait(for: process)
                        throw error
                    }
                    ProcessLifetime.wait(for: process)
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
}
