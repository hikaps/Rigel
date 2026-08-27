import SwiftUI
import ComposeApp

struct DeviceSetupView: View {
    let devices: [DiscoveredDevice]
    let onAdded: () -> Void
    let onRemoved: () -> Void

    @State private var ipText = ""
    @State private var notice: String?
    @State private var adding = false
    @State private var manualDevices: [DiscoveredDevice]

    init(
        devices: [DiscoveredDevice],
        onAdded: @escaping () -> Void,
        onRemoved: @escaping () -> Void
    ) {
        self.devices = devices
        self.onAdded = onAdded
        self.onRemoved = onRemoved
        _manualDevices = State(initialValue: devices.filter { $0.via == "manual" })
    }

    var body: some View {
        List {
            Section("Add by IP") {
                HStack {
                    TextField("TV IP, e.g. 192.168.1.42", text: $ipText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        addByIP()
                    } label: {
                        if adding {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rigelStar)
                    .accessibilityLabel("Add device by IP")
                    .disabled(adding || ipText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Why can't I find my device?") {
                Text("Devices must be on the same Wi-Fi network as this iPhone.")
                Text("Rigel finds TVs using DLNA, Kodi, Roku, and Chromecast discovery.")
                Text("You can add a TV by IP address above even if discovery misses it.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if !manualDevices.isEmpty {
                Section("Manual devices") {
                    ForEach(manualDevices, id: \.target.stableId) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "tv")
                                .foregroundStyle(Color.rigelStar)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.target.name)
                                    .lineLimit(1)
                                Text(device.target.kindLabel)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                remove(device)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(device.target.name)")
                        }
                    }
                }
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Color.rigelStar)
                }
            }
        }
        .navigationTitle("Device setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addByIP() {
        let ip = ipText.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !adding else { return }

        adding = true
        notice = nil
        RigelCore.shared.devices.addManualByIp(ip: ip) { target, _ in
            Task { @MainActor in
                self.adding = false
                if let target {
                    self.notice = "Added \(target.name)"
                    self.ipText = ""
                    self.onAdded()
                } else {
                    self.notice = "No renderer found at \(ip)"
                }
            }
        }
    }

    private func remove(_ device: DiscoveredDevice) {
        RigelCore.shared.devices.removeManualDevice(target: device.target)
        manualDevices.removeAll { $0.target.stableId == device.target.stableId }
        onRemoved()
    }
}
