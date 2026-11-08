import SwiftUI
import AVFoundation

/// What to watch: the shuffle (a reel of posters that whizzes past and lands on one), or swiping together on phones.
/// One page, with the switch at the top staying put, so the remote never loses its place (it used to jump to Home).
struct WhatToWatchView: View {
    @State private var swipe = false
    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollViewReader { sv in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .center, spacing: 36) {
                            Text("What shall we watch?").font(.ember(52, .bold))
                            WTWModes(swipe: swipe) { s in withAnimation(.easeInOut(duration: 0.25)) { swipe = s } }
                        }
                        .id("top")
                        if swipe { MatchBody() } else { ShuffleBody(scroll: sv) }
                    }
                    .padding(.horizontal, 90).padding(.top, 40).padding(.bottom, 80)
                }
                .scrollClipDisabled()
            }
          }
          .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
        }
    }
}

/// Shuffle  |  Swipe together
struct WTWModes: View {
    let swipe: Bool
    let pick: (Bool) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button { pick(false) } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(ChipStyle(on: !swipe))
            Button { pick(true) } label: { Label("Swipe together", systemImage: "iphone") }
                .buttonStyle(ChipStyle(on: swipe))
        }
        .padding(6)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

/// A filter chip: orange when chosen, white when selected by the remote.
struct ChipStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View { ChipBody(label: configuration.label, on: on, pressed: configuration.isPressed) }
}

private struct ChipBody<L: View>: View {
    let label: L
    let on: Bool
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        label
            .font(.ember(20, on ? .bold : .medium))
            .foregroundStyle(focused || on ? Theme.ink : .white.opacity(0.9))
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(Capsule().fill(focused ? Color.white : on ? Theme.accent : Color.white.opacity(0.08)))
            .scaleEffect(pressed ? 0.95 : focused ? 1.07 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 10, y: 5)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// One of the four filter selectors: a soft card, orange-edged while open, white when the remote is on it.
struct SelectorStyle: ButtonStyle {
    let open: Bool
    func makeBody(configuration: Configuration) -> some View { SelectorBody(label: configuration.label, open: open, pressed: configuration.isPressed) }
}

private struct SelectorBody<L: View>: View {
    let label: L
    let open: Bool
    let pressed: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        label
            .foregroundStyle(focused ? Theme.ink : .white)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.white : open ? Theme.accent.opacity(0.16) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(open && !focused ? Theme.accent.opacity(0.6) : .white.opacity(0.08), lineWidth: open ? 2 : 1))
            .scaleEffect(pressed ? 0.97 : focused ? 1.04 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - sounds

/// Little sounds, made on the spot: the reel ticking past (slowing with it), a chime when it lands, a ding for a match.
@MainActor
final class Sfx {
    static let shared = Sfx()
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var next = 0
    private let rate = 44100.0
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    var on: Bool { UserDefaults.standard.object(forKey: "sfx") as? Bool ?? true }

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        for _ in 0..<4 {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            nodes.append(n)
        }
    }

    private func buffer(_ seconds: Double) -> AVAudioPCMBuffer? {
        let n = AVAudioFrameCount(seconds * rate)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return nil }
        b.frameLength = n
        if let p = b.floatChannelData?[0] { for i in 0..<Int(n) { p[i] = 0 } }
        return b
    }

    private func add(_ b: AVAudioPCMBuffer, at start: Double, length: Double, _ f: (Double) -> Double) {
        guard let p = b.floatChannelData?[0] else { return }
        let s = Int(start * rate), e = min(Int(b.frameLength), s + Int(length * rate))
        guard s < e else { return }
        for i in s..<e { p[i] += Float(f(Double(i - s) / rate)) }
    }

    private func bell(_ b: AVAudioPCMBuffer, at start: Double, freq: Double, vol: Double) {
        add(b, at: start, length: 1.4) { t in
            let env = min(1, t / 0.006) * exp(-t / 0.42)
            return vol * env * (sin(2 * .pi * freq * t) + 0.35 * sin(2 * .pi * freq * 2.01 * t) * exp(-t / 0.2)
                                + 0.12 * sin(2 * .pi * freq * 3.02 * t) * exp(-t / 0.1))
        }
    }

    private func play(_ b: AVAudioPCMBuffer?) {
        guard on, let b else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let n = nodes[next]
        next = (next + 1) % nodes.count
        n.stop()
        n.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        n.play()
    }

