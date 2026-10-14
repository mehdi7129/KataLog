import Combine
import Foundation
import KataLogCore

/// Independent detail reads use the library's serialization and cancellation path.
@MainActor
final class LogComparisonStore: ObservableObject {
    typealias Reader = @MainActor (String) async throws -> FlightLog
    @Published private(set) var first: FlightLog?
    @Published private(set) var second: FlightLog?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let reader: Reader
    private var task: Task<Void, Never>?
    private var token = UUID()

    init(reader: @escaping Reader) { self.reader = reader }
    convenience init(library: LibraryStore) {
        self.init { id in try await FlightDetailLoader.read(logID: id, library: library) }
    }

    var comparison: ParameterComparison? {
        guard let first, let second else { return nil }
        return ParameterComparison.compare(previous: first, current: second)
    }

    func load(logIDs: [String]) {
        cancel(); first = nil; second = nil; error = nil
        guard logIDs.count == 2, Set(logIDs).count == 2 else {
            error = "Choisissez exactement deux logs distincts dans l’historique."; return
        }
        let expected = token
        isLoading = true
        task = Task { [weak self, reader] in
            do {
                let first = try await reader(logIDs[0])
                try Task.checkCancellation()
                let second = try await reader(logIDs[1])
                try Task.checkCancellation()
                guard let self, token == expected else { return }
                guard first.id == logIDs[0], second.id == logIDs[1] else {
                    throw AnalysisError.engine("Les détails reçus ne correspondent pas aux logs demandés.")
                }
                try Self.validate(first: first, second: second)
                self.first = first; self.second = second
                isLoading = false; task = nil
            } catch {
                guard !Task.isCancelled, let self, token == expected else { return }
                self.error = error.localizedDescription; isLoading = false; task = nil
            }
        }
    }

    static func validate(first: FlightLog, second: FlightLog) throws {
        for log in [first, second] {
            guard !log.droneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  log.identityProvisional != true, !log.droneID.hasPrefix("card:"), !log.droneID.hasPrefix("unknown:") else {
                throw AnalysisError.engine("L’identité du contrôleur n’est pas établie dans au moins un log. Une comparaison entre ces logs serait ambiguë.")
            }
        }
        guard first.droneID == second.droneID else {
            throw AnalysisError.engine("Choisissez deux logs du même contrôleur. Les noms et numéros de stock ne suffisent pas à établir cette correspondance.")
        }
    }

    func swap() { let previous = first; first = second; second = previous }
    func cancel() { token = UUID(); task?.cancel(); task = nil; isLoading = false }
}
