import SwiftUI

/// The bar under a category header: how big the category is next to the
/// largest one, split by how much thought deleting it needs.
///
/// Read down the folded list, the bars are a map of the disk — which group is
/// big, and how much of it is safe to take. The colours are the badges' own,
/// so green means Safe here exactly as it does on a row. A single split bar
/// rather than a striped texture, because a texture is unreadable at 4 points.
struct AtlasBar: View {
    let safe: Int64
    let review: Int64
    let manual: Int64
    /// The largest category's total; this bar's length is its share of that.
    let scale: Int64

    var body: some View {
        GeometryReader { geometry in
            let total = safe + review + manual
            let length = geometry.size.width * CGFloat(total) / CGFloat(max(scale, 1))
            HStack(spacing: 0) {
                segment(safe, of: total, length: length, color: .green)
                segment(review, of: total, length: length, color: .orange)
                segment(manual, of: total, length: length, color: .secondary)
            }
            .frame(width: length, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(L("%@ safe · %@ to review · %@ manual",
                              safe.byteString, review.byteString, manual.byteString))
    }

    private func segment(_ bytes: Int64, of total: Int64, length: CGFloat, color: Color) -> some View {
        color.frame(width: total > 0 ? length * CGFloat(bytes) / CGFloat(total) : 0)
    }
}
