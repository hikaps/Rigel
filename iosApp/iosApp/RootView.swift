import SwiftUI
import UIKit

extension Color {
    /// Rigel identity: a blue supergiant.
    static let rigelStar = Color(red: 0.357, green: 0.722, blue: 1.0) // #5BB8FF
    static let rigelStarDim = Color(red: 0.086, green: 0.2, blue: 0.302) // #16334D
    static let rigelInk = Color(red: 0.043, green: 0.055, blue: 0.078) // #0B0E14
    static let rigelSteel = Color(red: 0.561, green: 0.639, blue: 0.749) // #8FA3BF
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var tab = Tab.home

    enum Tab: Hashable {
        case home, devices, sources, history, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView(
                onOpenDevices: { tab = .devices },
                onOpenSources: { tab = .sources }
            )
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(Tab.home)

            DevicesView()
                .tabItem { Label("Devices", systemImage: "tv") }
                .tag(Tab.devices)

            SourcesView()
                .tabItem { Label("Sources", systemImage: "video") }
                .tag(Tab.sources)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.fill") }
                .tag(Tab.history)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Color.rigelStar)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $player.showPlayer) {
            PlayerHostView()
                .environmentObject(player)
        }
    }
}
