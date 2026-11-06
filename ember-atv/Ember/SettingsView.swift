import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var notices: Notices
    @AppStorage("feed") private var feed = ""
    @AppStorage("hdrOutput") private var hdrOutput = false

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 80) {
                VStack(spacing: 24) {
                    Flame().frame(width: 120, height: 155)
                    Text("Ember").font(.ember(60, .bold)).foregroundStyle(Theme.accent)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.ember(19)).foregroundStyle(Theme.muted)
                }
                .frame(width: 520)
                .padding(.top, 60)

                List {
                    Section {
                        TextField("lucapi address", text: $feed, prompt: Text(API.defaultFeed))
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: { Text("lucapi") } footer: {
                        Text("Your rows, where you are in everything, and the stream picker all come from here. Leave it empty for \(API.defaultFeed).")
                    }
                    Section("AIOStreams") {
                        HStack {
                            Text(store.aio.isEmpty ? "Not linked yet" : "Linked, from lucapi")
                            Spacer()
                            Image(systemName: store.aio.isEmpty ? "exclamationmark.triangle" : "checkmark.circle.fill")
                                .foregroundStyle(store.aio.isEmpty ? .yellow : Theme.accent)
                        }
                        if store.aio.isEmpty {
                            Text("Open Ember PC once: it shares the link with your TVs through lucapi.").font(.ember(19)).foregroundStyle(Theme.muted)
                        }
                    }
                    Section {
                        Toggle("HDR output (experimental)", isOn: $hdrOutput)
                    } header: { Text("Picture") } footer: {
                        Text("Off: HDR and Dolby Vision are converted to a normal picture (reliable). On: sent to the TV as HDR; if streams then crash or look wrong, turn it off.")
                    }
                    Section {
                        Button("Test notifications") {
                            notices.say("Test: in 1h 00m  ·  Shift: MOTD at 18:30", level: 1)
                            notices.showCat("Test: Winnie came in")
                        }
                    } header: { Text("Notifications") } footer: {
                        Text("Calendar alerts show top right and the cats bottom left, while Ember is open (including over the player). tvOS doesn't let apps show anything over other apps.")
                    }
                    Section("What Ember last did") {
                        let steps = Array(Diag.lastSteps(25).reversed())
                        ForEach(steps.indices, id: \.self) { i in
                            Text(steps[i]).font(.system(size: 16, design: .monospaced)).lineLimit(2)
                        }
                    }
                    Section {
                        Button("Reload everything") { Task { await store.loadHome() } }
                    } footer: {
                        Text("Plays and progress are reported as \"\(API.deviceName)\", so Ember PC and Ember TV can carry on where you stopped.")
                    }
                }
                .frame(maxWidth: 1000)
            }
            .padding(.horizontal, 90)
            .background { AmbientBackground() }
        }
    }
}
