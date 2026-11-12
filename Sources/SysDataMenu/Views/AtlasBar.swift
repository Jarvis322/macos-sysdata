import SwiftUI

/// The bar under a category header: how big the category is next to the
/// largest one, split by how much thought deleting it needs.
///
/// Read down the folded list, the bars are a map of the disk — which group is
/// big, and how much of it is safe to take. The colours are the badges' own,
/// so green means Safe here exactly as it does on a row.
///
/// Drawn in one `Canvas`. As six stacked shapes it was six layer-backed views
/// per category, and a folded list is mostly these cards.
struct AtlasBar: View {
    let safe: Int64
    let review: Int64
    let manual: Int64
    /// The largest category's total; this bar's length is its share of that.
    let scale: Int64

    var body: some View {
        Canvas { context, size in
            let total = safe + review + manual
            let length = size.width * CGFloat(total) / CGFloat(max(scale, 1))
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(.secondary.opacity(0.14)))
            guard total > 0, length > 0 else { return }

            context.drawLayer { layer in
                layer.clip(to: track)
                var x: CGFloat = 0
                for (bytes, color) in [(safe, Color.green), (review, Color.orange), (manual, Color.secondary)] {
                    let width = length * CGFloat(bytes) / CGFloat(total)
                    guard width > 0 else { continue }
                    let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                    layer.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(colors: [color.opacity(0.92), color]),
                            startPoint: CGPoint(x: rect.midX, y: 0),
                            endPoint: CGPoint(x: rect.midX, y: size.height)
                        )
                    )
                    x += width
                }
                // A highlight along the top edge, so the bar has the same
                // light from above as the icons.
                let highlight = Path(roundedRect: CGRect(x: 0, y: 0.5, width: length, height: 1.5), cornerRadius: 0.75)
                layer.fill(highlight, with: .color(.white.opacity(0.22)))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(L("%@ safe · %@ to review · %@ manual",
                              safe.byteString, review.byteString, manual.byteString))
    }
}
