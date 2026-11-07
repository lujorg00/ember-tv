import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    @FocusState private var focusKey: String?
    @State private var lastKey: String?

    var body: some View {
        NavigationStack(path: $path) {
          ZStack {
            AmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !store.hero.isEmpty { HeroView(items: store.hero) }
                    if !store.cw.isEmpty { ContinueRow(items: store.cw) }
                    // the two watchlists (films, series) sit side by side, where the first of them comes
                    let walls = store.rows.filter(\.wide)
                    ForEach(store.rows) { r in
                        if r.top { TopRow(row: r) }
                        else if r.wide {
                            if walls.count >= 2 {
                                if r.id == walls[0].id {
                                    HStack(alignment: .top, spacing: 0) {
                                        WallRow(row: walls[0], leading: 90, trailing: 30, clip: true).frame(maxWidth: .infinity, alignment: .leading)
                                        WallRow(row: walls[1], leading: 30, trailing: 90, clip: true).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            } else { WallRow(row: r) }
                        }
                        else { SpotRow(row: r) }
                    }
                    ForEach(store.tileGroups) { g in TileRow(group: g, type: "") }
                    if !store.homeLoaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 300)
                    } else if store.rows.isEmpty {
                        Text("No rows yet. Check lucapi's address in Settings.")
                            .foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 300)
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .ignoresSafeArea()
          }
            .environment(\.focusMemory, $focusKey)
            .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
            .navigationDestination(for: Tile.self) { t in TilePage(tile: t, type: "") }
        }
        .rememberFocus($focusKey, last: $lastKey, depth: path.count)
    }
}

// MARK: - coming back to the same spot

private struct FocusMemoryKey: EnvironmentKey { static let defaultValue: FocusState<String?>.Binding? = nil }
extension EnvironmentValues {
    /// The page's focus, so Back can land on the row and item you opened.
    var focusMemory: FocusState<String?>.Binding? {
        get { self[FocusMemoryKey.self] }
        set { self[FocusMemoryKey.self] = newValue }
    }
}

/// Marks a card so the page can put the focus back on it.
struct Remember: ViewModifier {
    @Environment(\.focusMemory) private var memory
    let key: String
    func body(content: Content) -> some View {
        if let memory { content.focused(memory, equals: key) } else { content }
    }
}

extension View {
    func remember(_ key: String) -> some View { modifier(Remember(key: key)) }

    /// Notes what has the focus; coming back from a details page (the stack getting shorter), puts it back there.
    func rememberFocus(_ focus: FocusState<String?>.Binding, last: Binding<String?>, depth: Int) -> some View {
        self
            .onChange(of: focus.wrappedValue) { _, k in if let k { last.wrappedValue = k } }
            .onChange(of: depth) { old, new in
                guard new < old, let k = last.wrappedValue else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    focus.wrappedValue = k
                }
            }
    }
}

/// While a poster is selected, its details and pictures load ahead, so the details page opens complete.
struct Prefetch: View {
    let meta: Meta
    @Environment(\.isFocused) private var focused
    var body: some View {
        Color.clear.onChange(of: focused) { _, on in
            guard on else { return }
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let full = await MetaCache.shared.full(meta)
                _ = await ImageStore.shared.load(optional: full.backdropURL)
                _ = await ImageStore.shared.load(optional: full.logoURL)
            }
        }
    }
}

// MARK: - hero

/// The slideshow at the top: backdrop, logo, a line about it, Play and Details. Moves on every 15 seconds
/// (counting from the last change, so skipping by hand doesn't stop it). Each slide's picture and logo load first,
/// then fade in together.
struct HeroView: View {
    @EnvironmentObject var store: Store
    let items: [Meta]
    var pageName: String? = nil
    @State private var idx = 0
    @State private var full: [String: Meta] = [:]
    @State private var changedAt = Date()
    @State private var shown = false
    @State private var moving = false
    enum Btn: Hashable { case prev, play, details, next }
    @FocusState private var btn: Btn?

