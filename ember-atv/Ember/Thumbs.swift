import Foundation
import UIKit
import SwiftUI
import Libmpv

/// Preview pictures for scrubbing: a second, silent mpv opens the same stream, jumps to the time you're sliding to
/// and draws that frame small (in software, into memory). Started on the first slide, closed with the player.
final class Thumbnailer {
    private var mpv: OpaquePointer?
    private var render: OpaquePointer?
    private let q = DispatchQueue(label: "ember.thumbs", qos: .userInitiated)
    private let url: URL
    private var opened = false
    private var seekingTo: Double?
    private var wanted: Double?
    private var cache: [Int: UIImage] = [:]       // by 4-second step
    private let w = 480, h = 270
    private var buf: UnsafeMutableRawPointer
    /// The picture for a time (called on the main thread).
    var onImage: ((Double, UIImage) -> Void)?

    init(url: URL) {
        self.url = url
        buf = UnsafeMutableRawPointer.allocate(byteCount: 480 * 270 * 4, alignment: 64)
    }

    private static func bucket(_ t: Double) -> Int { Int(t / 4) }

    /// Wants the picture at t; only the latest wish counts while a frame is on its way.
    func request(_ t: Double) {
        q.async {
            if let hit = self.cache[Thumbnailer.bucket(t)] { self.deliver(t, hit); return }
            self.wanted = t
            if !self.opened { self.open(at: t); return }
            if self.seekingTo == nil { self.seek(t) }
        }
    }

    private func set(_ m: OpaquePointer, _ k: String, _ v: String) { mpv_set_option_string(m, k, v) }

    private func open(at t: Double) {
        opened = true
        guard let m = mpv_create() else { return }
        mpv = m
        mpv_request_log_messages(m, "no")
        set(m, "vo", "libmpv")
        set(m, "hwdec", "videotoolbox-copy")
        set(m, "aid", "no")
        set(m, "sid", "no")
        set(m, "pause", "yes")
        set(m, "hr-seek", "no")              // nearest keyframe: quick, and close enough for a preview
        set(m, "cache", "no")
        set(m, "demuxer-max-bytes", "16MiB")
        set(m, "demuxer-readahead-secs", "1")
        set(m, "vd-lavc-skiploopfilter", "all")
        set(m, "vd-lavc-fast", "yes")
        set(m, "network-timeout", "15")
        set(m, "keep-open", "yes")
        set(m, "ytdl", "no")
        guard mpv_initialize(m) >= 0 else { Diag.log("thumbs: mpv wouldn't start"); return }

        var api = Array("sw".utf8CString)
        var ctx: OpaquePointer?
        let ok: Int32 = api.withUnsafeMutableBufferPointer { p in
            var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(p.baseAddress)),
                          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            return mpv_render_context_create(&ctx, m, &params)
        }
        guard ok >= 0, let ctx else { Diag.log("thumbs: no software renderer (\(ok))"); return }
        render = ctx
        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(ctx, { p in
            guard let p else { return }
            let t = Unmanaged<Thumbnailer>.fromOpaque(p).takeUnretainedValue()
            t.q.async { t.frameReady() }
        }, me)
        // events aren't needed, but they're read so they don't pile up
        mpv_set_wakeup_callback(m, { p in
            guard let p else { return }
            let t = Unmanaged<Thumbnailer>.fromOpaque(p).takeUnretainedValue()
            t.q.async { t.drain() }
        }, me)
        seekingTo = t
        mpv_set_property_string(m, "start", String(format: "%.1f", t))
        command(["loadfile", url.absoluteString, "replace"])
        Diag.log("thumbs: opened for previews")
    }

    private func drain() {
        guard let m = mpv else { return }
        while let ev = mpv_wait_event(m, 0), ev.pointee.event_id != MPV_EVENT_NONE {
            if ev.pointee.event_id == MPV_EVENT_SHUTDOWN { return }
        }
    }

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs { if let p { free(UnsafeMutablePointer(mutating: p)) } } }
        mpv_command_async(mpv, 0, &cargs)
    }

    private func seek(_ t: Double) {
        seekingTo = t
        command(["seek", String(format: "%.1f", t), "absolute+keyframes"])
    }

    private func frameReady() {
        guard let ctx = render else { return }
        let flags = mpv_render_context_update(ctx)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        var size: [Int32] = [Int32(w), Int32(h)]
        var fmt = Array("rgb0".utf8CString)
        var stride = w * 4
        let rc: Int32 = size.withUnsafeMutableBufferPointer { sp in
            fmt.withUnsafeMutableBufferPointer { fp in
                withUnsafeMutablePointer(to: &stride) { st in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sp.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(fp.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(st)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buf),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(ctx, &params)
                }
            }
        }
        guard rc >= 0, let t = seekingTo, let img = image() else { return }
        cache[Thumbnailer.bucket(t)] = img
        deliver(t, img)
        seekingTo = nil
        if let next = wanted, Thumbnailer.bucket(next) != Thumbnailer.bucket(t) {
            if let hit = cache[Thumbnailer.bucket(next)] { deliver(next, hit) } else { seek(next) }
        }
    }

    private func image() -> UIImage? {
        let data = Data(bytes: buf, count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    private func deliver(_ t: Double, _ img: UIImage) {
        DispatchQueue.main.async { self.onImage?(t, img) }
    }

    func close() {
        onImage = nil
        q.async {
            if let r = self.render { mpv_render_context_set_update_callback(r, nil, nil); mpv_render_context_free(r) }
            self.render = nil
            if let m = self.mpv { mpv_set_wakeup_callback(m, nil, nil); mpv_terminate_destroy(m) }
            self.mpv = nil
        }
    }

    deinit { buf.deallocate() }
}

/// The Siri Remote's touch surface: resting a finger and sliding left or right (not the clicks or quick flicks,
/// which still move by 10 s and more). Calls back with how far the finger moved and how fast.
struct RemotePan: UIViewRepresentable {
    var allowed: () -> Bool
    var began: () -> Void
    var moved: (CGFloat, CGFloat) -> Void
    var ended: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PanHost {
        let v = PanHost()
        v.coordinator = context.coordinator
        return v
    }
    func updateUIView(_ v: PanHost, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ v: PanHost, coordinator: Coordinator) { v.detach() }

    final class PanHost: UIView {
        weak var coordinator: Coordinator?
        private var pan: UIPanGestureRecognizer?
        private weak var attached: UIWindow?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window, let coordinator else { return }
            let p = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handle(_:)))
            p.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            p.cancelsTouchesInView = false
            p.delegate = coordinator
            window.addGestureRecognizer(p)
            pan = p
            attached = window
        }
        func detach() {
            if let pan, let attached { attached.removeGestureRecognizer(pan) }
            pan = nil
            attached = nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RemotePan
        private var scrubbing = false
        private var lastX: CGFloat = 0
        init(_ p: RemotePan) { parent = p }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            let tr = g.translation(in: g.view)
            switch g.state {
            case .began:
                scrubbing = false
                lastX = 0
            case .changed:
                if !scrubbing {
                    // a deliberate sideways slide, not a wobble while clicking
                    guard parent.allowed(), abs(tr.x) > 60, abs(tr.x) > abs(tr.y) * 1.5 else { return }
                    scrubbing = true
                    lastX = tr.x
                    parent.began()
                    return
                }
                let dx = tr.x - lastX
                lastX = tr.x
                parent.moved(dx, g.velocity(in: g.view).x)
            default:
                if scrubbing { parent.ended() }
                scrubbing = false
            }
        }
    }
}
