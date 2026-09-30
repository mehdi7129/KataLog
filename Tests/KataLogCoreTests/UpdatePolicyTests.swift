import XCTest
@testable import KataLogCore

final class UpdatePolicyTests: XCTestCase {
    private var valid: [String: Any] {
        ["KatalogUpdatesEnabled": true, "KatalogSparkleVersion": "2.10.0", "KatalogUpdateChannel": "staging",
         "SUFeedURL": "https://updates.example.org/staging/appcast.xml", "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
         "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true, "SUSignedFeedFailureExpirationInterval": 0,
         "SUAllowsAutomaticUpdates": false, "SUAutomaticallyUpdate": false, "SUEnableAutomaticChecks": false,
         "SUEnableJavaScript": false, "SUEnableSystemProfiling": false]
    }
    func testMissingConfigurationIsDisabledWithoutNetwork() throws {
        XCTAssertNil(try UpdatePolicy.configuration(info: [:]))
        XCTAssertNil(try UpdatePolicy.configuration(info: ["KatalogUpdatesEnabled": false, "SUFeedURL": "http://invalid"]))
    }
    func testOnlyCompleteSignedHTTPSConfigurationIsAccepted() throws {
        let config = try XCTUnwrap(UpdatePolicy.configuration(info: valid))
        XCTAssertEqual(config.channel, .staging)
        XCTAssertEqual(config.feedURL.scheme, "https")
        for name in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var info = valid; info[name] = false
            XCTAssertThrowsError(try UpdatePolicy.configuration(info: info))
        }
        for name in ["SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableAutomaticChecks", "SUEnableJavaScript", "SUEnableSystemProfiling"] {
            var info = valid; info[name] = true
            XCTAssertThrowsError(try UpdatePolicy.configuration(info: info))
        }
        var expiration = valid; expiration["SUSignedFeedFailureExpirationInterval"] = 1_728_000
        XCTAssertThrowsError(try UpdatePolicy.configuration(info: expiration))
    }
    func testCredentialsAndUnsupportedFeedsKeysAndChannelsAreRejected() throws {
        for url in ["http://updates.example.org/appcast.xml", "https://user:password@updates.example.org/appcast.xml", "https://updates.example.org/appcast.xml?token=test", "https://updates.example.org/appcast.xml#fragment", "https://updates.example.org:8443/appcast.xml", "file:///private/tmp/appcast.xml"] {
            var info = valid; info["SUFeedURL"] = url
            XCTAssertThrowsError(try UpdatePolicy.configuration(info: info))
        }
        for key in ["", "not-a-public-key", Data(repeating: 0, count: 32).base64EncodedString(), Data(repeating: 1, count: 64).base64EncodedString()] {
            var info = valid; info["SUPublicEDKey"] = key
            XCTAssertThrowsError(try UpdatePolicy.configuration(info: info))
        }
        var info = valid; info["KatalogUpdateChannel"] = "unknown"
        XCTAssertThrowsError(try UpdatePolicy.configuration(info: info))
    }
    func testRunningWorkBlocksCheckAndInstallationUntilIdle() throws {
        XCTAssertThrowsError(try UpdatePolicy.requireIdle(false))
        XCTAssertNoThrow(try UpdatePolicy.requireIdle(true))
    }
}