    private var m: Meta { let base = items[min(idx, items.count - 1)]; return full[base.id] ?? base }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // the slide: picture, logo and words, crossfading as one
            ZStack(alignment: .bottomLeading) {
                Backdrop(url: m.backdropURL, height: 760, kenBurns: true)
                LinearGradient(colors: [Theme.bg.opacity(0.95), Theme.bg.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [Theme.bg, .clear], startPoint: .bottom, endPoint: .center)
                VStack(alignment: .leading, spacing: 20) {
                    TitleArt(meta: m, height: 160, width: 620)
                    Text(store.progress[m.id]?.line ?? m.metaLine).font(.ember(24, .medium)).foregroundStyle(Theme.accent)
                    Text(m.description).font(.ember(24)).foregroundStyle(.white.opacity(0.9)).lineLimit(3).frame(maxWidth: 900, alignment: .leading)
                    Color.clear.frame(height: 60 + 8 + 12 + 50)   // room for the buttons and dots, which stay put
                }
                .padding(.leading, 90)
                .padding(.bottom, 40)
            }
            .id(m.id)
            .transition(.opacity)

            if let pageName {
                // the page's name, big and faint at the top, blending into the picture (as on Ember PC)
                Text(pageName).font(.ember(120, .heavy)).foregroundStyle(.white.opacity(0.10))
                    .padding(.leading, 80).padding(.top, 150)   // below the tab bar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    Button { play() } label: {
                        Label(store.progress[m.id].map { "Resume \(clock($0.position))" } ?? "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(EmberButtonStyle(primary: true))
                    .focused($btn, equals: .play)
                    NavigationLink(value: m) { Text("Details") }
                        .buttonStyle(EmberButtonStyle())
                        .focused($btn, equals: .details)
                }
                .padding(.top, 8)
                HStack(spacing: 16) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .prev).scaleEffect(0.8)
                    HStack(spacing: 10) {
                        ForEach(items.indices, id: \.self) { i in
                            Capsule().fill(i == idx ? Theme.accent : .white.opacity(0.3)).frame(width: i == idx ? 30 : 10, height: 10)
                        }
                    }
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .next).scaleEffect(0.8)
                }
            }
            .padding(.leading, 90)
            .padding(.bottom, 40)
            .onMoveCommand { d in
                // left from Play (nothing else that way): the slide before
                if d == .left && btn == .play { step(-1) }
            }
            if pageName == nil {
                // the cats and what's next, small, top right beside the tab bar
                GlanceView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 70).padding(.top, 52)
                    .allowsHitTesting(false)
            }
            if pageName == nil && !store.upcoming.isEmpty {
                WeekPanel(eps: store.upcoming)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 80).padding(.bottom, 40)
            }
        }
        .frame(height: 760)
        .clipped()
        // coming to the tab: the hero fades in where it is, rather than anything sliding about
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeIn(duration: 0.45)) { shown = true } }
        .onDisappear { shown = false }
        .task {
            await prepare(idx)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Date().timeIntervalSince(changedAt) >= 15, !items.isEmpty, !moving { await go(to: (idx + 1) % items.count) }
            }
        }
    }

    private func step(_ d: Int) {
        guard !items.isEmpty else { return }
        Task { await go(to: (idx + d + items.count) % items.count) }
    }

    /// Details, picture and logo ready before the slide shows, so they appear together.
    private func prepare(_ i: Int) async {
        let base = items[min(i, items.count - 1)]
        var f: Meta
        if let known = full[base.id] { f = known } else { f = await MetaCache.shared.full(base) }
        full[base.id] = f
        async let b = ImageStore.shared.load(optional: f.backdropURL)
        async let l = ImageStore.shared.load(optional: f.logoURL)
        _ = await (b, l)
    }

    private func go(to i: Int) async {
        moving = true
        changedAt = Date()
        await prepare(i)
        withAnimation(.easeInOut(duration: 0.7)) { idx = i }
        changedAt = Date()
        moving = false
    }

    private func play() {
        let p = store.progress[m.id]
        if m.isSeries {
            store.playBest(m, season: p?.season ?? 1, episode: p?.episode ?? 1, epTitle: p?.episodeTitle ?? "", start: p?.position ?? 0)
        } else {
            store.playBest(m, start: p?.position ?? 0)
        }
    }
}

/// A backdrop that fills its space (cropped, never spilling out) and fades in once loaded.
struct Backdrop: View {
    let url: URL?
    var height: CGFloat? = nil
    var kenBurns = false          // a slow drift in, like the Apple TV app's backdrops
    @State private var zoom = false
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : nil)
            .frame(height: height)
            .overlay {
                RemoteImage(url: url) { Color.clear }
                .scaleEffect(zoom ? 1.08 : 1.0, anchor: .topTrailing)
            }
            .clipped()
            .onAppear {
                // the drift starts once and carries on: coming back to the tab doesn't jolt it
                guard kenBurns, !zoom else { return }
                withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) { zoom = true }
            }
    }
}

