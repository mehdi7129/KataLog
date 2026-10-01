import SwiftUI
import KataLogCore

/// A native button keeps explanations available to both pointer and keyboard users.
struct LibraryHelpButton: View {
    var title: String
    var text: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("À propos de « \(title) »")
        .accessibilityHint("Ouvre une explication")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }.padding(18).frame(width: 320, alignment: .leading)
        }
    }
}

struct LogAssessmentBadge: View {
    var log: FlightLog
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        BentoStatus(label: log.assessment.label, color: color)
            .help(log.assessment.help)
            .accessibilityLabel(log.assessment.label + ", " + log.assessment.reason)
    }
    private var color: Color {
        switch log.assessment.tone {
        case "red": scheme == .dark ? .red : Color(red: 0.72, green: 0.12, blue: 0.12)
        case "orange": scheme == .dark ? .orange : Color(red: 0.66, green: 0.32, blue: 0.05)
        case "yellow": scheme == .dark ? .yellow : Color(red: 0.55, green: 0.40, blue: 0.04)
        default: .secondary
        }
    }
}
