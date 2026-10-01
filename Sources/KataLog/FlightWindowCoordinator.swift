import AppKit
import SwiftUI
import Combine
import KataLogCore

/// Retains native windows until they close. Reopening a log focuses its existing window.
@MainActor
final class FlightWindowCoordinator {
    static let shared = FlightWindowCoordinator()
    private var controllers: [String: FlightLogWindowController] = [:]
    private var cascadePoint = NSPoint(x: 140, y: 900)

    static func key(logID: String, database: URL) -> String {
        database.standardizedFileURL.path + "\n" + logID
    }

    func open(log: FlightLog, library: LibraryStore) {
        let key = Self.key(logID: log.id, database: library.databaseURL)
        if let existing = controllers[key] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            if existing.window?.isMiniaturized == true { existing.window?.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let session = FlightDetailSession(log: log, library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(log.displayName) · \(log.fileName)"
        window.identifier = NSUserInterfaceItemIdentifier("flight.window.\(log.id)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 560)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: FlightWindowContent(library: library, session: session))
        let controller = FlightLogWindowController(window: window, session: session, library: library) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.load()
    }

    func closeAll(library: LibraryStore) {
        let prefix = library.databaseURL.standardizedFileURL.path + "\n"
        let owned = controllers.filter { $0.key.hasPrefix(prefix) }.map(\.value)
        for controller in owned { controller.close() }
    }
}

@MainActor
private final class FlightLogWindowController: NSWindowController, NSWindowDelegate {
    private let session: FlightDetailSession
    private let onClose: () -> Void
    private var subscriptions: Set<AnyCancellable> = []
    init(window: NSWindow, session: FlightDetailSession, library: LibraryStore, onClose: @escaping () -> Void) {
        self.session = session; self.onClose = onClose
        super.init(window: window)
        window.delegate = self
        library.views.$state.sink { [weak window] state in
            switch WorkspaceAppearance.colorScheme(for: state.theme) {
            case .dark: window?.appearance = NSAppearance(named: .darkAqua)
            case .light: window?.appearance = NSAppearance(named: .aqua)
            default: window?.appearance = nil
            }
        }.store(in: &subscriptions)
        session.$log.sink { [weak window] log in
            guard let log else { return }
            window?.title = "\(log.displayName) · \(log.fileName)"
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic window only") }
    func windowWillClose(_ notification: Notification) { session.cancel(); onClose() }
}

private struct FlightWindowContent: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var views: LibraryViewStore
    let session: FlightDetailSession
    init(library: LibraryStore, session: FlightDetailSession) {
        self.library = library; views = library.views; self.session = session
    }
    var body: some View {
        FlightDetailView(store: library, session: session)
            .preferredColorScheme(WorkspaceAppearance.colorScheme(for: views.state.theme))
    }
}
