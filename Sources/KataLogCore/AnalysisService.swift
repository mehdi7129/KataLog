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

public enum AnalysisService {
    public static let parserVersion = "1.4.0"
    public static func decode(_ data: Data) throws -> FleetSnapshot {
        let snapshot = try JSONDecoder().decode(FleetSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw AnalysisError.schema(snapshot.schemaVersion) }
        return snapshot
    }

    public static func scan(folder: URL, database: URL, output: URL, progress: URL, engine: URL, archiveDestination: URL? = nil, clientID: String? = nil) async throws -> FleetSnapshot {
        try await scan(folder: folder, database: database, output: output, progress: progress, engine: engine,
                       archiveDestination: archiveDestination, clientID: clientID, runtimeConfiguration: .current)
    }

    public static func scanPaged(folder: URL, database: URL, output: URL, progress: URL, engine: URL, archiveDestination: URL? = nil, clientID: String? = nil) async throws -> FleetSnapshot {
        try await scan(folder: folder, database: database, output: output, progress: progress, engine: engine,
                       skipSnapshot: true, archiveDestination: archiveDestination, clientID: clientID, runtimeConfiguration: .current)
    }

    static func scan(folder: URL, database: URL, output: URL, progress: URL, engine: URL,
                     skipSnapshot: Bool = false,
                     archiveDestination: URL? = nil,
                     clientID: String? = nil,
                     runtimeConfiguration: EngineRuntimeResolver.Configuration) async throws -> FleetSnapshot {
        guard archiveDestination?.isFileURL ?? true else { throw AnalysisError.engine("Choisissez un dossier local pour les archives.") }
        let control = ProcessLifetime()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                defer { control.cleanup() }
                guard FileManager.default.fileExists(atPath: engine.path) else {
                    throw AnalysisError.unavailable("Le moteur d’analyse est absent de l’app : \(engine.path)")
                }
                try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let stderr = work.appendingPathComponent("stderr.txt")
                let runtime = try EngineRuntimeResolver.resolve(configuration: runtimeConfiguration,
                                                               launch: control.run, finished: control.finish)
                let arguments = ["-B", engine.path, "scan", "--folder", folder.path,
                    "--database", database.path, "--output", output.path, "--progress", progress.path]
                    + (skipSnapshot ? ["--skip-snapshot"] : [])
                    + (archiveDestination.map { ["--archive-destination", $0.path] } ?? [])
                    + (clientID.map { ["--client-id", $0] } ?? [])
                let status = try execute(runtime, arguments: arguments, control: control, stderr: stderr)
                guard status == 0 else {
                    let detail = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
                    throw AnalysisError.engine("L’analyse a échoué (code \(status)). \(String(detail.suffix(4000)))")
                }
                return try decode(Data(contentsOf: output))
            }.value
        } onCancel: { control.cancel() }
    }

    public static func detail(logID: String, database: URL, engine: URL) async throws -> FlightLog {
        try await detail(logID: logID, database: database, engine: engine, runtimeConfiguration: .current)
    }

    public static func detail(logID: String, database: URL, engine: URL, readOnly: Bool) async throws -> FlightLog {
        let command = ["detail", "--log-id", logID, "--database", database.path] + (readOnly ? ["--read-only"] : [])
        let data = try await run(command, engine: engine)
        let log = try JSONDecoder().decode(FlightLog.self, from: data)
        guard log.id == logID else { throw AnalysisError.engine("Le détail reçu ne correspond pas au log demandé.") }
        return log
    }

    static func detail(logID: String, database: URL, engine: URL,
                       runtimeConfiguration: EngineRuntimeResolver.Configuration) async throws -> FlightLog {
        let data = try await readData(command: ["detail", "--log-id", logID], database: database, engine: engine,
                                      runtimeConfiguration: runtimeConfiguration)
        let log = try JSONDecoder().decode(FlightLog.self, from: data)
        guard log.id == logID else { throw AnalysisError.engine("Le détail reçu ne correspond pas au log demandé.") }
        return log
    }

    public static func snapshot(database: URL, engine: URL) async throws -> FleetSnapshot {
        try await snapshot(database: database, engine: engine, runtimeConfiguration: .current)
    }

    public static func snapshot(database: URL, engine: URL, readOnly: Bool) async throws -> FleetSnapshot {
        try decode(await run(["snapshot", "--database", database.path] + (readOnly ? ["--read-only"] : []), engine: engine,
                             outputLimit: 512 * 1024 * 1024))
    }

    static func snapshot(database: URL, engine: URL,
                         runtimeConfiguration: EngineRuntimeResolver.Configuration) async throws -> FleetSnapshot {
        try decode(await readData(command: ["snapshot"], database: database, engine: engine,
                                  runtimeConfiguration: runtimeConfiguration))
    }

    private static func readData(command: [String], database: URL, engine: URL,
                                 runtimeConfiguration: EngineRuntimeResolver.Configuration) async throws -> Data {
        try await run(command + ["--database", database.path], engine: engine, runtimeConfiguration: runtimeConfiguration)
    }

    /// Command results are bounded before decoding; temporary request files are
    /// private and removed after completion or cancellation.
    public static func run(_ command: [String], engine: URL, request: Data? = nil,
                           outputLimit: Int = 16 * 1024 * 1024) async throws -> Data {
        try await run(command, engine: engine, request: request, outputLimit: outputLimit, runtimeConfiguration: .current)
    }

    static func run(_ command: [String], engine: URL, request: Data? = nil,
                    outputLimit: Int = 16 * 1024 * 1024,
                    runtimeConfiguration: EngineRuntimeResolver.Configuration) async throws -> Data {
        let control = ProcessLifetime()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                defer { control.cleanup() }
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-read-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let errors = work.appendingPathComponent("stderr.txt"), output = work.appendingPathComponent("result.json")
                var arguments = command
                if let request {
                    let input = work.appendingPathComponent("request.json")
                    try request.write(to: input, options: .atomic)
                    arguments += ["--request", input.path]
                }
                guard FileManager.default.fileExists(atPath: engine.path) else {
                    throw AnalysisError.unavailable("Le moteur d’analyse est absent de l’app.")
                }
                let runtime = try EngineRuntimeResolver.resolve(configuration: runtimeConfiguration,
                                                               launch: control.run, finished: control.finish)
                let status = try execute(runtime, arguments: ["-B", engine.path] + arguments + ["--output", output.path], control: control, stderr: errors)
                guard status == 0 else {
                    let detail = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
                    throw AnalysisError.engine(String(detail.suffix(2000)))
                }
                let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= outputLimit else { throw AnalysisError.engine("La réponse du moteur dépasse la limite autorisée. Réduisez la sélection.") }
                try control.checkCancellation()
                return try Data(contentsOf: output)
            }.value
        } onCancel: { control.cancel() }
    }

    private static func execute(_ runtime: EngineRuntimeResolver.Runtime, arguments: [String], control: ProcessLifetime, stderr: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let handle = try FileHandle(forWritingTo: stderr)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        let writerInput = try LibraryWriterLease.inheritedInput(for: arguments)
        defer { try? writerInput?.close() }
        process.standardInput = writerInput ?? FileHandle.nullDevice
        process.environment = runtime.environment
        try control.run(process)
        ProcessLifetime.wait(for: process)
        try control.finish()
        return process.terminationStatus
    }
}
