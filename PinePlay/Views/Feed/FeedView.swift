import SwiftUI
import Combine

struct FeedView: View {
    @EnvironmentObject var api: PinepodsAPIService
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var episodes: [EpisodeItem] = []
    @State private var inProgress: [EpisodeItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEpisode: EpisodeItem?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && episodes.isEmpty {
                    ProgressView("Loading feed…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage, episodes.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load Feed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await loadFeed() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if episodes.isEmpty {
                    ContentUnavailableView(
                        "No Recent Episodes",
                        systemImage: "list.bullet.below.rectangle",
                        description: Text("Subscribe to podcasts to see episodes here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(episodes) { episode in
                                EpisodeRowView(
                                    episode: episode,
                                    showPodcastName: true,
                                    onTap: { selectedEpisode = episode },
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
                                .swipeActions(edge: .trailing) {
                                    Button { downloadEpisode(episode) } label: {
                                        Label("Download", systemImage: "arrow.down.circle")
                                    }
                                    .tint(.blue)
                                }
                            }
                        } header: {
                            if !inProgress.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Continue Listening")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .padding(.bottom, 4)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(inProgress) { episode in
                                                ContinueListeningCard(episode: episode, onPlay: {
                                                    playEpisode(episode)
                                                }, onTap: {
                                                    selectedEpisode = episode
                                                }, onDismiss: {
                                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                                                        inProgress.removeAll { $0.id == episode.id }
                                                    }
                                                }, onMarkCompleted: {
                                                    markCompleted(episode)
                                                })
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.trailing, 8)
                                    }

                                    Text("Recent Episodes")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .padding(.top, 8)
                                }
                                .textCase(nil)
                                .padding(.horizontal, -4)
                            } else {
                                Text("Recent Episodes")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await loadFeed() }
                }
            }
            .navigationTitle("Feed")
            .sheet(item: $selectedEpisode) { ep in
                EpisodeDetailSheet(
                    episode: ep,
                    onPlay: { playEpisode(ep) },
                    onDownload: { downloadEpisode(ep) },
                    onDelete: { deleteDownload(ep) },
                    onToggleCompleted: { toggleCompleted(ep) }
                )
            }
        }
        .task {
            await loadFeed()
            downloads.autoDownloadNewEpisodes(episodes)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await loadFeed() }
            }
        }
        // onReceive subscribes to the specific @Published property, not the whole player,
        // so FeedView doesn't re-render on every currentTime tick.
        // @Published emits the current value immediately on subscription — so this fires
        // even if the episode was already playing before Feed tab was ever opened.
        .onReceive(AudioPlayerManager.shared.$currentEpisode) { episode in
            guard let ep = episode else { return }
            // Always add the currently playing episode — even if marked completed on the
            // server, the user explicitly pressed play so it belongs in Continue Listening.
            if !inProgress.contains(where: { $0.id == ep.id }) {
                inProgress.append(ep)
            }
            // Re-sort immediately so the newly-playing episode moves to the front.
            let dates = AudioPlayerManager.shared.lastListenedDates
            inProgress = inProgress.sorted { a, b in
                let da = dates[a.id] ?? .distantPast
                let db = dates[b.id] ?? .distantPast
                return da > db
            }
        }
    }

    private func loadFeed() async {
        isLoading = true
        errorMessage = nil
        do {
            episodes = try await api.getRecentEpisodes()
            // Rebuild from server, then merge in anything already in inProgress
            // (e.g. a completed episode the user scrubbed back into — don't drop it).
            var updated = episodes.filter { ($0.listenDuration ?? 0) > 0 && !$0.completed }
            for existing in inProgress where !updated.contains(where: { $0.id == existing.id }) {
                updated.append(existing)
            }
            // Ensure the currently playing episode is always present
            if let playing = AudioPlayerManager.shared.currentEpisode,
               !updated.contains(where: { $0.id == playing.id }) {
                updated.append(playing)
            }
            // Fallback: if the server didn't return the last-played episode with progress yet
            // (e.g. app was killed before the 15 s save fired), use the locally cached copy.
            let savedTime = UserDefaults.standard.integer(forKey: "lastPlaybackTime")
            if savedTime > 0,
               let data = UserDefaults.standard.data(forKey: "lastPlayingEpisode"),
               let lastEpisode = try? JSONDecoder().decode(EpisodeItem.self, from: data),
               !updated.contains(where: { $0.id == lastEpisode.id }),
               !episodes.contains(where: { $0.id == lastEpisode.id && $0.completed }) {
                updated.append(lastEpisode)
            }
            // Sort by most recently listened — episodes with no recorded date go to the end.
            let dates = AudioPlayerManager.shared.lastListenedDates
            inProgress = updated.sorted { a, b in
                let da = dates[a.id] ?? .distantPast
                let db = dates[b.id] ?? .distantPast
                return da > db
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playEpisode(_ episode: EpisodeItem) {
        let localURL = downloads.localURL(for: episode.id)
        AudioPlayerManager.shared.play(episode: episode, localURL: localURL)
        Task { try? await api.recordHistory(episodeId: episode.id, isYoutube: episode.isYoutube) }
    }

    private func downloadEpisode(_ episode: EpisodeItem) {
        downloads.downloadEpisode(episode)
        Task { try? await api.requestServerDownload(episodeId: episode.id, isYoutube: episode.isYoutube) }
    }

    private func deleteDownload(_ episode: EpisodeItem) {
        downloads.deleteLocalDownload(episode.id)
    }

    private func markCompleted(_ episode: EpisodeItem) {
        inProgress.removeAll { $0.id == episode.id }
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx].completed = true
        }
        Task {
            try? await api.markEpisodeCompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
        }
    }

    private func toggleCompleted(_ episode: EpisodeItem) {
        // Optimistic update — flip locally so UI responds instantly
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx].completed.toggle()
            inProgress = episodes.filter { ($0.listenDuration ?? 0) > 0 && !$0.completed }
            if let playing = AudioPlayerManager.shared.currentEpisode,
               !playing.completed,
               !inProgress.contains(where: { $0.id == playing.id }) {
                inProgress.insert(playing, at: 0)
            }
        }
        Task {
            do {
                if episode.completed {
                    try await api.markEpisodeUncompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                } else {
                    try await api.markEpisodeCompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                }
            } catch {
                await loadFeed()  // revert on failure
            }
        }
    }
}

