import SwiftUI

/// The original workspace palette, shared with the paginated workspace.
struct Palette {
    let dark: Bool
    var background: Color { Color(hex: dark ? 0x0B0B0B : 0xF7F7F5) }
    var sidebar: Color { Color(hex: dark ? 0x111111 : 0xEEEEEC) }
    var card: Color { Color(hex: dark ? 0x191919 : 0xFFFFFF) }
    var raised: Color { Color(hex: dark ? 0x222222 : 0xF2F2EF) }
    var border: Color { Color(hex: dark ? 0x303030 : 0xE1E1DC) }
    var primary: Color { Color(hex: dark ? 0xF3F3F1 : 0x171717) }
    var secondary: Color { Color(hex: dark ? 0xA4A4A4 : 0x666666) }
    var muted: Color { Color(hex: dark ? 0x929292 : 0x6B6B6B) }
    var mint: Color { Color(hex: dark ? 0x8BC4AC : 0x397E61) }
    var amber: Color { Color(hex: dark ? 0xE3B771 : 0x956019) }
    var red: Color { Color(hex: dark ? 0xE49089 : 0xB34840) }
}

enum WorkspaceAppearance {
    /// An unset preference retains the original dark workspace. Only an explicit
    /// "system" preference delegates appearance to macOS.
    static func selection(for value: String?) -> String {
        guard let value, ["system", "light", "dark"].contains(value) else { return "dark" }
        return value
    }

    static func colorScheme(for value: String?) -> ColorScheme? {
        switch selection(for: value) {
        case "system": nil
        case "light": .light
        default: .dark
        }
    }

    static func toggledSelection(for value: String?, systemScheme: ColorScheme) -> String {
        let current = colorScheme(for: value) ?? systemScheme
        return current == .dark ? "light" : "dark"
    }
}

struct WorkspaceActionButtonStyle: ButtonStyle {
    let palette: Palette
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 38)
            .foregroundStyle(prominent ? palette.background : palette.primary)
            .background(prominent ? palette.primary : palette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(prominent ? .clear : palette.border, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// Direct light/dark access, with system appearance kept available in the menu.
struct WorkspaceThemeControl: View {
    @Binding var selection: String
    let palette: Palette
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.isEnabled) private var isEnabled

    private var dark: Bool {
        (WorkspaceAppearance.colorScheme(for: selection) ?? systemScheme) == .dark
    }
    private var actionLabel: String { dark ? "Activer le thème clair" : "Activer le thème sombre" }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                selection = WorkspaceAppearance.toggledSelection(for: selection, systemScheme: systemScheme)
            } label: {
                Image(systemName: dark ? "sun.max" : "moon")
                    .font(.system(size: 14)).frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
            .help(actionLabel)
            .accessibilityLabel(actionLabel)
            .accessibilityIdentifier("appearance.toggle")

            Menu {
                Button("Système") { selection = "system" }
                Button("Clair") { selection = "light" }
                Button("Sombre") { selection = "dark" }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium)).frame(width: 16, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Choisir le thème : système, clair ou sombre")
            .accessibilityLabel("Choisir le thème")
            .accessibilityIdentifier("appearance.menu")
        }
        .foregroundStyle(palette.secondary)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 7))
        .opacity(isEnabled ? 1 : 0.45)
        .fixedSize()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
