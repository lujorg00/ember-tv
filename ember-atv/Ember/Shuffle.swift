import SwiftUI

/// What to watch: the shuffle (a reel of posters that whizzes past and lands on one), or swiping together on phones.
struct WhatToWatchView: View {
    @State private var swipe = false
    var body: some View {
        if swipe { MatchView(toShuffle: { swipe = false }) } else { ShuffleView(toSwipe: { swipe = true }) }
    }
}

/// Shuffle  |  Swipe together
struct WTWModes: View {
    let swipe: Bool
    let other: () -> Void
    var body: some View {
        HStack(spacing: 18) {
            Button { if swipe { other() } } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(TabTextStyle(selected: !swipe))
            Button { if !swipe { other() } } label: { Label("Swipe together", systemImage: "iphone") }
                .buttonStyle(TabTextStyle(selected: swipe))
        }
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
            .font(.ember(21, on ? .bold : .medium))
            .foregroundStyle(focused || on ? Theme.ink : .white)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background(Capsule().fill(focused ? Color.white : on ? Theme.accent : Color.white.opacity(0.1)))
            .scaleEffect(pressed ? 0.95 : focused ? 1.07 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 10, y: 5)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct ShuffleView: View {
    @EnvironmentObject var store: Store
    var toSwipe: () -> Void

    @AppStorage("shufType") private var type = "both"
    @AppStorage("shufVibe") private var vibe = ""
    @AppStorage("shufGenres") private var genres = ""
    @AppStorage("shufDecade") private var decade = ""

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

    private let W: CGFloat = 200, H: CGFloat = 300, GAP: CGFloat = 26

    static let types = [("both", "Films & series"), ("movie", "Films"), ("series", "Series")]
    static let vibes = [("", "Any vibe"), ("feelgood", "Feel-good"), ("laugh", "Laugh"), ("edge", "Edge of your seat"),
                        ("mindbending", "Mind-bending"), ("cosy", "Cosy"), ("dark", "Dark"), ("epic", "Epic"), ("tearjerker", "Tearjerker")]
    static let genreList = [("", "Any genre"), ("action", "Action"), ("comedy", "Comedy"), ("drama", "Drama"), ("scifi", "Sci-Fi"),
                            ("thriller", "Thriller"), ("horror", "Horror"), ("crime", "Crime"), ("romance", "Romance"),
                            ("animation", "Animation"), ("documentary", "Documentary"), ("fantasy", "Fantasy"), ("mystery", "Mystery")]
    static let decades = [("", "Any time"), ("2020", "2020s"), ("2010", "2010s"), ("2000", "2000s"), ("1990", "90s"),
                          ("1980", "80s"), ("older", "Older")]

    private var genreSet: [String] { genres.split(separator: ",").map(String.init) }

    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollViewReader { sv in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("What shall we watch?").font(.ember(52, .bold))
                            WTWModes(swipe: false, other: toSwipe)
                        }
                        .padding(.bottom, 6)
                        chipRow(Self.types, selected: { $0 == type }) { k in type = k; fresh() }
                        chipRow(Self.vibes, selected: { $0 == vibe }) { k in vibe = k; fresh() }
                        chipRow(Self.genreList, selected: { k in k.isEmpty ? genres.isEmpty : genreSet.contains(k) }) { k in toggleGenre(k) }
                        chipRow(Self.decades, selected: { $0 == decade }) { k in decade = k; fresh() }
                        HStack(spacing: 24) {
                            Button { Task { await spin() } } label: {
                                Label(pick == nil ? "Shuffle" : "Shuffle again", systemImage: "shuffle")
                            }
                            .buttonStyle(EmberButtonStyle(primary: true))
                            .disabled(spinning)
                            if !note.isEmpty { Text(note).font(.ember(21)).foregroundStyle(Theme.muted) }
                        }
                        .padding(.top, 8)
                        if !reel.isEmpty { stage }
                        if landed, let p = pick {
                            result(p).id("pick").transition(.opacity.combined(with: .offset(y: 24)))
                        }
                    }
                    .padding(.horizontal, 90).padding(.top, 50).padding(.bottom, 80)
                }
                .scrollClipDisabled()
                .onChange(of: landed) { _, l in
                    guard l else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { sv.scrollTo("pick", anchor: .bottom) }
                    focusWatch = true
                }
            }
          }
          .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
        }
    }

    // MARK: - filters

    private func chipRow(_ list: [(String, String)], selected: @escaping (String) -> Bool, tap: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(list.indices, id: \.self) { i in
                    Button { tap(list[i].0) } label: { Text(list[i].1) }
                        .buttonStyle(ChipStyle(on: selected(list[i].0)))
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
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

    // MARK: - the reel

    private var stage: some View {
        GeometryReader { g in
            HStack(spacing: GAP) {
                ForEach(reel.indices, id: \.self) { i in
                    let won = landed && i == at
                    RemoteImage(url: reel[i].posterURL) { Theme.card }
                        .frame(width: W, height: H)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent, lineWidth: won ? 4 : 0))
                        .shadow(color: won ? Theme.accent.opacity(0.6) : .black.opacity(0.45), radius: won ? 30 : 12, y: 8)
                        .scaleEffect(won ? 1.08 : 1)
                        .brightness(spinning ? -0.12 : 0)
                }
            }
            .fixedSize()
            .offset(x: offset)
            .frame(width: g.size.width, height: H + 50, alignment: .leading)
            .onAppear { stageW = g.size.width }
            .onChange(of: g.size.width) { _, w in stageW = w }
        }
        .frame(height: H + 50)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }

    private func spin() async {
        guard !spinning else { return }
        spinning = true
        note = ""
        withAnimation(.easeOut(duration: 0.2)) { landed = false }
        if used >= pile.count {
            note = "Shuffling…"
            await load()
        }
        guard used < pile.count else { spinning = false; return }
        if note == "Shuffling…" { note = "" }
        let p = pile[used]
        used += 1
        let others = pile.filter { $0.id != p.id }.shuffled()
        var run: [Meta] = []
        for i in 0..<30 { run.append(others.isEmpty ? p : others[i % others.count]) }
        let landAt = run.count
        run.append(p)
        run.append(contentsOf: others.prefix(4))
        let step = W + GAP
        let mid = stageW / 2 - W / 2
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { reel = run; at = landAt; pick = p; offset = mid - 2 * step }
        try? await Task.sleep(nanoseconds: 80_000_000)
        withAnimation(.timingCurve(0.12, 0.72, 0.14, 1, duration: 3.4)) { offset = mid - CGFloat(landAt) * step }
        try? await Task.sleep(nanoseconds: 3_450_000_000)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { landed = true }
        spinning = false
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
            let urls = got.prefix(30).compactMap(\.posterURL)
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

    // MARK: - the pick

    private func metaLine(_ p: Meta) -> String {
        var bits = [p.type == "series" ? "Series" : "Film"]
        if !p.releaseInfo.isEmpty { bits.append(p.releaseInfo) }
        if let r = p.rating, !r.isEmpty { bits.append("★ " + r) }
        return bits.joined(separator: "  ·  ")
    }

    private func result(_ p: Meta) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: p.backdropURL) { Theme.card }
                .frame(maxWidth: .infinity)
                .frame(height: 470)
                .clipped()
            LinearGradient(colors: [Theme.bg.opacity(0.96), Theme.bg.opacity(0.8), Theme.bg.opacity(0.1)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 16) {
                TitleArt(meta: p, height: 120, width: 560, nameSize: 52)
                Text(metaLine(p)).font(.ember(22)).foregroundStyle(.white.opacity(0.85))
                Text(p.description).font(.ember(21)).foregroundStyle(Theme.muted).lineLimit(3)
                    .frame(maxWidth: 780, alignment: .leading)
                HStack(spacing: 20) {
                    Button { store.playBest(p) } label: { Label("Watch", systemImage: "play.fill") }
                        .buttonStyle(EmberButtonStyle(primary: true))
                        .focused($focusWatch)
                    NavigationLink(value: p) { Label("Details", systemImage: "info.circle") }
                        .buttonStyle(EmberButtonStyle())
                    Button { Task { await spin() } } label: { Label("Not this one", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(EmberButtonStyle())
                }
                .padding(.top, 6)
            }
            .padding(44)
        }
        .frame(height: 470)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
}
