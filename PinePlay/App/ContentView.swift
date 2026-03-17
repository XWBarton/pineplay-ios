import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @State private var selectedTab = 0

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
        .overlay {
            if player.isLoading {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 90)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: player.isLoading)
            }
        }
    }
}
