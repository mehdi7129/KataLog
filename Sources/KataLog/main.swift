import AppKit
import SwiftUI
import KataLogCore

@main
struct KataLogApp: App {
    @NSApplicationDelegateAdaptor(KataLogApplicationDelegate.self) private var applicationDelegate
    @StateObject private var library = LibraryStore(pagedNavigation: AppPreviewConfiguration().showReviewUI)
    @StateObject private var gcs = GCSStore()
    @StateObject private var updates = UpdateStore()

    var body: some Scene {
        WindowGroup("KataLog") {
            Group { if AppPreviewConfiguration().showReviewUI {
                Workspace06View(library: library, gcs: gcs, updates: updates)
            } else { LegacyWorkspaceView(store: library, gcs: gcs) } }
                .onAppear { applicationDelegate.library = library; applicationDelegate.gcs = gcs }
        }
            .defaultSize(width: 1440, height: 980)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Rechercher une mise à jour…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheck)
                }
            }
    }
}
