import SwiftUI

/// A film or show: backdrop, logo, where you are, Play/Resume, and for a show its seasons and episodes.
struct DetailView: View {
    @EnvironmentObject var store: Store
    let meta: Meta
    @State private var m: Meta?
    @State private var saved: [String: Position] = [:]   // "season:episode" ("" for a film)
    @State private var season = 1
    @State private var nextUp: (Int, Int)?

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

    var body: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(url: mm.backdropURL).ignoresSafeArea()
            LinearGradient(colors: [Theme.bg.opacity(0.97), Theme.bg.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing).ignoresSafeArea()
            LinearGradient(colors: [Theme.bg, Theme.bg.opacity(0.3), .clear], startPoint: .bottom, endPoint: .top).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    TitleArt(meta: mm, height: 190, width: 760).padding(.top, 60)
                    Text(mm.metaLine).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                    if let p = store.progress[mm.id] {
                        Text(p.line).font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    Text(mm.description).font(.callout).lineLimit(4).frame(maxWidth: 1000, alignment: .leading)
                    HStack(spacing: 24) {
                        Button { play() } label: { Label(playLabel, systemImage: "play.fill") }
                        if !mm.isSeries {
                            let done = store.watched[mm.id] == "done"
                            Button {
                                Task { await store.markTitle(mm, watched: !done) }
                            } label: { Label(done ? "Watched" : "Mark watched", systemImage: done ? "checkmark.circle.fill" : "checkmark.circle") }
                        }
                    }
                    .padding(.top, 10)
                    if mm.isSeries && !mm.videos.isEmpty { episodesSection }
                }
                .padding(.horizontal, 90)
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .background(Theme.bg)
        .task { await load() }
        .onChange(of: store.progressVersion) { _, _ in Task { await loadSaved() } }
    }

    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(seasons, id: \.self) { s in
                        Button { season = s } label: {
                            Text("Season \(s)").fontWeight(s == season ? .bold : .regular)
                                .foregroundStyle(s == season ? Theme.accent : .primary)
                        }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 36) {
                    ForEach(episodes) { v in episodeCard(v) }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.top, 20)
    }

    private func episodeCard(_ v: Video) -> some View {
        let sp = saved[key(v.season, v.episode)]
        return VStack(alignment: .leading, spacing: 10) {
            Button { playEpisode(v) } label: {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: v.thumbnail ?? mm.backdropURL) { ph in
                        if let img = ph.image { img.resizable().scaledToFill() } else { Theme.card }
                    }
                    .frame(width: 420, height: 236)
                    .clipped()
                    if sp?.finished == true {
                        VStack { HStack { Spacer(); WatchBadge(state: "done") }; Spacer() }
                    } else if let sp, sp.percent > 1 {
                        ProgressBar(fraction: sp.percent / 100).padding(12)
                    }
                    if !v.aired {
                        Text("Not out yet").font(.caption.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.65), in: Capsule()).padding(12)
                    }
                }
                .frame(width: 420, height: 236)
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
                Button("Mark Season \(v.season) watched") {
                    Task { await store.markEpisodes(mm, mm.videos.filter { $0.season == v.season && $0.aired }, watched: true); await loadSaved() }
                }
            }
            Text("E\(v.episode)  \(v.title)").font(.callout.weight(.semibold)).lineLimit(1).frame(width: 420, alignment: .leading)
            if let d = v.released {
                Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private func load() async {
        let full = await MetaCache.shared.full(meta)
        m = full
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
