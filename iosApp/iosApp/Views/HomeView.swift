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
                VStack(alignment: .leading, spacing: 16) {
                    brand

                    if player.phase == .playing {
                        nowPlayingCard
                    }

                    openStreamCard
                    receiveCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Color.rigelInk.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rigelInk, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "play.tv.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.rigelInk)
                    .frame(width: 48, height: 48)
                    .background(Color.rigelStar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Rigel")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("PERSONAL MEDIA ROUTER")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.rigelStar)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Receive from any app.\nSend to any screen.")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text("Play a link here, or send it to a screen on your network.")
                    .font(.subheadline)
                    .foregroundStyle(Color.rigelSteel)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var nowPlayingCard: some View {
        Button {
            player.showPlayer = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Now playing", systemImage: "waveform")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(Color.rigelStar)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.rigelStar)
                }

                HStack(spacing: 14) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.rigelStar)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.displayTitle ?? "Now playing")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Playing on this device" + (player.sender.map { " · via \($0)" } ?? ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rigelStarDim.opacity(0.75), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.rigelStar.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var openStreamCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(
                icon: "link",
                title: "Open a stream",
                message: "Paste a direct video link or a rigel:// handoff."
            )

            HStack(spacing: 8) {
                TextField("URL or rigel:// link", text: $urlText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .lineLimit(1...3)

                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    urlText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    errorText = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .tint(Color.rigelStar)
                .accessibilityLabel("Paste link")
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                openStream()
            } label: {
                Label("Play on this device", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.rigelStar)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var receiveCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(
                icon: "arrow.down.to.line.compact",
                title: "Bring playback here",
                message: "Share a video to Rigel from Safari, Files, or any player app."
            )

            HStack(spacing: 10) {
                Button {
                    onOpenDevices()
                } label: {
                    Label("Devices", systemImage: "tv")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onOpenSources()
                } label: {
                    Label("Sources", systemImage: "rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Label(
                "Play a stream, then send it to an AirPlay, DLNA, Roku, Kodi, or Chromecast screen from the player.",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func cardHeader(icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.rigelStar)
                .frame(width: 38, height: 38)
                .background(Color.rigelStarDim, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openStream() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = raw.isEmpty ? "Paste a URL first"
            : (player.open(url: raw) ? nil : "Unrecognized URL")
    }

}
