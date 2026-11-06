import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !store.hero.isEmpty { HeroView(items: store.hero) }
                    if !store.cw.isEmpty { ContinueRow(items: store.cw) }
                    ForEach(store.rows) { r in
                        if r.top { TopRow(row: r) } else { PosterRow(row: r) }
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
            .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
            .navigationDestination(for: Tile.self) { t in TilePage(tile: t, type: "") }
        }
    }
}

// MARK: - hero

/// The slideshow at the top: backdrop, logo, a line about it, Play and Details. Moves on every 15 seconds.
struct HeroView: View {
    @EnvironmentObject var store: Store
    let items: [Meta]
    var pageName: String? = nil
    @State private var idx = 0
    @State private var full: [String: Meta] = [:]
    @State private var holdUntil = Date.distantPast
    @FocusState private var focused: Bool
    @State private var shown = false

    private var m: Meta { let base = items[min(idx, items.count - 1)]; return full[base.id] ?? base }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Backdrop(url: m.backdropURL, height: 760, kenBurns: true)
                .id(m.id)
                .transition(.opacity)
            if let pageName {
                // the page's name, big and faint at the top, blending into the picture (as on Ember PC)
                Text(pageName).font(.ember(120, .heavy)).foregroundStyle(.white.opacity(0.10))
                    .padding(.leading, 80).padding(.top, 150)   // below the tab bar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            LinearGradient(colors: [Theme.bg.opacity(0.95), Theme.bg.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [Theme.bg, .clear], startPoint: .bottom, endPoint: .center)
            VStack(alignment: .leading, spacing: 20) {
                TitleArt(meta: m, height: 160, width: 620)
                if let p = store.progress[m.id] {
                    Text(p.line).font(.ember(24, .medium)).foregroundStyle(Theme.accent)
                } else {
                    Text(m.metaLine).font(.ember(24, .medium)).foregroundStyle(Theme.accent)
                }
                Text(m.description).font(.ember(24)).foregroundStyle(.white.opacity(0.9)).lineLimit(3).frame(maxWidth: 900, alignment: .leading)
                HStack(spacing: 24) {
                    Button {
                        play()
                    } label: {
                        Label(store.progress[m.id].map { "Resume \(clock($0.position))" } ?? "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(EmberButtonStyle(primary: true))
                    NavigationLink(value: m) { Text("Details") }
                        .buttonStyle(EmberButtonStyle())
                }
                .focused($focused)
                .padding(.top, 8)
                HStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule().fill(i == idx ? Theme.accent : .white.opacity(0.3)).frame(width: i == idx ? 30 : 10, height: 10)
                    }
                }
                .padding(.top, 12)
            }
            .padding(.leading, 90)
            .padding(.bottom, 40)
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
        .animation(.easeInOut(duration: 0.6), value: idx)
        .task(id: idx) {
            let base = items[min(idx, items.count - 1)]
            if full[base.id] == nil { full[base.id] = await MetaCache.shared.full(base) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !focused, Date() > holdUntil, !items.isEmpty { idx = (idx + 1) % items.count }
            }
        }
        // left and right on the hero's buttons, past either end, change slide
        .onMoveCommand { d in
            guard focused else { return }
            if d == .left || d == .right { holdUntil = Date().addingTimeInterval(60) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEW THIS WEEK").font(.ember(15, .bold)).tracking(1.4).foregroundStyle(Theme.muted).padding(.leading, 8)
            ForEach(eps.prefix(4)) { e in
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
                .buttonStyle(.plain)
            }
            if eps.count > 4 {
                Text("and \(eps.count - 4) more").font(.ember(15)).foregroundStyle(Theme.muted).padding(.leading, 8)
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
        .focusSection()
    }
}

/// The title's logo, or its name when there's no logo.
struct TitleArt: View {
    let meta: Meta
    var height: CGFloat
    var width: CGFloat
    var body: some View {
        AsyncImage(url: meta.logoURL) { ph in
            if let img = ph.image {
                img.resizable().scaledToFit().frame(maxWidth: width, maxHeight: height, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 4)
            } else {
                Text(meta.name).font(.ember(60, .bold)).lineLimit(2).frame(maxWidth: width, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 4)
            }
        }
        .frame(maxWidth: width, maxHeight: height, alignment: .bottomLeading)
    }
}

// MARK: - rows

struct RowHeader: View {
    let title: String
    var kind: String? = nil
    var count: Int? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.ember(34, .bold))
            if let kind { Text(kind).font(.ember(24, .semibold)).foregroundStyle(Theme.accent) }
            if let count { Text("\(count)").font(.ember(20)).foregroundStyle(Theme.muted) }
        }
        .padding(.leading, 90)
    }
}