/// New This Week: a small panel at the bottom right of the hero. Each opens the show.
struct WeekPanel: View {
    let eps: [Upcoming]
    @State private var all = false      // "and N more" opens the rest
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEW THIS WEEK").font(.ember(15, .bold)).tracking(1.4).foregroundStyle(Theme.muted).padding(.leading, 8)
            ForEach(eps.prefix(all ? 10 : 4)) { e in
                NavigationLink(value: Meta(["id": e.imdb, "type": "series", "name": e.show])) {
                    HStack(spacing: 14) {
                        RemoteImage(url: URL(string: "https://images.metahub.space/background/small/\(e.imdb)/img")) { Theme.card }
                        .frame(width: 84, height: 47)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.show).font(.ember(20, .semibold)).lineLimit(1)
                            Text("\(e.when) · S\(e.season) E\(e.episode)").font(.ember(17))
                                .foregroundStyle(e.out ? Theme.accent : Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                }
                .buttonStyle(RowButtonStyle())
            }
            if eps.count > 4 && !all {
                Button { withAnimation(.easeOut(duration: 0.25)) { all = true } } label: {
                    Text("and \(eps.count - 4) more").font(.ember(16, .semibold)).foregroundStyle(Theme.accent)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
        .focusSection()
    }
}

/// The title's logo, or its name when there's no logo (shown straight away when it's been loaded before).
struct TitleArt: View {
    let meta: Meta
    var height: CGFloat
    var width: CGFloat
    var nameSize: CGFloat = 60
    @State private var img: UIImage?
    @State private var failed = false

    init(meta: Meta, height: CGFloat, width: CGFloat, nameSize: CGFloat = 60) {
        self.meta = meta
        self.height = height
        self.width = width
        self.nameSize = nameSize
        _img = State(initialValue: meta.logoURL.flatMap { ImageStore.shared.cache.object(forKey: $0 as NSURL) })
    }

    var body: some View {
        Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: width, maxHeight: height, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 4)
                    .transition(.opacity)
            } else if meta.logoURL == nil || failed {
                Text(meta.name).font(.ember(nameSize, .bold)).lineLimit(2).frame(maxWidth: width, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 4)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: width, maxHeight: height, alignment: .bottomLeading)
        .frame(height: height, alignment: .bottomLeading)
        .task(id: meta.logoURL) {
            guard img == nil, let u = meta.logoURL else { return }
            if let got = await ImageStore.shared.load(u) { withAnimation(.easeIn(duration: 0.35)) { img = got } }
            else { withAnimation(.easeIn(duration: 0.35)) { failed = true } }
        }
    }
}

// MARK: - rows

struct RowHeader: View {
    let title: String
    var kind: String? = nil
    var count: Int? = nil
    var leading: CGFloat = 90
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.ember(34, .bold))
            if let kind { Text(kind).font(.ember(24, .semibold)).foregroundStyle(Theme.accent) }
            if let count { Text("\(count)").font(.ember(20)).foregroundStyle(Theme.muted) }
        }
        .padding(.leading, leading)
    }
}

