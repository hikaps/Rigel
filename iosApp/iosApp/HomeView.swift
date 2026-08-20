import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerModel
    let onOpenDevices: () -> Void
    let onOpenSources: () -> Void

    @State private var urlText = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    brand

                    if player.phase == .playing {
                        nowPlayingCard
                    }

                    openStreamCard
                    receiveCard
                }
                .padding(20)
            }
            .background(Color.rigelInk)
            .navigationTitle("Rigel")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rigel")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rigelStar)
            Text("Receive from any app. Send to any screen.")
                .font(.subheadline)
                .foregroundStyle(Color.rigelSteel)
        }
    }

    private var nowPlayingCard: some View {
        Button {
            player.showPlayer = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.rigelStar)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.filename ?? "Now playing")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Playing on this device" + (player.sender.map { " · via \($0)" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Open")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.rigelStar)
            }
            .padding(14)
            .background(Color.rigelStarDim.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var openStreamCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a stream")
                .font(.headline)
            TextField("URL or rigel:// link", text: $urlText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button {
                let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                errorText = raw.isEmpty ? "Paste a URL first"
                    : (player.open(url: raw) ? nil : "Unrecognized URL")
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.rigelStar)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var receiveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring playback here")
                .font(.headline)
            Text("Share a video to Rigel from Safari, Files, or any player app — or hand off with a rigel:// link from Nuvio, Kodi, Stremio addons, and scripts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Devices") { onOpenDevices() }
                    .buttonStyle(.bordered)
                Button("Sources") { onOpenSources() }
                    .buttonStyle(.bordered)
            }
            Label("AirPlay, DLNA, Roku, and Kodi screens are reachable from the Devices tab.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
