import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(0)

            FeedView()
                .tabItem { Label("Feed", systemImage: "list.bullet.below.rectangle") }
                .tag(1)

            PlayerView()
                .tabItem {
                    Label("Player", systemImage: player.isLoading ? "waveform" : "play.circle")
                }
                .tag(2)
        }
        .onChange(of: player.currentEpisode?.id) { _, newId in
            if newId != nil {
                withAnimation {
                    selectedTab = 2
                }
            }
        }
    }
}
