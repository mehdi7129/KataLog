import SwiftUI

/// Update state uses the same compact bento card as the other workspace settings.
struct UpdateSettingsView: View {
    @ObservedObject var store: UpdateStore
    let readOnly: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { Palette(dark: colorScheme == .dark) }
    private var ink: Color { palette.primary }
    private var subtle: Color { palette.secondary }
    private var checking: Bool { store.state == .checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Mises à jour").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                        .foregroundStyle(store.state == .upToDate ? palette.mint : ink)
                        .frame(width: 42, height: 42)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.title).font(.system(size: 13, weight: .semibold))
                        Text(store.message).font(.system(size: 12)).foregroundStyle(subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if checking {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Recherche d’une nouvelle version en cours")
                    }
                }
                if readOnly {
                    Label("Bibliothèque en lecture seule. Fermez l’autre instance avant d’installer une mise à jour.", systemImage: "lock")
                        .font(.system(size: 12)).foregroundStyle(subtle)
                }
                HStack {
                    Text("Installation sur votre Mac").font(.system(size: 11)).foregroundStyle(subtle)
                    Spacer()
                    Button("Rechercher une mise à jour") { store.checkForUpdates() }
                        .buttonStyle(WorkspaceActionButtonStyle(palette: palette))
                        .disabled(readOnly || !store.canCheck || checking)
                        .accessibilityIdentifier("updates.check")
                        .accessibilityHint("Vérifie le flux signé et demande votre choix avant installation.")
                        .help(readOnly ? "L’installation attend la fermeture de l’autre instance." : "Les opérations en cours doivent être terminées.")
                }
            }
            Label("Les imports, collectes et exports se terminent avant le redémarrage.", systemImage: "clock")
                .font(.system(size: 11)).foregroundStyle(subtle)
        }
        .foregroundStyle(ink).padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Réglages des mises à jour de KataLog")
    }

    private var symbol: String {
        switch store.state {
        case .disabled: "arrow.down.app"
        case .upToDate: "checkmark.seal"
        case .failed: "exclamationmark.circle"
        case .deferred: "clock.arrow.circlepath"
        default: "arrow.triangle.2.circlepath"
        }
    }
}
