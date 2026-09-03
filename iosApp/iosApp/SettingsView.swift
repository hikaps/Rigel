import SwiftUI
import ComposeApp

struct SettingsView: View {
    @State private var routeKey = ""
    @State private var capKey = ""
    @State private var rendererOn = false
    @State private var rendererNotice: String?
    @State private var openSubtitlesAPIKey = ""
    @State private var openSubtitlesUsername = ""
    @State private var openSubtitlesPassword = ""
    @State private var openSubtitlesConnected = false
    @State private var openSubtitlesBusy = false
    @State private var openSubtitlesNotice: String?
    private var settings: SettingsStore { RigelCore.shared.settings }

    var body: some View {
        NavigationStack {
            Form {
                playbackSection
                integrationSection
                openSubtitlesSection
                rendererSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear {
                routeKey = settings.routeOverride().name
                capKey = settings.transcodeCap().name == "P720" ? "720p" : "1080p"
                rendererOn = RendererBridgeAccess.shared.isRunning()
                loadOpenSubtitlesSettings()
            }
            .onChange(of: routeKey) { newValue in
                settings.setRouteOverride(value: routeOverride(for: newValue))
            }
            .onChange(of: capKey) { newValue in
                settings.setTranscodeCap(value: newValue == "720p" ? TranscodeCap.p720 : TranscodeCap.p1080)
            }
        }
    }

    private var playbackSection: some View {
        Section("Playback") {
            Picker("Playback route", selection: $routeKey) {
                Text("Auto").tag("AUTO")
                Text("Direct").tag("DIRECT")
                Text("Always proxy").tag("ALWAYS_PROXY")
            }
            .pickerStyle(.segmented)
            Text(routeDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("Transcode cap", selection: $capKey) {
                Text("720p").tag("720p")
                Text("1080p").tag("1080p")
            }
            .pickerStyle(.segmented)
        }
    }

    private var integrationSection: some View {
        Section("Integration") {
            NavigationLink {
                IntegrationHelpView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How apps send streams to Rigel")
                            .font(.body)
                        Text("Scheme grammar for Nuvio, Kodi, Stremio addons, scripts")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "link")
                        .foregroundStyle(Color.rigelStar)
                }
            }
        }
    }


