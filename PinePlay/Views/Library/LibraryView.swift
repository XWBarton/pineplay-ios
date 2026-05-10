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
    // Pre-computed search results — updated async off the main thread after debounce.
    @State private var filteredPodcasts: [PodcastItem] = []
    @State private var episodeTitleMatches: [EpisodeItem] = []
    @State private var episodeNotesMatches: [EpisodeItem] = []

    enum LibraryShuffleTarget { case queue, download }
    @State private var shufflePodcast: PodcastItem? = nil
    @State private var showShuffleSheet = false
    @State private var libraryShuffleTarget: LibraryShuffleTarget = .queue
    @State private var libraryShuffleCount: Double = 5
    @State private var libraryShuffleEpisodes: [EpisodeItem] = []
    @State private var isLoadingShuffleEpisodes = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var isSearching: Bool { !searchText.isEmpty }

    /// Word-based match: every whitespace-separated word in `query` must appear
    /// as a substring in `text` (case insensitive).
    private static func fuzzyMatch(_ query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        let t = text.lowercased()
        let words = query.lowercased().split(separator: " ").map(String.init)
        return words.allSatisfy { t.contains($0) }
    }

    private static func fuzzyMatchesAny(_ query: String, in strings: String?...) -> Bool {
        strings.contains { s in s.map { fuzzyMatch(query, in: $0) } ?? false }
    }

    /// Run all filtering off the main thread and publish results back.
    private func applySearch(query: String, podcasts: [PodcastItem], episodes: [EpisodeItem]) async {
        let pods = await Task.detached(priority: .userInitiated) {
            podcasts.filter { LibraryView.fuzzyMatchesAny(query, in: $0.name, $0.author, $0.description) }
        }.value
        let titles = await Task.detached(priority: .userInitiated) {
            episodes.filter { LibraryView.fuzzyMatchesAny(query, in: $0.title, $0.podcastName) }
        }.value
        let titleIds = Set(titles.map(\.id))
        let notes = await Task.detached(priority: .userInitiated) {
            episodes.filter { !titleIds.contains($0.id) && LibraryView.fuzzyMatch(query, in: $0.description) }
        }.value
        filteredPodcasts = pods
        episodeTitleMatches = titles
        episodeNotesMatches = notes
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
            .sheet(isPresented: $showShuffleSheet) {
                libraryShuffleSheet
            }
        }
        .task { await loadPodcasts() }
        .task(id: searchText) {
            guard !searchText.isEmpty else {
                filteredPodcasts = []; episodeTitleMatches = []; episodeNotesMatches = []
                return
            }
            // Kick off episode load on first search
            if searchEpisodes.isEmpty && !isLoadingEpisodes {
                Task { await loadSearchEpisodes() }
            }
            // Debounce: wait 300 ms after the last keystroke before filtering
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await applySearch(query: searchText, podcasts: podcasts, episodes: searchEpisodes)
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
                    .contextMenu {
                        Button {
                            libraryShuffleTarget = .queue
                            libraryShuffleEpisodes = []
                            isLoadingShuffleEpisodes = true
                            shufflePodcast = podcast
                            showShuffleSheet = true
                        } label: {
                            Label("Shuffle to Queue…", systemImage: "shuffle")
                        }
                        Button {
                            libraryShuffleTarget = .download
                            libraryShuffleEpisodes = []
                            isLoadingShuffleEpisodes = true
                            shufflePodcast = podcast
                            showShuffleSheet = true
                        } label: {
                            Label("Shuffle to Download…", systemImage: "arrow.down.circle")
                        }
                    }
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

            // Episodes — title/podcast name matches
            Section {
                if isLoadingEpisodes {
                    HStack {
                        Spacer()
                        ProgressView().padding(.vertical, 8)
                        Spacer()
                    }
                } else if episodeTitleMatches.isEmpty && episodeNotesMatches.isEmpty && !searchEpisodes.isEmpty {
                    Text("No episodes found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(episodeTitleMatches) { episode in
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

            // Episodes — show notes matches (separate section so titles always come first)
            if !isLoadingEpisodes && !episodeNotesMatches.isEmpty {
                Section("Show Notes") {
                    ForEach(episodeNotesMatches) { episode in
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
            }

            if filteredPodcasts.isEmpty && episodeTitleMatches.isEmpty && episodeNotesMatches.isEmpty && !isLoadingEpisodes {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Actions

    @ViewBuilder
    private var libraryShuffleSheet: some View {
        NavigationStack {
            let pool: [EpisodeItem] = {
                guard !libraryShuffleEpisodes.isEmpty else { return [] }
                if libraryShuffleTarget == .download {
                    let notDownloaded = libraryShuffleEpisodes.filter { !downloads.locallyDownloaded.contains($0.id) }
                    return notDownloaded.isEmpty ? libraryShuffleEpisodes : notDownloaded
                }
                return libraryShuffleEpisodes
            }()
            let maxCount = max(1, min(pool.count, 50))
            let safeCount = Binding<Double>(
                get: { min(max(libraryShuffleCount, 1), Double(maxCount)) },
                set: { libraryShuffleCount = $0 }
            )
            let count = Int(safeCount.wrappedValue)

            Form {
                if isLoadingShuffleEpisodes {
                    Section {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: libraryShuffleTarget == .queue ? "shuffle" : "arrow.down.circle")
                                .font(.largeTitle)
                                .foregroundStyle(.tint)
                            Text(libraryShuffleTarget == .queue
                                 ? "Add \(count) shuffled episode\(count == 1 ? "" : "s") to queue"
                                 : "Download \(count) shuffled episode\(count == 1 ? "" : "s")")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        if maxCount > 1 {
                            Slider(value: safeCount, in: 1...Double(maxCount), step: 1)
                                .id(maxCount)
                        }
                        Stepper(
                            "\(count) episode\(count == 1 ? "" : "s")",
                            value: safeCount,
                            in: 1...Double(maxCount),
                            step: 1
                        )
                        .id(maxCount)
                    } header: {
                        Text("Number of episodes")
                    } footer: {
                        if libraryShuffleTarget == .download {
                            Text("\(pool.count) undownloaded episode\(pool.count == 1 ? "" : "s") available")
                        } else {
                            Text("\(libraryShuffleEpisodes.count) episode\(libraryShuffleEpisodes.count == 1 ? "" : "s") available")
                        }
                    }
                }
            }
            .navigationTitle(shufflePodcast?.name ?? "Shuffle Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showShuffleSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        executeLibraryShuffle(count: count)
                        showShuffleSheet = false
                    }
                    .disabled(isLoadingShuffleEpisodes || pool.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .task(id: shufflePodcast?.id) {
            guard let podcast = shufflePodcast else { return }
            isLoadingShuffleEpisodes = true
            libraryShuffleEpisodes = (try? await api.getPodcastEpisodes(podcastId: podcast.id)) ?? []
            let cap = max(1, min(libraryShuffleEpisodes.count, 50))
            libraryShuffleCount = min(libraryShuffleCount, Double(cap))
            isLoadingShuffleEpisodes = false
        }
    }

    private func executeLibraryShuffle(count: Int) {
        let pool: [EpisodeItem]
        if libraryShuffleTarget == .download {
            let notDownloaded = libraryShuffleEpisodes.filter { !downloads.locallyDownloaded.contains($0.id) }
            pool = notDownloaded.isEmpty ? libraryShuffleEpisodes : notDownloaded
        } else {
            pool = libraryShuffleEpisodes
        }
        let shuffled = pool.shuffled().prefix(count)
        switch libraryShuffleTarget {
        case .queue:
            let wasIdle = player.currentEpisode == nil && player.queue.isEmpty
            for ep in shuffled { player.addToQueue(ep) }
            if wasIdle { player.playNextInQueue() }
        case .download:
            for ep in shuffled {
                downloads.downloadEpisode(ep)
                Task { try? await api.requestServerDownload(episodeId: ep.id, isYoutube: ep.isYoutube) }
            }
        }
    }

    private func loadPodcasts() async {
        isLoading = true
        errorMessage = nil
        do {
            podcasts = try await api.getPodcasts()
            for podcast in podcasts {
                PodcastFeedURLRegistry.shared.register(podcast.feedURL, for: podcast.name)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadSearchEpisodes() async {
        isLoadingEpisodes = true
        // Fetch all episodes from every subscribed podcast concurrently so search
        // covers the full back-catalogue, not just recent episodes.
        searchEpisodes = await withTaskGroup(of: [EpisodeItem].self) { group in
            for podcast in podcasts {
                group.addTask { (try? await api.getPodcastEpisodes(podcastId: podcast.id)) ?? [] }
            }
            var all: [EpisodeItem] = []
            for await eps in group { all.append(contentsOf: eps) }
            return all
        }
        isLoadingEpisodes = false
        // Re-run filtering now that the full episode list is available
        if !searchText.isEmpty {
            await applySearch(query: searchText, podcasts: podcasts, episodes: searchEpisodes)
        }
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
