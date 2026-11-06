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
                    if mode == .day { ctx.addFilter(.blur(radius: 1.4)) }   // the dust glows softly, no hard edges
                    for p in parts {
                        if mode == .day {
                            // motes of dust drifting slowly down through the light at the top right
                            let life = (t * (0.012 + p.s * 0.014) + p.p).truncatingRemainder(dividingBy: 1)
                            let x = (0.55 + p.x * 0.45) * W + sin(t * 0.3 + p.p) * 20 - life * W * 0.08
                            let y = (p.y * 0.25 + life * 0.6) * H
                            let d = 2 + p.r * 2.8, a = sin(life * .pi) * 0.6
                            // softened, so each mote glows a little with no hard edge
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                                     with: .color(Color(red: 1, green: 0.93, blue: 0.78).opacity(a)))
                        } else if mode == .night {
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
                    let n = now == .night ? 90 : now == .evening ? 34 : 36
                    parts = (0..<n).map { _ in Particle(x: .random(in: 0...1), y: .random(in: 0...1), r: .random(in: 0...1), s: .random(in: 0...1), p: .random(in: 0...6.28)) }
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// A soft glow: the light falls away on an eased curve through many steps, so there are no visible rings,
    /// with a faint grain over it to break up the banding a dark TV picture shows.
    private func soft(_ r: Double, _ g: Double, _ b: Double, _ a: Double, at c: UnitPoint, radius: CGFloat) -> RadialGradient {
        let stops = (0...16).map { k -> Gradient.Stop in
            let t = Double(k) / 16
            return .init(color: Color(red: r, green: g, blue: b).opacity(a * pow(1 - t, 2.2) * (1 - t * 0.15)), location: t)
        }
        return RadialGradient(gradient: Gradient(stops: stops), center: c, startRadius: 0, endRadius: radius)
    }

    @ViewBuilder private var glow: some View {
        ZStack {
            switch mode {
            case .day:
                LinearGradient(colors: [Color(red: 0.11, green: 0.08, blue: 0.055), Color(red: 0.07, green: 0.05, blue: 0.04), Theme.bg],
                               startPoint: .top, endPoint: .bottom)
                soft(1, 0.81, 0.55, 0.30, at: UnitPoint(x: 0.92, y: -0.12), radius: 1500)
                soft(1, 0.9, 0.75, 0.14, at: UnitPoint(x: 1, y: 0), radius: 900)
            case .evening:
                soft(0.94, 0.47, 0.16, 0.24, at: UnitPoint(x: 0, y: 1.08), radius: 1200)
                soft(1, 0.67, 0.31, 0.12, at: UnitPoint(x: 0.06, y: 1), radius: 700)
            case .night:
                soft(0.35, 0.41, 0.67, 0.15, at: UnitPoint(x: 0.86, y: -0.12), radius: 1200)
            }
            Image(uiImage: Grain.image).resizable(resizingMode: .tile).opacity(0.05).blendMode(.overlay)
        }
    }
}

/// A tile of fine random grain (made once).
enum Grain {
    static let image: UIImage = {
        let n = 160
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            let v = UInt8.random(in: 0...255)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return UIImage() }
        return UIImage(cgImage: cg)
    }()
}
