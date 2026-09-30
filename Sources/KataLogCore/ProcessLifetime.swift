import Darwin
import Foundation

/// Owns only the processes launched for one engine operation. Cancellation is
/// bounded even when that helper ignores SIGTERM; no remote action is implied.
final class ProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let grace: TimeInterval
    private let registry: EngineOperationRegistry

    init(grace: TimeInterval = 0.75, registry: EngineOperationRegistry = EngineOperations.registry) {
        self.grace = grace; self.registry = registry
    }

    func run(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        guard self.process == nil else { throw AnalysisError.engine("Un helper est déjà actif pour cette opération.") }
        try registry.register(self)
        do {
            try process.run()
            self.process = process
        } catch {
            registry.unregister(self)
            throw error
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let owned = process
        if let owned, owned.isRunning { owned.terminate() }
        lock.unlock()
        guard let owned else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [self, owned] in
            lock.lock(); defer { lock.unlock() }
            guard process === owned, owned.isRunning else { return }
            _ = Darwin.kill(owned.processIdentifier, SIGKILL)
        }
    }

    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        process = nil
        registry.unregister(self)
        if cancelled { throw CancellationError() }
    }

    /// Call from the operation's defer so every error path releases its entry.
    /// A still-running owned process is stopped before it leaves the registry.
    func cleanup() {
        lock.lock(); let owned = process; lock.unlock()
        if let owned, owned.isRunning {
            cancel()
            Self.wait(for: owned)
        }
        try? finish()
    }

    /// Foundation owns child reaping. Its run-loop based waitUntilExit can miss
    /// completion on a detached cooperative thread on macOS 27. Poll the
    /// thread-safe running state instead; cancellation escalates the owned PID.
    static func wait(for process: Process) {
        while process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
    }

    /// Poll instead of blocking in availableData: a child holding stdout open
    /// cannot prevent cancellation of the stream reader.
    func readChunk(from handle: FileHandle) throws -> Data? {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        while true {
            try checkCancellation()
            let result = Darwin.poll(&descriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw AnalysisError.engine("Le flux du moteur ne peut pas être lu.")
            }
            if result == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL | POLLERR) != 0 {
                throw AnalysisError.engine("Le flux du moteur a été fermé.")
            }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                throw AnalysisError.engine("La réponse du moteur ne peut pas être lue.")
            }
            return Data(bytes.prefix(count))
        }
    }
}
