import SwiftUI
import KataLogCore

struct FlightSheet06: View {
    @ObservedObject var library: LibraryStore
    var body: some View {
        FlightDetailView(store: library)
            .frame(minWidth: 900, minHeight: 620)
    }
}
