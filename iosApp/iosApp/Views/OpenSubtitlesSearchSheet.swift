import SwiftUI
import ComposeApp

struct OpenSubtitlesSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [OpenSubtitlesSearchResult] = []
    @State private var isSearching = false
    @State private var downloadingID: Int?
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?

    let client: OpenSubtitlesClient
    let onDownloaded: (SubtitleTrack) -> Void

    init(query: String, client: OpenSubtitlesClient, onDownloaded: @escaping (SubtitleTrack) -> Void) {
        _query = State(initialValue: query)
        self.client = client
        self.onDownloaded = onDownloaded
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Movie or show title", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button("Search") { search() }
                        .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()

                if isSearching {
                    ProgressView("Searching OpenSubtitles…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                        Button("Try Again") { search() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "captions.bubble")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No subtitles found")
                            .font(.headline)
                        Text("Try a different title or include the release year.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results) { result in
                        Button {
                            download(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.displayTitle)
                                    .foregroundStyle(.primary)
                                Text(result.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if downloadingID == result.id {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(downloadingID != nil)
                    }
                }
            }
            .navigationTitle("OpenSubtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { search() }
        .onDisappear {
            requestTask?.cancel()
            requestTask = nil
            isSearching = false
            downloadingID = nil
        }
    }

    private func search() {
        guard requestTask == nil else { return }
        let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedQuery.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        let task = Task { @MainActor in
            do {
                let language = Locale.preferredLanguages.first?
                    .split(separator: "-")
                    .first
                    .map(String.init)
                let found = try await client.search(query: requestedQuery, language: language)
                guard !Task.isCancelled else { return }
                results = found
                isSearching = false
                requestTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
                isSearching = false
                requestTask = nil
            }
        }
        requestTask = task
    }

    private func download(_ result: OpenSubtitlesSearchResult) {
        guard requestTask == nil, downloadingID == nil else { return }
        downloadingID = result.id
        errorMessage = nil
        let task = Task { @MainActor in
            do {
                let url = try await client.download(result)
                guard !Task.isCancelled else { return }
                let track = SubtitleTrack(
                    url: url.absoluteString,
                    language: result.language,
                    title: result.displayTitle
                )
                onDownloaded(track)
                dismiss()
                downloadingID = nil
                requestTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                downloadingID = nil
                requestTask = nil
            }
        }
        requestTask = task
    }
}
