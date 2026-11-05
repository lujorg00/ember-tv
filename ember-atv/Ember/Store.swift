import Foundation
import SwiftUI

struct RowData: Identifiable {
    let id: String
    let title: String
    let kind: String?      // "Films" / "Series" when the name doesn't already say
    let metas: [Meta]
    let top: Bool          // a top-10 list: big rank numbers
}

struct CWItem: Identifiable {
    let id: String
    let meta: Meta
    let label: String      // "▶ S2 · E6 · 10m left", "Next · S3 · E1"
    let art: URL?
    let percent: Double?
}

struct LoadState {
    var art: URL?
    var logo: URL?
    var title: String
    var sub: String
    var steps: [String]
    var step: Int = 0
    var badges: [String] = []
    var note: String = ""
}

struct PlaySession: Identifiable {
    var id = UUID()
    let meta: Meta
    let season: Int?
    let episode: Int?
    let epTitle: String
    var start: Double
    let ranked: [Ranked]
    var n: Int = 0
    var stream: Ranked { ranked[n] }
    var next: Video? { (season != nil && episode != nil) ? meta.next(after: season!, episode!) : nil }
    var title: String {
        guard let s = season, let e = episode else { return meta.name }
        return "\(meta.name)  ·  S\(s) E\(e)\(epTitle.isEmpty ? "" : "  ·  " + epTitle)"
    }
}

enum PlayEnd {
    case stopped
    case next
    case failed(String, Double)   // why, where it got to
}

/// Everything the screens share. Lives on the main thread.
@MainActor
final class Store: ObservableObject {
    @Published var aio = UserDefaults.standard.string(forKey: "aio") ?? ""
    @Published var progress: [String: Progress] = [:]
    @Published var watched: [String: String] = [:]      // imdb -> "done" | "partial"
    @Published var hero: [Meta] = []
    @Published var rows: [RowData] = []
    @Published var cw: [CWItem] = []
    @Published var homeLoaded = false
    @Published var toast: String?
    @Published var loading: LoadState?
    @Published var playing: PlaySession?
    @Published var progressVersion = 0                  // bumps after playback, so open pages refresh

    private var cwCats: [JSON] = []
    private var picking = false

    func say(_ msg: String) {
        toast = msg
        Task { try? await Task.sleep(nanoseconds: 4_500_000_000); if toast == msg { toast = nil } }
    }

    // MARK: - loading

    /// The AIOStreams link comes from lucapi (Ember PC shares it there), so nothing has to be typed on the remote.
    func fetchShared() async {
        guard let s = try? await API.feedGet("/settings/shared", timeout: 6), let link = s.str("aio") else { return }
        if link != aio {
            aio = link
            UserDefaults.standard.set(link, forKey: "aio")
        }
    }

    func loadProgress() async {
        async let w = try? API.feedGet("/watched", timeout: 8)
        if let p = try? await API.feedGet("/progress", timeout: 8) {
            var out: [String: Progress] = [:]
            for (k, v) in p.obj("items") { if let j = v as? JSON { out[k] = Progress(j) } }
            progress = out
        }
        if let wj = await w {
            var out: [String: String] = [:]
            for (k, v) in wj.obj("items") { if let s = v as? String { out[k] = s } }
            watched = out
        }
    }

