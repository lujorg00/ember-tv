import SwiftUI

/// Films or Series: the hero, Trending Now, New for you, the services' Top 10s, then the boxes.
struct BrowseView: View {
    @EnvironmentObject var store: Store
    let type: String
    @State private var hero: [Meta] = []
    @State private var rows: [RowData] = []
    @State private var loaded = false

    private var name: String { type == "movie" ? "Films" : "Series" }

    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !hero.isEmpty { HeroView(items: hero, pageName: name) }
                    ForEach(rows) { r in
                        if r.top { TopRow(row: r) } else { PosterRow(row: r) }
                    }
                    ForEach(store.tiles(for: type)) { g in TileRow(group: g, type: type) }
                    if !loaded { ProgressView().frame(maxWidth: .infinity).padding(.top, 300) }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .ignoresSafeArea()
          }
            .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
            .navigationDestination(for: Tile.self) { t in TilePage(tile: t, type: type) }
        }
        .task {
            guard !loaded else { return }
            let r = await store.browse(type)
            hero = r.hero
            rows = r.rows
            loaded = true
        }
    }
}

// MARK: - tiles

struct TileRow: View {
    let group: TileGroup
    let type: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeader(title: group.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(group.tiles) { t in
                        NavigationLink(value: t) { TileCard(tile: t) }
                            .buttonStyle(.card)
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

/// Designed boxes, as on Ember PC: services and studios in their colours with their logos, awards with the award
/// itself behind the name, directors' photos, everything else on artwork with its logo.
struct TileCard: View {
    let tile: Tile
    static let size = CGSize(width: 300, height: 162)

    var body: some View {
        let key = tile.title.lowercased().trimmingCharacters(in: .whitespaces)
        Group {
            if let aw = Award.all[key] { award(aw) }
            else if let br = Brand.all[key] { brand(br) }
            else if tile.style == "person" { person }
            else if key == "007" { bond }
            else if tile.style == "logo" { serviceLogo }
            else { art }
        }
        .frame(width: TileCard.size.width, height: TileCard.size.height)
        .clipped()
    }

    private func award(_ a: Award) -> some View {
        ZStack {
            LinearGradient(colors: [Color(hex: a.from), Color(hex: a.to)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image("award-\(a.art)").resizable().scaledToFit().frame(height: TileCard.size.height * a.scale).opacity(0.9)
                .overlay {
                    if a.art == "tomato" {
                        Text("100%").font(.system(size: 22, weight: .heavy)).foregroundStyle(Color(red: 0.55, green: 0.06, blue: 0.03).opacity(0.85))
                            .offset(y: 8)
                    }
                }
            VStack {
                Text(a.small).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.78)).padding(.top, 12)
                Spacer()
                Text(a.big).font(.system(size: a.big.count > 9 ? 24 : 34, weight: .light)).tracking(a.big.count > 9 ? 3 : 5)
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 8).lineLimit(1).minimumScaleFactor(0.6).padding(.bottom, 14)
            }
        }
    }

    private func brand(_ b: Brand) -> some View {
        ZStack {
            LinearGradient(colors: [Color(hex: b.from), Color(hex: b.to)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.10), .clear], center: .center, startRadius: 0, endRadius: 160)
            VStack(spacing: 6) {
                if let asset = b.asset {
                    inked(Image(asset).resizable(), b.ink).scaledToFit().frame(maxWidth: 200, maxHeight: 70)
                } else if let u = tile.logo {
                    AsyncImage(url: u) { ph in
                        if let img = ph.image { inked(img.resizable(), tile.logoKind == "icon" ? "o" : b.ink).scaledToFit().frame(maxWidth: 200, maxHeight: 70) }
                        else { name(30) }
                    }
                } else { name(30) }
                if let sub = b.sub { Text(sub).font(.system(size: 15, weight: .semibold)).tracking(4).foregroundStyle(.white.opacity(0.9)) }
            }
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        }
    }

    @ViewBuilder private func inked(_ img: Image, _ ink: String) -> some View {
        switch ink {
        case "w", "W": img.renderingMode(.template).foregroundStyle(.white)
        case "k": img.renderingMode(.template).foregroundStyle(.black)
        default: img
        }
    }

    private var person: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: tile.image) { ph in
                if let img = ph.image { img.resizable().scaledToFill() } else { Theme.card }
            }
            .frame(width: TileCard.size.width, height: TileCard.size.height)
            .clipped()
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .center)
            name(24).padding(14)
        }
    }

    private var bond: some View {
        ZStack {
            AsyncImage(url: tile.image) { ph in
                if let img = ph.image { img.resizable().scaledToFill() } else { Theme.card }
            }
            Color.black.opacity(0.55)
            VStack(spacing: 2) {
                Text("007").font(.system(size: 56, weight: .heavy)).tracking(2)
                Text("JAMES BOND").font(.system(size: 14, weight: .medium)).tracking(7).foregroundStyle(Color(red: 0.91, green: 0.86, blue: 0.8))
            }
            .shadow(color: .black, radius: 14)
        }
    }

    private var serviceLogo: some View {
        ZStack {
            Color(hex: tile.colour ?? "#2a2a2a")
            if let u = tile.logo {
                AsyncImage(url: u) { ph in
                    if let img = ph.image { img.resizable().scaledToFit() } else { name(26) }
                }
                .frame(height: TileCard.size.height)
            } else { name(26) }
        }
    }

    private var art: some View {
        ZStack {
            AsyncImage(url: tile.image) { ph in
                if let img = ph.image { img.resizable().scaledToFill() } else { Theme.card }
            }
            .frame(width: TileCard.size.width, height: TileCard.size.height)
            .clipped()
            LinearGradient(colors: [Theme.bg.opacity(tile.logo == nil ? 0.3 : 0.55), Theme.bg.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            if let u = tile.logo {
                AsyncImage(url: u) { ph in
                    if let img = ph.image {
                        logoLook(img.resizable()).scaledToFit().frame(maxWidth: 200, maxHeight: 80)
                            .shadow(color: .black.opacity(0.7), radius: 10)
                    } else { name(24) }
                }
            } else { name(24) }
        }
    }

    /// Dark one-colour logos are turned light (keeping their detail); the rest keep their own colours.
    @ViewBuilder private func logoLook(_ img: Image) -> some View {
        if tile.logoMode == "dark" || tile.logoMode == "mono" { img.grayscale(1).colorInvert().brightness(0.05) } else { img }
    }

    private func name(_ size: CGFloat) -> some View {
        Text(tile.title.uppercased()).font(.system(size: size, weight: .bold)).tracking(0.5).multilineTextAlignment(.center)
            .foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: 10).padding(.horizontal, 12).lineLimit(2).minimumScaleFactor(0.6)
    }
}

