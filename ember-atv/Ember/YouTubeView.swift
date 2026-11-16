import SwiftUI

/// YouTube inside Ember: your recommendations, subscriptions, Watch later and history (signed in on lucapi),
/// search and channels, laid out like the YouTube app. Videos play in Ember's own player (no ads), so the cat
/// flap camera and the other pop-ups still show over them.
enum YT {
    static let red = Color(red: 1, green: 0, blue: 0.2)                 // #FF0033
    static let bg = Color(red: 0.059, green: 0.059, blue: 0.059)        // #0F0F0F
    static let card = Color(white: 0.16)
    static let muted = Color(white: 0.67)
    static func font(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w) }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Looked at a video for a moment: lucapi gets its streams ready, so it starts quickly if it's picked.
    @MainActor private static var prepped = Set<String>()
    @MainActor static func prep(_ id: String) {
        guard !prepped.contains(id) else { return }
        prepped.insert(id)
        Task { _ = try? await API.feedGet("/yt/prep/\(id)", timeout: 10) }
    }
}

struct YTChannel: Hashable {
    let id: String
    let name: String
}

struct YouTubeView: View {
    enum Page: String, CaseIterable, Hashable {
        case search, home, subs, later, history
        var label: String {
            switch self {
            case .search: return "Search"
            case .home: return "Home"
            case .subs: return "Subscriptions"
            case .later: return "Watch later"
            case .history: return "History"
            }
        }
        var icon: String {
            switch self {
            case .search: return "magnifyingglass"
            case .home: return "house.fill"
            case .subs: return "play.square.stack.fill"
            case .later: return "clock.fill"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    @State private var page: Page = .home
    @State private var path: [YTChannel] = []
    @FocusState private var rail: Page?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .leading) {
                YT.bg.ignoresSafeArea()
                Group {
                    switch page {
                    case .search: YTSearch(open: open)
                    default: YTGrid(source: "/yt/feed/\(page.rawValue)", title: page == .home ? nil : page.label, open: open)
                            .id(page)
                    }
                }
                .padding(.leading, 150)
                railView
            }
            .navigationDestination(for: YTChannel.self) { c in
                ZStack { YT.bg.ignoresSafeArea(); YTGrid(source: "/yt/channel/\(c.id)", title: c.name, open: open).padding(.leading, 60) }
            }
        }
    }

    private func open(_ c: YTChannel) { path.append(c) }

    /// The menu down the left: icons, opening out with names while you're in it (as on YouTube).
    private var railView: some View {
        let expanded = rail != nil
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Page.allCases, id: \.self) { p in
                Button { page = p } label: {
                    HStack(spacing: 22) {
                        Image(systemName: p.icon).font(.system(size: 30, weight: .semibold)).frame(width: 44)
                        if expanded { Text(p.label).font(YT.font(26, .medium)).fixedSize() }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .buttonStyle(YTRailStyle(selected: page == p))
                .focused($rail, equals: p)
            }
        }
        .padding(.leading, 34).padding(.vertical, 40)
        .frame(maxHeight: .infinity, alignment: .center)
        .frame(width: expanded ? 420 : 140, alignment: .leading)
        .background(LinearGradient(colors: [YT.bg, YT.bg.opacity(expanded ? 0.97 : 0)], startPoint: .leading, endPoint: .trailing)
            .ignoresSafeArea())
        .focusSection()
        .onChange(of: rail) { _, r in if let r { page = r } }   // moving down the menu changes the page, as on YouTube
        .animation(.easeOut(duration: 0.2), value: expanded)
    }
}

