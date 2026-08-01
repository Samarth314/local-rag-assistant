import SwiftUI

/// Lays subviews out left-to-right, wrapping onto a new line when the next one
/// would overflow the available width.
///
/// Used for the category filters. A horizontal `ScrollView` was the obvious
/// choice and the wrong one: filters that sit off-screen are filters the user
/// does not know exist, and a scroll view gives no hint that there are more.
/// Wrapping shows the whole set at once, which for a fixed handful of
/// categories is both simpler and more honest about what is available.
///
/// Heights within a row are aligned on their centres, so chips of different
/// heights (a longer label wrapping, say) do not sit ragged.
struct FlowLayout: Layout {
    var spacing: CGFloat = Ataru.Space.sm
    var lineSpacing: CGFloat = Ataru.Space.sm

    /// One line of subviews, plus the metrics needed to place it.
    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = wrap(subviews, maxWidth: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(lines.count - 1, 0))
        // When width is unconstrained (a sizing pass), report the widest line
        // rather than `.infinity`, which would make the container unbounded.
        let width = maxWidth.isFinite ? maxWidth : (lines.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in wrap(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func wrap(_ subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width

            if needed > maxWidth, !current.indices.isEmpty {
                lines.append(current)
                current = Line()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
