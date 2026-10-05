import Darwin
import Foundation
import KataLogCore

/// In-memory query results. File identities include the WAL so a second, read-only
/// window never reuses results after another process commits to the library.
@MainActor
final class LibraryNavigationCache {
    enum Page {
        case history(LibraryLogPage, LibraryGroupPage)
        case map(LibraryMapPage)
        case drones(LibraryDronePage)
        case groups(LibraryGroupPage)
        case messages(LibraryMessagePage)
    }

    struct Stamp: Equatable {
        var generation: UInt64
        var files: [FileStamp]
    }
    struct FileStamp: Equatable {
        var inode: UInt64 = 0
        var size: Int64 = 0
        var modifiedSeconds: Int64 = 0
        var modifiedNanoseconds: Int64 = 0
        var changedSeconds: Int64 = 0
        var changedNanoseconds: Int64 = 0

        init(_ url: URL) {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ fstatat(AT_FDCWD, $0!, &info, 0) }) == 0 else { return }
            inode = UInt64(info.st_ino); size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    private let files: [URL]
    private var generation: UInt64 = 0
    private var entries: [Data: (page: Page, stamp: Stamp)] = [:]
    private var order: [Data] = []
    private let capacity = 8

    init(directory: URL) {
        files = ["library.sqlite", "library.sqlite-wal", "fleet.json"].map { directory.appendingPathComponent($0) }
    }

    static func key(_ request: LibraryQueryRequest) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // All request fields are finite Codable values. A failed encoding must
        // never accidentally match another request.
        return (try? encoder.encode(request)) ?? Data(UUID().uuidString.utf8)
    }

    func stamp(includeFleet: Bool = false) -> Stamp {
        Stamp(generation: generation, files: files.prefix(includeFleet ? 3 : 2).map(FileStamp.init))
    }

    func invalidate() {
        generation &+= 1
        entries.removeAll(); order.removeAll()
    }

    func value(for key: Data, includeFleet: Bool = false) -> Page? {
        guard let entry = entries[key] else { return nil }
        guard entry.stamp == stamp(includeFleet: includeFleet) else {
            entries.removeValue(forKey: key); order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }; order.append(key)
        return entry.page
    }

    func insert(_ page: Page, for key: Data, readStamp: Stamp) {
        guard readStamp == stamp(includeFleet: readStamp.files.count == 3) else { return }
        entries[key] = (page, readStamp)
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
    }
}