struct YTRailStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration, selected: selected) }
    private struct Body: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? .black : selected ? .white : YT.muted)
                .background(focused ? Color.white : selected ? Color.white.opacity(0.14) : .clear, in: Capsule())
                .scaleEffect(focused ? 1.04 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// A grid of videos from lucapi (a feed, a search or a channel), four across.
struct YTGrid: View {
    let source: String
    var title: String? = nil
    let open: (YTChannel) -> Void
    @State private var items: [JSON] = []
    @State private var error = ""
    @State private var loading = true

    private let cols = Array(repeating: GridItem(.fixed(390), spacing: 44, alignment: .top), count: 4)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if let title { Text(title).font(YT.font(38, .bold)).padding(.top, 10) }
                if loading && items.isEmpty {
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 50) {
                        ForEach(0..<8, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                RoundedRectangle(cornerRadius: 14).fill(YT.card).frame(width: 390, height: 219)
                                RoundedRectangle(cornerRadius: 6).fill(YT.card).frame(width: 300, height: 22)
                                RoundedRectangle(cornerRadius: 6).fill(YT.card).frame(width: 180, height: 18)
                            }
                        }
                    }
                } else if items.isEmpty {
                    Text(error.isEmpty ? "Nothing here yet." : error).font(YT.font(24)).foregroundStyle(YT.muted)
                        .padding(.top, 80).focusable()
                } else {
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 50) {
                        ForEach(items.indices, id: \.self) { i in
                            YTTile(v: items[i], row: items, index: i, open: open)
                        }
                    }
                }
            }
            .padding(.trailing, 60).padding(.bottom, 80).padding(.top, 20)
        }
        .scrollClipDisabled()
        .task(id: source) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let j = try? await API.feedGet(source, timeout: 120) else { error = "Couldn't reach lucapi."; return }
        items = j.arr("items")
        error = j.str("error") ?? ""
    }
}

struct YTSearch: View {
    let open: (YTChannel) -> Void
    @State private var q = ""
    @State private var term = ""

    var body: some View {
        ZStack {
            if term.isEmpty {
                Text("Search YouTube").font(YT.font(30)).foregroundStyle(YT.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                YTGrid(source: "/yt/search?q=\(API.q(term))", open: open).id(term)
            }
        }
        .searchable(text: $q, prompt: "Search YouTube")
        .task(id: q) {
            let t = q.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)   // wait for typing to pause
            if !Task.isCancelled { term = t }
        }
    }
}

/// One video: picture with its length (or LIVE) and a red bar for how far you got, then title, channel, views · age.
/// Select plays it (the rest of the row plays on after); hold for the channel.
struct YTTile: View {
    @EnvironmentObject var store: Store
    let v: JSON
    let row: [JSON]
    let index: Int
    let open: (YTChannel) -> Void

    var body: some View {
        Button { store.playYouTube(v, queue: Array(row.dropFirst(index + 1).prefix(25))) } label: { YTTileLabel(v: v) }
            .buttonStyle(YTTileStyle())
            .contextMenu {
                if let cid = v.str("channel_id"), cid.hasPrefix("UC") {
                    Button { open(YTChannel(id: cid, name: v.str("channel") ?? "")) } label: {
                        Label("Go to \(v.str("channel") ?? "channel")", systemImage: "person.crop.square")
                    }
                }
                Button { store.playYouTube(v) } label: { Label("Play just this", systemImage: "play.fill") }
            }
    }
}

struct YTTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct YTTileLabel: View {
    let v: JSON
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: v.str("thumb").flatMap(URL.init(string:))) {
                    RemoteImage(url: v.str("thumb2").flatMap(URL.init(string:))) { YT.card }
                }
                .frame(width: 390, height: 219)
                .clipped()
                if v.bool("live") {
                    Text(v.bool("upcoming") ? "UPCOMING" : "LIVE").font(YT.font(16, .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(v.bool("upcoming") ? Color.black.opacity(0.8) : YT.red, in: RoundedRectangle(cornerRadius: 5))
                        .padding(10)
                } else if let d = v.dbl("duration"), d > 0 {
                    Text(YT.clock(d)).font(YT.font(17, .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                        .padding(.trailing, 10).padding(.bottom, (v.dbl("progress") ?? 0) > 0 ? 16 : 10)
                }
                if let p = v.dbl("progress"), p > 0 {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.35))
                        Rectangle().fill(YT.red).frame(width: 390 * min(1, max(0.03, p)))
                    }
                    .frame(width: 390, height: 6)
                }
            }
            .frame(width: 390, height: 219)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white, lineWidth: focused ? 5 : 0))
            .scaleEffect(focused ? 1.05 : 1)
            .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 20, y: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text(v.str("title") ?? "").font(YT.font(23, .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(.white)
                Text(v.str("channel") ?? "").font(YT.font(19)).foregroundStyle(YT.muted).lineLimit(1)
                let line = [v.str("views") ?? "", v.str("ago") ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")
                if !line.isEmpty { Text(line).font(YT.font(19)).foregroundStyle(YT.muted).lineLimit(1) }
            }
            .frame(width: 390, alignment: .leading)
            .offset(y: focused ? 8 : 0)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .task(id: focused) {
            guard focused, let id = v.str("id") else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { YT.prep(id) }
        }
    }
}
