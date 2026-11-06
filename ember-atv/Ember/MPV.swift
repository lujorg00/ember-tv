import Foundation
import UIKit
import Libmpv

/// MoltenVK sometimes asks for a 1x1 drawable to finish a frame; ignoring that stops flicker (mpv #13651).
final class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }

    /// HDR: MoltenVK switches the layer to extended range from mpv's drawing thread, but the switch has to happen on
    /// the main thread (off it, the app is killed). Same fix as MPVKit's iOS demo.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue } }
        }
    }
}

@MainActor
protocol MPVEvents: AnyObject {
    func mpvTime(_ t: Double)
    func mpvDuration(_ d: Double)
    func mpvPaused(_ p: Bool)
    func mpvBuffering(_ b: Bool)
    func mpvStarted()
    func mpvEnded(error: Bool)
}

struct Track: Identifiable, Hashable {
    let id: Int
    let type: String       // "audio", "sub", "video"
    let label: String
    let selected: Bool
    var lang: String = ""
    var forced: Bool = false
}

/// Hosts mpv's picture: a Metal layer filling the screen.
final class MPVHostController: UIViewController {
    var metalLayer = MetalLayer()
    let core: MPVCore
    var url: URL?
    var start: Double = 0
    var hdr = false

    init(core: MPVCore) {
        self.core = core
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        Diag.log("mpv: creating (hdr output \(hdr ? "on" : "off"))")
        core.setup(layer: &metalLayer, hdr: hdr)
        Diag.log("mpv: ready")
        if let url { core.load(url, start: start) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
    }
}

/// mpv (the same player Ember PC uses), drawing with Metal: plays MKV, HEVC, Dolby Vision, DTS and TrueHD.
final class MPVCore {
    private(set) var mpv: OpaquePointer?
    weak var events: MPVEvents?
    private let queue = DispatchQueue(label: "ember.mpv", qos: .userInitiated)

    private func opt(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
    }

    func setup(layer: inout MetalLayer, hdr: Bool) {
        guard mpv == nil, let m = mpv_create() else { return }
        mpv = m
        mpv_request_log_messages(m, "no")
        mpv_set_option(m, "wid", MPV_FORMAT_INT64, &layer)
        opt("vo", "gpu-next")
        opt("gpu-api", "vulkan")
        opt("gpu-context", "moltenvk")
        opt("hwdec", "videotoolbox")
        opt("video-rotate", "no")
        // letterbox bars jet black; HDR passed to the TV as HDR when the Apple TV is outputting HDR, and when it
        // isn't, a tone-mapping that keeps contrast (not the flat, washed-out look)
        opt("background-color", "#000000")
        // only for HDR streams (it can't be changed once playing; SDR ones don't need it)
        opt("target-colorspace-hint", hdr ? "yes" : "no")
        opt("tone-mapping", "bt.2446a")
        opt("hdr-contrast-recovery", "0.30")
        // English audio and subtitles first, as on the PC; forced subtitles (foreign bits) still show
        opt("alang", "en,eng")
        opt("slang", "en,eng")
        opt("subs-fallback", "yes")
        opt("sub-scale", String(UserDefaults.standard.object(forKey: "subScale") as? Double ?? 0.75))
        opt("cache", "yes")
        opt("demuxer-max-bytes", "150MiB")
        opt("demuxer-max-back-bytes", "40MiB")
        opt("network-timeout", "20")
        opt("keep-open", "no")
        mpv_initialize(m)
        mpv_observe_property(m, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(m, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(m, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(m, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(m, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func load(_ url: URL, start: Double) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "start", start > 1 ? String(Int(start)) : "none")
        Diag.log("mpv: loading from \(Int(start))s")
        command(["loadfile", url.absoluteString, "replace"])
    }

    /// Without waiting (subtitles from the internet: a slow download mustn't freeze the app).
    func commandAsync(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs { if let p { free(UnsafeMutablePointer(mutating: p)) } } }
        mpv_command_async(mpv, 0, &cargs)
    }

    func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs { if let p { free(UnsafeMutablePointer(mutating: p)) } } }
        mpv_command(mpv, &cargs)
    }

    func setFlag(_ name: String, _ v: Bool) {
        guard let mpv else { return }
        var d: Int32 = v ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &d)
    }

