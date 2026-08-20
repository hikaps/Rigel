import SwiftUI
import ComposeApp

/// Send flow: confirm/adjust the URL a remote screen will fetch, then dispatch
/// to the right adapter via CastDispatcher (Kotlin).
struct CastSheetView: View {
    let target: CastTarget
    let onResult: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var url: String
    @State private var busy = false

    init(target: CastTarget, onResult: @escaping (String) -> Void) {
        self.target = target
        self.onResult = onResult
        _url = State(initialValue: CastDispatcher.shared.remoteCastUrl() ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(target.name)
                            .font(.headline)
                    } icon: {
                        Image(systemName: "tv")
                            .foregroundStyle(Color.rigelStar)
                    }
                }

                Section("Capabilities") {
                    capabilityLine
                }

                Section {
                    TextField("URL the screen will fetch", text: $url, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    if url.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No stream loaded — paste a URL the TV/receiver can reach on your network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("URL")
                }

                Section {
                    Button {
                        cast()
                    } label: {
                        HStack {
                            Spacer()
                            if busy {
                                ProgressView()
                            } else {
                                Text("Cast")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rigelStar)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Send to \(target.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .preferredColorScheme(.dark)
    }

    private var capabilityLine: some View {
        let caps = CastDispatcher.shared.capabilities(target: target)
        var parts: [String] = []
        parts.append(caps.supportsSeek ? "Seek" : "No seek")
        parts.append(caps.supportsPosition ? "Position tracking" : "No position tracking")
        if let note = caps.note, !note.isEmpty {
            parts.append(note)
        }
        return Text(parts.joined(separator: " · "))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func cast() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        CastDispatcher.shared.cast(
            target: target,
            url: trimmed,
            title: CastDispatcher.shared.remoteCastTitle()
        ) { result, _ in
            busy = false
            onResult(result ?? "Cast failed")
            dismiss()
        }
    }
}
