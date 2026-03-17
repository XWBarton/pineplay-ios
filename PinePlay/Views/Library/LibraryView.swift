import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var api: PinepodsAPIService
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var downloads: DownloadManager

    @State private var podcasts: [PodcastItem] = []
    @State private var searchEpisodes: [EpisodeItem] = []
    @State private var isLoading = false
    @State private var isLoadingEpisodes = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showDownloads = false
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var isSearching: Bool { !searchText.isEmpty }

    private var filteredPodcasts: [PodcastItem] {
        podcasts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.author?.localizedCaseInsensitiveContains(searchText) == true ||
            $0.description?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private var filteredEpisodes: [EpisodeItem] {
        searchEpisodes.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.podcastName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && podcasts.isEmpty {
                    ProgressView("Loading library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage, podcasts.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load Library", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await loadPodcasts() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if podcasts.isEmpty {
                    ContentUnavailableView(
                        "No Podcasts",
                        systemImage: "headphones",
                        description: Text("Subscribe to podcasts from the web interface.")
                    )
                } else if isSearching {
                    searchResults
                } else {
                    podcastGrid
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search podcasts & episodes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDownloads = true } label: {
                        Image(systemName: "arrow.down.circle")
                            .overlay(alignment: .topTrailing) {
                                if !downloads.downloadProgress.isEmpty {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 3, y: -3)
                                }
                            }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showDownloads) {
                DownloadsView()
            }
        }
        .task { await loadPodcasts() }
        .onChange(of: searchText) { _, new in
            if !new.isEmpty && searchEpisodes.isEmpty && !isLoadingEpisodes {
                Task { await loadSearchEpisodes() }
            }
        }
    }

    // MARK: - Subviews

    private var podcastGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(podcasts) { podcast in
                    NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                        PodcastGridCell(podcast: podcast)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .refreshable { await loadPodcasts() }
    }

    private var searchResults: some View {
        List {
            // Podcasts section
            if !filteredPodcasts.isEmpty {
                Section("Podcasts") {
                    ForEach(filteredPodcasts) { podcast in
                        NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                            HStack(spacing: 12) {
                                PodcastArtworkView(url: podcast.artworkURL, size: 48, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(podcast.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    if let author = podcast.author {
                                        Text(author)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Episodes section
            Section {
                if isLoadingEpisodes {
                    HStack {
                        Spacer()
                        ProgressView().padding(.vertical, 8)
                        Spacer()
                    }
                } else if filteredEpisodes.isEmpty && !searchEpisodes.isEmpty {
                    Text("No episodes found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(filteredEpisodes) { episode in
                        EpisodeRowView(
                            episode: episode,
                            showPodcastName: true,
                            onPlay: { playEpisode(episode) },
                            onDownload: { downloadEpisode(episode) },
                            onDelete: { downloads.deleteLocalDownload(episode.id) },
                            onToggleCompleted: { toggleCompleted(episode) }
                        )
                    }
                }
            } header: {
                Text("Episodes")
            }

            if filteredPodcasts.isEmpty && filteredEpisodes.isEmpty && !isLoadingEpisodes {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func loadPodcasts() async {
        isLoading = true
        errorMessage = nil
        do {
            podcasts = try await api.getPodcasts()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadSearchEpisodes() async {
        isLoadingEpisodes = true
        searchEpisodes = (try? await api.getRecentEpisodes()) ?? []
        isLoadingEpisodes = false
    }

    private func playEpisode(_ episode: EpisodeItem) {
        player.play(episode: episode, localURL: downloads.localURL(for: episode.id))
        Task { try? await api.recordHistory(episodeId: episode.id, isYoutube: episode.isYoutube) }
    }

    private func downloadEpisode(_ episode: EpisodeItem) {
        downloads.downloadEpisode(episode)
        Task { try? await api.requestServerDownload(episodeId: episode.id, isYoutube: episode.isYoutube) }
    }

    private func toggleCompleted(_ episode: EpisodeItem) {
        if let idx = searchEpisodes.firstIndex(where: { $0.id == episode.id }) {
            searchEpisodes[idx].completed.toggle()
        }
        Task {
            do {
                if episode.completed {
                    try await api.markEpisodeUncompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                } else {
                    try await api.markEpisodeCompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                }
            } catch {
                searchEpisodes = (try? await api.getRecentEpisodes()) ?? []  // revert on failure
            }
        }
    }
}

struct PodcastGridCell: View {
    let podcast: PodcastItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PodcastArtworkView(url: podcast.artworkURL, size: .infinity, cornerRadius: 12)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: podcast.name, font: .footnote.weight(.semibold))
                    .frame(height: 16)

                if let author = podcast.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let count = podcast.episodeCount {
                    Text("\(count) episodes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
