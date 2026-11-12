import SwiftUI
import AVFoundation

/// Calendar and reminder alerts, new episodes, and the cats coming and going - the same pop-ups as Ember TV, from
/// lucapi. tvOS doesn't let an app put anything over other apps, so these show while Ember is open (including
/// over the player): calendar ones top right for 10 s, the cats as a small drop-down top left for 5 s.
@MainActor
final class Notices: ObservableObject {
    struct Alert { let id: String; let at: Date; let until: Date; let start: Date; let wake: Date?
                   let title: String; let place: String; let kind: String; let shift: Bool; let level: Int }

    @Published var top: (text: String, level: Int)? = nil
    @Published var cat: String? = nil
    @Published var glance: JSON = [:]
    /// the cat flap camera (the Ring's live view), while lucapi says to show it
    struct Cam: Equatable { let id: String; let title: String; let player: AVPlayer }
    @Published var cam: Cam? = nil
    private var camShownId = ""

    private var alerts: [Alert] = []
    private var alertsAt = Date.distantPast
    private var catsHome: [String: Bool] = [:]
    private var catsKnown = false
    private var queue: [(String, Int)] = []
    private var topUntil = Date.distantPast
    private var running = false

    private var shown: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "shownAlerts") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(300)), forKey: "shownAlerts") }
    }

    func start() {
        guard !running else { return }
        running = true
        Task {
            var n = 0
            while true {
                if n % 4 == 0 {   // every 20 s, as before
                    if Date().timeIntervalSince(alertsAt) > 300 { await fetchAlerts() }
                    showDue()
                    await pollCats()
                }
                await pollCam()   // every 5 s, so the camera comes up while the cat's still there
                n += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private func fetchAlerts() async {
        alertsAt = Date()
        guard let j = try? await API.feedGet("/alerts", timeout: 10) else { return }
        alerts = j.arr("alerts").compactMap { a in
            guard let id = a.str("id"), let at = Notices.date(a.str("at")), let until = Notices.date(a.str("until")),
                  let start = Notices.date(a.str("start")) else { return nil }
            return Alert(id: id, at: at, until: until, start: start, wake: Notices.date(a.str("wake")), title: a.str("title") ?? "",
                         place: a.str("where") ?? "", kind: a.str("kind") ?? "cal", shift: (a["shift"] as? Bool) ?? false,
                         level: a.int("level") ?? 1)
        }
    }

    private func showDue() {
        let now = Date()
        var seen = shown
        for a in alerts where a.at <= now && a.until > now && !seen.contains(a.id) {
            seen.insert(a.id)
            say(Notices.text(a, now), level: a.level)
        }
        shown = seen
    }

    private func pollCats() async {
        guard let j = try? await API.feedGet("/glance", timeout: 8) else { return }
        glance = j
        var msg: [String] = []
        for c in j.arr("cats") {
            guard let name = c.str("name"), let home = c["home"] as? Bool else { continue }
            let before = catsHome.updateValue(home, forKey: name)
            if catsKnown, let before, before != home { msg.append(home ? "\(name) came in" : "\(name) went out") }
        }
        catsKnown = true
        if !msg.isEmpty { showCat(msg.joined(separator: "  ·  ")) }
    }

    private func pollCam() async {
        guard let j = try? await API.feedGet("/cats", timeout: 4), let c = j["cam"] as? JSON,
              let id = c.str("id"), let url = c.str("url").flatMap(URL.init(string:)), id != camShownId else { return }
        camShownId = id
        let secs = max(10, c.int("secs") ?? 45)
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.automaticallyWaitsToMinimizeStalling = false
        p.play()
        let shown = Cam(id: id, title: c.str("title") ?? "Cat flap", player: p)
        Diag.log("camera: showing \(shown.title)")
        withAnimation(.easeOut(duration: 0.35)) { cam = shown }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            guard cam?.id == id else { return }
            withAnimation(.easeIn(duration: 0.35)) { cam = nil }
            p.pause()
            p.replaceCurrentItem(with: nil)
        }
    }

    /// A calendar-style note, top right, one at a time (urgent ones jump the queue).
    func say(_ text: String, level: Int) {
        if Date() < topUntil {
            if level >= 3 { queue.insert((text, level), at: 0) } else { queue.append((text, level)) }
            return
        }
        withAnimation(.easeOut(duration: 0.35)) { top = (text, level) }
        topUntil = Date().addingTimeInterval(10)
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            withAnimation(.easeIn(duration: 0.35)) { top = nil }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !queue.isEmpty { let n = queue.removeFirst(); topUntil = .distantPast; say(n.0, level: n.1) }
        }
    }

    func showCat(_ text: String) {
        withAnimation(.easeOut(duration: 0.35)) { cat = text }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.easeIn(duration: 0.35)) { if cat == text { cat = nil } }
        }
    }

    /// The words, worked out when shown, so the time left is right (as on Ember TV).
    static func text(_ a: Alert, _ now: Date) -> String {
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let at = hm.string(from: a.start)
        let place = a.place.isEmpty ? "" : "  ·  " + a.place
        if let w = a.wake { return "Early shift: \(a.title) at \(at)  ·  you need to be up at \(hm.string(from: w)), in \(span(w.timeIntervalSince(now)))" }
        let left = span(a.start.timeIntervalSince(now))
        if a.kind == "ep" { return a.title }
        if a.kind == "rem" { return a.level >= 3 ? "Reminder in \(left): \(a.title)!" : "Reminder in \(left): \(a.title) (\(at))" }
        let what = a.shift ? "Shift: \(a.title)" : a.title
        switch a.level {
        case 1: return "In \(left)  ·  \(what) at \(at)\(place)"
        case 2: return "In \(left): \(what) at \(at)\(place)"
        default: return "\(what) starts in \(left)!  \(at)\(place)"
        }
    }

    static func span(_ s: TimeInterval) -> String {
        let m = max(0, Int(s / 60))
        return m < 60 ? "\(m) min" : String(format: "%dh %02dm", m / 60, m % 60)
    }
}

