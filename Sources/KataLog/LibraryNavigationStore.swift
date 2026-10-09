import Combine
import Foundation
import KataLogCore

/// Per-window query presentation and cancellation. The library remains the sole writer.
@MainActor
final class LibraryNavigationStore: ObservableObject {
    private unowned let library: LibraryStore
    private let isDefault: Bool
    private var catalogueReaders = 0
    private var catalogueToken = UUID()
    private var hasLoaded = false
    private var reloadAfterCancellation = false
    private var librarySubscription: AnyCancellable?
    private var storageDirectory: URL { library.storageDirectory }
    private var databaseURL: URL { library.databaseURL }
    private var engineURL: URL? { library.engineURL }
    private var views: LibraryViewStore { library.views }
    private var annotations: DroneAnnotationStore { library.annotations }
    private var isReadOnly: Bool { library.isReadOnly }
    private var isImporting: Bool { library.isImporting }
    private var isMaintainingLibrary: Bool { library.isMaintainingLibrary }
    private var usesPagedNavigation: Bool { library.usesPagedNavigation }
    private var activeDetailLoads: Int { library.activeDetailLoads }
    private func hasExternalActivity() -> Bool { library.hasExternalActivity() }
    var hasActiveQuery: Bool { isQuerying || catalogueReaders > 0 }
    var hasActiveWork: Bool { hasActiveQuery || isLoadingFlight }

    init(library: LibraryStore, isDefault: Bool = false) {
        self.library = library; self.isDefault = isDefault
        library.registerNavigation(self)
        librarySubscription = objectWillChange.sink { [weak library] _ in library?.objectWillChange.send() }
    }

    /// Data and shared filters changed; reset only this session's stale results.
    func reload() {
        navigationCache.invalidate()
        catalogueToken = UUID(); catalogue = nil; mapPage = nil; dronePage = nil
        if hasLoaded {
            historyResultsCurrent = false; groupResultsCurrent = false; occurrenceResultsCurrent = false
            if isCancellingQuery { reloadAfterCancellation = true } else { loadHistory() }
        }
    }

    func invalidateCache() { navigationCache.invalidate() }

    func reset() {
        navigationCache.invalidate(); catalogueToken = UUID()
        displayedQueryKeys.removeAll()
        historyResultsCurrent = false; groupResultsCurrent = false
        droneResultsCurrent = false; occurrenceResultsCurrent = false
        snapshot = .empty; historyPage = nil; groupPage = nil; dronePage = nil
        mapPage = nil; occurrencePage = nil; catalogue = nil; mapProximity = nil
        currentHistoryCursor = nil
    }

    func prepareForTermination() {
        close(); catalogueToken = UUID()
    }

    /// Closing a window cancels its reads, retaining activity until helpers reap.
    func close() {
        hasLoaded = false; reloadAfterCancellation = false
        flightTask?.cancel()
        Task { await cancelQuery() }
    }

    @Published private(set) var historyPage: LibraryLogPage?
    @Published private(set) var currentHistoryCursor: String?
    @Published private(set) var groupPage: LibraryGroupPage?
    @Published private(set) var dronePage: LibraryDronePage?
    @Published private(set) var mapPage: LibraryMapPage?
    @Published private(set) var occurrencePage: LibraryMessagePage?
    @Published private(set) var isQuerying = false
    @Published private(set) var isCancellingQuery = false
    @Published private(set) var queryWasCancelled = false
    @Published private(set) var queryError: String?
    @Published private(set) var catalogue: LibraryCataloguePage?
    @Published private(set) var catalogueError: String?
    private var queryTask: Task<Void, Never>?
    @Published private(set) var queryToken = UUID()
    @Published private(set) var snapshot: FleetSnapshot = .empty
    @Published private(set) var mapProximity: GeographicProximity?
    @Published private(set) var isLoadingFlight = false
    @Published private(set) var flightError: String?
    private var flightTask: Task<Void, Never>?
    private var flightToken = UUID()
    var historySortOverride: String?
    private lazy var navigationCache = LibraryNavigationCache(directory: storageDirectory)
    private var activeQueryKey: Data?
    private var displayedQueryKeys: [String: Data] = [:]
    @Published private(set) var historyResultsCurrent = false
    @Published private(set) var groupResultsCurrent = false
    @Published private(set) var droneResultsCurrent = false
    @Published private(set) var occurrenceResultsCurrent = false

