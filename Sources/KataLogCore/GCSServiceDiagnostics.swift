import Foundation

public struct GCSServiceDiagnosticFile: Sendable, Equatable {
    public let name: String
    public let text: String
    public init(name: String, text: String) { self.name = name; self.text = text }
}

public struct GCSServiceDiagnosticsResult: Sendable {
    public let files: [GCSServiceDiagnosticFile]
    public let fetchedAt: Date
    public let currentBootOnly = true
    public init(files: [GCSServiceDiagnosticFile], fetchedAt: Date = Date()) {
        self.files = files; self.fetchedAt = fetchedAt
    }
}

public enum GCSServiceDiagnosticsError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint, unsupported, timeout, offline, redirectDenied, tooLarge, unsafeArchive, invalidArchive
    case server(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Adresse GCS invalide. Choisissez une adresse HTTP ou HTTPS sans identifiants."
        case .unsupported: "Ce firmware GCS ne propose pas l’export des journaux de services. Le diagnostic KataLog reste disponible."
        case .timeout: "La GCS n’a pas répondu à temps. Réessayez lorsqu’elle sera disponible."
        case .offline: "La GCS est inaccessible. Vérifiez sa connexion ; le diagnostic KataLog reste disponible."
        case .redirectDenied: "La GCS a demandé une redirection. Aucun journal n’a été demandé à une autre adresse."
        case .tooLarge: "Les journaux GCS dépassent la limite du diagnostic. Aucun fichier partiel n’a été conservé."
        case .unsafeArchive: "L’archive GCS contient des entrées inattendues ou non sûres. Elle a été refusée."
        case .invalidArchive: "La réponse GCS n’est pas une archive de journaux valide."
        case .server(let status): "L’export GCS a échoué (HTTP \(status)). Le diagnostic KataLog reste disponible."
        }
    }
}

/// This reads a service export only. No MQTT, FTP or drone command is sent.
public enum GCSServiceDiagnostics {
    public struct Limits: Sendable {
        public var archiveBytes = 20 * 1024 * 1024
        public var entryBytes = 2 * 1024 * 1024
        public var totalTextBytes = 8 * 1024 * 1024
        public var timeout: TimeInterval = 30
        public init() {}
    }
    private static let names: Set<String> = ["mosquitto.log", "reactor.log", "python.log", "node.log", "metadata.json"]

