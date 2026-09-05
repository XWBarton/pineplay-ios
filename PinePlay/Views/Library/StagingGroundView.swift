import SwiftUI

// MARK: - Library Section

/// Horizontal strip shown beneath the subscribed-podcasts grid in Library —
/// shows the user is considering but hasn't subscribed to yet.
struct StagingGroundSection: View {
    let podcasts: [StagedPodcast]
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Staging Ground")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if podcasts.isEmpty {
                Text("Add shows you want to try before subscribing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(podcasts) { podcast in
                            NavigationLink(destination: StagingPodcastDetailView(podcast: podcast)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    PodcastArtworkView(url: podcast.artworkURL, size: 90, cornerRadius: 10)
                                    Text(podcast.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .frame(width: 90, height: 32, alignment: .topLeading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
                .scrollClipDisabled()
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

// MARK: - Add to Staging Ground

struct AddToStagingView: View {
    @Environment(\.dismiss) var dismiss

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showPasteURL = false
    @State private var pasteURLText = ""
    @State private var isFetchingPastedFeed = false
    @State private var pasteError: String?
    @State private var addedFeedURLs: Set<String> = Set(StagingGround.load().map(\.feedURL))

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && results.isEmpty {
                    ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage, results.isEmpty {
                    ContentUnavailableView {
                        Label("Search Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "Find a Show",
                        systemImage: "magnifyingglass",
                        description: Text("Search for a podcast, or paste a feed URL if you already have one.")
                    )
                } else {
                    List(results) { podcast in
                        HStack(spacing: 12) {
                            PodcastArtworkView(url: podcast.artworkURL, size: 48, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(podcast.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if let author = podcast.author {
                                    Text(author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if addedFeedURLs.contains(podcast.feedURL) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button {
                                    add(podcast)
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Staging Ground")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search podcasts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPasteURL = true } label: {
                        Image(systemName: "link")
                    }
                }
            }
            .task(id: query) {
                guard !query.isEmpty else { results = []; errorMessage = nil; return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await runSearch()
            }
            .alert("Paste Feed URL", isPresented: $showPasteURL) {
                TextField("https://example.com/feed.xml", text: $pasteURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { pasteURLText = "" }
                Button("Add") { Task { await addFromPastedURL() } }
            } message: {
                if let pasteError { Text(pasteError) }
            }
            .overlay {
                if isFetchingPastedFeed {
                    ProgressView("Loading feed…")
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func runSearch() async {
        isSearching = true
        errorMessage = nil
        do {
            results = try await PodcastSearchService.shared.search(term: query)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func add(_ podcast: PodcastSearchResult) {
        StagingGround.add(podcast.toStagedPodcast())
        addedFeedURLs.insert(podcast.feedURL)
    }

    private func addFromPastedURL() async {
        let url = pasteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteURLText = ""
        guard !url.isEmpty else { return }
        isFetchingPastedFeed = true
        pasteError = nil
        do {
            let feed = try await PodcastFeedService.shared.fetchFeed(url: url)
            let staged = StagedPodcast(
                title: feed.title.isEmpty ? url : feed.title, artworkURL: feed.artworkURL,
                author: feed.author, description: feed.description, feedURL: url,
                website: feed.website, episodeCount: feed.episodes.count, explicit: feed.explicit
            )
            StagingGround.add(staged)
            addedFeedURLs.insert(url)
        } catch {
            pasteError = error.localizedDescription
            showPasteURL = true
        }
        isFetchingPastedFeed = false
    }
}

// MARK: - Staging Podcast Detail (preview)

struct StagingPodcastDetailView: View {
    let podcast: StagedPodcast

    @EnvironmentObject var api: PinepodsAPIService
    @EnvironmentObject var player: AudioPlayerManager

    @State private var feed: ParsedFeed?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSubscribing = false
    @State private var subscribeError: String?
    @State private var didSubscribe = false
    @State private var selectedEpisode: ParsedFeedEpisode?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    PodcastArtworkView(url: podcast.artworkURL, size: 100, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(podcast.title).font(.title3.bold())
                        if let author = feed?.author ?? podcast.author {
                            Text(author).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let desc = feed?.description ?? podcast.description, !desc.isEmpty {
                            HTMLInlineView(text: desc).lineLimit(3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding()
                }
            } else if let error = errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                    Button("Retry") { Task { await loadFeed() } }
                }
            } else if let feed, !feed.episodes.isEmpty {
                Section("Episodes") {
                    ForEach(feed.episodes.sorted { $0.pubDate > $1.pubDate }) { episode in
                        StagingEpisodeRow(
                            episode: episode,
                            podcastName: podcast.title,
                            fallbackArtwork: podcast.artworkURL,
                            onTap: { selectedEpisode = episode }
                        )
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    remove()
                } label: {
                    Image(systemName: "trash")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await subscribe() }
                } label: {
                    if isSubscribing {
                        ProgressView()
                    } else {
                        Text("Subscribe")
                    }
                }
                .disabled(isSubscribing)
            }
        }
        .alert("Couldn't Subscribe", isPresented: .constant(subscribeError != nil), actions: {
            Button("OK") { subscribeError = nil }
        }, message: {
            Text(subscribeError ?? "")
        })
        .alert("Subscribed", isPresented: $didSubscribe, actions: {
            Button("OK") { dismiss() }
        }, message: {
            Text("Pinepods is fetching \(podcast.title)'s episodes on the server now — it can take a minute or two to show up in your Library.")
        })
        .sheet(item: $selectedEpisode) { episode in
            StagingEpisodeDetailSheet(
                episode: episode, podcastName: podcast.title, fallbackArtwork: podcast.artworkURL
            )
        }
        .task {
            // Feed URLs registered here let ChaptersService find this show's RSS
            // even though it isn't a real subscription yet.
            PodcastFeedURLRegistry.shared.register(podcast.feedURL, for: podcast.title)
            await loadFeed()
        }
    }

    private func loadFeed() async {
        isLoading = true
        errorMessage = nil
        do {
            feed = try await PodcastFeedService.shared.fetchFeed(url: podcast.feedURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func remove() {
        StagingGround.remove(feedURL: podcast.feedURL)
        dismiss()
    }

    private func subscribe() async {
        isSubscribing = true
        do {
            try await api.addPodcast(
                title: podcast.title,
                artworkURL: feed?.artworkURL ?? podcast.artworkURL,
                author: feed?.author ?? podcast.author,
                description: feed?.description ?? podcast.description,
                feedURL: podcast.feedURL,
                website: feed?.website ?? podcast.website,
                episodeCount: feed?.episodes.count ?? podcast.episodeCount,
                explicit: feed?.explicit ?? podcast.explicit,
                podcastIndexId: podcast.podcastIndexId
            )
            StagingGround.remove(feedURL: podcast.feedURL)
            NotificationCenter.default.post(name: .podcastSubscribed, object: nil)
            didSubscribe = true
        } catch {
            subscribeError = error.localizedDescription
        }
        isSubscribing = false
    }
}

/// A lightweight episode row for feed previews — no download or completed-state
/// controls since the show isn't subscribed yet. Tapping the row opens the
/// detail sheet; only the play/pause button on the right actually plays.
private struct StagingEpisodeRow: View {
    let episode: ParsedFeedEpisode
    let podcastName: String
    let fallbackArtwork: String?
    let onTap: () -> Void

    @EnvironmentObject var player: AudioPlayerManager

    private var episodeItem: EpisodeItem {
        episode.toEpisodeItem(podcastName: podcastName, fallbackArtwork: fallbackArtwork)
    }
    private var isCurrentEpisode: Bool { player.currentEpisode?.id == episodeItem.id }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                PodcastArtworkView(url: episodeItem.artwork, size: 52, cornerRadius: 8)
                if isCurrentEpisode && player.isPlaying {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.4), in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if !episode.pubDate.isEmpty {
                        Text(episode.pubDate.prefix(10))
                    }
                    if episode.duration > 0 {
                        Text(episodeItem.formattedDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if isCurrentEpisode {
                    player.togglePlayPause()
                } else {
                    player.play(episode: episodeItem)
                }
            } label: {
                Image(systemName: isCurrentEpisode && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.accent)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Detail sheet for a Staging Ground episode preview. Deliberately excludes
/// Queue/Play Next/Download — the show isn't subscribed yet, so there's no
/// server episode record to hang those actions off of.
struct StagingEpisodeDetailSheet: View {
    let episode: ParsedFeedEpisode
    let podcastName: String
    let fallbackArtwork: String?

    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) var dismiss

    private var episodeItem: EpisodeItem {
        episode.toEpisodeItem(podcastName: podcastName, fallbackArtwork: fallbackArtwork)
    }
    private var isCurrentPlaying: Bool {
        player.currentEpisode?.id == episodeItem.id && player.isPlaying
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PodcastArtworkView(url: episodeItem.artwork, size: 160, cornerRadius: 16)
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)

                    VStack(spacing: 6) {
                        Text(episode.title)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                        Text(podcastName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            if !episode.pubDate.isEmpty {
                                Text(episode.pubDate.prefix(10))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if episode.duration > 0 {
                                Text(episodeItem.formattedDuration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    Button {
                        if player.currentEpisode?.id == episodeItem.id {
                            player.togglePlayPause()
                        } else {
                            player.play(episode: episodeItem)
                        }
                        dismiss()
                    } label: {
                        Label(isCurrentPlaying ? "Pause" : "Play", systemImage: isCurrentPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)

                    if !episode.description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Episode Notes")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            EpisodeNotesView(text: episode.description)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
