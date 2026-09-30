import Foundation
import XCTest
@preconcurrency import WebKit
@preconcurrency import AppKit
@testable import KataLogCore

/// Exercises the generated document in the system WebKit DOM, without a user's
/// browser profile, network dependency, or operational log fixture.
@MainActor
final class ReportDOMTests: XCTestCase {
    func testFilteredOccurrenceCellsAndResetUseTheSameMessages() async throws {
        let page = try await load(snapshot([
            log("one", messages: [message("a", text: "GPS error"), message("b", text: "GPS  error")]),
            log("two", messages: [message("c", text: "GPS error")])
        ]))
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.message-row,.group-occurrence').length") as? Int, 0)
        try await page.evaluateJavaScript("document.querySelector('.alert-group').open=true;document.getElementById('expand-logs').click()")
        try await wait(in: page, until: "document.querySelectorAll('.message-row').length===3 && document.querySelectorAll('.group-occurrence').length===2")
        assertEqual(try await text(".group-occurrence[data-log='one'] .occurrence-message-count", in: page), "2")
        try await page.evaluateJavaScript("document.getElementById('report-search').value='GPS  error';document.getElementById('report-search').dispatchEvent(new Event('input',{bubbles:true}));")
        try await wait(in: page, until: "document.getElementById('group-summary').textContent.includes('1 message')")
        assertEqual(try await text(".group-occurrence[data-log='one'] .occurrence-message-count", in: page), "1")
        assertEqual(try await page.evaluateJavaScript("document.querySelector('.group-occurrence[data-log=\"two\"]')===null") as? Bool, true)
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.log-card:not([hidden]) .message-row:not([hidden])').length") as? Int, 1)
        try await page.evaluateJavaScript("document.getElementById('reset-filters').click()")
        assertEqual(try await text(".group-occurrence[data-log='one'] .occurrence-message-count", in: page), "2")
        assertEqual(try await page.evaluateJavaScript("document.querySelector('.group-occurrence[data-log=\"two\"]')!==null") as? Bool, true)
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.message-row:not([hidden])').length") as? Int, 3)
    }

    func testFailsafeIsSeparateFromTextualFamiliesAndMessages() async throws {
        var flight = log("failsafe", messages: [])
        flight.failsafeObserved = true
        let page = try await load(snapshot([flight]))
        assertEqual(try await text("#stat-alerts", in: page), "1 / 1")
        assertTrue(try await text("#stat-alert-detail", in: page).contains("1 log avec failsafe"))
        assertTrue(try await text("#family-chart", in: page).contains("sans famille d’alerte textuelle"))
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.alert-group,.message-row,.family-row').length") as? Int, 0)
    }

    func testCapturedSelectionDoesNotRestoreExcludedFailsafeOnReset() async throws {
        var informational = message("info", text: "Synthetic information")
        informational.level = "INFO"; informational.alertFlag = false
        var flight = log("captured", messages: [informational])
        flight.failsafeObserved = true; flight.selectionIncludesFailsafe = false
        let page = try await load(snapshot([flight]))
        assertEqual(try await text("#stat-alerts", in: page), "0 / 1")
        try await page.evaluateJavaScript("document.getElementById('reset-filters').click()")
        assertEqual(try await text("#stat-alerts", in: page), "0 / 1")
        assertTrue(try await text("#stat-alert-detail", in: page).contains("0 message"))
    }

