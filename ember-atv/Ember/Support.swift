import SwiftUI
import UIKit
import CoreText

// MARK: - Ember's typeface

extension Font {
    /// Selawik: Microsoft's open-source twin of Segoe UI (what Ember PC uses on Windows), same shapes and spacing.
    static func ember(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .ultraLight, .thin, .light: name = "Selawik-Light"
        case .regular: name = "Selawik-Regular"
        case .medium: name = "Selawik-Semilight"
        case .semibold: name = "Selawik-Semibold"
        default: name = "Selawik-Bold"
        }
        return .custom(name, fixedSize: size)
    }
}

/// Text drawn as an outline only (Ember PC's big Top 10 numbers).
struct OutlinedText: View {
    let text: String
    var size: CGFloat = 180
    var font = "Selawik-Bold"
    var tracking: CGFloat = -8
    var color: Color = Theme.accent.opacity(0.55)
    var lineWidth: CGFloat = 2.5

    var body: some View {
        let (path, box) = OutlinedText.glyphs(text, font, size, tracking)
        return Path(path).stroke(color, lineWidth: lineWidth).frame(width: box.width, height: box.height)
    }

    static func glyphs(_ text: String, _ name: String, _ size: CGFloat, _ tracking: CGFloat) -> (CGPath, CGSize) {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let all = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            for i in 0..<n {
                if let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                    all.addPath(g, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        let b = all.boundingBoxOfPath
        guard !b.isNull else { return (all, .zero) }
        // CoreText draws upwards: flip it and sit it in its own box (a little room for the stroke)
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -b.minX + 3, ty: b.maxY + 3)
        let out = all.copy(using: &t) ?? all
        return (out, CGSize(width: b.width + 6, height: b.height + 6))
    }
}

// MARK: - pictures

/// Posters and backdrops: kept in memory, retried when a download fails, started again when a row scrolls back.
final class ImageStore {
    static let shared = ImageStore()
    let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 20
        c.urlCache = URLCache.shared
        return URLSession(configuration: c)
    }()
    init() { cache.countLimit = 700 }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        for attempt in 0..<3 {
            if Task.isCancelled { return nil }
            if let res = try? await session.data(from: url),
               ((res.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400, let img = UIImage(data: res.0) {
                let ready = await img.byPreparingForDisplay() ?? img
                cache.setObject(ready, forKey: url as NSURL)
                return ready
            }
            try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
        }
        return nil
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var fit = false
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            if let img {
                Image(uiImage: img).resizable().aspectRatio(contentMode: fit ? .fit : .fill).transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { img = nil; return }
            if let hit = ImageStore.shared.cache.object(forKey: url as NSURL) { img = hit; return }
            if let got = await ImageStore.shared.load(url) {
                withAnimation(.easeIn(duration: 0.25)) { img = got }
            }
        }
    }
}

// MARK: - what the app was doing (sent to lucapi, so a crash can be tracked down)

enum Diag {
    private static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let logFile = dir.appendingPathComponent("ember-steps.log")
    static let crashFile = dir.appendingPathComponent("ember-crash.txt")
    static let playingFile = dir.appendingPathComponent("ember-playing.txt")
    private static let q = DispatchQueue(label: "ember.diag")
    private static var pending: [String] = []

    /// One step, kept on the Apple TV and sent to the Pi.
    static func log(_ msg: String) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(msg)"
        q.async {
            var lines = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            lines.append(line)
            if lines.count > 300 { lines.removeFirst(lines.count - 300) }
            try? lines.joined(separator: "\n").write(to: logFile, atomically: false, encoding: .utf8)
            pending.append(line)
            let batch = pending
            pending = []
            DispatchQueue.main.async { API.fire("/client/log", ["device": API.deviceName, "lines": batch]) }
        }
    }

    static func lastSteps(_ n: Int) -> [String] {
        Array((((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)).suffix(n))
    }

    static func startedPlaying(_ what: String) { try? what.write(to: playingFile, atomically: true, encoding: .utf8) }
    static func stoppedPlaying() { try? FileManager.default.removeItem(at: playingFile) }

    /// If Ember died last time, tell the Pi what it was doing.
    static func reportLastRun() {
        var out: [String] = []
        if let c = try? String(contentsOf: crashFile, encoding: .utf8) {
            out.append("CRASH last time: " + String(c.prefix(6000)))
            try? FileManager.default.removeItem(at: crashFile)
        }
        if let p = try? String(contentsOf: playingFile, encoding: .utf8) {
            out.append("Ember closed while playing (\(p)) without stopping normally")
            stoppedPlaying()
        }
        guard !out.isEmpty else { return }
        out.append("its last steps:")
        out += lastSteps(40)
        API.fire("/client/log", ["device": API.deviceName, "lines": out])
    }

    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { e in
            let text = "exception \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.prefix(40).joined(separator: "\n")
            try? text.write(to: Diag.crashFile, atomically: true, encoding: .utf8)
        }
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(s) { sig in
                let text = "signal \(sig)\n" + Thread.callStackSymbols.prefix(40).joined(separator: "\n")
                try? text.write(to: Diag.crashFile, atomically: true, encoding: .utf8)
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }
}
