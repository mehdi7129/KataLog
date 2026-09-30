import XCTest
@testable import KataLog

final class AppPreviewConfigurationTests: XCTestCase {
    func testReviewPackageShowsUIAndUsesDistinctLibrary() {
        let review = AppPreviewConfiguration(environment: [:], reviewBuild: true)
        XCTAssertTrue(review.showReviewUI)
        XCTAssertEqual(review.defaultLibraryComponent, "KataLogPreview-0.6")
        let installed = AppPreviewConfiguration(environment: [:], reviewBuild: false)
        XCTAssertFalse(installed.showReviewUI)
        XCTAssertEqual(installed.defaultLibraryComponent, "KataLog")
    }
    func testDeveloperToggleDoesNotRedirectTheInstalledLibrary() {
        let developer = AppPreviewConfiguration(environment: ["KATALOG_UI_PREVIEW": "1"], reviewBuild: false)
        XCTAssertTrue(developer.showReviewUI)
        XCTAssertEqual(developer.defaultLibraryComponent, "KataLog")
    }
}
