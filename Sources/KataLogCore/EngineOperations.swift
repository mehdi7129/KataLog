import Foundation

/// Only helpers launched through KataLog's process controls are registered.
/// Termination permanently closes the launch gate for this app instance.
public enum EngineOperations {
    static let registry = EngineOperationRegistry()

    public static var activeProcessCount: Int { registry.activeProcessCount }

    public static func beginTermination() { registry.beginTermination() }
}

final class EngineOperationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var controls: [ObjectIdentifier: ProcessLifetime] = [:]
    private var isTerminating = false

    var activeProcessCount: Int {
        lock.lock(); defer { lock.unlock() }
        return controls.count
    }

    func register(_ control: ProcessLifetime) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isTerminating else { throw CancellationError() }
        controls[ObjectIdentifier(control)] = control
    }

    func unregister(_ control: ProcessLifetime) {
        lock.lock(); defer { lock.unlock() }
        controls.removeValue(forKey: ObjectIdentifier(control))
    }

    func beginTermination() {
        lock.lock()
        isTerminating = true
        let owned = Array(controls.values)
        lock.unlock()
        // Do not hold the registry lock while entering a process control.
        for control in owned { control.cancel() }
    }
}