    private var openSubtitlesSection: some View {
        Section("OpenSubtitles") {
            if openSubtitlesConnected {
                LabeledContent("Connected as", value: openSubtitlesUsername)
                Button("Disconnect", role: .destructive) {
                    OpenSubtitlesKeychainStore.shared.clear()
                    openSubtitlesAPIKey = ""
                    openSubtitlesPassword = ""
                    openSubtitlesConnected = false
                    openSubtitlesNotice = "OpenSubtitles disconnected"
                }
                .disabled(openSubtitlesBusy)
                Text("Disconnect to connect a different account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("API key", text: $openSubtitlesAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $openSubtitlesUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $openSubtitlesPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(openSubtitlesBusy ? "Connecting…" : "Connect") {
                    connectOpenSubtitles()
                }
                .disabled(openSubtitlesBusy)
            }

            if let openSubtitlesNotice {
                Text(openSubtitlesNotice)
                    .font(.footnote)
                    .foregroundStyle(openSubtitlesConnected ? Color.rigelStar : .secondary)
            }
            Text("Used by “Get More…” in the player subtitle picker. Credentials stay in the iOS Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }


    private var rendererSection: some View {
        Section("Renderer") {
            Toggle(isOn: Binding(
                get: { rendererOn },
                set: { toggleRenderer($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DLNA renderer (receive pushes)")
                        .font(.body)
                    Text("Kodi 'Play using…', BubbleUPnP, Jellyfin-web")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.rigelStar)
            if let rendererNotice {
                Text(rendererNotice)
                    .font(.footnote)
                    .foregroundStyle(rendererOn ? Color.rigelStar : .red)
            }
            Text("Receive mode needs the multicast networking entitlement (Apple-gated); it is off by default and degrades gracefully when unavailable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Label {
                Text("Rigel — open-source iOS player. Receive from any app, send to any screen.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "star.fill")
                    .foregroundStyle(Color.rigelStar)
            }
            Text("Licenses: Rigel GPL-3.0 · FFmpeg LGPL-3.0 (source: ffmpeg.org)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var routeDetail: String {
        switch routeKey {
        case "DIRECT": return "Hand the URL straight to AVPlayer"
        case "ALWAYS_PROXY": return "Remux/transcode through the local HLS proxy"
        default: return "Probe the stream and pick the best path"
        }
    }

    private func routeOverride(for key: String) -> RouteOverride {
        switch key {
        case "DIRECT": return RouteOverride.direct
        case "ALWAYS_PROXY": return RouteOverride.alwaysProxy
        default: return RouteOverride.auto_
        }
    }

    private func loadOpenSubtitlesSettings() {
        let store = OpenSubtitlesKeychainStore.shared
        openSubtitlesAPIKey = store.apiKey ?? ""
        openSubtitlesUsername = store.username ?? ""
        openSubtitlesPassword = ""
        openSubtitlesConnected = store.isConnected
        openSubtitlesNotice = store.isConnected ? "Connected" : nil
    }

    private func connectOpenSubtitles() {
        let apiKey = openSubtitlesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = openSubtitlesUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = openSubtitlesPassword
        guard !apiKey.isEmpty, !username.isEmpty, !password.isEmpty else {
            openSubtitlesNotice = "Enter an API key, username, and password."
            openSubtitlesConnected = OpenSubtitlesKeychainStore.shared.isConnected
            return
        }

        openSubtitlesBusy = true
        openSubtitlesNotice = nil
        Task { @MainActor in
            do {
                let session = try await OpenSubtitlesClient.shared.login(
                    apiKey: apiKey,
                    username: username,
                    password: password
                )
                let store = OpenSubtitlesKeychainStore.shared
                store.apiKey = apiKey
                store.username = username
                store.token = session.token
                store.baseURL = session.baseURL
                openSubtitlesPassword = ""
                openSubtitlesConnected = true
                openSubtitlesNotice = "Connected"
            } catch {
                let stillConnected = OpenSubtitlesKeychainStore.shared.isConnected
                openSubtitlesConnected = stillConnected
                openSubtitlesNotice = stillConnected
                    ? "Could not reconnect; the saved connection remains active."
                    : error.localizedDescription
            }
            openSubtitlesBusy = false
        }
    }

    private func toggleRenderer(_ wantOn: Bool) {
        if wantOn {
            let error = RendererBridgeAccess.shared.start()
            if error == nil {
                rendererOn = true
                rendererNotice = "Rigel now appears as a DLNA renderer on the network"
            } else {
                rendererOn = false
                rendererNotice = error
            }
        } else {
            RendererBridgeAccess.shared.stop()
            rendererOn = false
            rendererNotice = nil
        }
    }
}

/// In-app scheme documentation so any app can target Rigel.
struct IntegrationHelpView: View {
    var body: some View {
        Form {
            Section("Scheme") {
                Text("Any app can hand a stream to Rigel:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("rigel://x-callback-url/{play|stream}?url=<enc>\n&filename=<enc>&sub=<enc,repeatable>\n&x-source=<enc>&x-success=<enc>")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Example (Nuvio-compatible)") {
                Text("rigel://x-callback-url/play?url=https%3A%2F%2Fx%2Fv.mkv&filename=Movie&sub=https%3A%2F%2Fx%2Fs.vtt&x-source=nuvio")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Also accepts") {
                Text("Plain http(s):// URLs, file:// (Files open-in), the share sheet, and a rigel:// URL passed as a launch argument. The sender shows as 'via <x-source>' in the player.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Integration")
        .navigationBarTitleDisplayMode(.inline)
    }
}
