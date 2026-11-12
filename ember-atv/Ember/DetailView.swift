import SwiftUI

/// A film or show: backdrop, logo, where you are, Play/Resume, and for a show its seasons and episodes.
struct DetailView: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    @State private var m: Meta?
    @State private var saved: [String: Position] = [:]   // "season:episode" ("" for a film)
    @State private var season = 1
    @AppStorage("showSpoilers") private var showSpoilers = false   // off: pictures of episodes you haven't seen are blurred
    @State private var nextUp: (Int, Int)?
    @State private var similar: [Meta] = []
    @State private var scores: [Score] = []
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

    enum Btn: Hashable { case play, stream, together, trailer, watchlist, love, watched, more }
    @FocusState private var btn: Btn?
    @State private var showMore = false
    @State private var ready = false

    private func reveal() {
        guard !ready else { return }
        withAnimation(.easeOut(duration: 0.35)) { ready = true }
    }

    private var caption: String {
        switch btn {
        case .stream: return "Choose stream"
        case .together: return "Watch together: play here and ask your other Ember devices to join in"
        case .trailer: return "Watch trailer"
        case .watchlist: return store.watchlist.contains(mm.id) ? "On your watchlist" : "Add to watchlist"
        case .love: return store.loved.contains(mm.id) ? "Loved · select to take the love off" : "Love it: your recommendations lean towards what you love"
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
                  // the title and what it's about on the left; its scores on the right, where there's room
                  HStack(alignment: .bottom, spacing: 40) {
                    VStack(alignment: .leading, spacing: 16) {
                    TitleArt(meta: mm, height: 130, width: 560).padding(.top, 70)
                    HStack(spacing: 18) {
                        Text(scores.isEmpty ? mm.metaLine : mm.metaLinePlain).foregroundStyle(.white.opacity(0.75))
                        if let line = store.release[mm.id]?.line { Text(line).foregroundStyle(Theme.accent) }
                    }
                    .font(.ember(21, .medium))
                    if let p = store.progress[mm.id] {
                        Text(p.line).font(.ember(21, .semibold)).foregroundStyle(Theme.accent)
                    }
                    Text(mm.description).font(.ember(22)).foregroundStyle(.white.opacity(0.9)).lineLimit(3)
                        .frame(maxWidth: 860, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    if !scores.isEmpty { ScoreChips(items: scores).transition(.opacity) }
                  }
                    HStack(spacing: 20) {
                        Button { play() } label: { Label(playLabel, systemImage: "play.fill") }
                            .buttonStyle(EmberButtonStyle(primary: true)).focused($btn, equals: .play)
                        Button { chooseStream() } label: { Image(systemName: "list.bullet") }
                            .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .stream)
                        Button { store.togetherNext = true; play() } label: { Image(systemName: "person.2.fill") }
                            .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .together)
                        if hasTrailer {
                            Button { store.playTrailer(mm) } label: { Image(systemName: "film") }
                                .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .trailer)
                        }
                        Button { Task { await store.toggleWatchlist(mm) } } label: {
                            Image(systemName: store.watchlist.contains(mm.id) ? "checkmark" : "plus")
                        }
                        .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .watchlist)
                        Button { Task { await store.setLove(mm, !store.loved.contains(mm.id)) } } label: {
                            Image(systemName: store.loved.contains(mm.id) ? "heart.fill" : "heart")
                                .foregroundStyle(store.loved.contains(mm.id) ? Color(red: 1, green: 0.36, blue: 0.42) : Color.primary)
                        }
                        .buttonStyle(EmberButtonStyle(round: true)).focused($btn, equals: .love)
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
        // the page appears whole: picture, logo and words fade in together once the picture is ready
        // (at most 0.6 s; straight away when it was loaded ahead while the poster was selected)
        .opacity(ready ? 1 : 0)
        .scaleEffect(ready ? 1 : 1.012)
        .background(Theme.bg)
        .environment(\.focusMemory, nil)   // its own rows aren't the page you came from
        .task {
            if ImageStore.shared.cached(meta.backdropURL) != nil { reveal() }
            Task { try? await Task.sleep(nanoseconds: 600_000_000); reveal() }
            Task {
                let f = await MetaCache.shared.full(meta)
                async let b = ImageStore.shared.load(optional: f.backdropURL)
                async let l = ImageStore.shared.load(optional: f.logoURL)
                _ = await (b, l)
                reveal()
            }
            await load()
        }
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
                HStack(spacing: 16) {
                    if seasons.count > 8 {
                        // lots of seasons: one button that opens a list, not a long row
                        Menu {
                            ForEach(seasons, id: \.self) { s in
                                Button { season = s } label: { Text(s == 0 ? "Specials" : "Season \(s)") }
                            }
                        } label: {
                            Label(season == 0 ? "Specials" : "Season \(season)", systemImage: "chevron.down")
                        }
                        .buttonStyle(TabTextStyle(selected: true))
                    } else {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: { Text("Season \(s)") }
                                .buttonStyle(TabTextStyle(selected: s == season))
                        }
                    }
                    Text("\(episodes.count) episodes").font(.ember(19)).foregroundStyle(Theme.muted).padding(.leading, 20).padding(.bottom, 12)
                    Button { withAnimation(.easeInOut(duration: 0.3)) { showSpoilers.toggle() } } label: {
                        Label(showSpoilers ? "Spoilers shown" : "Spoilers hidden", systemImage: showSpoilers ? "eye" : "eye.slash")
                    }
                    .buttonStyle(TabTextStyle(selected: false))
                    .padding(.leading, 20)
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
                    .blur(radius: !showSpoilers && sp?.finished != true ? 22 : 0, opaque: true)
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
            if let r = try? await API.feedGet("/ratings/\(kind)/\(full.id)", timeout: 15) {
                let order = ["imdb", "rt", "mc", "tmdb", "trakt"]
                let got = r.arr("items").map(Score.init).sorted { (order.firstIndex(of: $0.src) ?? 9) < (order.firstIndex(of: $1.src) ?? 9) }
                withAnimation(.easeIn(duration: 0.3)) { scores = got }
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
                                .padding(.vertical, 12).padding(.horizontal, 18)
                            }
                            .buttonStyle(RowButtonStyle())
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


// MARK: - scores

struct Score: Identifiable {
    let src: String, label: String, value: String
    var id: String { src }
    init(_ j: JSON) { src = j.str("src") ?? ""; label = j.str("label") ?? ""; value = j.str("value") ?? "" }
}

/// The scores, in a small quiet box on the right: IMDb, Rotten Tomatoes, Metacritic, TMDB, Trakt.
struct ScoreChips: View {
    let items: [Score]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { r in
                HStack(spacing: 12) {
                    Group {
                        switch r.src {
                        case "imdb": Image("brand-imdb").resizable().scaledToFit().frame(height: 20)
                        case "rt":
                            Image("award-tomato").resizable().scaledToFit().frame(height: 22)
                                .hueRotation(.degrees((Int(r.value.filter(\.isNumber)) ?? 100) < 60 ? 70 : 0))
                        case "mc": Image("brand-metacritic").resizable().scaledToFit().frame(height: 22)
                        case "tmdb": Image("brand-tmdb").resizable().scaledToFit().frame(height: 16)
                        case "trakt": Image("brand-trakt").resizable().scaledToFit().frame(height: 22)
                        default: Text(r.label.uppercased()).font(.ember(13, .bold)).tracking(0.6).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(width: 50, alignment: .leading)
                    if r.src == "mc" {
                        // Metacritic's score in its coloured square, after the logo like the others
                        let n = Int(r.value) ?? 0
                        Text(r.value).font(.ember(16, .bold)).foregroundStyle(n >= 40 && n < 61 ? Color.black : .white)
                            .frame(width: 34, height: 26)
                            .background(n >= 61 ? Color(red: 0.23, green: 0.71, blue: 0.29) : n >= 40 ? Color(red: 0.89, green: 0.66, blue: 0) : Color(red: 0.88, green: 0.21, blue: 0.17),
                                        in: RoundedRectangle(cornerRadius: 5))
                    } else { Text(r.value).font(.ember(20, .semibold)) }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Theme.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 8)
    }
}
