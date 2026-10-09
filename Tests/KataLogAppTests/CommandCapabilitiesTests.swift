import XCTest
@testable import KataLog

final class CommandCapabilitiesTests: XCTestCase {
    private enum Activity: Int, CaseIterable, Hashable {
        case readOnly, importing, query, cancellingQuery, snapshot, flight, detail,
             maintenance, report, external, collection, diagnosticExport, diagnosticFetch
    }

    /// This table records the pre-refactor command contract independently of the
    /// production formulas. Every combination also covers overlapping activity.
    func testEveryCommandPreservesItsActivityMatrix() {
        typealias A = Activity
        let libraryRules: [(String, Set<A>, (LibraryCommandCapabilities) -> Bool)] = [
            ("choose import", [.readOnly, .maintenance, .importing], { $0.canChooseImportFolder }),
            ("admit collection import", [.readOnly, .maintenance], { $0.canAdmitCollectedImport }),
            ("refresh analysis", [.readOnly, .maintenance, .importing, .query, .cancellingQuery, .snapshot, .detail], { $0.canRefreshAnalysis }),
            ("legacy report", [.report], { $0.canBeginReport }),
            ("diagnostic settings", [.readOnly, .importing, .report, .maintenance, .external], { $0.canWriteDiagnosticSettings }),
            ("maintenance", [.readOnly, .importing, .query, .cancellingQuery, .snapshot, .flight, .detail, .maintenance, .report, .external], { $0.canMaintain() })
        ]
        let workspaceRules: [(String, Set<A>, (WorkspaceCommandCapabilities) -> Bool)] = [
            ("navigation", [.importing, .maintenance, .query, .cancellingQuery, .snapshot, .flight], { $0.canNavigate }),
            ("import", [.readOnly, .importing, .maintenance, .query, .cancellingQuery, .snapshot, .flight, .collection, .detail, .diagnosticExport, .diagnosticFetch], { $0.canImport }),
            ("annotations", [.readOnly, .importing, .maintenance, .query, .cancellingQuery, .snapshot, .flight, .collection, .detail, .diagnosticExport, .diagnosticFetch], { $0.canEditAnnotations }),
            ("report", [.readOnly, .importing, .maintenance, .query, .cancellingQuery, .snapshot, .flight, .collection, .detail, .diagnosticExport, .diagnosticFetch, .report], { $0.canPrepareReport }),
            ("reset", [.readOnly, .importing, .maintenance, .query, .cancellingQuery, .snapshot, .flight, .collection, .detail, .diagnosticExport, .diagnosticFetch, .report], { $0.canResetLibrary }),
            ("restore", [.readOnly, .importing, .maintenance, .query, .cancellingQuery, .snapshot, .flight, .collection, .detail, .diagnosticExport, .diagnosticFetch], { $0.canRestoreLibrary }),
            ("refresh analyses", [.readOnly, .importing, .maintenance, .query, .cancellingQuery, .snapshot, .flight, .collection, .detail, .diagnosticExport, .diagnosticFetch], { $0.canRefreshAnalysis }),
            ("update", [.readOnly, .importing, .maintenance, .query, .cancellingQuery, .flight, .collection, .detail, .diagnosticExport, .diagnosticFetch, .report], { $0.canInstallUpdate })
        ]
        for mask in 0..<(1 << A.allCases.count) {
            let active = Set(A.allCases.filter { mask & (1 << $0.rawValue) != 0 })
            let library = LibraryCommandCapabilities(readOnly: active.contains(.readOnly), importing: active.contains(.importing),
                querying: !active.isDisjoint(with: [.query, .cancellingQuery]), loading: active.contains(.snapshot),
                loadingFlight: active.contains(.flight), detailOpen: active.contains(.detail), maintaining: active.contains(.maintenance),
                exporting: active.contains(.report), externalActivity: active.contains(.external))
            let workspace = WorkspaceCommandCapabilities(library: library, collecting: active.contains(.collection),
                diagnosticExporting: active.contains(.diagnosticExport), diagnosticFetching: active.contains(.diagnosticFetch))
            for (name, blocked, allowed) in libraryRules {
                XCTAssertEqual(allowed(library), active.isDisjoint(with: blocked), "\(name): \(active)")
            }
            for (name, blocked, allowed) in workspaceRules {
                XCTAssertEqual(allowed(workspace), active.isDisjoint(with: blocked), "\(name): \(active)")
            }
        }
    }

    func testOwnedCaptureOnlyExemptsItsOwnExportOrQuery() {
        var state = LibraryCommandCapabilities(querying: true, exporting: true)
        XCTAssertFalse(state.canMaintain())
        XCTAssertFalse(state.canMaintain(allowOwnedExport: true))
        XCTAssertFalse(state.canMaintain(allowOwnedQuery: true))
        XCTAssertTrue(state.canMaintain(allowOwnedExport: true, allowOwnedQuery: true))
        state.externalActivity = true
        XCTAssertFalse(state.canMaintain(allowOwnedExport: true, allowOwnedQuery: true))
        state.externalActivity = false; state.detailOpen = true
        XCTAssertFalse(state.canMaintain(allowOwnedExport: true, allowOwnedQuery: true))
    }

    func testIndependentNavigationDoesNotPermitMutationOverAnotherReader() {
        let workspace = WorkspaceCommandCapabilities(library: .init(querying: true),
            navigationQuerying: false, navigationLoadingFlight: false)
        XCTAssertTrue(workspace.canNavigate)
        XCTAssertFalse(workspace.canImport)
        XCTAssertFalse(workspace.canPrepareReport)
        XCTAssertFalse(workspace.canInstallUpdate)
    }

    func testWaitingImportAndUpdateKeepTheirIntentionalDifferences() {
        let state = LibraryCommandCapabilities(querying: true)
        XCTAssertTrue(state.canChooseImportFolder)
        XCTAssertTrue(state.canAdmitCollectedImport)
        XCTAssertTrue(state.mustWaitForCollectedImport)
        XCTAssertFalse(WorkspaceCommandCapabilities(library: state).canImport)
        let loading = WorkspaceCommandCapabilities(library: .init(loading: true))
        XCTAssertFalse(loading.canNavigate)
        XCTAssertTrue(loading.canInstallUpdate)
        let report = WorkspaceCommandCapabilities(library: .init(exporting: true))
        XCTAssertTrue(report.canImport)
        XCTAssertFalse(report.canPrepareReport)
        XCTAssertFalse(report.canInstallUpdate)
    }
}
