import Foundation
import Darwin

/// Shared runtime selection for imports and GCS collection. Distributed apps only
/// execute their bundled engine; external Python is a development convenience.
enum EngineRuntimeResolver {
    struct Configuration: Sendable {
        var bundleURL: URL?
        var bundledEngineRequired: Bool
        var environment: [String: String]
        var externalCandidates: [URL]?

        static var current: Configuration {
            let main = Bundle.main
            let required = main.object(forInfoDictionaryKey: "KatalogBundledEngineRequired") as? Bool == true
            let cliBundle = required ? nil : distributionBundle(for: main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            return Configuration(bundleURL: cliBundle ?? main.bundleURL,
                bundledEngineRequired: required || cliBundle != nil,
                environment: ProcessInfo.processInfo.environment)
        }

        /// Foundation may treat a secondary CLI executable as a plain binary,
        /// even though it is inside the installed app. Resolve that exact app
        /// from its executable, never from the caller's working directory.
        static func distributionBundle(for executable: URL) -> URL? {
            let binary = executable.standardizedFileURL.resolvingSymlinksInPath()
            guard binary.lastPathComponent == "katalog-cli" else { return nil }
            let macOS = binary.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
            let app = contents.deletingLastPathComponent()
            guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app",
                  let info = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
                  let metadata = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  metadata["KatalogBundledEngineRequired"] as? Bool == true else { return nil }
            return app
        }

        init(bundleURL: URL? = nil, bundledEngineRequired: Bool = false,
             environment: [String: String], externalCandidates: [URL]? = nil) {
            self.bundleURL = bundleURL
            self.bundledEngineRequired = bundledEngineRequired
            self.environment = environment
            self.externalCandidates = externalCandidates
        }
    }

    struct Runtime: Sendable {
        enum Kind: Sendable { case bundled, development }
        let executableURL: URL
        let environment: [String: String]
        let kind: Kind
    }

    private struct RuntimeInfo: Decodable {
        let protocolVersion: Int
        let parserVersion: String
        let python: String
        let numpy: String
        let pyulog: String
        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol", parserVersion, python, numpy, pyulog
        }
    }

    private static let reinstallMessage = "Le moteur intégré de KataLog est absent, endommagé ou incompatible. Réinstallez KataLog depuis le DMG officiel."
    private static let externalProbe = """
        import json, sys, importlib.metadata
        import numpy, pyulog
        print(json.dumps({'protocol': 1, 'parserVersion': '\(AnalysisService.parserVersion)', 'python': sys.version.split()[0], 'numpy': numpy.__version__, 'pyulog': importlib.metadata.version('pyulog')}))
        """

    static func resolve(configuration: Configuration = .current,
                        launch: (Process) throws -> Void = { try $0.run() },
                        finished: () throws -> Void = {}) throws -> Runtime {
        let environment = sanitizedEnvironment(configuration.environment)
        if let bundle = configuration.bundleURL {
            let helper = bundle.appendingPathComponent("Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine")
            if FileManager.default.fileExists(atPath: helper.path) {
                guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                    throw AnalysisError.unavailable(reinstallMessage)
                }
                do {
                    try validate(helper, arguments: ["--katalog-runtime-info"], environment: environment,
                                 launch: launch, finished: finished)
                    return Runtime(executableURL: helper, environment: environment, kind: .bundled)
                } catch is CancellationError { throw CancellationError() }
                catch { throw AnalysisError.unavailable(reinstallMessage) }
            }
        }
        guard !configuration.bundledEngineRequired else { throw AnalysisError.unavailable(reinstallMessage) }

        if let custom = configuration.environment["KATALOG_PYTHON"], !custom.isEmpty {
            let executable = URL(fileURLWithPath: custom)
            do {
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw AnalysisError.unavailable("Runtime de développement inaccessible.")
                }
                try validate(executable, arguments: ["-B", "-c", externalProbe], environment: environment,
                             launch: launch, finished: finished)
                return Runtime(executableURL: executable, environment: environment, kind: .development)
            } catch is CancellationError { throw CancellationError() }
            catch {
                throw AnalysisError.unavailable("Le moteur défini par KATALOG_PYTHON ne fonctionne pas. Vérifiez cet override de développement et ses dépendances pyulog et numpy.")
            }
        }

        var paths = configuration.externalCandidates ?? defaultCandidates(environment: configuration.environment)
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0.path).inserted }
        for executable in paths where FileManager.default.isExecutableFile(atPath: executable.path) {
            do {
                try validate(executable, arguments: ["-B", "-c", externalProbe], environment: environment,
                             launch: launch, finished: finished)
                return Runtime(executableURL: executable, environment: environment, kind: .development)
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw AnalysisError.unavailable("Le moteur de développement PX4 est introuvable. Utilisez l’app installée depuis le DMG, qui contient son moteur, ou configurez KATALOG_PYTHON avec pyulog et numpy pour exécuter les sources.")
    }

    static func sanitizedEnvironment(_ source: [String: String]) -> [String: String] {
        var environment = source.filter { key, _ in
            !key.hasPrefix("PYTHON") && !key.hasPrefix("DYLD_") &&
            !["VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "CONDA_PROMPT_MODIFIER",
              "__PYVENV_LAUNCHER__", "LD_LIBRARY_PATH", "LD_PRELOAD", "KATALOG_PYTHON"].contains(key)
        }
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private static func defaultCandidates(environment: [String: String]) -> [URL] {
        var paths: [String] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(support.appendingPathComponent("KataLog/python/bin/python3").path)
        }
        paths += ["/opt/homebrew/opt/python@3.13/bin/python3.13", "/opt/homebrew/bin/python3.13",
                  "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private static func validate(_ executable: URL, arguments: [String], environment: [String: String],
                                 launch: (Process) throws -> Void, finished: () throws -> Void) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let outputURL = work.appendingPathComponent("runtime.json")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // A file prevents a helper's stdout from filling a pipe before waitUntilExit.
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try launch(process)
        let watchdog = ProbeWatchdog(process: process)
        watchdog.start()
        ProcessLifetime.wait(for: process)
        let timedOut = watchdog.finish()
        try finished()
        guard !timedOut, process.terminationStatus == 0 else {
            throw AnalysisError.unavailable("Le moteur PX4 n’a pas confirmé son bon fonctionnement.")
        }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw AnalysisError.unavailable("Réponse du moteur PX4 invalide.") }
        let info = try JSONDecoder().decode(RuntimeInfo.self, from: data)
        guard info.protocolVersion == 1, info.parserVersion == AnalysisService.parserVersion,
              !info.python.isEmpty, !info.numpy.isEmpty, !info.pyulog.isEmpty else {
            throw AnalysisError.unavailable("Version du moteur PX4 incompatible.")
        }
    }
}

/// Bounds runtime validation even if a damaged helper stops responding.
private final class ProbeWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var active = true
    private var timedOut = false

    init(process: Process) { self.process = process }
    func start() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard active, process.isRunning else { return }
            timedOut = true
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
                lock.lock(); defer { lock.unlock() }
                if active, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        active = false
        return timedOut
    }
}
