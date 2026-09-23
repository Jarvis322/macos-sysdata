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
        case .other: .secondary
        }
    }
}

/// The category's symbol on a small rounded tile, the way System Settings
/// marks its panes.
struct CategoryIcon: View {
    let category: StorageCategory

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}
