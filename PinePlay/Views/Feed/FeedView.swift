import SwiftUI
import Combine

struct FeedView: View {
    @EnvironmentObject var api: PinepodsAPIService
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var network: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase

    @State private var episodes: [EpisodeItem] = []
    @State private var inProgress: [EpisodeItem] = []
    @State private var dismissedIds: Set<Int> = {
        let arr = UserDefaults.standard.array(forKey: "dismissedContinueListeningIds") as? [Int] ?? []
        return Set(arr)
    }()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEpisode: EpisodeItem?
    /// True when the feed came from parsing subscribed shows' RSS feeds directly
    /// because the Pinepods server call failed (but the device still has internet).
    @State private var serverUnreachable = false

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
                        if serverUnreachable {
                            Section {
                                HStack(spacing: 6) {
                                    Image(systemName: "wifi.exclamationmark")
                                        .font(.caption.weight(.semibold))
                                    Text("Server Unreachable")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("Showing episodes from RSS")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                        }
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
                                            toggleCompleted(episode)
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
                                                    dismissedIds.insert(episode.id)
                                                    UserDefaults.standard.set(Array(dismissedIds), forKey: "dismissedContinueListeningIds")
                                                }, onMarkCompleted: {
                                                    markCompleted(episode)
                                                })
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.trailing, 8)
                                    }
                                    // The viewport sits inset from the screen edge inside the
                                    // list header — without this, artwork clips mid-screen.
                                    .scrollClipDisabled()

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
            // Skip when running on the RSS fallback: those episodes carry synthetic
            // ids distinct from any real server-id copy already downloaded, so
            // auto-download can't tell they're not new — it would re-download the
            // whole "most recent N per show" backlog under fresh ids every time.
            if !serverUnreachable {
                downloads.autoDownloadNewEpisodes(episodes)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await loadFeed() }
            }
        }
        .onChange(of: network.isOffline) { _, _ in Task { await loadFeed() } }
        .onReceive(NotificationCenter.default.publisher(for: .feedMutedPodcastsChanged)) { _ in
            Task { await loadFeed() }
        }
        // onReceive subscribes to the specific @Published property, not the whole player,
        // so FeedView doesn't re-render on every currentTime tick.
        // @Published emits the current value immediately on subscription — so this fires
        // even if the episode was already playing before Feed tab was ever opened.
        .onReceive(AudioPlayerManager.shared.$lastProgressResetId) { episodeId in
            guard let id = episodeId else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                inProgress.removeAll { $0.id == id }
            }
        }
        // Drop episodes from Continue Listening the moment they have <30 s left.
        .onReceive(AudioPlayerManager.shared.$nearlyFinishedId) { episodeId in
            guard let id = episodeId else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                inProgress.removeAll { $0.id == id }
            }
        }
        .onReceive(AudioPlayerManager.shared.$currentEpisode) { episode in
            // Staging Ground previews have no server-side episode record — they
            // don't belong in Continue Listening, which drives history/completed
            // API calls keyed on a real episode id.
            guard let ep = episode, !ep.isPreview, !isNearlyFinished(ep) else { return }
            // Playing an episode is explicit user intent — remove from dismissed so it
            // reappears in Continue Listening.
            if dismissedIds.contains(ep.id) {
                dismissedIds.remove(ep.id)
                UserDefaults.standard.set(Array(dismissedIds), forKey: "dismissedContinueListeningIds")
            }
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
        let mutedNames = FeedPreferences.mutedPodcastNames()
        if network.isOffline {
            episodes = downloads.episodeMetadata.values
                .filter { downloads.locallyDownloaded.contains($0.id) && !mutedNames.contains($0.podcastName) }
                .sorted { $0.pubDate > $1.pubDate }
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            episodes = try await api.getRecentEpisodes().filter { !mutedNames.contains($0.podcastName) }
            serverUnreachable = false
            // Rebuild from server, then merge in anything already in inProgress
            // (e.g. a completed episode the user scrubbed back into — don't drop it).
            let resetIds = AudioPlayerManager.shared.progressResetIds
            var updated = episodes.filter {
                ($0.listenDuration ?? 0) > 0 && !$0.completed
                    && !resetIds.contains($0.id) && !isNearlyFinished($0)
            }
            for existing in inProgress where !updated.contains(where: { $0.id == existing.id })
                && !isNearlyFinished(existing) && !mutedNames.contains(existing.podcastName) {
                updated.append(existing)
            }
            // Rescue episodes whose progress was saved locally but not yet synced to the server.
            // localProgress persists across launches so episodes don't vanish after an app kill.
            let localProgress = AudioPlayerManager.shared.localProgress
            for episode in episodes where !episode.completed && !updated.contains(where: { $0.id == episode.id }) {
                if let localSecs = localProgress[episode.id], localSecs > 0, !isNearlyFinished(episode) {
                    updated.append(episode)
                }
            }
            // Ensure the currently playing episode is always present
            if let playing = AudioPlayerManager.shared.currentEpisode, !playing.isPreview,
               !updated.contains(where: { $0.id == playing.id }),
               !isNearlyFinished(playing), !mutedNames.contains(playing.podcastName) {
                updated.append(playing)
            }
            // Fallback: if the server didn't return the last-played episode with progress yet
            // (e.g. app was killed before the 15 s save fired), use the locally cached copy.
            let savedTime = UserDefaults.standard.integer(forKey: "lastPlaybackTime")
            if savedTime > 0,
               let data = UserDefaults.standard.data(forKey: "lastPlayingEpisode"),
               let lastEpisode = try? JSONDecoder().decode(EpisodeItem.self, from: data),
               !updated.contains(where: { $0.id == lastEpisode.id }),
               !episodes.contains(where: { $0.id == lastEpisode.id && $0.completed }),
               !isNearlyFinished(lastEpisode), !mutedNames.contains(lastEpisode.podcastName) {
                updated.append(lastEpisode)
            }
            // Sort by most recently listened — episodes with no recorded date go to the end.
            // Filter out episodes the user has dismissed (they re-appear only when played again).
            let dates = AudioPlayerManager.shared.lastListenedDates
            inProgress = updated
                .filter { !dismissedIds.contains($0.id) }
                .sorted { a, b in
                    let da = dates[a.id] ?? .distantPast
                    let db = dates[b.id] ?? .distantPast
                    return da > db
                }
        } catch {
            await fallBackToRSS(error: error, mutedNames: mutedNames)
        }
        isLoading = false
    }

    /// Called when the server call fails but the device still has internet.
    /// Parses each cached subscription's RSS feed directly (bypassing the
    /// server entirely) so there's still something to browse and download.
    /// Continue Listening is rebuilt from locally-tracked progress only, since
    /// there's no server data to merge in.
    private func fallBackToRSS(error: Error, mutedNames: Set<String>) async {
        guard !downloads.cachedPodcasts.isEmpty else {
            errorMessage = error.localizedDescription
            return
        }
        let rssEpisodes = await PodcastFeedService.shared.fetchRecentEpisodes(from: downloads.cachedPodcasts)
        guard !rssEpisodes.isEmpty else {
            errorMessage = error.localizedDescription
            return
        }
        episodes = rssEpisodes.filter { !mutedNames.contains($0.podcastName) }
        serverUnreachable = true

        let localProgress = AudioPlayerManager.shared.localProgress
        var updated = Array(downloads.episodeMetadata.values)
            .filter { !$0.completed && !mutedNames.contains($0.podcastName) }
            .filter { (localProgress[$0.id] ?? 0) > 0 && !isNearlyFinished($0) }
        if let playing = AudioPlayerManager.shared.currentEpisode, !playing.isPreview,
           !updated.contains(where: { $0.id == playing.id }),
           !isNearlyFinished(playing), !mutedNames.contains(playing.podcastName) {
            updated.append(playing)
        }
        let dates = AudioPlayerManager.shared.lastListenedDates
        inProgress = updated
            .filter { !dismissedIds.contains($0.id) }
            .sorted { a, b in
                let da = dates[a.id] ?? .distantPast
                let db = dates[b.id] ?? .distantPast
                return da > db
            }
    }

    /// Episodes with less than 30 s of playtime left are treated as finished and
    /// kept out of Continue Listening. Uses the freshest progress available —
    /// the local cache (updated every 15 s) wins over the server's listenDuration.
    private func isNearlyFinished(_ episode: EpisodeItem) -> Bool {
        guard episode.duration > 0 else { return false }
        let local = AudioPlayerManager.shared.localProgress[episode.id] ?? 0
        let listened = max(local, Double(episode.listenDuration ?? 0))
        guard listened > 0 else { return false }
        return Double(episode.duration) - listened <= 30
    }

    private func playEpisode(_ episode: EpisodeItem) {
        let localURL = downloads.localURL(for: episode.id)
        AudioPlayerManager.shared.play(episode: episode, localURL: localURL)
        // RSS-fallback episodes have no server-side record — nothing to sync history to.
        guard !episode.isPreview else { return }
        Task { try? await api.recordHistory(episodeId: episode.id, isYoutube: episode.isYoutube) }
    }

    private func downloadEpisode(_ episode: EpisodeItem) {
        downloads.downloadEpisode(episode)
        guard !episode.isPreview else { return }
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
        // If this episode is in the player, remove it
        if AudioPlayerManager.shared.currentEpisode?.id == episode.id {
            AudioPlayerManager.shared.clearPlayer()
        }
        // RSS-fallback episodes have no server-side record to update.
        guard !episode.isPreview else { return }
        Task {
            try? await api.markEpisodeCompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
        }
    }

    private func toggleCompleted(_ episode: EpisodeItem) {
        // Optimistic update — flip locally so UI responds instantly
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx].completed.toggle()
            if episode.completed {
                // Marking as unplayed — reset listen progress so it leaves Continue Listening
                episodes[idx].listenDuration = 0
            }
            inProgress = episodes.filter { ($0.listenDuration ?? 0) > 0 && !$0.completed }
            if let playing = AudioPlayerManager.shared.currentEpisode,
               !playing.completed,
               !inProgress.contains(where: { $0.id == playing.id }) {
                inProgress.insert(playing, at: 0)
            }
        }
        // If marking as completed and this episode is in the player, remove it
        if !episode.completed, AudioPlayerManager.shared.currentEpisode?.id == episode.id {
            AudioPlayerManager.shared.clearPlayer()
        }
        if episode.completed {
            // Marking as unplayed — also wipe local progress cache
            AudioPlayerManager.shared.resetProgress(for: episode.id)
        }
        // RSS-fallback episodes have no server-side record — the optimistic
        // local flip above is final; there's no server truth to sync or revert to.
        guard !episode.isPreview else { return }
        Task {
            do {
                if episode.completed {
                    try await api.markEpisodeUncompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                    try? await api.updateEpisodeProgress(episodeId: episode.id, listenDuration: 0, isYoutube: episode.isYoutube)
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
    private var progress: Double {
        if isCurrentEpisode { return player.progressFraction }
        if let localSecs = player.localProgress[episode.id], episode.duration > 0 {
            return min(1.0, localSecs / Double(episode.duration))
        }
        return episode.progress
    }

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
                .frame(width: 90, height: 32, alignment: .topLeading)
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
        // Swipe-up to dismiss via a UIKit pan that only begins on clearly-upward
        // drags. Horizontal pans never trigger it (carousel scrolls), downward pans
        // never trigger it (feed scrolls), and when it does begin, UIKit exclusivity
        // keeps the scroll views still — a combination SwiftUI's DragGesture can't
        // express (.gesture blocks scrolling entirely, .simultaneousGesture can't
        // stop the feed from scrolling during the swipe).
        .modifier(SwipeUpToDismissModifier(dragOffset: $dragOffset) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                onDismiss?()
            }
        })
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

// MARK: - Vertical dismiss gesture

private struct SwipeUpToDismissModifier: ViewModifier {
    @Binding var dragOffset: CGFloat
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(VerticalDismissGesture(
                onChanged: { dy in dragOffset = min(0, dy) },
                onEnded: { dy, vy in
                    if dy < -40 || vy < -300 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                            dragOffset = 0
                        }
                    }
                }
            ))
        } else {
            // Pre-iOS 18 fallback: simultaneous drag keeps side-scrolling smooth,
            // though the feed may also scroll a little during the swipe.
            content.simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .onChanged { value in
                        if value.translation.height < 0,
                           abs(value.translation.height) > abs(value.translation.width) * 1.5 {
                            dragOffset = value.translation.height
                        } else {
                            dragOffset = 0
                        }
                    }
                    .onEnded { value in
                        let distance = value.translation.height
                        let velocity = value.predictedEndTranslation.height
                        let isVertical = abs(distance) > abs(value.translation.width) * 1.5
                        if isVertical && (distance < -50 || velocity < -400) {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
        }
    }
}

/// A pan recognizer that only begins on clearly-upward drags, used for
/// swipe-up-to-dismiss on Continue Listening cards.
@available(iOS 18.0, *)
private struct VerticalDismissGesture: UIGestureRecognizerRepresentable {
    /// Called with the vertical translation while dragging.
    let onChanged: (CGFloat) -> Void
    /// Called with the final vertical translation and velocity.
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let view = recognizer.view else { return }
        switch recognizer.state {
        case .changed:
            onChanged(recognizer.translation(in: view).y)
        case .ended:
            onEnded(recognizer.translation(in: view).y, recognizer.velocity(in: view).y)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            // Upward and clearly more vertical than horizontal — anything else is
            // left for the carousel (horizontal) or the feed (downward) to scroll.
            return velocity.y < 0 && abs(velocity.y) > abs(velocity.x) * 1.5
        }
    }
}
