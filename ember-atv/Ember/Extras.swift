import SwiftUI

/// "What shall we watch?": everyone swipes on their phone (scan the code); whatever you all like shows up here.
struct MatchView: View {
    @EnvironmentObject var store: Store
    @State private var code = ""
    @State private var people: [(String, Int)] = []
    @State private var deck = 0
    @State private var matches: [Meta] = []
    @State private var error = ""
    @State private var round = 0

    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What shall we watch?").font(.ember(52, .bold))
                        Text("Everyone swipes on their phone. Anything you all like appears here.").font(.ember(22)).foregroundStyle(Theme.muted)
                    }
                    HStack(alignment: .top, spacing: 60) {
                        VStack(spacing: 18) {
                            if code.isEmpty {
                                ProgressView().frame(width: 300, height: 300)
                            } else {
                                AsyncImage(url: URL(string: "\(API.feed)/match/\(code)/qr.png")) { ph in
                                    if let img = ph.image { img.resizable().interpolation(.none).scaledToFit() } else { Color.white.opacity(0.1) }
                                }
                                .frame(width: 300, height: 300)
                                .padding(14)
                                .background(.white, in: RoundedRectangle(cornerRadius: 22))
                                Text(code).font(.ember(54, .bold)).tracking(10).foregroundStyle(Theme.accent)
                                Text("Scan with your phone's camera, or go to\n\(API.feed.replacingOccurrences(of: "http://", with: ""))/m/\(code)")
                                    .font(.ember(19)).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                            }
                            Button { Task { await start() } } label: { Label("New deck", systemImage: "shuffle") }
                                .buttonStyle(EmberButtonStyle())
                        }
                        .frame(width: 380)
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(spacing: 12) {
                                if people.isEmpty { Text("Waiting for people to join…").foregroundStyle(Theme.muted) }
                                ForEach(people.indices, id: \.self) { i in
                                    Text("\(people[i].0) · \(people[i].1)/\(deck)").font(.ember(19, .semibold))
                                        .padding(.horizontal, 14).padding(.vertical, 6).background(Theme.card, in: Capsule())
                                }
                            }
                            Text("Matches").font(.ember(30, .bold))
                            if matches.isEmpty {
                                Text(people.count < 2 ? "None yet. Needs at least two people." : "None yet.").foregroundStyle(Theme.muted)
                            } else {
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(205), spacing: 36), count: 5), alignment: .leading, spacing: 44) {
                                    ForEach(matches) { m in PosterCard(meta: m) }
                                }
                            }
                            if !error.isEmpty { Text(error).foregroundStyle(.red.opacity(0.8)) }
                        }
                    }
                }
                .padding(.horizontal, 90).padding(.top, 50).padding(.bottom, 80)
            }
            .scrollClipDisabled()
          }
            .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
        }
        .task(id: round) {
            if code.isEmpty { await start() }
            var shown = ""
            while !Task.isCancelled {
                if !code.isEmpty, let st = try? await API.feedGet("/match/\(code)", timeout: 6) {
                    people = st.arr("people").map { ($0.str("name") ?? "Someone", $0.int("swiped") ?? 0) }
                    deck = st.int("deckSize") ?? 0
                    let ms = st.arr("matches").map { Meta($0, type: $0.str("type") ?? "movie") }
                    let key = ms.map(\.id).joined(separator: ",")
                    if key != shown {
                        if ms.count > matches.count, let last = ms.last { store.say("It's a match: \(last.name)") }
                        matches = ms
                        shown = key
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func start() async {
        error = ""
        code = ""; people = []; matches = []
        do {
            let r = try await API.post("/match/new", [:], timeout: 30)
            code = r.str("code") ?? ""
        } catch { self.error = "Couldn't reach lucapi: \(error.localizedDescription)" }
    }
}

/// Your year in watching, from your Trakt history (Omni, Ember TV, Ember PC and here).
struct YearView: View {
    @EnvironmentObject var store: Store
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var w: JSON?
    @State private var failed = ""

    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 36) {
                    HStack(alignment: .firstTextBaseline, spacing: 30) {
                        Text("Your \(String(year)) in watching").font(.ember(52, .bold))
                        let now = Calendar.current.component(.year, from: Date())
                        ForEach([now - 1, now], id: \.self) { y in
                            Button { year = y } label: { Text(String(y)) }.buttonStyle(TabTextStyle(selected: y == year))
                        }
                    }
                    if let w { content(w) }
                    else if !failed.isEmpty { Text(failed).foregroundStyle(Theme.muted) }
                    else { HStack(spacing: 16) { ProgressView(); Text("Adding it all up…").foregroundStyle(Theme.muted) } }
                }
                .padding(.horizontal, 90).padding(.top, 50).padding(.bottom, 80)
            }
            .scrollClipDisabled()
          }
            .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
        }
        .task(id: year) {
            w = nil; failed = ""
            do { w = try await API.feedGet("/wrapped?year=\(year)", timeout: 90) }
            catch { failed = "Couldn't get your history from lucapi: \(error.localizedDescription)" }
        }
    }

    @ViewBuilder private func content(_ w: JSON) -> some View {
        HStack(spacing: 28) {
            big(w.int("hours") ?? 0, "hours watched")
            big(w.int("episodes") ?? 0, "episodes")
            big(w.int("films") ?? 0, "films")
            bigText(w.dbl("days").map { String(format: "%.1f", $0) } ?? "0", "whole days of telly")
        }
        HStack(alignment: .top, spacing: 28) {
            card("By month") {
                let months = (w["byMonth"] as? [NSNumber])?.map(\.doubleValue) ?? []
                let top = max(1, months.max() ?? 1)
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(months.indices, id: \.self) { i in
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                                .frame(width: 34, height: max(4, 200 * months[i] / top))
                            Text(String("JFMAMJJASOND".map(String.init)[i])).font(.ember(17)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .frame(height: 240, alignment: .bottom)
            }
            card("Your habits") {
                VStack(alignment: .leading, spacing: 14) {
                    if let n = w.str("favouriteNight") {
                        Text("Your favourite night is **\(n)**, and you usually start around **\(hour(w.int("favouriteHour")))**.")
                    }
                    let bd = w.obj("busiestDay")
                    if let d = parseDay(bd.str("date")) {
                        Text("Your biggest day was **\(d)**: \(bd.dbl("hours").map { String(format: "%.1f", $0) } ?? "") hours.")
                    }
                    if let r = w.arr("rewatched").first {
                        Text("You couldn't stop rewatching **\(r.str("title") ?? "")** (\(r.int("plays") ?? 0) times).")
                    }
                }
                .font(.ember(22))
                .frame(maxWidth: 520, alignment: .leading)
            }
        }
        HStack(alignment: .top, spacing: 28) {
            card("Top shows") { list(w.arr("topShows"), type: "series") { x in "\(x.int("episodes") ?? 0) eps · \(Int((x.dbl("minutes") ?? 0) / 60))h" } }
            card("Top films") { list(w.arr("topFilms"), type: "movie") { x in
                [x.str("year"), (x.int("plays") ?? 1) > 1 ? "\(x.int("plays")!)×" : nil].compactMap { $0 }.joined(separator: " · ") } }
        }
    }

    private func big(_ n: Int, _ label: String) -> some View { bigText(n.formatted(), label) }
    private func bigText(_ n: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(n).font(.ember(64, .heavy)).foregroundStyle(Theme.accent)
            Text(label).font(.ember(20)).foregroundStyle(Theme.muted)
        }
        .padding(28)
        .frame(width: 400, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 22))
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.ember(26, .bold))
            c()
        }
        .padding(28)
        .frame(minWidth: 600, alignment: .topLeading)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 22))
    }

    private func list(_ items: [JSON], type: String, detail: @escaping (JSON) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.prefix(8).indices), id: \.self) { i in
                let x = items[i]
                NavigationLink(value: Meta(["id": x.str("imdb") ?? "", "type": type, "name": x.str("title") ?? ""])) {
                    HStack(spacing: 14) {
                        Text("\(i + 1)").font(.ember(20, .bold)).foregroundStyle(Theme.accent).frame(width: 30, alignment: .trailing)
                        Text(x.str("title") ?? "").font(.ember(21, .semibold)).lineLimit(1)
                        Spacer(minLength: 10)
                        Text(detail(x)).font(.ember(18)).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .disabled((x.str("imdb") ?? "").isEmpty)
            }
        }
        .frame(width: 600)
    }

    private func hour(_ h: Int?) -> String {
        guard let h else { return "—" }
        return "\((h + 11) % 12 + 1)\(h < 12 ? "am" : "pm")"
    }
    private func parseDay(_ s: String?) -> String? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(s.prefix(10))) else { return nil }
        let o = DateFormatter(); o.locale = Locale(identifier: "en_GB"); o.dateFormat = "d MMMM"
        return o.string(from: d)
    }
}
