import SwiftUI

/// A one-line trend of a value over time, no axes and no numbers — just the
/// shape of where a folder's size is heading. It inherits the foreground style
/// of wherever it is placed, so it stays quiet against the row.
///
/// The size is fixed: the row always gives it 46×12, and a `GeometryReader`
/// per row was a second layout pass for a size that never changes.
struct Sparkline: View {
    let values: [Int64]

    private static let size = CGSize(width: 46, height: 12)

    var body: some View {
        line
            .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .frame(width: Self.size.width, height: Self.size.height)
    }

    private var line: Path {
        Path { path in
            guard values.count >= 2 else { return }
            let lowest = values.min() ?? 0
            let highest = values.max() ?? 0
            let span = max(highest - lowest, 1)
            let step = Self.size.width / CGFloat(values.count - 1)

            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                let fraction = CGFloat(value - lowest) / CGFloat(span)
                // Larger sizes sit higher, so the line climbs as a folder grows.
                let y = Self.size.height - fraction * Self.size.height
                let point = CGPoint(x: x, y: y)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }
}
