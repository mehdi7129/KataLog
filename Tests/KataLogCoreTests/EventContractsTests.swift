import Foundation
import XCTest
import KataLogCore

final class EventContractsTests: XCTestCase {
    func testEventRequestAndCoverageRemainSeparateFromTextFilters() throws {
        var scope = SelectionScope(); scope.search = "textual filter"
        var request = LibraryQueryRequest(kind: "events", scope: scope)
        request.eventLevelSource = "external"; request.eventLevels = ["WARNING"]; request.eventSearch = "123"
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(json["eventLevelSource"], .string("external"))
        XCTAssertEqual(json["eventSearch"], .string("123"))
        XCTAssertEqual(json["scope"]?["search"], .string("textual filter"))
        let coverage = try JSONDecoder().decode(LibraryEventCoverage.self, from: Data(#"{"selectedLogs":12,"cachedLogs":3,"unavailableLogs":9,"legacyCacheLogs":1,"invalidCacheLogs":0,"eventLogs":1,"translatedLogs":0,"previousParserLogs":1}"#.utf8))
        XCTAssertEqual(coverage.selectedLogs, coverage.cachedLogs + coverage.unavailableLogs)
        XCTAssertEqual(coverage.translatedLogs, 0)
        XCTAssertEqual(coverage.eventLogs, 1)
    }
    func testCatalogueContainsInfoOnlyFamiliesAndUnknownLevels() throws {
        let page = try JSONDecoder().decode(LibraryCataloguePage.self, from: Data(#"{"queryVersion":1,"revision":7,"scopeHash":"demo","families":["Boot info","Unknown device"],"levels":["INFO","RAW","UNKNOWN"],"total":5,"nextCursor":null}"#.utf8))
        XCTAssertTrue(page.families.contains("Boot info"))
        XCTAssertTrue(page.levels.contains("UNKNOWN"))
        XCTAssertEqual(page.total, page.families.count + page.levels.count)
    }
}
