import SwiftUI
import AVFoundation

enum Theme {
    static let accent = Color(red: 0.941, green: 0.627, blue: 0.294)     // #F0A04B, Ember's orange
    static let ink = Color(red: 0.10, green: 0.06, blue: 0.03)
    static let bg = Color(red: 0.055, green: 0.043, blue: 0.035)         // #0E0B09
    static let card = Color(red: 0.13, green: 0.10, blue: 0.08)
    static let muted = Color(white: 0.72)
}

@main
struct EmberApp: App {
    @StateObject private var store = Store()
    @StateObject private var notices = Notices()

    init() {
        // posters and backdrops: keep plenty on disk so rows come back instantly
        URLCache.shared = URLCache(memoryCapacity: 96 << 20, diskCapacity: 768 << 20)
        Diag.installCrashHandlers()
        // films and shows: full surround to the TV or soundbar (5.1 / 7.1), not stereo
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        try? audio.setActive(true)
        try? audio.setPreferredOutputNumberOfChannels(audio.maximumOutputNumberOfChannels)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(notices)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var notices: Notices
    @Environment(\.scenePhase) private var phase
    @State private var lastCrash: [String]?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house") }
                BrowseView(type: "movie")
                    .tabItem { Label("Films", systemImage: "film") }
                BrowseView(type: "series")
                    .tabItem { Label("Series", systemImage: "tv") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                WhatToWatchView()
                    .tabItem { Label("What to watch?", systemImage: "heart") }
                YearView()
                    .tabItem { Label("Your year", systemImage: "chart.bar") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            }
            if let l = store.loading { LoadingView(state: l).transition(.opacity).zIndex(2) }
            NoticeOverlay().zIndex(4)
            if let t = store.toast {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.ember(22))
                        .padding(.horizontal, 28).padding(.vertical, 16)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 50)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.loading != nil)
        .animation(.easeInOut(duration: 0.3), value: store.toast)
        .sheet(isPresented: Binding(get: { lastCrash != nil }, set: { if !$0 { lastCrash = nil } })) {
            CrashReport(lines: lastCrash ?? [])
        }
        .fullScreenCover(item: $store.playing) { s in
            PlayerScreen(session: s).environmentObject(store).environmentObject(notices)
                .overlay { NoticeOverlay().environmentObject(notices) }
        }
        .task {
            lastCrash = Diag.reportLastRun()
            Diag.log("app: started, version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            notices.start()
            await store.loadHome()
        }
        .onChange(of: phase) { _, p in
            // back from another app or the screensaver: you may have watched something on the PC meanwhile
            if p == .active, store.homeLoaded, store.playing == nil { store.refreshAfterPlay() }
        }
    }
}

/// After a crash: what Ember was doing, on screen (take a photo of it).
struct CrashReport: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ember closed unexpectedly last time").font(.ember(34, .bold))
            Text("A photo of this helps track it down. It has also been sent to lucapi.").font(.ember(20)).foregroundStyle(Theme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i]).font(.system(size: 17, design: .monospaced)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .focusable()
        }
        .padding(50)
        .frame(width: 1600, height: 950, alignment: .topLeading)
    }
}
