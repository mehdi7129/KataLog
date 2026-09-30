import XCTest
import KataLogCore
@testable import KataLog

@MainActor
final class AppPreviewConfigurationTests: XCTestCase {
    func testReviewPackageShowsUIAndUsesDistinctLibrary() {
        let review = AppPreviewConfiguration(environment: [:], reviewBuild: true)
        XCTAssertTrue(review.showReviewUI)
        XCTAssertEqual(review.defaultLibraryComponent, "KataLogPreview-0.6")
        let installed = AppPreviewConfiguration(environment: [:], reviewBuild: false, releaseVersion: "0.5.2")
        XCTAssertFalse(installed.showReviewUI)
        XCTAssertEqual(installed.defaultLibraryComponent, "KataLog")
    }
    func testDeveloperToggleDoesNotRedirectTheInstalledLibrary() {
        let developer = AppPreviewConfiguration(environment: ["KATALOG_UI_PREVIEW": "1"], reviewBuild: false)
        XCTAssertTrue(developer.showReviewUI)
        XCTAssertEqual(developer.defaultLibraryComponent, "KataLog")
    }

    func testApprovedStableWorkspaceKeepsTheInstalledLibraryAndExplicitDestination() {
        for version in ["0.6.0", "0.6.1", "0.10.0", "1.0.0"] {
            let installed = AppPreviewConfiguration(environment: ["KATALOG_LIBRARY_DIR": "/synthetic-selected"],
                                                    reviewBuild: false, releaseVersion: version)
            XCTAssertTrue(installed.showReviewUI, version)
            XCTAssertFalse(installed.reviewBuild)
            XCTAssertEqual(installed.defaultLibraryComponent, "KataLog")
            XCTAssertEqual(installed.libraryDirectory().path, "/synthetic-selected")
        }
    }

    func testOlderMissingOrMalformedVersionDoesNotEnableTheStableWorkspace() {
        for version in [nil, "", "0.5.2", "0.6.0-beta", "unknown"] as [String?] {
            let installed = AppPreviewConfiguration(environment: [:], reviewBuild: false, releaseVersion: version)
            XCTAssertFalse(installed.showReviewUI, version ?? "missing")
            XCTAssertEqual(installed.defaultLibraryComponent, "KataLog")
        }
    }

    func testLibraryRootResolutionPreservesExplicitAndEnvironmentOverrides() {
        let support = URL(fileURLWithPath: "/synthetic-support", isDirectory: true)
        let explicit = URL(fileURLWithPath: "/synthetic-explicit", isDirectory: true)
        for reviewBuild in [false, true] {
            let configuration = AppPreviewConfiguration(environment: ["KATALOG_LIBRARY_DIR": "/synthetic-override"], reviewBuild: reviewBuild)
            XCTAssertEqual(configuration.libraryDirectory(storageDirectory: explicit, applicationSupportDirectory: support), explicit)
            XCTAssertEqual(configuration.libraryDirectory(applicationSupportDirectory: support).path, "/synthetic-override")
            let defaults = AppPreviewConfiguration(environment: [:], reviewBuild: reviewBuild)
            XCTAssertEqual(defaults.libraryDirectory(applicationSupportDirectory: support).lastPathComponent,
                           reviewBuild ? "KataLogPreview-0.6" : "KataLog")
        }
    }

