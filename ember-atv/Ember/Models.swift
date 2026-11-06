import Foundation

/// Stremio and lucapi JSON is loose (numbers as strings, missing fields), so it's read by hand rather than Codable.
typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s.isEmpty ? nil : s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func dbl(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
    func bool(_ k: String) -> Bool {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.boolValue }
        return false
    }
    func arr(_ k: String) -> [JSON] { (self[k] as? [JSON]) ?? [] }
    func obj(_ k: String) -> JSON { (self[k] as? JSON) ?? [:] }
    func strings(_ k: String) -> [String] { (self[k] as? [String]) ?? [] }
}

private let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let isoPlain = ISO8601DateFormatter()
func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

struct Video: Identifiable, Hashable {
    let id: String
    let season: Int
    let episode: Int
    let title: String
    let thumbnail: URL?
    let released: Date?

    init?(_ j: JSON) {
        guard let s = j.int("season"), let e = j.int("episode") ?? j.int("number") else { return nil }
        season = s
        episode = e
        id = j.str("id") ?? "\(s):\(e)"
        title = j.str("name") ?? j.str("title") ?? ""
        thumbnail = j.str("thumbnail").flatMap(URL.init(string:))
        released = parseDate(j.str("released") ?? j.str("firstAired"))
    }
    var aired: Bool { released.map { $0 <= Date() } ?? true }
}

/// A film or show, as the addons and Cinemeta describe it.
struct Meta: Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String
    let releaseInfo: String
    let rating: String?
    let genres: [String]
    let runtime: String?
    var videos: [Video]

    init(_ j: JSON, type fallback: String = "movie") {
        id = j.str("id") ?? j.str("imdb_id") ?? ""
        type = j.str("type") ?? fallback
        name = j.str("name") ?? ""
        poster = j.str("poster")
        background = j.str("background")
        logo = j.str("logo")
        description = j.str("description") ?? ""
        releaseInfo = j.str("releaseInfo") ?? j.str("year") ?? ""
        rating = j.str("imdbRating")
        genres = j.strings("genres").isEmpty ? j.strings("genre") : j.strings("genres")
        runtime = j.str("runtime")
        videos = j.arr("videos").compactMap(Video.init).filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    /// The addon's entry topped up with Cinemeta's details (logo, episodes...).
    func merged(with full: Meta?) -> Meta {
        guard let f = full, !f.id.isEmpty else { return self }
        var j: JSON = ["id": id, "type": type]
        j["name"] = name.isEmpty ? f.name : name
        j["poster"] = poster ?? f.poster
        j["background"] = f.background ?? background
        j["logo"] = f.logo ?? logo
        j["description"] = f.description.isEmpty ? description : f.description
        j["releaseInfo"] = f.releaseInfo.isEmpty ? releaseInfo : f.releaseInfo
        j["imdbRating"] = f.rating ?? rating
        j["genres"] = f.genres.isEmpty ? genres : f.genres
        j["runtime"] = f.runtime ?? runtime
        var m = Meta(j, type: type)
        m.videos = f.videos.isEmpty ? videos : f.videos
        return m
    }

    var isSeries: Bool { type == "series" }
    var posterURL: URL? {
        if let p = poster, let u = URL(string: p) { return u }
        return id.hasPrefix("tt") ? URL(string: "https://images.metahub.space/poster/medium/\(id)/img") : nil
    }
    var backdropURL: URL? {
        if let b = background, let u = URL(string: b) { return u }
        return id.hasPrefix("tt") ? URL(string: "https://images.metahub.space/background/large/\(id)/img") : nil
    }
    /// The title's logo; when the details don't name one, metahub's (which most titles have).
    var logoURL: URL? {
        if let l = logo, let u = URL(string: l) { return u }
        return id.hasPrefix("tt") ? URL(string: "https://images.metahub.space/logo/medium/\(id)/img") : nil
    }
    var year: String { String(releaseInfo.prefix(4)) }
    var runtimeMinutes: Int? { runtime.flatMap { Int($0.filter(\.isNumber)) } }

    /// "2023– · 51 min · ★ 8.1 · Adventure, Drama"
    /// The line without the score (the details page shows the scores on their own).
    var metaLinePlain: String {
        [releaseInfo.isEmpty ? nil : releaseInfo, runtime, genres.isEmpty ? nil : genres.prefix(3).joined(separator: ", ")]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }
    var metaLine: String {
        [releaseInfo.isEmpty ? nil : releaseInfo, runtime, rating.map { "★ \($0)" },
         genres.isEmpty ? nil : genres.prefix(3).joined(separator: ", ")].compactMap { $0 }.joined(separator: "  ·  ")
    }

    static func == (a: Meta, b: Meta) -> Bool { a.id == b.id && a.type == b.type }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(type) }

    func next(after season: Int, _ episode: Int) -> Video? {
        guard let i = videos.firstIndex(where: { $0.season == season && $0.episode == episode }), i + 1 < videos.count else { return nil }
        return videos[i + 1]
    }
}

