import SwiftUI
import KataLogCore

struct AlertExplanationView: View {
    let message: LogMessage
    @State private var expanded = false
    private var explanation: AlertExplanation { AlertKnowledge.explanation(for: message) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(explanation.title, systemImage: explanation.isDocumented ? "text.book.closed" : "info.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(explanation.meaning).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Vérifications et limites", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(explanation.checks, id: \.self) { check in
                        HStack(alignment: .top, spacing: 7) {
                            Text("•").foregroundStyle(.secondary)
                            Text(check).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(explanation.limits).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 12)).padding(.top, 8)
            }.font(.system(size: 12, weight: .medium))
            Text(explanation.provenance).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(explanation.sources, id: \.url) { source in
                Link(destination: source.url) {
                    Label(source.title, systemImage: "arrow.up.right").font(.system(size: 11))
                }.tint(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07), lineWidth: 1))
        .onChange(of: message.groupKey) { _, _ in expanded = false }
    }
}