    /// Keep mutations disabled until the owned helper has actually stopped.
    /// Invalidating the token also prevents a late response from publishing.
    func cancelQuery() async {
        guard isQuerying, !isCancellingQuery, let task = queryTask else { return }
        isCancellingQuery = true
        library.cancelNavigationPreparation(ifLastReader: self)
        let token = UUID(); queryToken = token
        task.cancel()
        await task.value
        guard queryToken == token else { return }
        queryTask = nil; isQuerying = false; isCancellingQuery = false
        queryWasCancelled = true; queryError = nil
        if reloadAfterCancellation { reloadAfterCancellation = false; loadHistory() }
    }
    func loadCatalogue() async {
        let library = library
        guard let engine = engineURL, FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        guard !library.isMaintainingLibrary, !library.isImporting else { return }
        catalogueReaders += 1; library.objectWillChange.send()
        defer { catalogueReaders -= 1; library.objectWillChange.send() }
        let token = catalogueToken
        catalogueError = nil
        do {
            var request = LibraryQueryRequest(kind: "catalogue", scope: views.state.activeScope, annotations: annotations.state)
            var result = try await LibraryQueryService.page(LibraryCataloguePage.self, request: request, database: databaseURL, engine: engine, readOnly: true)
            while let cursor = result.nextCursor {
                try Task.checkCancellation()
                guard result.families.count + result.levels.count < 8192 else {
                    throw AnalysisError.engine("Le catalogue dépasse 8 192 valeurs. Affinez les classifications avant de modifier le filtre.")
                }
                request.cursor = cursor
                let next = try await LibraryQueryService.page(LibraryCataloguePage.self, request: request, database: databaseURL, engine: engine, readOnly: true)
                guard next.revision == result.revision, next.scopeHash == result.scopeHash else {
                    throw AnalysisError.engine("Le catalogue a changé pendant sa lecture. Rechargez le filtre.")
                }
                result.families += next.families; result.levels += next.levels; result.nextCursor = next.nextCursor
                guard result.families.count + result.levels.count <= 8192 else {
                    throw AnalysisError.engine("Le catalogue dépasse la limite de 8 192 valeurs.")
                }
            }
            try Task.checkCancellation()
            guard catalogueToken == token else { return }
            catalogue = result
        } catch is CancellationError {} catch { if catalogueToken == token { catalogueError = error.localizedDescription } }
    }

    /// Each cached response belongs to its full request and an unchanged local
    /// database/WAL. Switching tabs restores results synchronously when possible.
    private func applyNavigationPage(_ page: LibraryNavigationCache.Page, request: LibraryQueryRequest) {
        let key = LibraryNavigationCache.key(request)
        switch page {
        case let .history(logs, groups):
            historyPage = logs; groupPage = groups; currentHistoryCursor = request.cursor
            occurrencePage = nil; occurrenceResultsCurrent = false
            snapshot = logs.snapshot
            if isDefault { library.snapshot = logs.snapshot }
            historyResultsCurrent = true; groupResultsCurrent = true
            displayedQueryKeys["logs"] = key
            var groupRequest = request; groupRequest.kind = "groups"; groupRequest.cursor = nil
            displayedQueryKeys["groups"] = LibraryNavigationCache.key(groupRequest)
        case let .map(value): mapPage = value
        case let .drones(value): dronePage = value; droneResultsCurrent = true
        case let .groups(value): groupPage = value; groupResultsCurrent = true
        case let .messages(value): occurrencePage = value; occurrenceResultsCurrent = true
        }
        displayedQueryKeys[request.kind] = key
        queryError = nil; queryWasCancelled = false
    }

    private typealias NavigationResult = (page: LibraryNavigationCache.Page, stamp: LibraryNavigationCache.Stamp)

