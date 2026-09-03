import SwiftUI
import ComposeApp

struct HistoryView: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var entries: [LinkHistoryEntry] = []
    @State private var confirmClear = false

    private var settings: SettingsStore { RigelCore.shared.settings }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !entries.isEmpty {
                    Button("Clear", role: .destructive) {
                        confirmClear = true
                    }
                }
            }
            .confirmationDialog(
                "Clear all links from history?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    settings.clearLinkHistory()
                    reload()
                }
            }
            .onAppear { reload() }
            .onChange(of: player.phase) { _ in reload() }
        }
    }

    private var historyList: some View {
        List {
            ForEach(entries, id: \.url) { entry in
                Button {
                    _ = player.open(url: entry.url, title: entry.title)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title ?? entry.url)
                            .lineLimit(1)
                        if entry.title != nil {
                            Text(entry.url)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(Color.rigelStar)
            Text("No links yet")
                .font(.headline)
            Text("Links you open or receive appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func reload() {
        entries = settings.linkHistory()
    }
}
