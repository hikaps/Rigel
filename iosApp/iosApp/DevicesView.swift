import SwiftUI
import ComposeApp

struct DevicesView: View {
    @State private var devices: [DiscoveredDevice] = []
    @State private var scanning = false
    @State private var ipText = ""
    @State private var notice: String?
    @State private var castTarget: CastTarget?

    var body: some View {
        NavigationStack {
            List {
                Section("Screen") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AirPlay receivers")
                                .font(.body)
                            Text("Apple TV, AirPlay-2 TVs, MacBooks — pick the output from the player screen.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "airplayvideo")
                            .foregroundStyle(Color.rigelStar)
                    }
                }

                Section {
                    if scanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Scanning the network…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if devices.isEmpty && !scanning {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No renderers found")
                                .font(.subheadline.weight(.semibold))
                            Text("SSDP multicast may be restricted on this Wi-Fi. Add a device by IP below, or check the TV/Kodi/Roku is on the same network.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(devices, id: \.stableId) { device in
                        DeviceRow(device: device) {
                            castTarget = device.target
                        } onRemove: {
                            RigelCore.shared.devices.removeManualDevice(target: device.target)
                            devices.removeAll { $0.stableId == device.stableId }
                        }
                    }
                } header: {
                    Text("On your network")
                }

                Section {
                    HStack {
                        TextField("TV IP, e.g. 192.168.1.42", text: $ipText)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            addByIP()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.rigelStar)
                        .disabled(ipText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Probes DLNA, Kodi JSON-RPC (:8080), Roku ECP (:8060), and Chromecast (:8009).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Add by IP")
                }

                if let notice {
                    Section {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Color.rigelStar)
                    }
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        scan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(scanning)
                }
            }
            .task { scan() }
            .sheet(isPresented: Binding(
                get: { castTarget != nil },
                set: { if !$0 { castTarget = nil } }
            )) {
                if let target = castTarget {
                    CastSheetView(target: target) { result in
                        notice = result
                    }
                }
            }
        }
    }

    private func scan() {
        scanning = true
        RigelCore.shared.devices.scan(timeoutMs: 5000) { found, _ in
            Task { @MainActor in
                self.devices = found ?? []
                self.scanning = false
            }
        }
    }

    private func addByIP() {
        let ip = ipText.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        RigelCore.shared.devices.addManualByIp(ip: ip) { target, _ in
            Task { @MainActor in
                if let target {
                    self.notice = "Added \(target.name)"
                    self.ipText = ""
                    self.scan()
                } else {
                    self.notice = "No renderer found at \(ip)"
                }
            }
        }
    }
}

/// Stable identity per renderer (usn-based), independent of display name —
/// multiple manual Kodis legitimately share the name "Kodi".
private extension DiscoveredDevice {
    var stableId: String { target.stableId }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let onCast: () -> Void
    let onRemove: () -> Void

    private var kind: String { device.target.kindLabel }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .foregroundStyle(Color.rigelStar)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.target.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(kind)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.rigelStarDim, in: Capsule())
                        .foregroundStyle(Color.rigelStar)
                    Text(device.via)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if device.via == "manual" {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Button("Cast", action: onCast)
                .buttonStyle(.borderedProminent)
                .tint(Color.rigelStar)
        }
        .padding(.vertical, 2)
    }
}