    private func readNavigationPage(request: LibraryQueryRequest, usingCache: Bool,
                                    operation: @escaping @MainActor () async throws -> NavigationResult) {
        // Clients remain usable even when a heavier navigation query fails.
        // Warm navigation retries failed reads without restarting successful ones.
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            library.clients.reloadIfNeeded(refresh: !usingCache && request.kind == "logs")
        }
        let key = LibraryNavigationCache.key(request)
        if isQuerying, activeQueryKey == key { return }
        if queryTask == nil, usingCache, let page = navigationCache.value(for: key, includeFleet: request.kind == "drones") {
            applyNavigationPage(page, request: request)
            return
        }
        let current = displayedQueryKeys[request.kind] == key
        switch request.kind {
        case "logs":
            historyResultsCurrent = current
            var groupRequest = request; groupRequest.kind = "groups"; groupRequest.cursor = nil
            groupResultsCurrent = displayedQueryKeys["groups"] == LibraryNavigationCache.key(groupRequest)
        case "groups": groupResultsCurrent = current
        case "drones": droneResultsCurrent = current
        case "messages": occurrenceResultsCurrent = current
        case "map-overview": if !current { mapPage = nil }
        default: break
        }
        let previous = queryTask
        previous?.cancel()
        let token = UUID(); queryToken = token; activeQueryKey = key
        isQuerying = true; queryWasCancelled = false; queryError = nil
        queryTask = Task { [weak self, library] in
            defer { library.objectWillChange.send() }
            // A cached destination cannot release the activity lock while a
            // superseded helper is still shutting down.
            await previous?.value
            guard let self, !Task.isCancelled, queryToken == token else { return }
            defer {
                if queryToken == token { isQuerying = false; queryTask = nil; activeQueryKey = nil }
            }
            do {
                try await library.prepareNavigationIndex()
                try Task.checkCancellation()
                if usingCache, let cached = navigationCache.value(for: key, includeFleet: request.kind == "drones") {
                    applyNavigationPage(cached, request: request)
                    return
                }
                let result = try await operation()
                guard !Task.isCancelled, queryToken == token else { return }
                navigationCache.insert(result.page, for: key, readStamp: result.stamp)
                applyNavigationPage(result.page, request: request)
            } catch {
                guard !Task.isCancelled, queryToken == token else { return }
                queryError = error.localizedDescription
            }
        }
    }

    private func navigationRequest(kind: String, cursor: String? = nil) -> LibraryQueryRequest {
        var request = LibraryQueryRequest(kind: kind, scope: views.state.activeScope, annotations: annotations.state,
                                          maskedMessageKeys: views.state.maskedMessageKeys)
        request.cursor = cursor
        request.sortOrder = views.state.historySort ?? "recent"
        return request
    }

    func loadHistory(cursor: String? = nil, usingCache: Bool = false) {
        guard !isImporting, (!isMaintainingLibrary || library.isPreparingNavigation), !isCancellingQuery, let engine = engineURL else { return }
        guard FileManager.default.fileExists(atPath: databaseURL.path) || (!isReadOnly && usesPagedNavigation) else { return }
        hasLoaded = true
        var request = navigationRequest(kind: "logs", cursor: cursor)
        request.sortOrder = historySortOverride ?? views.state.historySort ?? "recent"
        let database = databaseURL
        readNavigationPage(request: request, usingCache: usingCache) { [self] in
            let stamp = navigationCache.stamp()
            let page = try await LibraryQueryService.page(LibraryLogPage.self, request: request, database: database, engine: engine, readOnly: true)
            var groupsRequest = request; groupsRequest.kind = "groups"; groupsRequest.cursor = nil
            let groups = try await LibraryQueryService.page(LibraryGroupPage.self, request: groupsRequest, database: database, engine: engine, readOnly: true)
            guard page.revision == groups.revision else { throw AnalysisError.engine("La bibliothèque a changé pendant la lecture. Rechargez la sélection.") }
            return (.history(page, groups), stamp)
        }
    }

    func loadOccurrences(groupID: String, cursor: String? = nil, usingCache: Bool = false) {
        guard !isImporting, (!isMaintainingLibrary || library.isPreparingNavigation), !isCancellingQuery, let engine = engineURL else { return }
        var request = navigationRequest(kind: "messages", cursor: cursor)
        request.groupID = groupID
        let database = databaseURL
        readNavigationPage(request: request, usingCache: usingCache) { [self] in
            let stamp = navigationCache.stamp()
            let result = try await LibraryQueryService.page(LibraryMessagePage.self, request: request, database: database, engine: engine, readOnly: true)
            return (.messages(result), stamp)
        }
    }

    func loadAuxiliary(kind: String, cursor: String? = nil, search: String? = nil, usingCache: Bool = false) {
        guard !isImporting, (!isMaintainingLibrary || library.isPreparingNavigation), !isCancellingQuery, ["drones", "map", "groups"].contains(kind),
              let engine = engineURL, FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        var request = navigationRequest(kind: kind == "map" ? "map-overview" : kind, cursor: cursor)
        request.registrySearch = search
        if kind == "map" { request.proximity = mapProximity; request.sortOrder = "recent"; request.limit = 5000 }
        let database = databaseURL
        readNavigationPage(request: request, usingCache: usingCache) { [self] in
            let stamp = navigationCache.stamp(includeFleet: kind == "drones")
            if kind == "drones" {
                let result = try await LibraryQueryService.page(LibraryDronePage.self, request: request, database: database, engine: engine, readOnly: true)
                return (.drones(result), stamp)
            } else if kind == "map" {
                var current = request
                var result: LibraryMapPage
                var mapStamp = stamp
                if request.proximity != nil, !isReadOnly, activeDetailLoads == 0, !hasExternalActivity(), !library.hasOtherNavigationWork(than: self) {
                    result = try await library.performMaintenance(navigationOwner: self) {
                        try await LibraryQueryService.page(LibraryMapPage.self, request: current, database: database, engine: engine, readOnly: false)
                    }
                    mapStamp = navigationCache.stamp()
                } else {
                    result = try await LibraryQueryService.page(LibraryMapPage.self, request: current, database: database, engine: engine, readOnly: true)
                }
                // The optional preparation above may have retained exact GPS
                // caches. Pagination itself remains a read-only operation.
                var seen = Set<String>()
                while let cursor = result.nextCursor {
                    try Task.checkCancellation()
                    guard seen.insert(cursor).inserted else { throw AnalysisError.engine("La pagination de la carte n’a pas progressé. Rechargez la sélection.") }
                    current.cursor = cursor
                    let next = try await LibraryQueryService.page(LibraryMapPage.self, request: current, database: database, engine: engine, readOnly: true)
                    guard next.revision == result.revision, next.scopeHash == result.scopeHash else {
                        throw AnalysisError.engine("La bibliothèque a changé pendant la lecture de la carte. Rechargez la sélection.")
                    }
                    result.markers += next.markers; result.nextCursor = next.nextCursor
                }
                return (.map(result), mapStamp)
            } else {
                let result = try await LibraryQueryService.page(LibraryGroupPage.self, request: request, database: database, engine: engine, readOnly: true)
                return (.groups(result), stamp)
            }
        }
    }

    func openMapFlight(logID: String) {
        guard !isLoadingFlight, !isMaintainingLibrary, let engine = engineURL else { return }
        var request = navigationRequest(kind: "logs")
        request.scope.logIDs = [logID]; request.limit = 1
        let database = databaseURL, token = UUID(); flightToken = token
        isLoadingFlight = true; flightError = nil
        flightTask = Task { [weak self, library] in
            defer {
                if let self, flightToken == token { isLoadingFlight = false; flightTask = nil }
                library.objectWillChange.send()
            }
            do {
                let result = try await LibraryQueryService.page(LibraryLogPage.self, request: request, database: database, engine: engine, readOnly: true)
                guard !Task.isCancelled, let self, flightToken == token else { return }
                guard let log = result.snapshot.logs.first else { throw AnalysisError.engine("Ce log ne fait plus partie de la sélection.") }
                isLoadingFlight = false; flightTask = nil
                library.openFlightWindow(log)
            } catch {
                guard !Task.isCancelled, let self, flightToken == token else { return }
                flightError = error.localizedDescription; library.errorMessage = error.localizedDescription
                isLoadingFlight = false; flightTask = nil
            }
        }
    }

    func loadMap(proximity: GeographicProximity? = nil) {
        guard !isImporting, (!isMaintainingLibrary || library.isPreparingNavigation), !isCancellingQuery else { return }
        mapProximity = proximity
        loadAuxiliary(kind: "map")
    }

}
