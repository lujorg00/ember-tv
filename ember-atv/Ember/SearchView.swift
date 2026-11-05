import SwiftUI

/// Search films and series (Cinemeta), with the Apple TV's own search keyboard.
struct SearchView: View {
    @EnvironmentObject var store: Store
    @State private var q = ""
    @State private var series: [Meta] = []
    @State private var films: [Meta] = []
    @State private var searched = ""

    var body: some View {
        NavigationStack {
          ZStack {
            AmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !series.isEmpty { PosterRow(row: RowData(id: "s", title: "Series", kind: nil, metas: series, top: false)) }
                    if !films.isEmpty { PosterRow(row: RowData(id: "f", title: "Films", kind: nil, metas: films, top: false)) }
                    if !searched.isEmpty && series.isEmpty && films.isEmpty {
                        Text("Nothing found for “\(searched)”.").foregroundStyle(Theme.muted).padding(.horizontal, 90).padding(.top, 60)
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .searchable(text: $q, prompt: "Films and series")
          }
            .navigationDestination(for: Meta.self) { m in DetailView(meta: m) }
        }
        .task(id: q) {
            let term = q.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2 else { series = []; films = []; searched = ""; return }
            try? await Task.sleep(nanoseconds: 400_000_000)   // wait for typing to pause
            if Task.isCancelled { return }
            async let s = search("series", term)
            async let f = search("movie", term)
            let (rs, rf) = await (s, f)
            if Task.isCancelled { return }
            series = rs
            films = rf
            searched = term
        }
    }

    private func search(_ type: String, _ term: String) async -> [Meta] {
        let j = try? await API.get("\(API.cinemeta)/catalog/\(type)/top/search=\(API.q(term)).json", timeout: 15)
        return (j?.arr("metas") ?? []).map { Meta($0, type: type) }.filter { !$0.id.isEmpty }
    }
}
