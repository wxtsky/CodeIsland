import SwiftUI

/// A text column whose rows use their natural heights at the available width.
/// Unlike VStack, it does not probe each rich row at zero and infinite height.
struct NaturalHeightColumn: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        }
        let rowProposal = ProposedViewSize(width: width, height: nil)
        let height = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(rowProposal).height }
        return CGSize(width: width, height: height + CGFloat(max(0, subviews.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for row in subviews {
            row.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: rowProposal)
            y += row.sizeThatFits(rowProposal).height + spacing
        }
    }
}