/// The page behind a box: its titles, Films or Series where both exist, in the order you pick.
struct TilePage: View {
    @EnvironmentObject var store: Store
    let tile: Tile
    let type: String
    @State private var typ = "movie"
    @State private var sort = ""
    @State private var metas: [Meta] = []
    @State private var shown = 0
    @State private var page = 1
    @State private var more = true
    @State private var busy = false

    private var own: Bool { tile.kind == "cat" }
    private var both: Bool { own ? tile.types.count > 1 : ["service", "genre", "company"].contains(tile.kind) }
    static let sorts: [(String, String)] = [("", "List order"), ("new", "Newest"), ("old", "Oldest"), ("rating", "Top rated"), ("az", "A–Z")]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottomLeading) {
                    Backdrop(url: tile.style == "person" ? nil : tile.image, height: 420, kenBurns: true)
                    LinearGradient(colors: [Theme.bg, Theme.bg.opacity(0.3)], startPoint: .bottom, endPoint: .top)
                    VStack(alignment: .leading, spacing: 22) {
                        Text(tile.title).font(.system(size: 64, weight: .bold)).shadow(color: .black.opacity(0.6), radius: 16)
                        HStack(spacing: 18) {
                            if both {
                                chip("Films", on: typ == "movie") { typ = "movie"; reload() }
                                chip("Series", on: typ == "series") { typ = "series"; reload() }
                                Spacer().frame(width: 30)
                            }
                            if own {
                                ForEach(0..<TilePage.sorts.count, id: \.self) { i in
                                    let s = TilePage.sorts[i]
                                    chip(s.1, on: sort == s.0) { sort = s.0; reload() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 90).padding(.bottom, 20)
                }
                .frame(height: 420)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(205), spacing: 40), count: 7), alignment: .leading, spacing: 50) {
                    ForEach(metas) { m in
                        PosterCard(meta: m).onAppear { if m.id == metas.last?.id { loadMore() } }
                    }
                }
                .padding(.horizontal, 90)
                if busy { ProgressView().frame(maxWidth: .infinity).padding(40) }
                else if metas.isEmpty { Text("Nothing in this list yet.").foregroundStyle(Theme.muted).padding(.horizontal, 90) }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea()
        .background { AmbientBackground() }
        .task {
            if metas.isEmpty {
                let first = tile.types.first ?? "movie"
                typ = type.isEmpty ? first : (tile.types.contains(type) || !own ? type : first)
                loadMore()
            }
        }
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 22, weight: on ? .bold : .medium))
                .foregroundStyle(on ? Theme.ink : .white)
                .padding(.horizontal, 6)
        }
        .tint(on ? Theme.accent : nil)
        .buttonStyle(.bordered)
    }

    private func reload() {
        metas = []; shown = 0; page = 1; more = true
        loadMore()
    }

    private func loadMore() {
        guard more, !busy else { return }
        busy = true
        let path = own ? "/browse/cat/\(tile.id)?type=\(typ)&skip=\(shown)&sort=\(sort)" : "/browse/\(tile.kind)/\(tile.id)?type=\(typ)&page=\(page)"
        let want = (typ, sort)
        Task {
            defer { busy = false }
            guard let r = try? await API.feedGet(path, timeout: 60), want == (typ, sort) else { return }
            let got = r.arr("metas").map { Meta($0, type: typ) }.filter { !$0.id.isEmpty }
            let have = Set(metas.map(\.id))
            let fresh = got.filter { !have.contains($0.id) }
            metas += fresh
            shown += got.count
            if own { more = r.bool("more") && !fresh.isEmpty } else { page += 1; more = page <= (r.int("pages") ?? 1) }
        }
    }
}

