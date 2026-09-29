import Foundation

public enum AnalysisError: LocalizedError {
    case unavailable(String)
    case engine(String)
    case schema(Int)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .engine(let message): message
        case .schema(let version): "Version de bibliothèque non prise en charge : \(version)."
        }
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func run(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        process = nil
        if cancelled { throw CancellationError() }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

public enum AnalysisService {
    public static let parserVersion = "1.2.0"
    public static func decode(_ data: Data) throws -> FleetSnapshot {
        let snapshot = try JSONDecoder().decode(FleetSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw AnalysisError.schema(snapshot.schemaVersion) }
        return snapshot
    }

    public static func scan(folder: URL, database: URL, output: URL, progress: URL, engine: URL) async throws -> FleetSnapshot {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: engine.path) else {
                    throw AnalysisError.unavailable("Le moteur d’analyse est absent de l’app : \(engine.path)")
                }
                try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let stderr = work.appendingPathComponent("stderr.txt")
                let python = try findPython(control: control, stderr: stderr)
                let status = try execute(python, arguments: [engine.path, "scan", "--folder", folder.path,
                    "--database", database.path, "--output", output.path, "--progress", progress.path], control: control, stderr: stderr)
                guard status == 0 else {
                    let detail = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
                    throw AnalysisError.engine("L’analyse a échoué (code \(status)). \(String(detail.suffix(4000)))")
                }
                return try decode(Data(contentsOf: output))
            }.value
        } onCancel: { control.cancel() }
    }

    public static func detail(logID: String, database: URL, engine: URL) async throws -> FlightLog {
        let data = try await readData(command: ["detail", "--log-id", logID], database: database, engine: engine)
        let log = try JSONDecoder().decode(FlightLog.self, from: data)
        guard log.id == logID else { throw AnalysisError.engine("Le détail reçu ne correspond pas au log demandé.") }
        return log
    }

    public static func snapshot(database: URL, engine: URL) async throws -> FleetSnapshot {
        try decode(await readData(command: ["snapshot"], database: database, engine: engine))
    }

    private static func readData(command: [String], database: URL, engine: URL) async throws -> Data {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-read-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let errors = work.appendingPathComponent("stderr.txt"), output = work.appendingPathComponent("result.json")
                let python = try findPython(control: control, stderr: errors)
                let status = try execute(python, arguments: [engine.path] + command + ["--database", database.path, "--output", output.path], control: control, stderr: errors)
                guard status == 0 else {
                    let detail = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
                    throw AnalysisError.engine(String(detail.suffix(2000)))
                }
                return try Data(contentsOf: output)
            }.value
        } onCancel: { control.cancel() }
    }

    private static func findPython(control: ProcessControl, stderr: URL) throws -> URL {
        var candidates: [String] = []
        if let custom = ProcessInfo.processInfo.environment["KATALOG_PYTHON"] { candidates.append(custom) }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("KataLog/python/bin/python3").path)
        }
        candidates += ["/opt/homebrew/opt/python@3.13/bin/python3.13", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }
        for path in Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            if try execute(url, arguments: ["-c", "import pyulog, numpy"], control: control, stderr: stderr) == 0 { return url }
        }
        throw AnalysisError.unavailable("Le moteur de lecture PX4 n’est pas installé sur ce Mac. Suivez la section « Moteur Python » du README de KataLog (pyulog et numpy), puis relancez l’import.")
    }

    private static func execute(_ executable: URL, arguments: [String], control: ProcessControl, stderr: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let handle = try FileHandle(forWritingTo: stderr)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        try control.run(process)
        process.waitUntilExit()
        try control.check()
        return process.terminationStatus
    }
}
