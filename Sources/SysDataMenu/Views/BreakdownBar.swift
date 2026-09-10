import SwiftUI

/// A single thin bar showing how the measured total splits across categories —
/// the shape of "what is it, mostly" in one glance, before the list spells it
/// out. Deliberately restrained: one line, no labels, colour only, so it
/// informs the list rather than competing with it.
struct BreakdownBar: View {
    /// Categories with their totals, largest first. Zero-sized ones are left
    /// out by the caller.
    let segments: [(category: StorageCategory, bytes: Int64)]

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.bytes }, 1)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments, id: \.category) { segment in
                    Self.color(for: segment.category)
                        .frame(width: geometry.size.width * CGFloat(segment.bytes) / CGFloat(total))
                        .help("\(segment.category.title) — \(segment.bytes.byteString)")
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(L("Breakdown by category"))
    }

    /// A stable colour per category, from a small palette indexed by the
    /// category's fixed order, so the same group is the same colour every run
    /// and the palette works in light and dark.
    static func color(for category: StorageCategory) -> Color {
        let palette: [Color] = [
            .blue, .teal, .green, .orange, .pink, .purple,
            .indigo, .mint, .cyan, .yellow, .red, .brown,
        ]
        let index = StorageCategory.allCases.firstIndex(of: category) ?? 0
        return palette[index % palette.count]
    }
}
