import SwiftUI
import UIKit

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
