import SwiftUI
import AVFoundation

struct TrackPickerOption: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
}

@MainActor
final class TrackPickerModel: ObservableObject {
    enum Kind {
        case audio
        case subtitles
    }

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    let kind: Kind
    @Published var options: [TrackPickerOption]
    @Published var loadState: LoadState
    @Published var customizeEnabled: Bool

    init(
        kind: Kind,
        options: [TrackPickerOption],
        loadState: LoadState,
        customizeEnabled: Bool = true
    ) {
        self.kind = kind
        self.options = options
        self.loadState = loadState
        self.customizeEnabled = customizeEnabled
    }

    var title: String {
        switch kind {
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        }
    }

    var emptyMessage: String {
        // Usable options always win over state copy, so a late sidecar stays
        // selectable even when native discovery failed.
        if !options.isEmpty { return "" }
        switch kind {
        case .audio:
            switch loadState {
            case .loading: return "Audio tracks are still loading."
            case .loaded: return "No alternate audio tracks are available."
            case .failed: return "Unable to load audio tracks."
            }
        case .subtitles:
            switch loadState {
            case .loading: return "Subtitle tracks are still loading."
            case .loaded: return "No subtitle tracks are available."
            case .failed: return "Unable to load subtitle tracks."
            }
        }
    }
}

struct TrackPickerSheet: View {
    @ObservedObject var model: TrackPickerModel
    let moreAction: (() -> Void)?
    let customizeAction: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.options.isEmpty {
                    VStack {
                        Spacer()
                        Text(model.emptyMessage)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        actionButtons
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(model.options) { option in
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
            .navigationTitle(model.title)
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
            .disabled(!model.customizeEnabled)
            .accessibilityIdentifier("player.customizeSubtitles")
            .accessibilityHint(
                model.customizeEnabled
                    ? "Adjust the selected sidecar subtitle"
                    : "Select a downloaded or sidecar subtitle to customize"
            )
        }
    }
}
