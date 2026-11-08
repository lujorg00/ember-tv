import SwiftUI
import UIKit
import AVKit
import AVFoundation
import CoreMedia

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
    @Published var subText = ""           // the current subtitle, drawn by Ember (text subtitles)
    @Published var ownSubs = false
    @Published var intro = false          // the title at the top for the first few seconds
    @Published var upNext = false
    @Published var countdown = 15
    @Published var tracks: [Track] = []
    @Published var subDelay: Double = 0
    @Published var subScale: Double = UserDefaults.standard.object(forKey: "subSize") as? Double ?? 1.0

    let core = MPVCore()
    private(set) var session: PlaySession?
    weak var store: Store?
    private var lastReport = Date.distantPast
    private var bufferingSince: Date?
    private var openedAt = Date()
    private var controlsUntil = Date.distantPast
    private var introUntil = Date.distantPast
    private var creditsWanted = false
    private var creditsChapter: Double?        // when the file marks where the credits start
    @Published var autoNext = false            // counting down to the next episode (only when the credits are marked)
    private var lastSkip = Date.distantPast
    private var skipStreak = 0
    private var skipTarget: Double?
    private var skipDir: Double = 0
    // sliding a finger on the remote's touch surface: where you'd land, and a picture of it
    @Published var scrubTo: Double?
    @Published var preview: UIImage?
    @Published var previewAt: Double = -1
    private var thumbs: Thumbnailer?
    private var playAfterScrub = false
    var lastScrub = Date.distantPast
    private var done = false
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var switching = false        // the TV is changing mode (frame rate / HDR): playback held meanwhile

    func begin(_ s: PlaySession, store: Store) {
        guard session == nil else { return }
        Diag.log("player: \(s.title) · stream \(s.n + 1) of \(s.ranked.count) · \(s.stream.badges.joined(separator: " ")) · \(s.stream.label)")
        Diag.startedPlaying(s.title)
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
    func mpvSubText(_ s: String) {
        let t = Subtitles.tidy(s)
        if t != subText { subText = t }
    }
    func mpvSubCodec(_ c: String) {
        let picture = ["hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub", "dvb_subtitle", "dvbsub", "xsub"].contains(c.lowercased())
        let mine = !c.isEmpty && !picture
        if mine != ownSubs || c.isEmpty {
            ownSubs = mine
            core.subtitlesDrawnByEmber(mine)
        }
        Diag.log("subs: \(c.isEmpty ? "off" : c) · drawn by \(mine ? "Ember" : "mpv")")
    }
    func mpvDuration(_ d: Double) { dur = d }
    /// Keeps the screensaver away while a stream is playing (mpv doesn't tell tvOS, as Apple's own player does).
    /// Paused, stopped or finished: the Apple TV can sleep again as normal.
    private func stayAwake(_ on: Bool) {
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
    }

    func mpvPaused(_ p: Bool) {
        paused = p
        stayAwake(!p && !done)
        if switching { return }
        if p && started && !done { report("paused") }
        if p { showControls(for: 3600) } else { showControls() }
    }
    func mpvBuffering(_ b: Bool) {
        buffering = b
        bufferingSince = b && started ? Date() : nil
    }
    func mpvStarted() {
        if !started {
            Diag.log("playing: \(core.int("video-params/w"))x\(core.int("video-params/h")) \(core.string("video-params/gamma") ?? "?") \(String(format: "%.3f", core.double("container-fps")))fps \(core.string("audio-codec-name") ?? "") \(core.string("audio-params/channel-count") ?? "")ch")
            tracks = core.tracks()
            creditsChapter = findCreditsChapter()
            if session?.trailer != true { intro = true; introUntil = Date().addingTimeInterval(13) }
            matchDisplay()
            setupTracks()
        }
        started = true
        stayAwake(!paused && !done)
        buffering = false
        bufferingSince = nil
    }
    func mpvEnded(error: Bool) {
        guard !done else { return }
        if error { return fail(started ? "kept stalling" : "wouldn't play") }
        // a two-minute "this file is unavailable" video from the service instead of the episode: try the next stream
        if let s = session, !s.trailer, dur > 0, dur < 180, (s.meta.runtimeMinutes ?? 30) >= 10 {
            return fail("was unavailable")
        }
        // the stream just stopped well before the end (the connection dropped and the player took it as the end of
        // the file): don't count it as watched or drop back to the details page - carry on from here on the next stream
        if let s = session, !s.trailer, started, dur > 600, pos < dur - 300, pos / dur < 0.9 {
            Diag.log("player: ended early at \(Int(pos))s of \(Int(dur))s")
            return fail("stopped early")
        }
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
        if intro && now > introUntil { intro = false }
        creditsTick()
        // once a minute while playing: how smoothly it's going (dropped and late frames), for the log on lucapi
        ticks += 1
        if started && !paused && ticks % 60 == 0 {
            Diag.log("frames: \(String(format: "%.3f", core.double("container-fps")))fps on a \(String(format: "%.2f", core.double("display-fps")))Hz screen, dropped \(core.int("frame-drop-count")) + \(core.int("decoder-frame-drop-count")) decoding, late \(core.int("vo-delayed-frame-count")), mistimed \(core.int("mistimed-frame-count"))")
        }
    }
    private var ticks = 0

    /// Where the credits start, when the file's chapters say so ("Credits", "End Credits", "Outro"...).
    private func findCreditsChapter() -> Double? {
        let n = core.int("chapter-list/count")
        guard n > 1 else { return nil }
        for i in (0..<n).reversed() {
            let t = (core.string("chapter-list/\(i)/title") ?? "").lowercased()
            if t.contains("credit") || t.contains("outro") || t == "ending" || t == "end" {
                let at = core.double("chapter-list/\(i)/time")
                if at > 0 { return at }
            }
        }
        return nil
    }

    /// Next episode. If the file marks its credits, the card appears there and counts down from 15.
    /// Streams mostly don't say, and guessing cut the end off shows that play right to the last seconds
    /// (Law & Order: SVU), so otherwise the card only appears for the last 20 seconds and the next episode
    /// starts when this one has actually finished.
    private func creditsTick() {
        guard hasNext, started, dur > 300 else { return }
        let marked = creditsChapter
        let creditsAt = marked ?? (dur - 20)
        if pos < creditsAt {
            if upNext { upNext = false }
            creditsWanted = false
            return
        }
        if creditsWanted { return }
        if !upNext {
            upNext = true
            autoNext = marked != nil
            countdown = 15
            controls = false
        } else if autoNext && !paused {
            countdown -= 1
            if countdown <= 0 { playNext() }
        }
    }

    // MARK: actions

    func showControls(for seconds: Double = 5) {
        controls = true
        controlsUntil = Date().addingTimeInterval(seconds)
    }
    // MARK: scrubbing with the touch surface (like Apple's player): slide to look, click to jump, Back to stay

    var scrubbing: Bool { scrubTo != nil }

    func scrubBegin() {
        guard started, dur > 0, !done, !upNext else { return }
        lastScrub = Date()
        if scrubTo == nil {
            scrubTo = pos
            playAfterScrub = !paused
            core.pause()
            if thumbs == nil, let s = session, let u = URL(string: s.stream.url) {
                let t = Thumbnailer(url: u)
                t.onImage = { [weak self] at, img in
                    guard let self, self.scrubTo != nil else { return }
                    self.preview = img
                    self.previewAt = at
                }
                thumbs = t
            }
            thumbs?.request(pos)
        }
        showControls(for: 3600)
    }

    /// dx: how far the finger moved; faster slides cover more ground.
    func scrubMove(_ dx: CGFloat, velocity: CGFloat) {
        guard let t = scrubTo, dur > 0 else { return }
        lastScrub = Date()
        let perPoint = max(0.15, dur / 12000) * Double(1 + min(7, abs(velocity) / 900))
        let to = max(0, min(dur - 2, t + Double(dx) * perPoint))
        scrubTo = to
        thumbs?.request(to)
        showControls(for: 3600)
    }

    func scrubEnded() { lastScrub = Date() }

    func scrubCommit() {
        guard let t = scrubTo else { return }
        Diag.log("player: scrubbed to \(Int(t))s")
        core.command(["seek", String(format: "%.1f", t), "absolute"])
        pos = t
        endScrub()
    }

    func scrubCancel() { endScrub() }

    private func endScrub() {
        scrubTo = nil
        preview = nil
        previewAt = -1
        lastScrub = Date()
        if playAfterScrub { core.play() }
        playAfterScrub = false
        showControls()
    }

    /// Left/right on the timeline. Pressing (or holding) quickly speeds up: 10 s, then 30 s, then 1 and 2 minutes a press.
    func skip(_ s: Double) {
        // the move that ends a slide on the touch surface isn't a skip
        if scrubbing || Date().timeIntervalSince(lastScrub) < 0.5 { return }
        let now = Date()
        let dir: Double = s < 0 ? -1 : 1
        if now.timeIntervalSince(lastSkip) < 0.7 && dir == skipDir { skipStreak += 1 } else { skipStreak = 0; skipTarget = nil }
        lastSkip = now
        skipDir = dir
        let step = skipStreak < 3 ? 10.0 : skipStreak < 7 ? 30.0 : skipStreak < 12 ? 60.0 : 120.0
        let from = skipTarget ?? pos
        let to = max(0, min(dur > 0 ? dur - 2 : from + step, from + (s < 0 ? -step : step)))
        skipTarget = to
        core.command(["seek", String(format: "%.1f", to), "absolute+keyframes"])
        pos = to
        showControls()
        let mine = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.lastSkip == mine else { return }
            self.skipTarget = nil
            self.skipStreak = 0
        }
    }
    func togglePause() { core.togglePause() }
    func refreshTracks() { tracks = core.tracks(); subDelay = core.double("sub-delay") }
    func selectSubtitle(_ t: Track?) {
        core.set("sid", t.map { String($0.id) } ?? "no")
        remember("sub", t.map { $0.lang.isEmpty ? "und" : $0.lang } ?? "off")
        refreshTracks()
    }
    func selectAudio(_ t: Track) {
        core.set("aid", String(t.id))
        remember("audio", t.lang)
        refreshTracks()
    }
    func setSubScale(_ v: Double) {
        subScale = v
        core.set("sub-scale", String(v))
        UserDefaults.standard.set(v, forKey: "subSize")
    }
    func nudgeSubs(_ by: Double) {
        if by == 0 { core.set("sub-delay", "0") } else { core.command(["add", "sub-delay", String(by)]) }
        refreshTracks()
    }

    // MARK: audio and subtitle choices, remembered per film or show

    private var tracksKey: String { "tracks:\(session?.meta.id ?? "")" }
    private func remember(_ k: String, _ v: String) {
        guard session?.trailer == false else { return }
        var d = UserDefaults.standard.dictionary(forKey: tracksKey) as? [String: String] ?? [:]
        d[k] = v
        UserDefaults.standard.set(d, forKey: tracksKey)
    }

    /// Your last choices for this show (or film) put back; English subtitles fetched from OpenSubtitles
    /// (the same source as Stremio's) when the file has none of its own.
    private func setupTracks() {
        guard let s = session, !s.trailer else { return }
        let saved = UserDefaults.standard.dictionary(forKey: tracksKey) as? [String: String] ?? [:]
        if let a = saved["audio"], !a.isEmpty, let t = tracks.first(where: { $0.type == "audio" && $0.lang == a && !$0.selected }) {
            core.set("aid", String(t.id))
        }
        if let sub = saved["sub"] {
            if sub == "off" { core.set("sid", "no") }
            else if let t = tracks.first(where: { $0.type == "sub" && $0.lang == sub && !$0.forced }) { core.set("sid", String(t.id)) }
        }
        let english = tracks.contains { $0.type == "sub" && !$0.forced && ["en", "eng"].contains($0.lang) }
        if !english {
            let wantNow = ["en", "eng"].contains(saved["sub"] ?? "")
            let type = s.meta.isSeries ? "series" : "movie"
            let id = s.season != nil ? "\(s.meta.id):\(s.season!):\(s.episode ?? 1)" : s.meta.id
            Task {
                guard let j = try? await API.get("https://opensubtitles-v3.strem.io/subtitles/\(type)/\(id).json", timeout: 12) else { return }
                let eng = j.arr("subtitles").filter { ["eng", "en"].contains(($0.str("lang") ?? "").lowercased()) }.compactMap { $0.str("url") }
                Diag.log("subs: adding \(min(3, eng.count)) from OpenSubtitles")
                for (i, u) in eng.prefix(3).enumerated() {
                    core.commandAsync(["sub-add", u, i == 0 && wantNow ? "select" : "auto", "OpenSubtitles \(i + 1)", "eng"])
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                refreshTracks()
            }
        }
        refreshTracks()
    }

    // MARK: the TV's picture mode follows the video (frame rate, HDR), when "Match Content" is on in the Apple TV's settings

    /// The TV's picture-mode switcher. Asked for carefully: if it isn't there, Ember just doesn't switch (it used to crash).
    private var displayManager: AVDisplayManager? {
        guard let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              win.responds(to: NSSelectorFromString("avDisplayManager")) else {
            Diag.log("tv mode: switching isn't available")
            return nil
        }
        return win.avDisplayManager
    }

    private func matchDisplay() {
        guard let dm = displayManager, dm.isDisplayCriteriaMatchingEnabled else { Diag.log("tv mode: Match Content is off"); return }
        let gamma = core.string("video-params/gamma") ?? ""
        let w = core.int("video-params/w"), h = core.int("video-params/h")
        let fps = core.double("container-fps")
        guard w > 0, h > 0 else { return }
        // Dolby Vision is shown as HDR10 by mpv, so the TV is asked for HDR10 then (not Dolby Vision mode)
        let hdr = gamma == "pq" || gamma == "hlg"
        let transfer = gamma == "pq" ? kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            : gamma == "hlg" ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG : kCMFormatDescriptionTransferFunction_ITU_R_709_2
        let ext: [String: Any] = [
            kCMFormatDescriptionExtension_TransferFunction as String: transfer,
            kCMFormatDescriptionExtension_ColorPrimaries as String: hdr ? kCMFormatDescriptionColorPrimaries_ITU_R_2020 : kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: hdr ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        ]
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
                                       width: Int32(w), height: Int32(h), extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        guard let fd else { return }
        Diag.log("tv mode: asking for \(String(format: "%.3f", fps))Hz \(hdr ? gamma : "SDR")")
        dm.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(fps), formatDescription: fd)
        // hold playback while the TV changes mode, so nothing is missed in the blank second or two
        switching = true
        core.pause()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            for _ in 0..<50 where dm.isDisplayModeSwitchInProgress { try? await Task.sleep(nanoseconds: 150_000_000) }
            switching = false
            core.play()
        }
    }

    private func resetDisplay() { displayManager?.preferredDisplayCriteria = nil }
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
        Diag.log("player: stream \(why)")
        if started && pos > 60 { report("stopped") }
        finish(.failed(why, started ? pos : (session?.start ?? 0)))
    }

    private func finish(_ how: PlayEnd) {
        done = true
        stayAwake(false)
        Diag.log("player: closing (\(how))")
        Diag.stoppedPlaying()
        if case .next = how {} else { resetDisplay() }   // straight into the next episode: stay in this mode
        ticker?.cancel()
        thumbs?.close()
        thumbs = nil
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
    var hdr = false
    func makeUIViewController(context: Context) -> MPVHostController {
        let c = MPVHostController(core: model.core)
        c.url = url
        c.start = start
        c.hdr = hdr
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
                // HDR output (experimental, Settings): only for streams named HDR / Dolby Vision. Otherwise HDR is
                // converted to a normal picture, which is what's been reliable.
                MPVView(model: model, url: url, start: session.start,
                        hdr: UserDefaults.standard.bool(forKey: "hdrOutput")
                            && session.stream.badges.contains { ["HDR", "HDR10+", "Dolby Vision"].contains($0) }).ignoresSafeArea()
            }
            if model.buffering { ProgressView().scaleEffect(1.8).tint(.white) }
            if model.ownSubs && !model.subText.isEmpty {
                SubtitleText(text: model.subText, scale: model.subScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, model.controls ? 330 : 64)
                    .animation(.easeOut(duration: 0.25), value: model.controls)
                    .allowsHitTesting(false)
            }

            // controls hidden: this invisible button has the remote. Click shows the controls; left/right skip 10 s.
            RemotePan(allowed: { (focus == .bar || focus == .catcher) && !showSubs && !showAudio && !model.upNext },
                      began: { model.scrubBegin(); focus = .bar },
                      moved: { dx, v in model.scrubMove(dx, velocity: v) },
                      ended: { model.scrubEnded() })
                .frame(width: 1, height: 1).allowsHitTesting(false)

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

            if model.intro && !model.controls { introTitle.transition(.opacity) }
            if model.controls { controls.transition(.opacity) }
            if model.upNext { upNextCard.transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .animation(.easeInOut(duration: 0.25), value: model.controls)
        .animation(.easeInOut(duration: 1.2), value: model.intro)
        .animation(.easeInOut(duration: 0.3), value: model.upNext)
        .onAppear {
            model.begin(session, store: store)
            focus = .catcher
        }
        .onPlayPauseCommand { model.togglePause() }
        .onExitCommand {
            if model.scrubbing { model.scrubCancel(); return }
            if model.controls && !model.paused { model.controls = false; focus = .catcher }
            else if model.upNext { model.watchCredits(); focus = .catcher }
            else { model.stop() }
        }
        .onChange(of: model.controls) { _, on in if !on && !model.upNext { focus = .catcher } }
        .onChange(of: model.upNext) { _, on in focus = on ? .upPlay : .catcher }
        .confirmationDialog("Subtitles", isPresented: $showSubs) {
            let subs = model.tracks.filter { $0.type == "sub" }
            Button((subs.contains { $0.selected } ? "" : "✓ ") + "Off") { model.selectSubtitle(nil) }
            ForEach(subs) { t in
                Button((t.selected ? "✓ " : "") + t.label) { model.selectSubtitle(t) }
            }
            Button("Size: " + (model.subScale < 0.95 ? "Small" : model.subScale > 1.05 ? "Large" : "Medium") + "  (change)") {
                model.setSubScale(model.subScale < 0.95 ? 1.0 : model.subScale > 1.05 ? 0.85 : 1.2)
                reopenSubs()
            }
            Button("Timing: show earlier (−0.5 s)") { model.nudgeSubs(-0.5); reopenSubs() }
            Button("Timing: show later (+0.5 s)") { model.nudgeSubs(0.5); reopenSubs() }
            if model.subDelay != 0 {
                Button("Timing: reset (now \(String(format: "%+.1f", model.subDelay)) s)") { model.nudgeSubs(0); reopenSubs() }
            }
        }
        .confirmationDialog("Audio", isPresented: $showAudio) {
            ForEach(model.tracks.filter { $0.type == "audio" }) { t in
                Button((t.selected ? "✓ " : "") + t.label) { model.selectAudio(t) }
            }
        }
    }

    /// Size and timing changes keep the menu open (it closes itself after each choice), so you can see the effect and go again.
    private func reopenSubs() {
        Task { try? await Task.sleep(nanoseconds: 450_000_000); showSubs = true }
    }

    // MARK: the title when a stream starts: stays about 13 s, then fades away

    private var introTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.meta.name).font(.ember(40, .semibold)).lineLimit(1)
                        if let se = session.season, let ep = session.episode {
                            Text("S\(se) E\(ep)" + (session.epTitle.isEmpty ? "" : "  ·  " + session.epTitle))
                                .font(.ember(26, .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .padding(.leading, 90).padding(.top, 60)
                }
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: the controls: title, timeline, subtitles, audio, next episode

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .overlay(alignment: .topLeading) {
                    Text(model.title).font(.ember(30, .semibold)).padding(.leading, 90).padding(.top, 60)
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
                    .onTapGesture {
                        if model.scrubbing { model.scrubCommit() } else { model.togglePause(); model.showControls() }
                    }
                HStack(spacing: 24) {
                    Button { showSubs = true; model.refreshTracks() } label: { Label("Subtitles", systemImage: "captions.bubble") }
                            .buttonStyle(EmberButtonStyle(primary: false))
                        .focused($focus, equals: .subs)
                    Button { showAudio = true; model.refreshTracks() } label: { Label("Audio", systemImage: "speaker.wave.2") }
                            .buttonStyle(EmberButtonStyle(primary: false))
                        .focused($focus, equals: .audio)
                    if model.hasNext {
                        Button { model.playNext() } label: { Label("Next episode", systemImage: "forward.end.fill") }
                            .buttonStyle(EmberButtonStyle(primary: false))
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
                    Text(model.autoNext ? "Next episode in \(model.countdown)" : "Next episode").font(.ember(26, .semibold))
                    if let n = session.next {
                        Text("S\(n.season) E\(n.episode)\(n.title.isEmpty ? "" : " · " + n.title)").font(.ember(22)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    HStack(spacing: 20) {
                        Button { model.playNext() } label: { Label("Play now", systemImage: "play.fill") }
                            .buttonStyle(EmberButtonStyle(primary: true))
                            .focused($focus, equals: .upPlay)
                        Button { model.watchCredits(); focus = .catcher } label: { Text("Watch credits") }
                            .buttonStyle(EmberButtonStyle(primary: false))
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
                let sf = model.dur > 0 ? min(1, max(0, (model.scrubTo ?? 0) / model.dur)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: focused ? 12 : 8)
                    Capsule().fill(Theme.accent).frame(width: max(8, g.size.width * f), height: focused ? 12 : 8)
                    Circle().fill(model.scrubbing ? Theme.accent : focused ? .white : Theme.accent)
                        .frame(width: focused ? 34 : 18, height: focused ? 34 : 18)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .offset(x: g.size.width * f - (focused ? 17 : 9))
                    if let t = model.scrubTo {
                        // where you'd land: a white marker, with the picture and time above it
                        Capsule().fill(.white).frame(width: 6, height: 34).offset(x: g.size.width * sf - 3)
                        let pw: CGFloat = 400, ph: CGFloat = 225
                        VStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.85))
                                if let img = model.preview {
                                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: pw, height: ph).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                } else {
                                    ProgressView().tint(.white)
                                }
                            }
                            .frame(width: pw, height: ph)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.85), lineWidth: 3))
                            .shadow(color: .black.opacity(0.6), radius: 16)
                            Text(clock(t)).font(.ember(26, .semibold).monospacedDigit())
                                .shadow(color: .black, radius: 6)
                        }
                        .frame(width: pw)
                        .offset(x: min(max(0, g.size.width * sf - pw / 2), g.size.width - pw), y: -(ph / 2 + 60))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 36)
            HStack {
                Text(clock(model.pos))
                if model.paused && !model.scrubbing { Image(systemName: "pause.fill").padding(.leading, 8) }
                Spacer()
                if model.scrubbing {
                    Text("Click to jump · Back to stay").foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
                Text("-" + clock(max(0, model.dur - model.pos)))
            }
            .font(.ember(22).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}


// MARK: - subtitles, Netflix-style

/// A subtitle line: Ember's typeface, white, a fine dark edge and a soft shadow, no box.
struct SubtitleText: View {
    let text: String
    var scale: Double
    var body: some View {
        Text(text)
            .font(.ember(54 * scale, .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .shadow(color: .black.opacity(0.95), radius: 1.2, x: 0, y: 0)
            .shadow(color: .black.opacity(0.85), radius: 1.2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.55), radius: 9, x: 0, y: 3)
            .frame(maxWidth: 1400)
            .padding(.horizontal, 120)
    }
}

enum Subtitles {
    /// Cleans a subtitle for display; ALL-CAPS subtitles (common on TV captions) become sentence case.
    static func tidy(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: "\\N", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return sentenceCase(s)
    }

    static func sentenceCase(_ s: String) -> String {
        var letters = 0, upper = 0
        for ch in s.unicodeScalars where CharacterSet.letters.contains(ch) {
            letters += 1
            if CharacterSet.uppercaseLetters.contains(ch) { upper += 1 }
        }
        guard letters >= 4, Double(upper) / Double(letters) >= 0.8 else { return s }
        var out = ""
        var capNext = true
        for ch in s.lowercased() {
            if capNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capNext = false
                continue
            }
            out.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" { capNext = true }
            else if capNext, ch == "[" || ch == "(" { capNext = false }   // [door slams] stays lower case
        }
        // "i", "i'm", "i'll" on their own are always capitals
        return out.replacingOccurrences(of: "(?<![\\p{L}'’])i(?=$|[^\\p{L}])", with: "I", options: .regularExpression)
    }
}