    /// Clicks at these times (seconds from now).
    func ticks(_ times: [Double]) {
        guard on, let b = buffer((times.last ?? 0) + 0.12) else { return }
        for (i, t) in times.enumerated() {
            let f = 2100.0 - Double(min(i, 30)) * 22
            add(b, at: t, length: 0.05) { x in 0.16 * min(1, x / 0.002) * exp(-x / 0.011) * sin(2 * .pi * f * x) }
        }
        play(b)
    }

    func land() {
        guard on, let b = buffer(1.6) else { return }
        bell(b, at: 0, freq: 784, vol: 0.16)
        bell(b, at: 0.11, freq: 1175, vol: 0.13)
        play(b)
    }

    func ding() {
        guard on, let b = buffer(1.7) else { return }
        bell(b, at: 0, freq: 1047, vol: 0.2)
        bell(b, at: 0.16, freq: 1568, vol: 0.15)
        play(b)
    }

    /// When each poster passes the middle, on the reel's ease-out curve (so the ticks slow down with it).
    static func reelTicks(_ n: Int, _ dur: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [Double] {
        func bz(_ u: Double, _ a: Double, _ b: Double) -> Double { 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u }
        var out: [Double] = []
        var j = 1, last = -1.0, u = 0.0
        while u <= 1 && j <= n {
            while j <= n && bz(u, y1, y2) >= (Double(j) - 0.5) / Double(n) {
                let t = bz(u, x1, x2) * dur
                if t - last > 0.045 { out.append(t); last = t }
                j += 1
            }
            u += 0.0005
        }
        return out
    }
}

// MARK: - the shuffle

struct ShuffleBody: View {
    @EnvironmentObject var store: Store
    let scroll: ScrollViewProxy

    @AppStorage("shufType") private var type = "both"
    @AppStorage("shufVibe") private var vibe = ""
    @AppStorage("shufGenres") private var genres = ""
    @AppStorage("shufDecade") private var decade = ""
    @AppStorage("sfx") private var sound = true

    @State private var pile: [Meta] = []
    @State private var used = 0
    @State private var reel: [Meta] = []
    @State private var at = 0
    @State private var offset: CGFloat = 0
    @State private var spinning = false
    @State private var landed = false
    @State private var pick: Meta?
    @State private var note = ""
    @State private var stageW: CGFloat = 1740
    @FocusState private var focusWatch: Bool

    private let W: CGFloat = 230, H: CGFloat = 345, GAP: CGFloat = 28, STAGE: CGFloat = 480
    private let dur = 3.6

    static let types = [("both", "Films & series"), ("movie", "Films"), ("series", "Series")]
    static let vibes = [("", "Any vibe"), ("feelgood", "Feel-good"), ("laugh", "Make me laugh"), ("easy", "Easy watching"), ("cosy", "Cosy"),
                        ("romantic", "Romantic"), ("family", "Family night"), ("edge", "Edge of your seat"), ("adrenaline", "Adrenaline"),
                        ("scary", "Scare me"), ("dark", "Dark"), ("mindbending", "Mind-bending"), ("thoughtful", "Thought-provoking"),
                        ("weird", "Weird & wonderful"), ("epic", "Epic"), ("inspiring", "Inspiring"), ("tearjerker", "Tearjerker"),
                        ("nostalgic", "Nostalgic"), ("quick", "Short & sweet")]
    static let genreList = [("", "Any genre"), ("action", "Action"), ("comedy", "Comedy"), ("drama", "Drama"), ("scifi", "Sci-Fi"),
                            ("thriller", "Thriller"), ("horror", "Horror"), ("crime", "Crime"), ("romance", "Romance"),
                            ("animation", "Animation"), ("documentary", "Documentary"), ("fantasy", "Fantasy"), ("mystery", "Mystery")]
    static let decades = [("", "Any time"), ("2020", "2020s"), ("2010", "2010s"), ("2000", "2000s"), ("1990", "90s"),
                          ("1980", "80s"), ("older", "Older")]