    public static func endpoint(host: String) throws -> URL {
        let input = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 2048 else { throw GCSServiceDiagnosticsError.invalidEndpoint }
        var components: URLComponents
        if input.contains("://") {
            guard let parsed = URLComponents(string: input), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.user == nil, parsed.password == nil, parsed.query == nil,
                  ["", "/", "/servicelogs"].contains(parsed.path) else { throw GCSServiceDiagnosticsError.invalidEndpoint }
            components = parsed
        } else {
            guard input.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]%_").contains($0) }) else { throw GCSServiceDiagnosticsError.invalidEndpoint }
            components = URLComponents(); components.scheme = "http"; components.host = input; components.port = 8080
        }
        components.path = "/servicelogs"; components.fragment = nil
        guard let url = components.url, let host = components.host, !host.isEmpty else { throw GCSServiceDiagnosticsError.invalidEndpoint }
        try validateEndpoint(url)
        return url
    }

    private static func validateEndpoint(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path == "/servicelogs" else {
            throw GCSServiceDiagnosticsError.invalidEndpoint
        }
    }

    public static func fetch(endpoint: URL, session supplied: URLSession? = nil, limits: Limits = Limits()) async throws -> GCSServiceDiagnosticsResult {
        try validateEndpoint(endpoint)
        guard limits.archiveBytes > 0, limits.entryBytes > 0, limits.totalTextBytes > 0, limits.timeout > 0 else { throw GCSServiceDiagnosticsError.tooLarge }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limits.timeout; configuration.timeoutIntervalForResource = limits.timeout
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = supplied ?? URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { if supplied == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: limits.timeout)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw GCSServiceDiagnosticsError.invalidArchive }
            switch response.statusCode {
            case 200: break
            case 301...399: throw GCSServiceDiagnosticsError.redirectDenied
            case 404, 405, 501: throw GCSServiceDiagnosticsError.unsupported
            default: throw GCSServiceDiagnosticsError.server(response.statusCode)
            }
            guard response.url == endpoint else { throw GCSServiceDiagnosticsError.redirectDenied }
            guard response.expectedContentLength <= limits.archiveBytes else { throw GCSServiceDiagnosticsError.tooLarge }
            var bytes = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard bytes.count < limits.archiveBytes else { throw GCSServiceDiagnosticsError.tooLarge }
                bytes.append(byte)
            }
            data = bytes
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? GCSServiceDiagnosticsError { throw error }
            if (error as? URLError)?.code == .timedOut { throw GCSServiceDiagnosticsError.timeout }
            throw GCSServiceDiagnosticsError.offline
        }
        return GCSServiceDiagnosticsResult(files: try await decodeArchive(data, limits: limits))
    }

    /// Validate all central and local headers before reading any entry. We never
    /// extract an archive path: only exact allowlisted names are read into memory.
    static func decodeArchive(_ data: Data, limits: Limits = Limits()) async throws -> [GCSServiceDiagnosticFile] {
        guard data.count <= limits.archiveBytes else { throw GCSServiceDiagnosticsError.tooLarge }
        let entries = try validateArchive(data, limits: limits)
        let control = ProcessLifetime()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                defer { control.cleanup() }
                try Task.checkCancellation(); try control.checkCancellation()
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-service-diagnostic-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: root) }
                let archive = root.appendingPathComponent("services.zip")
                try data.write(to: archive, options: .atomic)
                var result: [GCSServiceDiagnosticFile] = []
                var total = 0
                for entry in entries.sorted(by: { $0.name < $1.name }) {
                    try control.checkCancellation()
                    let process = Process(), pipe = Pipe()
                    defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    process.arguments = ["-p", archive.path, entry.name]
                    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
                    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                    try control.run(process)
                    var output = Data()
                    while let chunk = try control.readChunk(from: pipe.fileHandleForReading) {
                        guard output.count + chunk.count <= limits.entryBytes,
                              total + output.count + chunk.count <= limits.totalTextBytes else { throw GCSServiceDiagnosticsError.tooLarge }
                        output.append(chunk)
                    }
                    ProcessLifetime.wait(for: process); try control.finish()
                    guard process.terminationStatus == 0, output.count == entry.bytes,
                          let text = String(data: output, encoding: .utf8), !text.contains("\0") else { throw GCSServiceDiagnosticsError.invalidArchive }
                    total += output.count; result.append(.init(name: entry.name, text: text))
                }
                return result
            }.value
        } onCancel: { control.cancel() }
    }

    private struct Entry { let name: String; let bytes: Int }
    private static func validateArchive(_ data: Data, limits: Limits) throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) throws -> Int {
            guard i >= 0, i + 2 <= bytes.count else { throw GCSServiceDiagnosticsError.invalidArchive }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8
        }
        func u32(_ i: Int) throws -> Int {
            guard i >= 0, i + 4 <= bytes.count else { throw GCSServiceDiagnosticsError.invalidArchive }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        guard bytes.count >= 22 else { throw GCSServiceDiagnosticsError.invalidArchive }
        let lower = max(0, bytes.count - 65557)
        let candidates: StrideThrough<Int> = stride(from: bytes.count - 22, through: lower, by: -1)
        let endOffset: Int? = candidates.first { (i: Int) -> Bool in
            guard bytes[i] == 0x50, bytes[i + 1] == 0x4b,
                  bytes[i + 2] == 5, bytes[i + 3] == 6 else { return false }
            let commentLow: Int = Int(bytes[i + 20])
            let commentHigh: Int = Int(bytes[i + 21]) << 8
            let commentLength: Int = commentLow | commentHigh
            let recordEnd: Int = i + 22 + commentLength
            return recordEnd == bytes.count
        }
        guard let end = endOffset else { throw GCSServiceDiagnosticsError.invalidArchive }
        let count = try u16(end + 10), offset = try u32(end + 16), size = try u32(end + 12)
        guard try u16(end+4) == 0, try u16(end+6) == 0, try u16(end+8) == count,
              (1...names.count).contains(count), offset + size == end else { throw GCSServiceDiagnosticsError.unsafeArchive }
        var cursor = offset, total = 0, seen = Set<String>(), entries: [Entry] = []
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw GCSServiceDiagnosticsError.invalidArchive }
            let flags = try u16(cursor+8), method = try u16(cursor+10), length = try u16(cursor+28)
            let extra = try u16(cursor+30), comment = try u16(cursor+32), compressed = try u32(cursor+20), expanded = try u32(cursor+24)
            let local = try u32(cursor+42), mode = (try u32(cursor+38) >> 16) & 0o170000
            let next = cursor + 46 + length + extra + comment
            guard length > 0, next <= end, try u16(cursor+34) == 0, flags & 1 == 0,
                  [0, 8].contains(method), [0, 0o100000].contains(mode),
                  let name = String(bytes: bytes[(cursor+46)..<(cursor+46+length)], encoding: .utf8), names.contains(name),
                  seen.insert(name).inserted else { throw GCSServiceDiagnosticsError.unsafeArchive }
            guard expanded <= limits.entryBytes, total + expanded <= limits.totalTextBytes else { throw GCSServiceDiagnosticsError.tooLarge }
            guard local + 30 <= offset, try u32(local) == 0x04034b50, try u16(local+6) == flags, try u16(local+8) == method,
                  try u16(local+26) == length else { throw GCSServiceDiagnosticsError.unsafeArchive }
            let localExtra = try u16(local+28), localEnd = local + 30 + length + localExtra
            guard localEnd + compressed <= offset,
                  bytes[(local+30)..<(local+30+length)].elementsEqual(bytes[(cursor+46)..<(cursor+46+length)]) else { throw GCSServiceDiagnosticsError.unsafeArchive }
            total += expanded; entries.append(Entry(name: name, bytes: expanded)); cursor = next
        }
        guard cursor == end else { throw GCSServiceDiagnosticsError.invalidArchive }
        return entries
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
