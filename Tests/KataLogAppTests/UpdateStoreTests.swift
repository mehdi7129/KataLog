import XCTest
import Sparkle
@testable import KataLog

@MainActor
final class UpdateStoreTests: XCTestCase {
    func testDisabledBuildHasNoUpdaterOrRemoteCheck() {
        let store = UpdateStore(info: [:], start: false)
        XCTAssertEqual(store.state, .disabled)
        XCTAssertFalse(store.canCheck)
        XCTAssertFalse(store.driverCanCheck)
        store.checkForUpdates()
        XCTAssertEqual(store.state, .disabled)
        XCTAssertTrue(store.message.contains("DMG"))
        store.setAutomaticallyChecksForUpdates(true)
        XCTAssertFalse(store.automaticallyChecksForUpdates)
        XCTAssertFalse(store.canConfigureAutomaticChecks)
    }

    func testInvalidActiveConfigurationFailsClosed() {
        let store = UpdateStore(info: ["KatalogUpdatesEnabled": true], start: false)
        guard case .failed = store.state else { return XCTFail("Unsafe update metadata must fail closed") }
        XCTAssertFalse(store.canCheck)
        XCTAssertFalse(store.driverCanCheck)
    }

    func testSDKDelegateRejectsBusyCheckAndRestoresIdlePermissionWithoutStartingSDK() {
        let store = UpdateStore(info: [:], start: false)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        store.installationAllowed = { false }
        XCTAssertThrowsError(try store.updater(controller.updater, mayPerform: .updates))
        store.installationAllowed = { true }
        XCTAssertNoThrow(try store.updater(controller.updater, mayPerform: .updates))
        XCTAssertTrue(store.allowedChannels(for: controller.updater).isEmpty)
        XCTAssertEqual(store.state, .disabled)
    }

    func testAutomaticCheckPreferencePersistsWithoutStartingTheSDK() throws {
        let info: [String: Any] = [
            "KatalogUpdatesEnabled": true, "KatalogSparkleVersion": "2.10.0",
            "KatalogUpdateChannel": "staging", "SUFeedURL": "https://updates.example.org/staging/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0, "SUAllowsAutomaticUpdates": false,
            "SUAutomaticallyUpdate": false, "SUEnableAutomaticChecks": false,
            "SUEnableJavaScript": false, "SUEnableSystemProfiling": false
        ]
        // Sparkle uses standard defaults for the main bundle. The SwiftPM
        // XCTest runner may have an empty bundle identifier, which is not a
        // valid suite name; it still has a standard preference domain.
        let defaults = UserDefaults.standard
        let key = "SUEnableAutomaticChecks"
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let first = UpdateStore(info: info, start: false)
        XCTAssertTrue(first.canConfigureAutomaticChecks)
        first.setAutomaticallyChecksForUpdates(true)
        let reopened = UpdateStore(info: info, start: false)
        XCTAssertTrue(reopened.automaticallyChecksForUpdates)
        XCTAssertEqual(reopened.state, .ready)
        reopened.setAutomaticallyChecksForUpdates(false)
        let reopenedAgain = UpdateStore(info: info, start: false)
        XCTAssertFalse(reopenedAgain.automaticallyChecksForUpdates)
        XCTAssertEqual(reopenedAgain.state, .ready)
    }
}
