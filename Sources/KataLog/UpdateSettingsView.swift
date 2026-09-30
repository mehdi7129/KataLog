import SwiftUI

/// Standalone settings proposal. Integration into navigation follows visual approval.
struct UpdateSettingsView: View {
    @ObservedObject var store: UpdateStore
    let readOnly: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { colorScheme == .dark ? .white : .black }
    private var surface: Color { colorScheme == .dark ? Color(white: 0.10) : .white }
    private var subtle: Color { ink.opacity(0.62) }
    private var checking: Bool { store.state == .checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Mises à jour").font(.system(size: 28, weight: .semibold)).tracking(-0.7)
                Text("Les nouvelles versions, avec votre bibliothèque conservée.")
                    .font(.system(size: 13)).foregroundStyle(subtle)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                        .foregroundStyle(store.state == .upToDate ? Color.green : ink)
                        .frame(width: 42, height: 42)
                        .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.title).font(.system(size: 17, weight: .semibold))
                        Text(store.message).font(.system(size: 13)).foregroundStyle(subtle)
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
                        .buttonStyle(.borderedProminent).tint(ink)
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .disabled(readOnly || !store.canCheck || checking)
                        .accessibilityIdentifier("updates.check")
                        .accessibilityHint("Vérifie le flux signé et demande votre choix avant installation.")
                        .help(readOnly ? "L’installation attend la fermeture de l’autre instance." : "Les opérations en cours doivent être terminées.")
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ink.opacity(0.08), lineWidth: 1))
            Label("Les imports, collectes et exports se terminent avant le redémarrage.", systemImage: "clock")
                .font(.system(size: 12)).foregroundStyle(subtle)
        }
        .foregroundStyle(ink).padding(28).frame(minWidth: 480, idealWidth: 660)
        .background(colorScheme == .dark ? Color(white: 0.055) : Color(white: 0.965))
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
