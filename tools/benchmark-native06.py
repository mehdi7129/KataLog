#!/usr/bin/env python3
"""Isolated native performance recipe; never opens the installed app or its library.

Cold means a new process, not a purged OS cache. All libraries and private ULogs
are independent copies under --work. The generated Swift runner uses the actual
stores/views/services and an offscreen NSWindow; it does not drive another app.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time

SWIFT = r'''
import AppKit
import Darwin
import Foundation
import SwiftUI
import WebKit
@testable import KataLog
@testable import KataLogCore

@MainActor final class BrowserDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failure = error.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failure = error.localizedDescription }
}

@main struct NativeBenchmark {
    @MainActor static func main() async {
        do {
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
            let begin = now()
            _ = NSApplication.shared
            emit(["phase": "native-ready", "pid": getpid()])
            var result: [String: Any]
            switch config["mode"] as! String {
            case "navigation": result = try await navigation(config, begin: begin)
            case "curves": result = try await curves(config)
            case "browser": result = try await browser(config)
            default: throw AnalysisError.engine("Unknown native recipe")
            }
            var usage = rusage()
            if getrusage(RUSAGE_SELF, &usage) == 0 { result["kernelPeakNativeRSSBytes"] = UInt64(usage.ru_maxrss) }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: url(config, "result"), options: .atomic)
            emit(["phase": "complete", "rssBytes": rss()])
            exit(0)
        } catch {
            emit(["phase": "failed", "error": error.localizedDescription,
                "details": String(describing: (error as NSError).userInfo)]); exit(1)
        }
    }
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func url(_ c: [String: Any], _ key: String) -> URL { URL(fileURLWithPath: c[key] as! String) }
    static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
    static func rss() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    @MainActor static func settled(_ library: LibraryStore) async throws {
        try await Task.sleep(for: .milliseconds(10))
        let deadline = now() + 30
        while library.isLoading || library.isQuerying || library.isLoadingFlight {
            guard now() < deadline else { throw AnalysisError.engine("Native store timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let error = library.queryError { throw AnalysisError.engine(error) }
        guard library.historyPage != nil else { throw AnalysisError.engine("No history page") }
    }
    @MainActor static func rendered<V: View>(_ view: V) async throws -> (Double, Int) {
        let begin = now()
        let host = NSHostingController(rootView: view.environment(\.colorScheme, .dark))
        host.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: host.view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(20)) // declared scheduling settle, included in render timing
        host.view.layoutSubtreeIfNeeded()
        guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { throw AnalysisError.engine("No offscreen bitmap") }
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 5000 else { throw AnalysisError.engine("Blank offscreen render") }
        return (now() - begin, png.count)
    }
    @MainActor static func navigation(_ c: [String: Any], begin: Double) async throws -> [String: Any] {
        emit(["phase": "navigation-start"])
        let storeStart = now()
        let library = LibraryStore(storageDirectory: url(c, "library"), engine: url(c, "engine"), pagedNavigation: true)
        defer { library.prepareForTermination() }
        try await settled(library)
        let firstPage = now() - storeStart
        guard library.historyPage?.totals.logs == (c["expectedLogs"] as! Int),
              library.historyPage?.totals.messages == (c["expectedMessages"] as! Int), library.snapshot.logs.count <= 200 else {
            throw AnalysisError.engine("Native first-page count oracle failed")
        }
        var state = GCSCollectionState(downloadDirectory: url(c, "library").appendingPathComponent("Collected").path)
        state.host = ""; state.reconnect = false; state.autoImport = false
        try JSONEncoder().encode(state).write(to: url(c, "library").appendingPathComponent("gcs-settings.json"), options: .atomic)
        let gcs = GCSStore(storageDirectory: url(c, "library"), collector: url(c, "noNetwork"), snapshot: { library.snapshot })
        let firstRender = try await rendered(Workspace06View(library: library, gcs: gcs))
        let launchToFirstRender = now() - begin
        emit(["phase": "navigation-first-render", "rssBytes": rss(), "storeSeconds": firstPage])
        var samples = [[String: Any]]()
        for i in 0..<((c["repeats"] as! Int) * 2) {
            var scope = SelectionScope(); scope.droneKeys = ["ulog:fixture-controller-1"]
            if i % 2 == 1 { scope = SelectionScope() }
            let start = now()
            try library.views.chooseScope(scope)
            try await settled(library)
            let querySeconds = now() - start
            if i % 2 == 1 && library.historyPage?.totals.logs != (c["expectedLogs"] as! Int) {
                throw AnalysisError.engine("Warm scope oracle failed")
            }
            let render = try await rendered(Workspace06View(library: library, gcs: gcs))
            samples.append(["kind": i % 2 == 0 ? "drone" : "all", "storeSeconds": querySeconds,
                "renderSeconds": render.0, "pngBytes": render.1, "rssBytes": rss(),
                "visibleLogs": library.snapshot.logs.count, "totalLogs": library.historyPage!.totals.logs])
        }
        return ["mode": "navigation", "firstPageSeconds": firstPage,
            "nativeEntryToFirstRenderSeconds": launchToFirstRender, "firstRenderSeconds": firstRender.0,
            "samples": samples, "rssBytesAfterNavigation": rss(), "countOracle": true,
            "pageBound": 200, "offscreen": true, "warmRepetitionsPerCase": c["repeats"] as! Int,
            "renderSettleMsIncluded": 20]
    }
    @MainActor static func curves(_ c: [String: Any]) async throws -> [String: Any] {
        let library = LibraryStore(storageDirectory: url(c, "library"), engine: url(c, "engine"), pagedNavigation: true)
        defer { library.prepareForTermination() }
        try await settled(library)
        let id = c["logID"] as! String
        let log = try await AnalysisService.detail(logID: id, database: library.databaseURL, engine: url(c, "engine"), readOnly: true)
        let request = TelemetryRequest(recipe: "battery")
        let study = FlightStudyStore(library: library)
        let begin = now(); study.load(logID: id, request: request)
        while study.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        if let error = study.errorMessage { throw AnalysisError.engine(error) }
        guard let response = study.response, response.displayedPointCount <= 2048 else { throw AnalysisError.engine("Curve bound failed") }
        let coldRead = now() - begin
        let render = try await rendered(FlightAnalysisView(log: log, study: study))
        // FlightAnalysisView's task restores the same recipe; wait for it explicitly.
        while study.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        var warm = [Double]()
        for _ in 0..<(c["repeats"] as! Int) {
            let start = now(); study.load(logID: id, request: request)
            while study.isLoading { try await Task.sleep(for: .milliseconds(1)) }
            warm.append(now() - start)
        }
        var uncached = [Double]()
        for i in 0..<min(10, c["repeats"] as! Int) {
            var window = request; window.timeFrom = Double(i) / 10
            let t = now()
            let value = try await TelemetryService.extract(logID: id, request: window, database: library.databaseURL, engine: url(c, "engine"))
            guard value.displayedPointCount <= 2048 else { throw AnalysisError.engine("Window curve bound failed") }
            uncached.append(now() - t)
        }
        var helperEnded = false
        let cancellable = FlightStudyStore(extractor: { _, query in
            defer { helperEnded = true }
            return try await TelemetryService.extract(logID: id, request: query, database: library.databaseURL, engine: url(c, "engine"))
        })
        let trigger = url(c, "cancelTrigger"); try? FileManager.default.removeItem(at: trigger)
        emit(["phase": "cancellation-start", "trigger": trigger.path])
        cancellable.load(logID: id, request: request)
        let deadline = now() + 15
        while !FileManager.default.fileExists(atPath: trigger.path) && !helperEnded && now() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard !helperEnded, FileManager.default.fileExists(atPath: trigger.path) else { throw AnalysisError.engine("Cancellation did not observe an in-flight series helper") }
        let cancelStart = now(); cancellable.cancel()
        let feedback = now() - cancelStart
        guard !cancellable.isLoading else { throw AnalysisError.engine("Cancellation left UI loading") }
        while !helperEnded && now() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        guard helperEnded else { throw AnalysisError.engine("Cancelled helper did not return") }
        let completion = now() - cancelStart
        emit(["phase": "cancellation-complete", "uiSeconds": feedback, "helperReturnSeconds": completion])
        return ["mode": "curves", "coldStoreReadSeconds": coldRead, "warmStoreCacheSeconds": warm,
            "sameProcessUncachedWindowReadSeconds": uncached,
            "renderSeconds": render.0, "pngBytes": render.1, "seriesCount": response.series.count,
            "displayedPoints": response.displayedPointCount,
            "originalSamples": response.series.map(\.originalSampleCount), "missingFields": response.missingFields,
            "uiCancelSeconds": feedback, "helperReturnAfterCancelSeconds": completion,
            "cancelledResponseNotPublished": cancellable.response == nil, "rssBytes": rss(), "offscreen": true]
    }
    @MainActor static func browser(_ c: [String: Any]) async throws -> [String: Any] {
        let snapshot = try AnalysisService.decode(Data(contentsOf: url(c, "snapshot")))
        let renderStart = now()
        let html = ReportRenderer.html(snapshot)
        try html.write(to: url(c, "html"), atomically: true, encoding: .utf8)
        let renderTime = now() - renderStart
        guard html.utf8.count <= 10 * 1024 * 1024 else { throw AnalysisError.engine("HTML budget failed") }
        let javaScript = c["javaScript"] as? Bool ?? true
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        let delegate = BrowserDelegate(); view.navigationDelegate = delegate
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.stopLoading(); window.close() }
        emit(["phase": "webkit-load-start", "rssBytes": rss()])
        let start = now(); view.loadFileURL(url(c, "html"), allowingReadAccessTo: url(c, "html").deletingLastPathComponent())
        let deadline = now() + 30
        while !delegate.finished && delegate.failure == nil && now() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        if let error = delegate.failure { throw AnalysisError.engine(error) }
        guard delegate.finished else { throw AnalysisError.engine("WKWebView navigation timed out") }
        let load = now() - start
        let initial = try await view.evaluateJavaScript("JSON.stringify({logs:document.getElementById('stat-logs').textContent,ready:!document.getElementById('filter-controls').hidden})") as! String
        let dom = try await view.evaluateJavaScript("JSON.stringify({elements:document.getElementsByTagName('*').length,svgs:document.querySelectorAll('svg').length,messageRows:document.querySelectorAll('.message-row').length,occurrenceRows:document.querySelectorAll('.group-occurrence').length,logCards:document.querySelectorAll('.log-card').length,groups:document.querySelectorAll('.alert-group').length,inlineDataCharacters:document.getElementById('report-data')?.textContent.length ?? 0,scripts:document.scripts.length})") as! String
        emit(["phase": "webkit-initial-ready", "dom": dom])
        try await Task.sleep(for: .milliseconds(350)) // independent initial-RSS sampling window
        var interactions = [Double](); var visibleGroups = [Int]()
        for i in 0..<(javaScript ? c["repeats"] as! Int : 0) {
            let t = now()
            let js = "(()=>{const x=document.getElementById('family-filter');x.value=\(i % 2 == 0 ? "'Family-2'" : "''");x.dispatchEvent(new Event('change'));return [...document.querySelectorAll('.alert-group')].filter(x=>!x.hidden).length;})()"
            let count = try await view.evaluateJavaScript(js) as! Int
            guard count == (i % 2 == 0 ? 5 : 50) else { throw AnalysisError.engine("Browser filter count oracle failed") }
            visibleGroups.append(count)
            interactions.append(now() - t)
            emit(["phase": "webkit-filter-\(i)"])
        }
        emit(["phase": "webkit-filters-complete"])
        try await Task.sleep(for: .milliseconds(500)) // RSS sampling window, excluded from load timing
        return ["mode": "browser", "htmlBytes": html.utf8.count, "htmlGenerationSeconds": renderTime,
            "wkLoadAndInitialJSSeconds": load, "interactiveState": initial,
            "dom": dom, "javaScriptEnabled": javaScript,
            "filterRoundtripSeconds": interactions, "visibleGroups": visibleGroups, "filterCountOracle": true,
            "rssBytes": rss(), "offscreen": true,
            "logCount": snapshot.logs.count, "messageCount": snapshot.logs.reduce(0) { $0 + $1.messages.count }]
    }
}
'''

def sha(path: Path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()

def fingerprint(path):
    st = path.stat()
    return {'sha256': sha(path), 'sizeBytes': st.st_size, 'mtimeNs': st.st_mtime_ns}

def stage(args):
    package = args.package or args.work / 'package'
    package.mkdir(parents=True, exist_ok=True)
    proof = {}
    for target in ('KataLogCore', 'KataLog'):
        source = args.source / 'Sources' / target
        for item in source.rglob('*'):
            if not item.is_file() or item.name in ('main.swift', 'ApplicationLifecycle.swift'): continue
            destination = package / 'Sources' / target / item.relative_to(source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(item, destination)
            proof[str(item.relative_to(args.source))] = sha(destination)
    runner = package / 'Sources/NativeBenchmark/main.swift'
    runner.parent.mkdir(parents=True, exist_ok=True); runner.write_text(SWIFT)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "KataLogNative06Benchmark", platforms: [.macOS(.v15)],
 dependencies: [.package(path: %s)], targets: [
 .target(name:"KataLogCore", swiftSettings:[.unsafeFlags(["-enable-testing"])]),
 .target(name:"KataLog", dependencies:["KataLogCore", .product(name:"Sparkle", package:"Sparkle")], resources:[.copy("Resources")], swiftSettings:[.unsafeFlags(["-enable-testing"])]),
 .executableTarget(name:"NativeBenchmark", dependencies:["KataLog", "KataLogCore"], swiftSettings:[.unsafeFlags(["-parse-as-library"])])])
''' % json.dumps(str(args.sparkle_checkout)))
    (args.work / 'source-proof.json').write_text(json.dumps(proof, indent=2))
    return package, proof

def processes():
    lines = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,command='], text=True).splitlines()
    result = {}
    for line in lines:
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            result[int(fields[0])] = {'ppid': int(fields[1]), 'rssBytes': int(fields[2]) * 1024, 'command': fields[3]}
    return result

def run_native(binary, config, environment, log):
    config_path = Path(config['result']).with_suffix('.config.json')
    config_path.write_text(json.dumps(config))
    baseline = processes(); begin = time.monotonic()
    peak = {}; phase_peaks = {}; native_peak = 0; helper_peak = 0; cancel_observed = False; first_render_wall = None
    with log.open('w') as out:
        proc = subprocess.Popen([str(binary), str(config_path)], env=environment, stdout=out, stderr=subprocess.STDOUT)
        while proc.poll() is None:
            current = processes()
            log_text = log.read_text()
            events = []
            for line in log_text.splitlines():
                if line.startswith('{'):
                    try: events.append(json.loads(line))
                    except json.JSONDecodeError: pass
            phase = next((item['phase'] for item in reversed(events) if 'phase' in item), 'process-start')
            if first_render_wall is None and '"phase":"navigation-first-render"' in log_text:
                first_render_wall = time.monotonic() - begin
            row = current.get(proc.pid)
            if row: native_peak = max(native_peak, row['rssBytes'])
            descendants = {proc.pid}
            for _ in range(8):
                descendants |= {pid for pid, info in current.items() if info['ppid'] in descendants}
            for pid, info in current.items():
                webkit = ('com.apple.WebKit.' in info['command'] or 'WebKit.WebContent' in info['command']) and pid not in baseline
                role = 'webkit-webcontent' if '.WebContent' in info['command'] else 'webkit-networking' if '.Networking' in info['command'] else 'webkit-gpu' if '.GPU' in info['command'] else 'webkit-other'
                if pid in descendants or webkit:
                    old = peak.get(pid, {})
                    peak[pid] = {'pid': pid, 'ppid': info['ppid'], 'rssBytes': max(old.get('rssBytes', 0), info['rssBytes']),
                                 'role': role if webkit else 'native' if pid == proc.pid else 'helper'}
                    key = (phase, pid)
                    phase_peaks[key] = max(phase_peaks.get(key, 0), info['rssBytes'])
                if pid in descendants and pid != proc.pid:
                    helper_peak = max(helper_peak, info['rssBytes'])
                    if config['mode'] == 'curves' and ' series ' in info['command'] and not cancel_observed:
                        # Only signal after the runner explicitly enters its cancellation phase.
                        if log.exists() and '"phase":"cancellation-start"' in log.read_text():
                            Path(config['cancelTrigger']).write_text('observed series helper')
                            cancel_observed = True
            time.sleep(.04)
        code = proc.returncode
    end = time.monotonic()
    # Newly spawned WebKit children that disappear with this isolated runner
    # provide attribution evidence; existing browser processes are excluded.
    after = processes()
    if any(p['role'].startswith('webkit-') for p in peak.values()):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(pid in after for pid, p in peak.items() if p['role'].startswith('webkit-')):
            time.sleep(.1); after = processes()
    for pid, item in peak.items():
        item['absentAfterNativeExit'] = pid not in after
    if code: raise RuntimeError(f'Native {config["mode"]} exited {code}; see {log}')
    result = json.loads(Path(config['result']).read_text())
    result.update(processWallSeconds=end-begin, sampledNativePeakRSSBytes=native_peak,
        sampledLargestHelperRSSBytes=helper_peak, processSamples=list(peak.values()), rssPollIntervalMs=40,
        phasePeakRSS=[dict(phase=phase, pid=pid, role=peak[pid]['role'], rssBytes=value) for (phase,pid),value in phase_peaks.items()],
        cancellationHelperObserved=cancel_observed, sampledSpawnToFirstRenderSeconds=first_render_wall)
    return result

def prepare_fixtures(args):
    sys.path.insert(0, str(args.source / 'Sources/KataLog/Resources'))
    sys.path.insert(0, str(args.source / 'Tests'))
    import analyzer
    from fixture_ulog import record, info, MAGIC
    import struct
    prepared = {}
    synthetic = args.work / 'synthetic'; synthetic.mkdir(exist_ok=True)
    sources = synthetic / 'sources'; sources.mkdir(exist_ok=True)
    data = [MAGIC + bytes([1]) + struct.pack('<Q', 1_000_000),
        record('F', b'battery_status:uint64_t timestamp;float voltage_v;float current_a;float remaining;float discharged_mah;'),
        info('drone_name', 'Native benchmark invented controller'),
        record('A', struct.pack('<BH', 0, 1) + b'battery_status')]
    for index in range(300_000):
        stamp = 1_000_000 + index * 10_000 + (index // 30_000) * 2_000_000
        values = (float('nan') if index in (100, 101) else 16-index/300_000,
                  float((index // 1000) % 5), 1-index/300_000, index/1000)
        data.append(record('D', struct.pack('<HQffff', 1, stamp, *values)))
    (sources / 'invented.ulg').write_bytes(b''.join(data)); del data
    analyzer.scan(sources, synthetic / 'library.sqlite', synthetic / 'library.json', synthetic / 'progress.json')
    db = sqlite3.connect(synthetic / 'library.sqlite'); prepared['syntheticLogID'] = db.execute('SELECT id FROM logs').fetchone()[0]; db.close()
    # An invented 10k-message report exercises actual report DOM/JS, not padding.
    records = []
    for i in range(200):
        identity = hashlib.sha256(('browser-'+str(i)).encode()).hexdigest()
        value = analyzer.base_log(Path('invented-%03d.ulg' % i), Path('.'), identity, 1)
        value.update(droneID='browser-fixture-%d' % (i % 20), droneName='Invented %d' % (i % 20), status='ok', durationSeconds=60, date='2026-01-%02dT12:00:00Z' % (i%28+1))
        value['messages'] = [dict(id=f'{identity}-{j}', text='Invented alert %02d' % j, family='Family-%d' % (j % 10),
            level='WARNING', isAlert=True, timestampSeconds=j, groupKey='fixture-%d' % j, title='Invented alert') for j in range(50)]
        records.append(value)
    snapshot = dict(schemaVersion=1, generatedAt='2026-01-01T00:00:00Z', sourceFolders=[], importStats=dict(discovered=200, imported=200, unchanged=0, duplicates=0, failed=0), logs=records)
    (args.work / 'browser-snapshot.json').write_text(json.dumps(snapshot))
    private_proof = []
    if args.private_corpus:
        private = args.work / 'private'; private.mkdir(exist_ok=True)
        target = private / 'sources'; target.mkdir(exist_ok=True)
        for i, source in enumerate(sorted(args.private_corpus.rglob('*.ulg'))):
            before = fingerprint(source); destination = target / ('private-%02d.ulg' % i)
            shutil.copyfile(source, destination)
            private_proof.append(dict(ordinal=i, **before, copiedBytesMatch=sha(destination)==before['sha256'], before=before, _source=source))
        begin = time.monotonic(); first = analyzer.scan(target, private/'library.sqlite', private/'library.json', private/'progress.json')
        prepared['privateImportSeconds'] = time.monotonic()-begin
        begin = time.monotonic(); second = analyzer.scan(target, private/'library.sqlite', private/'library.json', private/'progress.json')
        prepared['privateReimportSeconds'] = time.monotonic()-begin
        prepared['privateImportStats'] = first['importStats']; prepared['privateReimportStats'] = second['importStats']
        prepared['privateLogID'] = max(first['logs'], key=lambda x:x['sizeBytes'])['id']
    return prepared, private_proof

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True, help='New owned scratch folder; data are kept for inspection.')
    parser.add_argument('--grand-library', type=Path, required=True)
    parser.add_argument('--private-corpus', type=Path)
    parser.add_argument('--sparkle-checkout', type=Path, required=True)
    parser.add_argument('--package', type=Path, help='Optional existing owned test package, never the working repository.')
    parser.add_argument('--build', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--helper-app', type=Path, help='Independent candidate KataLogEngine.app, copied into the bench bundle.')
    parser.add_argument('--repeats', type=int, default=20)
    parser.add_argument('--mode', choices=('all','navigation','curves','browser'), default='all')
    parser.add_argument('--disable-page-javascript', action='store_true', help='Browser profile control; API DOM inspection remains enabled.')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--run-only', action='store_true')
    args = parser.parse_args()
    args.source = args.source.resolve(); args.work = args.work.resolve()
    for scratch in (args.work,args.package,args.build):
        if scratch is not None and scratch.resolve().is_relative_to(args.source):
            parser.error('Scratch must be outside the repository; private copies must never enter its tree')
    if not 1 <= args.repeats <= 30: parser.error('Use 1..30 repetitions')
    if not args.run_only and (args.work/'prepared.json').exists():
        parser.error('Prepared scratch exists; use --run-only or a new --work')
    args.work.mkdir(parents=True, exist_ok=True)
    package = args.package or args.work/'package'; build = args.build or args.work/'build'
    if not args.run_only:
        package, proof = stage(args)
        command = ['swift','build','--package-path',str(package),'--scratch-path',str(build),'--build-system','native','--product','NativeBenchmark']
        with (args.work/'build.log').open('w') as output:
            subprocess.run(command, check=True, stdout=output, stderr=subprocess.STDOUT)
        fixtures, private_proof = prepare_fixtures(args)
        private_state = [{**p, '_source': str(p['_source'])} for p in private_proof]
        (args.work/'prepared.json').write_text(json.dumps(dict(fixtures=fixtures, private=private_state)))
        # APFS clone is a distinct file/inode with copy-on-write semantics.
        grand = args.work/'grand'; grand.mkdir(exist_ok=True)
        source_db = args.grand_library/'library.sqlite'
        if source_db.with_name('library.sqlite-wal').exists() and source_db.with_name('library.sqlite-wal').stat().st_size:
            raise RuntimeError('Grand fixture has nonempty WAL; use a consistent SQLite backup instead.')
        subprocess.run(['cp','-c',str(source_db),str(grand/'library.sqlite')],check=True)
        if source_db.stat().st_ino == (grand/'library.sqlite').stat().st_ino: raise RuntimeError('Clone shares inode')
        (args.work/'grand-clone.json').write_text(json.dumps(dict(sourceBytes=source_db.stat().st_size, distinctInode=True, apfsClone=True)))
    else:
        proof = json.loads((args.work/'source-proof.json').read_text())
        prepared = json.loads((args.work/'prepared.json').read_text()); fixtures = prepared['fixtures']; private_proof=prepared['private']
    if args.prepare_only: print(json.dumps({'phase':'prepared','work':str(args.work)})); return 0
    if not args.run_only: private_proof = private_state
    binary = build/'arm64-apple-macosx/debug/NativeBenchmark'
    runtime = 'development-python'
    bundle = args.work/('NativeBenchmarkBundled.app' if args.helper_app else 'NativeBenchmarkDevelopment.app')
    macos=bundle/'Contents/MacOS'; macos.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(binary,macos/'katalog-cli'); (macos/'katalog-cli').chmod(0o755)
    import plistlib
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='invalid.katalog.nativebenchmark.'+('bundled' if args.helper_app else 'development'),
        CFBundleExecutable='katalog-cli', CFBundleName='KataLog Native Benchmark', CFBundlePackageType='APPL',
        CFBundleVersion='1', CFBundleShortVersionString='1.0', LSUIElement=True, NSHighResolutionCapable=True,
        KatalogBundledEngineRequired=args.helper_app is not None)))
    binary=macos/'katalog-cli'
    if args.helper_app:
        helpers=bundle/'Contents/Helpers'; helpers.mkdir(exist_ok=True)
        shutil.copytree(args.helper_app,helpers/'KataLogEngine.app',copy_function=shutil.copyfile,dirs_exist_ok=True)
        (helpers/'KataLogEngine.app/Contents/MacOS/KataLogEngine').chmod(0o755)
        runtime='candidate-bundled-helper'
    env=os.environ.copy(); env['KATALOG_PYTHON']=str(args.python); env['KATALOG_UI_PREVIEW']='1'
    env['DYLD_FRAMEWORK_PATH']=str(build/'arm64-apple-macosx/debug')
    no_network=args.work/'no-network.py'; no_network.write_text("raise RuntimeError('Benchmark must never invoke GCS')\n")
    engine=package/'Sources/KataLog/Resources/analyzer.py'
    runs=[]
    for i in range(3 if args.mode in ('all','navigation') else 0):
        config=dict(mode='navigation', library=str(args.work/'grand'), engine=str(engine), expectedLogs=50_000,
            expectedMessages=5_000_000, repeats=args.repeats if i==0 else 0, noNetwork=str(no_network), result=str(args.work/f'navigation-{i}.json'))
        runs.append(run_native(binary,config,env,args.work/f'navigation-{i}.log'))
    for kind in ('synthetic','private'):
        if args.mode not in ('all','curves'): continue
        if kind+'LogID' not in fixtures: continue
        config=dict(mode='curves',library=str(args.work/kind),engine=str(engine),logID=fixtures[kind+'LogID'],repeats=args.repeats,
            cancelTrigger=str(args.work/f'cancel-{kind}'),result=str(args.work/f'curves-{kind}.json'))
        result=run_native(binary,config,env,args.work/f'curves-{kind}.log'); result['fixtureKind']=kind; runs.append(result)
    if args.mode in ('all','browser'):
        config=dict(mode='browser',snapshot=str(args.work/'browser-snapshot.json'),html=str(args.work/'report.html'),repeats=args.repeats,
            javaScript=not args.disable_page_javascript,result=str(args.work/'browser.json'))
        runs.append(run_native(binary,config,env,args.work/'browser.log'))
    private_preserved=[]
    for p in private_proof:
        after=fingerprint(Path(p['_source']))
        private_preserved.append({k:p[k] for k in ('ordinal','sha256','sizeBytes','mtimeNs','copiedBytesMatch')} | {'sourceSHABytesMtimePreserved':after==p['before']})
    result=dict(benchmarkVersion=1, cacheProtocol='Three new native processes; same-process warm stores. OS page cache is not cleared or controlled.',
        processKind='Isolated debug executable using actual App stores/SwiftUI views; offscreen NSWindow, not installed app launch.',
        runtime=runtime, runtimeHelperExecutableSHA256=sha(bundle/'Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine') if args.helper_app else None,
        hardware=subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip(), osVersion=subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),
        compiledSourceSHA256=proof, benchmarkToolSHA256=sha(Path(__file__)),
        runnerSourceSHA256=sha(package/'Sources/NativeBenchmark/main.swift'),
        fixtures=fixtures, privateCorpus=private_preserved, runs=runs,
        libraryClone=json.loads((args.work/'grand-clone.json').read_text()),
        limits=['No OS cold-cache claim','RSS sampled every40ms can miss short peaks','Existing/shared WebKit processes excluded','No physical GCS/drone/network qualification','Internal APFS only; external-volume speed unmeasured'])
    args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(result,indent=2))
    print(json.dumps({'output':str(args.output),'runs':len(runs),'privateSourcesPreserved':all(p['sourceSHABytesMtimePreserved'] for p in private_preserved)}))
    return 0

if __name__ == '__main__': sys.exit(main())
