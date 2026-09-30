import XCTest
@testable import KataLogCore

final class TelemetryReportTests: XCTestCase {
    func testSVGUsesSeparatePathsAndDiscreteTransitionsAtRecordedTimes() throws {
        let curve = try JSONDecoder().decode(TelemetrySeries.self, from: Data(#"{"key":"state","label":"État <&\"","unit":"unknown","source":"topic.field","originalSampleCount":4,"interpolation":"step","points":[{"timeSeconds":0,"value":0,"segment":0},{"timeSeconds":1,"value":1,"segment":0},{"timeSeconds":10,"value":1,"segment":1},{"timeSeconds":11,"value":0,"segment":1}]}"#.utf8))
        let svg = TelemetryReport.svg(curve)
        XCTAssertEqual(svg.components(separatedBy: "data-telemetry-segment=").count - 1, 2)
        XCTAssertEqual(svg.components(separatedBy: "<circle ").count - 1, 4)
        XCTAssertTrue(svg.contains("H115.455V40.000"), "A state changes at the recorded x-time, without a diagonal ramp.")
        XCTAssertNil(svg.range(of: #"data-telemetry-segment="[^"]+" d="[^"]*L"#, options: .regularExpression),
                     "Step paths must not connect states with a slope.")
        XCTAssertTrue(svg.contains("État &lt;&amp;&quot;"))
        XCTAssertFalse(svg.contains("<script"))
    }

    func testEmptyAndExtremeSeriesKeepRawTableAvailableWithoutInvalidSVGCoordinates() throws {
        var curve = try JSONDecoder().decode(TelemetrySeries.self, from: Data(#"{"key":"empty","label":"Empty","unit":"unknown","source":"topic.field","originalSampleCount":0,"points":[]}"#.utf8))
        XCTAssertTrue(TelemetryReport.svg(curve).contains("Aucun point valide"))
        curve.points = [.init(timeSeconds: 0, value: -Double.greatestFiniteMagnitude, segment: 0),
                        .init(timeSeconds: 1, value: Double.greatestFiniteMagnitude, segment: 0)]
        let svg = TelemetryReport.svg(curve)
        XCTAssertFalse(svg.contains("inf")); XCTAssertTrue(svg.contains("valeurs restent dans le tableau"))
    }
}
