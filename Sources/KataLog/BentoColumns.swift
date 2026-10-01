import SwiftUI

/// Two cards with explicit wrapping widths. Long explanatory text must not force
/// a desktop layout into one column through its unconstrained ideal width.
struct BentoColumns: Layout {
    var firstMinimum: CGFloat = 320
    var secondMinimum: CGFloat = 320
    var secondWidth: CGFloat?
    var spacing: CGFloat = BentoTokens.spacing

    private func columns(for width: CGFloat) -> [CGFloat] {
        guard width >= firstMinimum + secondMinimum + spacing else { return [width] }
        let right = min(width - spacing - firstMinimum, max(secondMinimum, secondWidth ?? (width - spacing) / 2))
        return [width - spacing - right, right]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? (firstMinimum + secondMinimum + spacing)
        let width = proposed.isFinite ? max(0, proposed) : firstMinimum + secondMinimum + spacing
        let widths = columns(for: width)
        let heights = subviews.enumerated().map { index, subview in
            subview.sizeThatFits(.init(width: widths.count == 1 ? width : widths[index % 2], height: nil)).height
        }
        let height = widths.count == 1 ? heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing : heights.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columns(for: bounds.width)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let width = widths.count == 1 ? bounds.width : widths[index % 2]
            let size = subview.sizeThatFits(.init(width: width, height: nil))
            let x = widths.count == 1 || index == 0 ? bounds.minX : bounds.minX + widths[0] + spacing
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(width: width, height: size.height))
            if widths.count == 1 { y += size.height + spacing }
        }
    }
}