// MARK: - Continue Listening Card

struct ContinueListeningCard: View {
    let episode: EpisodeItem
    let onPlay: () -> Void
    var onTap: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var onMarkCompleted: (() -> Void)? = nil
    @EnvironmentObject var player: AudioPlayerManager

    @State private var showCheck = false
    @State private var cardOpacity: Double = 1
    @State private var dragOffset: CGFloat = 0

    private var isCurrentEpisode: Bool { player.currentEpisode?.id == episode.id }
    private var progress: Double { isCurrentEpisode ? player.progressFraction : episode.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Artwork + now-playing indicator
                ZStack(alignment: .bottomTrailing) {
                    PodcastArtworkView(url: episode.artwork, size: 90, cornerRadius: 10)
                        .onTapGesture { if let onTap { onTap() } else { onPlay() } }
                    if isCurrentEpisode && player.isPlaying && !showCheck {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }

                // Played overlay
                if showCheck {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.45))
                        .frame(width: 90, height: 90)
                        .allowsHitTesting(false)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }

                // Mark-as-played button — always tappable, no long press needed
                if !showCheck {
                    Button { markPlayed() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }

            Text(episode.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(width: 90, alignment: .leading)
                .onTapGesture { if let onTap { onTap() } else { onPlay() } }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * progress, height: 3)
                        .animation(.linear(duration: 0.5), value: progress)
                }
            }
            .frame(width: 90, height: 3)
        }
        .opacity(cardOpacity)
        .offset(y: dragOffset)
        .transition(.offset(y: -160).combined(with: .opacity))
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height < 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    let distance = value.translation.height
                    let velocity = value.predictedEndTranslation.height
                    if distance < -40 || velocity < -300 {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                            onDismiss?()
                        }
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    private func markPlayed() {
        withAnimation(.spring(duration: 0.35)) { showCheck = true }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeIn(duration: 0.25)) { cardOpacity = 0 }
            try? await Task.sleep(nanoseconds: 250_000_000)
            onMarkCompleted?()
        }
    }
}
