import Combine
import Foundation
import KataLogCore

/// Reading state belongs to one window, never to the library's current selection.
@MainActor
final class FlightDetailSession: ObservableObject {
    typealias Reader = @MainActor (String) async throws -> FlightLog
    @Published private(set) var log: FlightLog?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var isActive = true
    private let reader: Reader
    private var annotationSubscription: AnyCancellable?
    private var clientSubscription: AnyCancellable?
    private weak var library: LibraryStore?

    init(log: FlightLog?, reader: @escaping Reader) {
        self.log = log
        self.reader = reader
    }

    convenience init(log: FlightLog?, library: LibraryStore) {
        self.init(log: log) { [weak library] id in
            guard let library else {
                throw AnalysisError.engine("Moteur d’analyse absent.")
            }
            return try await FlightDetailLoader.read(logID: id, library: library)
        }
        self.library = library
        annotationSubscription = library.annotations.$state.sink { [weak self, weak library] state in
            guard let self, let log = self.log else { return }
            self.log = state.applying(to: log, relatedLogs: library?.snapshot.logs ?? [])
        }
        clientSubscription = library.clients.$isWorking.removeDuplicates().dropFirst().sink { [weak self] working in
            guard !working else { return }
            Task { @MainActor [weak self] in
                guard let self, isActive else { return }
                load()
            }
        }
    }

    func load() {
        guard let log else { return }
        isActive = true
        task?.cancel()
        generation = UUID()
        let expected = generation
        isLoading = true; error = nil
        task = Task { [weak self, reader] in
            do {
                try Task.checkCancellation()
                let detail = try await reader(log.id)
                guard !Task.isCancelled, let self, generation == expected else { return }
                guard detail.id == log.id else { throw AnalysisError.engine("Le détail reçu ne correspond pas au log demandé.") }
                self.log = library?.annotations.state.applying(to: detail, relatedLogs: library?.snapshot.logs ?? []) ?? detail
                isLoading = false; task = nil
            } catch {
                guard !Task.isCancelled, let self, generation == expected else { return }
                self.error = error.localizedDescription; isLoading = false; task = nil
            }
        }
    }

    func cancel() {
        isActive = false; generation = UUID(); task?.cancel(); task = nil; isLoading = false
    }
}
