import SwiftUI

/// Ember's sky, behind the pages (as on Ember PC): warm sunlight by day, rising embers in the evening,
/// twinkling stars at night, timed to today's sunrise and sunset from lucapi.
struct AmbientBackground: View {
    enum Mode { case day, evening, night }
    struct Particle { let x, y, r, s, p: Double }

    @State private var mode: Mode = .night
    @State private var parts: [Particle] = []

    var body: some View {
        ZStack {
            Theme.bg
            glow
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let W = size.width, H = size.height
                    for p in parts {
                        if mode == .night {
                            let a = 0.25 + 0.55 * (0.5 + 0.5 * sin(t * (0.4 + p.s) + p.p))
                            let d = 1.6 + p.r * 2.2
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x * W, y: p.y * H * 0.7, width: d, height: d)),
                                     with: .color(Color(red: 0.91, green: 0.93, blue: 1).opacity(a * 0.8)))
                        } else {
                            // embers drifting up from the bottom left, swaying, fading as they rise
                            let life = (t * (0.025 + p.s * 0.035) + p.p).truncatingRemainder(dividingBy: 1)
                            let x = p.x * 0.45 * W + sin(t * 0.6 + p.p * 6.28) * 24 + life * W * 0.16
                            let y = H - life * H * 0.9
                            let d = 2.4 + p.r * 4
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                                     with: .color(Color(red: 1, green: (150 + p.r * 60) / 255, blue: 70 / 255).opacity((1 - life) * 0.6)))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task {
            var rise = 7 * 60, set = 17 * 60
            if let w = try? await API.feedGet("/weather", timeout: 6) {
                func hm(_ s: String?) -> Int? {
                    let p = (s ?? "").split(separator: ":").compactMap { Int($0) }
                    return p.count >= 2 ? p[0] * 60 + p[1] : nil
                }
                rise = hm(w.str("sunrise")) ?? rise
                set = hm(w.str("sunset")) ?? set
            }
            while !Task.isCancelled {
                let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
                let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                let now: Mode = m < rise + 20 || m > set + 45 ? .night : m > set - 75 ? .evening : .day
                if now != mode || parts.isEmpty {
                    mode = now
                    let n = now == .night ? 90 : now == .evening ? 34 : 16
                    parts = (0..<n).map { _ in Particle(x: .random(in: 0...1), y: .random(in: 0...1), r: .random(in: 0...1), s: .random(in: 0...1), p: .random(in: 0...6.28)) }
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    @ViewBuilder private var glow: some View {
        switch mode {
        case .day:
            ZStack {
                LinearGradient(colors: [Color(red: 0.09, green: 0.067, blue: 0.05), Theme.bg], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 1, green: 0.84, blue: 0.59).opacity(0.16), .clear], center: UnitPoint(x: 0.88, y: -0.1), startRadius: 0, endRadius: 1300)
            }
        case .evening:
            ZStack {
                RadialGradient(colors: [Color(red: 0.94, green: 0.47, blue: 0.16).opacity(0.22), .clear], center: UnitPoint(x: 0, y: 1.1), startRadius: 0, endRadius: 1100)
                RadialGradient(colors: [Color(red: 1, green: 0.67, blue: 0.31).opacity(0.10), .clear], center: UnitPoint(x: 0.06, y: 1), startRadius: 0, endRadius: 700)
            }
        case .night:
            RadialGradient(colors: [Color(red: 0.35, green: 0.41, blue: 0.67).opacity(0.14), .clear], center: UnitPoint(x: 0.85, y: -0.1), startRadius: 0, endRadius: 1100)
        }
    }
}