    func loadHome() async {
        await fetchShared()
        async let prog: Void = loadProgress()
        let man = try? await API.feedGet("/addon/manifest.json", timeout: 20)
        let cats = (man?.arr("catalogs") ?? []).filter { c in !c.arr("extra").contains { $0.bool("isRequired") } }
        if man == nil { say("Couldn't reach lucapi at \(API.feed). Check the address in Settings.") }
        let lay = (try? await API.feedGet("/browse/tiles", timeout: 90)) ?? [:]
        await prog

        func find(_ x: JSON) -> JSON { cats.first { $0.str("type") == x.str("type") && $0.str("id") == x.str("id") } ?? x }
        let homeList = lay.arr("home").isEmpty ? cats : lay.arr("home").map(find)
        let heroCats = lay.arr("hero").map(find)
        func named(_ c: JSON, _ pattern: String) -> Bool {
            (c.str("name") ?? "").range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let isCont = { (c: JSON) in named(c, "pick up|left off|continue") }
        let isTop = { (c: JSON) in named(c, "\\btop\\b") }
        cwCats = homeList.filter(isCont)
        let ordered: [(JSON, Bool)] = homeList.filter { isTop($0) && !isCont($0) }.map { ($0, true) }
            + homeList.filter { !isTop($0) && !isCont($0) }.map { ($0, false) }

        // every row at once; shown in their order
        let built = await withTaskGroup(of: (Int, RowData?).self, returning: [RowData].self) { g in
            for (i, (c, top)) in ordered.enumerated() {
                g.addTask {
                    let metas = await API.catalog(c)
                    guard !metas.isEmpty else { return (i, nil) }
                    let name = c.str("name") ?? c.str("id") ?? ""
                    let says = name.range(of: "\\b(films?|movies?|series|shows?|tv)\\b", options: [.regularExpression, .caseInsensitive]) != nil
                    let kind: String? = says ? nil : (c.str("type") == "movie" ? "Films" : "Series")
                    return (i, RowData(id: "\(c.str("type") ?? ""):\(c.str("id") ?? "")", title: name, kind: kind, metas: metas, top: top))
                }
            }
            var out = [RowData?](repeating: nil, count: ordered.count)
            for await (i, r) in g { out[i] = r }
            return out.compactMap { $0 }
        }
        rows = built

        // the slideshow: your hero list, or the top two of each row
        var heroItems: [Meta] = []
        for c in heroCats { heroItems += await API.catalog(c) }
        if heroItems.isEmpty { for k in 0..<2 { for r in built where r.metas.count > k { heroItems.append(r.metas[k]) } } }
        var seen = Set<String>()
        hero = Array(heroItems.filter { seen.insert($0.id).inserted }.prefix(10))
        homeLoaded = true
        await loadContinue()
    }

    /// Continue watching: part-way through (any device), newest first, then what's next from your addon's list.
    func loadContinue() async {
        var items: [(Meta, Progress?)] = []
        var seen = Set<String>()
        for (id, p) in progress.sorted(by: { $0.value.pausedAt > $1.value.pausedAt }) {
            items.append((Meta(["id": id, "type": p.type]), p))
            seen.insert(id)
        }
        let gone = (try? await API.feedGet("/progress/dismissed", timeout: 5))?.obj("dismissed") ?? [:]
        for c in cwCats {
            for m in await API.catalog(c) where !seen.contains(m.id) && gone[m.id] == nil {
                items.append((m, nil))
                seen.insert(m.id)
            }
        }
        let list = Array(items.prefix(20))
        let built = await withTaskGroup(of: (Int, CWItem).self, returning: [CWItem].self) { g in
            for (i, (m, p)) in list.enumerated() {
                g.addTask {
                    let full = await MetaCache.shared.full(m)
                    var season = p?.season, episode = p?.episode
                    var label = ""
                    if let p {
                        let left = p.minutesLeft.map { $0 <= 10 ? " · \($0)m left" : "" } ?? ""
                        label = (full.isSeries && season != nil ? "▶ S\(season!) · E\(episode!)" : "▶ Resume") + left
                    } else if full.isSeries, let n = try? await API.feedGet("/next/\(m.id)", timeout: 6), let s = n.int("season") {
                        season = s
                        episode = n.int("episode")
                        label = "Next · S\(s) · E\(episode ?? 1)"
                    }
                    let ep = full.videos.first { $0.season == season && $0.episode == episode }
                    return (i, CWItem(id: m.id, meta: full, label: label, art: ep?.thumbnail ?? full.backdropURL, percent: p?.percent))
                }
            }
            var out = [CWItem?](repeating: nil, count: list.count)
            for await (i, it) in g { out[i] = it }
            return out.compactMap { $0 }
        }
        cw = built
    }

    func refreshAfterPlay() {
        Task {
            await loadProgress()
            await loadContinue()
            progressVersion += 1
        }
    }

    // MARK: - changes (all saved on the Pi, and on to Trakt)

    func dismiss(_ id: String) {
        cw.removeAll { $0.id == id }
        progress[id] = nil
        Task {
            do { try await API.post("/progress/dismiss", ["imdb": id]) } catch { say("Couldn't reach lucapi: \(error.localizedDescription)") }
        }
    }

    /// A whole film or show, from its poster.
    func markTitle(_ m: Meta, watched on: Bool) async {
        var eps: [[Int]] = []
        if m.isSeries {
            let full = await MetaCache.shared.full(m)
            eps = full.videos.filter(\.aired).map { [$0.season, $0.episode] }
            if eps.isEmpty { say("Couldn't find its episodes to mark."); return }
        }
        do {
            try await API.post("/progress/watched", ["imdb": m.id, "type": m.isSeries ? "series" : "movie", "watched": on, "episodes": eps, "all": m.isSeries])
            watched[m.id] = on ? "done" : nil
            if on { progress[m.id] = nil }
            say(on ? "Marked \(m.name) as watched." : "\(m.name) is unwatched again.")
            await loadContinue()
            progressVersion += 1
        } catch { say("Couldn't update lucapi: \(error.localizedDescription)") }
    }

    func markEpisodes(_ m: Meta, _ eps: [Video], watched on: Bool) async {
        do {
            try await API.post("/progress/watched", ["imdb": m.id, "type": "series", "watched": on, "all": false,
                                                     "episodes": eps.map { [$0.season, $0.episode] }])
            progressVersion += 1
            await loadProgress()
        } catch { say("Couldn't update lucapi: \(error.localizedDescription)") }
    }

    // MARK: - playing

    /// The best stream lucapi's picker finds (it tests the top few for speed); the next best if that one fails.
    func playBest(_ m: Meta, season: Int? = nil, episode: Int? = nil, epTitle: String = "", start: Double = 0) {
        guard !picking else { return }
        guard !aio.isEmpty else { say("No AIOStreams link yet: open Ember PC once, it shares the link through lucapi."); return }
        picking = true
        Task {
            defer { picking = false }
            let full = await MetaCache.shared.full(m)
            var sub = start > 0 ? "from \(clock(start))" : ""
            if let s = season, let e = episode { sub = "S\(s) · E\(e)\(epTitle.isEmpty ? "" : " · " + epTitle)\(start > 0 ? "  ·  from " + clock(start) : "")" }
            loading = LoadState(art: full.backdropURL, logo: full.logoURL, title: full.name, sub: sub,
                                steps: ["Finding streams", "Testing the best ones for speed", "Starting playback"])
            let stepper = Task { try? await Task.sleep(nanoseconds: 1_800_000_000); if loading?.step == 0 { loading?.step = 1 } }
            let sid = full.isSeries ? "\(full.id):\(season ?? 1):\(episode ?? 1)" : full.id
            let runtime = full.runtimeMinutes.map(String.init) ?? ""
            let path = "/pick/\(full.isSeries ? "series" : "movie")/\(API.q(sid))?aio=\(API.q(aio))&quality=4k&runtime=\(runtime)&passthrough=0"
            let res: JSON
            do { res = try await API.feedGet(path, timeout: 60) } catch {
                stepper.cancel(); loading = nil
                say("Couldn't ask lucapi for the best stream: \(error.localizedDescription)")
                return
            }
            stepper.cancel()
            let ranked = res.arr("ranked").map(Ranked.init).filter { $0.ok && !$0.url.isEmpty }
            guard let best = ranked.first else { loading = nil; say("No working streams found for this one."); return }
            loading?.step = 2
            loading?.badges = best.badges
            loading?.note = (best.mbps.map { "tested \(Int($0)) Mbit/s · " } ?? "") + best.label
            playing = PlaySession(meta: full, season: season, episode: episode, epTitle: epTitle, start: start, ranked: ranked)
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            loading = nil
        }
    }

    func playerEnded(_ how: PlayEnd) {
        guard let s = playing else { return }
        playing = nil
        switch how {
        case .stopped:
            refreshAfterPlay()
        case .next:
            refreshAfterPlay()
            if let n = s.next {
                Task { try? await Task.sleep(nanoseconds: 700_000_000); playBest(s.meta, season: n.season, episode: n.episode, epTitle: n.title) }
            }
        case .failed(let why, let at):
            API.fire("/pick/failed", ["text": s.stream.text, "why": why])
            let limit = min(4, s.ranked.count)
            guard s.n + 1 < limit else { refreshAfterPlay(); say("None of the streams would play properly."); return }
            var ns = s
            ns.id = UUID()
            ns.n += 1
            if at > 20 { ns.start = at }
            loading = LoadState(art: s.meta.backdropURL, logo: s.meta.logoURL, title: s.meta.name, sub: "That stream \(why)",
                                steps: ["Switching to the next best (\(ns.n + 1) of \(limit))", "Starting playback"], step: 1,
                                badges: ns.stream.badges, note: ns.stream.label)
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                playing = ns
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                loading = nil
            }
        }
    }
}
