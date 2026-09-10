import SwiftUI

/// A one-line trend of a value over time, no axes and no numbers — just the
/// shape of where a folder's size is heading. It inherits the foreground style
/// of wherever it is placed, so it stays quiet against the row.
struct Sparkline: View {
    let values: [Int64]

    var body: some View {
        GeometryReader { geometry in
            line(in: geometry.size)
                .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }

    private func line(in size: CGSize) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 0
        let span = max(highest - lowest, 1)
        let step = size.width / CGFloat(values.count - 1)

        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * step
            let fraction = CGFloat(value - lowest) / CGFloat(span)
            // Larger sizes sit higher, so the line climbs as a folder grows.
            let y = size.height - fraction * size.height
            let point = CGPoint(x: x, y: y)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}
