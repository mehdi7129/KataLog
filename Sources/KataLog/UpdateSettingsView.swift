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
    private var isPreview: Bool { AppPreviewConfiguration().reviewBuild }
    private var updateMessage: String {
        guard store.state == .disabled, isPreview else { return store.message }
        return "Cette Preview se met à jour manuellement. Installez le prochain DMG Preview à la place de KataLog Preview. Sa bibliothèque dédiée est conservée."
    }
    private var checkExplanation: String {
        if readOnly { return "Fermez l’autre instance avant de rechercher une mise à jour." }
        if checking { return "La recherche d’une nouvelle version est en cours." }
        if store.workBlocked || !store.installationAllowed() { return "Terminez les imports, collectes ou exports en cours avant de rechercher une mise à jour." }
        if !store.driverCanCheck { return "Le service de mise à jour n’est pas encore prêt." }
        return "Vérifie le flux signé. Vous choisissez ensuite si vous souhaitez installer la nouvelle version."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Mises à jour").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    BentoIcon(symbol: symbol, size: 22)
                        .foregroundStyle(store.state == .upToDate ? palette.mint : ink)
                        .frame(width: 42, height: 42)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.title).font(.system(size: 13, weight: .semibold))
                        Text(updateMessage).font(.system(size: 12)).foregroundStyle(subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if checking {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Recherche d’une nouvelle version en cours")
                    }
                }
                if store.canConfigureAutomaticChecks {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Rechercher automatiquement les mises à jour", isOn: Binding(
                            get: { store.automaticallyChecksForUpdates },
                            set: { store.setAutomaticallyChecksForUpdates($0) }
                        ))
                        .toggleStyle(.switch).controlSize(.small)
                        .font(.system(size: 12)).disabled(readOnly)
                        .accessibilityIdentifier("updates.automaticChecks")
                        Text("KataLog vous propose les nouvelles versions. Vous choisissez quand installer et redémarrer.")
                            .font(.system(size: 11)).foregroundStyle(subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if readOnly && store.canConfigureAutomaticChecks {
                    Label("Bibliothèque en lecture seule. Fermez l’autre instance avant d’installer une mise à jour.", systemImage: "lock")
                        .font(.system(size: 12)).foregroundStyle(subtle)
                }
                if store.canConfigureAutomaticChecks {
                    HStack {
                        Text("Installation sur votre Mac").font(.system(size: 11)).foregroundStyle(subtle)
                        Spacer()
                        Button("Rechercher une mise à jour") { store.checkForUpdates() }
                            .buttonStyle(WorkspaceActionButtonStyle(palette: palette))
                            .disabled(readOnly || !store.canCheck || checking)
                            .accessibilityIdentifier("updates.check")
                            .accessibilityHint(checkExplanation)
                            .help(checkExplanation)
                    }
                }
            }
            if store.canConfigureAutomaticChecks {
                Label("Les imports, collectes et exports se terminent avant le redémarrage.", systemImage: "clock")
                    .font(.system(size: 11)).foregroundStyle(subtle)
            }
        }
        .foregroundStyle(ink).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(palette.border, lineWidth: 1))
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
