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
            let snapshot: FleetSnapshot
            if let folder = option("--folder") {
                guard let database = option("--database") else { throw AnalysisError.unavailable("--database requis") }
                let db = URL(fileURLWithPath: database)
                let output = option("--output").map { URL(fileURLWithPath: $0) } ?? db.deletingLastPathComponent().appendingPathComponent("library.json")
                let engine = URL(fileURLWithPath: option("--engine") ?? "Sources/KataLog/Resources/analyzer.py")
                snapshot = try await AnalysisService.scan(folder: URL(fileURLWithPath: folder), database: db, output: output,
                    progress: db.deletingLastPathComponent().appendingPathComponent("progress.json"), engine: engine)
            } else if let path = option("--snapshot") {
                snapshot = try AnalysisService.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            } else {
                print("katalog-cli --folder DOSSIER --database BIBLIOTHEQUE.sqlite [--output JSON] [--html RAPPORT.html] [--engine analyzer.py]\nkatalog-cli --snapshot BIBLIOTHEQUE.json --html RAPPORT.html")
                return
            }
            if let html = option("--html") { try ReportRenderer.html(snapshot).write(toFile: html, atomically: true, encoding: .utf8) }
            let stats = snapshot.importStats
            print("\(snapshot.logs.count) fichiers · \(snapshot.drones.count) identités drone · \(snapshot.logs.reduce(0) { $0 + $1.messages.count }) messages · \(snapshot.alertLogCount) logs avec alertes · \(snapshot.failsafeLogCount) logs avec failsafe")
            print("Import : \(stats.imported) nouveaux, \(stats.unchanged) inchangés, \(stats.duplicates) doublons, \(stats.failed) erreurs")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
