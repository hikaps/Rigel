import SwiftUI
import AVFoundation

struct TrackPickerOption: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
}

struct TrackPickerSheet: View {
    let title: String
    let options: [TrackPickerOption]
    let emptyMessage: String
    let moreAction: (() -> Void)?
    let customizeAction: (() -> Void)?
    let customizeEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if options.isEmpty {
                    VStack {
                        Spacer()
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        actionButtons
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(options) { option in
                            Button {
                                option.select()
                                dismiss()
                            } label: {
                                HStack {
                                    Text(option.title)
                                    Spacer()
                                    if option.isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(option.isSelected ? "Selected" : "")
                        }
                        Section {
                            actionButtons
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let moreAction {
            Button("Get More from OpenSubtitles") {
                dismiss()
                DispatchQueue.main.async { moreAction() }
            }
        }
        if let customizeAction {
            Button("Customize Subtitles") {
                dismiss()
                DispatchQueue.main.async { customizeAction() }
            }
            .disabled(!customizeEnabled)
            .accessibilityIdentifier("player.customizeSubtitles")
            .accessibilityHint(
                customizeEnabled
                    ? "Adjust the selected sidecar subtitle"
                    : "Select a downloaded or sidecar subtitle to customize"
            )
        }
    }
}
