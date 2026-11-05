import SwiftUI
import UIKit

/// What the player screen shows and does: playback state from mpv, progress reports to lucapi,
/// giving up on a stream that won't start or keeps stalling, and the "Next episode" pop-up in the credits.
@MainActor
final class PlayerModel: ObservableObject, MPVEvents {
    @Published var pos: Double = 0
    @Published var dur: Double = 0
    @Published var paused = false
    @Published var buffering = true
    @Published var started = false
    @Published var controls = false
    @Published var upNext = false
    @Published var countdown = 15
    @Published var tracks: [Track] = []

    let core = MPVCore()
    private(set) var session: PlaySession?
    weak var store: Store?
    private var lastReport = Date.distantPast
    private var bufferingSince: Date?
    private var openedAt = Date()
    private var controlsUntil = Date.distantPast
    private var creditsWanted = false
    private var done = false
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func begin(_ s: PlaySession, store: Store) {
        guard session == nil else { return }
        session = s
        self.store = store
        core.events = self
        openedAt = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
        // Home pressed or the TV went to sleep: save the exact spot so the PC can carry on from it
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.report("paused"); self?.core.pause() }
        })
    }

    var hasNext: Bool { session?.next != nil }
    var title: String { session?.title ?? "" }

    // MARK: mpv

    func mpvTime(_ t: Double) { pos = t }
    func mpvDuration(_ d: Double) { dur = d }
    func mpvPaused(_ p: Bool) {
        paused = p
        if p && started && !done { report("paused") }
        if p { showControls(for: 3600) } else { showControls() }
    }
    func mpvBuffering(_ b: Bool) {
        buffering = b
        bufferingSince = b && started ? Date() : nil
    }
    func mpvStarted() {
        if !started { tracks = core.tracks() }
        started = true
        buffering = false
        bufferingSince = nil
    }
    func mpvEnded(error: Bool) {
        guard !done else { return }
        if error { return fail(started ? "kept stalling" : "wouldn't play") }
        report("stopped", finished: true)
        finish(hasNext ? .next : .stopped)
    }

    // MARK: every second

    private func tick() {
        guard !done else { return }
        let now = Date()
        if !started && now.timeIntervalSince(openedAt) > 25 { return fail("wouldn't start") }
        if let b = bufferingSince, now.timeIntervalSince(b) > 12 { return fail("kept stalling") }
        if started && !paused && now.timeIntervalSince(lastReport) > 15 { report("playing") }
        if controls && now > controlsUntil && !paused { controls = false }
        creditsTick()
    }

    /// Where the credits roughly start. Streams don't say, so it's an estimate: the last 4% of the episode,
    /// at least 25 s and at most 100 s (about 50 s on a half-hour show, 100 s on an hour-long one).
    private func creditsTick() {
        guard hasNext, started, dur > 300 else { return }
        let creditsAt = dur - max(25, min(100, dur / 25))
        if pos < creditsAt {
            if upNext { upNext = false }
            creditsWanted = false
            return
        }
        if creditsWanted { return }
        if !upNext {
            upNext = true
            countdown = 15
            controls = false
        } else if !paused {
            countdown -= 1
        }
        if countdown <= 0 { playNext() }
    }

    // MARK: actions

    func showControls(for seconds: Double = 5) {
        controls = true
        controlsUntil = Date().addingTimeInterval(seconds)
    }
    func skip(_ s: Double) {
        core.seek(by: s)
        pos = max(0, min(dur > 0 ? dur - 1 : pos + s, pos + s))
        showControls()
    }
    func togglePause() { core.togglePause() }
    func refreshTracks() { tracks = core.tracks() }
    func selectSubtitle(_ t: Track?) { core.set("sid", t.map { String($0.id) } ?? "no"); refreshTracks() }
    func selectAudio(_ t: Track) { core.set("aid", String(t.id)); refreshTracks() }
    func watchCredits() { creditsWanted = true; upNext = false }
    func playNext() {
        guard !done else { return }
        report("stopped", finished: true)
        finish(.next)
    }
    func stop() {
        guard !done else { return }
        report("stopped")
        finish(.stopped)
    }

    private func fail(_ why: String) {
        guard !done else { return }
        if started && pos > 60 { report("stopped") }
        finish(.failed(why, started ? pos : (session?.start ?? 0)))
    }

    private func finish(_ how: PlayEnd) {
        done = true
        ticker?.cancel()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        core.shutdown()
        store?.playerEnded(how)
    }

    /// Where you are, to lucapi (the same report Ember PC and Ember TV send); lucapi passes it on to Trakt.
    func report(_ state: String, finished: Bool = false) {
        guard let s = session, !s.trailer, started, pos > 1 else { return }
        lastReport = Date()
        var b: JSON = ["imdb": s.meta.id, "type": s.meta.isSeries ? "series" : "movie", "position": pos,
                       "device": API.deviceName, "state": state, "finished": finished]
        if dur > 0 { b["duration"] = dur }
        if let se = s.season, let ep = s.episode { b["season"] = se; b["episode"] = ep; b["episodeTitle"] = s.epTitle }
        API.fire("/progress/report", b)
    }
}

/// mpv's picture inside SwiftUI.
struct MPVView: UIViewControllerRepresentable {
    let model: PlayerModel
    let url: URL
    let start: Double
    func makeUIViewController(context: Context) -> MPVHostController {
        let c = MPVHostController(core: model.core)
        c.url = url
        c.start = start
        return c
    }
    func updateUIViewController(_ c: MPVHostController, context: Context) {}
}