struct PosterRow: View {
    let row: RowData
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: row.title, kind: row.kind, count: row.metas.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(row.metas) { m in PosterCard(meta: m).remember("\(row.id)|\(m.id)") }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 28)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Top 10, as on Ember PC: big outlined orange numbers, each beside a wide picture with the title on it.
struct TopRow: View {
    @EnvironmentObject var store: Store
    let row: RowData
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: row.title, kind: row.kind)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 34) {
                    ForEach(0..<min(row.numbered ? 25 : 30, row.metas.count), id: \.self) { i in
                        let m = row.metas[i]
                        HStack(alignment: .bottom, spacing: -6) {
                            if row.numbered { OutlinedText(text: "\(i + 1)", size: 190).offset(y: 6) }
                            NavigationLink(value: m) {
                                ZStack(alignment: .bottomLeading) {
                                    RemoteImage(url: m.backdropURL) { Theme.card }
                                        .frame(width: 400, height: 225)
                                        .clipped()
                                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                                    // the title as its logo (the name when it has none)
                                    TitleArt(meta: m, height: 70, width: 250, nameSize: 26)
                                        .padding(.horizontal, 16).padding(.bottom, 14)
                                    WatchBadge(state: store.badge(m.id))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.watchlist.contains(m.id) ? .topLeading : .topTrailing)
                                    if store.watchlist.contains(m.id) { Bookmark().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                                }
                                .frame(width: 400, height: 225)
                            }
                            .buttonStyle(.card)
                            .remember("\(row.id)|\(m.id)")
                            .onAppear { store.wantRelease(m) }
                            .contextMenu { PosterMenu(meta: m) }
                        }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 28)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Your watchlists: wide pictures with the title on them, so they stand apart from the poster rows.
struct WideRow: View {
    @EnvironmentObject var store: Store
    let row: RowData
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: row.title, kind: row.kind, count: row.metas.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(row.metas) { m in
                        NavigationLink(value: m) {
                            ZStack(alignment: .bottomLeading) {
                                RemoteImage(url: m.backdropURL) { Theme.card }
                                    .frame(width: 400, height: 225)
                                    .clipped()
                                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                                Text(m.name).font(.ember(24, .bold)).lineLimit(2)
                                    .shadow(color: .black, radius: 10).padding(.horizontal, 16).padding(.bottom, 14)
                                WatchBadge(state: store.badge(m.id)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            }
                            .frame(width: 400, height: 225)
                            .background(Prefetch(meta: m))
                        }
                        .buttonStyle(.card)
                        .remember("\(row.id)|\(m.id)")
                        .onAppear { store.wantRelease(m) }
                        .contextMenu { PosterMenu(meta: m) }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 28)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A poster: lifts and catches the light when selected (tvOS's own card effect). Hold to mark it watched.
struct PosterCard: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    var width: CGFloat = 205
    var inWatchlist = false     // a watchlist row: the tick sits top left, and watched takes it off the list

    var body: some View {
        NavigationLink(value: meta) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: meta.posterURL) {
                    ZStack { Theme.card; Text(meta.name).font(.ember(20)).multilineTextAlignment(.center).padding() }
                }
                .frame(width: width, height: width * 1.5)
                .clipped()
                if store.watchlist.contains(meta.id) { Bookmark() }
                // bookmarked (or a watchlist row): the tick sits top left, clear of the bookmark
                WatchBadge(state: store.badge(meta.id))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: inWatchlist || store.watchlist.contains(meta.id) ? .topLeading : .topTrailing)
                if let label = store.release[meta.id]?.label {
                    Text(label).font(.ember(15, .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background((store.release[meta.id]?.s == "cinema" ? Theme.accent : Color.black.opacity(0.7)), in: Capsule())
                        .foregroundStyle(store.release[meta.id]?.s == "cinema" ? Theme.ink : .white)
                        .padding(10)
                        // the tick is top left on bookmarked posters: the label sits beside it
                        .padding(.leading, store.watched[meta.id] != nil && (inWatchlist || store.watchlist.contains(meta.id)) ? 48 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let p = store.progress[meta.id] {
                    VStack { Spacer(); ProgressBar(fraction: p.percent / 100).padding(10) }
                }
            }
            .frame(width: width, height: width * 1.5)
            .background(Prefetch(meta: meta))
        }
        .buttonStyle(.card)
        .onAppear { store.wantRelease(meta) }
        .contextMenu { PosterMenu(meta: meta, inWatchlist: inWatchlist) }
    }
}

/// On your watchlist: an amber bookmark at the top right of the poster, on every row and page.
struct Bookmark: View {
    var size: CGFloat = 1
    var body: some View {
        BookmarkShape().fill(Theme.accent)
            .frame(width: 26 * size, height: 36 * size)
            .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
            .padding(.trailing, 12 * size)
            .offset(y: -2)
    }
}
struct BookmarkShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.26))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The ordinary rows: the first title large (picture, logo, a line about it, Play and Details), then the posters.
/// The ordinary rows, as on Ember PC: posters, and the one you rest on opens out into a large card (its picture,
/// logo, a line about it) in place. Select opens it; the Play/Pause button plays it.
struct SpotRow: View {
    let row: RowData
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: row.title, kind: row.kind, count: row.metas.count)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 32) {
                        ForEach(row.metas) { m in
                            SpotPoster(meta: m) {
                                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(m.id, anchor: UnitPoint(x: 0.05, y: 0.5)) }
                            }
                            .id(m.id)
                            .remember("\(row.id)|\(m.id)")
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 28)
                }
                .scrollClipDisabled()
            }
        }
        .focusSection()
    }
}

/// Mark watched, love: the long-press menu on any poster.
struct PosterMenu: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    var inWatchlist = false
    var body: some View {
        if store.watched[meta.id] == "done" {
            Button("Mark as unwatched") { Task { await store.markTitle(meta, watched: false) } }
        } else if inWatchlist {
            Button("Mark as watched (takes it off your watchlist)") { Task { await store.watchedFromWatchlist(meta) } }
        } else {
            Button("Mark as watched") { Task { await store.markTitle(meta, watched: true) } }
        }
        Button(store.loved.contains(meta.id) ? "Take the love off" : "Love it (steers your recommendations)") {
            Task { await store.setLove(meta, !store.loved.contains(meta.id)) }
        }
    }
}

