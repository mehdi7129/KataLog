import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class LibraryNavigationCacheTests: XCTestCase {
    private func fixture() throws -> (URL, LibraryNavigationCache) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, LibraryNavigationCache(directory: directory))
    }

    private var page: LibraryNavigationCache.Page {
        get throws {
            let data = Data(#"{"queryVersion":1,"revision":1,"scopeHash":"fixture","groups":[],"total":0}"#.utf8)
            return .groups(try JSONDecoder().decode(LibraryGroupPage.self, from: data))
        }
    }

    func testFullRequestKeyDistinguishesAllSelectionDimensions() {
        let original = LibraryQueryRequest()
        var requests: [LibraryQueryRequest] = [original]
        var modified = original; modified.scope.clientID = "invented-client"; requests.append(modified)
        modified = original; modified.maskedMessageKeys = ["synthetic-rule"]; requests.append(modified)
        modified = original; modified.cursor = "page-two"; requests.append(modified)
        modified = original; modified.sortOrder = "oldest"; requests.append(modified)
        modified = original; modified.kind = "map-overview"; requests.append(modified)
        modified = original; modified.registrySearch = "synthetic-drone"; requests.append(modified)
        modified = original; modified.proximity = .init(latitude: 50, longitude: 0, radiusMeters: 1000); requests.append(modified)
        XCTAssertEqual(Set(requests.map(LibraryNavigationCache.key)).count, requests.count)
        XCTAssertEqual(LibraryNavigationCache.key(original), LibraryNavigationCache.key(original))
    }

    func testResultsAreBoundedAndMostRecentlyUsedEntrySurvives() throws {
        let (_, cache) = try fixture()
        let stamp = cache.stamp(), value = try page
        for index in 0..<8 { cache.insert(value, for: Data([UInt8(index)]), readStamp: stamp) }
        XCTAssertNotNil(cache.value(for: Data([0])))
        cache.insert(value, for: Data([8]), readStamp: stamp)
        XCTAssertNotNil(cache.value(for: Data([0])))
        XCTAssertNil(cache.value(for: Data([1])))
        XCTAssertNotNil(cache.value(for: Data([8])))
    }

    func testChangedDatabaseWALOrFleetRejectsResultsEvenWithoutExplicitInvalidation() throws {
        let (directory, cache) = try fixture()
        let key = Data([0]), value = try page
        for file in ["library.sqlite", "library.sqlite-wal", "fleet.json"] {
            let observesFleet = file == "fleet.json"
            let before = cache.stamp(includeFleet: observesFleet)
            cache.insert(value, for: key, readStamp: before)
            XCTAssertNotNil(cache.value(for: key, includeFleet: observesFleet))
            try Data([1]).write(to: directory.appendingPathComponent(file))
            XCTAssertNil(cache.value(for: key, includeFleet: observesFleet))
            cache.insert(value, for: key, readStamp: before)
            XCTAssertNil(cache.value(for: key, includeFleet: observesFleet), "A response read across a mutation cannot populate the cache.")
        }
    }

    func testGCSHeartbeatDoesNotInvalidateHistoryOrMap() throws {
        let (directory, cache) = try fixture()
        let historyKey = Data([0]), droneKey = Data([1]), value = try page
        cache.insert(value, for: historyKey, readStamp: cache.stamp())
        cache.insert(value, for: droneKey, readStamp: cache.stamp(includeFleet: true))
        try Data([1]).write(to: directory.appendingPathComponent("fleet.json"))
        XCTAssertNotNil(cache.value(for: historyKey))
        XCTAssertNil(cache.value(for: droneKey, includeFleet: true))
    }

    func testExplicitInvalidationRejectsInFlightOldGeneration() throws {
        let (_, cache) = try fixture()
        let before = cache.stamp(), key = Data([0]), value = try page
        cache.invalidate()
        cache.insert(value, for: key, readStamp: before)
        XCTAssertNil(cache.value(for: key))
        cache.insert(value, for: key, readStamp: cache.stamp())
        XCTAssertNotNil(cache.value(for: key))
    }
}
