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
}