// MARK: - designed boxes (the same tables as Ember PC)

struct Brand {
    let from: String, to: String, ink: String
    var asset: String? = nil
    var sub: String? = nil
    static let all: [String: Brand] = [
        "netflix": Brand(from: "#3a0606", to: "#0c0202", ink: "o", asset: "brand-netflix"),
        "prime video": Brand(from: "#1f8fff", to: "#0a3f8a", ink: "w", asset: "brand-prime-video"),
        "apple tv+": Brand(from: "#3a3a3a", to: "#050505", ink: "w", asset: "brand-apple-tv-plus"),
        "disney+": Brand(from: "#1d3a9c", to: "#070f33", ink: "w"), "hbo max": Brand(from: "#262626", to: "#000000", ink: "w"),
        "hulu": Brand(from: "#1ed27a", to: "#0a6b3b", ink: "w"),
        "paramount +": Brand(from: "#3c7bff", to: "#1238b8", ink: "w"), "paramount+": Brand(from: "#3c7bff", to: "#1238b8", ink: "w"),
        "peacock": Brand(from: "#2a2a2a", to: "#000000", ink: "w"),
        "discovery +": Brand(from: "#2468e8", to: "#0a2a7a", ink: "w", asset: "brand-discovery-plus"),
        "discovery+": Brand(from: "#2468e8", to: "#0a2a7a", ink: "w", asset: "brand-discovery-plus"),
        "crunchyroll": Brand(from: "#ff8a3d", to: "#c24a0c", ink: "w", asset: "brand-crunchyroll"),
        "marvel studios": Brand(from: "#d3191f", to: "#5c080b", ink: "o"), "dc studios": Brand(from: "#2a6be8", to: "#0a2a72", ink: "o"),
        "pixar": Brand(from: "#3a3a3a", to: "#0a0a0a", ink: "w"),
        "walt disney": Brand(from: "#1a2f80", to: "#070d29", ink: "w"), "walt disney animation studios": Brand(from: "#1a2f80", to: "#070d29", ink: "w"),
        "dreamworks animation": Brand(from: "#2a62c9", to: "#0a1f4f", ink: "w"), "illumination studios": Brand(from: "#ffd23a", to: "#d39a00", ink: "k"),
        "sony pictures animation": Brand(from: "#4b7fe0", to: "#13306e", ink: "w"), "sony pictures": Brand(from: "#2a2a2a", to: "#000000", ink: "W"),
        "studio ghibli": Brand(from: "#72b6e3", to: "#1f5f8f", ink: "w"), "universal pictures": Brand(from: "#14284f", to: "#02060f", ink: "w"),
        "warner brothers": Brand(from: "#2357b0", to: "#0a2350", ink: "o"),
        "warner brothers animation": Brand(from: "#2357b0", to: "#0a2350", ink: "o", sub: "ANIMATION"),
        "lionsgate": Brand(from: "#4a4a4a", to: "#111111", ink: "w"), "miramax": Brand(from: "#2a2a2a", to: "#000000", ink: "w"),
        "mgm": Brand(from: "#8a6a24", to: "#2b1d06", ink: "w"), "searchlight pictures": Brand(from: "#24384e", to: "#070d14", ink: "w"),
        "cbeebies": Brand(from: "#22307a", to: "#0b1238", ink: "o", asset: "brand-cbeebies"),
        "cartoon network": Brand(from: "#9a9a9a", to: "#4a4a4a", ink: "o", asset: "brand-cartoon-network"),
        "nickelodeon": Brand(from: "#2a2a2a", to: "#050505", ink: "o", asset: "brand-nickelodeon"),
        "disney kids": Brand(from: "#4b33b5", to: "#1a1150", ink: "o", asset: "brand-disney-channel"),
        "imdb top 250": Brand(from: "#2a2a2a", to: "#000000", ink: "o", asset: "brand-imdb", sub: "TOP 250"),
    ]
}

