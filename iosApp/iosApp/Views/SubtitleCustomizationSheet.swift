import SwiftUI

@MainActor
final class SubtitleCustomizationModel: ObservableObject {
    @Published private(set) var appearance: SubtitleAppearance
    @Published private(set) var delay: TimeInterval
    @Published var isExternalPlaybackActive = false

    private let onChange: (SubtitleAppearance, TimeInterval) -> Void

    init(onChange: @escaping (SubtitleAppearance, TimeInterval) -> Void) {
        appearance = SubtitlePreferences.appearance
        delay = SubtitlePreferences.delay
        self.onChange = onChange
    }

    func updateAppearance(_ update: (inout SubtitleAppearance) -> Void) {
        var next = appearance
        update(&next)
        SubtitlePreferences.appearance = next
        appearance = SubtitlePreferences.appearance
        onChange(appearance, delay)
    }

    func setDelay(_ value: TimeInterval) {
        SubtitlePreferences.delay = min(max(value, -10), 10)
        delay = SubtitlePreferences.delay
        onChange(appearance, delay)
    }

    func adjustFontSize(by delta: CGFloat) {
        updateAppearance {
            $0.fontSizePoints = min(max(($0.fontSizePoints + delta).rounded(), 12), 40)
            $0.fontSizePoints = ($0.fontSizePoints / 2).rounded() * 2
        }
    }

    func reset() {
        SubtitlePreferences.reset()
        appearance = SubtitlePreferences.appearance
        delay = SubtitlePreferences.delay
        onChange(appearance, delay)
    }
}

struct SubtitleCustomizationSheet: View {
    @ObservedObject var model: SubtitleCustomizationModel
    @Environment(\.dismiss) private var dismiss

    private let textColors: [SubtitleColorPreset] = [
        .white, .gold, .cyan, .red, .brightGreen, .purple, .orange, .blue, .black
    ]
    private let backgroundColors: [SubtitleColorPreset] = [
        .transparent, .black, .navy, .darkRed, .darkGreen, .darkBlue
    ]
    private let outlineColors: [SubtitleColorPreset] = [.black, .white, .cyan, .red]

    var body: some View {
        NavigationStack {
            Form {
                Section("Timing") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Subtitle delay")
                            Spacer()
                            Text(String(format: "%+.1f s", model.delay))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { model.delay },
                                set: { model.setDelay($0) }
                            ),
                            in: -10...10,
                            step: 0.1
                        )
                        .accessibilityIdentifier("player.subtitle.delay")
                        .accessibilityLabel("Subtitle delay")
                        .accessibilityValue(String(format: "%+.1f seconds", model.delay))
                        Text("Positive values show subtitles later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Appearance") {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Button {
                            model.adjustFontSize(by: -2)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .accessibilityLabel("Decrease subtitle font size")
                        Text("\(Int(model.appearance.fontSizePoints)) pt")
                            .frame(minWidth: 58)
                            .accessibilityLabel("Subtitle font size")
                            .accessibilityValue("\(Int(model.appearance.fontSizePoints)) points")
                        Button {
                            model.adjustFontSize(by: 2)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Increase subtitle font size")
                    }
                    .accessibilityIdentifier("player.subtitle.fontSize")

                    Toggle(
                        "Bold",
                        isOn: Binding(
                            get: { model.appearance.bold },
                            set: { value in model.updateAppearance { $0.bold = value } }
                        )
                    )
                    .accessibilityIdentifier("player.subtitle.bold")

                    colorSection(
                        title: "Text color",
                        presets: textColors,
                        selected: model.appearance.textColor,
                        identifier: "player.subtitle.textColor"
                    ) { preset in
                        model.updateAppearance { $0.textColor = preset }
                    }

                    opacitySlider(
                        title: "Text opacity",
                        value: Binding(
                            get: { Double(model.appearance.textOpacity) },
                            set: { value in model.updateAppearance { $0.textOpacity = CGFloat(value) } }
                        ),
                        identifier: "player.subtitle.textOpacity"
                    )

                    colorSection(
                        title: "Background color",
                        presets: backgroundColors,
                        selected: model.appearance.backgroundColor,
                        identifier: "player.subtitle.backgroundColor"
                    ) { preset in
                        model.updateAppearance { $0.backgroundColor = preset }
                    }

                    opacitySlider(
                        title: "Background opacity",
                        value: Binding(
                            get: { Double(model.appearance.backgroundOpacity) },
                            set: { value in model.updateAppearance { $0.backgroundOpacity = CGFloat(value) } }
                        ),
                        identifier: "player.subtitle.backgroundOpacity"
                    )

                    Toggle(
                        "Outline",
                        isOn: Binding(
                            get: { model.appearance.outlineEnabled },
                            set: { value in model.updateAppearance { $0.outlineEnabled = value } }
                        )
                    )
                    .accessibilityIdentifier("player.subtitle.outline")

                    colorSection(
                        title: "Outline color",
                        presets: outlineColors,
                        selected: model.appearance.outlineColor,
                        identifier: "player.subtitle.outlineColor",
                        enabled: model.appearance.outlineEnabled
                    ) { preset in
                        model.updateAppearance {
                            $0.outlineEnabled = true
                            $0.outlineColor = preset
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Vertical position")
                            Spacer()
                            Text("\(Int(model.appearance.bottomInset)) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(model.appearance.bottomInset) },
                                set: { value in model.updateAppearance { $0.bottomInset = CGFloat(value) } }
                            ),
                            in: 40...300,
                            step: 10
                        )
                        .accessibilityIdentifier("player.subtitle.bottomInset")
                        .accessibilityLabel("Subtitle vertical position")
                        .accessibilityValue("\(Int(model.appearance.bottomInset)) points")
                    }
                }

                if model.isExternalPlaybackActive {
                    Section {
                        Label(
                            "AirPlay devices control final caption appearance.",
                            systemImage: "airplayvideo"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Reset Defaults") {
                        model.reset()
                    }
                    .accessibilityIdentifier("player.subtitle.reset")
                }
            }
            .navigationTitle("Customize Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func opacitySlider(
        title: String,
        value: Binding<Double>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1, step: 0.1)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
        }
    }

    @ViewBuilder
    private func colorSection(
        title: String,
        presets: [SubtitleColorPreset],
        selected: SubtitleColorPreset,
        identifier: String,
        enabled: Bool = true,
        onSelect: @escaping (SubtitleColorPreset) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            onSelect(preset)
                        } label: {
                            Circle()
                                .fill(Color(uiColor: preset.color))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Circle()
                                        .stroke(
                                            preset == selected ? Color.primary : Color.secondary.opacity(0.45),
                                            lineWidth: preset == selected ? 3 : 1
                                        )
                                }
                        }
                        .disabled(!enabled)
                        .accessibilityLabel(preset.displayName)
                        .accessibilityValue(preset == selected ? "Selected" : "")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier(identifier)
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