/// Where you are in a title (lucapi's /progress: the newest unfinished position from any device).
struct Progress {
    let type: String
    let season: Int?
    let episode: Int?
    let episodeTitle: String
    let position: Double
    let duration: Double?
    let percent: Double
    let pausedAt: String
    let device: String
    let ago: String

    init(_ j: JSON) {
        type = j.str("type") ?? "movie"
        season = j.int("season")
        episode = j.int("episode")
        episodeTitle = j.str("episodeTitle") ?? ""
        position = j.dbl("position") ?? 0
        duration = j.dbl("duration")
        percent = j.dbl("progress") ?? 0
        pausedAt = j.str("pausedAt") ?? ""
        device = j.str("device") ?? ""
        ago = j.str("ago") ?? ""
    }

    var minutesLeft: Int? { duration.map { max(1, Int((($0 - position) / 60).rounded())) } }

    /// "S2 · E6 · 33:25 in, 10 min left · Ember PC, 14h ago"
    var line: String {
        var ep = ""
        if type == "series", let s = season, let e = episode {
            ep = "S\(s) · E\(e)\(episodeTitle.isEmpty ? "" : " · " + episodeTitle)  ·  "
        }
        let left = minutesLeft.map { "\($0) min left" } ?? "\(Int(percent))% through"
        return "\(ep)\(clock(position)) in, \(left)  ·  \(device)\(ago.isEmpty ? "" : ", \(ago) ago")"
    }
}

/// One saved position for an episode (or the film): lucapi's /progress/<imdb>.
struct Position {
    let season: Int?
    let episode: Int?
    let position: Double
    let duration: Double?
    let percent: Double
    let finished: Bool
    let device: String
    let ago: String

    init(_ j: JSON) {
        season = j.int("season")
        episode = j.int("episode")
        position = j.dbl("position") ?? 0
        duration = j.dbl("duration")
        percent = j.dbl("percent") ?? 0
        finished = j.bool("finished")
        device = j.str("device") ?? ""
        ago = j.str("ago") ?? ""
    }
    var resumable: Bool { !finished && position > 20 }
}

/// A stream lucapi's picker chose (best first, the top few tested for speed).
struct Ranked {
    let url: String
    let name: String
    let title: String
    let filename: String
    let mbps: Double?
    let ok: Bool

    init(_ j: JSON) {
        url = j.str("url") ?? ""
        name = j.str("name") ?? ""
        title = j.str("title") ?? ""
        filename = j.str("filename") ?? ""
        let probe = j["probe"] as? JSON
        mbps = probe?.dbl("mbps")
        ok = probe == nil || probe!.bool("ok")
    }
    var text: String { "\(name)\n\(title)\n\(filename)" }
    var label: String { String((filename.isEmpty ? (title.components(separatedBy: "\n").first ?? "") : filename).prefix(90)) }

