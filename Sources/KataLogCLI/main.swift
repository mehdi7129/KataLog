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
                    archiveDestination: option("--archive-destination").map { URL(fileURLWithPath: $0) },
                    additionalOutputs: option("--html").map { [URL(fileURLWithPath: $0)] } ?? [])
            } else if let path = option("--snapshot") {
                snapshot = try AnalysisService.decode(Data(contentsOf: URL(fileURLWithPath: path)))
                if let html = option("--html") {
                    let sources = snapshot.logs.flatMap { $0.sourcePaths + ($0.sourceAvailability ?? []).map(\.path) }
                    try validateHTMLDestination(URL(fileURLWithPath: html),
                                                snapshot: URL(fileURLWithPath: path),
                                                inputs: sources.map { URL(fileURLWithPath: $0) })
                }
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

    private static func validateHTMLDestination(_ output: URL, snapshot: URL, inputs: [URL]) throws {
        func identity(_ url: URL) throws -> (String, String?) {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            // Reserve case/normalization variants on all volumes, including
            // when a missing file will later be created on a macOS volume.
            let key = resolved.path.decomposedStringWithCanonicalMapping
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard FileManager.default.fileExists(atPath: resolved.path) else { return (key, nil) }
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return (key, nil) }
            return (key, "\(device):\(inode)")
        }
        let target = try identity(output)
        var protectedInputs = inputs + [snapshot, URL(fileURLWithPath: CommandLine.arguments[0])]
        let roots = Set([snapshot.deletingLastPathComponent(), snapshot.resolvingSymlinksInPath().deletingLastPathComponent()])
        for root in roots {
            let controls = ["annotations.json", "views.json", "fleet.json", "settings.json", "gcs-collection.json",
                            "gcs-settings.json", "import-options.json", ".library-writer.lock", ".restore-journal.json", ".archive-journal.json"]
            protectedInputs += controls.map { root.appendingPathComponent($0) }
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let databases = entries.filter { ["sqlite", "sqlite3"].contains($0.pathExtension.lowercased()) }
                + [root.appendingPathComponent("library.sqlite"), root.appendingPathComponent("gcs-queue.sqlite")]
            protectedInputs += databases.flatMap { database in
                ["", "-wal", "-shm", "-journal"].map { URL(fileURLWithPath: database.path + $0) }
            }
            let dictionaries = try identity(root.appendingPathComponent("event-dictionaries")).0
            if target.0 == dictionaries || target.0.hasPrefix(dictionaries + "/") {
                throw AnalysisError.engine("Le chemin de sortie empiète sur les dictionnaires de la bibliothèque.")
            }
        }
        for input in protectedInputs {
            let protected = try identity(input)
            if target.0 == protected.0 || (target.1 != nil && target.1 == protected.1) {
                throw AnalysisError.engine("Le chemin de sortie remplacerait le snapshot, une source ou une donnée de la bibliothèque.")
            }
        }
    }
}
