import SwiftUI
import AVKit
import ComposeApp

struct DevicesView: View {
    @State private var devices: [DiscoveredDevice] = []
    @State private var scanning = false
    @State private var notice: String?
    @State private var busyTarget: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("AirPlay & Bluetooth")
                        Spacer(minLength: 8)
                        RoutePickerRow()
                            .frame(width: 44, height: 44)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("AirPlay")
                } footer: {
                    Text("Sends playback to Apple TVs, HomePods, and AirPlay speakers.")
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
                            Text("No screens found")
                                .font(.subheadline.weight(.semibold))
                            Text("Make sure your TV is on the same Wi-Fi, then scan again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(devices, id: \.stableId) { device in
                        DeviceRow(
                            device: device,
                            isCasting: busyTarget == device.target.stableId,
                            showRemove: device.via == "manual",
                            onCast: { castNow(device) },
                            onRemove: { remove(device) }
                        )
                    }
                } header: {
                    Text("On your network")
                }

                Section {
                    NavigationLink {
                        DeviceSetupView(
                            devices: devices,
                            onAdded: { scan() },
                            onRemoved: { scan() }
                        )
                    } label: {
                        Label("Can't find your device?", systemImage: "questionmark.circle")
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
            .navigationTitle("Playback Destination")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        scan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(scanning)
                    .accessibilityLabel("Scan for devices")
                }
            }
            .task { scan() }
        }
    }

    private func scan() {
        scanning = true
        notice = nil
        RigelCore.shared.devices.scan(timeoutMs: 5000) { found, _ in
            Task { @MainActor in
                self.devices = found ?? []
                self.scanning = false
            }
        }
    }

    private func castNow(_ device: DiscoveredDevice) {
        guard busyTarget == nil else { return }
        guard let url = CastDispatcher.shared.remoteCastUrl(), !url.isEmpty else {
            notice = "Nothing to send — play a stream first"
            return
        }

        busyTarget = device.target.stableId
        notice = nil
        CastDispatcher.shared.cast(
            target: device.target,
            url: url,
            title: CastDispatcher.shared.remoteCastTitle()
        ) { result, _ in
            Task { @MainActor in
                self.busyTarget = nil
                self.notice = result ?? "Cast failed"
            }
        }
    }

    private func remove(_ device: DiscoveredDevice) {
        guard device.via == "manual" else { return }
        RigelCore.shared.devices.removeManualDevice(target: device.target)
        devices.removeAll { $0.stableId == device.stableId }
    }
}

private extension DiscoveredDevice {
    var stableId: String { target.stableId }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let isCasting: Bool
    let showRemove: Bool
    let onCast: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let onCast = onCast {
                Button(action: onCast) {
                    destinationLabel
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isCasting)
            } else {
                destinationLabel
            }

            if isCasting {
                ProgressView()
                    .accessibilityLabel("Sending to \(device.target.name)")
            } else if showRemove {
                Menu {
                    Button("Remove", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Options for \(device.target.name)")
            }
        }
        .padding(.vertical, 2)
    }

    private var destinationLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .foregroundStyle(Color.rigelStar)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.target.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(device.target.kindLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.rigelStarDim, in: Capsule())
                        .foregroundStyle(Color.rigelStar)

                    if device.via == "manual" {
                        Text("Manual")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct RoutePickerRow: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