    func testFlightCoverageProvisionalIdentityBadgesAndHelpFollowVisibleScope() async throws {
        var measured = log("measured", messages: [message("error", text: "Navigation error")])
        measured.flightSeconds = 30
        var warning = message("warning", text: "Battery warning")
        warning.level = "WARNING"; warning.family = "Batterie"
        var unknown = log("unknown", messages: [warning])
        unknown.droneID = "card:synthetic"; unknown.status = "partial"
        let page = try await load(snapshot([measured, unknown]))
        assertEqual(try await text("#stat-drones", in: page), "1")
        assertTrue(try await text("#stat-provisional", in: page).contains("1 identité provisoire"))
        assertEqual(try await text("#stat-flight-coverage", in: page), "Calculé sur 1 / 2 logs")
        assertEqual(try await text("#log-1 .log-status", in: page), "Lecture partielle")
        assertEqual(try await text("#log-1 .log-assessment", in: page), "Avertissement")
        try await page.evaluateJavaScript("document.querySelector('.report-help summary').focus();document.activeElement.click()")
        assertEqual(try await page.evaluateJavaScript("document.activeElement.closest('details').open") as? Bool, true)
        assertTrue(try await page.evaluateJavaScript("document.activeElement.getAttribute('aria-label').startsWith('Aide :')") as? Bool == true)
        try await page.evaluateJavaScript("document.getElementById('family-filter').value='Batterie';document.getElementById('family-filter').dispatchEvent(new Event('change'))")
        assertEqual(try await text("#stat-flight", in: page), "Non disponible")
        assertEqual(try await text("#stat-flight-coverage", in: page), "Calculé sur 0 / 1 logs")
        assertEqual(try await text("#stat-drones", in: page), "0")
        assertTrue(try await text("#assessment-scope", in: page).contains("événements PX4 et état failsafe exclus"))
        try await page.evaluateJavaScript("window.dispatchEvent(new Event('beforeprint'));window.dispatchEvent(new Event('afterprint'))")
        assertEqual(try await page.evaluateJavaScript("document.querySelector('.report-help').open") as? Bool, true)
        try await page.evaluateJavaScript("document.getElementById('reset-filters').click()")
        assertEqual(try await text("#stat-flight-coverage", in: page), "Calculé sur 1 / 2 logs")
        try await page.evaluateJavaScript("document.querySelector('.report-help').open=false")
        try await capture(page, name: "report-top-js")
    }

