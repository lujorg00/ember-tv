import Foundation
import UIKit

/// lucapi (ember-feed on the Pi) does the thinking: your rows, where you are, which stream is best.
/// Cinemeta fills in details. Everything the app knows lives on the Pi, so Ember PC and Ember TV stay in step.
enum API {
    static let defaultFeed = "http://192.168.4.141:8090"
    static let cinemeta = "https://v3-cinemeta.strem.io"
    static let deviceName = "Apple TV"

    static var feed: String {
        let s = (UserDefaults.standard.string(forKey: "feed") ?? "").trimmingCharacters(in: .whitespaces)
        let f = s.isEmpty ? defaultFeed : s
        return f.hasSuffix("/") ? String(f.dropLast()) : f
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    static func get(_ url: String, timeout: TimeInterval = 15) async throws -> JSON {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        let (d, resp) = try await session.data(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: d)) as? JSON ?? [:]
    }

    static func feedGet(_ path: String, timeout: TimeInterval = 15) async throws -> JSON {
        try await get(feed + path, timeout: timeout)
    }

    @discardableResult
    static func post(_ path: String, _ body: JSON, timeout: TimeInterval = 10) async throws -> JSON {
        guard let u = URL(string: feed + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await session.data(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let msg = ((try? JSONSerialization.jsonObject(with: d)) as? JSON)?.str("error") ?? "HTTP \(h.statusCode)"
            throw NSError(domain: "lucapi", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return ((try? JSONSerialization.jsonObject(with: d)) as? JSON) ?? [:]
    }

    /// Fire and forget, and finish even if Ember is being sent to the background (Home pressed mid-episode).
    static func fire(_ path: String, _ body: JSON) {
        let bg = BackgroundTask()
        Task {
            _ = try? await post(path, body, timeout: 8)
            await MainActor.run { bg.end() }
        }
    }

    /// One row's titles, from your addon through lucapi.
    /// A Top list, 25 long: the service's own Top 10, then what was in it on recent days (kept by lucapi).
    static func toplist(_ c: JSON) async -> [Meta] {
        guard let type = c.str("type"), let id = c.str("id") else { return [] }
        let aio = c.str("aio") != nil
        if let j = try? await feedGet("/toplist/\(type)/\(q(id)).json\(aio ? "?aio=1" : "")", timeout: 30) {
            let metas = j.arr("metas").map { Meta($0, type: type) }.filter { !$0.id.isEmpty }
            if !metas.isEmpty { return metas }
        }
        if aio { return await Store.anyCatalog(c) }
        return await catalog(c)
    }

    static func catalog(_ c: JSON) async -> [Meta] {
        guard let type = c.str("type"), let id = c.str("id") else { return [] }
        let j = try? await feedGet("/addon/catalog/\(type)/\(q(id)).json", timeout: 30)
        return (j?.arr("metas") ?? []).map { Meta($0, type: type) }.filter { !$0.id.isEmpty }
    }
}

/// Cinemeta details (logos, episodes), kept for 6 hours.
actor MetaCache {
    static let shared = MetaCache()
    private var store: [String: (Date, Meta)] = [:]

    func get(_ type: String, _ id: String) async -> Meta? {
        let k = type + ":" + id
        if let hit = store[k], Date().timeIntervalSince(hit.0) < 6 * 3600 { return hit.1 }
        guard let j = try? await API.get("\(API.cinemeta)/meta/\(type)/\(id).json", timeout: 15) else { return store[k]?.1 }
        let m = Meta(j.obj("meta"), type: type)
        guard !m.id.isEmpty else { return nil }
        store[k] = (Date(), m)
        return m
    }

    /// The row's entry with Cinemeta's details on top.
    func full(_ m: Meta) async -> Meta { m.merged(with: await get(m.type, m.id)) }
}

/// Keeps Ember running for a moment after Home is pressed, so the last report gets to the Pi.
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init() {
        id = UIApplication.shared.beginBackgroundTask { [weak self] in self?.end() }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