struct Award {
    let from: String, to: String, small: String, big: String, art: String
    var scale: CGFloat { ["palme": 0.6, "tomato": 0.58, "bafta": 0.62, "globe": 0.76][art] ?? 0.8 }
    static let all: [String: Award] = [
        "oscar winners": Award(from: "#432466", to: "#120a22", small: "The Academy Awards", big: "OSCARS", art: "oscar"),
        "academy award winners": Award(from: "#432466", to: "#120a22", small: "The Academy Awards", big: "OSCARS", art: "oscar"),
        "bafta": Award(from: "#2e2142", to: "#0d0914", small: "The British Academy Film Awards", big: "BAFTA", art: "bafta"),
        "golden globes": Award(from: "#7a4416", to: "#2a1505", small: "Golden Globe Awards", big: "GOLDEN GLOBES", art: "globe"),
        "cannes": Award(from: "#14295a", to: "#060f28", small: "Festival de Cannes", big: "CANNES", art: "palme"),
        "certified fresh": Award(from: "#1f4a22", to: "#071509", small: "Rotten Tomatoes", big: "CERTIFIED FRESH", art: "tomato"),
    ]
}

extension Color {
    /// "#F0A04B"
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        if h.count == 3 { v = ((v & 0xF00) << 12 | (v & 0xF00) << 8) | ((v & 0xF0) << 8 | (v & 0xF0) << 4) | ((v & 0xF) << 4 | (v & 0xF)) }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