    func testUnicodeHostileSourceThemeAndPrintLifecycleRemainSafe() async throws {
        let attack = "</script><img src=x onerror=window.__sourceExecuted=true>\u{2028}\u{2029} Batterie éè 漢字"
        let page = try await load(snapshot([log("unicode", messages: [message("unsafe", text: attack)])]))
        try await page.evaluateJavaScript("document.getElementById('expand-logs').click()")
        try await wait(in: page, until: "document.querySelectorAll('.message-row').length===1")
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('img').length") as? Int, 0)
        assertEqual(try await page.evaluateJavaScript("Boolean(window.__sourceExecuted)") as? Bool, false)
        assertTrue(try await text(".message-row .raw", in: page).contains("Batterie éè 漢字"))
        let theme = try await page.evaluateJavaScript("document.documentElement.dataset.theme || ''") as? String
        try await page.evaluateJavaScript("document.getElementById('theme-toggle').click()")
        assertNotEqual(try await page.evaluateJavaScript("document.documentElement.dataset.theme || ''") as? String, theme)
        try await page.evaluateJavaScript("window.__beforePrint=Array.from(document.querySelectorAll('details')).map(n=>n.open);window.dispatchEvent(new Event('beforeprint')); ")
        assertEqual(try await page.evaluateJavaScript("Array.from(document.querySelectorAll('details')).every(n=>n.open)") as? Bool, true)
        try await page.evaluateJavaScript("window.dispatchEvent(new Event('afterprint'))")
        assertEqual(try await page.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('details')).map(n=>n.open))===JSON.stringify(window.__beforePrint)") as? Bool, true)
    }

    func testWithoutContentJavaScriptSourceAndDetailsRemainInDocument() async throws {
        let page = try await load(snapshot([log("offline", messages: [message("raw", text: "Source offline éè")])]), javascript: false)
        assertTrue(try await text(".message-row .raw", in: page).contains("Source offline éè"))
        assertTrue(try await text(".log-body", in: page).contains("SHA256"))
        assertEqual(try await page.evaluateJavaScript("document.getElementById('filter-controls').hidden && document.getElementById('report-actions').hidden") as? Bool, true)
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.log-card').length") as? Int, 1)
        assertEqual(try await page.evaluateJavaScript("document.querySelector('.log-card').hidden") as? Bool, false)
        try await page.evaluateJavaScript("document.querySelector('.report-help summary').focus();document.activeElement.click()")
        assertEqual(try await page.evaluateJavaScript("document.activeElement.closest('details').open") as? Bool, true)
        try await capture(page, name: "report-desktop-no-js")
    }

    func testLongDetailPaginationPrintSelectionAndCloseRestoreAllMessages() async throws {
        let attack = "</noscript></script><img src=x onerror=window.__sourceExecuted=true> éè 漢字\u{2028}\u{2029}"
        let messages = (0..<251).map { i in
            var value = message("long-\(i)", text: i == 150 ? attack : "Invented occurrence \(i)")
            value.groupKey = "shared-long-group"; value.title = "Long synthetic group"
            return value
        }
        var info = message("info", text: "Informational unrelated source")
        info.level = "INFO"; info.alertFlag = false
        let page = try await load(snapshot([log("long", messages: messages), log("other", messages: [info])]))
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.message-row,.group-occurrence').length") as? Int, 0)
        try await page.evaluateJavaScript("document.getElementById('log-0').open=true")
        try await wait(in: page, until: "document.querySelectorAll('#log-0 .message-row').length===100")
        assertTrue(try await text("#log-0 .detail-pagination", in: page).contains("1–100 / 251 messages"))
        try await page.evaluateJavaScript("document.querySelector('#log-0 .detail-pagination button:last-of-type').focus();document.activeElement.click()")
        assertEqual(try await page.evaluateJavaScript("document.querySelector('#log-0 .message-row').dataset.index") as? String, "100")
        assertEqual(try await page.evaluateJavaScript("document.activeElement.dataset.detailPage") as? String, "next")
        assertTrue(try await text("#log-0 .message-table", in: page).contains(attack))
        assertEqual(try await page.evaluateJavaScript("Boolean(window.__sourceExecuted)||document.querySelectorAll('img').length>0") as? Bool, false)
        try await page.evaluateJavaScript("document.querySelector('#log-0 .detail-pagination button:last-of-type').click()")
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('#log-0 .message-row').length") as? Int, 51)
        assertEqual(try await page.evaluateJavaScript("document.querySelector('#log-0 .detail-pagination button:last-of-type').disabled") as? Bool, true)
        assertEqual(try await page.evaluateJavaScript("document.activeElement.dataset.detailPage") as? String, "previous")
        // Filtering changes the selection, not the payload or its global totals.
        try await page.evaluateJavaScript("document.getElementById('level-filter').value='ERROR+';document.getElementById('level-filter').dispatchEvent(new Event('change'));document.querySelector('#log-0 .detail-pagination button:last-of-type').click()")
        assertEqual(try await page.evaluateJavaScript("JSON.parse(document.getElementById('report-data').textContent).logs[0].messages.length") as? Int, 251)
        try await page.evaluateJavaScript("window.dispatchEvent(new Event('beforeprint'))")
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.log-card:not([hidden]) .message-row').length") as? Int, 251)
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('#log-1 .message-row').length") as? Int, 0)
        try await page.evaluateJavaScript("window.dispatchEvent(new Event('afterprint'))")
        try await wait(in: page, until: "document.querySelectorAll('#log-0 .message-row').length===100")
        assertEqual(try await page.evaluateJavaScript("document.querySelector('#log-0 .message-row').dataset.index") as? String, "100")
        try await page.evaluateJavaScript("document.getElementById('log-0').open=false")
        try await wait(in: page, until: "document.querySelectorAll('.message-row,.group-occurrence').length===0")
        try await page.evaluateJavaScript("document.getElementById('log-0').open=true")
        try await wait(in: page, until: "document.querySelectorAll('#log-0 .message-row').length===100")
        assertEqual(try await page.evaluateJavaScript("document.querySelector('#log-0 .message-row').dataset.index") as? String, "100")
    }

    func testScriptFailureMaterializesCompleteEscapedFallbackAndLeavesNoHiddenRows() async throws {
        let attack = "</noscript><img src=x onerror=window.__sourceExecuted=true> Éè 漢字"
        let messages = (0..<251).map { message("fallback-\($0)", text: $0 == 150 ? attack : "Fallback \($0)") }
        let page = try await load(snapshot([log("fallback", messages: messages)]), corruptPayload: true)
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.message-row').length") as? Int, 251)
        assertTrue(try await text(".message-table", in: page).contains(attack))
        assertEqual(try await page.evaluateJavaScript("Boolean(window.__sourceExecuted)||document.querySelectorAll('img').length>0") as? Bool, false)
        assertEqual(try await page.evaluateJavaScript("document.querySelectorAll('.lazy-message-table,.lazy-occurrence-table').length") as? Int, 0)
        assertTrue(try await text(".scope-bar", in: page).contains("rapport complet reste disponible"))
    }

    private func load(_ snapshot: FleetSnapshot, javascript: Bool = true, corruptPayload: Bool = false) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = javascript
        let page = WKWebView(frame: .zero, configuration: configuration)
        var html = ReportRenderer.html(snapshot)
        if corruptPayload { html = html.replacingOccurrences(of: "<script id=\"report-data\" type=\"application/json\">", with: "<script id=\"report-data\" type=\"application/json\">invalid-json") }
        page.loadHTMLString(html, baseURL: nil)
        let ready = corruptPayload ? "document.querySelectorAll('.message-row').length===251" : javascript ? "!document.getElementById('filter-controls').hidden" : "Boolean(document.querySelector('.log-card'))"
        try await wait(in: page, until: "document.readyState==='complete' && (\(ready))")
        return page
    }

    private func wait(in page: WKWebView, until expression: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (try? await page.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("WebKit document did not reach the expected state within 20 seconds: \(expression)")
        throw NSError(domain: "KataLog.ReportDOMTests", code: 1)
    }

    /// Optional visual artifacts from the same invented data and WebKit DOM.
    /// The normal gate never depends on screenshot permissions or a browser.
    private func capture(_ page: WKWebView, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["KATALOG_REPORT_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        page.frame = CGRect(x: 0, y: 0, width: 1360, height: 1500)
        try await page.evaluateJavaScript("window.scrollTo(0,0)")
        try await Task.sleep(for: .milliseconds(150))
        let screenshot = try await page.takeSnapshot(configuration: nil)
        let tiff = try XCTUnwrap(screenshot.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func text(_ selector: String, in page: WKWebView) async throws -> String {
        let encoded = String(data: try JSONEncoder().encode(selector), encoding: .utf8)!
        let result = try await page.evaluateJavaScript("document.querySelector(\(encoded))?.textContent ?? ''") as? String
        return try XCTUnwrap(result)
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func assertNotEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(actual, expected, file: file, line: line)
    }
    private func assertTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual, file: file, line: line)
    }

    private func message(_ id: String, text: String) -> LogMessage {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return LogMessage(id: id, timestampSeconds: 1, level: "ERROR", text: text, family: "Navigation", groupKey: "Navigation|ERROR|" + normalized, title: normalized, alertFlag: true)
    }
    private func log(_ id: String, messages: [LogMessage]) -> FlightLog {
        FlightLog(id: id, droneID: "synthetic-controller", droneName: "Drone test", date: "2030-01-01T12:00:00Z", dateSource: "gps", sourcePaths: ["/synthetic/\(id).ulg"], fileName: id + ".ulg", sizeBytes: 1, durationSeconds: 60, flightSeconds: nil, status: "ok", issues: [], metadata: [:], topics: [], messages: messages, metrics: [], coverage: [], failsafeObserved: false)
    }
    private func snapshot(_ logs: [FlightLog]) -> FleetSnapshot {
        FleetSnapshot(schemaVersion: 1, generatedAt: "2030-01-01T12:00:00Z", sourceFolders: ["/synthetic"], importStats: .empty, logs: logs)
    }
}