    func flag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var d: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &d)
        return d != 0
    }

    func int(_ name: String) -> Int {
        guard let mpv else { return 0 }
        var d: Int64 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &d)
        return Int(d)
    }

    func double(_ name: String) -> Double {
        guard let mpv else { return 0 }
        var d: Double = 0
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &d)
        return d
    }

    func string(_ name: String) -> String? {
        guard let mpv, let c = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    func set(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    var paused: Bool { flag("pause") }
    func togglePause() { setFlag("pause", !paused) }
    func pause() { setFlag("pause", true) }
    func play() { setFlag("pause", false) }
    func seek(by s: Double) { command(["seek", String(Int(s)), "relative"]) }
    func seek(to s: Double) { command(["seek", String(Int(s)), "absolute"]) }

    /// The audio and subtitle tracks in the file, named for people ("English · 5.1 · E-AC-3").
    func tracks() -> [Track] {
        let n = int("track-list/count")
        var out: [Track] = []
        for i in 0..<n {
            guard let type = string("track-list/\(i)/type"), type != "video" else { continue }
            let id = int("track-list/\(i)/id")
            let lang = string("track-list/\(i)/lang") ?? ""
            let title = string("track-list/\(i)/title") ?? ""
            let codec = (string("track-list/\(i)/codec") ?? "").uppercased()
            let ch = string("track-list/\(i)/demux-channels") ?? ""
            let forced = flag("track-list/\(i)/forced")
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? (lang.isEmpty ? "Track \(id)" : lang)
            var parts = [name]
            if !title.isEmpty && title.lowercased() != name.lowercased() { parts.append(title) }
            if type == "audio" { if !ch.isEmpty { parts.append(ch) }; if !codec.isEmpty { parts.append(codec) } }
            if forced { parts.append("Forced") }
            if flag("track-list/\(i)/external") && type == "sub" && title.isEmpty { parts.append("Downloaded") }
            out.append(Track(id: id, type: type, label: parts.joined(separator: " · "), selected: flag("track-list/\(i)/selected"),
                             lang: lang.lowercased(), forced: forced))
        }
        return out
    }

    private func readEvents() {
        queue.async { [weak self] in
            while let self, let m = self.mpv {
                guard let ev = mpv_wait_event(m, 0) else { break }
                let e = ev.pointee
                if e.event_id == MPV_EVENT_NONE { break }
                switch e.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let pp = e.data?.assumingMemoryBound(to: mpv_event_property.self).pointee, let cname = pp.name else { break }
                    let name = String(cString: cname)
                    if pp.format == MPV_FORMAT_DOUBLE, let v = pp.data?.assumingMemoryBound(to: Double.self).pointee {
                        Task { @MainActor in
                            if name == "time-pos" { self.events?.mpvTime(v) } else if name == "duration" { self.events?.mpvDuration(v) }
                        }
                    } else if pp.format == MPV_FORMAT_FLAG, let v = pp.data?.assumingMemoryBound(to: Int32.self).pointee {
                        let on = v != 0
                        Task { @MainActor in
                            if name == "pause" { self.events?.mpvPaused(on) } else if name == "paused-for-cache" { self.events?.mpvBuffering(on) }
                        }
                    }
                case MPV_EVENT_PLAYBACK_RESTART:
                    Task { @MainActor in self.events?.mpvStarted() }
                case MPV_EVENT_END_FILE:
                    guard let ef = e.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { break }
                    let err = ef.reason == MPV_END_FILE_REASON_ERROR
                    Diag.log("mpv: file ended (\(err ? "error \(ef.error)" : "reason \(ef.reason.rawValue)"))")
                    if err || ef.reason == MPV_END_FILE_REASON_EOF {
                        Task { @MainActor in self.events?.mpvEnded(error: err) }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default:
                    break
                }
            }
        }
    }

    /// Stops and frees mpv. Called when the player closes.
    func shutdown() {
        guard let m = mpv else { return }
        mpv = nil
        events = nil
        mpv_set_wakeup_callback(m, nil, nil)
        queue.async { mpv_terminate_destroy(m) }
    }

    deinit { if let m = mpv { mpv_set_wakeup_callback(m, nil, nil); mpv_terminate_destroy(m) } }
}