/// The pop-ups themselves: calendar top right, the cats bottom left.
struct NoticeOverlay: View {
    @EnvironmentObject var notices: Notices
    var body: some View {
        ZStack {
            if let t = notices.top {
                HStack(spacing: 16) {
                    Image(systemName: t.level >= 3 ? "exclamationmark.circle.fill" : "calendar")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(t.level >= 3 ? Color(red: 1, green: 0.42, blue: 0.36) : t.level == 2 ? Theme.accent : .white.opacity(0.85))
                    Text(t.text).font(.ember(t.level >= 3 ? 28 : 25, .semibold)).lineLimit(2)
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .background(Theme.bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .stroke(t.level >= 3 ? Color(red: 1, green: 0.42, blue: 0.36) : t.level == 2 ? Theme.accent : .white.opacity(0.12), lineWidth: t.level >= 2 ? 2 : 1))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 50).padding(.trailing, 70)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let c = notices.cat {
                // the cats: a small drop-down, top left (calendar ones are top right), 5 seconds
                HStack(spacing: 10) {
                    Image(systemName: "pawprint.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                    Text(c).font(.ember(20, .semibold))
                }
                .padding(.horizontal, 20).padding(.vertical, 11)
                .background(Theme.bg.opacity(0.85), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.08)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 40).padding(.leading, 70)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let c = notices.cam {
                // the cat flap camera: bottom right, muted, about 45 s
                ZStack(alignment: .topLeading) {
                    Theme.bg
                    Text("Connecting to the camera…").font(.ember(18)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    CamLayer(player: c.player)
                    HStack(spacing: 8) {
                        Image(systemName: "pawprint.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
                        Text(c.title).font(.ember(18, .semibold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.bg.opacity(0.8), in: Capsule())
                    .padding(14)
                }
                .frame(width: 640, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.55), radius: 30, y: 10)
                .padding(.trailing, 70).padding(.bottom, 56)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// The camera's picture (AVPlayerLayer: no controls, nothing to focus).
struct CamLayer: UIViewRepresentable {
    let player: AVPlayer
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        v.pl.videoGravity = .resizeAspectFill
        v.pl.player = player
        return v
    }
    func updateUIView(_ v: V, context: Context) { v.pl.player = player }
}

/// Top right of Home, small, beside the tab bar: the cats on one line (green paw in, grey out), what's next below.
struct GlanceView: View {
    @EnvironmentObject var notices: Notices
    var body: some View {
        let cats = notices.glance.arr("cats")
        let next = notices.glance["next"] as? JSON
        if !cats.isEmpty || next != nil {
            VStack(alignment: .trailing, spacing: 4) {
                if !cats.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(cats.indices, id: \.self) { i in
                            let c = cats[i], home = (c["home"] as? Bool) ?? false
                            HStack(spacing: 5) {
                                Image(systemName: "pawprint.fill").font(.system(size: 13))
                                    .foregroundStyle(home ? Color(red: 0.5, green: 0.83, blue: 0.54) : Theme.muted)
                                Text(c.str("name") ?? "").font(.ember(16, .semibold))
                                    .foregroundStyle(home ? .white : Theme.muted)
                            }
                        }
                    }
                }
                if let n = next {
                    HStack(spacing: 6) {
                        Text(n.str("title") ?? "").font(.ember(15, .semibold)).lineLimit(1)
                            .foregroundStyle((n["shift"] as? Bool) == true ? Theme.accent : .white)
                        Text((n.str("day") == "Today" ? "" : (n.str("day") ?? "") + " ") + (n.str("time") ?? ""))
                            .font(.ember(15)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                    }
                }
            }
            .frame(maxWidth: 300, alignment: .trailing)
            .shadow(color: .black.opacity(0.6), radius: 8)
            .transition(.opacity)
        }
    }
}
