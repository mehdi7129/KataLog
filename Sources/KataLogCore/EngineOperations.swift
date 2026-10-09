import Foundation

/// Only helpers launched through KataLog's process controls are registered.
/// Termination closes the launch gate until exit or an explicitly cancelled quit.
public enum EngineOperations {
    static let registry = EngineOperationRegistry()

    public static var activeProcessCount: Int { registry.activeProcessCount }

    public static func beginTermination() { registry.beginTermination() }
    @discardableResult public static func cancelTermination() -> Bool { registry.cancelTermination() }
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
    /// A failed final save may cancel quit, but never reopen while old helpers
    /// still own operations or writer leases.
    func cancelTermination() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard controls.isEmpty else { return false }
        isTerminating = false
        return true
    }

}
