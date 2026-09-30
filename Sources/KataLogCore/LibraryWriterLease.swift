import Darwin
import Foundation

@_silgen_name("flock")
private func libraryFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Advisory lock on a stable inode. Restore must keep the storage root and this
/// file in place. The lease is released automatically when the owning app exits.
public final class LibraryWriterLease: @unchecked Sendable {
    public let isWritable: Bool
    private let descriptor: Int32
    private let directoryKey: String
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryKey = Self.key(directory)
        let path = directory.appendingPathComponent(".library-writer.lock").path
        descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AnalysisError.engine("Impossible de réserver l’accès à la bibliothèque.") }
        isWritable = libraryFlock(descriptor, LOCK_EX | LOCK_NB) == 0
        if isWritable {
            let owner = "pid=\(getpid())\nbuild=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")\n"
            _ = Darwin.ftruncate(descriptor, 0)
            owner.withCString { _ = Darwin.write(descriptor, $0, strlen($0)) }
            _ = Darwin.fsync(descriptor)
            WriterLeaseDescriptors.shared.register(descriptor, for: directoryKey)
        }
    }
    deinit {
        // Closing the last copy releases flock. Explicit LOCK_UN would also
        // unlock an inherited helper copy while that helper is still writing.
        WriterLeaseDescriptors.shared.close(descriptor, for: isWritable ? directoryKey : nil)
    }

    private static func key(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The analyzer does not read stdin; requests use private --request files.
    /// Foundation duplicates this handle to fd 0 for the child. Only the
    /// already-owned writable lease for the exact library can be inherited.
    static func inheritedInput(for arguments: [String]) throws -> FileHandle? {
        let directory: URL
        if let index = arguments.firstIndex(of: "--library"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else if let index = arguments.firstIndex(of: "--database"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1]).deletingLastPathComponent()
        } else { return nil }
        return try WriterLeaseDescriptors.shared.duplicateInput(for: key(directory))
    }
}

private final class WriterLeaseDescriptors: @unchecked Sendable {
    static let shared = WriterLeaseDescriptors()
    private let lock = NSLock()
    private var descriptors: [String: Int32] = [:]

    func register(_ descriptor: Int32, for key: String) {
        lock.lock(); defer { lock.unlock() }
        descriptors[key] = descriptor
    }

    func close(_ descriptor: Int32, for key: String?) {
        lock.lock(); defer { lock.unlock() }
        if let key, descriptors[key] == descriptor { descriptors.removeValue(forKey: key) }
        _ = Darwin.close(descriptor)
    }

    func duplicateInput(for key: String) throws -> FileHandle? {
        lock.lock(); defer { lock.unlock() }
        guard let descriptor = descriptors[key] else { return nil }
        let copy = Darwin.dup(descriptor)
        guard copy >= 0 else { throw AnalysisError.engine("Impossible de protéger la bibliothèque pendant l’analyse.") }
        // The parent-side duplicate must not escape through another concurrent
        // exec. Foundation creates the intended child stdin independently.
        guard Darwin.fcntl(copy, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = Darwin.close(copy)
            throw AnalysisError.engine("Impossible de protéger la bibliothèque pendant l’analyse.")
        }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
    }
}