/// A poster that opens out into the spotlight card when you rest on it.
struct SpotPoster: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    var opened: () -> Void = {}

    var body: some View {
        NavigationLink(value: meta) {
            SpotFace(meta: meta, opened: opened)
        }
        .buttonStyle(LiftCardStyle())
        .onAppear { store.wantRelease(meta) }
        .onPlayPauseCommand { play() }
        .contextMenu { PosterMenu(meta: meta) }
    }

    private func play() {
        let p = store.progress[meta.id]
        if meta.isSeries {
            store.playBest(meta, season: p?.season ?? 1, episode: p?.episode ?? 1, epTitle: p?.episodeTitle ?? "", start: p?.position ?? 0)
        } else {
            store.playBest(meta, start: p?.position ?? 0)
        }
    }
}

private struct SpotFace: View {
    @EnvironmentObject var store: Store
    @Environment(\.isFocused) private var focused
    let meta: Meta
    let opened: () -> Void
    @State private var open = false
    @State private var resting = false      // still selected (read after the pause, so it's current)
    @State private var full: Meta?
    private var m: Meta { full ?? meta }
    static let h: CGFloat = 308

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // the poster, crossfading to the wide picture as it opens (and back)
            RemoteImage(url: meta.posterURL) {
                ZStack { Theme.card; Text(meta.name).font(.ember(20)).multilineTextAlignment(.center).padding() }
            }
            .frame(width: 205, height: SpotFace.h).clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .opacity(open ? 0 : 1)
            if open {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: m.backdropURL) { Theme.card }
                        .frame(width: 720, height: SpotFace.h).clipped()
                    LinearGradient(colors: [Theme.bg.opacity(0.94), Theme.bg.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [Theme.bg.opacity(0.6), .clear], startPoint: .bottom, endPoint: .center)
                    VStack(alignment: .leading, spacing: 8) {
                        TitleArt(meta: m, height: 72, width: 330, nameSize: 34)
                        Text(store.progress[m.id]?.line ?? m.metaLine).font(.ember(18, .medium))
                            .foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Text(m.description).font(.ember(17)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                            .frame(maxWidth: 440, alignment: .leading)
                        HStack(spacing: 8) {
                            Image(systemName: "playpause.fill")
                            Text(store.progress[m.id] != nil ? "Resume" : "Play")
                            Text("·")
                            Text("Select for details")
                        }
                        .font(.ember(15, .medium)).foregroundStyle(Theme.muted)
                    }
                    .padding(.leading, 24).padding(.bottom, 20)
                }
                .transition(.opacity)
            }
            if store.watchlist.contains(meta.id) { Bookmark().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            WatchBadge(state: store.badge(meta.id))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.watchlist.contains(meta.id) ? .topLeading : .topTrailing)
            if let p = store.progress[meta.id], !open {
                ProgressBar(fraction: p.percent / 100).padding(10).frame(width: 205)
            }
        }
        .frame(width: open ? 720 : 205, height: SpotFace.h)
        .clipped()
        .background(Prefetch(meta: meta))
        .onChange(of: focused) { _, on in
            resting = on
            if on {
                Task {
                    if full == nil { full = await MetaCache.shared.full(meta) }
                    if let b = m.backdropURL { _ = await ImageStore.shared.load(b) }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard resting, !open else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { open = true }
                    opened()
                }
            } else if open {
                withAnimation(.easeInOut(duration: 0.25)) { open = false }
            }
        }
    }
}

