import Foundation
import KataLogCore

/// Detail parsing can create a cache/revision. Serialize those publications per library;
/// the library's activity count prevents a concurrent reset or new import from starting.
@MainActor
enum FlightDetailLoader {
    typealias Reader = @MainActor (String, Bool) async throws -> FlightLog
    private struct Pending {
        let token: UUID
        let task: Task<FlightLog, Error>
    }
    private static var pending: [URL: Pending] = [:]

    static func read(logID: String, library: LibraryStore, reader: Reader? = nil) async throws -> FlightLog {
        guard !library.isMaintainingLibrary else {
            throw AnalysisError.engine("Attendez la fin de l’opération sur la bibliothèque, puis réessayez.")
        }
        let key = library.databaseURL.standardizedFileURL
        let previous = pending[key]?.task
        let token = UUID()
        library.activeDetailLoads += 1
        let task = Task { @MainActor in
            // Waiting is asynchronous. Closing the preceding window cancels its helper;
            // this request still waits for that helper to drain before opening its database.
            _ = await previous?.result
            try Task.checkCancellation()
            guard !library.isMaintainingLibrary else {
                throw AnalysisError.engine("La bibliothèque est en cours de modification. Réessayez dans un instant.")
            }
            let readOnly = library.isReadOnly || library.isImporting || library.hasExternalActivity()
            if let reader { return try await reader(logID, readOnly) }
            guard let engine = library.engineURL else { throw AnalysisError.engine("Moteur d’analyse absent.") }
            return try await AnalysisService.detail(logID: logID, database: library.databaseURL,
                                                    engine: engine, readOnly: readOnly)
        }
        pending[key] = Pending(token: token, task: task)
        defer {
            library.activeDetailLoads -= 1
            if pending[key]?.token == token { pending.removeValue(forKey: key) }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}