    private var genreSet: [String] { genres.split(separator: ",").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // four tidy selectors showing what's chosen; pick one and its options open underneath
            HStack(spacing: 24) {
                selector("watch", "WATCH", name(Self.types, type))
                selector("vibe", "VIBE", name(Self.vibes, vibe))
                selector("genre", "GENRE", genres.isEmpty ? "Any genre" : genreSet.map { g in name(Self.genreList, g) }.joined(separator: ", "))
                selector("era", "ERA", name(Self.decades, decade))
            }
            if let o = open {
                Group {
                    switch o {
                    case "watch": chipRow(Self.types, selected: { $0 == type }) { k in type = k; fresh(); close() }
                    case "vibe": chipRow(Self.vibes, selected: { $0 == vibe }) { k in vibe = k; fresh(); close() }
                    case "genre": chipRow(Self.genreList, selected: { k in k.isEmpty ? genres.isEmpty : genreSet.contains(k) }, done: true) { k in toggleGenre(k) }
                    default: chipRow(Self.decades, selected: { $0 == decade }) { k in decade = k; fresh(); close() }
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22))
                .transition(.opacity.combined(with: .offset(y: -10)))
            }

            stage.id("stage")

            HStack(spacing: 22) {
                Spacer()
                Button { Task { await spin() } } label: {
                    Label(pick == nil ? "Shuffle" : "Shuffle again", systemImage: "shuffle").frame(minWidth: 260)
                }
                .buttonStyle(EmberButtonStyle(primary: true))
                .disabled(spinning)
                Button { sound.toggle() } label: { Label("Sound", systemImage: sound ? "speaker.wave.2.fill" : "speaker.slash.fill") }
                    .buttonStyle(ChipStyle(on: false))
                Spacer()
            }
            if !note.isEmpty {
                Text(note).font(.ember(21)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: filters

    @State private var open: String?
    @FocusState private var focusSel: String?

    private func name(_ list: [(String, String)], _ k: String) -> String { list.first { $0.0 == k }?.1 ?? list[0].1 }

    private func close() {
        let o = open
        withAnimation(.easeOut(duration: 0.2)) { open = nil }
        focusSel = o
    }

    private func selector(_ id: String, _ label: String, _ value: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { open = open == id ? nil : id }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.ember(15, .bold)).tracking(2).opacity(0.65)
                    Text(value).font(.ember(23, .semibold)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: open == id ? "chevron.up" : "chevron.down").font(.system(size: 18, weight: .semibold)).opacity(0.6)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SelectorStyle(open: open == id))
        .focused($focusSel, equals: id)
    }

    private func chipRow(_ list: [(String, String)], selected: @escaping (String) -> Bool, done: Bool = false,
                         tap: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(list.indices, id: \.self) { i in
                    Button { tap(list[i].0) } label: { Text(list[i].1) }
                        .buttonStyle(ChipStyle(on: selected(list[i].0)))
                }
                if done {
                    Button { close() } label: { Label("Done", systemImage: "checkmark") }.buttonStyle(ChipStyle(on: false))
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
        }
        .scrollClipDisabled()
    }

    private func toggleGenre(_ k: String) {
        if k.isEmpty { genres = "" } else {
            var set = genreSet
            if let i = set.firstIndex(of: k) { set.remove(at: i) } else { set.append(k) }
            genres = set.joined(separator: ",")
        }
        fresh()
    }

    /// New filters: a new pile next shuffle.
    private func fresh() { pile = []; used = 0 }

    // MARK: the stage: a fanned deck to start, then the reel, then the pick front and centre with its details beside it

    private var stage: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if let p = pick {
                    RemoteImage(url: p.backdropURL) { Color.clear }
                        .frame(width: g.size.width, height: STAGE).clipped()
                        .overlay(LinearGradient(stops: [.init(color: Theme.bg.opacity(0.5), location: 0), .init(color: Theme.bg.opacity(0.35), location: 0.4),
                                                        .init(color: Theme.bg.opacity(0.92), location: 0.62), .init(color: Theme.bg.opacity(0.97), location: 1)],
                                                startPoint: .leading, endPoint: .trailing))
                        .opacity(landed ? 0.6 : 0)
                }
                if reel.isEmpty {
                    deck.frame(width: g.size.width, height: STAGE)
                } else {
                    HStack(spacing: GAP) {
                        ForEach(reel.indices, id: \.self) { i in
                            let won = landed && i == at
                            RemoteImage(url: reel[i].posterURL) { Theme.card }
                                .frame(width: W, height: H)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.accent, lineWidth: won ? 4 : 0))
                                .shadow(color: won ? Theme.accent.opacity(0.55) : .black.opacity(0.45), radius: won ? 36 : 12, y: 10)
                                .scaleEffect(won ? 1.24 : 1)
                                .opacity(landed && !won ? 0 : 1)
                                .brightness(spinning ? -0.1 : 0)
                                .zIndex(won ? 1 : 0)
                        }
                    }
                    .fixedSize()
                    .offset(x: offset)
                    .frame(width: g.size.width, height: STAGE, alignment: .leading)
                }
                if landed, let p = pick {
                    info(p)
                        .frame(width: max(300, g.size.width / 2 - W * 0.62 - 90), alignment: .leading)
                        .offset(x: g.size.width / 2 + W * 0.62 + 50)
                        .transition(.opacity.combined(with: .offset(x: 30)))
                }
            }
            .onAppear { stageW = g.size.width }
            .onChange(of: g.size.width) { _, w in stageW = w }
        }
        .frame(height: STAGE)
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 30))
    }

    private var deck: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.15, blue: 0.08), Color(red: 0.11, green: 0.08, blue: 0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.accent.opacity(0.35)))
                    .overlay(Text("?").font(.system(size: 80, weight: .heavy)).foregroundStyle(Theme.accent.opacity(0.55)))
                    .frame(width: W, height: H)
                    .rotationEffect(.degrees([-9, 8, 0][i]))
                    .offset(x: [-40, 40, 0][i])
                    .opacity([0.6, 0.75, 1][i])
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            }
        }
    }

    private func spin() async {
        guard !spinning else { return }
        open = nil
        spinning = true
        note = ""
        withAnimation(.easeOut(duration: 0.25)) { landed = false }
        if used >= pile.count {
            note = "Shuffling the deck…"
            await load()
        }
        guard used < pile.count else { spinning = false; return }
        if note == "Shuffling the deck…" { note = "" }
        let p = pile[used]
        used += 1
        let others = pile.filter { $0.id != p.id }.shuffled()
        var run: [Meta] = []
        for i in 0..<34 { run.append(others.isEmpty ? p : others[i % others.count]) }
        let landAt = run.count
        run.append(p)
        run.append(contentsOf: others.prefix(5))
        let step = W + GAP
        let mid = stageW / 2 - W / 2
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { reel = run; at = landAt; pick = p; offset = mid - 2 * step }
        withAnimation(.easeInOut(duration: 0.5)) { scroll.scrollTo("stage", anchor: .center) }
        try? await Task.sleep(nanoseconds: 80_000_000)
        Sfx.shared.ticks(Sfx.reelTicks(landAt - 2, dur, 0.12, 0.72, 0.14, 1))
        withAnimation(.timingCurve(0.12, 0.72, 0.14, 1, duration: dur)) { offset = mid - CGFloat(landAt) * step }
        try? await Task.sleep(nanoseconds: UInt64((dur + 0.05) * 1_000_000_000))
        Sfx.shared.land()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { landed = true }
        spinning = false
        try? await Task.sleep(nanoseconds: 300_000_000)
        focusWatch = true
    }

    private func load() async {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "genres", value: genres),
                        URLQueryItem(name: "vibe", value: vibe), URLQueryItem(name: "decade", value: decade)]
        let q = c.percentEncodedQuery ?? ""
        do {
            let j = try await API.feedGet("/shuffle?" + q, timeout: 45)
            let got = j.arr("metas").map { Meta($0, type: $0.str("type") ?? "movie") }.filter { $0.poster != nil }
            pile = got
            used = 0
            if got.isEmpty { note = "Nothing matches all of those. Try fewer filters." }
            let urls = got.prefix(36).compactMap(\.posterURL)
            Task.detached {
                await withTaskGroup(of: Void.self) { g in
                    for u in urls { g.addTask { _ = await ImageStore.shared.load(u) } }
                }
            }
        } catch {
            pile = []
            used = 0
            note = "Couldn't reach lucapi: \(error.localizedDescription)"
        }
    }

    // MARK: the pick

    private func metaLine(_ p: Meta) -> String {
        var bits = [p.type == "series" ? "Series" : "Film"]
        if !p.releaseInfo.isEmpty { bits.append(p.releaseInfo) }
        if let r = p.rating, !r.isEmpty { bits.append("★ " + r) }
        return bits.joined(separator: "  ·  ")
    }

    private func info(_ p: Meta) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TitleArt(meta: p, height: 110, width: 520, nameSize: 46)
            Text(metaLine(p)).font(.ember(22)).foregroundStyle(.white.opacity(0.85))
            Text(p.description).font(.ember(21)).foregroundStyle(Theme.muted).lineLimit(4)
            HStack(spacing: 20) {
                Button { store.playBest(p) } label: { Label("Watch", systemImage: "play.fill") }
                    .buttonStyle(EmberButtonStyle(primary: true))
                    .focused($focusWatch)
                NavigationLink(value: p) { Label("Details", systemImage: "info.circle") }
                    .buttonStyle(EmberButtonStyle())
            }
            .padding(.top, 6)
        }
    }
}
