import SwiftUI

/// Shared colors for the native workspace and its collection screens.
struct Palette {
    let dark: Bool
    var background: Color { Color(hex: dark ? 0x0B0B0B : 0xF7F7F5) }
    var sidebar: Color { Color(hex: dark ? 0x111111 : 0xEEEEEC) }
    var card: Color { Color(hex: dark ? 0x191919 : 0xFFFFFF) }
    var raised: Color { Color(hex: dark ? 0x202020 : 0xF4F4F2) }
    var border: Color { Color(hex: dark ? 0x30302E : 0xE3E3DF) }
    var buttonBorder: Color { Color(hex: dark ? 0x444441 : 0xD6D6D1) }
    var hover: Color { Color(hex: dark ? 0x272725 : 0xF2F2EF) }
    var active: Color { Color(hex: dark ? 0x2B2B29 : 0xDEDED9) }
    var primary: Color { Color(hex: dark ? 0xF3F3F1 : 0x1B1B1B) }
    var secondary: Color { Color(hex: dark ? 0xA4A4A0 : 0x71716D) }
    var muted: Color { Color(hex: dark ? 0x81817B : 0x8A8A84) }
    var mint: Color { Color(hex: dark ? 0x9BCBBC : 0x427C6F) }
    var amber: Color { Color(hex: dark ? 0xDFB577 : 0x976613) }
    var red: Color { Color(hex: dark ? 0xE2968D : 0xB45148) }
}

enum BentoTokens {
    static let cardRadius: CGFloat = 18
    static let buttonRadius: CGFloat = 12
    static let cardPadding: CGFloat = 24
    static let spacing: CGFloat = 18
    static let sidebarWidth: CGFloat = 230
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
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceButtonSurface(label: configuration.label, palette: palette,
                               prominent: prominent, compact: compact,
                               selected: false, destructive: configuration.role == .destructive,
                               isPressed: configuration.isPressed)
    }
}

private struct WorkspaceButtonSurface<Label: View>: View {
    let label: Label
    let palette: Palette
    let prominent: Bool
    let compact: Bool
    let selected: Bool
    let destructive: Bool
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @Environment(\.isFocused) private var focused

    private var fill: Color {
        if isEnabled && isPressed { return palette.active }
        if isEnabled && hovering { return palette.hover }
        return .clear
    }

    var body: some View {
        label
            .font(.system(size: 12, weight: prominent || selected ? .semibold : .medium))
            .padding(.horizontal, compact ? 11 : 15)
            .padding(.vertical, compact ? 6 : 9)
            .frame(minHeight: compact ? 32 : 38)
            .foregroundStyle(destructive ? palette.red : palette.primary)
            .background(fill, in: RoundedRectangle(cornerRadius: BentoTokens.buttonRadius))
            .overlay {
                RoundedRectangle(cornerRadius: BentoTokens.buttonRadius)
                    .strokeBorder(focused && isEnabled ? palette.secondary : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: BentoTokens.buttonRadius))
            .opacity(isEnabled ? (prominent && (isPressed || hovering) ? 0.86 : 1) : 0.45)
            .onHover { hovering = $0 }
    }
}

private enum WorkspaceThemeOption: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Système"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }
    var symbol: String {
        switch self {
        case .system: "desktopcomputer"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

private struct WorkspaceThemeChoiceStyle: ButtonStyle {
    let palette: Palette
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceButtonSurface(label: configuration.label, palette: palette,
                               prominent: false, compact: false,
                               selected: selected, destructive: false, isPressed: configuration.isPressed)
    }
}

/// Independent appearance choices retain the ordinary native button behavior.
struct WorkspaceThemeChoices: View {
    @Binding var selection: String
    let palette: Palette

    var body: some View {
        HStack(spacing: 9) {
            ForEach(WorkspaceThemeOption.allCases) { option in
                let selected = WorkspaceAppearance.selection(for: selection) == option.rawValue
                Button {
                    selection = option.rawValue
                } label: {
                    HStack(spacing: 8) {
                        BentoIcon(symbol: option.symbol, size: 14)
                        Text(option.label)
                        BentoIcon(symbol: "checkmark", size: 10)
                            .opacity(selected ? 1 : 0)
                    }
                }
                .buttonStyle(WorkspaceThemeChoiceStyle(palette: palette, selected: selected))
                .accessibilityLabel(option.label)
                .accessibilityValue(selected ? "Sélectionné" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("appearance.choice.\(option.rawValue)")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A single click switches light and dark. System appearance lives in Settings.
struct WorkspaceThemeControl: View {
    @Binding var selection: String
    let palette: Palette
    @Environment(\.colorScheme) private var systemScheme

    private var dark: Bool {
        (WorkspaceAppearance.colorScheme(for: selection) ?? systemScheme) == .dark
    }
    private var actionLabel: String { dark ? "Activer le thème clair" : "Activer le thème sombre" }

    var body: some View {
        Button {
            selection = WorkspaceAppearance.toggledSelection(for: selection, systemScheme: systemScheme)
        } label: {
            BentoIcon(symbol: dark ? "sun.max" : "moon", size: 17)
        }
        .buttonStyle(WorkspaceActionButtonStyle(palette: palette, compact: true))
        .help(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityIdentifier("appearance.toggle")
    }
}

/// Regular SF Symbols share one size; the drone is a four-rotor outline.
struct BentoIcon: View {
    let symbol: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if symbol == "drone" {
                BentoDroneShape()
                    .stroke(style: StrokeStyle(lineWidth: size * 1.65 / 24,
                                               lineCap: .round, lineJoin: .round))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .regular))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct BentoDroneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 9, y: 9, width: 6, height: 6), cornerSize: CGSize(width: 2, height: 2))
        for (start, end) in [
            (CGPoint(x: 9.5, y: 9.5), CGPoint(x: 6.5, y: 6.5)),
            (CGPoint(x: 14.5, y: 9.5), CGPoint(x: 17.5, y: 6.5)),
            (CGPoint(x: 9.5, y: 14.5), CGPoint(x: 6.5, y: 17.5)),
            (CGPoint(x: 14.5, y: 14.5), CGPoint(x: 17.5, y: 17.5))
        ] {
            path.move(to: start)
            path.addLine(to: end)
        }
        for center in [CGPoint(x: 5.5, y: 5.5), CGPoint(x: 18.5, y: 5.5),
                       CGPoint(x: 5.5, y: 18.5), CGPoint(x: 18.5, y: 18.5)] {
            path.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        }
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                              tx: origin.x, ty: origin.y))
    }
}

struct BentoPanel<Content: View>: View {
    let palette: Palette
    private let content: Content

    init(palette: Palette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(BentoTokens.cardPadding)
            .background(palette.card, in: RoundedRectangle(cornerRadius: BentoTokens.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: BentoTokens.cardRadius)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
    }
}

/// A status stays plain text with a colored dot, without a button surface.
struct BentoStatus: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(label).font(.system(size: 11)).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
