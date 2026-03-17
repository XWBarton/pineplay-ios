import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var player: AudioPlayerManager
    let onTap: () -> Void

    var body: some View {
        if let episode = player.currentEpisode {
            Button(action: onTap) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        PodcastArtworkView(url: episode.artwork, size: 44, cornerRadius: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                            Text(episode.podcastName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if player.isLoading {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Button {
                                player.togglePlayPause()
                            } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color(red: 0.18, green: 0.45, blue: 0.31))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            player.skip(by: 30)
                        } label: {
                            Image(systemName: "goforward.30")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    // Progress bar inside the card
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.1))
                                .frame(height: 3)
                            Capsule()
                                .fill(Color(red: 0.18, green: 0.45, blue: 0.31).opacity(0.8))
                                .frame(width: geo.size.width * player.progressFraction, height: 3)
                                .animation(.linear(duration: 0.5), value: player.progressFraction)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .buttonStyle(.plain)
            .modifier(GlassCardModifier())
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
    }
}