    func testReviewGCSNeverReadsOrMigratesInstalledSettingsQueueOrObservations() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-preview-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let support = sandbox.appendingPathComponent("Application Support"), installed = support.appendingPathComponent("KataLog")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let installedUUID = "0102030405060708090A0B0C", reviewUUID = "1112131415161718191A1B1C"
        var installedState = GCSCollectionState(downloadDirectory: installed.appendingPathComponent("private-destination").path)
        installedState.host = "installed-only.invalid"; installedState.allowedUUIDs = [installedUUID]
        installedState.queue = [GCSTransfer(droneUUID: installedUUID, remotePath: "/fs/microsd/log/synthetic/installed.ulg", size: 64,
                                          host: installedState.host, destination: installedState.downloadDirectory)]
        let original = try JSONEncoder().encode(installedState)
        try original.write(to: installed.appendingPathComponent("gcs-collection.json"))
        try original.write(to: installed.appendingPathComponent("gcs-settings.json"))
        do {
            let repository = try GCSQueueRepository(url: installed.appendingPathComponent("gcs-queue.sqlite"))
            try repository.migrateLegacy(installedState.queue)
        }
        var observations = GCSFleetObservationState()
        observations.drones = [GCSFleetObservation(uuid: installedUUID, authorized: true)]
        try JSONEncoder().encode(observations).write(to: installed.appendingPathComponent("fleet.json"))
        func installedBytes() throws -> [String: Data] {
            let paths = try FileManager.default.contentsOfDirectory(at: installed, includingPropertiesForKeys: [.isRegularFileKey])
            return try Dictionary(uniqueKeysWithValues: paths.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
                .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        let before = try installedBytes()
        let configuration = AppPreviewConfiguration(environment: [:], reviewBuild: true)
        let review = configuration.libraryDirectory(applicationSupportDirectory: support)
        let store = GCSStore(previewConfiguration: configuration, applicationSupportDirectory: support)
        XCTAssertTrue(store.host.isEmpty)
        XCTAssertTrue(store.allowedUUIDs.isEmpty)
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.downloadDirectory.path, review.appendingPathComponent("Collected Logs").path)
        let library = LibraryStore(storageDirectory: review)
        store.attach(library: library)
        defer { store.disconnect() }
        store.host = "preview-only.invalid"
        store.setAllowed(uuid: reviewUUID, allowed: true)
        let added = try await store.enqueue([GCSLogFile(path: "/fs/microsd/log/synthetic/review.ulg", size: 128)],
                                            uuid: reviewUUID, host: store.host, destination: store.downloadDirectory.path)
        XCTAssertEqual(added, 1)
        try store.flushPersistedStateForMaintenance()
        for name in ["gcs-settings.json", "gcs-queue.sqlite", "fleet.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: review.appendingPathComponent(name).path), name)
        }
        let state = try JSONDecoder().decode(GCSCollectionState.self, from: Data(contentsOf: review.appendingPathComponent("gcs-settings.json")))
        XCTAssertEqual(state.allowedUUIDs, [reviewUUID])
        XCTAssertEqual(state.host, "preview-only.invalid")
        let repository = try GCSQueueRepository(url: review.appendingPathComponent("gcs-queue.sqlite"), readOnly: true)
        XCTAssertEqual(try repository.retainedTransfers().map(\.droneUUID), [reviewUUID])
        let reviewFleet = try JSONDecoder().decode(GCSFleetObservationState.self, from: Data(contentsOf: review.appendingPathComponent("fleet.json")))
        XCTAssertEqual(reviewFleet.drones.map(\.uuid), [reviewUUID])
        let reopened = GCSStore(previewConfiguration: configuration, applicationSupportDirectory: support)
        XCTAssertEqual(reopened.host, "preview-only.invalid")
        XCTAssertEqual(reopened.queue.map(\.droneUUID), [reviewUUID])
        XCTAssertEqual(try installedBytes(), before, "Review startup and writes must not read, migrate or change installed-app state.")
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
        XCTAssertNil(store.errorMessage)
    }

    func testAttachmentReconnectWaitsForStartupMaintenanceWithoutResumingStoppedTransfers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-preview-startup-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("collector.py"), started = root.appendingPathComponent("started")
        try #"""
import json,pathlib,sys,time
(pathlib.Path(__file__).parent/'started').write_text(json.dumps(sys.argv))
print(json.dumps(dict(event='connection',connected=True)),flush=True)
print(json.dumps(dict(event='drones',drones=[dict(uuid='0102030405060708090A0B0C',time_usec=1,arming_state=1)])),flush=True)
time.sleep(30)
"""#.write(to: script, atomically: true, encoding: .utf8)
        let identity = "0102030405060708090A0B0C"
        var state = GCSCollectionState(downloadDirectory: root.path)
        state.host = "synthetic-gcs.local"; state.reconnect = true; state.allowedUUIDs = [identity]
        var stopped = GCSTransfer(droneUUID: identity, remotePath: "/fs/microsd/log/synthetic/stopped.ulg", size: 64,
                                  host: state.host, destination: root.path)
        stopped.state = "stopped"; state.queue = [stopped]
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("gcs-collection.json"))
        let library = LibraryStore(storageDirectory: root.appendingPathComponent("library"))
        let store = GCSStore(storageDirectory: root, collector: script)
        defer { store.disconnect() }
        let gate = Task { try await library.performMaintenance { try await Task.sleep(for: .milliseconds(700)) } }
        let startDeadline = Date().addingTimeInterval(2)
        while !library.isMaintainingLibrary && Date() < startDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(library.isMaintainingLibrary)
        store.attach(library: library)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gcs-settings.json").path))
        try await gate.value
        let connectionDeadline = Date().addingTimeInterval(5)
        while !store.isConnected && Date() < connectionDeadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(store.isConnected)
        XCTAssertNil(store.errorMessage)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: started))
        XCTAssertEqual(arguments.dropFirst(), ["discover", "--host", "synthetic-gcs.local", "--port", "1999"])
        XCTAssertEqual(store.queue.map(\.state), ["stopped"])
        XCTAssertFalse(store.isBusy)
    }

    func testFreshAttachmentInitializesOwnedDestinationAfterStartupMaintenance() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("katalog-preview-fresh-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let configuration = AppPreviewConfiguration(environment: [:], reviewBuild: true)
        let root = configuration.libraryDirectory(applicationSupportDirectory: support)
        let library = LibraryStore(storageDirectory: root)
        let store = GCSStore(previewConfiguration: configuration, applicationSupportDirectory: support)
        defer { store.disconnect() }
        let gate = Task { try await library.performMaintenance { try await Task.sleep(for: .milliseconds(700)) } }
        let startDeadline = Date().addingTimeInterval(2)
        while !library.isMaintainingLibrary && Date() < startDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(library.isMaintainingLibrary)
        store.attach(library: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.downloadDirectory.path))
        XCTAssertNil(store.errorMessage)
        try await gate.value
        let settings = root.appendingPathComponent("gcs-settings.json")
        let persistenceDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: settings.path) && Date() < persistenceDeadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gcs-queue.sqlite").path))
        XCTAssertNil(store.downloadDirectoryIssue)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isConnecting)
    }
}
