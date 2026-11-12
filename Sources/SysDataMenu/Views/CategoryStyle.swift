import SwiftUI

/// Each category's symbol and colour, so a long folded list can be read by
/// shape and hue before any title is. The colours only identify a group;
/// how safe a deletion is stays with the green, orange and grey of the bars
/// and badges.
extension StorageCategory {
    var symbol: String {
        switch self {
        case .snapshots: "externaldrive.fill.badge.timemachine"
        case .simulators: "iphone.gen3"
        case .runtimes: "square.stack.3d.up.fill"
        case .xcode: "hammer.fill"
        case .packages: "shippingbox.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .ai: "brain"
        case .logs: "doc.text.magnifyingglass"
        case .temp: "clock.arrow.circlepath"
        case .docker: "cube.fill"
        case .vms: "desktopcomputer"
        case .trash: "trash.fill"
        case .backups: "iphone.and.arrow.forward"
        case .shared: "person.2.fill"
        case .android: "candybarphone"
        case .apps: "app.badge.fill"
        case .projects: "folder.fill.badge.gearshape"
        case .system: "gearshape.2.fill"
        case .other: "folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .snapshots: .teal
        case .simulators, .runtimes: .blue
        case .xcode: .indigo
        case .packages: .brown
        case .tools: .purple
        case .ai: .pink
        case .logs: .gray
        case .temp: .mint
        case .docker: .cyan
        case .vms: .blue
        case .trash: .gray
        case .backups: .pink
        case .shared: .orange
        case .android: .green
        case .apps: .red
        case .projects: .yellow
        case .system: .gray
        case .other: .gray
        }
    }
}

/// A symbol on a small tile with depth: lit from above, a sheen across the
/// top half, an edge that catches the light and a soft shadow in its own
/// colour, so icons read as objects rather than flat squares. Pointed at, it
/// lifts and tilts towards the pointer; under Reduce Motion it stays still.
/// Shared by the category list, the notices and the empty states, so every
/// icon in the window is made the same way.
struct DepthTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24
    /// Lifted, because whatever it heads is being pointed at.
    var isRaised = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.28), radius: 0.6, y: 0.8)
            .frame(width: size, height: size)
            .background {
                shape.fill(tint)
                // Lit from above: lighter at the top, deeper at the bottom.
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.30), .clear, .black.opacity(0.22)],
                    startPoint: .top, endPoint: .bottom
                ))
                // A sheen across the top half, the way glass and enamel catch light.
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.32), .white.opacity(0)],
                    startPoint: .top, endPoint: .center
                ))
                .padding(1)
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.55), .white.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 0.75)
            }
            .shadow(color: tint.opacity(0.45), radius: isRaised ? 5 : 2, y: isRaised ? 3 : 1.5)
            .rotation3DEffect(
                .degrees(isRaised && !reduceMotion ? 14 : 0),
                axis: (x: 1, y: -0.7, z: 0), perspective: 0.5
            )
            .scaleEffect(isRaised && !reduceMotion ? 1.08 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isRaised)
            .accessibilityHidden(true)
    }
}

/// The category's symbol, as a lit tile in the category's colour. Reads the
/// card's hover state here rather than being handed a `Bool`, so the card's
/// rows are not rebuilt when the pointer arrives.
struct CategoryIcon: View {
    let category: StorageCategory
    var hover: CardHover?
    var size: CGFloat = 24

    var body: some View {
        DepthTile(
            symbol: category.symbol, tint: category.tint, size: size,
            isRaised: hover?.isRaised ?? false
        )
    }
}