    /// 4K · HDR · DV · Atmos... from the release name, for the loading screen.
    var badges: [String] {
        let t = text
        func has(_ p: String) -> Bool { t.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        var out: [String] = []
        if has("2160p|\\b4k\\b|uhd") { out.append("4K") } else if has("1080p") { out.append("1080p") } else if has("720p") { out.append("720p") }
        if has("\\bDV\\b|dolby.?vision|\\bDoVi\\b") { out.append("Dolby Vision") }
        if has("HDR10\\+|HDR10plus") { out.append("HDR10+") } else if has("\\bHDR") { out.append("HDR") }
        if has("atmos") { out.append("Atmos") }
        if has("truehd") { out.append("TrueHD") } else if has("DTS-?HD|DTS-?X") { out.append("DTS-HD") } else if has("\\bDTS\\b") { out.append("DTS") }
        else if has("DDP|DD\\+|E-?AC-?3") { out.append("DD+") } else if has("\\bDD\\b|\\bAC-?3\\b") { out.append("DD") }
        return out
    }
}

/// 3725 -> "1:02:05", 205 -> "3:25"
func clock(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    let h = t / 3600, m = t / 60 % 60, x = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
}

/// "In cinemas" / "Coming 13 Nov" (lucapi's /release, from TMDB release dates).
struct Release {
    let s: String          // "cinema", "soon" or ""
    let d: String?         // yyyy-mm-dd: out to watch at home
    init(_ j: JSON) { s = j.str("s") ?? ""; d = j.str("d") }

    private static let inF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_GB"); return f }()
    private func day(_ withYear: Bool) -> String? {
        guard let d, let t = Release.inF.date(from: String(d.prefix(10))) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB")
        f.dateFormat = Calendar.current.component(.year, from: t) == Calendar.current.component(.year, from: Date()) || !withYear ? "d MMM" : "d MMM yyyy"
        return f.string(from: t)
    }
    /// on posters
    var label: String? {
        switch s {
        case "cinema": return "In cinemas"
        case "soon": return day(true).map { "Coming \($0)" } ?? "Coming soon"
        default: return nil
        }
    }
    /// on the details page
    var line: String? {
        switch s {
        case "cinema": return "In cinemas now" + (day(true).map { " · to watch at home from \($0)" } ?? " · not yet out to watch at home")
        case "soon": return "Not out yet" + (day(true).map { " · comes out \($0)" } ?? "")
        default: return nil
        }
    }
}

/// A box on Films and Series (a streaming service, studio, genre, franchise, director, award...): lucapi's /browse/tiles.
struct Tile: Identifiable, Hashable {
    let kind: String
    let id: String
    let title: String
    let image: URL?
    let colour: String?
    let logo: URL?
    let logoKind: String
    let logoMode: String
    let types: [String]
    let style: String

    init(_ j: JSON, style: String) {
        kind = j.str("kind") ?? "cat"
        id = j.str("id") ?? ""
        title = j.str("title") ?? ""
        image = j.str("image").flatMap(URL.init(string:))
        colour = j.str("colour")
        let l = j.str("logo") ?? ""
        logo = l.isEmpty ? nil : URL(string: l.hasPrefix("/") ? API.feed + l : l)
        logoKind = j.str("logo_kind") ?? ""
        logoMode = j.str("logo_mode") ?? ""
        types = j.strings("types")
        self.style = style
    }
    static func == (a: Tile, b: Tile) -> Bool { a.kind == b.kind && a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(kind); h.combine(id) }
}

struct TileGroup: Identifiable {
    var id: String { title }
    let title: String
    let style: String
    let tiles: [Tile]
}

/// An episode of one of your shows this week (lucapi's /upcoming, from the Trakt calendar).
struct Upcoming: Identifiable {
    var id: String { "\(imdb):\(season):\(episode)" }
    let imdb: String
    let show: String
    let season: Int
    let episode: Int
    let airs: Date
    let out: Bool
    init?(_ j: JSON) {
        guard let i = j.str("imdb"), let s = j.int("season"), let e = j.int("episode"), let a = parseDate(j.str("airs")) else { return nil }
        imdb = i; show = j.str("show") ?? ""; season = s; episode = e; airs = a; out = j.bool("out")
    }
    /// "Out now", "Tomorrow 2am", "Mon 1am"
    var when: String {
        if out { return "Out now" }
        let cal = Calendar.current
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_GB"); tf.dateFormat = cal.component(.minute, from: airs) == 0 ? "ha" : "h:mma"
        let t = tf.string(from: airs).lowercased()
        if cal.isDateInToday(airs) { return "Today \(t)" }
        if cal.isDateInTomorrow(airs) { return "Tomorrow \(t)" }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_GB"); df.dateFormat = "EEE"
        return "\(df.string(from: airs)) \(t)"
    }
}
