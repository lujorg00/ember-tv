import SwiftUI

/// Search films and series (Cinemeta), with the Apple TV's own search keyboard.
struct SearchView: View {
    @EnvironmentObject var store: Store
    @State private var q = ""
    @State private var series: [Meta] = []
    @State private var films: [Meta] = []
    @State private var searched = ""
    @State private var smart: [Meta] = []          // asking for something: Ember's picks for it
    @State private var smartLabel = ""
    @State private var smartBy = ""
    @State private var aiNote = ""                 // AI search off: out of credit, or the key turned down
    @State private var asking = false

    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if asking && smart.isEmpty {
                        Text("Looking for “\(searched)”…").font(.ember(21)).foregroundStyle(Theme.muted).padding(.horizontal, 90)
                    }
                    if !aiNote.isEmpty {
                        Label(aiNote, systemImage: "exclamationmark.circle").font(.ember(20)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 90)
                    }
                    if !smart.isEmpty { PosterRow(row: RowData(id: "smart", title: "✦ " + smartLabel, kind: smartBy.isEmpty ? nil : smartBy, metas: smart, top: false)) }
                    if !series.isEmpty { PosterRow(row: RowData(id: "s", title: "Series", kind: nil, metas: series, top: false)) }
                    if !films.isEmpty { PosterRow(row: RowData(id: "f", title: "Films", kind: nil, metas: films, top: false)) }
                    if !searched.isEmpty && series.isEmpty && films.isEmpty && smart.isEmpty && !asking {
                        Text("Nothing found for “\(searched)”.").foregroundStyle(Theme.muted).padding(.horizontal, 90).padding(.top, 60)
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .searchable(text: $q, prompt: "Search, or ask: rom coms from the 2000s…")
          }
            .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
        }
        .task(id: q) {
            let term = q.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2 else { series = []; films = []; smart = []; searched = ""; asking = false; aiNote = ""; return }
            let ask = term.contains(" ")
            try? await Task.sleep(nanoseconds: ask ? 800_000_000 : 400_000_000)   // wait for typing to pause
            if Task.isCancelled { return }
            async let s = search("series", term)
            async let f = search("movie", term)
            let (rs, rf) = await (s, f)
            if Task.isCancelled { return }
            series = rs
            films = rf
            searched = term
            smart = []
            aiNote = ""
            guard ask else { asking = false; return }
            asking = true
            let r = try? await API.feedGet("/search/smart?q=\(API.q(term))", timeout: 45)
            if Task.isCancelled { return }
            asking = false
            let got = (r?.arr("metas") ?? []).map { Meta($0, type: $0.str("type") ?? "movie") }.filter { !$0.id.isEmpty }
            smartLabel = r?.str("label") ?? term
            smartBy = (r?["ai"] as? Bool) == true ? "picked by Claude" : ""
            aiNote = r?.str("aiNote") ?? ""
            withAnimation(.easeOut(duration: 0.3)) { smart = got }
        }
    }

    private func search(_ type: String, _ term: String) async -> [Meta] {
        let j = try? await API.get("\(API.cinemeta)/catalog/\(type)/top/search=\(API.q(term)).json", timeout: 15)
        return (j?.arr("metas") ?? []).map { Meta($0, type: type) }.filter { !$0.id.isEmpty }
    }
}
