import SwiftUI

enum AlertProfile06 {
    enum ChartKind: Equatable { case empty, bars, radar }
    static func chartKind(axisCount: Int) -> ChartKind { axisCount == 0 ? .empty : axisCount < 3 ? .bars : .radar }
    /// Presentation zoom only. Raw counts and the number of readable logs stay unchanged.
    static func displayMaximum(counts: [String: Int], denominator: Int) -> Int {
        guard denominator > 0 else { return 1 }
        let peak = max(0, counts.values.max() ?? 0)
        guard peak > 0 else { return 1 }
        let remainder = peak % 4
        guard remainder > 0, peak <= Int.max - (4 - remainder) else { return peak }
        return peak + 4 - remainder
    }
    static func moving(_ family: String, in axes: [String], by offset: Int) -> [String] {
        guard let index = axes.firstIndex(of: family), axes.indices.contains(index + offset) else { return axes }
        var result = axes; result.swapAt(index, index + offset); return result
    }
    static func families(counts: [String: Int], selectedAxes: [String]) -> [String] {
        Array(Set(counts.keys).union(selectedAxes)).sorted {
            let lhs = counts[$0] ?? 0, rhs = counts[$1] ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
    }
}

struct AlertProfileChart06: View {
    let axes: [String]; let counts: [String: Int]; let denominator: Int
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        switch AlertProfile06.chartKind(axisCount: axes.count) {
        case .empty:
            Text("Aucun axe sélectionné. Choisissez des familles pour afficher leur fréquence.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .bars:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(axes, id: \.self) { family in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(family).font(.caption); Spacer(); Text("\(counts[family] ?? 0) / \(denominator)").font(.caption).monospacedDigit() }
                        GeometryReader { geometry in
                            let fraction = denominator > 0 ? min(1, max(0, Double(max(0, counts[family] ?? 0)) / Double(AlertProfile06.displayMaximum(counts: counts, denominator: denominator)))) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(palette.border)
                                Capsule().fill(palette.mint.opacity(0.8)).frame(width: geometry.size.width * fraction)
                            }
                        }.frame(height: 8)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .radar: ProfileRadar06(axes: axes, counts: counts, denominator: denominator)
        }
    }
}

private struct ProfileRadar06: View {
    let axes: [String]; let counts: [String: Int]; let denominator: Int
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(dark: scheme == .dark) }
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let layoutRadius: CGFloat = min(geometry.size.width / 3, geometry.size.height / 2.6)
            let radius: Double = Double(layoutRadius)
            let count = axes.count
            ZStack {
                ForEach(1...4, id: \.self) { ring in Path { path in for index in 0..<count { let p = point(index, count, center, radius * Double(ring) / 4); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.stroke(palette.border, lineWidth: 1) }
                Path { path in for (index, axis) in axes.enumerated() { let fraction = denominator > 0 ? min(1, Double(max(0, counts[axis] ?? 0)) / Double(AlertProfile06.displayMaximum(counts: counts, denominator: denominator))) : 0; let p = point(index, count, center, radius * fraction); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.fill(palette.mint.opacity(0.15)).overlay(Path { path in for (index, axis) in axes.enumerated() { let p = point(index, count, center, radius * (denominator > 0 ? min(1, Double(max(0, counts[axis] ?? 0)) / Double(AlertProfile06.displayMaximum(counts: counts, denominator: denominator))) : 0)); if index == 0 { path.move(to: p) } else { path.addLine(to: p) } }; path.closeSubpath() }.stroke(palette.mint, lineWidth: 1.5))
                ForEach(Array(axes.enumerated()), id: \.element) { index, axis in Text(axis).font(.system(size: 9)).foregroundStyle(palette.secondary).frame(width: 100).position(point(index, count, center, radius + 25)) }
            }
        }
    }
    private func point(_ index: Int, _ count: Int, _ center: CGPoint, _ radius: Double) -> CGPoint { let angle = Double(index) * .pi * 2 / Double(count) - .pi / 2; return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius) }
}
