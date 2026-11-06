import SwiftUI

/// Full screen while a stream is found and tested, as on Ember PC: logo, the steps, what it's about to play.
struct LoadingView: View {
    let state: LoadState
    @State private var pulse = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Backdrop(url: state.art).blur(radius: 60).opacity(0.55).ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 30) {
                AsyncImage(url: state.logo) { ph in
                    if let img = ph.image { img.resizable().scaledToFit().frame(maxWidth: 620, maxHeight: 200) }
                    else { Text(state.title).font(.ember(64, .bold)) }
                }
                .frame(maxHeight: 200)
                if !state.sub.isEmpty { Text(state.sub).font(.ember(24, .medium)).foregroundStyle(Theme.accent) }
                Flame().frame(width: 70, height: 90).scaleEffect(pulse ? 1.06 : 0.94)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(state.steps.indices, id: \.self) { i in
                        HStack(spacing: 16) {
                            Circle()
                                .strokeBorder(Theme.accent, lineWidth: 3)
                                .background(Circle().fill(i < state.step ? Theme.accent : .clear))
                                .frame(width: 22, height: 22)
                            Text(state.steps[i]).font(.ember(24, i == state.step ? .semibold : .regular))
                                .foregroundStyle(i <= state.step ? .white : .white.opacity(0.5))
                            if i == state.step && i == state.steps.count - 1 {
                                ForEach(state.badges, id: \.self) { b in
                                    Text(b).font(.ember(19, .bold)).padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(Theme.ink)
                                }
                            }
                        }
                    }
                }
                if !state.note.isEmpty {
                    Text(state.note).font(.ember(20)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(maxWidth: 1100)
                }
            }
        }
        .onAppear { pulse = true }
    }
}

/// Ember's flame.
struct Flame: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.97, y: h * 0.52))
                    p.addQuadCurve(to: CGPoint(x: w / 2, y: h), control: CGPoint(x: w * 1.02, y: h * 0.98))
                    p.addQuadCurve(to: CGPoint(x: w * 0.03, y: h * 0.52), control: CGPoint(x: -w * 0.02, y: h * 0.98))
                    p.closeSubpath()
                }
                .fill(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.8), radius: 24)
                Ellipse().fill(Color(red: 1, green: 0.88, blue: 0.7))
                    .frame(width: w * 0.5, height: h * 0.3)
                    .position(x: w / 2, y: h * 0.76)
            }
        }
    }
}
