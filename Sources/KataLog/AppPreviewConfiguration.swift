import Foundation

/// A review package has its own library. Turning on developer UI in an
/// ordinary build does not silently redirect an explicitly selected library.
struct AppPreviewConfiguration {
    let reviewBuild: Bool
    let showReviewUI: Bool
    private let libraryOverride: String?
    private let previewLibraryComponent: String?
    var defaultLibraryComponent: String {
        guard reviewBuild else { return "KataLog" }
        if let name = previewLibraryComponent,
           name.range(of: #"^KataLogPreview-[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil {
            return name
        }
        return "KataLogPreview-0.6"
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         reviewBuild: Bool = Bundle.main.object(forInfoDictionaryKey: "KataLogUIReviewPreview") as? Bool == true,
         releaseVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         previewLibraryComponent: String? = Bundle.main.object(forInfoDictionaryKey: "KataLogPreviewLibraryComponent") as? String) {
        self.reviewBuild = reviewBuild
        self.previewLibraryComponent = previewLibraryComponent
        // The approved workspace ships in stable 0.6+ builds. Preview storage
        // remains a separate choice, never inferred from the workspace layout.
        let approvedRelease = releaseVersion.map {
            $0.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
                && $0.compare("0.6.0", options: .numeric) != .orderedAscending
        } ?? false
        showReviewUI = reviewBuild || environment["KATALOG_UI_PREVIEW"] == "1" || approvedRelease
        libraryOverride = environment["KATALOG_LIBRARY_DIR"]
    }

    /// Resolve before reading any store, including legacy GCS state. Review
    /// builds must never migrate installed-app data through a different root.
    func libraryDirectory(storageDirectory: URL? = nil,
                          applicationSupportDirectory: URL? = nil) -> URL {
        if let storageDirectory { return storageDirectory }
        if let libraryOverride { return URL(fileURLWithPath: libraryOverride, isDirectory: true) }
        let support = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(defaultLibraryComponent, isDirectory: true)
    }
}