/// A button style that draws nothing: for the invisible button that takes the remote while the controls are hidden.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct PlayerScreen: View {
    @EnvironmentObject var store: Store
    let session: PlaySession
    @StateObject private var model = PlayerModel()
    @FocusState private var focus: Field?
    @State private var showSubs = false
    @State private var showAudio = false

    enum Field: Hashable { case catcher, bar, subs, audio, next, upPlay, upStay }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = URL(string: session.stream.url) {
                MPVView(model: model, url: url, start: session.start).ignoresSafeArea()
            }
            if model.buffering { ProgressView().scaleEffect(1.8).tint(.white) }

            // controls hidden: this invisible button has the remote. Click shows the controls; left/right skip 10 s.
            Button { model.showControls(); focus = .bar } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                .buttonStyle(BareButtonStyle())
                .focused($focus, equals: .catcher)
                .disabled(model.controls || model.upNext)
                .onMoveCommand { d in
                    switch d {
                    case .left: model.skip(-10); focus = .bar
                    case .right: model.skip(10); focus = .bar
                    default: model.showControls(); focus = .bar
                    }
                }

            if model.controls { controls.transition(.opacity) }
            if model.upNext { upNextCard.transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .animation(.easeInOut(duration: 0.25), value: model.controls)
        .animation(.easeInOut(duration: 0.3), value: model.upNext)
        .onAppear {
            model.begin(session, store: store)
            focus = .catcher
        }
        .onPlayPauseCommand { model.togglePause() }
        .onExitCommand {
            if model.controls && !model.paused { model.controls = false; focus = .catcher }
            else if model.upNext { model.watchCredits(); focus = .catcher }
            else { model.stop() }
        }
        .onChange(of: model.controls) { _, on in if !on && !model.upNext { focus = .catcher } }
        .onChange(of: model.upNext) { _, on in focus = on ? .upPlay : .catcher }
        .confirmationDialog("Subtitles", isPresented: $showSubs) {
            Button("Off") { model.selectSubtitle(nil) }
            ForEach(model.tracks.filter { $0.type == "sub" }) { t in
                Button((t.selected ? "✓ " : "") + t.label) { model.selectSubtitle(t) }
            }
        }
        .confirmationDialog("Audio", isPresented: $showAudio) {
            ForEach(model.tracks.filter { $0.type == "audio" }) { t in
                Button((t.selected ? "✓ " : "") + t.label) { model.selectAudio(t) }
            }
        }
    }

    // MARK: the controls: title, timeline, subtitles, audio, next episode

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .overlay(alignment: .topLeading) {
                    Text(model.title).font(.title3.weight(.semibold)).padding(.leading, 90).padding(.top, 60)
                }
            Spacer()
            VStack(alignment: .leading, spacing: 26) {
                Timeline(model: model, focused: focus == .bar)
                    .focusable()
                    .focused($focus, equals: .bar)
                    .onMoveCommand { d in
                        switch d {
                        case .left: model.skip(-10)
                        case .right: model.skip(10)
                        case .down: focus = .subs; model.showControls()
                        default: model.showControls()
                        }
                    }
                    .onTapGesture { model.togglePause(); model.showControls() }
                HStack(spacing: 24) {
                    Button { showSubs = true; model.refreshTracks() } label: { Label("Subtitles", systemImage: "captions.bubble") }
                        .focused($focus, equals: .subs)
                    Button { showAudio = true; model.refreshTracks() } label: { Label("Audio", systemImage: "speaker.wave.2") }
                        .focused($focus, equals: .audio)
                    if model.hasNext {
                        Button { model.playNext() } label: { Label("Next episode", systemImage: "forward.end.fill") }
                            .focused($focus, equals: .next)
                    }
                }
                .onMoveCommand { d in if d == .up { focus = .bar }; model.showControls() }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 60)
            .padding(.top, 120)
            .background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .top))
        }
        .ignoresSafeArea()
    }

    private var upNextCard: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Next episode in \(model.countdown)").font(.headline)
                    if let n = session.next {
                        Text("S\(n.season) E\(n.episode)\(n.title.isEmpty ? "" : " · " + n.title)").font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    HStack(spacing: 20) {
                        Button { model.playNext() } label: { Label("Play now", systemImage: "play.fill") }
                            .focused($focus, equals: .upPlay)
                        Button { model.watchCredits(); focus = .catcher } label: { Text("Watch credits") }
                            .focused($focus, equals: .upStay)
                    }
                }
                .padding(30)
                .frame(maxWidth: 640, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding(.trailing, 90)
                .padding(.bottom, 80)
            }
        }
    }
}

/// The timeline: where you are, what's left. Selected, the dot grows and turns white; left/right skip 10 s.
struct Timeline: View {
    @ObservedObject var model: PlayerModel
    let focused: Bool
    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { g in
                let f = model.dur > 0 ? min(1, max(0, model.pos / model.dur)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: focused ? 12 : 8)
                    Capsule().fill(Theme.accent).frame(width: max(8, g.size.width * f), height: focused ? 12 : 8)
                    Circle().fill(focused ? .white : Theme.accent)
                        .frame(width: focused ? 34 : 18, height: focused ? 34 : 18)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .offset(x: g.size.width * f - (focused ? 17 : 9))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 36)
            HStack {
                Text(clock(model.pos))
                if model.paused { Image(systemName: "pause.fill").padding(.leading, 8) }
                Spacer()
                Text("-" + clock(max(0, model.dur - model.pos)))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}
