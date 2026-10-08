import Foundation

public enum GCSProcessService {
    public static func events(script: URL, arguments: [String], writerLibrary: URL? = nil) -> AsyncThrowingStream<GCSCollectorEvent, Error> {
        events(script: script, arguments: arguments, writerLibrary: writerLibrary, runtimeConfiguration: .current)
    }

    static func events(script: URL, arguments: [String], writerLibrary: URL? = nil,
                       runtimeConfiguration: EngineRuntimeResolver.Configuration) -> AsyncThrowingStream<GCSCollectorEvent, Error> {
        let reader = CollectorEventReader(script: script, arguments: arguments, writerLibrary: writerLibrary,
                                          runtimeConfiguration: runtimeConfiguration)
        // Pull one event per next(): the OS pipe, not an unbounded Swift queue,
        // holds output while the consumer works. Blocking I/O stays off its actor.
        return AsyncThrowingStream(unfolding: {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) { try reader.next() }.value
            } onCancel: { reader.cancel() }
        })
    }
}

/// A stream may have several iterators; serialize their reads and resource state.
private final class CollectorEventReader: @unchecked Sendable {
    private let lock = NSLock()
    private let control = ProcessLifetime()
    private let script: URL
    private let arguments: [String]
    private let writerLibrary: URL?
    private let runtimeConfiguration: EngineRuntimeResolver.Configuration
    private var process: Process?
    private var pipe: Pipe?
    private var errors: FileHandle?
    private var errorsURL: URL?
    private var writerInput: FileHandle?
    private var buffer = Data()
    private var reachedEOF = false
    private var finished = false
    private var reportedError: String?
    private let maximumLineBytes = 4 * 1024 * 1024

    init(script: URL, arguments: [String], writerLibrary: URL?, runtimeConfiguration: EngineRuntimeResolver.Configuration) {
        self.script = script; self.arguments = arguments; self.writerLibrary = writerLibrary
        self.runtimeConfiguration = runtimeConfiguration
    }

    deinit {
        // Breaking out of a for-await loop can release the stream on MainActor.
        // Signal cancellation now, then reap and close off that actor.
        control.cancel()
        Task.detached { [control, pipe, errors, errorsURL, writerInput] in
            Self.cleanup(control: control, pipe: pipe, errors: errors, errorsURL: errorsURL, writerInput: writerInput)
        }
    }

    func cancel() { control.cancel() }

    func next() throws -> GCSCollectorEvent? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        do {
            try control.checkCancellation()
            if process == nil { try start() }
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    guard buffer.distance(from: buffer.startIndex, to: newline) <= maximumLineBytes else {
                        throw AnalysisError.engine("Réponse GCS trop volumineuse.")
                    }
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if !line.isEmpty { return try decode(line) }
                    continue
                }
                guard buffer.count <= maximumLineBytes else { throw AnalysisError.engine("Réponse GCS trop volumineuse.") }
                if reachedEOF {
                    if !buffer.isEmpty {
                        let line = buffer; buffer = Data()
                        return try decode(line)
                    }
                    guard let process else { return nil }
                    ProcessLifetime.wait(for: process)
                    try control.finish()
                    if process.terminationStatus != 0 {
                        let detail = stderrTail()
                        throw AnalysisError.engine(reportedError ?? (detail.isEmpty ? "La collecte a été interrompue (code \(process.terminationStatus))." : detail))
                    }
                    finish()
                    return nil
                }
                guard let pipe else { return nil }
                if let chunk = try control.readChunk(from: pipe.fileHandleForReading) { buffer.append(chunk) }
                else { reachedEOF = true }
            }
        } catch {
            finish()
            throw error
        }
    }

    private func decode(_ line: Data) throws -> GCSCollectorEvent {
        let event = try JSONDecoder().decode(GCSCollectorEvent.self, from: line)
        if event.event == "error" { reportedError = event.message }
        return event
    }

    private func start() throws {
        guard FileManager.default.fileExists(atPath: script.path) else { throw AnalysisError.unavailable("Le collecteur GCS est absent de l’app.") }
        let runtime = try EngineRuntimeResolver.resolve(configuration: runtimeConfiguration, launch: control.run, finished: control.finish)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-gcs-\(UUID().uuidString).stderr")
        errorsURL = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        errors = try FileHandle(forWritingTo: url)
        let output = Pipe(), child = Process()
        pipe = output; process = child
        child.executableURL = runtime.executableURL
        child.arguments = ["-u", "-B", script.path] + arguments
        child.environment = runtime.environment
        child.standardOutput = output; child.standardError = errors
        // Retain only this app's exact writer lease until the helper exits.
        writerInput = try writerLibrary.flatMap { try LibraryWriterLease.inheritedInput(for: ["--library", $0.path]) }
        child.standardInput = writerInput ?? FileHandle.nullDevice
        try control.run(child)
    }

    private func stderrTail() -> String {
        guard let errorsURL, let handle = try? FileHandle(forReadingFrom: errorsURL) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: size > 6_000 ? size - 6_000 : 0)
        guard let data = try? handle.read(upToCount: 6_000) else { return "" }
        return String(String(decoding: data, as: UTF8.self).suffix(1_500))
    }

    private func finish() {
        finished = true
        Self.cleanup(control: control, pipe: pipe, errors: errors, errorsURL: errorsURL, writerInput: writerInput)
        process = nil; pipe = nil; errors = nil; errorsURL = nil; writerInput = nil; buffer = Data()
    }

    private static func cleanup(control: ProcessLifetime, pipe: Pipe?, errors: FileHandle?, errorsURL: URL?, writerInput: FileHandle?) {
        control.cleanup()
        try? pipe?.fileHandleForReading.close(); try? pipe?.fileHandleForWriting.close()
        try? errors?.close(); try? writerInput?.close()
        if let errorsURL { try? FileManager.default.removeItem(at: errorsURL) }
    }
}
