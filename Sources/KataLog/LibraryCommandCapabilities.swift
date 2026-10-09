import Foundation

/// Intentional differences between commands are centralized here. These values
/// describe admission, not ownership: an admitted task keeps its existing drain,
/// cancellation, writer lease and revalidation sequence.
struct LibraryCommandCapabilities: Equatable {
    var readOnly = false
    var importing = false
    var querying = false
    var loading = false
    var loadingFlight = false
    var detailOpen = false
    var maintaining = false
    var exporting = false
    var externalActivity = false

    // The interactive importer may be admitted during a read, then wait for it.
    var canChooseImportFolder: Bool { !readOnly && !maintaining && !importing }
    var canAdmitCollectedImport: Bool { !readOnly && !maintaining }
    var mustWaitForCollectedImport: Bool { importing || querying || loading || detailOpen }
    var canRefreshAnalysis: Bool { !readOnly && !maintaining && !mustWaitForCollectedImport }

    // A legacy report renders an immutable snapshot and only excludes another
    // export. A paged report additionally acquires maintenance for its capture.
    var canBeginReport: Bool { !exporting }
    var canWriteDiagnosticSettings: Bool { !readOnly && !importing && !exporting && !maintaining && !externalActivity }
    var hasActiveWork: Bool { importing || exporting || maintaining || querying || loading || loadingFlight || detailOpen }

    func canMaintain(allowOwnedExport: Bool = false, allowOwnedQuery: Bool = false) -> Bool {
        !readOnly && !maintaining && !importing && (!exporting || allowOwnedExport)
            && !loading && (!querying || allowOwnedQuery) && !loadingFlight
            && !detailOpen && !externalActivity
    }
}

/// Workspace controls have stricter admission than the importer facade. Keep
/// update installation's historic exception for snapshot loading explicit.
struct WorkspaceCommandCapabilities: Equatable {
    var library: LibraryCommandCapabilities
    var collecting = false
    var diagnosticExporting = false
    var diagnosticFetching = false
    // A workspace may own a separate navigation session. Mutation and update
    // admission still use the library's aggregate readers.
    var navigationQuerying: Bool?
    var navigationLoadingFlight: Bool?

    var canNavigate: Bool {
        !library.importing && !library.maintaining && !(navigationQuerying ?? library.querying)
            && !library.loading && !(navigationLoadingFlight ?? library.loadingFlight)
    }
    var canMutate: Bool {
        canNavigate && !library.querying && !library.loadingFlight && !collecting && !library.detailOpen && !diagnosticExporting && !diagnosticFetching
    }
    var canImport: Bool { canMutate && !library.readOnly }
    var canEditAnnotations: Bool { canImport }
    var canRefreshAnalysis: Bool { canImport }
    var canRestoreLibrary: Bool { canImport }
    var canResetLibrary: Bool { canImport && !library.exporting }
    var canPrepareReport: Bool { canImport && !library.exporting }
    var canInstallUpdate: Bool {
        !library.readOnly && !library.importing && !library.exporting && !library.maintaining
            && !collecting && !library.querying && !library.loadingFlight && !library.detailOpen
            && !diagnosticExporting && !diagnosticFetching
    }
}

extension LibraryStore {
    var commandCapabilities: LibraryCommandCapabilities {
        LibraryCommandCapabilities(readOnly: isReadOnly, importing: isImporting,
            querying: isQuerying, loading: isLoading, loadingFlight: isLoadingFlight,
            detailOpen: activeDetailLoads > 0, maintaining: isMaintainingLibrary,
            exporting: isExporting, externalActivity: hasExternalActivity())
    }
}
