import Foundation
import KataLogCore

@main
struct KataLogCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        do {
            var writerLease: LibraryWriterLease?
            defer { withExtendedLifetime(writerLease) {} }
            let snapshot: FleetSnapshot
            if let folder = option("--folder") {
                guard let database = option("--database") else { throw AnalysisError.unavailable("--database requis") }
                let db = URL(fileURLWithPath: database)
                writerLease = try LibraryWriterLease(directory: db.deletingLastPathComponent())
                guard writerLease?.isWritable == true else { throw AnalysisError.engine("Une autre instance utilise cette bibliothèque. Fermez-la avant l’import CLI.") }
                let output = option("--output").map { URL(fileURLWithPath: $0) } ?? db.deletingLastPathComponent().appendingPathComponent("library.json")
                let engine: URL
                if let explicit = option("--engine") { engine = URL(fileURLWithPath: explicit) }
                else if let bundled = Bundle.main.url(forResource: "analyzer", withExtension: "py") { engine = bundled }
                else {
                    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
                    let installed = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/analyzer.py")
                    engine = FileManager.default.fileExists(atPath: installed.path) ? installed : URL(fileURLWithPath: "Sources/KataLog/Resources/analyzer.py")
                }
                snapshot = try await AnalysisService.scan(folder: URL(fileURLWithPath: folder), database: db, output: output,
                    progress: db.deletingLastPathComponent().appendingPathComponent("progress.json"), engine: engine,
                    archiveDestination: option("--archive-destination").map { URL(fileURLWithPath: $0) })
            } else if let path = option("--snapshot") {
                snapshot = try AnalysisService.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            } else {
                print("katalog-cli --folder DOSSIER --database BIBLIOTHEQUE.sqlite [--output JSON] [--html RAPPORT.html] [--archive-destination DOSSIER] [--engine analyzer.py]\nkatalog-cli --snapshot BIBLIOTHEQUE.json --html RAPPORT.html")
                return
            }
            if let html = option("--html") { try ReportRenderer.html(snapshot).write(toFile: html, atomically: true, encoding: .utf8) }
            let stats = snapshot.importStats
            print("\(snapshot.logs.count) fichiers · \(snapshot.drones.count) identités drone · \(snapshot.logs.reduce(0) { $0 + $1.messages.count }) messages · \(snapshot.alertLogCount) logs avec alertes · \(snapshot.failsafeLogCount) logs avec failsafe")
            print("Import : \(stats.imported) nouveaux, \(stats.unchanged) inchangés, \(stats.duplicates) doublons, \(stats.failed) erreurs")
            if stats.archiveRequested != nil {
                print("Copies originales : \(stats.archiveCompleted ?? 0) vérifiées, \(stats.archiveReused ?? 0) réutilisées, \(stats.archiveSkipped ?? 0) ignorées, \(stats.archiveFailed ?? 0) erreurs")
                if (stats.archiveFailed ?? 0) > 0 {
                    throw AnalysisError.engine("La copie de certains originaux a échoué. Consultez archiveResult.errors dans le JSON exporté avant de retirer la source.")
                }
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
