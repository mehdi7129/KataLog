import SwiftUI
import KataLogCore

struct RecordedMetadataView: View {
    let log: FlightLog
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let battery = log.batteryDetails {
                recordedSection("Batteries · champs enregistrés par instance", value: battery)
                Text("Le numéro de série d’une batterie identifie le pack, sans attribuer un numéro au drone.").font(.caption).foregroundStyle(.secondary)
            }
            if let gnss = log.gnssDetails { recordedSection("GNSS · champs enregistrés par récepteur", value: gnss) }
            if let metadata = log.metadataDetails {
                recordedSection("Informations enregistrées et provenance", value: metadata)
            }
            if let parameters = log.parameterDetails {
                recordedSection("Paramètres typés et changements", value: parameters)
                Text("Les changements décrivent ce qui a été enregistré ; leur proximité avec une alerte ne prouve pas une relation de cause à effet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let dropouts = log.dropouts {
                recordedSection("Interruptions de journalisation · \(dropouts.count)", value: .array(dropouts))
            }
        }
    }
    private func recordedSection(_ title: String, value: JSONValue) -> some View {
        DisclosureGroup(title) {
            Text(formatted(value))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func formatted(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? value.description
    }
}
