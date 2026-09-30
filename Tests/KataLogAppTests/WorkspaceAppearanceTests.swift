import SwiftUI
import XCTest
@testable import KataLog

@MainActor
final class WorkspaceAppearanceTests: XCTestCase {
    func testFirstLaunchKeepsTheOriginalDarkAppearance() {
        XCTAssertEqual(WorkspaceAppearance.selection(for: nil), "dark")
        XCTAssertEqual(WorkspaceAppearance.colorScheme(for: nil), .dark)
        XCTAssertEqual(WorkspaceAppearance.toggledSelection(for: nil, systemScheme: .light), "light")
    }

    func testExplicitModesAndSystemToggleMatchWhatTheUserSees() {
        XCTAssertEqual(WorkspaceAppearance.colorScheme(for: "light"), .light)
        XCTAssertEqual(WorkspaceAppearance.colorScheme(for: "dark"), .dark)
        XCTAssertNil(WorkspaceAppearance.colorScheme(for: "system"))
        XCTAssertEqual(WorkspaceAppearance.toggledSelection(for: "system", systemScheme: .dark), "light")
        XCTAssertEqual(WorkspaceAppearance.toggledSelection(for: "system", systemScheme: .light), "dark")
        XCTAssertEqual(WorkspaceAppearance.toggledSelection(for: "dark", systemScheme: .light), "light")
        XCTAssertEqual(WorkspaceAppearance.toggledSelection(for: "light", systemScheme: .dark), "dark")
    }

    func testSelectedThemePersistsWithoutChangingSavedScopesOrMasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        let store = LibraryViewStore(url: url)
        var scope = store.state.activeScope
        scope.families = ["Batterie"]
        try store.setScope(scope)
        try store.mask(["text-v1:7:WARNINGBattery"], masked: true)
        for selection in ["light", "dark", "system"] {
            try store.setTheme(selection)
            let reopened = LibraryViewStore(url: url)
            XCTAssertEqual(WorkspaceAppearance.selection(for: reopened.state.theme), selection)
            XCTAssertEqual(reopened.state.activeScope, scope)
            XCTAssertEqual(reopened.state.maskedMessageKeys, ["text-v1:7:WARNINGBattery"])
        }
    }
}
