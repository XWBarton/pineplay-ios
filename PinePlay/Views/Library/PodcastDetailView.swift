import SwiftUI

struct PodcastDetailView: View {
    let podcast: PodcastItem

    @EnvironmentObject var api: PinepodsAPIService
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var downloads: DownloadManager

    @State private var episodes: [EpisodeItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var filter: EpisodeFilter = .all
    @State private var sortOrder: SortOrder = .newestFirst

    enum EpisodeFilter: String, CaseIterable {
        case all = "All"
        case unplayed = "Unplayed"
        case downloaded = "Downloaded"
    }

    enum SortOrder: String, CaseIterable {
        case newestFirst = "Newest"
        case oldestFirst = "Oldest"
        case title = "Title"
    }

    private var filteredEpisodes: [EpisodeItem] {
        let filtered: [EpisodeItem]
        switch filter {
        case .all: filtered = episodes
        case .unplayed: filtered = episodes.filter { !$0.completed }
        case .downloaded: filtered = episodes.filter { downloads.locallyDownloaded.contains($0.id) }
        }
        switch sortOrder {
        case .newestFirst: return filtered.sorted { $0.pubDate > $1.pubDate }
        case .oldestFirst: return filtered.sorted { $0.pubDate < $1.pubDate }
        case .title: return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        List {
            // Podcast header
            Section {
                HStack(spacing: 16) {
                    PodcastArtworkView(url: podcast.artworkURL, size: 100, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(podcast.name)
                            .font(.title3.bold())
                        if let author = podcast.author {
                            Text(author).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let desc = podcast.description, !desc.isEmpty {
                            HTMLInlineView(text: desc)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(EpisodeFilter.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if isLoading && episodes.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                }
            } else if let error = errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            } else {
                Section {
                    ForEach(filteredEpisodes) { episode in
                        EpisodeRowView(
                            episode: episode,
                            showPodcastName: false,
                            onPlay: { playEpisode(episode) },
                            onDownload: { downloadEpisode(episode) },
                            onDelete: { deleteDownload(episode) },
                            onToggleCompleted: { toggleCompleted(episode) }
                        )
                        .swipeActions(edge: .leading) {
                            if !episode.completed {
                                Button {
                                    Task { try? await api.markEpisodeCompleted(episodeId: episode.id, isYoutube: episode.isYoutube) }
                                } label: {
                                    Label("Played", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    shuffleEpisodes()
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(filteredEpisodes.isEmpty)
            }
        }
        .refreshable { await loadEpisodes() }
        .task { await loadEpisodes() }
    }

    private func loadEpisodes() async {
        isLoading = true
        errorMessage = nil
        do {
            episodes = try await api.getPodcastEpisodes(podcastId: podcast.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playEpisode(_ episode: EpisodeItem) {
        let localURL = downloads.localURL(for: episode.id)
        player.play(episode: episode, localURL: localURL)
        Task { try? await api.recordHistory(episodeId: episode.id, isYoutube: episode.isYoutube) }
    }

    private func downloadEpisode(_ episode: EpisodeItem) {
        downloads.downloadEpisode(episode)
        Task { try? await api.requestServerDownload(episodeId: episode.id, isYoutube: episode.isYoutube) }
    }

    private func deleteDownload(_ episode: EpisodeItem) {
        downloads.deleteLocalDownload(episode.id)
    }

    private func shuffleEpisodes() {
        guard let episode = filteredEpisodes.randomElement() else { return }
        playEpisode(episode)
    }

    private func toggleCompleted(_ episode: EpisodeItem) {
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx].completed.toggle()
        }
        Task {
            do {
                if episode.completed {
                    try await api.markEpisodeUncompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                } else {
                    try await api.markEpisodeCompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                }
            } catch {
                await loadEpisodes()  // revert on failure
            }
        }
    }
}
