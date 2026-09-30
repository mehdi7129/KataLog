import AppKit
import SwiftUI
import XCTest
@testable import KataLog
@testable import KataLogCore

@MainActor
final class DiagnosticStoreTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-diagnostic-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func journal(_ root: URL) -> DiagnosticJournal {
        DiagnosticJournal(directory: root.appendingPathComponent("Diagnostics"), configuration: .init(persistent: false))
    }
    private var report: DiagnosticReport {
        DiagnosticReport(appVersion: "test", appBuild: "1", operations: ["collection": false],
                         counts: ["logs": 3], countScope: ["logs": .activeSelection], runtimeBundled: false)
    }
    private func settle(_ store: DiagnosticStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading || store.isFetchingGCS || store.isExporting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.isLoading || store.isFetchingGCS || store.isExporting)
    }

    func testOpeningReviewNeverFetchesGCSAndOptInsAreIndependent() async throws {
        let root = try folder(), journal = journal(root), probe = DiagnosticServiceProbe()
        journal.record(.appStarted)
        let store = DiagnosticStore(journal: journal, serviceLoader: { host in try await probe.fetch(host) })
        store.load(report: report); try await settle(store)
        let serviceCalls = await probe.calls()
        XCTAssertEqual(serviceCalls, 0)
        XCTAssertEqual(store.eventCount, 1); XCTAssertTrue(store.canExport)
        XCTAssertFalse(store.includePrivateGCS); XCTAssertFalse(store.includeULogs)
        XCTAssertFalse(try XCTUnwrap(store.preview).privateDataIncluded)
        let source = root.appendingPathComponent("selected.ulg")
        try Data([0x55, 0x4c, 0x6f, 0x67, 0x01, 0x12, 0x35, 0x01] + Array(repeating: 0, count: 8)).write(to: source)
        store.selectULogs([source])
        XCTAssertTrue(store.privateULogs.isEmpty, "Selecting a file must not enable the private opt-in.")
        store.includeULogs = true
        XCTAssertEqual(store.privateULogs, [source]); XCTAssertTrue(store.preview?.privateDataIncluded == true)
        XCTAssertFalse(store.includePrivateGCS, "Choosing ULogs must not enable raw service logs.")
        store.includeULogs = false
        XCTAssertFalse(store.preview?.privateDataIncluded == true)
        store.dismiss()
        XCTAssertTrue(store.selectedULogs.isEmpty); XCTAssertNil(store.snapshot); XCTAssertNil(store.preview)
        XCTAssertFalse(store.includePrivateGCS); XCTAssertFalse(store.includeULogs)
    }

    func testGCSFailureLeavesLocalExportAvailableAndJournalExplainsTimeout() async throws {
        let root = try folder(), journal = journal(root)
        let store = DiagnosticStore(journal: journal, serviceLoader: { _ in throw GCSServiceDiagnosticsError.timeout })
        store.load(report: report); try await settle(store)
        store.fetchGCS(host: "example.invalid"); try await settle(store)
        XCTAssertTrue(store.serviceMessage?.contains("temps") == true)
        XCTAssertTrue(store.serviceFiles.isEmpty); XCTAssertTrue(store.canExport)
        XCTAssertEqual(store.snapshot?.events.last?.kind, .gcsDiagnosticsFailed)
        XCTAssertEqual(store.snapshot?.events.last?.code, .timeout)
        XCTAssertTrue(store.snapshotJSON.contains("activeSelection"), "Refreshing journal preserves report count scope.")
    }

    func testCancelAndEndpointChangeRejectLateServiceCapture() async throws {
        let root = try folder(), journal = journal(root), probe = DiagnosticServiceProbe()
        let store = DiagnosticStore(journal: journal, serviceLoader: { host in try await probe.fetch(host) })
        store.load(report: report); try await settle(store)
        store.fetchGCS(host: "old.invalid")
        for _ in 0..<100 where await probe.calls() == 0 { await Task.yield() }
        XCTAssertTrue(store.isFetchingGCS)
        store.endpointChanged(to: "new.invalid")
        await probe.complete(host: "old.invalid", result: .init(files: [.init(name: "python.log", text: "WARNING synthetic")]))
        try await settle(store)
        XCTAssertNil(store.serviceCapturedAt); XCTAssertTrue(store.serviceFiles.isEmpty)
        XCTAssertTrue(store.serviceMessage?.contains("changé") == true)
        XCTAssertTrue(store.canExport)
        XCTAssertEqual(store.snapshot?.events.last?.code, .cancelled)
    }

    func testManualServiceCaptureOnlyExportsAllowlistedSourcesAndResetsOnDismiss() async throws {
        let root = try folder(), journal = journal(root)
        let store = DiagnosticStore(journal: journal, serviceLoader: { _ in
            .init(files: [.init(name: "python.log", text: "ERROR synthetic secret endpoint"),
                          .init(name: "unexpected.txt", text: "not a service")])
        })
        store.load(report: report); try await settle(store)
        store.fetchGCS(host: "example.invalid"); try await settle(store)
        XCTAssertEqual(store.serviceFiles.map(\.source), [.python])
        XCTAssertEqual(store.preview?.gcsSourceCount, 1); XCTAssertFalse(store.preview?.privateDataIncluded == true)
        XCTAssertEqual(store.snapshot?.events.last?.kind, .gcsDiagnosticsCompleted)
        store.includePrivateGCS = true; XCTAssertTrue(store.preview?.privateDataIncluded == true)
        store.dismiss()
        XCTAssertTrue(store.serviceFiles.isEmpty); XCTAssertNil(store.serviceCapturedAt); XCTAssertFalse(store.includePrivateGCS)
    }

    func testExportCancellationWaitsForCleanupAndPreservesExistingDestination() async throws {
        let root = try folder(), destination = root.appendingPathComponent("existing.zip")
        let before = Data("previous complete archive".utf8); try before.write(to: destination)
        let store = DiagnosticStore(journal: journal(root), exporter: { _, _, _, _, _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        })
        store.load(report: report); try await settle(store)
        store.export(to: destination); XCTAssertTrue(store.isExporting); XCTAssertFalse(store.canExport)
        store.prepareForTermination(); XCTAssertTrue(store.isCancellingExport)
        try await settle(store)
        XCTAssertFalse(store.isCancellingExport); XCTAssertTrue(store.exportMessage?.contains("annulé") == true)
        XCTAssertNil(store.errorMessage); XCTAssertEqual(try Data(contentsOf: destination), before)
        XCTAssertTrue(store.canExport)
    }

    func testBadULogSelectionCannotPublishAndRemovingItRestoresReview() async throws {
        let root = try folder(), store = DiagnosticStore(journal: journal(root))
        store.load(report: report); try await settle(store)
        let wrong = root.appendingPathComponent("not-a-log.txt"); try Data("synthetic".utf8).write(to: wrong)
        store.includeULogs = true; store.selectULogs([wrong])
        XCTAssertNil(store.preview); XCTAssertFalse(store.canExport); XCTAssertNotNil(store.errorMessage)
        store.selectULogs([])
        XCTAssertNotNil(store.preview); XCTAssertTrue(store.canExport); XCTAssertNil(store.errorMessage)
    }

    func testClearRequiresWritableInstanceAndPreservesSources() async throws {
        let root = try folder(), journal = journal(root), source = root.appendingPathComponent("private-source.ulg")
        let original = Data("original source remains untouched".utf8); try original.write(to: source)
        journal.record(.appStarted); journal.record(.gcsConnected)
        let reader = DiagnosticStore(journal: journal, canWrite: { false })
        reader.load(report: report); try await settle(reader)
        reader.clearJournal()
        XCTAssertNotNil(reader.errorMessage); XCTAssertEqual(try journal.snapshot().events.count, 2)
        let writer = DiagnosticStore(journal: journal)
        writer.load(report: report); try await settle(writer)
        writer.clearJournal(); XCTAssertTrue(writer.isClearingJournal); try await settle(writer)
        XCTAssertEqual(writer.snapshot?.events.map(\.kind), [.journalCleared])
        XCTAssertFalse(writer.isClearingJournal); XCTAssertTrue(writer.canExport)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExportFailureKeepsReviewAndDoesNotWriteFreeTextToJournal() async throws {
        let root = try folder(), journal = journal(root)
        let store = DiagnosticStore(journal: journal, exporter: { _, _, _, _, _, _ in
            throw NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "private arbitrary error text"])
        })
        store.load(report: report); try await settle(store)
        store.export(to: root.appendingPathComponent("failed.zip")); try await settle(store)
        XCTAssertNotNil(store.errorMessage); XCTAssertTrue(store.canExport)
        let snapshot = try journal.snapshot()
        XCTAssertEqual(snapshot.events.last?.code, .exportFailed)
        XCTAssertFalse(String(decoding: try snapshot.jsonLines(), as: UTF8.self).contains("private arbitrary"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("failed.zip").path))
    }

    func testBentoDiagnosticFitsBothThemesAtMinimumWindowWithoutNetwork() async throws {
        let root = try folder(), journal = journal(root)
        journal.record(.appStarted); journal.record(.gcsConnected)
        journal.record(.transferProgress, phase: .http, metrics: [.bytes: 350_000, .totalBytes: 1_000_000])
        journal.record(.transferRetrying, code: .timeout)
        _ = NSApplication.shared
        for scheme in [ColorScheme.dark, .light] {
            let store = DiagnosticStore(journal: journal, serviceLoader: { _ in
                .init(files: [.init(name: "python.log", text: "2026-01-01T12:00:00Z ERROR transfer timeout")])
            })
            store.load(report: report); try await settle(store)
            store.fetchGCS(host: "example.invalid"); try await settle(store)
            let view = DiagnosticView(store: store, host: "example.invalid", readOnly: false, refresh: {}, close: {})
                .environment(\.colorScheme, scheme).preferredColorScheme(scheme)
            let controller = NSHostingController(rootView: view)
            let size = NSSize(width: 820, height: 620)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentViewController = controller; window.setContentSize(size)
            controller.view.frame = NSRect(origin: .zero, size: size)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            controller.view.layoutSubtreeIfNeeded()
            let fit = controller.sizeThatFits(in: size)
            XCTAssertLessThanOrEqual(fit.width, size.width + 0.5); XCTAssertLessThanOrEqual(fit.height, size.height + 0.5)
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5_000)
            if let output = ProcessInfo.processInfo.environment["KATALOG_UI_ARTIFACTS"] {
                let folder = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("diagnostic-\(scheme)-minimum.png"))
            }
            window.close()
        }
    }
}

private actor DiagnosticServiceProbe {
    private var count = 0
    private var pending: [String: CheckedContinuation<GCSServiceDiagnosticsResult, Error>] = [:]
    func calls() -> Int { count }
    func fetch(_ host: String) async throws -> GCSServiceDiagnosticsResult {
        count += 1
        return try await withCheckedThrowingContinuation { pending[host] = $0 }
    }
    func complete(host: String, result: GCSServiceDiagnosticsResult) { pending.removeValue(forKey: host)?.resume(returning: result) }
}
