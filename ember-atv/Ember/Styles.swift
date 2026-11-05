import SwiftUI

/// Ember's buttons: a slim pill (or a round icon), glass when resting, white when selected, with a small lift.
/// Quieter than tvOS's standard buttons.
struct EmberButtonStyle: ButtonStyle {
    var primary = false
    var round = false
    func makeBody(configuration: Configuration) -> some View {
        EmberButtonBody(label: configuration.label, pressed: configuration.isPressed, primary: primary, round: round)
    }
}

private struct EmberButtonBody<L: View>: View {
    let label: L
    let pressed: Bool
    let primary: Bool
    let round: Bool
    @Environment(\.isFocused) private var focused

    private var fill: Color { focused ? .white : primary ? Theme.accent : Color.white.opacity(0.13) }
    private var ink: Color { focused || primary ? Theme.ink : .white }

    var body: some View {
        label
            .font(.system(size: 22, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(ink)
            .padding(.horizontal, round ? 0 : 28)
            .frame(width: round ? 60 : nil, height: 60)
            .background { if round { Circle().fill(fill) } else { Capsule().fill(fill) } }
            .overlay { if !focused && !primary { (round ? AnyShape(Circle()) : AnyShape(Capsule())).stroke(.white.opacity(0.12), lineWidth: 1) } }
            .scaleEffect(pressed ? 0.95 : focused ? 1.08 : 1)
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// Season 1  Season 2 ...: text tabs, the chosen one white and underlined in Ember's orange.
struct TabTextStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { TabTextBody(label: configuration.label, selected: selected) }
}

private struct TabTextBody<L: View>: View {
    let label: L
    let selected: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        VStack(spacing: 8) {
            label
                .font(.system(size: 24, weight: selected ? .bold : .medium))
                .foregroundStyle(focused ? Theme.ink : selected ? .white : Theme.muted)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Capsule().fill(focused ? .white : .clear))
            Capsule().fill(selected ? Theme.accent : .clear).frame(width: 36, height: 4)
        }
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}
