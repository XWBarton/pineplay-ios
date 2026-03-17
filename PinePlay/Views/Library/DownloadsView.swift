import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) var dismiss

    private var activeDownloads: [(episode: EpisodeItem?, id: Int, progress: Double)] {
        downloads.downloadProgress.map { (
            episode: downloads.downloadingEpisodes[$0.key] ?? downloads.episodeMetadata[$0.key],
            id: $0.key,
            progress: $0.value
        )}
        .sorted { $0.id < $1.id }
    }

    private var completedEpisodes: [EpisodeItem] {
        downloads.locallyDownloaded
            .compactMap { downloads.episodeMetadata[$0] }
            .sorted { $0.pubDate > $1.pubDate }
    }

    private var totalSize: String {
        let bytes = downloads.locallyDownloaded.reduce(0) { sum, id in
            let url = downloads.episodesDirectory.appendingPathComponent("\(id).audio")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return sum + size
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func fileSize(for id: Int) -> String {
        let url = downloads.episodesDirectory.appendingPathComponent("\(id).audio")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            List {
                // Active downloads
                if !activeDownloads.isEmpty {
                    Section("Downloading") {
                        ForEach(activeDownloads, id: \.id) { item in
                            HStack(spacing: 12) {
                                ZStack {
                                    if let artwork = item.episode?.artwork {
                                        PodcastArtworkView(url: artwork, size: 44, cornerRadius: 6)
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(width: 44, height: 44)
                                    }
                                    // Progress ring overlay
                                    ZStack {
                                        Circle()
                                            .stroke(Color.black.opacity(0.35), lineWidth: 3)
                                        Circle()
                                            .trim(from: 0, to: item.progress)
                                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                            .animation(.linear(duration: 0.2), value: item.progress)
                                    }
                                    .frame(width: 28, height: 28)
                                }
                                .frame(width: 44, height: 44)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.episode?.title ?? "Episode \(item.id)")
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    if let podcastName = item.episode?.podcastName {
                                        Text(podcastName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text("\(Int(item.progress * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Button {
                                    downloads.cancelDownload(item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Completed downloads
                if !completedEpisodes.isEmpty {
                    Section {
                        ForEach(completedEpisodes) { episode in
                            HStack(spacing: 12) {
                                PodcastArtworkView(url: episode.artwork, size: 44, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(episode.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(episode.podcastName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(fileSize(for: episode.id))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Button {
                                    let localURL = downloads.localURL(for: episode.id)
                                    player.play(episode: episode, localURL: localURL)
                                    dismiss()
                                } label: {
                                    Image(systemName: "play.circle")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { completedEpisodes[$0].id }
                            ids.forEach { downloads.deleteLocalDownload($0) }
                        }
                    } header: {
                        Text("Downloaded · \(totalSize)")
                    }
                } else if downloads.locallyDownloaded.isEmpty && activeDownloads.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Downloaded episodes will appear here.")
                    )
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .task { await downloads.syncMissingMetadata() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