struct SpotCard: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    let key: String
    @State private var full: Meta?
    private var m: Meta { full ?? meta }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: m.backdropURL) { Theme.card }
                .frame(width: 720, height: 405).clipped()
            LinearGradient(colors: [Theme.bg.opacity(0.94), Theme.bg.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [Theme.bg.opacity(0.6), .clear], startPoint: .bottom, endPoint: .center)
            VStack(alignment: .leading, spacing: 10) {
                Text("TOP PICK").font(.ember(15, .bold)).tracking(1.6).foregroundStyle(Theme.accent)
                TitleArt(meta: m, height: 80, width: 360)
                Text(store.progress[m.id]?.line ?? m.metaLine).font(.ember(19, .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Text(m.description).font(.ember(19)).foregroundStyle(.white.opacity(0.85)).lineLimit(2).frame(maxWidth: 420, alignment: .leading)
                HStack(spacing: 18) {
                    Button { play() } label: {
                        Label(store.progress[m.id].map { "Resume \(clock($0.position))" } ?? "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(EmberButtonStyle(primary: true))
                    .remember(key + "-play")
                    .contextMenu { markMenu }
                    NavigationLink(value: m) { Text("Details") }
                        .buttonStyle(EmberButtonStyle())
                        .remember(key + "-details")
                        .contextMenu { markMenu }
                }
                .padding(.top, 4)
            }
            .padding(.leading, 30).padding(.bottom, 26)
            if store.watchlist.contains(m.id) { Bookmark(size: 1.2).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            WatchBadge(state: store.badge(m.id))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.watchlist.contains(m.id) ? .topLeading : .topTrailing)
        }
        .frame(width: 720, height: 405)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
        .task { if full == nil { full = await MetaCache.shared.full(meta) } }
        .onAppear { store.wantRelease(meta) }
    }

    @ViewBuilder private var markMenu: some View {
        Button(store.watched[m.id] == "done" ? "Mark as unwatched" : "Mark as watched") {
            Task { await store.markTitle(m, watched: store.watched[m.id] != "done") }
        }
        Button(store.loved.contains(m.id) ? "Take the love off" : "Love it (steers your recommendations)") {
            Task { await store.setLove(m, !store.loved.contains(m.id)) }
        }
    }

    private func play() {
        let p = store.progress[m.id]
        if m.isSeries {
            store.playBest(m, season: p?.season ?? 1, episode: p?.episode ?? 1, epTitle: p?.episodeTitle ?? "", start: p?.position ?? 0)
        } else {
            store.playBest(m, start: p?.position ?? 0)
        }
    }
}

/// Your watchlists: posters two rows deep, so they stand apart (each carries its bookmark).
struct WallRow: View {
    let row: RowData
    var leading: CGFloat = 90
    var trailing: CGFloat = 90
    var clip = false          // side by side: each scrolls within its own half
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: row.title, kind: row.kind, count: row.metas.count, leading: leading)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(240), spacing: 30), GridItem(.fixed(240))], spacing: 26) {
                    ForEach(row.metas) { m in PosterCard(meta: m, width: 160, inWatchlist: true).remember("\(row.id)|\(m.id)") }
                }
                .padding(.leading, leading).padding(.trailing, trailing)
                .padding(.vertical, 28)
            }
            .scrollClipDisabled(!clip)
        }
        .focusSection()
    }
}

struct WatchBadge: View {
    let state: String?
    var body: some View {
        if state == "loved" {
            Image(systemName: "heart.fill").font(.ember(18, .heavy)).foregroundStyle(Color(red: 1, green: 0.36, blue: 0.42))
                .frame(width: 38, height: 38).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).padding(10)
        } else if state == "done" {
            Image(systemName: "checkmark").font(.ember(18, .heavy)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).padding(10)
        } else if state == "partial" {
            Image(systemName: "circle.lefthalf.filled").font(.ember(18, .bold)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).padding(10)
        }
    }
}

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Theme.accent).frame(width: max(6, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - continue watching

struct ContinueRow: View {
    @EnvironmentObject var store: Store
    let items: [CWItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: "Continue watching", count: items.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 32) {
                    ForEach(items) { it in
                        VStack(alignment: .leading, spacing: 14) {
                            NavigationLink(value: it.meta) {
                                ZStack(alignment: .bottomLeading) {
                                    RemoteImage(url: it.art) { Theme.card }
                                    .frame(width: 430, height: 242)
                                    .clipped()
                                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .center)
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 8) {
                                            if !it.label.hasPrefix("Next") { Image(systemName: "play.fill").font(.system(size: 17, weight: .bold)) }
                                            Text(it.label).font(.ember(24, .bold))
                                        }
                                        if let p = it.percent { ProgressBar(fraction: p / 100) }
                                    }
                                    .padding(18)
                                }
                                .frame(width: 430, height: 242)
                            }
                            .buttonStyle(.card)
                            .remember("cw|\(it.id)")
                            .contextMenu {
                                PosterMenu(meta: it.meta)
                                Button("Remove from Continue watching", role: .destructive) { store.dismiss(it.id) }
                            }
                            Text(it.meta.name).font(.ember(24, .semibold)).lineLimit(1).frame(width: 430, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 28)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}