struct PosterRow: View {
    let row: RowData
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: row.title, kind: row.kind, count: row.metas.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(row.metas) { m in PosterCard(meta: m) }
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
                    ForEach(0..<min(10, row.metas.count), id: \.self) { i in
                        let m = row.metas[i]
                        HStack(alignment: .bottom, spacing: -6) {
                            OutlinedText(text: "\(i + 1)", size: 190).offset(y: 6)
                            NavigationLink(value: m) {
                                ZStack(alignment: .bottomLeading) {
                                    RemoteImage(url: m.backdropURL) { Theme.card }
                                        .frame(width: 400, height: 225)
                                        .clipped()
                                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                                    Text(m.name).font(.ember(24, .bold)).lineLimit(2)
                                        .shadow(color: .black, radius: 10).padding(.horizontal, 16).padding(.bottom, 14)
                                    WatchBadge(state: store.watched[m.id]).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                }
                                .frame(width: 400, height: 225)
                            }
                            .buttonStyle(.card)
                            .onAppear { store.wantRelease(m) }
                            .contextMenu {
                                Button(store.watched[m.id] == "done" ? "Mark as unwatched" : "Mark as watched") {
                                    Task { await store.markTitle(m, watched: store.watched[m.id] != "done") }
                                }
                            }
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

/// A poster: lifts and catches the light when selected (tvOS's own card effect). Hold to mark it watched.
struct PosterCard: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    var width: CGFloat = 205

    var body: some View {
        NavigationLink(value: meta) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: meta.posterURL) {
                    ZStack { Theme.card; Text(meta.name).font(.ember(20)).multilineTextAlignment(.center).padding() }
                }
                .frame(width: width, height: width * 1.5)
                .clipped()
                WatchBadge(state: store.watched[meta.id])
                if let label = store.release[meta.id]?.label {
                    Text(label).font(.ember(15, .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background((store.release[meta.id]?.s == "cinema" ? Theme.accent : Color.black.opacity(0.7)), in: Capsule())
                        .foregroundStyle(store.release[meta.id]?.s == "cinema" ? Theme.ink : .white)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let p = store.progress[meta.id] {
                    VStack { Spacer(); ProgressBar(fraction: p.percent / 100).padding(10) }
                }
            }
            .frame(width: width, height: width * 1.5)
        }
        .buttonStyle(.card)
        .onAppear { store.wantRelease(meta) }
        .contextMenu {
            if store.watched[meta.id] == "done" {
                Button("Mark as unwatched") { Task { await store.markTitle(meta, watched: false) } }
            } else {
                Button("Mark as watched") { Task { await store.markTitle(meta, watched: true) } }
            }
        }
    }
}

struct WatchBadge: View {
    let state: String?
    var body: some View {
        if state == "done" {
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
                                        Text(it.label).font(.ember(24, .bold))
                                        if let p = it.percent { ProgressBar(fraction: p / 100) }
                                    }
                                    .padding(18)
                                }
                                .frame(width: 430, height: 242)
                            }
                            .buttonStyle(.card)
                            .contextMenu {
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
