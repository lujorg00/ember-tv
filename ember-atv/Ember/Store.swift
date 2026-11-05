import Foundation
import SwiftUI
import UIKit

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
    var trailer = false
    var stream: Ranked { ranked[n] }
    var next: Video? { (season != nil && episode != nil) ? meta.next(after: season!, episode!) : nil }
    var title: String {
        if trailer { return "\(meta.name)  ·  Trailer" }
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
    @Published var release: [String: Release] = [:]
    @Published var watchlist: Set<String> = []
    @Published var upcoming: [Upcoming] = []
    @Published var tileGroups: [TileGroup] = []

    private var cats: [JSON] = []
    private var heroCats: [JSON] = []
    private var aioCats: [JSON]?
    private var relQueue = Set<String>()
    private var relAsked = Set<String>()
    private var relTask: Task<Void, Never>?

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
        heroCats = lay.arr("hero").map(find)
        self.cats = cats
        tileGroups = lay.arr("groups").map { g in
            let style = g.str("style") ?? "art"
            return TileGroup(title: g.str("title") ?? "", style: style, tiles: g.arr("tiles").map { Tile($0, style: style) })
        }
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
        async let more: Void = loadExtras()
        await loadContinue()
        await more
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

    /// Your watchlist and this week's new episodes (the New This Week panel on the hero).
    func loadExtras() async {
        async let w = try? API.feedGet("/watchlist", timeout: 10)
        if let u = try? await API.feedGet("/upcoming?days=6", timeout: 10) {
            let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86400)
            upcoming = u.arr("episodes").compactMap(Upcoming.init).filter { $0.airs >= start }.sorted { $0.airs < $1.airs }
        }
        if let wj = await w { watchlist = Set((wj["items"] as? [String]) ?? []) }
    }

    // MARK: - films and series pages

    /// AIOStreams' own lists (for the Disney+, Apple TV+ and Amazon charts).
    private func aioCatalogs() async -> [JSON] {
        if let a = aioCats { return a }
        guard !aio.isEmpty else { return [] }
        let base = aio.components(separatedBy: "/manifest.json").first ?? aio
        let man = try? await API.get("\(base)/manifest.json", timeout: 20)
        let list = (man?.arr("catalogs") ?? []).filter { c in !c.arr("extra").contains { $0.bool("isRequired") } }.map { c -> JSON in
            var x = c; x["aio"] = base; return x
        }
        if man != nil { aioCats = list }
        return list
    }

    /// A list from your addon (through lucapi) or from AIOStreams.
    nonisolated static func anyCatalog(_ c: JSON) async -> [Meta] {
        guard let base = c.str("aio") else { return await API.catalog(c) }
        guard let type = c.str("type"), let id = c.str("id"),
              let j = try? await API.get("\(base)/catalog/\(type)/\(API.q(id)).json", timeout: 20) else { return [] }
        return j.arr("metas").map { Meta($0, type: type) }.filter { !$0.id.isEmpty }
    }

    /// Films or Series: Trending Now, New for you, then the Top 10s of each service (the tiles follow on the page).
    func browse(_ type: String) async -> (hero: [Meta], rows: [RowData]) {
        for _ in 0..<400 where !homeLoaded { try? await Task.sleep(nanoseconds: 300_000_000) }   // Home is loading the lists
        let kind = type == "movie" ? "Films" : "Series"
        let mine = cats.filter { $0.str("type") == type }
        let theirs = await aioCatalogs().filter { $0.str("type") == type }
        func find(_ pattern: String, _ pools: [JSON]...) -> JSON? {
            for p in pools {
                if let c = p.first(where: { ($0.str("name") ?? "").trimmingCharacters(in: .whitespaces)
                    .range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }) { return c }
            }
            return nil
        }
        let plan: [(String, JSON?, Bool)] = [
            ("Trending Now", find("trending", mine, theirs), false),
            ("New \(kind) For You", find("^new .*for you", mine), false),
            ("Netflix Top \(kind)", find("netflix top", mine, theirs), true),
            ("Disney+ Top \(kind)", find("disney\\s*\\+", theirs, mine), true),
            ("Apple TV+ Top \(kind)", find("apple tv\\s*\\+", theirs, mine), true),
            ("Amazon Top \(kind)", find("prime video|amazon", theirs, mine), true),
        ]
        let wanted = plan.compactMap { p in p.1.map { (p.0, $0, p.2) } }
        let built = await withTaskGroup(of: (Int, RowData?).self, returning: [RowData].self) { g in
            for (i, (name, c, top)) in wanted.enumerated() {
                g.addTask {
                    let metas = await Store.anyCatalog(c).map { m -> Meta in
                        m.type == type ? m : Meta(["id": m.id, "type": type, "name": m.name, "poster": m.poster as Any, "background": m.background as Any], type: type)
                    }
                    return (i, metas.isEmpty ? nil : RowData(id: "\(type):\(name)", title: name, kind: nil, metas: metas, top: top))
                }
            }
            var out = [RowData?](repeating: nil, count: wanted.count)
            for await (i, r) in g { out[i] = r }
            return out.compactMap { $0 }
        }
        var heroItems: [Meta] = []
        for c in heroCats where c.str("type") == type { heroItems += await API.catalog(c) }
        if heroItems.isEmpty { for k in 0..<2 { for r in built where r.metas.count > k { heroItems.append(r.metas[k]) } } }
        var seen = Set<String>()
        return (Array(heroItems.filter { seen.insert($0.id).inserted }.prefix(10)), built)
    }

    /// The boxes for Films or Series (directors and franchises are for films).
    func tiles(for type: String) -> [TileGroup] {
        tileGroups.compactMap { g in
            if type == "series" && (g.style == "person" || g.title == "Franchises") { return nil }
            let list = g.tiles.filter { $0.types.isEmpty || $0.types.contains(type) }
            return list.isEmpty ? nil : TileGroup(title: g.title, style: g.style, tiles: list)
        }
    }

    // MARK: - release labels

    /// Asks lucapi which recent titles are only in cinemas or not out yet (batched, a moment after they appear).
    func wantRelease(_ m: Meta) {
        guard m.id.hasPrefix("tt"), !relAsked.contains(m.id) else { return }
        if let y = Int(m.year), y < Calendar.current.component(.year, from: Date()) - 1 { return }
        relAsked.insert(m.id)
        relQueue.insert(m.id)
        relTask?.cancel()
        relTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let ids = Array(relQueue.prefix(150))
            relQueue.subtract(ids)
            guard let r = try? await API.post("/release", ["ids": ids], timeout: 20) else { return }
            let items = r.obj("items")
            for i in ids { if let j = items[i] as? JSON { release[i] = Release(j) } }
        }
    }

    // MARK: - watchlist and trailers

    func toggleWatchlist(_ m: Meta) async {
        let add = !watchlist.contains(m.id)
        do {
            let r = try await API.post("/watchlist", ["imdb": m.id, "type": m.isSeries ? "series" : "movie", "add": add], timeout: 15)
            let on = r["on"] as? Bool ?? add
            if on { watchlist.insert(m.id) } else { watchlist.remove(m.id) }
            say(on ? "Added \(m.name) to your watchlist." : "Took \(m.name) off your watchlist.")
        } catch { say("Couldn't change your watchlist: \(error.localizedDescription)") }
    }

    /// The trailer, in Ember's own player (lucapi finds a stream with yt-dlp); the YouTube app if that can't be done.
    func playTrailer(_ m: Meta) {
        guard !picking else { return }
        picking = true
        Task {
            defer { picking = false }
            let path = "/trailer/\(m.isSeries ? "series" : "movie")/\(m.id)"
            let r = try? await API.feedGet(path + "/play", timeout: 70)
            if let url = r?.str("url") {
                playing = PlaySession(meta: m, season: nil, episode: nil, epTitle: "Trailer", start: 0,
                                      ranked: [Ranked(["url": url, "name": "Trailer"])], trailer: true)
                return
            }
            var yt = r?.str("yt") ?? ""
            if yt.isEmpty, let j = try? await API.feedGet(path, timeout: 15) { yt = j.str("yt") ?? "" }
            guard !yt.isEmpty else { say("No trailer found for \(m.name)."); return }
            for link in ["youtube://watch/\(yt)", "youtube://www.youtube.com/watch?v=\(yt)", "https://www.youtube.com/watch?v=\(yt)"] {
                if let u = URL(string: link), await UIApplication.shared.open(u, options: [:]) { return }
            }
            say("Couldn't open the trailer.")
        }
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
            let res: JSON
            do { res = try await API.feedGet(pickPath(full, season, episode), timeout: 60) } catch {
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

    private func pickPath(_ m: Meta, _ season: Int?, _ episode: Int?) -> String {
        let sid = m.isSeries ? "\(m.id):\(season ?? 1):\(episode ?? 1)" : m.id
        let runtime = m.runtimeMinutes.map(String.init) ?? ""
        return "/pick/\(m.isSeries ? "series" : "movie")/\(API.q(sid))?aio=\(API.q(aio))&quality=4k&runtime=\(runtime)&passthrough=0"
    }

    /// Every stream for this film or episode, best first (as Ember PC's "Choose stream").
    func streams(_ m: Meta, season: Int?, episode: Int?) async -> [Ranked]? {
        guard !aio.isEmpty else { say("No AIOStreams link yet: open Ember PC once, it shares the link through lucapi."); return nil }
        let full = await MetaCache.shared.full(m)
        guard let r = try? await API.feedGet(pickPath(full, season, episode), timeout: 60) else { say("Couldn't reach lucapi for the streams."); return nil }
        return r.arr("ranked").map(Ranked.init).filter { !$0.url.isEmpty }
    }

    /// One you picked: played as it is, no switching to another if it stalls.
    func playChosen(_ m: Meta, season: Int?, episode: Int?, epTitle: String, start: Double, stream: Ranked) {
        Task {
            let full = await MetaCache.shared.full(m)
            playing = PlaySession(meta: full, season: season, episode: episode, epTitle: epTitle, start: start, ranked: [stream])
        }
    }

    func playerEnded(_ how: PlayEnd) {
        guard let s = playing else { return }
        playing = nil
        switch how {
        case .stopped:
            if !s.trailer { refreshAfterPlay() }
        case .next where s.trailer:
            break
        case .next:
            refreshAfterPlay()
            if let n = s.next {
                Task { try? await Task.sleep(nanoseconds: 700_000_000); playBest(s.meta, season: n.season, episode: n.episode, epTitle: n.title) }
            }
        case .failed(_, _) where s.trailer:
            say("The trailer wouldn't play.")
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
