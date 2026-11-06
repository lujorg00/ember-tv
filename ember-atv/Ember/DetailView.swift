import SwiftUI

/// A film or show: backdrop, logo, where you are, Play/Resume, and for a show its seasons and episodes.
struct DetailView: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    @State private var m: Meta?
    @State private var saved: [String: Position] = [:]   // "season:episode" ("" for a film)
    @State private var season = 1
    @State private var nextUp: (Int, Int)?
    @State private var similar: [Meta] = []
    @State private var hasTrailer = false
    @State private var picking = false
    @State private var streamList: [Ranked]?

    private var mm: Meta { m ?? meta }
    private func key(_ s: Int?, _ e: Int?) -> String { "\(s.map(String.init) ?? ""):\(e.map(String.init) ?? "")" }
    private var seasons: [Int] { Array(Set(mm.videos.map(\.season))).sorted() }
    private var episodes: [Video] { mm.videos.filter { $0.season == season } }

    /// The episode Play starts: the one you're in, else Trakt's next, else the first you haven't finished.
    private var current: Video? {
        guard mm.isSeries else { return nil }
        if let p = store.progress[mm.id], let s = p.season, let e = p.episode,
           let v = mm.videos.first(where: { $0.season == s && $0.episode == e }) { return v }
        if let n = nextUp, let v = mm.videos.first(where: { $0.season == n.0 && $0.episode == n.1 }) { return v }
        return mm.videos.first { !(saved[key($0.season, $0.episode)]?.finished ?? false) } ?? mm.videos.first
    }

    private var playLabel: String {
        if mm.isSeries {
            guard let v = current else { return "Play" }
            let sp = saved[key(v.season, v.episode)]
            return sp?.resumable == true ? "Resume S\(v.season) E\(v.episode) · \(clock(sp!.position))" : "Play S\(v.season) E\(v.episode)"
        }
        let sp = saved[key(nil, nil)]
        return sp?.resumable == true ? "Resume · \(clock(sp!.position))" : "Play"
    }

    enum Btn: Hashable { case play, stream, trailer, watchlist, watched, more }
    @FocusState private var btn: Btn?
    @State private var showMore = false

    private var caption: String {
        switch btn {
        case .stream: return "Choose stream"
        case .trailer: return "Watch trailer"
        case .watchlist: return store.watchlist.contains(mm.id) ? "On your watchlist" : "Add to watchlist"
        case .watched: return store.watched[mm.id] == "done" ? "Watched · select to undo" : "Mark as watched"
        case .more: return "Mark seasons or the whole show"
        default: return " "
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(url: mm.backdropURL, kenBurns: true).ignoresSafeArea()
            LinearGradient(colors: [Theme.bg.opacity(0.96), Theme.bg.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing).ignoresSafeArea()
            LinearGradient(colors: [Theme.bg, Theme.bg.opacity(0.25), .clear], startPoint: .bottom, endPoint: .top).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
              VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 16) {
                    TitleArt(meta: mm, height: 130, width: 560).padding(.top, 70)
                    HStack(spacing: 18) {
                        Text(mm.metaLine).foregroundStyle(.white.opacity(0.75))
                        if let line = store.release[mm.id]?.line { Text(line).foregroundStyle(Theme.accent) }
                    }
                    .font(.ember(21, .medium))
                    if let p = store.progress[mm.id] {
                        Text(p.line).font(.ember(21, .semibold)).foregroundStyle(Theme.accent)
                    }
                    Text(mm.description).font(.ember(22)).foregroundStyle(.white.opacity(0.9)).lineLimit(3)
                        .frame(maxWidth: 860, alignment: .leading)
                    HStack(spacing: 20) {
                        Button { play() } label: { Label(playLabel, systemImage: "play.fill") }
                            .buttonStyle(EmberButtonStyle(primary: true)).focused($btn, equals: .play)
                        Button { chooseStream() } label: { Image(systemName: "list.bullet") }
                            .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .stream)
                        if hasTrailer {
                            Button { store.playTrailer(mm) } label: { Image(systemName: "film") }
                                .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .trailer)
                        }
                        Button { Task { await store.toggleWatchlist(mm) } } label: {
                            Image(systemName: store.watchlist.contains(mm.id) ? "checkmark" : "plus")
                        }
                        .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .watchlist)
                        if mm.isSeries {
                            Button { showMore = true } label: { Image(systemName: "ellipsis") }
                                .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .more)
                        } else {
                            let done = store.watched[mm.id] == "done"
                            Button { Task { await store.markTitle(mm, watched: !done) } } label: {
                                Image(systemName: done ? "checkmark.circle.fill" : "checkmark.circle")
                            }
                            .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .watched)
                        }
                    }
                    .padding(.top, 14)
                    Text(caption).font(.ember(19)).foregroundStyle(Theme.muted).animation(nil, value: btn)
                    if mm.isSeries && !mm.videos.isEmpty { episodesSection }
                }
                .padding(.horizontal, 90)
                if !similar.isEmpty {
                    PosterRow(row: RowData(id: "similar", title: "You may also like", kind: nil, metas: similar, top: false))
                }
              }
              .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .background(Theme.bg)
        .task { await load() }
        .defaultFocus($btn, .play)
        .confirmationDialog(mm.name, isPresented: $showMore) {
            let inSeason = episodes.filter(\.aired)
            let seasonDone = !inSeason.isEmpty && inSeason.allSatisfy { saved[key($0.season, $0.episode)]?.finished == true }
            Button(seasonDone ? "Mark season \(season) unwatched" : "Mark season \(season) watched") {
                Task { await store.markEpisodes(mm, inSeason, watched: !seasonDone); await loadSaved() }
            }
            Button(store.watched[mm.id] == "done" ? "Mark the whole show unwatched" : "Mark the whole show watched") {
                Task { await store.markTitle(mm, watched: store.watched[mm.id] != "done"); await loadSaved() }
            }
        }
        .sheet(isPresented: $picking) {
            StreamPicker(streams: streamList) { r in
                picking = false
                let v = current
                let sp = mm.isSeries ? v.flatMap { saved[key($0.season, $0.episode)] } : saved[key(nil, nil)]
                store.playChosen(mm, season: v?.season, episode: v?.episode, epTitle: v?.title ?? "",
                                 start: sp?.resumable == true ? sp!.position : 0, stream: r)
            }
        }
        .onChange(of: store.progressVersion) { _, _ in Task { await loadSaved() } }
    }

    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.self) { s in
                        Button { season = s } label: { Text("Season \(s)") }
                            .buttonStyle(TabTextStyle(selected: s == season))
                    }
                    Text("\(episodes.count) episodes").font(.ember(19)).foregroundStyle(Theme.muted).padding(.leading, 20).padding(.bottom, 12)
                }
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .focusSection()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(episodes) { v in episodeCard(v) }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.top, 26)
    }

    private func episodeCard(_ v: Video) -> some View {
        let sp = saved[key(v.season, v.episode)]
        let isCurrent = current?.season == v.season && current?.episode == v.episode
        return VStack(alignment: .leading, spacing: 8) {
            Button { playEpisode(v) } label: {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: v.thumbnail ?? mm.backdropURL) { Theme.card }
                    .frame(width: 320, height: 180)
                    .clipped()
                    if sp?.finished == true {
                        VStack { HStack { Spacer(); WatchBadge(state: "done") }; Spacer() }
                    } else if let sp, sp.percent > 1 {
                        ProgressBar(fraction: sp.percent / 100).padding(10)
                    }
                    if !v.aired {
                        Text("Not out yet").font(.ember(16, .bold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: Capsule()).padding(10)
                    }
                }
                .frame(width: 320, height: 180)
            }
            .buttonStyle(.card)
            .contextMenu {
                if sp?.finished == true {
                    Button("Mark as unwatched") { Task { await store.markEpisodes(mm, [v], watched: false); await loadSaved() } }
                } else {
                    Button("Mark as watched") { Task { await store.markEpisodes(mm, [v], watched: true); await loadSaved() } }
                    let upTo = mm.videos.filter { ($0.season, $0.episode) <= (v.season, v.episode) && $0.aired }
                    Button("Mark watched up to here") { Task { await store.markEpisodes(mm, upTo, watched: true); await loadSaved() } }
                }
            }
            HStack(spacing: 8) {
                Text("\(v.episode)").font(.ember(19, .bold)).foregroundStyle(isCurrent ? Theme.accent : Theme.muted)
                Text(v.title).font(.ember(20, .semibold)).lineLimit(1)
            }
            .frame(width: 320, alignment: .leading)
            if let d = v.released {
                Text(d.formatted(date: .abbreviated, time: .omitted)).font(.ember(17)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func load() async {
        let full = await MetaCache.shared.full(meta)
        m = full
        store.wantRelease(full)
        let kind = full.isSeries ? "series" : "movie"
        Task {
            if let r = try? await API.feedGet("/similar/\(kind)/\(full.id)", timeout: 30) {
                similar = r.arr("metas").map { Meta($0, type: kind) }.filter { !$0.id.isEmpty && $0.id != full.id }
            }
        }
        Task {
            if let r = try? await API.feedGet("/trailer/\(kind)/\(full.id)", timeout: 15), r.str("yt") != nil { hasTrailer = true }
        }
        await loadSaved()
        if full.isSeries, store.progress[full.id] == nil,
           let n = try? await API.feedGet("/next/\(full.id)", timeout: 6), let s = n.int("season"), let e = n.int("episode") {
            nextUp = (s, e)
        }
        if let v = current { season = v.season } else if let first = seasons.first { season = first }
    }

    private func loadSaved() async {
        guard let j = try? await API.feedGet("/progress/\(meta.id)", timeout: 6) else { return }
        var out: [String: Position] = [:]
        for p in j.arr("positions").map(Position.init) { out[key(p.season, p.episode)] = p }
        saved = out
    }

    private func chooseStream() {
        if mm.isSeries && current == nil { return store.say("Pick an episode first.") }
        streamList = nil
        picking = true
        let v = current
        Task { streamList = await store.streams(mm, season: v?.season, episode: v?.episode) ?? [] }
    }

    private func play() {
        if mm.isSeries {
            guard let v = current else { return store.say("Pick an episode first.") }
            playEpisode(v)
        } else {
            let sp = saved[key(nil, nil)]
            store.playBest(mm, start: sp?.resumable == true ? sp!.position : 0)
        }
    }

    private func playEpisode(_ v: Video) {
        let sp = saved[key(v.season, v.episode)]
        store.playBest(mm, season: v.season, episode: v.episode, epTitle: v.title, start: sp?.resumable == true ? sp!.position : 0)
    }
}

/// Every stream, best first, with what it is (4K, Dolby Vision, Atmos...), its speed test and its name.
struct StreamPicker: View {
    let streams: [Ranked]?
    let pick: (Ranked) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose stream").font(.ember(40, .bold))
            if let streams {
                if streams.isEmpty { Text("No streams found.").foregroundStyle(Theme.muted) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(streams.indices, id: \.self) { i in
                            let r = streams[i]
                            Button { pick(r) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        ForEach(r.badges, id: \.self) { b in
                                            Text(b).font(.ember(17, .bold)).padding(.horizontal, 9).padding(.vertical, 3)
                                                .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(Theme.ink)
                                        }
                                        if let mb = r.mbps { Text("\(Int(mb)) Mbit/s").font(.ember(17)).foregroundStyle(Theme.muted) }
                                        if !r.ok { Text("failed speed test").font(.ember(17)).foregroundStyle(.red.opacity(0.8)) }
                                    }
                                    Text(r.label).font(.ember(21)).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            } else {
                HStack(spacing: 18) { ProgressView(); Text("Finding and testing streams…").foregroundStyle(Theme.muted) }
                Spacer()
            }
        }
        .padding(60)
        .frame(width: 1300, height: 900, alignment: .topLeading)
    }
}
