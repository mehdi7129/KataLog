import Foundation

/// A review package has its own library. Turning on developer UI in an
/// ordinary build does not silently redirect an explicitly selected library.
struct AppPreviewConfiguration {
    let reviewBuild: Bool
    let showReviewUI: Bool
    var defaultLibraryComponent: String { reviewBuild ? "KataLogPreview-0.6" : "KataLog" }

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         reviewBuild: Bool = Bundle.main.object(forInfoDictionaryKey: "KataLogUIReviewPreview") as? Bool == true) {
        self.reviewBuild = reviewBuild
        showReviewUI = reviewBuild || environment["KATALOG_UI_PREVIEW"] == "1"
    }
}
