import Observation
import SwiftUI

// The pieces the window is built from, so the header, the list and the footer
// share one shape language: round icon buttons, cards with a soft edge and a
// lift on hover, and one switch that slides rather than snaps.

/// A round, borderless icon button for the header. A faint disc appears under
/// the pointer, so a row of bare symbols still reads as buttons.
struct RoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundIconBody(configuration: configuration)
    }

    private struct RoundIconBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(.quaternary.opacity(configuration.isPressed ? 0.9 : isHovered ? 0.6 : 0))
                )
                .contentShape(Circle())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// Rescan, with the scan's progress drawn as a ring around it and the arrow
/// turning while it runs: one control that both starts the scan and shows it.
struct ScanButton: View {
    let isScanning: Bool
    /// Probes finished out of probes started; nil when the scan has not said.
    let progress: Double?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                if isScanning {
                    Circle()
                        .stroke(.quaternary, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    Circle()
                        .trim(from: 0, to: progress ?? 0.25)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
                if isScanning && !reduceMotion {
                    TimelineView(.animation) { context in
                        let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(angle))
                    }
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: isScanning ? 10 : 13, weight: .medium))
                }
            }
        }
        .buttonStyle(RoundIconButtonStyle())
        .disabled(isScanning)
        .accessibilityLabel(isScanning ? L("Scanning") : L("Rescan"))
        .help(L("Rescan"))
    }
}

/// The two ways to read the list. A pill slides between them, so the change
/// of view is something seen happening rather than a swap.
struct ModeSwitch: View {
    @Binding var byProject: Bool
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            option(L("By category"), symbol: "square.grid.2x2.fill", value: false)
            option(L("By project"), symbol: "folder.fill", value: true)
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.45)))
        // The segmented picker it replaced was announced as one control with
        // a name; the two buttons keep that name as a group.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Group by"))
    }

    private func option(_ title: String, symbol: String, value: Bool) -> some View {
        let isOn = byProject == value
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { byProject = value }
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if isOn {
                        // Lighter than the track in both appearances: white
                        // in light, a lifted grey in dark.
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The card every group in the list sits on: a soft fill and an edge that
/// catches the light. Pointed at, it brightens and its category icon lifts.
///
/// The pointer state is a small observable object, read only by the card's
/// surface and its icon. The rows inside are not rebuilt when the pointer
/// crosses the card, which is what made the first version of the hover
/// expensive; and the lift is a brighter edge rather than a shadow over a
/// card that can be a thousand points tall.
@MainActor
@Observable
final class CardHover {
    private(set) var isRaised = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Every card that could still be lit. A card can slide out from under a
    /// still pointer while the list scrolls without the hover system ever
    /// reporting an exit, so scrolling clears them all.
    @ObservationIgnored private static var live = NSHashTable<CardHover>.weakObjects()
    /// While the list is moving, no card may light up: a card sliding under a
    /// still pointer would otherwise schedule a glow that outlives the scroll.
    @ObservationIgnored private static var scrolling = false

    init() {
        Self.live.add(self)
    }

    /// Waits for the pointer to settle: scrolling moves a new card under a
    /// still pointer, and each one would otherwise re-light and un-light.
    func update(_ inside: Bool) {
        guard inside, !Self.scrolling else {
            task?.cancel()
            task = nil
            if isRaised { isRaised = false }
            return
        }
        guard !isRaised, task == nil else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.isRaised = true
            self?.task = nil
        }
    }

    static func clearAll() {
        for card in live.allObjects {
            card.task?.cancel()
            card.task = nil
            card.isRaised = false
        }
    }

    static func setScrolling(_ value: Bool) {
        scrolling = value
        if value { clearAll() }
    }
}

/// The surface under a category card. It reads `isRaised` itself, so only
/// this view redraws when the pointer arrives; the rows above it do not.
private struct CardSurface: View {
    var hover: CardHover?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRaised: Bool { hover?.isRaised ?? false }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(.quaternary.opacity(isRaised ? 0.34 : 0.24))
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: isRaised
                        ? [.white.opacity(0.30), .white.opacity(0.10)]
                        : [.white.opacity(0.12), .white.opacity(0.03)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .overlay {
                // The glow: a wider, faint edge instead of a large shadow.
                if isRaised {
                    shape.strokeBorder(.white.opacity(0.10), lineWidth: 3)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isRaised)
    }
}

struct ListCard: ViewModifier {
    var hover: CardHover?

    func body(content: Content) -> some View {
        content.background { CardSurface(hover: hover) }
    }
}

/// A category card that owns its hover state. The content closure receives
/// the state and hands it to the icon; nothing in the row tree reads it, so
/// hovering never rebuilds the rows.
struct CategoryCard<Content: View>: View {
    @State private var hover = CardHover()
    @ViewBuilder var content: (_ hover: CardHover) -> Content

    var body: some View {
        content(hover)
            // `onContinuousHover` reports the end of a hover as well as its
            // start, including when the pointer leaves through a row.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hover.update(true)
                case .ended:
                    hover.update(false)
                }
            }
            .listCard(hover: hover)
    }
}

extension View {
    func listCard(hover: CardHover? = nil) -> some View {
        modifier(ListCard(hover: hover))
    }
}

/// Drops every card glow as soon as the list scrolls. A card whose frame
/// moves under a stationary pointer can otherwise stay lit after the pointer
/// is no longer over it.
struct ClearHoverOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 15.0, *) {
                content.onScrollPhaseChange { _, phase in
                    CardHover.setScrolling(phase.isScrolling)
                }
            } else {
                content
            }
        }
        .onDisappear { CardHover.setScrolling(false) }
    }
}
